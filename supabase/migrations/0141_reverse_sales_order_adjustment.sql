-- ============================================================================
-- 0141: Phase 6 — Services / Adjustments Core (9/11): reverse_sales_order_
-- adjustment() (§19/§20/§21)
-- ============================================================================
-- Migrations 0001-0140 are unmodified.
--
-- Administrative correction mechanism, NOT a customer refund engine — no
-- Refund Ledger/Settlement interaction. The parent sales_order_adjustments
-- row is NEVER mutated here except a defensive re-check of its row_version
-- token — its financial columns (customer_charge/direct_cost/payment_fee_
-- amount/gross_adjustment_profit/net_adjustment_profit) stay exactly as
-- approved forever, preserving the original effect at adjustment_date. The
-- reversal effect (at reversal_business_date) lives ONLY in the new
-- sales_order_adjustment_reversals row (0135) — the date is never erased as
-- if the Adjustment never happened. Read RPCs (0142) derive
-- effective_status='reversed' and present current effective profit as 0
-- from the mere EXISTENCE of that row, not from any column here.
-- ---------------------------------------------------------------------------
create or replace function public.reverse_sales_order_adjustment(
  p_id uuid,
  p_expected_version bigint,
  p_reversal_business_date date,
  p_reason text,
  p_closed_day_reason text default null
)
returns table (id uuid, reversal_id uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_adj record;
  v_order record;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_reversal_id uuid;
  v_today date := public.business_today();
begin
  -- Permission (§21)
  if v_actor is null or not public.has_permission('adjustments.reverse') then
    raise exception 'ليست لديك صلاحية عكس التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  if v_reason = '' then
    raise exception 'يجب إدخال سبب عكس هذا التعديل/الخدمة' using errcode = 'P0001';
  end if;
  if p_reversal_business_date is null then
    raise exception 'تاريخ العكس (reversal_business_date) مطلوب' using errcode = 'P0001';
  end if;

  -- Lock Adjustment
  select * into v_adj from public.sales_order_adjustments where sales_order_adjustments.id = p_id for update;
  if v_adj.id is null then
    raise exception 'التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;

  -- Concurrency token (§21)
  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لعكس التعديل/الخدمة' using errcode = 'P0001';
  end if;
  if v_adj.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا السجل من جهة أخرى — أعد تحميل الصفحة وحاول مرة أخرى (تعارض الإصدارات)' using errcode = 'P0001';
  end if;

  -- Only an APPROVED record can be reversed.
  if v_adj.status <> 'approved' then
    raise exception 'لا يمكن عكس إلا تعديل/خدمة معتمد' using errcode = 'P0001';
  end if;

  -- One-effective-reversal-max (§21) — friendly pre-check ahead of the
  -- UNIQUE(sales_order_adjustment_id) constraint on the reversals table.
  if exists (select 1 from public.sales_order_adjustment_reversals r where r.sales_order_adjustment_id = p_id) then
    raise exception 'تم عكس هذا التعديل/الخدمة مسبقًا — لا يمكن عكسه أكثر من مرة' using errcode = 'P0001';
  end if;

  -- §24 — Disabled-store historical-visibility rule: reversal is a
  -- CORRECTION on historical data, not new work, so the processing store
  -- only needs to be VISIBLE (not operable) at reversal time. Same for the
  -- linked Sales Order's store.
  select * into v_order from public.sales_orders where sales_orders.id = v_adj.sales_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير مرئية لك' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_adj.processing_store_id) then
    raise exception 'المتجر المُعالِج غير مرئي لك' using errcode = 'P0001';
  end if;

  -- Date bounds (§21) — the reversal cannot be dated before the original
  -- effect it is reversing, and cannot be in the future.
  if p_reversal_business_date < v_adj.adjustment_date then
    raise exception 'تاريخ العكس لا يمكن أن يسبق تاريخ التعديل/الخدمة الأصلي (%)', v_adj.adjustment_date using errcode = 'P0001';
  end if;
  if p_reversal_business_date > v_today then
    raise exception 'تاريخ العكس لا يمكن أن يكون في المستقبل' using errcode = 'P0001';
  end if;

  -- Daily Close (§22) — shared lock keyed on (processing store, REVERSAL
  -- business date), independent of the original adjustment_date's lock.
  perform public.acquire_daily_close_lock_shared(v_adj.processing_store_id, p_reversal_business_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = v_adj.processing_store_id and dc.business_date = p_reversal_business_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('adjustments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن عكس تعديل/خدمة فيه إلا بصلاحية خاصة (adjustments.process_closed_day)', p_reversal_business_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لعكس تعديل/خدمة في يوم مقفل' using errcode = 'P0001';
    end if;
    v_used_closed_day_override := true;
  end if;

  -- Append-only reversal — the parent row's financial columns are NEVER
  -- touched, only appended-to via this new row.
  insert into public.sales_order_adjustment_reversals (
    sales_order_adjustment_id, reversal_business_date, reason,
    customer_charge_snapshot, direct_cost_snapshot, payment_fee_amount_snapshot,
    gross_adjustment_profit_snapshot, net_adjustment_profit_snapshot,
    expected_row_version, reversed_by
  ) values (
    p_id, p_reversal_business_date, v_reason,
    v_adj.customer_charge, v_adj.direct_cost, v_adj.payment_fee_amount,
    v_adj.gross_adjustment_profit, v_adj.net_adjustment_profit,
    v_adj.row_version, v_actor
  )
  returning sales_order_adjustment_reversals.id into v_reversal_id;

  perform public.log_audit_event(
    'adjustment.reverse', 'sales_order_adjustment', p_id,
    jsonb_build_object(
      'adjustment_date', v_adj.adjustment_date, 'customer_charge', v_adj.customer_charge, 'direct_cost', v_adj.direct_cost,
      'payment_fee_amount', v_adj.payment_fee_amount, 'gross_adjustment_profit', v_adj.gross_adjustment_profit,
      'net_adjustment_profit', v_adj.net_adjustment_profit
    ),
    jsonb_build_object('reversal_id', v_reversal_id, 'reversal_business_date', p_reversal_business_date),
    v_reason
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'adjustment.closed_day_override', 'sales_order_adjustment', p_id, null,
      jsonb_build_object('reversal_business_date', p_reversal_business_date, 'reversed_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := p_id;
  reversal_id := v_reversal_id;
  return next;
end;
$$;

comment on function public.reverse_sales_order_adjustment(uuid, bigint, date, text, text) is
  'Phase 6 (§19/§20/§21) — append-only administrative reversal of an APPROVED Service/Adjustment. NOT a customer refund engine. The parent row''s financial columns are never modified — both the original effect (adjustment_date) and the reversal effect (reversal_business_date) remain readable forever via sales_order_adjustment_reversals (0135). At most one effective reversal per adjustment (UNIQUE constraint + pre-check). Requires adjustments.reverse. SECURITY DEFINER.';

revoke execute on function public.reverse_sales_order_adjustment(uuid, bigint, date, text, text) from public;
grant execute on function public.reverse_sales_order_adjustment(uuid, bigint, date, text, text) to authenticated;

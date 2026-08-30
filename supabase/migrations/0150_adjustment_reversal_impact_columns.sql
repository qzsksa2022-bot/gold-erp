-- ============================================================================
-- 0150: Phase 6 Integrity Patch 6.1 (7/13): explicit reversal financial
-- impact columns + backfill + reverse_sales_order_adjustment() v2
-- ============================================================================
-- Migrations 0001-0149 are unmodified. reverse_sales_order_adjustment()'s
-- signature/return type are UNCHANGED — CREATE OR REPLACE in place, only the
-- INSERT statement gains new columns.
--
-- Patch 6.1 item 20 — sales_order_adjustment_reversals (0135) already stored
-- the ORIGINAL (positive) snapshot at the moment of reversal (customer_
-- charge_snapshot/direct_cost_snapshot/payment_fee_amount_snapshot/gross_
-- adjustment_profit_snapshot/net_adjustment_profit_snapshot), but never the
-- IMPACT of the reversal itself as a signed figure — a reader had to
-- remember/re-derive the sign convention. This migration adds five explicit,
-- always-populated impact columns with a fixed, documented sign convention:
--   customer_charge_reversal_amount  = -customer_charge_snapshot
--   direct_cost_reversal_amount      = +direct_cost_snapshot
--   payment_fee_reversal_amount      = +payment_fee_amount_snapshot
--   gross_profit_reversal_amount     = -gross_adjustment_profit_snapshot
--   net_profit_reversal_amount       = -net_adjustment_profit_snapshot
-- i.e. "how much this reversal moves the Effective total by" — a positive
-- number ADDS to the effective total, a negative number SUBTRACTS. Applying
-- net_profit_reversal_amount to the original net_adjustment_profit always
-- yields exactly 0.00 (Original Net + Reversal Impact = Effective Net,
-- item 20's own worked example: 67.50 + (-67.50) = 0.00).
-- ---------------------------------------------------------------------------
alter table public.sales_order_adjustment_reversals
  add column customer_charge_reversal_amount numeric(12, 2),
  add column direct_cost_reversal_amount numeric(12, 2),
  add column payment_fee_reversal_amount numeric(12, 2),
  add column gross_profit_reversal_amount numeric(12, 2),
  add column net_profit_reversal_amount numeric(12, 2);

-- Backfill for any reversal row that existed before this migration — 0135
-- made this table append-only from the start (sales_order_adjustment_
-- reversals_reject_update/_reject_delete triggers unconditionally reject
-- ANY UPDATE/DELETE, with no carve-out for a trusted migration), so on a
-- real upgraded database that already has reversal rows (proven by
-- supabase/tests/upgrade_patch_6_1_fixtures.test.sql's fixture 4), this
-- backfill UPDATE would otherwise be rejected by its own table's
-- immutability trigger. The trigger is disabled for the duration of this
-- single, deterministic, migration-authored backfill statement only, then
-- immediately re-enabled — no other write path is affected.
alter table public.sales_order_adjustment_reversals
  disable trigger sales_order_adjustment_reversals_reject_update;

update public.sales_order_adjustment_reversals
set customer_charge_reversal_amount = -customer_charge_snapshot,
    direct_cost_reversal_amount = direct_cost_snapshot,
    payment_fee_reversal_amount = payment_fee_amount_snapshot,
    gross_profit_reversal_amount = -gross_adjustment_profit_snapshot,
    net_profit_reversal_amount = -net_adjustment_profit_snapshot
where customer_charge_reversal_amount is null;

alter table public.sales_order_adjustment_reversals
  enable trigger sales_order_adjustment_reversals_reject_update;

do $$
declare
  v_backfilled_count integer;
begin
  select count(*) into v_backfilled_count from public.sales_order_adjustment_reversals;
  raise notice 'Patch 6.1 item 20: % صف/صفوف موجودة في sales_order_adjustment_reversals أُعيد احتساب أعمدة أثر العكس الصريحة لها (backfill حتمي، بلا قيم مُختلَقة)', v_backfilled_count;
end $$;

alter table public.sales_order_adjustment_reversals
  alter column customer_charge_reversal_amount set not null,
  alter column direct_cost_reversal_amount set not null,
  alter column payment_fee_reversal_amount set not null,
  alter column gross_profit_reversal_amount set not null,
  alter column net_profit_reversal_amount set not null;

comment on column public.sales_order_adjustment_reversals.customer_charge_reversal_amount is 'Patch 6.1 item 20 — signed reversal impact = -customer_charge_snapshot. Always populated.';
comment on column public.sales_order_adjustment_reversals.direct_cost_reversal_amount is 'Patch 6.1 item 20 — signed reversal impact = +direct_cost_snapshot. Always populated.';
comment on column public.sales_order_adjustment_reversals.payment_fee_reversal_amount is 'Patch 6.1 item 20 — signed reversal impact = +payment_fee_amount_snapshot. Always populated.';
comment on column public.sales_order_adjustment_reversals.gross_profit_reversal_amount is 'Patch 6.1 item 20 — signed reversal impact = -gross_adjustment_profit_snapshot. Always populated.';
comment on column public.sales_order_adjustment_reversals.net_profit_reversal_amount is 'Patch 6.1 item 20 — signed reversal impact = -net_adjustment_profit_snapshot. Original Net + this = 0.00 always. Always populated.';

-- ---------------------------------------------------------------------------
-- reverse_sales_order_adjustment() v2 — same signature/return type as 0141's
-- original; the INSERT now also populates the five impact columns above.
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
  if v_actor is null or not public.has_permission('adjustments.reverse') then
    raise exception 'ليست لديك صلاحية عكس التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  if v_reason = '' then
    raise exception 'يجب إدخال سبب عكس هذا التعديل/الخدمة' using errcode = 'P0001';
  end if;
  if p_reversal_business_date is null then
    raise exception 'تاريخ العكس (reversal_business_date) مطلوب' using errcode = 'P0001';
  end if;

  select * into v_adj from public.sales_order_adjustments where sales_order_adjustments.id = p_id for update;
  if v_adj.id is null then
    raise exception 'التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لعكس التعديل/الخدمة' using errcode = 'P0001';
  end if;
  if v_adj.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا السجل من جهة أخرى — أعد تحميل الصفحة وحاول مرة أخرى (تعارض الإصدارات)' using errcode = 'P0001';
  end if;

  if v_adj.status <> 'approved' then
    raise exception 'لا يمكن عكس إلا تعديل/خدمة معتمد' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.sales_order_adjustment_reversals r where r.sales_order_adjustment_id = p_id) then
    raise exception 'تم عكس هذا التعديل/الخدمة مسبقًا — لا يمكن عكسه أكثر من مرة' using errcode = 'P0001';
  end if;

  select * into v_order from public.sales_orders where sales_orders.id = v_adj.sales_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير مرئية لك' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_adj.processing_store_id) then
    raise exception 'المتجر المُعالِج غير مرئي لك' using errcode = 'P0001';
  end if;

  if p_reversal_business_date < v_adj.adjustment_date then
    raise exception 'تاريخ العكس لا يمكن أن يسبق تاريخ التعديل/الخدمة الأصلي (%)', v_adj.adjustment_date using errcode = 'P0001';
  end if;
  if p_reversal_business_date > v_today then
    raise exception 'تاريخ العكس لا يمكن أن يكون في المستقبل' using errcode = 'P0001';
  end if;

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

  insert into public.sales_order_adjustment_reversals (
    sales_order_adjustment_id, reversal_business_date, reason,
    customer_charge_snapshot, direct_cost_snapshot, payment_fee_amount_snapshot,
    gross_adjustment_profit_snapshot, net_adjustment_profit_snapshot,
    customer_charge_reversal_amount, direct_cost_reversal_amount, payment_fee_reversal_amount,
    gross_profit_reversal_amount, net_profit_reversal_amount,
    expected_row_version, reversed_by
  ) values (
    p_id, p_reversal_business_date, v_reason,
    v_adj.customer_charge, v_adj.direct_cost, v_adj.payment_fee_amount,
    v_adj.gross_adjustment_profit, v_adj.net_adjustment_profit,
    -v_adj.customer_charge, v_adj.direct_cost, v_adj.payment_fee_amount,
    -v_adj.gross_adjustment_profit, -v_adj.net_adjustment_profit,
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
    jsonb_build_object('reversal_id', v_reversal_id, 'reversal_business_date', p_reversal_business_date, 'net_profit_reversal_amount', -v_adj.net_adjustment_profit),
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
  'Phase 6 (§19/§20/§21) + Patch 6.1 item 20 — append-only administrative reversal. Now also populates five explicit signed impact columns (customer_charge/direct_cost/payment_fee/gross_profit/net_profit_reversal_amount) alongside the original positive snapshot. Requires adjustments.reverse. SECURITY DEFINER.';

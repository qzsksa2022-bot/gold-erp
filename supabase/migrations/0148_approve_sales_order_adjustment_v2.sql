-- ============================================================================
-- 0148: Phase 6 Integrity Patch 6.1 (5/13): approve_sales_order_adjustment()
-- v2 — independent from adjustments.manage_cost, no Net Profit leak in the
-- write response, zero-charge fee bypass, sale-date revalidation, type lock
-- ============================================================================
-- Migrations 0001-0147 are unmodified. Return shape changes (adds `status`,
-- gates net_adjustment_profit) — the 0140 original 3-argument signature's
-- RETURN TYPE is not compatible with CREATE OR REPLACE, so it is dropped
-- explicitly first.
--
-- Patch 6.1 fixes bundled here:
--   item 5 — auth now requires ONLY adjustments.approve (0133's original
--     "approve implies manage_cost" design is retired — manage_cost governs
--     PENDING cost management exclusively, via 0145, never approval power).
--     direct_cost IS NULL still hard-rejects approval with an explicit
--     message (unchanged from 0140, now the ONLY financial gate on
--     approval besides adjustments.approve itself).
--   item 6 — net_adjustment_profit in the WRITE RESPONSE is now NULL for an
--     approver who does not hold sales.view_profit (mirrors every READ RPC
--     in this project — a write response is not a profit-disclosure
--     loophole).
--   item 8 — adjustment_date is revalidated against the (possibly since-
--     changed) linked Sales Order's sale_date at approval time too, not
--     only at create/update time.
--   item 9 — a FREE record (customer_charge = 0) skips the Financial Master
--     lock + Payment Fee Version resolution entirely; payment_fee_amount is
--     forced to exactly 0.00, and every payment-related snapshot column
--     (version id, percentage/fixed, method/channel name) stays NULL,
--     matching the 0144 DB-level invariant.
--   item 14 — acquire_adjustments_lock_shared() is taken before resolving/
--     snapshotting the Adjustment Type.
-- ---------------------------------------------------------------------------
drop function if exists public.approve_sales_order_adjustment(uuid, bigint, text);

create or replace function public.approve_sales_order_adjustment(
  p_id uuid,
  p_expected_version bigint,
  p_closed_day_reason text default null
)
returns table (id uuid, adjustment_number text, row_version bigint, status text, net_adjustment_profit text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_adj record;
  v_order record;
  v_type record;
  v_payment_method record;
  v_collection_channel record;
  v_fee record;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_is_free boolean;
  v_fee_version_id uuid;
  v_fee_percentage numeric;
  v_fee_fixed numeric;
  v_fee_amount numeric;
  v_payment_method_name text;
  v_collection_channel_name text;
  v_gross numeric;
  v_net numeric;
  v_new_row_version bigint;
  v_today date := public.business_today();
  v_can_view_profit boolean;
begin
  -- 1) auth — adjustments.approve ALONE (item 5). manage_cost is no longer
  -- required here; it governs setting direct_cost while pending (0145), a
  -- fully independent concern from the authority to approve/reject.
  if v_actor is null or not public.has_permission('adjustments.approve') then
    raise exception 'ليست لديك صلاحية اعتماد التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  -- 2) lock Adjustment
  select * into v_adj from public.sales_order_adjustments where sales_order_adjustments.id = p_id for update;
  if v_adj.id is null then
    raise exception 'التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;

  -- 3) expected row_version
  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب للاعتماد' using errcode = 'P0001';
  end if;
  if v_adj.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا السجل من جهة أخرى — أعد تحميل الصفحة وحاول مرة أخرى (تعارض الإصدارات)' using errcode = 'P0001';
  end if;

  -- 4) status must be pending
  if v_adj.status <> 'pending' then
    raise exception 'لا يمكن اعتماد تعديل/خدمة إلا في حالة "قيد الانتظار"' using errcode = 'P0001';
  end if;

  -- 5) lock/validate linked Sales Order
  select * into v_order from public.sales_orders where sales_orders.id = v_adj.sales_order_id for share;
  if v_order.id is null then
    raise exception 'عملية البيع المرتبطة غير موجودة' using errcode = 'P0001';
  end if;

  -- 6) order visible to actor
  if not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير مرئية لك' using errcode = 'P0001';
  end if;

  -- 7) processing store valid — operable for the approver too
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_adj.processing_store_id) then
    raise exception 'المتجر المُعالِج غير متاح لك للعمل عليه' using errcode = 'P0001';
  end if;

  -- 8) adjustment_date logical — not future, and not before the (possibly
  -- since-changed) linked Sale's own sale_date.
  if v_adj.adjustment_date > v_today then
    raise exception 'تاريخ التعديل/الخدمة لا يمكن أن يكون في المستقبل' using errcode = 'P0001';
  end if;
  if v_adj.adjustment_date < v_order.sale_date then
    raise exception 'تاريخ التعديل/الخدمة لا يمكن أن يسبق تاريخ عملية البيع الأصلية (%)', v_order.sale_date using errcode = 'P0001';
  end if;

  -- 9) Daily Close on (processing store, adjustment_date)
  perform public.acquire_daily_close_lock_shared(v_adj.processing_store_id, v_adj.adjustment_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = v_adj.processing_store_id and dc.business_date = v_adj.adjustment_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('adjustments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن اعتماد تعديل/خدمة فيه إلا بصلاحية خاصة (adjustments.process_closed_day)', v_adj.adjustment_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لاعتماد تعديل/خدمة في يوم مقفل' using errcode = 'P0001';
    end if;
    v_used_closed_day_override := true;
  end if;

  -- 10) SHARED adjustments lock (item 14), THEN validate active Adjustment
  -- Type — the lock is held until commit, so a concurrent type write can
  -- never race this snapshot.
  perform public.acquire_adjustments_lock_shared();

  select * into v_type from public.adjustment_types where adjustment_types.id = v_adj.adjustment_type_id;
  if v_type.id is null then
    raise exception 'نوع التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if v_type.status <> 'active' then
    raise exception 'نوع التعديل/الخدمة "%" غير نشط حاليًا — لا يمكن اعتماد تعديل بنوع معطّل', v_type.name_ar using errcode = 'P0001';
  end if;

  -- 11) require direct_cost not null (unconditional — even a free service
  -- must have an explicit direct cost recorded before approval, item 9's
  -- own worked example: customer_charge=0, direct_cost=25).
  if v_adj.direct_cost is null then
    raise exception 'يجب إدخال التكلفة المباشرة قبل اعتماد هذا التعديل/الخدمة' using errcode = 'P0001';
  end if;

  v_is_free := v_adj.customer_charge = 0;

  if v_is_free then
    -- item 9 — no fee to resolve at all: no Financial Master lock, no
    -- Payment Fee Version, no payment/channel snapshot. Explicit zero, not
    -- merely "not applicable".
    v_fee_version_id := null;
    v_fee_percentage := null;
    v_fee_fixed := null;
    v_fee_amount := 0;
    v_payment_method_name := null;
    v_collection_channel_name := null;
  else
    -- 12) validate Payment Method / Collection Channel (only meaningful for
    -- a paid record — the 0144 invariant guarantees both are non-null here).
    select * into v_payment_method from public.payment_methods where payment_methods.id = v_adj.payment_method_id;
    if v_payment_method.id is null or v_payment_method.status <> 'active' then
      raise exception 'طريقة الدفع غير موجودة أو غير نشطة حاليًا' using errcode = 'P0001';
    end if;

    select * into v_collection_channel from public.collection_channels where collection_channels.id = v_adj.collection_channel_id;
    if v_collection_channel.id is null or v_collection_channel.status <> 'active' then
      raise exception 'قناة التحصيل غير موجودة أو غير نشطة حاليًا' using errcode = 'P0001';
    end if;

    -- 13) acquire required financial master shared lock, resolve fee.
    perform public.acquire_financial_master_lock_shared();
    select * into v_fee from public.payment_fee_for_method_on_date(v_adj.payment_method_id, v_adj.adjustment_date);

    v_fee_version_id := v_fee.fee_version_id;
    v_fee_percentage := v_fee.percentage_fee;
    v_fee_fixed := v_fee.fixed_fee;
    v_fee_amount := round(v_adj.customer_charge * v_fee.percentage_fee / 100 + v_fee.fixed_fee, 2);
    v_payment_method_name := v_payment_method.name_ar;
    v_collection_channel_name := v_collection_channel.name_ar;
  end if;

  -- 14) compute Gross/Net authoritatively — SAME formula regardless of
  -- free/paid (fee_amount is simply 0 for a free record).
  v_gross := v_adj.customer_charge - v_adj.direct_cost;
  v_net := v_gross - v_fee_amount;

  v_new_row_version := v_adj.row_version + 1;

  -- 15/16) snapshot all financial/master labels + mark approved
  update public.sales_order_adjustments
  set status = 'approved',
      approved_by = v_actor,
      approved_at = now(),
      adjustment_type_code_snapshot = v_type.code,
      adjustment_type_name_ar_snapshot = v_type.name_ar,
      adjustment_type_name_en_snapshot = v_type.name_en,
      payment_method_name_snapshot = v_payment_method_name,
      collection_channel_name_snapshot = v_collection_channel_name,
      payment_fee_version_id = v_fee_version_id,
      payment_fee_percentage_snapshot = v_fee_percentage,
      payment_fee_fixed_snapshot = v_fee_fixed,
      payment_fee_amount = v_fee_amount,
      gross_adjustment_profit = v_gross,
      net_adjustment_profit = v_net,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_order_adjustments.id = p_id;

  -- 17) audit — full financial detail always recorded (protected by the
  -- audit_logs RLS profit gate, 0143/0156, never by omission here).
  perform public.log_audit_event(
    'adjustment.approve', 'sales_order_adjustment', p_id,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object(
      'status', 'approved', 'customer_charge', v_adj.customer_charge, 'direct_cost', v_adj.direct_cost,
      'payment_fee_amount', v_fee_amount, 'gross_adjustment_profit', v_gross, 'net_adjustment_profit', v_net,
      'is_free_service', v_is_free, 'row_version', v_new_row_version
    )
  );

  -- 18) closed-day override audit entry, if used
  if v_used_closed_day_override then
    perform public.log_audit_event(
      'adjustment.closed_day_override', 'sales_order_adjustment', p_id, null,
      jsonb_build_object('adjustment_date', v_adj.adjustment_date, 'approved_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  -- 19) item 6 — the WRITE RESPONSE never discloses Net Profit to an
  -- approver lacking sales.view_profit.
  v_can_view_profit := public.has_permission('sales.view_profit');

  -- 20) commit (implicit — end of function, transaction managed by caller)
  id := p_id;
  adjustment_number := v_adj.adjustment_number;
  row_version := v_new_row_version;
  status := 'approved';
  net_adjustment_profit := case when v_can_view_profit then v_net::text else null end;
  return next;
end;
$$;

comment on function public.approve_sales_order_adjustment(uuid, bigint, text) is
  'Phase 6 (§17) + Patch 6.1 items 5/6/8/9/14 — full approval procedure. Requires adjustments.approve ALONE (manage_cost is independent, governs pending cost management via 0145 only). direct_cost IS NULL still hard-rejects. Recomputes payment_fee/gross/net authoritatively; a customer_charge=0 record skips fee resolution entirely (fee forced to 0.00, no payment/channel snapshot). adjustment_date is revalidated against the Sale''s sale_date. net_adjustment_profit in the response is NULL without sales.view_profit. SECURITY DEFINER.';

revoke execute on function public.approve_sales_order_adjustment(uuid, bigint, text) from public;
grant execute on function public.approve_sales_order_adjustment(uuid, bigint, text) to authenticated;

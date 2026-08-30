-- ============================================================================
-- 0165: Phase 6 Final Audit & Invariant Hotfix 6.1.2 (3/4): approve_sales_
-- order_adjustment() v4 — full approval snapshot in the audit entry
-- ============================================================================
-- Migrations 0001-0164 are unmodified (Hotfix 6.1.2 freeze rule). Same
-- 3-argument signature and return shape as 0159 — CREATE OR REPLACE in
-- place, no drop needed. IDENTICAL runtime behavior to 0159: same
-- validations, same locks, same computed values, same UPDATE, same response
-- shape. The ONLY change is the payload of the single
-- log_audit_event('adjustment.approve', ...) call.
--
-- Hotfix 6.1.2 item 4 (BLOCKER) — 0159's audit entry for adjustment.approve
-- recorded only the top-line financial totals (status, customer_charge,
-- direct_cost, payment_fee_amount, gross/net_adjustment_profit,
-- calculation_version, row_version) but NOT the historical financial/master
-- snapshots that are actually pinned onto the row at approval time
-- (adjustment type code/name, payment method, collection channel, fee
-- version/percentage/fixed). Since Master Data can be renamed later, the
-- approval audit entry is the only place that can ever prove exactly what
-- those labels were AT THE MOMENT OF APPROVAL — without it, that history is
-- lost the instant a rename happens, even though the row's own *_snapshot
-- columns still hold the frozen truth.
--
-- new_values now also includes: adjustment_type_id,
-- adjustment_type_code_snapshot, adjustment_type_name_ar_snapshot,
-- adjustment_type_name_en_snapshot (nullable), payment_method_id (nullable),
-- payment_method_name_snapshot (nullable), collection_channel_id (nullable),
-- collection_channel_name_snapshot (nullable), payment_fee_version_id
-- (nullable), payment_fee_percentage_snapshot (nullable),
-- payment_fee_fixed_snapshot (nullable), is_free_service. All values are the
-- exact same local variables already computed and committed within this
-- same transaction earlier in the function — nothing is re-resolved or
-- recomputed specifically for the audit entry. For a Free Service, every
-- payment-related snapshot field is NULL exactly as it is on the persisted
-- row itself (v_payment_method_name/v_collection_channel_name/
-- v_fee_version_id/v_fee_percentage/v_fee_fixed are already explicitly null
-- in the v_is_free branch; v_adj.payment_method_id/v_adj.collection_channel_id
-- are guaranteed null for a free record by the 0144 zero-charge invariant).
--
-- The existing sales.view_profit audit-read protection (0143/0156) is
-- entirely unchanged by this migration — this migration only changes what
-- is WRITTEN to the audit log, never who may READ it.
-- ---------------------------------------------------------------------------
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

  -- 15/16) snapshot all financial/master labels + mark approved. Hotfix
  -- 6.1.1 item 7 — calculation_version = 1 is stamped HERE, authoritatively,
  -- the ONLY write path for this column on this or any other RPC.
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
      calculation_version = 1,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_order_adjustments.id = p_id;

  -- 17) audit — Hotfix 6.1.2 item 4: the full historical financial/master
  -- snapshot pinned at approval time is now recorded, not just the top-line
  -- totals. Every value below is the exact same already-computed/committed
  -- local variable used in the UPDATE above — nothing is re-resolved or
  -- recomputed for the audit entry itself. Still protected exclusively by
  -- the existing sales.view_profit audit-read gate (0143/0156, unchanged).
  perform public.log_audit_event(
    'adjustment.approve', 'sales_order_adjustment', p_id,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object(
      'status', 'approved',
      'adjustment_type_id', v_adj.adjustment_type_id,
      'adjustment_type_code_snapshot', v_type.code,
      'adjustment_type_name_ar_snapshot', v_type.name_ar,
      'adjustment_type_name_en_snapshot', v_type.name_en,
      'payment_method_id', v_adj.payment_method_id,
      'payment_method_name_snapshot', v_payment_method_name,
      'collection_channel_id', v_adj.collection_channel_id,
      'collection_channel_name_snapshot', v_collection_channel_name,
      'payment_fee_version_id', v_fee_version_id,
      'payment_fee_percentage_snapshot', v_fee_percentage,
      'payment_fee_fixed_snapshot', v_fee_fixed,
      'customer_charge', v_adj.customer_charge,
      'direct_cost', v_adj.direct_cost,
      'payment_fee_amount', v_fee_amount,
      'gross_adjustment_profit', v_gross,
      'net_adjustment_profit', v_net,
      'calculation_version', 1,
      'row_version', v_new_row_version,
      'is_free_service', v_is_free
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
  'Phase 6 (§17) + Patch 6.1 items 5/6/8/9/14 + Hotfix 6.1.1 item 7 + Hotfix 6.1.2 item 4 — full approval procedure. Requires adjustments.approve ALONE. direct_cost IS NULL still hard-rejects. Recomputes payment_fee/gross/net authoritatively; a customer_charge=0 record skips fee resolution entirely. adjustment_date is revalidated against the Sale''s sale_date. net_adjustment_profit in the response is NULL without sales.view_profit. Stamps calculation_version=1 authoritatively (0158) — never a client input. adjustment.approve audit entry now records the full financial/master snapshot pinned at approval (type/payment method/channel/fee version snapshots), not just top-line totals — still gated for reading by sales.view_profit only. SECURITY DEFINER.';

revoke execute on function public.approve_sales_order_adjustment(uuid, bigint, text) from public;
grant execute on function public.approve_sales_order_adjustment(uuid, bigint, text) to authenticated;

-- ============================================================================
-- 0101: Final Returns Integrity Patch 4.2 (3/7): approve_sales_return()
-- ============================================================================
-- Migrations 0001-0100 are unmodified. Same signature as 0095 — ONE new
-- check added, nothing else in the body changes.
--
-- Section 1 — the actual Upgrade Safety fix: if requires_sale_refresh is
-- true (0099's backfill flags every return that was already 'pending' when
-- this patch series applied — see 0099's header comment for the exact bug
-- this closes), approval is rejected outright with a clear message, NEVER
-- silently trusting that source_sale_row_version happening to equal the
-- Sale's current row_version means the item snapshots are actually fresh.
-- refresh_pending_sales_return_from_sale() (0100) is the only way to clear
-- the flag; there is no other path to approval for a flagged return. This
-- check is independent of (and runs alongside) the pre-existing Section 4
-- row_version comparison — a return can fail either check on its own.
create or replace function public.approve_sales_return(
  p_return_id uuid,
  p_expected_version bigint,
  p_fee_reversal_override numeric default null,
  p_closed_day_reason text default null
)
returns table (id uuid, return_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old_return record;
  v_order record;
  v_payment_method record;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_returned_original numeric;
  v_recovered_cost numeric;
  v_gross_profit numeric;
  v_revenue_reversal numeric;
  v_already_reversed_fee numeric;
  v_covers_all_remaining boolean;
  v_fee_reversal numeric;
  v_net_profit_reversal_legacy numeric;
  v_net_profit_adjustment numeric;
  v_new_row_version bigint;
  v_items_audit jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لاعتماد مرتجع' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.approve') then
    raise exception 'ليست لديك صلاحية اعتماد مرتجعات' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لاعتماد المرتجع' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_fee_reversal_override, 'قيمة استرداد العمولة اليدوية');

  -- Lock order step 1: sales_returns row.
  select * into v_old_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_old_return.id is null or not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_old_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_old_return.status <> 'pending' then
    raise exception 'لا يمكن اعتماد مرتجع ليس قيد المراجعة (الحالة الحالية: %)', v_old_return.status using errcode = 'P0001';
  end if;

  if v_old_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الاعتماد.' using errcode = 'P0001';
  end if;

  -- Patch 4.2 (Section 1) — the Upgrade Safety fix: a return flagged as
  -- requiring an explicit Sale refresh can NEVER be approved on the
  -- strength of a row_version match alone (0099's header comment explains
  -- exactly why that comparison alone is not trustworthy for these rows).
  if v_old_return.requires_sale_refresh then
    raise exception 'يجب تحديث بيانات المرتجع من عملية البيع قبل اعتماده.' using errcode = 'P0001';
  end if;

  -- Lock order step 2 (Section 19): sales_orders row, BEFORE the advisory
  -- lock — matches update_sales_order()'s own order (0084) exactly, so the
  -- two functions can never deadlock against each other on the same order.
  select * into v_order from public.sales_orders so where so.id = v_old_return.sales_order_id for update;

  -- Lock order step 3: the per-order returns advisory lock.
  perform public.acquire_returns_order_lock_exclusive(v_old_return.sales_order_id);

  perform public.acquire_daily_close_lock_shared(v_old_return.processed_store_id, v_old_return.return_date);

  select exists(
    select 1 from public.daily_closings
    where store_id = v_old_return.processed_store_id and business_date = v_old_return.return_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('returns.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن اعتماد مرتجع فيه إلا بصلاحية خاصة (returns.process_closed_day)', v_old_return.return_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لاعتماد مرتجع في يوم مقفل (%)', v_old_return.return_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  if not exists (select 1 from public.sales_return_items sri where sri.sales_return_id = p_return_id and sri.status = 'active') then
    raise exception 'لا يحتوي هذا المرتجع على أي بند نشط — لا يمكن اعتماده' using errcode = 'P0001';
  end if;

  -- Lock order step 4: every referenced sales_order_items row, in a fixed
  -- (id-ascending) order — deterministic across every caller, so no two
  -- concurrent approvals on overlapping item sets can ever cross-wait.
  perform 1 from public.sales_order_items soi
  where soi.id in (select sri.sales_order_item_id from public.sales_return_items sri where sri.sales_return_id = p_return_id and sri.status = 'active')
  order by soi.id
  for update;

  -- Section 4 — the actual stale-sale guard: the Sale must not have changed
  -- since this Pending return was created (or last explicitly refreshed).
  if v_order.row_version <> v_old_return.source_sale_row_version then
    raise exception 'تم تعديل عملية البيع بعد إنشاء طلب المرتجع. حدّث بيانات المرتجع قبل اعتماده.' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.sales_return_items sri
    where sri.sales_return_id = p_return_id and sri.status = 'active'
      and not exists (
        select 1 from public.sales_order_items soi
        where soi.id = sri.sales_order_item_id and soi.sales_order_id = v_old_return.sales_order_id and soi.status = 'active'
      )
  ) then
    raise exception 'تم تعديل عملية البيع بعد إنشاء طلب المرتجع. حدّث بيانات المرتجع قبل اعتماده.' using errcode = 'P0001';
  end if;

  -- Section 5 — friendly pre-check ahead of the unique-index backstop.
  -- Reachable in practice only if the per-order advisory lock somehow did
  -- not serialize a genuine concurrent claim (defense in depth).
  if exists (
    select 1 from public.sales_return_items sri
    where sri.sales_return_id = p_return_id and sri.status = 'active'
      and exists (
        select 1 from public.sales_return_items other
        where other.sales_order_item_id = sri.sales_order_item_id
          and other.is_effective = true
          and other.sales_return_id <> p_return_id
      )
  ) then
    raise exception 'هذه القطعة مرتجعة بالفعل.' using errcode = 'P0001';
  end if;

  select coalesce(sum(sale_price_snapshot), 0), coalesce(sum(total_cost_snapshot), 0), coalesce(sum(gross_profit_snapshot), 0)
  into v_returned_original, v_recovered_cost, v_gross_profit
  from public.sales_return_items
  where sales_return_id = p_return_id and status = 'active';

  v_returned_original := round(v_returned_original, 2);
  v_recovered_cost := round(v_recovered_cost, 2);
  v_gross_profit := round(v_gross_profit, 2);

  -- Section 1 — deduction/refund-difference re-validation against the
  -- FRESHLY computed total (guards against the item set having changed via
  -- update_pending_sales_return since these business inputs were last set).
  if v_old_return.non_shipping_deduction_amount > v_returned_original then
    raise exception 'قيمة الاستقطاع (%) تتجاوز إجمالي مبلغ البيع الأصلي المحتسب حاليًا (%) — عدّل المرتجع قبل اعتماده', v_old_return.non_shipping_deduction_amount, v_returned_original using errcode = 'P0001';
  end if;

  v_revenue_reversal := v_returned_original - v_old_return.non_shipping_deduction_amount;

  -- Section 2 — the real customer_never_received enforcement, re-checked
  -- authoritatively here (also a CHECK constraint backstop, 0092).
  if v_old_return.scenario = 'customer_never_received' and v_old_return.collection_state = 'not_collected' and v_old_return.approved_refund_amount <> 0 then
    raise exception 'عندما لم يستلم العميل البضاعة ولم يتم تحصيل المبلغ الأصلي، يجب أن تكون قيمة الاسترداد المعتمد صفرًا' using errcode = 'P0001';
  end if;

  if v_old_return.approved_refund_amount <> v_revenue_reversal and (v_old_return.refund_difference_reason is null or btrim(v_old_return.refund_difference_reason) = '') then
    raise exception 'قيمة الاسترداد المعتمد (%) تختلف عن صافي عكس الإيراد المحتسب حاليًا (%) — عدّل المرتجع لإضافة سبب الفرق قبل اعتماده', v_old_return.approved_refund_amount, v_revenue_reversal using errcode = 'P0001';
  end if;

  select * into v_payment_method from public.payment_methods pm where pm.id = v_old_return.payment_method_id;

  select coalesce(sum(sr.payment_fee_reversal_amount), 0) into v_already_reversed_fee
  from public.sales_returns sr
  where sr.sales_order_id = v_old_return.sales_order_id and sr.status = 'approved' and sr.id <> p_return_id;

  -- Does approving THIS return complete full coverage of the order (every
  -- active item now covered by an EFFECTIVE claim, counting this return's
  -- own items as about to become effective)?
  select not exists (
    select 1 from public.sales_order_items soi
    where soi.sales_order_id = v_old_return.sales_order_id and soi.status = 'active'
      and not exists (
        select 1 from public.sales_return_items sri
        where sri.sales_order_item_id = soi.id and sri.status = 'active'
          and (sri.sales_return_id = p_return_id or sri.is_effective = true)
      )
  ) into v_covers_all_remaining;

  v_fee_reversal := public.compute_sales_return_fee_reversal(
    v_old_return.order_subtotal_snapshot, v_old_return.order_payment_fee_amount_snapshot,
    v_returned_original, v_payment_method.refund_fee_policy,
    v_covers_all_remaining, v_already_reversed_fee, p_fee_reversal_override
  );

  v_net_profit_reversal_legacy := v_gross_profit - v_fee_reversal;
  v_net_profit_adjustment := -v_revenue_reversal + v_recovered_cost + v_fee_reversal;
  v_new_row_version := v_old_return.row_version + 1;

  update public.sales_returns
  set status = 'approved',
      approved_at = now(),
      approved_by = v_actor,
      returned_original_sale_amount = v_returned_original,
      sales_revenue_reversal_amount = v_revenue_reversal,
      recovered_original_cost_amount = v_recovered_cost,
      net_sales_profit_adjustment = v_net_profit_adjustment,
      gross_profit_reversal_amount = v_gross_profit,
      payment_fee_reversal_amount = v_fee_reversal,
      net_profit_reversal_amount = v_net_profit_reversal_legacy,
      refund_fee_policy_snapshot = v_payment_method.refund_fee_policy,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  begin
    update public.sales_return_items
    set is_effective = true, included_in_decision = true
    where sales_return_id = p_return_id and status = 'active';
  exception when unique_violation then
    raise exception 'هذه القطعة مرتجعة بالفعل.' using errcode = 'P0001';
  end;

  select coalesce(jsonb_agg(jsonb_build_object('sales_order_item_id', sales_order_item_id, 'condition', condition)), '[]'::jsonb)
  into v_items_audit
  from public.sales_return_items where sales_return_id = p_return_id and status = 'active';

  perform public.log_audit_event(
    'return.approve', 'sales_return', p_return_id,
    jsonb_build_object('status', v_old_return.status, 'row_version', v_old_return.row_version),
    jsonb_build_object(
      'status', 'approved', 'row_version', v_new_row_version,
      'sales_order_id', v_old_return.sales_order_id, 'items', v_items_audit,
      'collection_state', v_old_return.collection_state,
      'returned_original_sale_amount', v_returned_original,
      'non_shipping_deduction_amount', v_old_return.non_shipping_deduction_amount,
      'deduction_reason', v_old_return.deduction_reason,
      'sales_revenue_reversal_amount', v_revenue_reversal,
      'approved_refund_amount', v_old_return.approved_refund_amount,
      'refund_difference_reason', v_old_return.refund_difference_reason,
      'recovered_original_cost_amount', v_recovered_cost,
      'payment_fee_reversal_amount', v_fee_reversal,
      'net_sales_profit_adjustment', v_net_profit_adjustment,
      'gross_profit_reversal_amount', v_gross_profit,
      'net_profit_reversal_amount', v_net_profit_reversal_legacy,
      'refund_fee_policy_snapshot', v_payment_method.refund_fee_policy,
      'source_sale_row_version', v_old_return.source_sale_row_version,
      'actor', v_actor, 'approved_at', now()
    )
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'return.closed_day_override', 'sales_return', p_return_id, null,
      jsonb_build_object('return_number', v_old_return.return_number, 'return_date', v_old_return.return_date, 'approved_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := p_return_id;
  return_number := v_old_return.return_number;
  return next;
end;
$$;

comment on function public.approve_sales_return(uuid, bigint, numeric, text) is
  'Patch 4.1/4.2 (Sections 1/2/4/5/6/12/17/19) — same signature as 0087/0095, body rewritten. Patch 4.2 (0101): rejects outright if requires_sale_refresh (0099) is true, BEFORE even comparing row_version — a legacy Pending return''s source_sale_row_version happening to match the Sale''s current row_version is not sufficient proof its item snapshots are fresh (see 0099''s header comment). Global safe lock order unchanged: sales_returns row -> sales_orders row FOR UPDATE -> returns advisory lock -> sales_order_items rows FOR UPDATE ORDER BY id. Computes returned_original_sale_amount/sales_revenue_reversal_amount/recovered_original_cost_amount/net_sales_profit_adjustment (Section 12). Flips is_effective=true (+included_in_decision=true) for the return''s active items. SECURITY DEFINER.';

revoke execute on function public.approve_sales_return(uuid, bigint, numeric, text) from public;
grant execute on function public.approve_sales_return(uuid, bigint, numeric, text) to authenticated;

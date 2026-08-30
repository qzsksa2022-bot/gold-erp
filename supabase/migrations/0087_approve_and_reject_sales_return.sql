-- ============================================================================
-- 0087: Phase 4 — Returns Core (6/10): approve_sales_return(),
-- reject_sales_return()
-- ============================================================================
-- Migrations 0001-0086 are unmodified.
--
-- approve_sales_return() is the ONLY place sales_returns'' reversal/refund
-- columns are ever computed and written — a return that is later reversed
-- (0088) keeps these figures permanently (reversal does not erase history,
-- see 0082's lifecycle-fields-consistent constraint). Only a 'pending'
-- return may be approved or rejected.
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
  v_payment_method record;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_return_subtotal numeric;
  v_return_gross_profit numeric;
  v_already_reversed_fee numeric;
  v_covers_all_remaining boolean;
  v_fee_reversal numeric;
  v_net_profit_reversal numeric;
  v_new_row_version bigint;
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

  -- Serializes against every other Returns-lifecycle mutation AND against
  -- update_sales_order()'s effective-return guard (0084) for this order.
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

  select coalesce(sum(sale_price_snapshot), 0), coalesce(sum(gross_profit_snapshot), 0)
  into v_return_subtotal, v_return_gross_profit
  from public.sales_return_items
  where sales_return_id = p_return_id and status = 'active';

  select * into v_payment_method from public.payment_methods pm where pm.id = v_old_return.payment_method_id;

  select coalesce(sum(sr.payment_fee_reversal_amount), 0) into v_already_reversed_fee
  from public.sales_returns sr
  where sr.sales_order_id = v_old_return.sales_order_id and sr.status = 'approved' and sr.id <> p_return_id;

  -- Does approving THIS return complete full coverage of the order (every
  -- active item of the order now covered by an effective return, counting
  -- this return's own items as covered)?
  select not exists (
    select 1 from public.sales_order_items soi
    where soi.sales_order_id = v_old_return.sales_order_id and soi.status = 'active'
      and not exists (
        select 1 from public.sales_return_items sri
        where sri.sales_order_item_id = soi.id and sri.status = 'active'
          and (
            sri.sales_return_id = p_return_id
            or sri.sales_return_id in (select sr2.id from public.sales_returns sr2 where sr2.sales_order_id = v_old_return.sales_order_id and sr2.status = 'approved')
          )
      )
  ) into v_covers_all_remaining;

  v_fee_reversal := public.compute_sales_return_fee_reversal(
    v_old_return.order_subtotal_snapshot, v_old_return.order_payment_fee_amount_snapshot,
    round(v_return_subtotal, 2), v_payment_method.refund_fee_policy,
    v_covers_all_remaining, v_already_reversed_fee, p_fee_reversal_override
  );

  v_net_profit_reversal := round(v_return_gross_profit, 2) - v_fee_reversal;
  v_new_row_version := v_old_return.row_version + 1;

  update public.sales_returns
  set status = 'approved',
      approved_at = now(),
      approved_by = v_actor,
      sales_revenue_reversal_amount = round(v_return_subtotal, 2),
      gross_profit_reversal_amount = round(v_return_gross_profit, 2),
      payment_fee_reversal_amount = v_fee_reversal,
      net_profit_reversal_amount = v_net_profit_reversal,
      approved_refund_amount = round(v_return_subtotal, 2),
      refund_fee_policy_snapshot = v_payment_method.refund_fee_policy,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  perform public.log_audit_event(
    'return.approve', 'sales_return', p_return_id,
    jsonb_build_object('status', v_old_return.status, 'row_version', v_old_return.row_version),
    jsonb_build_object(
      'status', 'approved', 'row_version', v_new_row_version,
      'sales_revenue_reversal_amount', round(v_return_subtotal, 2),
      'gross_profit_reversal_amount', round(v_return_gross_profit, 2),
      'payment_fee_reversal_amount', v_fee_reversal,
      'net_profit_reversal_amount', v_net_profit_reversal,
      'approved_refund_amount', round(v_return_subtotal, 2),
      'refund_fee_policy_snapshot', v_payment_method.refund_fee_policy
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
  'Approves a ''pending'' return — the ONLY place sales_revenue_reversal_amount/gross_profit_reversal_amount/payment_fee_reversal_amount/net_profit_reversal_amount/approved_refund_amount are ever computed and written, via compute_sales_return_fee_reversal() (0085) consuming payment_methods.refund_fee_policy read LIVE at this moment (current config, not a historical resolver — see design notes) and stored as refund_fee_policy_snapshot. Real optimistic concurrency. Requires returns.approve + processed_store_id OPERABLE scope + closed-day gating (returns.process_closed_day). Once approved, sales_return_items_order_item_active_uq (0082) exclusively claims every one of this return''s items, and update_sales_order() (0084) locks the underlying Sale to metadata-only edits. SECURITY DEFINER.';

revoke execute on function public.approve_sales_return(uuid, bigint, numeric, text) from public;
grant execute on function public.approve_sales_return(uuid, bigint, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- reject_sales_return() — terminal, non-effective outcome. Cascades a
-- soft-remove over every active item of this return in the same statement,
-- releasing the sales_return_items_order_item_active_uq claim (0082) so
-- those items become returnable again immediately. No financial columns are
-- ever written for a rejected return (they stay NULL forever — a rejection
-- never went through approval, so there is nothing to reverse).
-- ---------------------------------------------------------------------------
create or replace function public.reject_sales_return(
  p_return_id uuid,
  p_expected_version bigint,
  p_rejection_reason text
)
returns table (id uuid, return_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old_return record;
  v_new_row_version bigint;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لرفض مرتجع' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.approve') then
    raise exception 'ليست لديك صلاحية رفض مرتجعات' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لرفض المرتجع' using errcode = 'P0001';
  end if;

  if p_rejection_reason is null or btrim(p_rejection_reason) = '' then
    raise exception 'يجب إدخال سبب رفض المرتجع' using errcode = 'P0001';
  end if;

  select * into v_old_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_old_return.id is null or not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_old_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_old_return.status <> 'pending' then
    raise exception 'لا يمكن رفض مرتجع ليس قيد المراجعة (الحالة الحالية: %)', v_old_return.status using errcode = 'P0001';
  end if;

  if v_old_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الرفض.' using errcode = 'P0001';
  end if;

  perform public.acquire_returns_order_lock_exclusive(v_old_return.sales_order_id);

  update public.sales_return_items
  set status = 'removed', removed_at = now(), removed_by = v_actor
  where sales_return_id = p_return_id and status = 'active';

  v_new_row_version := v_old_return.row_version + 1;

  update public.sales_returns
  set status = 'rejected',
      rejected_at = now(),
      rejected_by = v_actor,
      rejection_reason = p_rejection_reason,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  perform public.log_audit_event(
    'return.reject', 'sales_return', p_return_id,
    jsonb_build_object('status', v_old_return.status, 'row_version', v_old_return.row_version),
    jsonb_build_object('status', 'rejected', 'row_version', v_new_row_version, 'rejection_reason', p_rejection_reason)
  );

  id := p_return_id;
  return_number := v_old_return.return_number;
  return next;
end;
$$;

comment on function public.reject_sales_return(uuid, bigint, text) is
  'Rejects a ''pending'' return — terminal, non-effective outcome. Cascades a soft-remove over every active sales_return_items row of this return in the same statement, releasing the sales_return_items_order_item_active_uq claim (0082) so those items become returnable again immediately. No financial reversal columns are ever written for a rejected return. Requires returns.approve + processed_store_id OPERABLE scope + a mandatory rejection_reason. SECURITY DEFINER.';

revoke execute on function public.reject_sales_return(uuid, bigint, text) from public;
grant execute on function public.reject_sales_return(uuid, bigint, text) to authenticated;

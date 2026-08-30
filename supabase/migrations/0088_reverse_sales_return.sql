-- ============================================================================
-- 0088: Phase 4 — Returns Core (7/10): reverse_sales_return()
-- ============================================================================
-- Migrations 0001-0087 are unmodified.
--
-- Reverses an EFFECTIVE ('approved') return — the only reachable terminal
-- transition from 'approved' (no un-reverse; 'reversed' is itself terminal,
-- enforced by sales_returns_lifecycle_fields_consistent, 0082). Cascades a
-- soft-remove over every active item, releasing the sales_return_items_
-- order_item_active_uq claim (0082) so those items become returnable again
-- and, once no OTHER effective return remains on the order, update_sales_
-- order()'s financial lock (0084) lifts automatically (it re-checks
-- sales_returns.status='approved' fresh on every call — nothing to
-- unregister here). Every reversal/refund figure computed at approval
-- (sales_revenue_reversal_amount et al.) is left permanently in place —
-- reversal does not erase history, it only stops the return being
-- effective (reversed_at marks exactly when).
--
-- Does NOT touch sales_return_refund_events — the actual-cash-refund ledger
-- is intentionally independent (see design notes' "two fully independent
-- tracked values"); if cash was already disbursed against this return
-- before it was reversed, that is a separate reconciliation action staff
-- perform explicitly via reverse_sales_return_refund_event() (0089), never
-- an automatic side effect of reversing the return itself.
create or replace function public.reverse_sales_return(
  p_return_id uuid,
  p_expected_version bigint,
  p_reversal_reason text
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
    raise exception 'يجب تسجيل الدخول للتراجع عن مرتجع' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.reverse') then
    raise exception 'ليست لديك صلاحية التراجع عن مرتجعات معتمدة' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب للتراجع عن المرتجع' using errcode = 'P0001';
  end if;

  if p_reversal_reason is null or btrim(p_reversal_reason) = '' then
    raise exception 'يجب إدخال سبب التراجع عن المرتجع' using errcode = 'P0001';
  end if;

  select * into v_old_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_old_return.id is null or not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_old_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_old_return.status <> 'approved' then
    raise exception 'لا يمكن التراجع إلا عن مرتجع معتمد (الحالة الحالية: %)', v_old_return.status using errcode = 'P0001';
  end if;

  if v_old_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل التراجع.' using errcode = 'P0001';
  end if;

  -- Serializes against every other Returns-lifecycle mutation AND against
  -- update_sales_order()'s effective-return guard (0084) for this order —
  -- so a concurrent Sales financial edit cannot race a reversal that would
  -- otherwise unlock it mid-edit.
  perform public.acquire_returns_order_lock_exclusive(v_old_return.sales_order_id);

  update public.sales_return_items
  set status = 'removed', removed_at = now(), removed_by = v_actor
  where sales_return_id = p_return_id and status = 'active';

  v_new_row_version := v_old_return.row_version + 1;

  update public.sales_returns
  set status = 'reversed',
      reversed_at = now(),
      reversed_by = v_actor,
      reversal_reason = p_reversal_reason,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  perform public.log_audit_event(
    'return.reverse', 'sales_return', p_return_id,
    jsonb_build_object(
      'status', v_old_return.status, 'row_version', v_old_return.row_version,
      'sales_revenue_reversal_amount', v_old_return.sales_revenue_reversal_amount,
      'payment_fee_reversal_amount', v_old_return.payment_fee_reversal_amount
    ),
    jsonb_build_object('status', 'reversed', 'row_version', v_new_row_version, 'reversal_reason', p_reversal_reason)
  );

  id := p_return_id;
  return_number := v_old_return.return_number;
  return next;
end;
$$;

comment on function public.reverse_sales_return(uuid, bigint, text) is
  'Reverses an ''approved'' return (the only reachable transition from approved; ''reversed'' is itself terminal). Cascades a soft-remove over every active item, releasing the double-return-prevention claim so those items become returnable again; update_sales_order()''s financial lock (0084) lifts automatically once no OTHER effective return remains on the order. Every figure computed at approval is left permanently in place — only reversed_at/reversed_by/reversal_reason and status change. Does NOT touch sales_return_refund_events (0089) — the actual-cash-refund ledger is independently managed. Requires returns.reverse + processed_store_id OPERABLE scope + a mandatory reversal_reason. SECURITY DEFINER.';

revoke execute on function public.reverse_sales_return(uuid, bigint, text) from public;
grant execute on function public.reverse_sales_return(uuid, bigint, text) to authenticated;

-- ============================================================================
-- 0089: Phase 4 — Returns Core (8/10): record_sales_return_refund(),
-- reverse_sales_return_refund_event()
-- ============================================================================
-- Migrations 0001-0088 are unmodified.
--
-- record_sales_return_refund() writes to the actual-cash-refund ledger —
-- fully independent from sales_returns.approved_refund_amount (the
-- computed TARGET fixed at approval, 0087). No amount cap is enforced
-- against approved_refund_amount here (a partial/staged refund, or a rare
-- manual over/under-payment correction, must still be recordable for audit
-- integrity) — variance between target and actual is surfaced by the read
-- RPCs (0090) for reconciliation, never silently blocked or auto-adjusted.
-- Only recordable against an 'approved' (effective) return — not pending
-- (nothing was approved yet to refund against), not rejected (never
-- approved), not reversed (no longer an active financial obligation; any
-- refund events already recorded before the reversal remain visible/
-- reversible, but no NEW one may be added afterward).
create or replace function public.record_sales_return_refund(
  p_return_id uuid,
  p_amount numeric,
  p_refund_method_id uuid,
  p_notes text default null
)
returns table (id uuid, sales_return_id uuid, amount text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_return record;
  v_method record;
  v_event_id uuid;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتسجيل استرداد نقدي' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.record_refund') then
    raise exception 'ليست لديك صلاحية تسجيل استرداد نقدي' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  select * into v_return from public.sales_returns sr where sr.id = p_return_id;

  if v_return.id is null or not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_return.status <> 'approved' then
    raise exception 'لا يمكن تسجيل استرداد نقدي إلا لمرتجع معتمد (الحالة الحالية: %)', v_return.status using errcode = 'P0001';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'قيمة الاسترداد يجب أن تكون أكبر من صفر' using errcode = 'P0001';
  end if;

  if p_refund_method_id is null then
    raise exception 'طريقة الاسترداد مطلوبة' using errcode = 'P0001';
  end if;

  select * into v_method from public.payment_methods pm where pm.id = p_refund_method_id;
  if v_method.id is null then
    raise exception 'طريقة الاسترداد غير موجودة' using errcode = 'P0001';
  end if;
  if v_method.status <> 'active' then
    raise exception 'طريقة الاسترداد "%" غير نشطة', v_method.name_ar using errcode = 'P0001';
  end if;

  insert into public.sales_return_refund_events (sales_return_id, amount, refund_method_id, notes, created_by)
  values (p_return_id, p_amount, p_refund_method_id, nullif(btrim(coalesce(p_notes, '')), ''), v_actor)
  returning sales_return_refund_events.id into v_event_id;

  perform public.log_audit_event(
    'return.refund_recorded', 'sales_return_refund_event', v_event_id, null,
    jsonb_build_object('sales_return_id', p_return_id, 'return_number', v_return.return_number, 'amount', p_amount, 'refund_method_id', p_refund_method_id)
  );

  id := v_event_id;
  sales_return_id := p_return_id;
  amount := p_amount::text;
  return next;
end;
$$;

comment on function public.record_sales_return_refund(uuid, numeric, uuid, text) is
  'Appends one entry to the actual-cash-refund ledger (sales_return_refund_events) against an ''approved'' return — fully independent from sales_returns.approved_refund_amount (the computed target). No cap enforced against the target; variance is surfaced by get_sales_return()/list_sales_returns() (0090) for reconciliation. Requires returns.record_refund + processed_store_id OPERABLE scope. SECURITY DEFINER.';

revoke execute on function public.record_sales_return_refund(uuid, numeric, uuid, text) from public;
grant execute on function public.record_sales_return_refund(uuid, numeric, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- reverse_sales_return_refund_event() — soft-void a mistaken ledger entry.
-- amount/refund_method_id/notes are never edited; only status active->
-- reversed, mirroring sales_order_items' soft-remove pattern. A reversed
-- event's amount is excluded from the Actual Refunded Total sum by
-- get_sales_return()/list_sales_returns() (0090).
-- ---------------------------------------------------------------------------
create or replace function public.reverse_sales_return_refund_event(
  p_event_id uuid,
  p_reversal_reason text
)
returns table (id uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_event record;
  v_return record;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول للتراجع عن استرداد نقدي' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.record_refund') then
    raise exception 'ليست لديك صلاحية التراجع عن استرداد نقدي' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_reversal_reason is null or btrim(p_reversal_reason) = '' then
    raise exception 'يجب إدخال سبب التراجع عن الاسترداد' using errcode = 'P0001';
  end if;

  select * into v_event from public.sales_return_refund_events e where e.id = p_event_id for update;

  if v_event.id is null then
    raise exception 'سجل الاسترداد غير موجود' using errcode = 'P0001';
  end if;

  select * into v_return from public.sales_returns sr where sr.id = v_event.sales_return_id;

  if v_return.id is null or not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_event.status <> 'active' then
    raise exception 'سجل الاسترداد هذا متراجَع عنه بالفعل' using errcode = 'P0001';
  end if;

  update public.sales_return_refund_events
  set status = 'reversed', reversed_at = now(), reversed_by = v_actor, reversal_reason = p_reversal_reason
  where sales_return_refund_events.id = p_event_id;

  perform public.log_audit_event(
    'return.refund_reversed', 'sales_return_refund_event', p_event_id,
    jsonb_build_object('status', 'active', 'amount', v_event.amount),
    jsonb_build_object('status', 'reversed', 'reversal_reason', p_reversal_reason)
  );

  id := p_event_id;
  return next;
end;
$$;

comment on function public.reverse_sales_return_refund_event(uuid, text) is
  'Soft-voids a mistaken refund-ledger entry — amount/refund_method_id/notes stay permanent; only status active->reversed is ever written (mirrors sales_order_items'' soft-remove, never a hard delete or in-place amount edit). Requires returns.record_refund + processed_store_id OPERABLE scope (resolved via the parent return) + a mandatory reversal_reason. SECURITY DEFINER.';

revoke execute on function public.reverse_sales_return_refund_event(uuid, text) from public;
grant execute on function public.reverse_sales_return_refund_event(uuid, text) to authenticated;

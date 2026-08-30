-- ============================================================================
-- 0097: Returns Integrity Patch 4.1 (6/7): record_sales_return_refund(),
-- reverse_sales_return_refund_event(), finalize_sales_return_refund()
-- ============================================================================
-- Migrations 0001-0096 are unmodified.
--
-- Section 10 — record_sales_return_refund() now rejects (never silently
-- rounds) an amount carrying more than 2 decimal places, via validate_
-- money_scale() (0092), BEFORE the value ever reaches the numeric(14,2)
-- column.
--
-- Section 9 — both functions gain an independent business date
-- (refund_business_date / reversal_business_date on sales_return_refund_
-- events itself, 0092) with its own Daily Close check, distinct from the
-- parent return's return_date and from every OTHER event's own date.
--
-- Section 13 — store scope relaxed from OPERABLE to VISIBLE on both
-- (historical/bookkeeping actions against an already-approved return).
create or replace function public.record_sales_return_refund(
  p_return_id uuid,
  p_amount numeric,
  p_refund_method_id uuid,
  p_refund_business_date date default null,
  p_notes text default null,
  p_closed_day_reason text default null
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
  v_business_date date;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
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

  if p_amount is null or p_amount <= 0 then
    raise exception 'قيمة الاسترداد يجب أن تكون أكبر من صفر' using errcode = 'P0001';
  end if;

  -- Section 10 — reject over-precision BEFORE it ever reaches the
  -- numeric(14,2) column (which would otherwise silently round it).
  perform public.validate_money_scale(p_amount, 'قيمة الاسترداد');

  v_business_date := coalesce(p_refund_business_date, public.business_today());

  if v_business_date > public.business_today() then
    raise exception 'لا يمكن أن يكون تاريخ عملية الاسترداد في المستقبل (%)', v_business_date using errcode = 'P0001';
  end if;

  select * into v_return from public.sales_returns sr where sr.id = p_return_id;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_return.status <> 'approved' then
    raise exception 'لا يمكن تسجيل استرداد نقدي إلا لمرتجع معتمد (الحالة الحالية: %)', v_return.status using errcode = 'P0001';
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

  -- Section 9 — independent business date, own Daily Close check.
  perform public.acquire_daily_close_lock_shared(v_return.processed_store_id, v_business_date);

  select exists(
    select 1 from public.daily_closings
    where store_id = v_return.processed_store_id and business_date = v_business_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('returns.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن تسجيل استرداد نقدي فيه إلا بصلاحية خاصة (returns.process_closed_day)', v_business_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتسجيل استرداد نقدي في يوم مقفل (%)', v_business_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  insert into public.sales_return_refund_events (sales_return_id, amount, refund_method_id, refund_business_date, notes, created_by)
  values (p_return_id, p_amount, p_refund_method_id, v_business_date, nullif(btrim(coalesce(p_notes, '')), ''), v_actor)
  returning sales_return_refund_events.id into v_event_id;

  perform public.log_audit_event(
    'return.refund_recorded', 'sales_return_refund_event', v_event_id, null,
    jsonb_build_object(
      'sales_return_id', p_return_id, 'return_number', v_return.return_number,
      'amount', p_amount, 'refund_method_id', p_refund_method_id, 'refund_business_date', v_business_date
    )
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'return.closed_day_override', 'sales_return_refund_event', v_event_id, null,
      jsonb_build_object('return_number', v_return.return_number, 'refund_business_date', v_business_date, 'refund_recorded_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := v_event_id;
  sales_return_id := p_return_id;
  amount := p_amount::text;
  return next;
end;
$$;

comment on function public.record_sales_return_refund(uuid, numeric, uuid, date, text, text) is
  'Patch 4.1 (Sections 9/10/13) — rejects (does not silently round) an amount with more than 2 decimal places via validate_money_scale() (0092). Gains an independent refund_business_date (defaults to business_today()) with its own Daily Close check, distinct from the return''s return_date. Store scope relaxed to VISIBLE. SECURITY DEFINER.';

drop function if exists public.record_sales_return_refund(uuid, numeric, uuid, text);

revoke execute on function public.record_sales_return_refund(uuid, numeric, uuid, date, text, text) from public;
grant execute on function public.record_sales_return_refund(uuid, numeric, uuid, date, text, text) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.reverse_sales_return_refund_event(
  p_event_id uuid,
  p_reversal_reason text,
  p_reversal_business_date date default null,
  p_closed_day_reason text default null
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
  v_business_date date;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
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

  v_business_date := coalesce(p_reversal_business_date, public.business_today());

  if v_business_date > public.business_today() then
    raise exception 'لا يمكن أن يكون تاريخ عملية التراجع في المستقبل (%)', v_business_date using errcode = 'P0001';
  end if;

  select * into v_event from public.sales_return_refund_events e where e.id = p_event_id for update;

  if v_event.id is null then
    raise exception 'سجل الاسترداد غير موجود' using errcode = 'P0001';
  end if;

  select * into v_return from public.sales_returns sr where sr.id = v_event.sales_return_id;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_event.status <> 'active' then
    raise exception 'سجل الاسترداد هذا متراجَع عنه بالفعل' using errcode = 'P0001';
  end if;

  -- Section 9 — independent business date, own Daily Close check.
  perform public.acquire_daily_close_lock_shared(v_return.processed_store_id, v_business_date);

  select exists(
    select 1 from public.daily_closings
    where store_id = v_return.processed_store_id and business_date = v_business_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('returns.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن التراجع عن استرداد نقدي فيه إلا بصلاحية خاصة (returns.process_closed_day)', v_business_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب للتراجع عن استرداد نقدي في يوم مقفل (%)', v_business_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  update public.sales_return_refund_events
  set status = 'reversed', reversed_at = now(), reversed_by = v_actor,
      reversal_reason = p_reversal_reason, reversal_business_date = v_business_date
  where sales_return_refund_events.id = p_event_id;

  perform public.log_audit_event(
    'return.refund_reversed', 'sales_return_refund_event', p_event_id,
    jsonb_build_object('status', 'active', 'amount', v_event.amount),
    jsonb_build_object('status', 'reversed', 'reversal_reason', p_reversal_reason, 'reversal_business_date', v_business_date)
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'return.closed_day_override', 'sales_return_refund_event', p_event_id, null,
      jsonb_build_object('return_number', v_return.return_number, 'reversal_business_date', v_business_date, 'refund_reversed_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := p_event_id;
  return next;
end;
$$;

comment on function public.reverse_sales_return_refund_event(uuid, text, date, text) is
  'Patch 4.1 (Sections 9/13) — gains an independent reversal_business_date (defaults to business_today()) with its own Daily Close check. Store scope relaxed to VISIBLE. amount/refund_method_id/notes stay permanent (unchanged from 0089). SECURITY DEFINER.';

drop function if exists public.reverse_sales_return_refund_event(uuid, text);

revoke execute on function public.reverse_sales_return_refund_event(uuid, text, date, text) from public;
grant execute on function public.reverse_sales_return_refund_event(uuid, text, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- finalize_sales_return_refund() — Section 11: the missing "reconciliation
-- is done" concept. Marks refund_finalized_at/by; requires refund_final_
-- variance_reason iff actual_refunded_total (sum of active refund events)
-- does not equal approved_refund_amount at this moment. A return whose
-- approved_refund_amount is 0 can be finalized with zero refund events ever
-- recorded (Section 18-K) — finalization is a distinct action from
-- recording cash, never a fake zero-value refund event.
-- ---------------------------------------------------------------------------
create or replace function public.finalize_sales_return_refund(
  p_return_id uuid,
  p_expected_version bigint,
  p_variance_reason text default null
)
returns table (id uuid, return_number text, actual_refunded_total text, refund_variance text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_return record;
  v_actual_total numeric;
  v_variance numeric;
  v_stored_reason text;
  v_new_row_version bigint;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لإغلاق تسوية الاسترداد' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.record_refund') then
    raise exception 'ليست لديك صلاحية إغلاق تسوية الاسترداد' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لإغلاق تسوية الاسترداد' using errcode = 'P0001';
  end if;

  select * into v_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_return.status not in ('approved', 'reversed') then
    raise exception 'لا يمكن إغلاق تسوية استرداد إلا لمرتجع معتمد (الحالة الحالية: %)', v_return.status using errcode = 'P0001';
  end if;

  if v_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل إغلاق التسوية.' using errcode = 'P0001';
  end if;

  if v_return.refund_finalized_at is not null then
    raise exception 'تم إغلاق تسوية استرداد هذا المرتجع بالفعل بتاريخ %', v_return.refund_finalized_at using errcode = 'P0001';
  end if;

  select coalesce(sum(e.amount), 0) into v_actual_total
  from public.sales_return_refund_events e
  where e.sales_return_id = p_return_id and e.status = 'active';

  v_variance := coalesce(v_return.approved_refund_amount, 0) - v_actual_total;

  if v_variance <> 0 and (p_variance_reason is null or btrim(p_variance_reason) = '') then
    raise exception 'إجمالي المسترد فعليًا (%) يختلف عن قيمة الاسترداد المعتمد (%) — يجب إدخال سبب الفرق لإغلاق التسوية', v_actual_total, coalesce(v_return.approved_refund_amount, 0) using errcode = 'P0001';
  end if;

  v_stored_reason := case when v_variance = 0 then null else nullif(btrim(p_variance_reason), '') end;
  v_new_row_version := v_return.row_version + 1;

  update public.sales_returns
  set refund_finalized_at = now(),
      refund_finalized_by = v_actor,
      refund_final_variance_reason = v_stored_reason,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  perform public.log_audit_event(
    'return.refund_finalized', 'sales_return', p_return_id,
    jsonb_build_object('row_version', v_return.row_version, 'refund_finalized_at', null),
    jsonb_build_object(
      'row_version', v_new_row_version, 'approved_refund_amount', v_return.approved_refund_amount,
      'actual_refunded_total', v_actual_total, 'refund_variance', v_variance,
      'refund_final_variance_reason', v_stored_reason, 'actor', v_actor, 'refund_finalized_at', now()
    )
  );

  id := p_return_id;
  return_number := v_return.return_number;
  actual_refunded_total := v_actual_total::text;
  refund_variance := v_variance::text;
  return next;
end;
$$;

comment on function public.finalize_sales_return_refund(uuid, bigint, text) is
  'Patch 4.1 (Section 11) — declares refund reconciliation for one return complete. Requires refund_final_variance_reason iff actual_refunded_total (sum of active sales_return_refund_events) does not equal approved_refund_amount at this moment; stores null otherwise. A return with approved_refund_amount=0 and zero refund events reaches final state cleanly (variance=0, no reason needed, no fake event ever inserted). Terminal per return (raises if already finalized) — nothing is ever deleted/edited, only this new marker is written. Reusable on an ''approved'' OR ''reversed'' return (reconciliation of money already moved must still be closeable after a later reversal). SECURITY DEFINER.';

revoke execute on function public.finalize_sales_return_refund(uuid, bigint, text) from public;
grant execute on function public.finalize_sales_return_refund(uuid, bigint, text) to authenticated;

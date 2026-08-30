-- ============================================================================
-- 0107: Phase 4 — Final Hotfix 4.2.1 (2/7): record_sales_return_refund(),
-- reverse_sales_return_refund_event()
-- ============================================================================
-- Migrations 0001-0106 are unmodified. Signatures unchanged from 0103
-- except record_sales_return_refund() gains ONE new optional parameter
-- (p_reference, Section 6) appended at the end (never changes an existing
-- positional argument's meaning). Section 3/5 locking order is UNCHANGED —
-- both still lock the parent sales_returns row FIRST, in the same fixed
-- position every other refund-ledger mutation uses; reverse still locks the
-- specific event row second.
--
-- Section 1/3 — the actual append-only fix. record_sales_return_refund()
-- now also sets refund_method_name_snapshot at INSERT time (the payment
-- method's current name_ar — the only point in time it is ever knowable
-- fresh, since the event row is immutable from this point on) and the new
-- optional reference. reverse_sales_return_refund_event() NO LONGER issues
-- any UPDATE against sales_return_refund_events (impossible now regardless
-- — 0106's trigger would reject it) — it INSERTs into sales_return_refund_
-- event_reversals (0106) instead. "Already reversed" is now determined by
-- existence in that table, not e.status.
create or replace function public.record_sales_return_refund(
  p_return_id uuid,
  p_amount numeric,
  p_refund_method_id uuid,
  p_refund_business_date date default null,
  p_notes text default null,
  p_closed_day_reason text default null,
  p_reference text default null
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
  v_approved_business_date date;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_event_id uuid;
  v_reference text;
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

  -- Section 5 (unchanged from 0103) — lock the PARENT return row FIRST,
  -- before reading/checking anything else derived from it.
  select * into v_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_return.status <> 'approved' then
    raise exception 'لا يمكن تسجيل استرداد نقدي إلا لمرتجع معتمد (الحالة الحالية: %)', v_return.status using errcode = 'P0001';
  end if;

  if v_return.refund_finalized_at is not null then
    raise exception 'تم إغلاق تسوية استرداد هذا المرتجع بالفعل — يجب إعادة فتح التسوية أولًا قبل تسجيل استرداد جديد' using errcode = 'P0001';
  end if;

  v_approved_business_date := (v_return.approved_at at time zone 'Asia/Riyadh')::date;

  if v_business_date < v_approved_business_date then
    raise exception 'لا يمكن أن يكون تاريخ الاسترداد (%) قبل تاريخ اعتماد المرتجع (%)', v_business_date, v_approved_business_date using errcode = 'P0001';
  end if;

  if v_business_date < v_return.return_date then
    raise exception 'لا يمكن أن يكون تاريخ الاسترداد (%) قبل تاريخ المرتجع نفسه (%)', v_business_date, v_return.return_date using errcode = 'P0001';
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

  v_reference := nullif(btrim(coalesce(p_reference, '')), '');

  -- Section 6/17 — refund_method_name_snapshot captured NOW, at the one
  -- point in time it is knowable fresh; reference (if any) permanent from
  -- here on (0106's trigger makes both physically immutable afterward).
  insert into public.sales_return_refund_events (
    sales_return_id, amount, refund_method_id, refund_business_date, notes, created_by,
    reference, refund_method_name_snapshot
  )
  values (
    p_return_id, p_amount, p_refund_method_id, v_business_date, nullif(btrim(coalesce(p_notes, '')), ''), v_actor,
    v_reference, v_method.name_ar
  )
  returning sales_return_refund_events.id into v_event_id;

  perform public.log_audit_event(
    'return.refund_recorded', 'sales_return_refund_event', v_event_id, null,
    jsonb_build_object(
      'sales_return_id', p_return_id, 'return_number', v_return.return_number,
      'amount', p_amount, 'refund_method_id', p_refund_method_id, 'refund_business_date', v_business_date,
      'reference', v_reference
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

comment on function public.record_sales_return_refund(uuid, numeric, uuid, date, text, text, text) is
  'Hotfix 4.2.1 (Sections 1/3/6/17) — gains p_reference (optional external reference — bank transfer/gateway/internal). Captures refund_method_name_snapshot at insert time (permanent thereafter — 0106''s trigger blocks any later UPDATE). Locks the parent sales_returns row FOR UPDATE first, rejects outright if refund_finalized_at is set. Unchanged from 0103 otherwise. Store scope VISIBLE. SECURITY DEFINER.';

drop function if exists public.record_sales_return_refund(uuid, numeric, uuid, date, text, text);

revoke execute on function public.record_sales_return_refund(uuid, numeric, uuid, date, text, text, text) from public;
grant execute on function public.record_sales_return_refund(uuid, numeric, uuid, date, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- reverse_sales_return_refund_event() — rewritten for append-only.
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
  v_event_return_id uuid;
  v_event record;
  v_return record;
  v_business_date date;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_reversal_id uuid;
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

  select e0.sales_return_id into v_event_return_id from public.sales_return_refund_events e0 where e0.id = p_event_id;

  if v_event_return_id is null then
    raise exception 'سجل الاسترداد غير موجود' using errcode = 'P0001';
  end if;

  -- Lock order (Section 5, unchanged): parent sales_returns row FIRST.
  select * into v_return from public.sales_returns sr where sr.id = v_event_return_id for update;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_return.refund_finalized_at is not null then
    raise exception 'تم إغلاق تسوية استرداد هذا المرتجع بالفعل — يجب إعادة فتح التسوية أولًا قبل التراجع عن سجل استرداد' using errcode = 'P0001';
  end if;

  -- Lock order step 2: the specific original event row. It will never be
  -- mutated (0106's trigger forbids it) — this lock exists purely to
  -- serialize two concurrent reversal attempts against the SAME event, so
  -- the "already reversed?" check below and the INSERT that follows are
  -- atomic together for this event specifically.
  select * into v_event from public.sales_return_refund_events e where e.id = p_event_id for update;

  if exists (select 1 from public.sales_return_refund_event_reversals rev where rev.refund_event_id = p_event_id) then
    raise exception 'سجل الاسترداد هذا متراجَع عنه بالفعل' using errcode = 'P0001';
  end if;

  -- Section 6 (unchanged) — a reversal cannot predate the very event it
  -- reverses.
  if v_business_date < v_event.refund_business_date then
    raise exception 'لا يمكن أن يكون تاريخ التراجع (%) قبل تاريخ الاسترداد الأصلي نفسه (%)', v_business_date, v_event.refund_business_date using errcode = 'P0001';
  end if;

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

  -- Section 1/3 — the real fix: INSERT only, the original event row is
  -- never touched. unique(refund_event_id) is the ultimate backstop against
  -- a double reversal even if the pre-check above somehow raced (it cannot,
  -- under the FOR UPDATE lock above, but the constraint stays authoritative
  -- regardless).
  begin
    insert into public.sales_return_refund_event_reversals (
      refund_event_id, sales_return_id, reversal_business_date, reversal_reason, reversed_by
    ) values (
      p_event_id, v_event_return_id, v_business_date, p_reversal_reason, v_actor
    )
    returning sales_return_refund_event_reversals.id into v_reversal_id;
  exception when unique_violation then
    raise exception 'سجل الاسترداد هذا متراجَع عنه بالفعل' using errcode = 'P0001';
  end;

  perform public.log_audit_event(
    'return.refund_reversed', 'sales_return_refund_event', p_event_id,
    jsonb_build_object('amount', v_event.amount),
    jsonb_build_object('reversal_reason', p_reversal_reason, 'reversal_business_date', v_business_date, 'reversal_id', v_reversal_id)
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
  'Hotfix 4.2.1 (Sections 1/3/5) — genuinely append-only now: INSERTs into sales_return_refund_event_reversals (0106) instead of UPDATEing the original event (impossible regardless — trigger-blocked). "Already reversed" is existence in that table, not a status column. Lock order unchanged: parent sales_returns row FOR UPDATE first, then the specific event row (serializes concurrent reversal attempts on the same event; unique(refund_event_id) is the authoritative backstop). Rejects outright if refund_finalized_at is set. reversal_business_date must be >= the original event''s own refund_business_date. Store scope VISIBLE. SECURITY DEFINER.';

revoke execute on function public.reverse_sales_return_refund_event(uuid, text, date, text) from public;
grant execute on function public.reverse_sales_return_refund_event(uuid, text, date, text) to authenticated;

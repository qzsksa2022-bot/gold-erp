-- ============================================================================
-- 0103: Final Returns Integrity Patch 4.2 (5/7): record_sales_return_refund(),
-- reverse_sales_return_refund_event(), finalize_sales_return_refund(),
-- reopen_sales_return_refund_reconciliation()
-- ============================================================================
-- Migrations 0001-0102 are unmodified.
--
-- Section 3 — refund-ledger mutation serialization. Previously, record_
-- sales_return_refund() and reverse_sales_return_refund_event() never
-- locked the PARENT sales_returns row at all, and neither one checked
-- refund_finalized_at — so a refund could be recorded, or an event
-- reversed, at any time even after finalize_sales_return_refund() had
-- already declared reconciliation complete, silently invalidating the
-- finalized snapshot without any new finalization ever being required. Fix:
-- ALL FOUR functions below now lock the parent sales_returns row FOR UPDATE
-- FIRST, in that fixed order (parent row, then the specific event row where
-- one is involved) — the same "lock the thing being reasoned about before
-- computing anything from it" discipline Section 19 already established
-- elsewhere in Returns — and record/reverse both reject outright once
-- refund_finalized_at is set. This closes the race the spec describes
-- exactly: two concurrent callers can no longer have one record/reverse a
-- refund event while the other is mid-finalize; whichever acquires the
-- parent row lock first fully completes (or fails) before the other even
-- reads refund_finalized_at.
--
-- Section 4 — reconciliation is no longer a one-way door. finalize_sales_
-- return_refund() now also writes an immutable historical row to sales_
-- return_refund_reconciliation_events (0099); a NEW reopen_sales_return_
-- refund_reconciliation() clears the CURRENT-state finalized_at/by/reason
-- columns (never deletes the history row that got it there) so record/
-- reverse become possible again, then finalize can run once more — writing
-- a second historical row. Every reopen itself is also recorded permanently.
--
-- Section 6 — business-date chronology. record_sales_return_refund()'s
-- refund_business_date must now be >= the Riyadh business date of the
-- return's approved_at AND >= return_date (a cash refund cannot predate the
-- approval that authorized it, nor the return itself). reverse_sales_
-- return_refund_event()'s reversal_business_date must be >= the ORIGINAL
-- event's own refund_business_date (a reversal cannot predate the event it
-- reverses). The pre-existing "not in the future" upper bound is unchanged
-- on both.
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
  v_approved_business_date date;
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

  -- Patch 4.2 (Section 3) — lock the PARENT return row FIRST, before
  -- reading/checking anything else derived from it. Every other refund-
  -- ledger mutation (this function, reverse_sales_return_refund_event(),
  -- finalize_sales_return_refund(), reopen_sales_return_refund_reconciliation())
  -- acquires this same lock in this same first position, so no two of them
  -- can ever interleave their read-then-write against one return.
  select * into v_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_return.status <> 'approved' then
    raise exception 'لا يمكن تسجيل استرداد نقدي إلا لمرتجع معتمد (الحالة الحالية: %)', v_return.status using errcode = 'P0001';
  end if;

  -- Patch 4.2 (Section 3/4) — reconciliation already finalized: reject
  -- outright, never silently invalidate a closed reconciliation snapshot.
  -- reopen_sales_return_refund_reconciliation() (below) is the only path
  -- back to a recordable state.
  if v_return.refund_finalized_at is not null then
    raise exception 'تم إغلاق تسوية استرداد هذا المرتجع بالفعل — يجب إعادة فتح التسوية أولًا قبل تسجيل استرداد جديد' using errcode = 'P0001';
  end if;

  -- Patch 4.2 (Section 6) — chronology: a cash refund cannot predate the
  -- approval that authorized it, nor the return itself.
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
  'Patch 4.1/4.2 (Sections 3/6/9/10/13) — rejects an over-precision amount (validate_money_scale). Patch 4.2 (0103): locks the parent sales_returns row FOR UPDATE first and rejects outright if refund_finalized_at is set (reopen first); refund_business_date must now be >= the Riyadh business date of approved_at AND >= return_date. Store scope VISIBLE. SECURITY DEFINER.';

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
  v_event_return_id uuid;
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

  select e0.sales_return_id into v_event_return_id from public.sales_return_refund_events e0 where e0.id = p_event_id;

  if v_event_return_id is null then
    raise exception 'سجل الاسترداد غير موجود' using errcode = 'P0001';
  end if;

  -- Patch 4.2 (Section 3) — parent row locked FIRST, in the same fixed
  -- position every refund-ledger mutation uses (see record_sales_return_
  -- refund()'s comment above).
  select * into v_return from public.sales_returns sr where sr.id = v_event_return_id for update;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_return.refund_finalized_at is not null then
    raise exception 'تم إغلاق تسوية استرداد هذا المرتجع بالفعل — يجب إعادة فتح التسوية أولًا قبل التراجع عن سجل استرداد' using errcode = 'P0001';
  end if;

  select * into v_event from public.sales_return_refund_events e where e.id = p_event_id for update;

  if v_event.status <> 'active' then
    raise exception 'سجل الاسترداد هذا متراجَع عنه بالفعل' using errcode = 'P0001';
  end if;

  -- Patch 4.2 (Section 6) — a reversal cannot predate the very event it
  -- reverses.
  if v_business_date < v_event.refund_business_date then
    raise exception 'لا يمكن أن يكون تاريخ التراجع (%) قبل تاريخ الاسترداد الأصلي نفسه (%)', v_business_date, v_event.refund_business_date using errcode = 'P0001';
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
  'Patch 4.1/4.2 (Sections 3/6/9/13) — Patch 4.2 (0103): locks the parent sales_returns row FOR UPDATE before the event row (fixed order matching every other refund-ledger mutation) and rejects outright if refund_finalized_at is set; reversal_business_date must now be >= the ORIGINAL event''s own refund_business_date. Store scope VISIBLE. amount/refund_method_id/notes stay permanent. SECURITY DEFINER.';

revoke execute on function public.reverse_sales_return_refund_event(uuid, text, date, text) from public;
grant execute on function public.reverse_sales_return_refund_event(uuid, text, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- finalize_sales_return_refund() — unchanged locking/validation from 0097
-- (already locked the parent row FOR UPDATE first); the only addition is
-- writing a permanent row to sales_return_refund_reconciliation_events
-- (0099) alongside the existing CURRENT-state column updates.
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

  -- Patch 4.2 (Section 3) — same fixed lock-order position as record_sales_
  -- return_refund()/reverse_sales_return_refund_event() above; already
  -- correct since 0097, unchanged here.
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

  -- Computed AFTER the parent-row lock is held — no refund event can be
  -- recorded/reversed concurrently between this SELECT and the UPDATE
  -- below (Section 3), so the finalized snapshot is guaranteed accurate at
  -- the instant it is written.
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

  -- Section 4 — permanent, append-only history entry for this transition.
  insert into public.sales_return_refund_reconciliation_events (
    sales_return_id, event_type, actual_refunded_total, approved_refund_amount, variance, reason, actor
  ) values (
    p_return_id, 'finalized', v_actual_total, v_return.approved_refund_amount, v_variance, v_stored_reason, v_actor
  );

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
  'Patch 4.1/4.2 (Sections 3/4/11) — declares refund reconciliation for one return complete. Locks the parent return row FOR UPDATE first (same fixed order as every other refund-ledger mutation, Section 3) — the actual_refunded_total computed here is guaranteed accurate the instant it is written, since no concurrent record/reverse can slip in under the same lock. Patch 4.2 (0103): also writes a permanent row to sales_return_refund_reconciliation_events (0099, event_type=''finalized''). Terminal until reopen_sales_return_refund_reconciliation() (below) clears refund_finalized_at — reusable any number of times after a reopen, each writing its own history row. Usable on ''approved'' OR ''reversed''. SECURITY DEFINER.';

revoke execute on function public.finalize_sales_return_refund(uuid, bigint, text) from public;
grant execute on function public.finalize_sales_return_refund(uuid, bigint, text) to authenticated;

-- ---------------------------------------------------------------------------
-- reopen_sales_return_refund_reconciliation() — Section 4, new. The
-- explicit, audited, reason-required escape hatch from a Finalized state:
-- clears the CURRENT-state refund_finalized_at/by/refund_final_variance_
-- reason columns (never touches any *_at/*_by/*_reason from approve/reject/
-- reverse, never deletes the reconciliation history row that recorded the
-- finalize being reopened) so record_sales_return_refund()/reverse_sales_
-- return_refund_event() become callable again; finalize_sales_return_
-- refund() can then run once more, writing a second history row.
-- ---------------------------------------------------------------------------
create or replace function public.reopen_sales_return_refund_reconciliation(
  p_return_id uuid,
  p_expected_version bigint,
  p_reason text
)
returns table (id uuid, return_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_return record;
  v_actual_total numeric;
  v_variance numeric;
  v_new_row_version bigint;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لإعادة فتح تسوية الاسترداد' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.record_refund') then
    raise exception 'ليست لديك صلاحية إعادة فتح تسوية الاسترداد' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لإعادة فتح التسوية' using errcode = 'P0001';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'يجب إدخال سبب إعادة فتح التسوية' using errcode = 'P0001';
  end if;

  -- Same fixed lock-order position as every other refund-ledger mutation.
  select * into v_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل إعادة فتح التسوية.' using errcode = 'P0001';
  end if;

  if v_return.refund_finalized_at is null then
    raise exception 'تسوية استرداد هذا المرتجع ليست مُغلَقة أصلًا — لا حاجة لإعادة فتحها' using errcode = 'P0001';
  end if;

  select coalesce(sum(e.amount), 0) into v_actual_total
  from public.sales_return_refund_events e
  where e.sales_return_id = p_return_id and e.status = 'active';

  v_variance := coalesce(v_return.approved_refund_amount, 0) - v_actual_total;
  v_new_row_version := v_return.row_version + 1;

  -- Section 4 — permanent history entry BEFORE clearing the current-state
  -- columns: this is the authoritative record of what was true at the
  -- moment of reopening (never erased by the UPDATE that follows).
  insert into public.sales_return_refund_reconciliation_events (
    sales_return_id, event_type, actual_refunded_total, approved_refund_amount, variance, reason, actor
  ) values (
    p_return_id, 'reopened', v_actual_total, v_return.approved_refund_amount, v_variance, p_reason, v_actor
  );

  update public.sales_returns
  set refund_finalized_at = null,
      refund_finalized_by = null,
      refund_final_variance_reason = null,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  perform public.log_audit_event(
    'return.refund_reconciliation_reopened', 'sales_return', p_return_id,
    jsonb_build_object(
      'row_version', v_return.row_version, 'refund_finalized_at', v_return.refund_finalized_at,
      'refund_final_variance_reason', v_return.refund_final_variance_reason
    ),
    jsonb_build_object(
      'row_version', v_new_row_version, 'refund_finalized_at', null,
      'actual_refunded_total_at_reopen', v_actual_total, 'approved_refund_amount_at_reopen', v_return.approved_refund_amount,
      'variance_at_reopen', v_variance, 'actor', v_actor
    ),
    p_reason
  );

  id := p_return_id;
  return_number := v_return.return_number;
  return next;
end;
$$;

comment on function public.reopen_sales_return_refund_reconciliation(uuid, bigint, text) is
  'Patch 4.2 (Section 4) — the explicit, reason-required, audited escape hatch from a Finalized refund reconciliation. Requires returns.record_refund + a non-empty reason + the current row_version. Clears ONLY sales_returns.refund_finalized_at/by/refund_final_variance_reason (never any approve/reject/reverse column); the prior finalization is never erased — a permanent row (event_type=''reopened'') is written to sales_return_refund_reconciliation_events (0099) FIRST, snapshotting actual_refunded_total/approved_refund_amount/variance at the moment of reopening. After this call, record_sales_return_refund()/reverse_sales_return_refund_event() become callable again, and finalize_sales_return_refund() can run once more, writing a second (or Nth) historical finalization row. SECURITY DEFINER.';

revoke execute on function public.reopen_sales_return_refund_reconciliation(uuid, bigint, text) from public;
grant execute on function public.reopen_sales_return_refund_reconciliation(uuid, bigint, text) to authenticated;

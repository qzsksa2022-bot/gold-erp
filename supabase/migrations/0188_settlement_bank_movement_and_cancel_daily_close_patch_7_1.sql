-- ============================================================================
-- 0188: Phase 7 — Integrity Patch 7.1 (5/N): Daily Close + business-date
-- chronology on record/reverse bank movement + cancel_settlement_batch
-- (§12), new-movement-only-on-finalized (§13).
-- ============================================================================
-- Migrations 0001-0187 are FROZEN.
--
-- 0179/0181 (frozen) had NO Daily Close handling at all and NO business-
-- date chronology beyond "reason required" — Patch 7.1 §12 requires the
-- same Daily Close discipline finalize_settlement_batch() now has (0185,
-- §11) applied to these three RPCs too, each keyed on ITS OWN effective
-- date, for every store the batch actually touches (0186's terminology:
-- the same primary+secondary store set settlement_batch_lines carries).
-- §13 additionally restricts NEW bank movements to status='finalized'
-- only — 0179 allowed both 'finalized' and 'reconciled', which let a
-- reconciled batch's actual/variance silently drift after the fact.
-- ============================================================================
create or replace function public._settlement_batch_relevant_store_ids(p_settlement_batch_id uuid)
returns table (store_id uuid)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select distinct store_id from (
    select l.primary_store_id as store_id from public.settlement_batch_lines l where l.settlement_batch_id = p_settlement_batch_id
    union
    select l.secondary_store_id as store_id from public.settlement_batch_lines l where l.settlement_batch_id = p_settlement_batch_id and l.secondary_store_id is not null
  ) x;
$$;

comment on function public._settlement_batch_relevant_store_ids(uuid) is
  'Patch 7.1 §12 — every distinct store (primary + secondary, across all lines) a finalized batch actually touches. Used to key Daily Close checks in record/reverse_settlement_bank_movement() and cancel_settlement_batch() below on the CORRECT (batch-relevant) store set, unconditionally (not actor-visibility-scoped — this is a financial-integrity check, not a read-privacy one). Internal only.';

revoke execute on function public._settlement_batch_relevant_store_ids(uuid) from public;

-- ---------------------------------------------------------------------------
-- record_settlement_bank_movement() — §12/§13. Gains ONE new trailing
-- optional parameter (p_closed_day_reason) — same established pattern as
-- 0107's p_reference addition, never changes an existing positional
-- argument's meaning.
-- ---------------------------------------------------------------------------
create or replace function public.record_settlement_bank_movement(
  p_settlement_batch_id uuid,
  p_movement_business_date date,
  p_amount numeric,
  p_bank_reference text default null,
  p_notes text default null,
  p_closed_day_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_batch record;
  v_id uuid;
  v_store record;
  v_needs_closed_override boolean := false;
begin
  if v_actor is null or not public.has_permission('settlements.record_bank_movement') then
    raise exception 'ليست لديك صلاحية تسجيل حركة بنكية على تسوية' using errcode = 'P0001';
  end if;

  if p_movement_business_date is null then
    raise exception 'تاريخ الحركة البنكية مطلوب' using errcode = 'P0001';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception 'قيمة الحركة البنكية يجب ألا تساوي صفرًا' using errcode = 'P0001';
  end if;
  perform public.validate_money_scale(p_amount, 'قيمة الحركة البنكية');

  select * into v_batch from public.settlement_batches b where b.id = p_settlement_batch_id for update;
  if v_batch.id is null then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;
  if v_batch.status = 'draft' then
    raise exception 'لا يمكن تسجيل حركة بنكية على دفعة تسوية ما زالت مسودة — اعتمدها أولًا' using errcode = 'P0001';
  end if;
  -- §13 — a NEW bank movement is only recordable on a 'finalized' batch;
  -- 'reconciled' no longer accepts new movements (reconciliation freezes
  -- the actual/variance it was computed against — a later movement would
  -- silently change them while the batch still reads as reconciled).
  if v_batch.status = 'reconciled' then
    raise exception 'دفعة التسوية هذه مُطابَقة (reconciled) بالفعل — لا يمكن تسجيل حركة بنكية جديدة عليها بعد المطابقة' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = p_settlement_batch_id) then
    raise exception 'دفعة التسوية هذه مُلغاة — لا يمكن تسجيل حركة بنكية جديدة عليها' using errcode = 'P0001';
  end if;

  -- §12 — chronology: never in the future, never before the batch's own
  -- settlement_date (a bank movement cannot settle before the batch it
  -- belongs to was itself dated).
  if p_movement_business_date > public.business_today() then
    raise exception 'تاريخ الحركة البنكية (%) لا يمكن أن يكون في المستقبل', p_movement_business_date using errcode = 'P0001';
  end if;
  if p_movement_business_date < v_batch.settlement_date then
    raise exception 'تاريخ الحركة البنكية (%) لا يمكن أن يكون قبل تاريخ التسوية نفسها (%)', p_movement_business_date, v_batch.settlement_date using errcode = 'P0001';
  end if;

  -- §12 — Daily Close, keyed on movement_business_date, for every store
  -- this batch actually touches.
  for v_store in select store_id from public._settlement_batch_relevant_store_ids(p_settlement_batch_id) loop
    perform public.acquire_daily_close_lock_shared(v_store.store_id, p_movement_business_date);
    if exists (select 1 from public.daily_closings dc where dc.store_id = v_store.store_id and dc.business_date = p_movement_business_date) then
      v_needs_closed_override := true;
    end if;
  end loop;

  if v_needs_closed_override then
    if not public.has_permission('settlements.process_closed_day') then
      raise exception 'تاريخ الحركة البنكية % يقع في يوم مقفل لأحد متاجر هذه الدفعة — يتطلب صلاحية خاصة (settlements.process_closed_day)', p_movement_business_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتسجيل حركة بنكية في يوم مقفل' using errcode = 'P0001';
    end if;
  end if;

  insert into public.settlement_bank_movement_events (
    settlement_batch_id, movement_business_date, amount, bank_reference, notes, created_by
  )
  values (
    p_settlement_batch_id, p_movement_business_date, p_amount,
    nullif(btrim(p_bank_reference), ''), nullif(btrim(p_notes), ''), v_actor
  )
  returning settlement_bank_movement_events.id into v_id;

  perform public.log_audit_event(
    'settlement.bank_movement', 'settlement_batch', p_settlement_batch_id, null,
    jsonb_build_object(
      'bank_movement_event_id', v_id, 'settlement_number', v_batch.settlement_number,
      'amount', p_amount::text, 'movement_business_date', p_movement_business_date
    )
  );

  if v_needs_closed_override then
    perform public.log_audit_event(
      'settlement.closed_day_override', 'settlement_batch', p_settlement_batch_id, null,
      jsonb_build_object('settlement_number', v_batch.settlement_number, 'movement_business_date', p_movement_business_date, 'bank_movement_event_id', v_id),
      p_closed_day_reason
    );
  end if;

  return v_id;
end;
$$;

comment on function public.record_settlement_bank_movement(uuid, date, numeric, text, text, text) is
  'Phase 7.1 patch (§12/§13) — new trailing p_closed_day_reason. Only recordable on status=''finalized'' (§13 — reconciled no longer accepts new movements). Chronology: not in the future, not before settlement_date (§12). Daily Close checked on movement_business_date for every store the batch touches; a closed day requires settlements.process_closed_day + reason. SECURITY DEFINER.';

revoke execute on function public.record_settlement_bank_movement(uuid, date, numeric, text, text, text) from public;
grant execute on function public.record_settlement_bank_movement(uuid, date, numeric, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- reverse_settlement_bank_movement() — §12. Deliberately still allowed
-- regardless of finalized/reconciled status (§13 — reversal must remain
-- possible after reconciliation, since Cancellation requires every
-- movement already reversed first). Gains p_closed_day_reason.
-- ---------------------------------------------------------------------------
create or replace function public.reverse_settlement_bank_movement(
  p_bank_movement_event_id uuid,
  p_reversal_business_date date,
  p_reason text,
  p_closed_day_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_event record;
  v_id uuid;
  v_store record;
  v_needs_closed_override boolean := false;
begin
  if v_actor is null or not public.has_permission('settlements.record_bank_movement') then
    raise exception 'ليست لديك صلاحية تسجيل حركة بنكية على تسوية' using errcode = 'P0001';
  end if;

  if p_reversal_business_date is null then
    raise exception 'تاريخ عكس الحركة البنكية مطلوب' using errcode = 'P0001';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'يجب إدخال سبب لعكس الحركة البنكية' using errcode = 'P0001';
  end if;

  select * into v_event from public.settlement_bank_movement_events e where e.id = p_bank_movement_event_id for update;
  if v_event.id is null then
    raise exception 'الحركة البنكية غير موجودة' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.settlement_bank_movement_reversals r where r.bank_movement_event_id = p_bank_movement_event_id) then
    raise exception 'هذه الحركة البنكية مُعكوسة بالفعل — لا يمكن عكسها مرة أخرى' using errcode = 'P0001';
  end if;

  -- §12 — chronology: never in the future, never before the ORIGINAL
  -- movement it reverses.
  if p_reversal_business_date > public.business_today() then
    raise exception 'تاريخ عكس الحركة البنكية (%) لا يمكن أن يكون في المستقبل', p_reversal_business_date using errcode = 'P0001';
  end if;
  if p_reversal_business_date < v_event.movement_business_date then
    raise exception 'تاريخ عكس الحركة البنكية (%) لا يمكن أن يكون قبل تاريخ الحركة الأصلية (%)', p_reversal_business_date, v_event.movement_business_date using errcode = 'P0001';
  end if;

  for v_store in select store_id from public._settlement_batch_relevant_store_ids(v_event.settlement_batch_id) loop
    perform public.acquire_daily_close_lock_shared(v_store.store_id, p_reversal_business_date);
    if exists (select 1 from public.daily_closings dc where dc.store_id = v_store.store_id and dc.business_date = p_reversal_business_date) then
      v_needs_closed_override := true;
    end if;
  end loop;

  if v_needs_closed_override then
    if not public.has_permission('settlements.process_closed_day') then
      raise exception 'تاريخ عكس الحركة % يقع في يوم مقفل لأحد متاجر هذه الدفعة — يتطلب صلاحية خاصة (settlements.process_closed_day)', p_reversal_business_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لعكس حركة بنكية في يوم مقفل' using errcode = 'P0001';
    end if;
  end if;

  insert into public.settlement_bank_movement_reversals (
    bank_movement_event_id, reversal_business_date, reason, amount_impact, created_by
  )
  values (
    p_bank_movement_event_id, p_reversal_business_date, btrim(p_reason), -v_event.amount, v_actor
  )
  returning settlement_bank_movement_reversals.id into v_id;

  perform public.log_audit_event(
    'settlement.bank_movement_reverse', 'settlement_batch', v_event.settlement_batch_id, null,
    jsonb_build_object(
      'bank_movement_event_id', p_bank_movement_event_id, 'reversal_id', v_id,
      'amount_impact', (-v_event.amount)::text
    ),
    btrim(p_reason)
  );

  if v_needs_closed_override then
    perform public.log_audit_event(
      'settlement.closed_day_override', 'settlement_batch', v_event.settlement_batch_id, null,
      jsonb_build_object('bank_movement_event_id', p_bank_movement_event_id, 'reversal_business_date', p_reversal_business_date),
      p_closed_day_reason
    );
  end if;

  return v_id;
end;
$$;

comment on function public.reverse_settlement_bank_movement(uuid, date, text, text) is
  'Phase 7.1 patch (§12) — new trailing p_closed_day_reason. Chronology: not in the future, not before the original movement (§12). Daily Close checked on reversal_business_date for every store the batch touches; a closed day requires settlements.process_closed_day + reason. Still allowed regardless of finalized/reconciled status (§13 — Cancellation depends on this remaining possible). SECURITY DEFINER.';

revoke execute on function public.reverse_settlement_bank_movement(uuid, date, text, text) from public;
grant execute on function public.reverse_settlement_bank_movement(uuid, date, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- cancel_settlement_batch() — §12. Gains p_closed_day_reason.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_settlement_batch(
  p_settlement_batch_id uuid,
  p_expected_version bigint,
  p_cancellation_business_date date,
  p_reason text,
  p_closed_day_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_batch record;
  v_unreversed_count integer;
  v_id uuid;
  v_store record;
  v_needs_closed_override boolean := false;
begin
  if v_actor is null or not public.has_permission('settlements.cancel') then
    raise exception 'ليست لديك صلاحية إلغاء دفعة تسوية' using errcode = 'P0001';
  end if;

  if p_cancellation_business_date is null then
    raise exception 'تاريخ الإلغاء مطلوب' using errcode = 'P0001';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'يجب إدخال سبب لإلغاء دفعة التسوية' using errcode = 'P0001';
  end if;

  select * into v_batch from public.settlement_batches b where b.id = p_settlement_batch_id for update;
  if v_batch.id is null then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;
  if v_batch.status = 'draft' then
    raise exception 'دفعة التسوية هذه ما زالت مسودة — لا حاجة لإلغائها، احذف المسودة (لم يُحجز لها أي مصدر بعد)' using errcode = 'P0001';
  end if;
  if p_expected_version is null or v_batch.row_version <> p_expected_version then
    raise exception 'تم تعديل دفعة التسوية هذه من قِبل مستخدم آخر — يرجى إعادة التحميل والمحاولة مجددًا' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = p_settlement_batch_id) then
    raise exception 'دفعة التسوية هذه مُلغاة بالفعل' using errcode = 'P0001';
  end if;

  select count(*) into v_unreversed_count
  from public.settlement_bank_movement_events e
  where e.settlement_batch_id = p_settlement_batch_id
    and not exists (select 1 from public.settlement_bank_movement_reversals r where r.bank_movement_event_id = e.id);

  if v_unreversed_count > 0 then
    raise exception 'يوجد % حركة/حركات بنكية على هذه الدفعة لم تُعكس بعد — اعكس كل الحركات البنكية أولًا عبر reverse_settlement_bank_movement() قبل الإلغاء', v_unreversed_count
      using errcode = 'P0001';
  end if;

  -- §12 — chronology: never in the future, never before the batch's own
  -- settlement_date.
  if p_cancellation_business_date > public.business_today() then
    raise exception 'تاريخ الإلغاء (%) لا يمكن أن يكون في المستقبل', p_cancellation_business_date using errcode = 'P0001';
  end if;
  if p_cancellation_business_date < v_batch.settlement_date then
    raise exception 'تاريخ الإلغاء (%) لا يمكن أن يكون قبل تاريخ التسوية نفسها (%)', p_cancellation_business_date, v_batch.settlement_date using errcode = 'P0001';
  end if;

  for v_store in select store_id from public._settlement_batch_relevant_store_ids(p_settlement_batch_id) loop
    perform public.acquire_daily_close_lock_shared(v_store.store_id, p_cancellation_business_date);
    if exists (select 1 from public.daily_closings dc where dc.store_id = v_store.store_id and dc.business_date = p_cancellation_business_date) then
      v_needs_closed_override := true;
    end if;
  end loop;

  if v_needs_closed_override then
    if not public.has_permission('settlements.process_closed_day') then
      raise exception 'تاريخ الإلغاء % يقع في يوم مقفل لأحد متاجر هذه الدفعة — يتطلب صلاحية خاصة (settlements.process_closed_day)', p_cancellation_business_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لإلغاء دفعة تسوية في يوم مقفل' using errcode = 'P0001';
    end if;
  end if;

  insert into public.settlement_batch_cancellations (
    settlement_batch_id, cancellation_business_date, reason, created_by
  )
  values (
    p_settlement_batch_id, p_cancellation_business_date, btrim(p_reason), v_actor
  )
  returning settlement_batch_cancellations.id into v_id;

  update public.settlement_source_claims cl
  set released_at = now(), released_by = v_actor, release_reason = btrim(p_reason)
  where cl.settlement_batch_id = p_settlement_batch_id and cl.released_at is null;

  perform public.log_audit_event(
    'settlement.cancel', 'settlement_batch', p_settlement_batch_id, null,
    jsonb_build_object(
      'settlement_number', v_batch.settlement_number, 'cancellation_id', v_id,
      'cancellation_business_date', p_cancellation_business_date
    ),
    btrim(p_reason)
  );

  if v_needs_closed_override then
    perform public.log_audit_event(
      'settlement.closed_day_override', 'settlement_batch', p_settlement_batch_id, null,
      jsonb_build_object('settlement_number', v_batch.settlement_number, 'cancellation_business_date', p_cancellation_business_date),
      p_closed_day_reason
    );
  end if;

  return v_id;
end;
$$;

comment on function public.cancel_settlement_batch(uuid, bigint, date, text, text) is
  'Phase 7.1 patch (§12) — new trailing p_closed_day_reason. Chronology: not in the future, not before settlement_date. Daily Close checked on cancellation_business_date for every store the batch touches; a closed day requires settlements.process_closed_day + reason. Otherwise unchanged from 0181 (still requires every bank movement already individually reversed). SECURITY DEFINER.';

revoke execute on function public.cancel_settlement_batch(uuid, bigint, date, text, text) from public;
grant execute on function public.cancel_settlement_batch(uuid, bigint, date, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Each RPC above gained a new trailing parameter, so (exactly like 0189's
-- update_draft_settlement_batch) CREATE OR REPLACE created a NEW overload
-- alongside the pre-0188 one rather than replacing it — Postgres
-- distinguishes functions by their full argument type LIST, and a 5-arg
-- vs 6-arg (etc.) list is a different signature. Left un-dropped, the OLD
-- overload stays callable AND stays granted to authenticated, reaching the
-- completely unpatched pre-Patch-7.1 body (no §12 date/Daily-Close checks,
-- no §13 reconciled-block) — a real, silent bypass of every fix in this
-- migration. Drop all three old-signature overloads explicitly so exactly
-- one signature of each exists.
-- ---------------------------------------------------------------------------
drop function if exists public.record_settlement_bank_movement(uuid, date, numeric, text, text);
drop function if exists public.reverse_settlement_bank_movement(uuid, date, text);
drop function if exists public.cancel_settlement_batch(uuid, bigint, date, text);

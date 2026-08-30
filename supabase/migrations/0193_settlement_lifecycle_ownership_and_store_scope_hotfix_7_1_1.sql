-- ============================================================================
-- 0193: Phase 7 — Final Integrity Hotfix 7.1.1 (2/N): create-only draft
-- ownership on write (§4), all-stores-visible store scope on every
-- lifecycle WRITE RPC (§5), reconcile response financial redaction (§7),
-- cancellation chronology after the latest bank-movement reversal (§11).
-- ============================================================================
-- Migrations 0001-0192 are FROZEN.
--
-- §4 (CRITICAL) — get_draft_settlement_batch_for_edit() (0186) already
-- restricts a create-only actor (no settlements.view) to ONLY the drafts
-- they themselves created. update_draft_settlement_batch() (0189) checked
-- ONLY settlements.create — never ownership — so a create-only actor who
-- merely LEARNS another user's draft UUID (e.g. from a shared link, a log
-- line, guessing a sequential-looking id) could blind-update it despite
-- being unable to ever READ it back through the getter. Fixed by mirroring
-- the getter's exact ownership predicate here too: an actor without
-- settlements.view may write ONLY a draft where created_by = auth.uid();
-- a settlements.view holder is unrestricted (matches both getters). Same
-- "not found" message as every other existence-masking check in this
-- module — a known-but-foreign UUID is indistinguishable from a genuinely
-- missing one.
--
-- §5 (CRITICAL) — get_settlement_batch()/list_settlement_batches() (0186)
-- already fail closed on _settlement_batch_all_stores_visible(). The four
-- WRITE RPCs below did not re-check it at all — an actor holding the
-- relevant ACTION permission (record_bank_movement/reconcile/cancel) plus a
-- known batch UUID could mutate a batch touching a store entirely outside
-- their visibility, regardless of what the UI does or does not show them.
-- Fixed by calling the SAME shared predicate (0186) immediately after
-- resolving/locking the batch row in each of the four RPCs — fail closed
-- with the batch's own "not found" message if even one line's store is
-- invisible, exactly mirroring the read-path's masking discipline.
--
-- §7 (CRITICAL) — reconcile_settlement_batch() (0180) always returned
-- actual_bank_movement/variance regardless of settlements.view_financials,
-- even though every READ path in this module (list/get_settlement_batch)
-- redacts those same figures without it — a financial-response leak via a
-- WRITE RPC's own return value. Fixed: both columns are now NULL in the
-- return row unless the actor holds settlements.view_financials (the
-- reconciliation ITSELF still succeeds — settlements.reconcile alone is
-- still sufficient to perform it, exactly as before; only the two money
-- figures in the RESPONSE are gated).
--
-- §11 — cancel_settlement_batch() (0181/0188) already required every bank
-- movement to be individually reversed and checked cancellation_business_
-- date >= settlement_date, but never checked it against the actual
-- reversal dates that MADE cancellation possible in the first place — a
-- cancellation dated BEFORE the last reversal event would misrepresent the
-- chronology (the batch reads as "fully reversed as of a date before it
-- actually was"). Fixed: when the batch has any bank movement events,
-- cancellation_business_date must also be >= the MAX(reversal_business_
-- date) across every reversal of every movement on this batch (in addition
-- to the pre-existing >= settlement_date and <= business_today() bounds).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- update_draft_settlement_batch() — §4. Same 8-arg signature as 0189.
-- ---------------------------------------------------------------------------
create or replace function public.update_draft_settlement_batch(
  p_id uuid,
  p_expected_version bigint,
  p_settlement_route_id uuid default null,
  p_settlement_date date default null,
  p_provider_statement_reference text default null,
  p_notes text default null,
  p_provider_statement_reference_provided boolean default false,
  p_notes_provided boolean default false
)
returns table (id uuid, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_row record;
  v_route record;
  v_new_route uuid;
  v_new_date date;
  v_new_reference text;
  v_new_notes text;
begin
  if not public.has_permission('settlements.create') then
    raise exception 'ليست لديك صلاحية إنشاء/تعديل تسوية' using errcode = 'P0001';
  end if;

  select * into v_row from public.settlement_batches b where b.id = p_id for update;
  if v_row.id is null then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;

  -- §4 — an actor without settlements.view (the operational/full read
  -- permission) may write ONLY a draft they themselves created — mirrors
  -- get_draft_settlement_batch_for_edit()'s (0186) own ownership predicate
  -- exactly. The SAME "not found" message as a genuinely missing row: a
  -- known UUID belonging to someone else's draft must never be
  -- distinguishable from one that does not exist at all.
  if not public.has_permission('settlements.view') and v_row.created_by is distinct from v_actor then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;

  if v_row.status <> 'draft' then
    raise exception 'لا يمكن تعديل دفعة تسوية بعد اعتمادها (finalize) — هي مقفلة الآن' using errcode = 'P0001';
  end if;
  if p_expected_version is null or v_row.row_version <> p_expected_version then
    raise exception 'تم تعديل دفعة التسوية هذه من قِبل مستخدم آخر — يرجى إعادة التحميل والمحاولة مجددًا' using errcode = 'P0001';
  end if;

  v_new_route := coalesce(p_settlement_route_id, v_row.settlement_route_id);
  v_new_date := coalesce(p_settlement_date, v_row.settlement_date);

  if v_new_date > public.business_today() then
    raise exception 'تاريخ التسوية (%) لا يمكن أن يكون في المستقبل', v_new_date using errcode = 'P0001';
  end if;

  select * into v_route from public.settlement_routes r where r.id = v_new_route;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;
  if v_route.status <> 'active' then
    raise exception 'لا يمكن استخدام مسار معطَّل لدفعة تسوية' using errcode = 'P0001';
  end if;

  v_new_reference := case
    when p_provider_statement_reference_provided then nullif(btrim(coalesce(p_provider_statement_reference, '')), '')
    else v_row.provider_statement_reference
  end;
  v_new_notes := case
    when p_notes_provided then nullif(btrim(coalesce(p_notes, '')), '')
    else v_row.notes
  end;

  update public.settlement_batches b
  set
    settlement_route_id = v_new_route,
    settlement_date = v_new_date,
    provider_statement_reference = v_new_reference,
    notes = v_new_notes,
    row_version = b.row_version + 1
  where b.id = p_id;

  perform public.log_audit_event(
    'settlement.update', 'settlement_batch', p_id,
    jsonb_build_object(
      'settlement_route_id', v_row.settlement_route_id, 'settlement_date', v_row.settlement_date,
      'provider_statement_reference', v_row.provider_statement_reference, 'notes', v_row.notes,
      'row_version', v_row.row_version
    ),
    jsonb_build_object(
      'settlement_route_id', v_new_route, 'settlement_date', v_new_date,
      'provider_statement_reference', v_new_reference, 'notes', v_new_notes,
      'row_version', v_row.row_version + 1
    )
  );

  return query select p_id, v_row.row_version + 1;
end;
$$;

comment on function public.update_draft_settlement_batch(uuid, bigint, uuid, date, text, text, boolean, boolean) is
  'Hotfix 7.1.1 (§4) — same signature as 0189. A create-only actor (no settlements.view) may now write ONLY a draft they themselves created (created_by = auth.uid()) — mirrors get_draft_settlement_batch_for_edit()''s (0186) ownership predicate, previously enforced on READ but not on WRITE. Same not-found error either way — never leaks existence. Requires settlements.create. SECURITY DEFINER.';

-- ---------------------------------------------------------------------------
-- record_settlement_bank_movement() — §5. Same 6-arg signature as 0188.
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

  -- §5 — all-stores-visible fail-closed, mirroring get_settlement_batch()
  -- (0186). Checked BEFORE any status/chronology validation, right after
  -- the row is resolved.
  if not public._settlement_batch_all_stores_visible(p_settlement_batch_id, v_actor) then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;

  if v_batch.status = 'draft' then
    raise exception 'لا يمكن تسجيل حركة بنكية على دفعة تسوية ما زالت مسودة — اعتمدها أولًا' using errcode = 'P0001';
  end if;
  if v_batch.status = 'reconciled' then
    raise exception 'دفعة التسوية هذه مُطابَقة (reconciled) بالفعل — لا يمكن تسجيل حركة بنكية جديدة عليها بعد المطابقة' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = p_settlement_batch_id) then
    raise exception 'دفعة التسوية هذه مُلغاة — لا يمكن تسجيل حركة بنكية جديدة عليها' using errcode = 'P0001';
  end if;

  if p_movement_business_date > public.business_today() then
    raise exception 'تاريخ الحركة البنكية (%) لا يمكن أن يكون في المستقبل', p_movement_business_date using errcode = 'P0001';
  end if;
  if p_movement_business_date < v_batch.settlement_date then
    raise exception 'تاريخ الحركة البنكية (%) لا يمكن أن يكون قبل تاريخ التسوية نفسها (%)', p_movement_business_date, v_batch.settlement_date using errcode = 'P0001';
  end if;

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
  'Hotfix 7.1.1 (§5) — same signature as 0188. Now fails closed with the batch''s own not-found error if _settlement_batch_all_stores_visible() (0186) is false, checked immediately after resolving the batch row. Otherwise unchanged from 0188 (§12/§13 Daily Close/chronology/finalized-only). SECURITY DEFINER.';

-- ---------------------------------------------------------------------------
-- reverse_settlement_bank_movement() — §5. Same 4-arg signature as 0188.
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

  -- §5 — all-stores-visible fail-closed, keyed on the movement's OWN batch.
  if not public._settlement_batch_all_stores_visible(v_event.settlement_batch_id, v_actor) then
    raise exception 'الحركة البنكية غير موجودة' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.settlement_bank_movement_reversals r where r.bank_movement_event_id = p_bank_movement_event_id) then
    raise exception 'هذه الحركة البنكية مُعكوسة بالفعل — لا يمكن عكسها مرة أخرى' using errcode = 'P0001';
  end if;

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
  'Hotfix 7.1.1 (§5) — same signature as 0188. Now fails closed (with the SAME not-found message the movement-not-found path uses) if _settlement_batch_all_stores_visible() is false for the movement''s own batch. Otherwise unchanged from 0188. SECURITY DEFINER.';

-- ---------------------------------------------------------------------------
-- cancel_settlement_batch() — §5/§11. Same 5-arg signature as 0188.
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
  v_max_reversal_date date;
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

  -- §5 — all-stores-visible fail-closed.
  if not public._settlement_batch_all_stores_visible(p_settlement_batch_id, v_actor) then
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

  if p_cancellation_business_date > public.business_today() then
    raise exception 'تاريخ الإلغاء (%) لا يمكن أن يكون في المستقبل', p_cancellation_business_date using errcode = 'P0001';
  end if;
  if p_cancellation_business_date < v_batch.settlement_date then
    raise exception 'تاريخ الإلغاء (%) لا يمكن أن يكون قبل تاريخ التسوية نفسها (%)', p_cancellation_business_date, v_batch.settlement_date using errcode = 'P0001';
  end if;

  -- §11 — cancellation must also come at/after the LATEST reversal event
  -- that actually made cancellation possible (every movement is already
  -- individually reversed, per the check above) — never a cancellation
  -- date that predates the reversal chronology it depends on.
  select max(r.reversal_business_date) into v_max_reversal_date
  from public.settlement_bank_movement_reversals r
  join public.settlement_bank_movement_events e on e.id = r.bank_movement_event_id
  where e.settlement_batch_id = p_settlement_batch_id;

  if v_max_reversal_date is not null and p_cancellation_business_date < v_max_reversal_date then
    raise exception 'تاريخ الإلغاء (%) لا يمكن أن يكون قبل تاريخ آخر عكس حركة بنكية على هذه الدفعة (%)', p_cancellation_business_date, v_max_reversal_date using errcode = 'P0001';
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
  'Hotfix 7.1.1 (§5/§11) — same signature as 0188. Fails closed on _settlement_batch_all_stores_visible() (§5). cancellation_business_date must now also be >= MAX(reversal_business_date) across every reversal on this batch''s movements (§11), in addition to the pre-existing >= settlement_date/<= business_today() bounds. Otherwise unchanged from 0188. SECURITY DEFINER.';

-- ---------------------------------------------------------------------------
-- reconcile_settlement_batch() — §5/§7. Same 3-arg signature as 0180.
-- ---------------------------------------------------------------------------
create or replace function public.reconcile_settlement_batch(
  p_settlement_batch_id uuid,
  p_expected_version bigint,
  p_variance_reason text default null
)
returns table (id uuid, row_version bigint, actual_bank_movement text, variance text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_batch record;
  v_actual numeric;
  v_variance numeric;
  v_can_view_financials boolean;
begin
  if v_actor is null or not public.has_permission('settlements.reconcile') then
    raise exception 'ليست لديك صلاحية مطابقة دفعة تسوية' using errcode = 'P0001';
  end if;
  v_can_view_financials := public.has_permission('settlements.view_financials');

  select * into v_batch from public.settlement_batches b where b.id = p_settlement_batch_id for update;
  if v_batch.id is null then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;

  -- §5 — all-stores-visible fail-closed.
  if not public._settlement_batch_all_stores_visible(p_settlement_batch_id, v_actor) then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;

  if v_batch.status = 'draft' then
    raise exception 'لا يمكن مطابقة دفعة تسوية ما زالت مسودة — اعتمدها أولًا' using errcode = 'P0001';
  end if;
  if v_batch.status = 'reconciled' then
    raise exception 'دفعة التسوية هذه مُطابَقة بالفعل' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = p_settlement_batch_id) then
    raise exception 'دفعة التسوية هذه مُلغاة — لا يمكن مطابقتها' using errcode = 'P0001';
  end if;
  if p_expected_version is null or v_batch.row_version <> p_expected_version then
    raise exception 'تم تعديل دفعة التسوية هذه من قِبل مستخدم آخر — يرجى إعادة التحميل والمحاولة مجددًا' using errcode = 'P0001';
  end if;

  select
    coalesce((select sum(e.amount) from public.settlement_bank_movement_events e where e.settlement_batch_id = p_settlement_batch_id), 0)
    + coalesce((
        select sum(r.amount_impact)
        from public.settlement_bank_movement_reversals r
        join public.settlement_bank_movement_events e2 on e2.id = r.bank_movement_event_id
        where e2.settlement_batch_id = p_settlement_batch_id
      ), 0)
  into v_actual;

  v_variance := v_actual - coalesce(v_batch.expected_bank_settlement, 0);

  if v_variance <> 0 then
    if not public.has_permission('settlements.reconcile_variance') then
      raise exception 'يوجد فرق مطابقة (%) — يتطلب صلاحية خاصة (settlements.reconcile_variance)', v_variance using errcode = 'P0001';
    end if;
    if p_variance_reason is null or btrim(p_variance_reason) = '' then
      raise exception 'يجب إدخال سبب لفرق المطابقة قبل اعتماد المطابقة' using errcode = 'P0001';
    end if;
  end if;

  update public.settlement_batches b
  set
    status = 'reconciled',
    reconciled_at = now(),
    reconciled_by = v_actor,
    variance_reason = case when v_variance <> 0 then btrim(p_variance_reason) else null end,
    row_version = b.row_version + 1
  where b.id = p_settlement_batch_id;

  perform public.log_audit_event(
    'settlement.reconcile', 'settlement_batch', p_settlement_batch_id, null,
    jsonb_build_object(
      'settlement_number', v_batch.settlement_number, 'actual_bank_movement', v_actual::text,
      'expected_bank_settlement', coalesce(v_batch.expected_bank_settlement, 0)::text, 'variance', v_variance::text
    ),
    case when v_variance <> 0 then btrim(p_variance_reason) else null end
  );

  return query select
    p_settlement_batch_id,
    v_batch.row_version + 1,
    case when v_can_view_financials then v_actual::text end,
    case when v_can_view_financials then v_variance::text end;
end;
$$;

comment on function public.reconcile_settlement_batch(uuid, bigint, text) is
  'Hotfix 7.1.1 (§5/§7) — same signature as 0180. Fails closed on _settlement_batch_all_stores_visible() (§5). actual_bank_movement/variance in the RETURN row are now NULL unless the actor holds settlements.view_financials (§7) — the reconciliation itself still only requires settlements.reconcile (+ settlements.reconcile_variance for a nonzero variance), only the two money figures in the RESPONSE are redacted. Otherwise unchanged from 0180. SECURITY DEFINER.';

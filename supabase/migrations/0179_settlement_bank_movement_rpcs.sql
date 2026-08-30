-- ============================================================================
-- 0179: Phase 7 — Settlements Core (13/N): record_settlement_bank_movement()
-- + reverse_settlement_bank_movement()
-- ============================================================================
-- Migrations 0001-0178 are unmodified.
--
-- item 29/30 — actual bank/carrier movement against a FINALIZED batch is an
-- append-only signed ledger (settlement_bank_movement_events, 0174), never a
-- directly-editable column. record_settlement_bank_movement() is the sole
-- writer of that ledger; reverse_settlement_bank_movement() is the sole
-- writer of settlement_bank_movement_reversals (max ONE reversal per event,
-- enforced by the table's own UNIQUE constraint — layer 2 of this pair's
-- double-reversal safety net, mirroring finalize_settlement_batch's
-- claim-uniqueness pattern exactly: a pre-check for a clean error message,
-- the UNIQUE constraint itself as the real race guard).
--
-- Movements are recordable against a batch in EITHER 'finalized' or
-- 'reconciled' status (item 31/32 — reconciliation does not freeze the bank
-- ledger; a correction can still arrive after reconciliation, which is
-- exactly why 'actual'/'variance' are computed live rather than stored,
-- 0172's header) — but NEVER against a 'draft' batch (nothing to settle
-- against yet) NOR against a cancelled batch (item 33/34 — cancellation
-- requires every prior movement already reversed to net zero; recording a
-- NEW movement against an already-cancelled batch would reopen exactly what
-- cancellation closed out).
-- ---------------------------------------------------------------------------
create or replace function public.record_settlement_bank_movement(
  p_settlement_batch_id uuid,
  p_movement_business_date date,
  p_amount numeric,
  p_bank_reference text default null,
  p_notes text default null
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
  if exists (select 1 from public.settlement_batch_cancellations c where c.settlement_batch_id = p_settlement_batch_id) then
    raise exception 'دفعة التسوية هذه مُلغاة — لا يمكن تسجيل حركة بنكية جديدة عليها' using errcode = 'P0001';
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

  return v_id;
end;
$$;

comment on function public.record_settlement_bank_movement(uuid, date, numeric, text, text) is
  'Phase 7 (item 29) — appends one signed actual-bank-movement event against a finalized/reconciled settlement batch. Positive = deposit/remittance received; negative = debit/withdrawal — never assumed always-positive. Requires settlements.record_bank_movement. SECURITY DEFINER.';

revoke execute on function public.record_settlement_bank_movement(uuid, date, numeric, text, text) from public;
grant execute on function public.record_settlement_bank_movement(uuid, date, numeric, text, text) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.reverse_settlement_bank_movement(
  p_bank_movement_event_id uuid,
  p_reversal_business_date date,
  p_reason text
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

  -- Pre-check (clean error message) — the REAL race guard is the UNIQUE
  -- constraint on settlement_bank_movement_reversals.bank_movement_event_id
  -- (0174), which raises unique_violation and aborts the whole transaction
  -- if a concurrent reversal beat this one to it, exactly mirroring
  -- finalize_settlement_batch's claim-uniqueness double-layer pattern.
  if exists (select 1 from public.settlement_bank_movement_reversals r where r.bank_movement_event_id = p_bank_movement_event_id) then
    raise exception 'هذه الحركة البنكية مُعكوسة بالفعل — لا يمكن عكسها مرة أخرى' using errcode = 'P0001';
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

  return v_id;
end;
$$;

comment on function public.reverse_settlement_bank_movement(uuid, date, text) is
  'Phase 7 (item 30) — records the ONE-AND-ONLY-EVER reversal of a bank movement event (amount_impact = -original amount, computed authoritatively here, never client-suppliable). Requires settlements.record_bank_movement + a mandatory non-blank reason. SECURITY DEFINER.';

revoke execute on function public.reverse_settlement_bank_movement(uuid, date, text) from public;
grant execute on function public.reverse_settlement_bank_movement(uuid, date, text) to authenticated;

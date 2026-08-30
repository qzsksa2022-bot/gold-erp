-- ============================================================================
-- 0181: Phase 7 — Settlements Core (15/N): cancel_settlement_batch()
-- ============================================================================
-- Migrations 0001-0180 are unmodified.
--
-- item 33/34 — cancellation is a SEPARATE append-only event
-- (settlement_batch_cancellations, 0175). It NEVER touches settlement_
-- batches/settlement_batch_lines/reconciliation history — those stay
-- exactly as they were, permanently. Only TWO things happen:
--   1) one settlement_batch_cancellations row is inserted (at most one per
--      batch, enforced by that table's own UNIQUE settlement_batch_id).
--   2) every one of the batch's currently-active settlement_source_claims
--      rows is RELEASED (released_at/by/reason set — the one sanctioned
--      in-place UPDATE in this whole module, 0173's own documented
--      exception) so those source events become claimable again by a
--      future batch.
--
-- Precondition (item 33, "بعد التأكد أن كل الحركات البنكية المرتبطة عُكست
-- بالكامل"): every settlement_bank_movement_events row belonging to this
-- batch must ALREADY have its own reversal — checked per-event, not merely
-- "net sums to zero" (two coincidentally-offsetting but individually
-- unreversed movements would not satisfy "fully reversed").
-- ---------------------------------------------------------------------------
create or replace function public.cancel_settlement_batch(
  p_settlement_batch_id uuid,
  p_expected_version bigint,
  p_cancellation_business_date date,
  p_reason text
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

  -- Pre-check (clean error) — the REAL race guard against a double
  -- cancellation is settlement_batch_cancellations.settlement_batch_id's
  -- own UNIQUE constraint (0175), which raises unique_violation and aborts
  -- the whole transaction on the INSERT below if a concurrent cancellation
  -- beat this one to it.
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

  return v_id;
end;
$$;

comment on function public.cancel_settlement_batch(uuid, bigint, date, text) is
  'Phase 7 (item 33/34) — appends a settlement_batch_cancellations row (at most one ever, per-batch UNIQUE) and releases every active claim the batch holds. NEVER touches settlement_batches/settlement_batch_lines/reconciliation history. Requires every bank movement on the batch to already be individually reversed. Requires settlements.cancel + a mandatory reason. SECURITY DEFINER.';

revoke execute on function public.cancel_settlement_batch(uuid, bigint, date, text) from public;
grant execute on function public.cancel_settlement_batch(uuid, bigint, date, text) to authenticated;

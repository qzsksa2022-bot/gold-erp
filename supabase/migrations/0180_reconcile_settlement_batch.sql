-- ============================================================================
-- 0180: Phase 7 — Settlements Core (14/N): reconcile_settlement_batch()
-- ============================================================================
-- Migrations 0001-0179 are unmodified.
--
-- item 31/32 — actual/variance are NEVER stored columns (0172's header) —
-- computed HERE, live, from the append-only settlement_bank_movement_events/
-- _reversals ledger (0174), at the moment of reconciliation:
--   actual = sum(events.amount) + sum(reversals.amount_impact)
--   variance = actual - settlement_batches.expected_bank_settlement
--
-- Zero-variance path (item 32) — any actor holding settlements.reconcile
-- alone may reconcile directly, no reason required.
-- Nonzero-variance path — requires the STRICTER settlements.reconcile_
-- variance permission (the accountant financial-controller key, 0167) AND a
-- mandatory non-blank p_variance_reason — mirrors every other "exception
-- requires elevated permission + mandatory reason" pattern in this project
-- (batch fee override here, closed-day overrides everywhere else).
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
begin
  if v_actor is null or not public.has_permission('settlements.reconcile') then
    raise exception 'ليست لديك صلاحية مطابقة دفعة تسوية' using errcode = 'P0001';
  end if;

  select * into v_batch from public.settlement_batches b where b.id = p_settlement_batch_id for update;
  if v_batch.id is null then
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

  return query select p_settlement_batch_id, v_batch.row_version + 1, v_actual::text, v_variance::text;
end;
$$;

comment on function public.reconcile_settlement_batch(uuid, bigint, text) is
  'Phase 7 (item 31/32) — computes actual/variance LIVE from the bank-movement ledger (never stored columns) and transitions finalized -> reconciled in place. Zero variance needs only settlements.reconcile; nonzero variance needs settlements.reconcile_variance + a mandatory reason. SECURITY DEFINER.';

revoke execute on function public.reconcile_settlement_batch(uuid, bigint, text) from public;
grant execute on function public.reconcile_settlement_batch(uuid, bigint, text) to authenticated;

-- ============================================================================
-- Integration test: Phase 7 Integrity Patch 7.1 upgrade path (0183->latest,
-- §34 item C) — proves REAL pre-existing Phase 7 Settlements data (draft
-- batch, finalized batch, reconciled batch, cancelled batch, bank
-- movements, reversals, claimed sources, route fee versions), all created
-- under the OLD (0169-0183) RPC/schema contracts, is byte-identical after
-- 0184-0191 land on top — no data loss, no silent migration-time mutation —
-- and that the NEW (0191) get_settlement_batch()/list_settlement_batches()
-- still read it back correctly.
-- ============================================================================
-- This file does NOT build the database itself and does NOT create any of
-- the Settlements fixture data — it only ASSERTS against a database that
-- was already built the way a real production upgrade would experience it:
--
--   1. Fresh DB, migrations 0001-0183 applied (the ORIGINAL Phase 7
--      Settlements Core delivery's end state, before Patch 7.1 exists).
--   2. The REAL supabase/seed.sql applied.
--   3. supabase/tests/fixtures/phase7_1_upgrade_pre_fixture.sql applied — a
--      SEPARATE psql invocation, COMMITTED (not rolled back) — builds a
--      route + fee version, a draft batch, a finalized batch (claiming an
--      OLD 'return_refund'-kind source), a reconciled batch, and a
--      cancelled batch (with a bank movement + its reversal), ALL via the
--      OLD (0169-0183) RPCs, recording every id/number/known-figure PLUS a
--      to_jsonb(row) snapshot of every row of interest into the PERMANENT
--      public.p71u_scratch table.
--   4. Migrations 0184 through 0191 (Patch 7.1) applied on top — in a
--      SEPARATE psql invocation, exactly like a production upgrade would.
--
-- See scripts/run_upgrade_test_phase7_1_settlements.sh for the orchestration
-- that builds exactly this sequence, then runs this file.
--
-- Proves:
--   (A) Every one of the 7 snapshotted rows (settlement_routes,
--       settlement_route_fee_versions, settlement_batches x4, settlement_
--       batch_lines x3, settlement_bank_movement_events x2, settlement_
--       bank_movement_reversals x1, settlement_batch_cancellations x1,
--       settlement_source_claims x1) is BYTE-IDENTICAL (to_jsonb(row)::text
--       equality, not merely "still exists"/count-unchanged) pre- vs
--       post-migration.
--   (B) get_settlement_batch() (0191) on the FINALIZED batch still displays
--       its OLD 'return_refund'-kind line correctly (source_number/gross/
--       fee/expected all correct), and its original_* figures match the
--       fixture's own known amounts exactly.
--   (C) get_settlement_batch() (0191) on the RECONCILED batch shows
--       effective_* == original_* (not cancelled) with zero variance.
--   (D) get_settlement_batch() (0191) on the CANCELLED batch shows
--       original_*/historical_* UNCHANGED (the permanent historical fact)
--       while effective_expected_settlement_contribution/effective_actual_
--       settlement_contribution/effective_variance_contribution are ALL
--       exactly 0.00 (§26 — cancellation zeroes only the forward-looking
--       "effective" figures, never the historical ones).
--   (E) list_settlement_batches() (0191) agrees with get_settlement_batch()
--       on the same original_*/effective_* figures + source_count for every
--       one of the 4 batches, and p_effective_status filtering correctly
--       finds the cancelled batch under 'cancelled' (not 'reconciled').
--   (F) Final unconditional cleanup: drop the scratch table.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- (A) Byte-identical row snapshots — re-snapshot the SAME rows the SAME way
-- (to_jsonb(row)::text) as postgres/superuser (these 7 tables carry zero
-- SELECT RLS policies for `authenticated`, item 41) and assert textual
-- equality against what the pre-fixture recorded BEFORE 0184-0191 ran.
-- ---------------------------------------------------------------------------
do $$
declare
  v_before text; v_after text;
begin
  -- route
  select value into v_before from public.p71u_scratch where label = 'route_row_json';
  select to_jsonb(r)::text into v_after from public.settlement_routes r where r.id = (select value::uuid from public.p71u_scratch where label = 'route_id');
  assert v_before = v_after, format('BUG (A): settlement_routes row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  -- fee version
  select value into v_before from public.p71u_scratch where label = 'fee_version_row_json';
  select to_jsonb(v)::text into v_after from public.settlement_route_fee_versions v where v.id = (select value::uuid from public.p71u_scratch where label = 'fee_version_id');
  assert v_before = v_after, format('BUG (A): settlement_route_fee_versions row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  -- draft batch
  select value into v_before from public.p71u_scratch where label = 'batch_draft_row_json';
  select to_jsonb(b)::text into v_after from public.settlement_batches b where b.id = (select value::uuid from public.p71u_scratch where label = 'batch_draft_id');
  assert v_before = v_after, format('BUG (A): draft settlement_batches row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  -- finalized batch + its line + its claim
  select value into v_before from public.p71u_scratch where label = 'batch_finalized_row_json';
  select to_jsonb(b)::text into v_after from public.settlement_batches b where b.id = (select value::uuid from public.p71u_scratch where label = 'batch_finalized_id');
  assert v_before = v_after, format('BUG (A): finalized settlement_batches row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.p71u_scratch where label = 'batch_finalized_line_row_json';
  select to_jsonb(l)::text into v_after from public.settlement_batch_lines l where l.settlement_batch_id = (select value::uuid from public.p71u_scratch where label = 'batch_finalized_id');
  assert v_before = v_after, format('BUG (A): finalized batch''s settlement_batch_lines (return_refund-kind) row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.p71u_scratch where label = 'batch_finalized_claim_row_json';
  select to_jsonb(c)::text into v_after from public.settlement_source_claims c where c.settlement_batch_id = (select value::uuid from public.p71u_scratch where label = 'batch_finalized_id');
  assert v_before = v_after, format('BUG (A): finalized batch''s settlement_source_claims row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  -- reconciled batch + its line + its bank movement
  select value into v_before from public.p71u_scratch where label = 'batch_reconciled_row_json';
  select to_jsonb(b)::text into v_after from public.settlement_batches b where b.id = (select value::uuid from public.p71u_scratch where label = 'batch_reconciled_id');
  assert v_before = v_after, format('BUG (A): reconciled settlement_batches row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.p71u_scratch where label = 'batch_reconciled_line_row_json';
  select to_jsonb(l)::text into v_after from public.settlement_batch_lines l where l.settlement_batch_id = (select value::uuid from public.p71u_scratch where label = 'batch_reconciled_id');
  assert v_before = v_after, format('BUG (A): reconciled batch''s settlement_batch_lines row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.p71u_scratch where label = 'move_reconciled_row_json';
  select to_jsonb(e)::text into v_after from public.settlement_bank_movement_events e where e.id = (select value::uuid from public.p71u_scratch where label = 'move_reconciled_id');
  assert v_before = v_after, format('BUG (A): reconciled batch''s settlement_bank_movement_events row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  -- cancelled batch + its line + its movement + its reversal + its cancellation
  select value into v_before from public.p71u_scratch where label = 'batch_cancelled_row_json';
  select to_jsonb(b)::text into v_after from public.settlement_batches b where b.id = (select value::uuid from public.p71u_scratch where label = 'batch_cancelled_id');
  assert v_before = v_after, format('BUG (A): cancelled settlement_batches row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.p71u_scratch where label = 'batch_cancelled_line_row_json';
  select to_jsonb(l)::text into v_after from public.settlement_batch_lines l where l.settlement_batch_id = (select value::uuid from public.p71u_scratch where label = 'batch_cancelled_id');
  assert v_before = v_after, format('BUG (A): cancelled batch''s settlement_batch_lines row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.p71u_scratch where label = 'move_cancelled_row_json';
  select to_jsonb(e)::text into v_after from public.settlement_bank_movement_events e where e.id = (select value::uuid from public.p71u_scratch where label = 'move_cancelled_id');
  assert v_before = v_after, format('BUG (A): cancelled batch''s settlement_bank_movement_events row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.p71u_scratch where label = 'reversal_cancelled_row_json';
  select to_jsonb(rv)::text into v_after from public.settlement_bank_movement_reversals rv where rv.id = (select value::uuid from public.p71u_scratch where label = 'reversal_cancelled_id');
  assert v_before = v_after, format('BUG (A): settlement_bank_movement_reversals row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.p71u_scratch where label = 'cancellation_row_json';
  select to_jsonb(cx)::text into v_after from public.settlement_batch_cancellations cx where cx.id = (select value::uuid from public.p71u_scratch where label = 'cancellation_id');
  assert v_before = v_after, format('BUG (A): settlement_batch_cancellations row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  raise notice 'PASS (A): all 13 pre-existing row snapshots (route/fee-version/4 batches/3 lines/2 movements/1 reversal/1 cancellation/1 claim) are BYTE-IDENTICAL pre- vs post-migration (0184-0191 mutated nothing)';
end $$;

-- ---------------------------------------------------------------------------
-- (B)-(E) Read the pre-existing data back through the NEW (0191) get_
-- settlement_batch()/list_settlement_batches() and confirm it is still
-- displayed correctly — old 'return_refund'-kind line included, original_*/
-- effective_* figures correct, cancelled batch's effective_* collapsed to
-- 0.00 while original_*/historical_* stay exactly what they always were.
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"f7100000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_batch_finalized_id uuid := (select value::uuid from public.p71u_scratch where label = 'batch_finalized_id');
  v_return_number text := (select value from public.p71u_scratch where label = 'return_number');
  v_batch_reconciled_id uuid := (select value::uuid from public.p71u_scratch where label = 'batch_reconciled_id');
  v_order_recon_number text := (select value from public.p71u_scratch where label = 'order_recon_number');
  v_batch_cancelled_id uuid := (select value::uuid from public.p71u_scratch where label = 'batch_cancelled_id');
  v_order_cancel_number text := (select value from public.p71u_scratch where label = 'order_cancel_number');
  v_batch_draft_id uuid := (select value::uuid from public.p71u_scratch where label = 'batch_draft_id');

  v_g record;
  v_line jsonb;
begin
  -- (B) Finalized batch — OLD 'return_refund'-kind line must still display
  -- correctly, and original_* figures must be exactly what the fixture
  -- committed under the OLD (0176-0183) contracts.
  select * into v_g from public.get_settlement_batch(v_batch_finalized_id);
  assert v_g.status = 'finalized' and v_g.effective_status = 'finalized',
    format('BUG (B): finalized batch status/effective_status wrong: %s/%s', v_g.status, v_g.effective_status);
  assert v_g.original_gross_source_impact = '-300.00', format('BUG (B): original_gross_source_impact expected -300.00, got %s', v_g.original_gross_source_impact);
  assert v_g.original_provider_fee_impact = '0.00', format('BUG (B): original_provider_fee_impact expected 0.00, got %s', v_g.original_provider_fee_impact);
  assert v_g.original_expected_bank_settlement = '-300.00', format('BUG (B): original_expected_bank_settlement expected -300.00, got %s', v_g.original_expected_bank_settlement);
  assert v_g.effective_expected_settlement_contribution = '-300.00', format('BUG (B): effective_expected_settlement_contribution (not cancelled) expected -300.00, got %s', v_g.effective_expected_settlement_contribution);
  assert jsonb_array_length(v_g.lines) = 1, format('BUG (B): expected exactly 1 line on the finalized batch, got %s', jsonb_array_length(v_g.lines));
  v_line := v_g.lines -> 0;
  assert v_line ->> 'source_kind' = 'return_refund', format('BUG (B): expected the OLD ''return_refund'' source_kind to still display, got %s', v_line ->> 'source_kind');
  assert v_line ->> 'source_number' = v_return_number, format('BUG (B): line source_number mismatch: %s <> %s', v_line ->> 'source_number', v_return_number);
  assert (v_line ->> 'gross_collection_impact')::numeric = -300.00, format('BUG (B): line gross_collection_impact expected -300.00, got %s', v_line ->> 'gross_collection_impact');
  assert (v_line ->> 'provider_fee_impact')::numeric = 0.00, format('BUG (B): line provider_fee_impact expected 0.00, got %s', v_line ->> 'provider_fee_impact');
  assert (v_line ->> 'expected_settlement_impact')::numeric = -300.00, format('BUG (B): line expected_settlement_impact expected -300.00, got %s', v_line ->> 'expected_settlement_impact');

  raise notice 'PASS (B): get_settlement_batch() (0191) still displays the OLD (pre-Patch-7.1) ''return_refund''-kind line correctly, number=%, original_expected_bank_settlement=-300.00', v_g.settlement_number;

  -- (C) Reconciled batch — effective_* == original_* (not cancelled), zero
  -- variance.
  select * into v_g from public.get_settlement_batch(v_batch_reconciled_id);
  assert v_g.status = 'reconciled' and v_g.effective_status = 'reconciled',
    format('BUG (C): reconciled batch status/effective_status wrong: %s/%s', v_g.status, v_g.effective_status);
  assert v_g.original_gross_source_impact = '500.00', format('BUG (C): original_gross_source_impact expected 500.00, got %s', v_g.original_gross_source_impact);
  assert v_g.original_expected_bank_settlement = '500.00', format('BUG (C): original_expected_bank_settlement expected 500.00, got %s', v_g.original_expected_bank_settlement);
  assert v_g.historical_actual_bank_movement = '500.00', format('BUG (C): historical_actual_bank_movement expected 500.00, got %s', v_g.historical_actual_bank_movement);
  assert v_g.original_variance = '0.00', format('BUG (C): original_variance expected 0.00, got %s', v_g.original_variance);
  assert v_g.effective_expected_settlement_contribution = '500.00', format('BUG (C): effective_expected_settlement_contribution expected 500.00, got %s', v_g.effective_expected_settlement_contribution);
  assert v_g.effective_actual_settlement_contribution = '500.00', format('BUG (C): effective_actual_settlement_contribution expected 500.00, got %s', v_g.effective_actual_settlement_contribution);
  assert v_g.effective_variance_contribution = '0.00', format('BUG (C): effective_variance_contribution expected 0.00, got %s', v_g.effective_variance_contribution);
  assert jsonb_array_length(v_g.lines) = 1 and (v_g.lines -> 0 ->> 'source_kind') = 'sale' and (v_g.lines -> 0 ->> 'source_number') = v_order_recon_number,
    format('BUG (C): reconciled batch line mismatch: %s', v_g.lines);

  raise notice 'PASS (C): get_settlement_batch() (0191) on the reconciled batch: effective_* == original_* (500.00/500.00/0.00), number=%', v_g.settlement_number;

  -- (D) Cancelled batch — original_*/historical_* are the PERMANENT
  -- historical facts (600.00 gross, 0.00 actual since the movement was
  -- reversed, -600.00 variance) — NEVER zeroed by cancellation. effective_*
  -- collapses to EXACTLY 0.00 (§26).
  select * into v_g from public.get_settlement_batch(v_batch_cancelled_id);
  assert v_g.status = 'finalized' and v_g.effective_status = 'cancelled',
    format('BUG (D): cancelled batch status/effective_status wrong: %s/%s (status column itself must stay ''finalized'' forever, per item 17 — cancellation never rewrites it)', v_g.status, v_g.effective_status);
  assert v_g.original_gross_source_impact = '600.00', format('BUG (D): original_gross_source_impact expected 600.00 (never zeroed by cancellation), got %s', v_g.original_gross_source_impact);
  assert v_g.original_expected_bank_settlement = '600.00', format('BUG (D): original_expected_bank_settlement expected 600.00, got %s', v_g.original_expected_bank_settlement);
  assert v_g.historical_actual_bank_movement = '0.00', format('BUG (D): historical_actual_bank_movement expected 0.00 (600.00 movement fully reversed), got %s', v_g.historical_actual_bank_movement);
  assert v_g.original_variance = '-600.00', format('BUG (D): original_variance expected -600.00 (0.00 actual - 600.00 expected — the permanent historical fact), got %s', v_g.original_variance);
  -- Compared numerically (not exact text) — 0191 assigns these a bare
  -- `0::numeric` literal once cancelled (scale 0, renders as '0'), unlike
  -- every OTHER money figure here which flows through real numeric(14,2)
  -- column arithmetic (always renders with 2 decimals) — the VALUE is what
  -- matters (exactly zero), not the literal's display scale.
  assert v_g.effective_expected_settlement_contribution::numeric = 0, format('BUG (D): effective_expected_settlement_contribution expected 0 once cancelled (§26), got %s', v_g.effective_expected_settlement_contribution);
  assert v_g.effective_actual_settlement_contribution::numeric = 0, format('BUG (D): effective_actual_settlement_contribution expected 0 once cancelled (§26), got %s', v_g.effective_actual_settlement_contribution);
  assert v_g.effective_variance_contribution::numeric = 0, format('BUG (D): effective_variance_contribution expected 0 once cancelled (§26), got %s', v_g.effective_variance_contribution);
  assert v_g.cancellation_reason is not null and v_g.cancelled_at is not null,
    'BUG (D): cancellation_reason/cancelled_at must be populated on a cancelled batch';
  assert jsonb_array_length(v_g.lines) = 1 and (v_g.lines -> 0 ->> 'source_kind') = 'sale' and (v_g.lines -> 0 ->> 'source_number') = v_order_cancel_number,
    format('BUG (D): cancelled batch line mismatch: %s', v_g.lines);
  assert jsonb_array_length(v_g.bank_movements) = 1 and (v_g.bank_movements -> 0 ->> 'reversed')::boolean = true,
    format('BUG (D): cancelled batch bank_movements mismatch (expected exactly 1, reversed=true): %s', v_g.bank_movements);

  raise notice 'PASS (D): get_settlement_batch() (0191) on the cancelled batch: original_*/historical_* preserved EXACTLY (gross=600.00, actual=0.00, variance=-600.00) while effective_* is EXACTLY 0.00/0.00/0.00, number=%', v_g.settlement_number;

  -- Draft batch sanity — never touched, no lines, no financial figures.
  select * into v_g from public.get_settlement_batch(v_batch_draft_id);
  assert v_g.status = 'draft' and v_g.effective_status = 'draft', format('BUG: draft batch status/effective_status wrong: %s/%s', v_g.status, v_g.effective_status);
  assert jsonb_array_length(v_g.lines) = 0, format('BUG: draft batch expected 0 lines, got %s', jsonb_array_length(v_g.lines));
  assert v_g.original_gross_source_impact is null, format('BUG: draft batch original_gross_source_impact expected NULL (never finalized), got %s', v_g.original_gross_source_impact);

  raise notice 'PASS: draft batch (never finalized) still shows status=draft, 0 lines, NULL financial figures post-migration, number=%', v_g.settlement_number;
end $$;

-- ---------------------------------------------------------------------------
-- (E) list_settlement_batches() (0191) agrees with get_settlement_batch() on
-- source_count + original_*/effective_* figures, and p_effective_status
-- filtering correctly finds the cancelled batch under 'cancelled' only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_batch_finalized_id uuid := (select value::uuid from public.p71u_scratch where label = 'batch_finalized_id');
  v_batch_reconciled_id uuid := (select value::uuid from public.p71u_scratch where label = 'batch_reconciled_id');
  v_batch_cancelled_id uuid := (select value::uuid from public.p71u_scratch where label = 'batch_cancelled_id');
  v_batch_draft_id uuid := (select value::uuid from public.p71u_scratch where label = 'batch_draft_id');
  v_route_id uuid := (select value::uuid from public.p71u_scratch where label = 'route_id');
  v_row record;
  v_cancelled_found boolean := false;
  v_reconciled_found_under_cancelled boolean := false;
begin
  select * into v_row from public.list_settlement_batches(p_settlement_route_id := v_route_id, p_limit := 500) l where l.id = v_batch_finalized_id;
  assert v_row.source_count = 1 and v_row.original_gross_source_impact = '-300.00' and v_row.effective_expected_settlement_contribution = '-300.00',
    format('BUG (E): list_settlement_batches() finalized-batch row mismatch: source_count=%s, original_gross=%s, eff_expected=%s', v_row.source_count, v_row.original_gross_source_impact, v_row.effective_expected_settlement_contribution);

  select * into v_row from public.list_settlement_batches(p_settlement_route_id := v_route_id, p_limit := 500) l where l.id = v_batch_reconciled_id;
  assert v_row.source_count = 1 and v_row.original_gross_source_impact = '500.00' and v_row.effective_expected_settlement_contribution = '500.00' and v_row.effective_variance_contribution = '0.00',
    format('BUG (E): list_settlement_batches() reconciled-batch row mismatch: source_count=%s, original_gross=%s, eff_expected=%s, eff_variance=%s', v_row.source_count, v_row.original_gross_source_impact, v_row.effective_expected_settlement_contribution, v_row.effective_variance_contribution);

  select * into v_row from public.list_settlement_batches(p_settlement_route_id := v_route_id, p_limit := 500) l where l.id = v_batch_cancelled_id;
  -- effective_* compared numerically here too (see the same note in section D above).
  assert v_row.effective_status = 'cancelled' and v_row.source_count = 1
    and v_row.original_gross_source_impact = '600.00'
    and v_row.effective_expected_settlement_contribution::numeric = 0 and v_row.effective_actual_settlement_contribution::numeric = 0 and v_row.effective_variance_contribution::numeric = 0,
    format('BUG (E): list_settlement_batches() cancelled-batch row mismatch: effective_status=%s, source_count=%s, original_gross=%s, eff_expected=%s, eff_actual=%s, eff_variance=%s',
      v_row.effective_status, v_row.source_count, v_row.original_gross_source_impact, v_row.effective_expected_settlement_contribution, v_row.effective_actual_settlement_contribution, v_row.effective_variance_contribution);

  select * into v_row from public.list_settlement_batches(p_settlement_route_id := v_route_id, p_limit := 500) l where l.id = v_batch_draft_id;
  assert v_row.status = 'draft' and v_row.effective_status = 'draft' and v_row.source_count = 0 and v_row.original_gross_source_impact is null,
    format('BUG (E): list_settlement_batches() draft-batch row mismatch: status=%s, effective_status=%s, source_count=%s, original_gross=%s', v_row.status, v_row.effective_status, v_row.source_count, v_row.original_gross_source_impact);

  -- p_effective_status filter: 'cancelled' must find the cancelled batch and
  -- must NOT find the reconciled batch (which has a real historical
  -- variance but was never cancelled).
  select exists (
    select 1 from public.list_settlement_batches(p_settlement_route_id := v_route_id, p_effective_status := array['cancelled'], p_limit := 500) l
    where l.id = v_batch_cancelled_id
  ) into v_cancelled_found;
  assert v_cancelled_found, 'BUG (E): p_effective_status := array[''cancelled''] did not find the cancelled batch';

  select exists (
    select 1 from public.list_settlement_batches(p_settlement_route_id := v_route_id, p_effective_status := array['cancelled'], p_limit := 500) l
    where l.id = v_batch_reconciled_id
  ) into v_reconciled_found_under_cancelled;
  assert not v_reconciled_found_under_cancelled, 'BUG (E): p_effective_status := array[''cancelled''] incorrectly matched the reconciled (not cancelled) batch';

  raise notice 'PASS (E): list_settlement_batches() (0191) agrees with get_settlement_batch() on source_count/original_*/effective_* for all 4 pre-existing batches, and p_effective_status:=[''cancelled''] filters correctly';
end $$;

do $$
begin
  raise notice '=== ALL UPGRADE-TO-PHASE-7.1 TESTS PASSED (0184-0191 applied onto a real pre-Patch-7.1 production-shaped database built entirely under the OLD 0169-0183 Settlements RPCs, WITHOUT re-running seed.sql — every pre-existing row is byte-identical, and the NEW get_settlement_batch()/list_settlement_batches() correctly read the old-shape data back, including the retained-but-never-emitted-again ''return_refund'' source kind) ===';
end $$;

rollback;

-- ---------------------------------------------------------------------------
-- (F) Final unconditional cleanup — committed immediately (outside the
-- rolled-back assertion transaction above), so this test file leaves no
-- residue behind regardless of how it is re-run.
-- ---------------------------------------------------------------------------
drop table if exists public.p71u_scratch;

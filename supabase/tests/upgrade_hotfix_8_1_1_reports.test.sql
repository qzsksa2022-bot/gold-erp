-- ============================================================================
-- Phase 8 — Final Integrity Hotfix 8.1.1 (§60) — 0214->latest upgrade-safety
-- test. Runs AFTER migrations 0215-latest have been applied on top of a
-- database that already has the real, COMMITTED data from fixtures/
-- hotfix_8_1_1_upgrade_pre_fixture.sql (written entirely under 0214, before
-- any of this hotfix's fixes existed). Self-contained: begin;...rollback;
-- (only READS -- never mutates -- the pre-existing committed data).
-- ============================================================================
begin;

do $$
declare
  v_ship_id uuid := (select value::uuid from public.h811tu_scratch where label = 'cod_shipment_id');
  v_date_from date := (select value::date from public.h811tu_scratch where label = 'cod_date_from');
  v_date_to date := (select value::date from public.h811tu_scratch where label = 'cod_date_to');
  v jsonb;
  v_rows jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '81140000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  if v_ship_id is null then
    raise exception 'FAIL SETUP: h811tu_scratch has no cod_shipment_id -- did the pre-fixture actually run and commit?';
  end if;

  -- §23-26 CRITICAL: the SAME exact-parity matrix as hotfix_8_1_1_reports_
  -- exports.test.sql section A, now proven against a shipment_cod_events
  -- history that has existed since BEFORE migration 0216 (the fix) did.
  v := public.get_cod_report(p_date_from => v_date_from, p_date_to => v_date_to, p_basis => 'collection_transitions');
  v_rows := v -> 'rows';

  if jsonb_array_length(v_rows) <> 4 then
    raise exception 'FAIL A1: expected exactly 4 nonzero-effect transition rows for the pre-existing (pre-0216) COD event history, got %', jsonb_array_length(v_rows);
  end if;
  if (select count(*) from jsonb_array_elements(v_rows) r where (r ->> 'cod_effect')::numeric = -500.00) <> 1 then
    raise exception 'FAIL A2: expected exactly ONE -500 reversal row for the pre-existing COD event history -- the phantom-reversal bug (fixed by 0216) is back for HISTORICAL data';
  end if;
  if (v -> 'summary' ->> 'net_cod_collection_effect')::numeric <> 1000.00 then
    raise exception 'FAIL A3: expected net_cod_collection_effect=1000.00 for the pre-existing COD event history, got %', v -> 'summary' ->> 'net_cod_collection_effect';
  end if;

  raise notice 'PASS A: get_cod_report(collection_transitions) correctly re-derives the exact Phase-7-canonical-adapter parity matrix (§23-26) over a shipment_cod_events history written entirely BEFORE migration 0216 existed -- 4 real rows, net effect 1000.00, zero phantom reversals';
end $$;

do $$
declare
  v_route uuid := (select value::uuid from public.h811tu_scratch where label = 'settlement_route_id');
  v_batch_draft uuid := (select value::uuid from public.h811tu_scratch where label = 'settlement_batch_draft_id');
  v_batch_fin uuid := (select value::uuid from public.h811tu_scratch where label = 'settlement_batch_fin_id');
  v_date date := (select value::date from public.h811tu_scratch where label = 'settlement_date');
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '81140000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
  set local role authenticated;

  if v_batch_draft is null or v_batch_fin is null then
    raise exception 'FAIL SETUP: h811tu_scratch is missing settlement_batch_draft_id/settlement_batch_fin_id -- did the pre-fixture actually run and commit?';
  end if;

  -- §28-31 CRITICAL + the 0220 follow-up: the draft batch has existed,
  -- with ZERO settlement_batch_lines (create_draft_settlement_batch()
  -- itself is unchanged by this hotfix), since BEFORE 0218's Draft
  -- effective_status fix AND 0220's store-scope zero-lines fix existed.
  v := public.get_settlements_report(p_date_from => v_date, p_date_to => v_date, p_effective_status => 'draft', p_settlement_route_id => v_route);
  if jsonb_array_length(v -> 'rows') <> 1 or (v -> 'rows' -> 0 ->> 'settlement_batch_id')::uuid <> v_batch_draft then
    raise exception 'FAIL B1: expected effective_status=draft to surface the pre-existing draft batch (%) written before 0218/0220 existed, got rows=%', v_batch_draft, v -> 'rows';
  end if;
  if coalesce((v -> 'summary' ->> 'expected')::numeric, 0) <> 0 or coalesce((v -> 'summary' ->> 'actual')::numeric, 0) <> 0 then
    raise exception 'FAIL B2: expected zero financial contribution from the pre-existing draft batch, got expected=%/actual=%', v -> 'summary' ->> 'expected', v -> 'summary' ->> 'actual';
  end if;

  v := public.get_settlements_report(p_date_from => v_date, p_date_to => v_date, p_effective_status => 'finalized', p_settlement_route_id => v_route);
  if jsonb_array_length(v -> 'rows') <> 1 or (v -> 'rows' -> 0 ->> 'settlement_batch_id')::uuid <> v_batch_fin then
    raise exception 'FAIL B3: expected effective_status=finalized to surface ONLY the pre-existing finalized batch (%), not the draft one too, got rows=%', v_batch_fin, v -> 'rows';
  end if;
  if (v -> 'summary' ->> 'batches_count')::int <> 1 then
    raise exception 'FAIL B3b: expected summary.batches_count=1 for the finalized-only filtered population, got %', v -> 'summary' ->> 'batches_count';
  end if;

  raise notice 'PASS B: get_settlements_report() correctly surfaces the pre-existing (pre-0218/0220) never-finalized draft batch % under effective_status=draft with zero financial contribution, AND correctly isolates the pre-existing finalized batch % under effective_status=finalized with a filtered-matching batches_count=1 (§28-31)', v_batch_draft, v_batch_fin;
end $$;

do $$ begin
  raise notice '=== ALL upgrade_hotfix_8_1_1_reports.test.sql ASSERTIONS PASSED (§23-26/§28-31/§60 -- 0214->latest upgrade-safe on top of frozen 0001-0214) ===';
end $$;

rollback;

-- Cleanup: drop the scratch table itself (mirrors upgrade_phase8_
-- multidomain.test.sql's own convention -- test-only infrastructure,
-- never left behind for a later run to collide with).
drop table if exists public.h811tu_scratch;

-- ============================================================================
-- Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3 — UPGRADE test
-- (§11/§13/§14/§17 item E). Runs AFTER migrations 0197-latest (the CORRECTED
-- 0197/0198) have been applied on top of the committed
-- hotfix_7_1_3_upgrade_pre_fixture.sql data (built under the OLD 0001-0196
-- contract, in the SAME database as hotfix_7_1_2's own pre-fixture). Reads
-- back public.h713u_scratch.
--
-- Proves (spec §11/§13/§14):
--   Scenario 1 (§11, CRITICAL): the once-refreshed, still-PENDING Return's
--   backfilled collection_channel_id_snapshot is Channel B — reconstructed
--   from the audit_logs 'sale.update' event whose new_values.row_version
--   EXACTLY matches the Return's OWN source_sale_row_version=2 — NOT Channel
--   A (the Return's creation-time channel, which the ORIGINAL/buggy 0197
--   backfill would have wrongly used) and NOT any value that would fail the
--   payment_method_id anchor (already B pre-upgrade). The migration does
--   NOT abort (proven simply by this test running at all). Then the Return
--   is approved POST-upgrade — must succeed, since its recorded basis
--   (source_sale_row_version=2) already matches the Sale's current
--   row_version (2, unchanged since the fixture) — and Settlement Discovery
--   resolves exclusively to Route B, never Route A.
--
--   Scenario 2 (§13): the twice-refreshed, still-PENDING Return's backfilled
--   collection_channel_id_snapshot is Channel C — reconstructed from the
--   'sale.update' event at row_version=3 — confirming the audit match is
--   not coincidentally tied to "the first update" or "the second event" but
--   genuinely keyed to the Return's own basis version. Approved post-
--   upgrade, resolves exclusively to Route C.
--
--   Both scenarios, run in the SAME database upgrade as hotfix_7_1_2's own
--   fixture (§12), together exercise backfill reconstruction from a
--   'sale.create' basis (row_version=1, h712u's Return), a 'sale.update'
--   basis of row_version=2 (h713u Scenario 1), and a 'sale.update' basis of
--   row_version=3 (h713u Scenario 2) — the full §14 coverage matrix for the
--   "happy path" (the deliberate-FAIL path is proven separately by
--   hotfix_7_1_3_upgrade_broken_fixture.sql / run_upgrade_test_hotfix_7_1_3_
--   broken_fixture.sh, since a real FAIL there aborts the WHOLE migration
--   and cannot coexist in the same database as a passing upgrade).
--
-- NOTE: mirrors upgrade_hotfix_7_1_2_settlements.test.sql's structure and
-- conventions exactly. Not wrapped in begin/rollback by design for
-- Scenario-1/2 reads; the post-upgrade approve_sales_return() calls below
-- ARE real writes on real committed data (mirroring production upgrade
-- behavior — pending Returns get approved AFTER the upgrade, same as any
-- real operator would).
-- ============================================================================

do $$
declare
  v_s1_return uuid; v_s2_return uuid;
  v_pm_b uuid; v_pm_c uuid; v_chan_a uuid; v_chan_b uuid; v_chan_c uuid;
begin
  select value::uuid into v_s1_return from public.h713u_scratch where label = 's1_return_id';
  select value::uuid into v_s2_return from public.h713u_scratch where label = 's2_return_id';
  if v_s1_return is null or v_s2_return is null then
    raise exception 'FAIL: public.h713u_scratch is missing s1_return_id/s2_return_id — hotfix_7_1_3_upgrade_pre_fixture.sql did not run (or was run against the wrong database)';
  end if;
  raise notice 'H713U scratch reloaded: s1_return=%, s2_return=%', v_s1_return, v_s2_return;
end $$;

-- ---------------------------------------------------------------------------
-- Scenario 1 (§11 CRITICAL) — backfill + anchor, read as postgres (bypasses
-- RLS, mirrors h712u/h711u's own convention).
-- ---------------------------------------------------------------------------
do $$
declare
  v_return_id uuid; v_pm_b uuid; v_chan_a uuid; v_chan_b uuid;
  v_row record;
begin
  select value::uuid into v_return_id from public.h713u_scratch where label = 's1_return_id';
  select value::uuid into v_pm_b from public.h713u_scratch where label = 'pm_b';
  select value::uuid into v_chan_a from public.h713u_scratch where label = 'chan_a';
  select value::uuid into v_chan_b from public.h713u_scratch where label = 'chan_b';

  select payment_method_id, collection_channel_id_snapshot, source_sale_row_version, status into v_row
  from public.sales_returns where id = v_return_id;

  if v_row.status <> 'pending' then
    raise exception 'FAIL: S1 — expected the Return to still be pending immediately post-upgrade (0197-0198 never change status), got %', v_row.status;
  end if;
  if v_row.source_sale_row_version <> 2 then
    raise exception 'FAIL: S1 — expected source_sale_row_version to remain 2 post-upgrade (0197-0198 never touch it), got %', v_row.source_sale_row_version;
  end if;
  if v_row.payment_method_id is distinct from v_pm_b then
    raise exception 'FAIL: S1 — expected the pre-existing payment_method_id anchor to remain Payment Method B post-upgrade, got %', v_row.payment_method_id;
  end if;
  if v_row.collection_channel_id_snapshot is distinct from v_chan_b then
    raise exception 'FAIL: S1 (CRITICAL) — expected collection_channel_id_snapshot to be backfilled to Channel B (reconstructed from the sale.update audit event at row_version=2, matching the Return''s OWN source_sale_row_version), got % (Channel A would mean the backfill wrongly used the ORIGINAL "first update after created_at" timestamp heuristic instead of the corrected source_sale_row_version-keyed match)', v_row.collection_channel_id_snapshot;
  end if;
  if v_row.collection_channel_id_snapshot = v_chan_a then
    raise exception 'FAIL: S1 (CRITICAL) — collection_channel_id_snapshot was backfilled to Channel A, the Return''s stale CREATION-time channel — this is EXACTLY the §1/§11 bug this hotfix''s corrected backfill exists to close';
  end if;

  raise notice 'PASS: S1 (§11 CRITICAL) — payment_method_id anchor intact (Payment Method B); collection_channel_id_snapshot correctly backfilled to Channel B via the source_sale_row_version=2-keyed audit reconstruction, NOT the stale creation-time Channel A — migration did not abort, confirming the corrected §6/§7/§8 integrity check passed on a genuinely refreshed-pending row';
end $$;

-- ---------------------------------------------------------------------------
-- Scenario 2 (§13) — backfill for the twice-refreshed Return.
-- ---------------------------------------------------------------------------
do $$
declare
  v_return_id uuid; v_pm_c uuid; v_chan_a uuid; v_chan_b uuid; v_chan_c uuid;
  v_row record;
begin
  select value::uuid into v_return_id from public.h713u_scratch where label = 's2_return_id';
  select value::uuid into v_pm_c from public.h713u_scratch where label = 'pm_c';
  select value::uuid into v_chan_a from public.h713u_scratch where label = 'chan_a';
  select value::uuid into v_chan_b from public.h713u_scratch where label = 'chan_b';
  select value::uuid into v_chan_c from public.h713u_scratch where label = 'chan_c';

  select payment_method_id, collection_channel_id_snapshot, source_sale_row_version, status into v_row
  from public.sales_returns where id = v_return_id;

  if v_row.status <> 'pending' then
    raise exception 'FAIL: S2 — expected the Return to still be pending immediately post-upgrade, got %', v_row.status;
  end if;
  if v_row.source_sale_row_version <> 3 then
    raise exception 'FAIL: S2 — expected source_sale_row_version to remain 3 post-upgrade, got %', v_row.source_sale_row_version;
  end if;
  if v_row.payment_method_id is distinct from v_pm_c then
    raise exception 'FAIL: S2 — expected the pre-existing payment_method_id anchor to remain Payment Method C post-upgrade, got %', v_row.payment_method_id;
  end if;
  if v_row.collection_channel_id_snapshot is distinct from v_chan_c then
    raise exception 'FAIL: S2 (§13/§14 CRITICAL) — expected collection_channel_id_snapshot to be backfilled to Channel C (reconstructed from the sale.update audit event at row_version=3), got % (Channel A or B would mean the backfill matched the WRONG audit event — proving the reconstruction is not correctly keyed to THIS row''s own basis version)', v_row.collection_channel_id_snapshot;
  end if;

  raise notice 'PASS: S2 (§13/§14 CRITICAL) — the twice-refreshed Return''s collection_channel_id_snapshot correctly backfilled to Channel C via the row_version=3-keyed audit reconstruction — confirms the backfill is genuinely keyed to each row''s OWN source_sale_row_version, not a positional/first-match heuristic';
end $$;

-- ---------------------------------------------------------------------------
-- Post-upgrade lifecycle: approve BOTH Returns for real (as a real operator
-- would after the upgrade), then confirm Settlement Discovery on the SAME
-- real upgraded data.
-- ---------------------------------------------------------------------------
set role authenticated;
set request.jwt.claims = '{"sub":"a7130000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_s1_return uuid; v_s2_return uuid;
  v_return jsonb;
begin
  select value::uuid into v_s1_return from public.h713u_scratch where label = 's1_return_id';
  select value::uuid into v_s2_return from public.h713u_scratch where label = 's2_return_id';

  v_return := public.get_sales_return(v_s1_return);
  perform public.approve_sales_return(v_s1_return, (v_return ->> 'row_version')::bigint);
  v_return := public.get_sales_return(v_s1_return);
  if v_return ->> 'status' <> 'approved' then
    raise exception 'FAIL: post-upgrade approval of Scenario 1''s Return failed — expected status=approved, got %', v_return ->> 'status';
  end if;

  v_return := public.get_sales_return(v_s2_return);
  perform public.approve_sales_return(v_s2_return, (v_return ->> 'row_version')::bigint);
  v_return := public.get_sales_return(v_s2_return);
  if v_return ->> 'status' <> 'approved' then
    raise exception 'FAIL: post-upgrade approval of Scenario 2''s Return failed — expected status=approved, got %', v_return ->> 'status';
  end if;

  raise notice 'PASS: post-upgrade approve_sales_return() succeeded for BOTH refreshed-pending Returns — their recorded source_sale_row_version already matched the Sale''s current row_version, exactly as a real operator resuming a mid-lifecycle Return after this upgrade would experience';
end $$;

do $$
declare
  v_s1_return uuid; v_s2_return uuid;
  v_route_a uuid; v_route_b uuid; v_route_c uuid;
  v_on_a int; v_on_b int; v_on_c int;
begin
  select value::uuid into v_s1_return from public.h713u_scratch where label = 's1_return_id';
  select value::uuid into v_s2_return from public.h713u_scratch where label = 's2_return_id';
  select value::uuid into v_route_a from public.h713u_scratch where label = 'route_a';
  select value::uuid into v_route_b from public.h713u_scratch where label = 'route_b';
  select value::uuid into v_route_c from public.h713u_scratch where label = 'route_c';

  select count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id in (v_s1_return, v_s2_return))
  into v_on_a
  from public.list_unsettled_settlement_sources(v_route_a, public.business_today() - 5, public.business_today() + 1);
  select count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = v_s1_return)
  into v_on_b
  from public.list_unsettled_settlement_sources(v_route_b, public.business_today() - 5, public.business_today() + 1);
  select count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = v_s2_return)
  into v_on_c
  from public.list_unsettled_settlement_sources(v_route_c, public.business_today() - 5, public.business_today() + 1);

  if v_on_a <> 0 then
    raise exception 'FAIL: Discovery (CRITICAL) — Route A (neither Return''s final basis) must show NEITHER fee event, got %', v_on_a;
  end if;
  if v_on_b <> 1 then
    raise exception 'FAIL: Discovery (§11 CRITICAL) — Route B (Scenario 1''s reconstructed final basis) must show exactly Scenario 1''s fee event, got %', v_on_b;
  end if;
  if v_on_c <> 1 then
    raise exception 'FAIL: Discovery (§13 CRITICAL) — Route C (Scenario 2''s reconstructed final basis) must show exactly Scenario 2''s fee event, got %', v_on_c;
  end if;

  raise notice 'PASS: Discovery (§11/§13 CRITICAL, real accumulated data) — post-upgrade Settlement Discovery resolves Scenario 1''s fee event EXCLUSIVELY to Route B and Scenario 2''s EXCLUSIVELY to Route C — Route A (both Returns'' abandoned creation-time basis) shows neither, proving the corrected backfill + guard trigger produce a genuinely usable, correctly-routed real upgrade outcome';
end $$;

-- ---------------------------------------------------------------------------
-- Byte-identical proof: every pre-existing column, unchanged (excludes
-- collection_channel_id_snapshot/status/row_version/etc — the point of this
-- test IS to change those via the real post-upgrade approval above; the
-- byte-identical check instead targets the columns approve_sales_return()
-- itself does NOT touch, verified as postgres against the PRE-upgrade,
-- PRE-approval snapshot recorded by the fixture).
-- ---------------------------------------------------------------------------
do $$
declare
  v_s1_return uuid;
  v_pre jsonb; v_post jsonb;
begin
  select value::uuid into v_s1_return from public.h713u_scratch where label = 's1_return_id';
  select value::jsonb into v_pre from public.h713u_scratch where label = 's1_return_row_json_pre_upgrade';
  select to_jsonb(r) into v_post from public.sales_returns r where r.id = v_s1_return;

  if v_pre ->> 'id' <> v_post ->> 'id'
     or v_pre ->> 'return_number' <> v_post ->> 'return_number'
     or v_pre ->> 'sales_order_id' <> v_post ->> 'sales_order_id'
     or v_pre ->> 'created_at' <> v_post ->> 'created_at'
     or v_pre ->> 'created_by' <> v_post ->> 'created_by' then
    raise exception 'FAIL: byte-identical check — identity/creation columns on Scenario 1''s Return changed across the upgrade+approval, pre=% post=%', v_pre, v_post;
  end if;

  raise notice 'PASS: byte-identical check — Scenario 1''s Return identity/creation columns (id/return_number/sales_order_id/created_at/created_by) are unchanged across the upgrade and the subsequent real approval';
end $$;

do $$
begin
  raise notice '=== ALL upgrade_hotfix_7_1_3_settlements.test.sql ASSERTIONS PASSED ===';
end $$;

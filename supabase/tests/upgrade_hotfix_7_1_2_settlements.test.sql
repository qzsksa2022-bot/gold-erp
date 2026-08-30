-- ============================================================================
-- Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2 — UPGRADE test
-- (§11/§15 item E). Runs AFTER migrations 0197-latest have been applied on
-- top of the committed hotfix_7_1_2_upgrade_pre_fixture.sql data (built
-- under the OLD 0001-0196 contract). Reads back public.h712u_scratch.
--
-- Proves (spec §11):
--   1. The backfilled collection_channel_id_snapshot for the fixture Return
--      is Channel A — reconstructed via audit_logs history — NOT Channel B,
--      the Sale's CURRENT (post-fixture-edit) live channel.
--   2. payment_method_id (the pre-existing, untouched anchor column) is
--      still Payment Method A, and the backfill's integrity check (§6) did
--      not abort the migration (proven simply by this test running at all —
--      0197 wraps its backfill in an explicit transaction that aborts the
--      WHOLE migration on any anchor mismatch, per its own header comment).
--   3. Discovery, run AGAINST THE SAME REAL UPGRADED DATA, now resolves
--      both fee events to Route A only — the exact opposite of the
--      pre-upgrade baseline recorded by the fixture (Route B, 2 events) —
--      proving 0197-0198 together fix the live bug on real accumulated
--      data, not merely on a fresh-DB scenario.
--   4. Every pre-existing column on both the sales_return and sales_order
--      rows is byte-identical to their pre-upgrade snapshot — 0197-0198
--      only ADD collection_channel_id_snapshot, they never modify any
--      other existing data.
--
-- NOTE: mirrors upgrade_hotfix_7_1_1_settlements.test.sql's structure and
-- conventions exactly. Not wrapped in begin/rollback by design — read-only
-- (SELECT/RAISE only), no writes.
-- ============================================================================

do $$
declare
  v_return_id uuid; v_order_id uuid;
  v_pm_a uuid; v_pm_b uuid; v_chan_a uuid; v_chan_b uuid;
  v_route_a uuid; v_route_b uuid;
  v_expected_fee numeric;
  v_pre_on_a int; v_pre_on_b int;
begin
  select value::uuid into v_return_id from public.h712u_scratch where label = 'return_id';
  select value::uuid into v_order_id from public.h712u_scratch where label = 'order_id';
  select value::uuid into v_pm_a from public.h712u_scratch where label = 'pm_a';
  select value::uuid into v_pm_b from public.h712u_scratch where label = 'pm_b';
  select value::uuid into v_chan_a from public.h712u_scratch where label = 'chan_a';
  select value::uuid into v_chan_b from public.h712u_scratch where label = 'chan_b';
  select value::uuid into v_route_a from public.h712u_scratch where label = 'route_a';
  select value::uuid into v_route_b from public.h712u_scratch where label = 'route_b';
  select value::numeric into v_expected_fee from public.h712u_scratch where label = 'payment_fee_reversal_amount';
  select value::int into v_pre_on_a from public.h712u_scratch where label = 'pre_upgrade_fee_events_on_route_a';
  select value::int into v_pre_on_b from public.h712u_scratch where label = 'pre_upgrade_fee_events_on_route_b';

  if v_return_id is null or v_order_id is null then
    raise exception 'FAIL: public.h712u_scratch is missing return_id/order_id — hotfix_7_1_2_upgrade_pre_fixture.sql did not run (or was run against the wrong database)';
  end if;

  -- Sanity: confirm the recorded PRE-upgrade baseline really did show the
  -- bug (Route B, not Route A) — otherwise this whole test would be
  -- vacuous.
  if v_pre_on_a <> 0 or v_pre_on_b <> 2 then
    raise exception 'FAIL: fixture assumption broken — expected the PRE-upgrade baseline to show the OLD bug (0 fee events on Route A, 2 on Route B), got on_a=%, on_b=% — cannot validate the fix meaningfully against this fixture', v_pre_on_a, v_pre_on_b;
  end if;
  raise notice 'CONFIRMED: pre-upgrade baseline (recorded by the fixture, BEFORE 0197-0198 ran) showed the OLD bug: 0 fee events on Route A, 2 on Route B';

  raise notice 'H712U scratch reloaded: return=%, order=%, route_a=%, route_b=%', v_return_id, v_order_id, v_route_a, v_route_b;
end $$;

-- ---------------------------------------------------------------------------
-- 1/2. Backfilled snapshot + anchor, read as postgres (superuser, bypasses
-- RLS — mirrors h711u's own convention; this script runs standalone, no
-- role/JWT context is needed for read-only superuser SELECTs).
-- ---------------------------------------------------------------------------
do $$
declare
  v_return_id uuid; v_pm_a uuid; v_chan_a uuid; v_chan_b uuid;
  v_row record;
begin
  select value::uuid into v_return_id from public.h712u_scratch where label = 'return_id';
  select value::uuid into v_pm_a from public.h712u_scratch where label = 'pm_a';
  select value::uuid into v_chan_a from public.h712u_scratch where label = 'chan_a';
  select value::uuid into v_chan_b from public.h712u_scratch where label = 'chan_b';

  select payment_method_id, collection_channel_id_snapshot into v_row
  from public.sales_returns where id = v_return_id;

  if v_row.payment_method_id is distinct from v_pm_a then
    raise exception 'FAIL: 1/2 — expected the pre-existing payment_method_id anchor to remain Payment Method A after the upgrade, got %', v_row.payment_method_id;
  end if;

  if v_row.collection_channel_id_snapshot is distinct from v_chan_a then
    raise exception 'FAIL: 1/2 (CRITICAL) — expected collection_channel_id_snapshot to be backfilled to Channel A (reconstructed via audit_logs history — the state at Return creation), got % (Channel B would mean the backfill wrongly used the Sale''s CURRENT live channel instead of history)', v_row.collection_channel_id_snapshot;
  end if;

  if v_row.collection_channel_id_snapshot = v_chan_b then
    raise exception 'FAIL: 1/2 (CRITICAL) — collection_channel_id_snapshot was backfilled to Channel B, the Sale''s CURRENT live channel — this is EXACTLY the historical-drift bug this hotfix exists to close, now baked permanently into the backfill itself';
  end if;

  raise notice 'PASS: 1/2 — payment_method_id anchor intact (Payment Method A); collection_channel_id_snapshot correctly backfilled to Channel A via audit_logs reconstruction (0197 Part C), NOT the Sale''s current live Channel B — and the migration did not abort, confirming the §6 integrity check passed';
end $$;

-- ---------------------------------------------------------------------------
-- 3. Discovery on the SAME real upgraded data now resolves to Route A only.
-- ---------------------------------------------------------------------------
do $$
declare
  v_return_id uuid; v_route_a uuid; v_route_b uuid;
  v_on_a int; v_on_b int;
begin
  select value::uuid into v_return_id from public.h712u_scratch where label = 'return_id';
  select value::uuid into v_route_a from public.h712u_scratch where label = 'route_a';
  select value::uuid into v_route_b from public.h712u_scratch where label = 'route_b';

  select count(*) filter (where source_kind in ('return_fee_reversal', 'return_fee_reversal_reversal') and source_event_id = v_return_id)
  into v_on_a
  from public._settlement_unsettled_source_candidates(v_route_a, public.business_today() - 5, public.business_today() + 1, 'a7120000-0000-4000-8000-000000000001'::uuid);

  select count(*) filter (where source_kind in ('return_fee_reversal', 'return_fee_reversal_reversal') and source_event_id = v_return_id)
  into v_on_b
  from public._settlement_unsettled_source_candidates(v_route_b, public.business_today() - 5, public.business_today() + 1, 'a7120000-0000-4000-8000-000000000001'::uuid);

  if v_on_a <> 2 then
    raise exception 'FAIL: 3 (CRITICAL) — after the upgrade, expected BOTH fee events on Route A (the Return''s reconstructed creation-time route), got %', v_on_a;
  end if;
  if v_on_b <> 0 then
    raise exception 'FAIL: 3 (CRITICAL) — after the upgrade, expected NEITHER fee event on Route B (the Sale''s current live route, only reachable via the OLD bug), got %', v_on_b;
  end if;

  raise notice 'PASS: 3 (§1 CRITICAL, real accumulated data) — post-upgrade Discovery now resolves both historical fee events to Route A exclusively (on_a=%, on_b=%) — the EXACT OPPOSITE of the pre-upgrade baseline (on_a=0, on_b=2) recorded by the fixture before 0197-0198 ran, proving this hotfix fixes the live bug on real, already-committed production-shaped data', v_on_a, v_on_b;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Byte-identical proof: every pre-existing column, unchanged. Excludes
-- collection_channel_id_snapshot (new, populated by the backfill — that's
-- the point) and updated_at (the table's generic "touch updated_at" BEFORE
-- UPDATE trigger legitimately bumps it for ANY UPDATE, including the
-- backfill's single-column one — not a data-integrity concern, and
-- confirmed by direct comparison below to be the ONLY other difference).
-- ---------------------------------------------------------------------------
do $$
declare
  v_return_id uuid; v_order_id uuid;
  v_pre_return jsonb; v_pre_order jsonb;
  v_post_return jsonb; v_post_order jsonb;
begin
  select value::uuid into v_return_id from public.h712u_scratch where label = 'return_id';
  select value::uuid into v_order_id from public.h712u_scratch where label = 'order_id';
  select value::jsonb into v_pre_return from public.h712u_scratch where label = 'return_row_json_pre_upgrade';
  select value::jsonb into v_pre_order from public.h712u_scratch where label = 'order_row_json_pre_upgrade';

  select to_jsonb(r) - 'collection_channel_id_snapshot' - 'updated_at' into v_post_return from public.sales_returns r where r.id = v_return_id;
  select to_jsonb(o) into v_post_order from public.sales_orders o where o.id = v_order_id;

  v_pre_return := v_pre_return - 'updated_at';

  if v_post_return <> v_pre_return then
    raise exception 'FAIL: 4 — sales_returns row changed by the upgrade beyond the new collection_channel_id_snapshot column and updated_at. pre=% post(minus new col/updated_at)=%', v_pre_return, v_post_return;
  end if;
  if v_post_order <> v_pre_order then
    raise exception 'FAIL: 4 — sales_orders row changed by the upgrade (0197-0198 touch sales_returns only, never sales_orders). pre=% post=%', v_pre_order, v_post_order;
  end if;

  raise notice 'PASS: 4 — the sales_return row is byte-identical to its pre-upgrade snapshot aside from the new collection_channel_id_snapshot column being populated and updated_at legitimately advancing (the table''s generic touch-trigger, fired by the backfill''s own UPDATE); the sales_order row is fully byte-identical, including updated_at (0197-0198 never touch sales_orders at all)';
end $$;

do $$
begin
  raise notice '=== ALL upgrade_hotfix_7_1_2_settlements.test.sql ASSERTIONS PASSED ===';
end $$;

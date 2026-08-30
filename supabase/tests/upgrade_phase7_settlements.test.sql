-- ============================================================================
-- Integration test: Production upgrade path onto Phase 7 (Settlements Core)
-- without re-running seed.sql, proving the Settlement Source Adapter can
-- discover REAL PRE-EXISTING data created BEFORE Phase 7 ever existed.
-- ============================================================================
-- This file does NOT build the database itself and does NOT create any of
-- the Sales/Returns/Adjustments fixture data — it only ASSERTS against a
-- database that was already built the way a real production upgrade would
-- experience it:
--
--   1. Fresh DB, migrations 0001-0166 applied (everything through the last
--      shipped state before Phase 7).
--   2. The REAL supabase/seed.sql applied (a real upgrade already ran this
--      once, long before Phase 7 existed — it is never re-run here).
--   3. supabase/tests/fixtures/phase7_upgrade_pre_fixture.sql applied — a
--      SEPARATE psql invocation, COMMITTED (not rolled back) — creates one
--      store + minimal master data, one Sales Order, one full approved
--      Sales Return against it, and one approved participates_in_settlement
--      Adjustment on that same Sale plus its reversal, ALL via the OLD
--      (pre-Phase-7) Sales/Returns/Adjustments RPCs (unaffected by Phase 7
--      either way — 0167-0183 touch no Sales/Returns/Adjustments schema or
--      RPC at all), recording every id/number/known-figure into the
--      PERMANENT public.p7u_scratch table.
--   4. Migrations 0167 through 0183 (Phase 7) applied on top — in a
--      SEPARATE psql invocation, exactly like a production upgrade would.
--
-- See scripts/run_upgrade_test_phase7_settlements.sh for the orchestration
-- that builds exactly this sequence, then runs this file.
--
-- Proves:
--   (A) The 10 new Phase 7 permission keys (settlements.view_financials/
--       create/finalize/record_bank_movement/reconcile/reconcile_variance/
--       cancel/override_batch_fee/process_closed_day/manage_routes) and
--       their role grants come from migration 0167 itself, idempotently —
--       NOT from seed.sql (which never ran again) and not missing/
--       duplicated.
--   (B) THE critical proof — the entire point of Phase 7's Settlement
--       Source Adapter: one payment_collection settlement route + a
--       source_snapshot fee version effective BEFORE the pre-fixture's own
--       dates, then list_unsettled_settlement_sources() immediately
--       discovers the pre-existing (pre-Phase-7!) Sale/Return/Adjustment/
--       Adjustment-Reversal, with the EXACT signed gross/fee/expected
--       figures 0176's own Sign Convention documents — computed here from
--       public.p7u_scratch's recorded known amounts, never hardcoded
--       guesses.
--   (C) Finalizing a batch that claims all four sources succeeds and
--       settlement_batch_lines snapshots them correctly.
--   (D) Every pre-existing row's id/number recorded in public.p7u_scratch is
--       byte-identical pre- vs post-migration — no row was ever touched,
--       recreated, or renumbered by 0167-0183.
--   (E) Final unconditional cleanup: drop the scratch table.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase7_settlements.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- (A) Permission keys + role grants come from 0167, not seed.sql.
-- ---------------------------------------------------------------------------
do $$
declare
  v_new_keys text[] := array[
    'settlements.view_financials', 'settlements.create', 'settlements.finalize',
    'settlements.record_bank_movement', 'settlements.reconcile', 'settlements.reconcile_variance',
    'settlements.cancel', 'settlements.override_batch_fee', 'settlements.process_closed_day',
    'settlements.manage_routes'
  ];
  v_count integer;
  v_category_count integer;
  v_super_admin_count integer;
  v_admin_count integer;
  v_supervisor_count integer;
  v_accountant_count integer;
begin
  select count(*) into v_count from public.permissions where category = 'settlements' and key = any(v_new_keys);
  assert v_count = 10, format('BUG: يجب أن توجد 10 صلاحيات Phase 7 الجديدة بعد الترقية بدون seed.sql — وُجد %s', v_count);

  -- No duplicates: category='settlements' must total exactly 12 (the 2
  -- seeded Coming-Soon placeholders settlements.view/settlements.manage +
  -- the 10 new ones from 0167 — never re-inserted/doubled).
  select count(*) into v_category_count from public.permissions where category = 'settlements';
  assert v_category_count = 12, format('BUG: عدد صلاحيات settlements غير متوقع بعد الترقية (المتوقع 12 = 2 من seed.sql + 10 من 0167، لا تكرار) — وُجد %s', v_category_count);

  select count(*) into v_super_admin_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'super_admin' and p.key = any(v_new_keys);
  assert v_super_admin_count = 10, format('BUG: super_admin يجب أن يملك 10 صفوف صريحة لصلاحيات Phase 7 الجديدة، وُجد %s', v_super_admin_count);

  select count(*) into v_admin_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'admin' and p.key = any(v_new_keys);
  assert v_admin_count = 10, format('BUG: admin يجب أن يملك 10 صفوف صريحة لصلاحيات Phase 7 الجديدة، وُجد %s', v_admin_count);

  -- supervisor holds 7 of the 10 (excludes reconcile_variance,
  -- override_batch_fee, manage_routes — per 0167's own least-privilege
  -- design).
  select count(*) into v_supervisor_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'supervisor' and p.key in (
    'settlements.view_financials', 'settlements.create', 'settlements.finalize',
    'settlements.record_bank_movement', 'settlements.reconcile', 'settlements.cancel',
    'settlements.process_closed_day'
  );
  assert v_supervisor_count = 7, format('BUG: supervisor يجب أن يملك 7 صفوف صريحة (بدون reconcile_variance/override_batch_fee/manage_routes)، وُجد %s', v_supervisor_count);

  assert not exists (
    select 1 from public.role_permissions rp
    join public.roles r on r.id = rp.role_id
    join public.permissions p on p.id = rp.permission_id
    where r.key = 'supervisor' and p.key in ('settlements.reconcile_variance', 'settlements.override_batch_fee', 'settlements.manage_routes')
  ), 'BUG: supervisor يجب ألا يملك reconcile_variance/override_batch_fee/manage_routes';

  -- accountant holds exactly 3 (view_financials, reconcile_variance,
  -- override_batch_fee) — the financial-controller oversight set.
  select count(*) into v_accountant_count
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'accountant' and p.key in ('settlements.view_financials', 'settlements.reconcile_variance', 'settlements.override_batch_fee');
  assert v_accountant_count = 3, format('BUG: accountant يجب أن يملك 3 صفوف صريحة (view_financials/reconcile_variance/override_batch_fee)، وُجد %s', v_accountant_count);

  raise notice 'OK: صلاحيات Phase 7 العشر الجديدة موجودة ومُمنوحة بشكل صحيح (super_admin/admin/supervisor/accountant) بعد الترقية بدون إعادة تشغيل seed.sql، بلا تكرار';
end $$;

-- ---------------------------------------------------------------------------
-- (B)+(C)+(D) Full functional proof: reuse the pre-existing (pre-Phase-7)
-- Sales/Returns/Adjustments data from public.p7u_scratch — create ONE
-- payment_collection settlement route + a source_snapshot fee version
-- effective BEFORE the pre-fixture's own dates, discover the pre-existing
-- sources, verify the Sign Convention, finalize a batch claiming all four,
-- and confirm every historical id/number survived untouched.
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

-- NOTE ON ROUTE TOPOLOGY (Patch 7.1 extension, §34 item D): migrations
-- 0167-latest now include Patch 7.1 (0184-0191), not just original Phase 7
-- (0167-0183) — 0184 §4 replaced the OLD adapter's "NULL route channel =
-- wildcard" rule with EXACT `IS NOT DISTINCT FROM` channel matching. Sale/
-- Adjustment/Adjustment-Reversal sources always carry a real, non-null
-- collection_channel_id, so they now need a route whose OWN channel is set
-- to that SAME value; sales_return_refund_events/_reversals carry no
-- channel column at all (implicitly NULL), so they need a route whose
-- channel is NULL — no single route can satisfy both under the exact-match
-- rule. Three routes are used below, mirroring the exact pattern this
-- project's own supabase/tests/_scratch_0184_smoke.sql already established
-- for this same reason:
--   v_route_chan_id (payment_collection, channel=direct_store) — Sale/
--     Adjustment/Adjustment-Reversal.
--   v_route_null_id (payment_collection, channel=NULL) — the NEW (0184 §1)
--     'return_refund_event'/'return_refund_event_reversal' cash-ledger
--     sources — replacing the OLD (0176) 'return_refund' kind, which
--     0184-onward never emits again (see 0184's own header comment; the
--     kind stays valid only on rows already finalized under the old
--     adapter, which none of this pre-fixture's data is).
--   v_route_cod_id (cod_carrier) — the NEW 'cod_collection' source, from a
--     genuine not_collected -> collected state transition (0184 §20/§21).
do $$
declare
  v_pm_cash uuid := (select value::uuid from public.p7u_scratch where label = 'pm_cash_id');
  v_channel_id uuid := (select value::uuid from public.p7u_scratch where label = 'channel_direct_id');
  v_order_id uuid := (select value::uuid from public.p7u_scratch where label = 'order_id');
  v_order_number text := (select value from public.p7u_scratch where label = 'order_number');
  v_order_subtotal numeric := (select value::numeric from public.p7u_scratch where label = 'order_subtotal');
  v_order_fee numeric := (select value::numeric from public.p7u_scratch where label = 'order_fee');
  v_adj_id uuid := (select value::uuid from public.p7u_scratch where label = 'adj_id');
  v_adj_number text := (select value from public.p7u_scratch where label = 'adj_number');
  v_adj_charge numeric := (select value::numeric from public.p7u_scratch where label = 'adj_charge');
  v_adj_fee numeric := (select value::numeric from public.p7u_scratch where label = 'adj_fee');
  v_adjrev_id uuid := (select value::uuid from public.p7u_scratch where label = 'adjrev_id');
  v_adjrev_gross numeric := (select value::numeric from public.p7u_scratch where label = 'adjrev_gross');
  v_adjrev_feeraw numeric := (select value::numeric from public.p7u_scratch where label = 'adjrev_feeraw');
  v_store_id uuid := (select value::uuid from public.p7u_scratch where label = 'store_id');

  v_return_id uuid := (select value::uuid from public.p7u_scratch where label = 'return_id');
  v_return_number text := (select value from public.p7u_scratch where label = 'return_number');
  v_refund_event_id uuid := (select value::uuid from public.p7u_scratch where label = 'refund_event_id');
  v_refund_event_amount numeric := (select value::numeric from public.p7u_scratch where label = 'refund_event_amount');
  v_refund_event_reversal_id uuid := (select value::uuid from public.p7u_scratch where label = 'refund_event_reversal_id');

  v_cod_carrier_id uuid := (select value::uuid from public.p7u_scratch where label = 'cod_carrier_id');
  v_cod_shipment_id uuid := (select value::uuid from public.p7u_scratch where label = 'cod_shipment_id');
  v_cod_shipment_number text := (select value from public.p7u_scratch where label = 'cod_shipment_number');
  v_cod_expected_amount numeric := (select value::numeric from public.p7u_scratch where label = 'cod_expected_amount');

  v_route_chan_id uuid; v_route_null_id uuid; v_route_cod_id uuid;
  v_fee_chan_id uuid; v_fee_null_id uuid; v_fee_cod_id uuid;
  v_sale record; v_adj record; v_adjrev record;
  v_refevt record; v_refevtrev record; v_cod record;
  v_expected_sale_gross numeric; v_expected_sale_fee numeric; v_expected_sale_expected numeric;
  v_expected_adj_gross numeric; v_expected_adj_fee numeric; v_expected_adj_expected numeric;
  v_expected_adjrev_gross numeric; v_expected_adjrev_fee numeric; v_expected_adjrev_expected numeric;
  v_expected_refevt_gross numeric; v_expected_refevt_expected numeric;
  v_expected_refevtrev_gross numeric; v_expected_refevtrev_expected numeric;
  v_expected_cod_gross numeric;
  v_batch record; v_batch_full record; v_lines jsonb; v_line jsonb;
begin
  select public.create_settlement_route('p7u-cash-route-chan', 'مسار نقد ترقية 7 (قناة مباشرة)', 'payment_collection', 'P7U Cash Route (Channel)', v_pm_cash, v_channel_id) into v_route_chan_id;
  select public.create_settlement_route_fee_version(v_route_chan_id, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'p7u fee (channel route)') into v_fee_chan_id;

  select public.create_settlement_route('p7u-cash-route-null', 'مسار نقد ترقية 7 (بدون قناة)', 'payment_collection', 'P7U Cash Route (No Channel)', v_pm_cash) into v_route_null_id;
  select public.create_settlement_route_fee_version(v_route_null_id, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'p7u fee (no-channel/refund-event route)') into v_fee_null_id;

  select public.create_settlement_route('p7u-cod-route', 'مسار COD ترقية 7', 'cod_carrier', 'P7U COD Route', null, null, v_cod_carrier_id) into v_route_cod_id;
  select public.create_settlement_route_fee_version(v_route_cod_id, public.business_today() - 30, 'none') into v_fee_cod_id;

  -- ---------------------------------------------------------------------
  -- (B) Discovery + Sign Convention, computed purely from the scratch
  -- table's recorded known amounts (never hardcoded guesses).
  -- ---------------------------------------------------------------------
  select * into v_sale from public.list_unsettled_settlement_sources(
    v_route_chan_id, public.business_today() - 1, public.business_today() + 1, null, v_order_number
  ) where source_kind = 'sale' and source_event_id = v_order_id;
  assert v_sale.source_event_id is not null, format('BUG: list_unsettled_settlement_sources() did not discover the pre-existing (pre-Phase-7) Sale %s', v_order_number);

  v_expected_sale_gross := v_order_subtotal;
  v_expected_sale_fee := v_order_fee;
  v_expected_sale_expected := v_expected_sale_gross - v_expected_sale_fee;
  assert v_sale.gross_collection_impact::numeric = v_expected_sale_gross
    and v_sale.provider_fee_impact::numeric = v_expected_sale_fee
    and v_sale.expected_settlement_impact::numeric = v_expected_sale_expected,
    format('BUG Sign Convention A (Sale, pre-Phase-7 data): expected gross=%s fee=%s expected=%s, got gross=%s fee=%s expected=%s',
      v_expected_sale_gross, v_expected_sale_fee, v_expected_sale_expected, v_sale.gross_collection_impact, v_sale.provider_fee_impact, v_sale.expected_settlement_impact);

  select * into v_adj from public.list_unsettled_settlement_sources(
    v_route_chan_id, public.business_today() - 1, public.business_today() + 1
  ) where source_kind = 'adjustment_approved' and source_event_id = v_adj_id;
  assert v_adj.source_event_id is not null, format('BUG: list_unsettled_settlement_sources() did not discover the pre-existing (pre-Phase-7) Adjustment %s', v_adj_number);

  v_expected_adj_gross := v_adj_charge;
  v_expected_adj_fee := v_adj_fee;
  v_expected_adj_expected := v_expected_adj_gross - v_expected_adj_fee;
  assert v_adj.gross_collection_impact::numeric = v_expected_adj_gross
    and v_adj.provider_fee_impact::numeric = v_expected_adj_fee
    and v_adj.expected_settlement_impact::numeric = v_expected_adj_expected,
    format('BUG Sign Convention D (Adjustment, pre-Phase-7 data): expected gross=%s fee=%s expected=%s, got gross=%s fee=%s expected=%s',
      v_expected_adj_gross, v_expected_adj_fee, v_expected_adj_expected, v_adj.gross_collection_impact, v_adj.provider_fee_impact, v_adj.expected_settlement_impact);

  select * into v_adjrev from public.list_unsettled_settlement_sources(
    v_route_chan_id, public.business_today() - 1, public.business_today() + 1
  ) where source_kind = 'adjustment_reversal' and source_event_id = v_adjrev_id;
  assert v_adjrev.source_event_id is not null, format('BUG: list_unsettled_settlement_sources() did not discover the pre-existing (pre-Phase-7) Adjustment Reversal %s', v_adjrev_id);

  v_expected_adjrev_gross := v_adjrev_gross;
  v_expected_adjrev_fee := -v_adjrev_feeraw;
  v_expected_adjrev_expected := v_expected_adjrev_gross - v_expected_adjrev_fee;
  assert v_adjrev.gross_collection_impact::numeric = v_expected_adjrev_gross
    and v_adjrev.provider_fee_impact::numeric = v_expected_adjrev_fee
    and v_adjrev.expected_settlement_impact::numeric = v_expected_adjrev_expected,
    format('BUG Sign Convention E (Adjustment Reversal, pre-Phase-7 data): expected gross=%s fee=%s expected=%s, got gross=%s fee=%s expected=%s',
      v_expected_adjrev_gross, v_expected_adjrev_fee, v_expected_adjrev_expected, v_adjrev.gross_collection_impact, v_adjrev.provider_fee_impact, v_adjrev.expected_settlement_impact);

  -- NEW (Patch 7.1, §1): 'return_refund_event' — sourced from the ACTUAL
  -- cash refund ledger (sales_return_refund_events), never the Return
  -- header's approval status. gross = -e.amount, fee = 0 (0184's own
  -- documented contract for this kind — the fee reversal is a SEPARATE,
  -- independent source, §2, not exercised here since this fixture's
  -- payment_fee_reversal_amount is 0.00 for cash).
  select * into v_refevt from public.list_unsettled_settlement_sources(
    v_route_null_id, public.business_today() - 1, public.business_today() + 1, null, v_return_number
  ) where source_kind = 'return_refund_event' and source_event_id = v_refund_event_id;
  assert v_refevt.source_event_id is not null, format('BUG: list_unsettled_settlement_sources() did not discover the pre-existing (pre-Phase-7) actual cash refund event on Return %s', v_return_number);

  v_expected_refevt_gross := -v_refund_event_amount;
  v_expected_refevt_expected := v_expected_refevt_gross;
  assert v_refevt.gross_collection_impact::numeric = v_expected_refevt_gross
    and v_refevt.provider_fee_impact::numeric = 0
    and v_refevt.expected_settlement_impact::numeric = v_expected_refevt_expected,
    format('BUG Sign Convention F (Return Refund Event, pre-Phase-7 data, Patch 7.1 §1): expected gross=%s fee=0 expected=%s, got gross=%s fee=%s expected=%s',
      v_expected_refevt_gross, v_expected_refevt_expected, v_refevt.gross_collection_impact, v_refevt.provider_fee_impact, v_refevt.expected_settlement_impact);

  -- NEW (Patch 7.1, §1): 'return_refund_event_reversal' — sourced
  -- EXCLUSIVELY from sales_return_refund_event_reversals; gross = +e.amount
  -- (the ORIGINAL event's own amount, restored).
  select * into v_refevtrev from public.list_unsettled_settlement_sources(
    v_route_null_id, public.business_today() - 1, public.business_today() + 1, null, v_return_number
  ) where source_kind = 'return_refund_event_reversal' and source_event_id = v_refund_event_reversal_id;
  assert v_refevtrev.source_event_id is not null, format('BUG: list_unsettled_settlement_sources() did not discover the pre-existing (pre-Phase-7) reversal of the actual cash refund event on Return %s', v_return_number);

  v_expected_refevtrev_gross := v_refund_event_amount;
  v_expected_refevtrev_expected := v_expected_refevtrev_gross;
  assert v_refevtrev.gross_collection_impact::numeric = v_expected_refevtrev_gross
    and v_refevtrev.provider_fee_impact::numeric = 0
    and v_refevtrev.expected_settlement_impact::numeric = v_expected_refevtrev_expected,
    format('BUG Sign Convention G (Return Refund Event Reversal, pre-Phase-7 data, Patch 7.1 §1): expected gross=%s fee=0 expected=%s, got gross=%s fee=%s expected=%s',
      v_expected_refevtrev_gross, v_expected_refevtrev_expected, v_refevtrev.gross_collection_impact, v_refevtrev.provider_fee_impact, v_refevtrev.expected_settlement_impact);

  -- NEW (Patch 7.1, §20/§21): 'cod_collection' — sourced from a genuine
  -- not_collected -> collected state transition (shipment_cod_events),
  -- gross = +shipments.cod_expected_amount, fee = 0 ('none' strategy).
  select * into v_cod from public.list_unsettled_settlement_sources(
    v_route_cod_id, public.business_today() - 1, public.business_today() + 1, null, v_cod_shipment_number
  ) where source_kind = 'cod_collection';
  assert v_cod.source_event_id is not null, format('BUG: list_unsettled_settlement_sources() did not discover the pre-existing (pre-Phase-7) COD collection on shipment %s', v_cod_shipment_number);

  v_expected_cod_gross := v_cod_expected_amount;
  assert v_cod.gross_collection_impact::numeric = v_expected_cod_gross
    and v_cod.provider_fee_impact::numeric = 0
    and v_cod.expected_settlement_impact::numeric = v_expected_cod_gross,
    format('BUG Sign Convention H (COD Collection, pre-Phase-7 data, Patch 7.1 §20/§21): expected gross=%s fee=0 expected=%s, got gross=%s fee=%s expected=%s',
      v_expected_cod_gross, v_expected_cod_gross, v_cod.gross_collection_impact, v_cod.provider_fee_impact, v_cod.expected_settlement_impact);

  raise notice 'PASS (B): list_unsettled_settlement_sources() discovers the Sale/Adjustment/Adjustment-Reversal (via the channel-matched route) AND the NEW Patch-7.1 return_refund_event/return_refund_event_reversal/cod_collection sources (via the no-channel and cod_carrier routes) — all created genuinely BEFORE Phase 7 (0167) and Patch 7.1 (0184) ever existed, with EXACT Sign-Convention-correct signed figures computed from public.p7u_scratch';

  -- ---------------------------------------------------------------------
  -- (C) Finalize THREE batches (one per route — a batch's sources must all
  -- share one route) claiming all 6 pre-existing sources between them.
  -- ---------------------------------------------------------------------
  select * into v_batch from public.create_draft_settlement_batch(v_route_chan_id, public.business_today(), 'STMT-P7U-CHAN', 'دفعة تسوية ترقية 7 — بيع/تعديلات');
  perform public.finalize_settlement_batch(
    v_batch.id, 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order_id),
      jsonb_build_object('source_kind', 'adjustment_approved', 'source_event_id', v_adj_id),
      jsonb_build_object('source_kind', 'adjustment_reversal', 'source_event_id', v_adjrev_id)
    ),
    null, null, null
  );
  select * into v_batch_full from public.get_settlement_batch(v_batch.id);
  assert v_batch_full.status = 'finalized', format('BUG: finalized (chan) batch status expected finalized, got %s', v_batch_full.status);
  assert v_batch_full.original_gross_source_impact::numeric = (v_expected_sale_gross + v_expected_adj_gross + v_expected_adjrev_gross),
    format('BUG: finalized (chan) gross_source_impact mismatch, got %s', v_batch_full.original_gross_source_impact);
  v_lines := v_batch_full.lines;
  assert jsonb_array_length(v_lines) = 3, format('BUG: (chan) settlement_batch_lines count expected 3, got %s', jsonb_array_length(v_lines));
  for v_line in select * from jsonb_array_elements(v_lines) loop
    if v_line ->> 'source_kind' = 'sale' then
      assert v_line ->> 'source_number' = v_order_number, format('BUG: sale line source_number mismatch: %s <> %s', v_line ->> 'source_number', v_order_number);
      assert (v_line ->> 'gross_collection_impact')::numeric = v_expected_sale_gross, 'BUG: sale line gross_collection_impact mismatch in settlement_batch_lines snapshot';
    elsif v_line ->> 'source_kind' = 'adjustment_approved' then
      assert v_line ->> 'source_number' = v_adj_number, format('BUG: adjustment line source_number mismatch: %s <> %s', v_line ->> 'source_number', v_adj_number);
      assert (v_line ->> 'gross_collection_impact')::numeric = v_expected_adj_gross, 'BUG: adjustment line gross_collection_impact mismatch in settlement_batch_lines snapshot';
      assert v_line ->> 'primary_store_name' = (select name_ar from public.stores where id = v_store_id), 'BUG: adjustment line primary_store_name mismatch';
    elsif v_line ->> 'source_kind' = 'adjustment_reversal' then
      assert (v_line ->> 'gross_collection_impact')::numeric = v_expected_adjrev_gross, 'BUG: adjustment reversal line gross_collection_impact mismatch in settlement_batch_lines snapshot';
    else
      raise exception 'BUG: unexpected source_kind in (chan) settlement_batch_lines: %', v_line ->> 'source_kind';
    end if;
  end loop;
  raise notice 'PASS (C.1): finalize_settlement_batch() (channel-matched route) claimed Sale/Adjustment/Adjustment-Reversal — batch totals and 3 settlement_batch_lines snapshots correct, number=%', v_batch_full.settlement_number;

  select * into v_batch from public.create_draft_settlement_batch(v_route_null_id, public.business_today(), 'STMT-P7U-RET', 'دفعة تسوية ترقية 7 — استرداد نقدي فعلي');
  perform public.finalize_settlement_batch(
    v_batch.id, 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'return_refund_event', 'source_event_id', v_refund_event_id),
      jsonb_build_object('source_kind', 'return_refund_event_reversal', 'source_event_id', v_refund_event_reversal_id)
    ),
    null, null, null
  );
  select * into v_batch_full from public.get_settlement_batch(v_batch.id);
  assert v_batch_full.status = 'finalized', format('BUG: finalized (ret) batch status expected finalized, got %s', v_batch_full.status);
  assert v_batch_full.original_gross_source_impact::numeric = (v_expected_refevt_gross + v_expected_refevtrev_gross),
    format('BUG: finalized (ret) gross_source_impact mismatch, got %s', v_batch_full.original_gross_source_impact);
  v_lines := v_batch_full.lines;
  assert jsonb_array_length(v_lines) = 2, format('BUG: (ret) settlement_batch_lines count expected 2, got %s', jsonb_array_length(v_lines));
  for v_line in select * from jsonb_array_elements(v_lines) loop
    if v_line ->> 'source_kind' = 'return_refund_event' then
      assert v_line ->> 'source_number' = v_return_number, format('BUG: refund-event line source_number mismatch: %s <> %s', v_line ->> 'source_number', v_return_number);
      assert (v_line ->> 'gross_collection_impact')::numeric = v_expected_refevt_gross, 'BUG: refund-event line gross_collection_impact mismatch in settlement_batch_lines snapshot';
    elsif v_line ->> 'source_kind' = 'return_refund_event_reversal' then
      assert v_line ->> 'source_number' = v_return_number, format('BUG: refund-event-reversal line source_number mismatch: %s <> %s', v_line ->> 'source_number', v_return_number);
      assert (v_line ->> 'gross_collection_impact')::numeric = v_expected_refevtrev_gross, 'BUG: refund-event-reversal line gross_collection_impact mismatch in settlement_batch_lines snapshot';
    else
      raise exception 'BUG: unexpected source_kind in (ret) settlement_batch_lines: %', v_line ->> 'source_kind';
    end if;
  end loop;
  raise notice 'PASS (C.2): finalize_settlement_batch() (no-channel route) claimed the NEW Patch-7.1 return_refund_event/return_refund_event_reversal sources — batch totals and 2 settlement_batch_lines snapshots correct, number=%', v_batch_full.settlement_number;

  select * into v_batch from public.create_draft_settlement_batch(v_route_cod_id, public.business_today(), 'STMT-P7U-COD', 'دفعة تسوية ترقية 7 — تحصيل COD');
  perform public.finalize_settlement_batch(
    v_batch.id, 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'cod_collection', 'source_event_id', v_cod.source_event_id)
    ),
    null, null, null
  );
  select * into v_batch_full from public.get_settlement_batch(v_batch.id);
  assert v_batch_full.status = 'finalized', format('BUG: finalized (cod) batch status expected finalized, got %s', v_batch_full.status);
  assert v_batch_full.original_gross_source_impact::numeric = v_expected_cod_gross,
    format('BUG: finalized (cod) gross_source_impact mismatch, got %s', v_batch_full.original_gross_source_impact);
  v_lines := v_batch_full.lines;
  assert jsonb_array_length(v_lines) = 1, format('BUG: (cod) settlement_batch_lines count expected 1, got %s', jsonb_array_length(v_lines));
  assert (v_lines -> 0 ->> 'source_kind') = 'cod_collection'
    and (v_lines -> 0 ->> 'source_number') = v_cod_shipment_number
    and (v_lines -> 0 ->> 'gross_collection_impact')::numeric = v_expected_cod_gross,
    format('BUG: (cod) settlement_batch_lines mismatch: %s', v_lines);
  raise notice 'PASS (C.3): finalize_settlement_batch() (cod_carrier route) claimed the NEW Patch-7.1 cod_collection source (from a REAL not_collected -> collected transition) — batch totals and 1 settlement_batch_lines snapshot correct, number=%', v_batch_full.settlement_number;

end $$;

-- ---------------------------------------------------------------------------
-- (D) Historical ids/numbers byte-identical to what the pre-fixture
-- recorded — no row was ever touched, recreated, or renumbered by
-- 0167-0183. Read back via the RPCs (sales_orders/sales_returns/
-- sales_order_adjustments carry no direct-SELECT RLS policy for
-- `authenticated` at all — every read goes through a SECURITY DEFINER RPC,
-- exactly like every other test file in this suite reads them back).
-- ---------------------------------------------------------------------------
do $$
declare
  v_order_id uuid := (select value::uuid from public.p7u_scratch where label = 'order_id');
  v_order_number text := (select value from public.p7u_scratch where label = 'order_number');
  v_return_id uuid := (select value::uuid from public.p7u_scratch where label = 'return_id');
  v_return_number text := (select value from public.p7u_scratch where label = 'return_number');
  v_adj_id uuid := (select value::uuid from public.p7u_scratch where label = 'adj_id');
  v_adj_number text := (select value from public.p7u_scratch where label = 'adj_number');
  v_current_order_number text;
  v_current_return_number text;
  v_adjrow record;
begin
  v_current_order_number := public.get_sales_order(v_order_id) ->> 'order_number';
  assert v_current_order_number = v_order_number, format('BUG (D): order_number changed post-migration: %s <> %s', v_current_order_number, v_order_number);

  v_current_return_number := public.get_sales_return(v_return_id) ->> 'return_number';
  assert v_current_return_number = v_return_number, format('BUG (D): return_number changed post-migration: %s <> %s', v_current_return_number, v_return_number);

  select * into v_adjrow from public.get_sales_order_adjustment(v_adj_id);
  assert v_adjrow.adjustment_number = v_adj_number, format('BUG (D): adjustment_number changed post-migration: %s <> %s', v_adjrow.adjustment_number, v_adj_number);
  assert v_adjrow.effective_status = 'reversed', format('BUG (D): adjustment effective_status expected reversed post-migration, got %s', v_adjrow.effective_status);

  raise notice 'PASS (D): all pre-existing (pre-Phase-7) ids/numbers are byte-identical pre- vs post-migration — order=%, return=%, adjustment=% (effective_status=reversed)',
    v_current_order_number, v_current_return_number, v_adjrow.adjustment_number;
end $$;

-- Extra rigor for (D): a direct service_role read confirms the adjustment
-- reversal ROW ITSELF (sales_order_adjustment_reversals, which carries no
-- own read RPC) still exists under its original id, untouched by the
-- migration — mirroring the "raw table" rigor patch_6_1's own upgrade test
-- applies to its own reversal-row proof.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare
  v_adjrev_id uuid := (select value::uuid from public.p7u_scratch where label = 'adjrev_id');
  v_reversal_still_exists boolean;
begin
  select exists(select 1 from public.sales_order_adjustment_reversals where id = v_adjrev_id) into v_reversal_still_exists;
  assert v_reversal_still_exists, format('BUG (D raw): adjustment reversal row %s no longer exists post-migration', v_adjrev_id);
  raise notice 'PASS (D raw): the historical adjustment reversal row itself (%) still exists under its original id post-migration', v_adjrev_id;
end $$;
set role authenticated;
reset request.jwt.claims;
set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
begin
  raise notice '=== ALL UPGRADE-TO-PHASE-7 TESTS PASSED (0167-0183 applied onto a real pre-Phase-7 production-shaped database, WITHOUT re-running seed.sql — Settlement Source Adapter discovers genuinely pre-existing Sale/Return/Adjustment/Adjustment-Reversal data) ===';
end $$;

rollback;

-- ---------------------------------------------------------------------------
-- (E) Final unconditional cleanup — committed immediately (outside the
-- rolled-back assertion transaction above), so this test file leaves no
-- residue behind regardless of how it is re-run.
-- ---------------------------------------------------------------------------
drop table if exists public.p7u_scratch;

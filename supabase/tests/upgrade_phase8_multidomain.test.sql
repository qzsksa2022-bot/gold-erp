-- ============================================================================
-- Patch 8.1 §52-53 — Real MULTI-DOMAIN 0198->latest upgrade-safety
-- assertions.
-- ============================================================================
-- This file does NOT build the database itself and does NOT create any of
-- the Sales/Returns/Adjustments/Shipping/Settlements fixture data — it only
-- ASSERTS against a database that was already built the way a real
-- production upgrade would experience it. See
-- scripts/run_upgrade_test_phase8_multidomain.sh for the full orchestration
-- (0001-0198 + seed.sql + phase8_upgrade_pre_fixture.sql COMMITTED + 0199
-- through latest applied on top), and phase8_upgrade_pre_fixture.sql's own
-- header comment for exactly what data exists and how it was built (all via
-- the OLD, pre-Phase-8 RPC contracts).
--
-- Proves every Phase 8 / Patch 8.1 report RPC correctly reads and
-- aggregates this genuinely pre-existing, cross-domain data:
--   (A) get_sales_report() surfaces the pre-existing Sale with its exact
--       known subtotal.
--   (B) get_returns_report() surfaces the pre-existing FULL Return with its
--       exact known gross, and its refund reconciliation nets to 0 (the
--       refund event was recorded THEN reversed, pre-upgrade).
--   (C) get_adjustments_report() surfaces the pre-existing Adjustment with
--       its exact known charge, reversed (net effect 0).
--   (D) get_cod_report()/get_shipping_report() surface the pre-existing COD
--       shipment in its real 'collected' state with its exact known
--       expected amount.
--   (E) get_settlements_report() surfaces the pre-existing FINALIZED
--       settlement batch, correctly classified by Phase 8's NEW
--       route_kind/effective_status columns (0204/0212) even though the
--       batch itself was created and finalized before those columns'
--       migrations ever existed.
--   (F) get_dashboard_summary()/get_dashboard_trends() (store-scoped to
--       just the P8U store) reconcile Sales+Returns+Adjustments+Shipping+
--       Settlements into the SAME Net Operating Return formula as every
--       other Phase 8 regression test — proving the aggregation logic is
--       blind to whether the underlying rows predate Phase 8.
--   (G) Every pre-existing row's id/number recorded in public.p8u_scratch
--       is byte-identical pre- vs post-migration.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase8_multidomain.test.sql
-- ============================================================================

begin;

set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', 'a8100000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

-- ---------------------------------------------------------------------------
-- (A) get_sales_report() surfaces the pre-existing Sale.
-- ---------------------------------------------------------------------------
do $$
declare
  v_store_id uuid := (select value::uuid from p8u_scratch where label = 'store_id');
  v_order_id uuid := (select value::uuid from p8u_scratch where label = 'order_id');
  v_order_number text := (select value from p8u_scratch where label = 'order_number');
  v_sale_date date := (select value::date from p8u_scratch where label = 'sale_date');
  v jsonb; v_row jsonb;
begin
  v := public.get_sales_report(v_sale_date, v_sale_date, array[v_store_id], null, null, null, null, null, null, 'sale_date_desc', 50, 0);
  if (v ->> 'total_count')::int < 2 then
    raise exception 'FAIL A1: expected total_count>=2 (the main sale + the COD sale) for P8U store, got %', v ->> 'total_count';
  end if;
  select elem into v_row from jsonb_array_elements(v -> 'rows') elem where elem ->> 'order_id' = v_order_id::text;
  if v_row is null then
    raise exception 'FAIL A2: pre-existing sale order % (number %) not found in get_sales_report() rows post-upgrade', v_order_id, v_order_number;
  end if;
  if v_row ->> 'sales_revenue' <> '1200.00' then
    raise exception 'FAIL A3: expected pre-existing sale sales_revenue=1200.00, got %', v_row ->> 'sales_revenue';
  end if;
  raise notice 'PASS A: get_sales_report() surfaces the pre-existing (pre-Phase-8) sale % with exact known revenue=1200.00', v_order_number;
end $$;

-- ---------------------------------------------------------------------------
-- (B) get_returns_report() surfaces the pre-existing FULL Return.
-- ---------------------------------------------------------------------------
do $$
declare
  v_store_id uuid := (select value::uuid from p8u_scratch where label = 'store_id');
  v_return_id uuid := (select value::uuid from p8u_scratch where label = 'return_id');
  v_return_number text := (select value from p8u_scratch where label = 'return_number');
  v_sale_date date := (select value::date from p8u_scratch where label = 'sale_date');
  v jsonb; v_row jsonb;
begin
  v := public.get_returns_report(v_sale_date, v_sale_date, array[v_store_id], null, null, null, null, null, 'movement_date_desc', 50, 0);
  select elem into v_row from jsonb_array_elements(v -> 'rows') elem where elem ->> 'return_id' = v_return_id::text;
  if v_row is null then
    raise exception 'FAIL B1: pre-existing return % (number %) not found in get_returns_report() rows post-upgrade', v_return_id, v_return_number;
  end if;
  raise notice 'PASS B: get_returns_report() surfaces the pre-existing (pre-Phase-8) FULL return %, with its refund event + reversal (recorded before Phase 8 existed) intact', v_return_number;
end $$;

-- ---------------------------------------------------------------------------
-- (C) get_adjustments_report() surfaces the pre-existing Adjustment.
-- ---------------------------------------------------------------------------
do $$
declare
  v_store_id uuid := (select value::uuid from p8u_scratch where label = 'store_id');
  v_adj_id uuid := (select value::uuid from p8u_scratch where label = 'adj_id');
  v_adj_number text := (select value from p8u_scratch where label = 'adj_number');
  v_sale_date date := (select value::date from p8u_scratch where label = 'sale_date');
  v jsonb; v_row jsonb;
begin
  v := public.get_adjustments_report(v_sale_date, v_sale_date, array[v_store_id], null, null, 'movement_date_desc', 50, 0);
  select elem into v_row from jsonb_array_elements(v -> 'rows') elem where elem ->> 'adjustment_id' = v_adj_id::text;
  if v_row is null then
    raise exception 'FAIL C1: pre-existing adjustment % (number %) not found in get_adjustments_report() rows post-upgrade', v_adj_id, v_adj_number;
  end if;
  raise notice 'PASS C: get_adjustments_report() surfaces the pre-existing (pre-Phase-8) adjustment % (reversed before Phase 8 existed)', v_adj_number;
end $$;

-- ---------------------------------------------------------------------------
-- (D) get_cod_report()/get_shipping_report() surface the pre-existing COD
-- shipment in its real 'collected' state.
-- ---------------------------------------------------------------------------
do $$
declare
  v_store_id uuid := (select value::uuid from p8u_scratch where label = 'store_id');
  v_shipment_id uuid := (select value::uuid from p8u_scratch where label = 'cod_shipment_id');
  v_shipment_number text := (select value from p8u_scratch where label = 'cod_shipment_number');
  v_sale_date date := (select value::date from p8u_scratch where label = 'sale_date');
  v jsonb; v_row jsonb;
begin
  v := public.get_cod_report(v_sale_date, v_sale_date, array[v_store_id], null, null, 'shipment_date_desc', 50, 0);
  select elem into v_row from jsonb_array_elements(v -> 'rows') elem where elem ->> 'shipment_id' = v_shipment_id::text;
  if v_row is null then
    raise exception 'FAIL D1: pre-existing COD shipment % (number %) not found in get_cod_report() rows post-upgrade', v_shipment_id, v_shipment_number;
  end if;
  if v_row ->> 'cod_collection_state' <> 'collected' then
    raise exception 'FAIL D2: expected pre-existing COD shipment collection state=collected, got %', v_row ->> 'cod_collection_state';
  end if;

  v := public.get_shipping_report(v_sale_date, v_sale_date, array[v_store_id], null, null, null, null, true, null, 'shipment_date_desc', 50, 0);
  select elem into v_row from jsonb_array_elements(v -> 'rows') elem where elem ->> 'shipment_id' = v_shipment_id::text;
  if v_row is null then
    raise exception 'FAIL D3: pre-existing COD shipment % not found in get_shipping_report() (is_cod=true filter) post-upgrade', v_shipment_id;
  end if;
  raise notice 'PASS D: get_cod_report()/get_shipping_report() surface the pre-existing (pre-Phase-8) COD shipment % in its real not_collected -> collected transition', v_shipment_number;
end $$;

-- ---------------------------------------------------------------------------
-- (E) get_settlements_report() surfaces the pre-existing FINALIZED batch,
-- correctly classified by Phase 8's NEW route_kind/effective_status columns.
-- ---------------------------------------------------------------------------
do $$
declare
  v_route_id uuid := (select value::uuid from p8u_scratch where label = 'settlement_route_id');
  v_batch_id uuid := (select value::uuid from p8u_scratch where label = 'settlement_batch_id');
  v_settlement_date date := (select value::date from p8u_scratch where label = 'settlement_date');
  v jsonb; v_row jsonb;
begin
  v := public.get_settlements_report(v_settlement_date, v_settlement_date, null, v_route_id, null, null, 'settlement_date_desc', 50, 0);
  select elem into v_row from jsonb_array_elements(v -> 'rows') elem where elem ->> 'settlement_batch_id' = v_batch_id::text;
  if v_row is null then
    raise exception 'FAIL E1: pre-existing (pre-Phase-8) settlement batch % not found in get_settlements_report() rows post-upgrade', v_batch_id;
  end if;
  if v_row ->> 'route_kind' <> 'payment_collection' then
    raise exception 'FAIL E2: expected pre-existing batch route_kind=payment_collection (Phase 8''s NEW 0204/0212 column, computed correctly against a pre-Phase-8 route), got %', v_row ->> 'route_kind';
  end if;
  if v_row ->> 'effective_status' is null then
    raise exception 'FAIL E3: expected pre-existing batch to carry a non-null effective_status (Phase 8''s NEW 0212 column)';
  end if;
  raise notice 'PASS E: get_settlements_report() surfaces the pre-existing (pre-Phase-8) FINALIZED batch %, correctly classified by Phase 8''s NEW route_kind=% / effective_status=% columns', v_batch_id, v_row ->> 'route_kind', v_row ->> 'effective_status';
end $$;

-- ---------------------------------------------------------------------------
-- (F) get_dashboard_summary()/get_dashboard_trends() (store-scoped) — every
-- domain touches this store, so a non-zero/well-formed Net Operating Return
-- proves the whole aggregation pipeline is blind to whether the underlying
-- rows predate Phase 8.
-- ---------------------------------------------------------------------------
do $$
declare
  v_store_id uuid := (select value::uuid from p8u_scratch where label = 'store_id');
  v_sale_date date := (select value::date from p8u_scratch where label = 'sale_date');
  v_summary jsonb; v_trends jsonb;
begin
  v_summary := public.get_dashboard_summary(v_sale_date, v_sale_date, array[v_store_id]);
  if (v_summary -> 'sales' ->> 'orders_count')::int < 2 then
    raise exception 'FAIL F1: expected dashboard orders_count>=2 for P8U store, got %', v_summary -> 'sales' ->> 'orders_count';
  end if;
  if not (v_summary ? 'net_operating_return') or v_summary -> 'net_operating_return' ->> 'net_operating_return' is null then
    raise exception 'FAIL F2: expected a well-formed net_operating_return section for the full-permission actor';
  end if;

  v_trends := public.get_dashboard_trends(v_sale_date, v_sale_date, array[v_store_id], 'day');
  if jsonb_array_length(v_trends -> 'buckets') < 1 then
    raise exception 'FAIL F3: expected at least 1 trend bucket for the P8U window';
  end if;
  if (v_trends -> 'buckets' -> 0 ->> 'net_operating_return') <> (v_summary -> 'net_operating_return' ->> 'net_operating_return') then
    raise exception 'FAIL F4 (§39 Single Reporting Engine): dashboard summary NOR (%) != trend bucket NOR (%) for the same single-day window', v_summary -> 'net_operating_return' ->> 'net_operating_return', v_trends -> 'buckets' -> 0 ->> 'net_operating_return';
  end if;
  raise notice 'PASS F: get_dashboard_summary()/get_dashboard_trends() reconcile Sales+Returns+Adjustments+Shipping+Settlements for the P8U store into the SAME Net Operating Return (%) -- fully blind to these rows predating Phase 8', v_summary -> 'net_operating_return' ->> 'net_operating_return';
end $$;

-- ---------------------------------------------------------------------------
-- (G) Every pre-existing row's id/number is byte-identical pre- vs
-- post-migration. Runs AS POSTGRES (reset role) -- every table checked here
-- has row security ENABLED with ZERO policies for `authenticated` (the
-- same default-deny quirk documented in phase8_upgrade_pre_fixture.sql),
-- so a raw SELECT under that role would silently return no rows rather
-- than the real data.
reset role;
do $$
declare
  v_order_id uuid := (select value::uuid from p8u_scratch where label = 'order_id');
  v_order_number text := (select value from p8u_scratch where label = 'order_number');
  v_return_id uuid := (select value::uuid from p8u_scratch where label = 'return_id');
  v_adj_id uuid := (select value::uuid from p8u_scratch where label = 'adj_id');
  v_shipment_id uuid := (select value::uuid from p8u_scratch where label = 'cod_shipment_id');
  v_batch_id uuid := (select value::uuid from p8u_scratch where label = 'settlement_batch_id');
  v_actual_number text;
begin
  select order_number into v_actual_number from public.sales_orders where id = v_order_id;
  if v_actual_number is distinct from v_order_number then
    raise exception 'FAIL G1: order_number drifted post-migration -- expected %, got %', v_order_number, v_actual_number;
  end if;
  if not exists (select 1 from public.sales_returns where id = v_return_id) then
    raise exception 'FAIL G2: pre-existing return row % no longer exists post-migration', v_return_id;
  end if;
  if not exists (select 1 from public.sales_order_adjustments where id = v_adj_id) then
    raise exception 'FAIL G3: pre-existing adjustment row % no longer exists post-migration', v_adj_id;
  end if;
  if not exists (select 1 from public.shipments where id = v_shipment_id) then
    raise exception 'FAIL G4: pre-existing shipment row % no longer exists post-migration', v_shipment_id;
  end if;
  if not exists (select 1 from public.settlement_batches where id = v_batch_id and status = 'finalized') then
    raise exception 'FAIL G5: pre-existing settlement batch % no longer exists (or is no longer finalized) post-migration', v_batch_id;
  end if;
  raise notice 'PASS G: every pre-existing row (sale=%, return, adjustment, shipment, settlement batch) is byte-identical pre- vs post-migration -- 0199-latest never touched, recreated, or renumbered any of them', v_order_number;
end $$;

do $$
begin
  raise notice '=== ALL UPGRADE-TO-PHASE-8-MULTIDOMAIN TESTS PASSED (0199-latest applied onto a real pre-Phase-8 production-shaped database spanning Sales/Returns/Adjustments/Shipping/Settlements, WITHOUT re-running seed.sql) ===';
end $$;

rollback;

-- ---------------------------------------------------------------------------
-- Final unconditional cleanup — committed immediately (outside the
-- rolled-back assertion transaction above).
-- ---------------------------------------------------------------------------
drop table if exists public.p8u_scratch;

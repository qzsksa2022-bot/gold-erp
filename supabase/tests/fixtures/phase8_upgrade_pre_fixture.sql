-- ============================================================================
-- Patch 8.1 §52-53 — Real MULTI-DOMAIN 0198->latest upgrade-safety fixture.
-- ============================================================================
-- Runs against a database that has ONLY migrations 0001-0198 (the FROZEN
-- pre-Phase-8 baseline, §0) + the real supabase/seed.sql applied -- i.e.
-- BEFORE a single Phase 8 / Patch 8.1 migration (0199-0214) exists. Unlike
-- phase7_upgrade_pre_fixture.sql (which only had to prove Phase 7's own
-- Settlement Source Adapter could discover pre-existing UNCLAIMED sources),
-- this fixture builds a genuinely COMPLETE cross-domain dataset -- Sales,
-- Returns (+ a real cash refund event + its reversal), Adjustments (+ its
-- reversal), Shipping (a real COD not_collected -> collected transition),
-- AND an already-FINALIZED Settlement batch with a recorded bank movement
-- -- entirely via the OLD (pre-Phase-8) RPC contracts, all fully committed
-- BEFORE Phase 8's reporting layer (0199-0212) or Patch 8.1's own additions
-- (0213-0214) ever existed. The point: every Phase 8 report RPC must be
-- able to correctly read and aggregate this REAL historical data after the
-- upgrade -- not just avoid throwing on it -- because Phase 8 is a pure
-- reporting layer over data domains that already existed; it must never
-- implicitly assume any row was created only after Phase 8 shipped.
--
-- Data created (all dated public.business_today(), all COMMITTED, never
-- rolled back -- a real production upgrade never rolls back its history):
--   1. One store + minimal karat/category/gold-price/manufacturing-fee/
--      VAT master data (whatever seed.sql does not already provide).
--   2. One Sales Order (cash, 0% fee) -- known subtotal=1200.00.
--   3. One FULL Sales Return on that order, approved, PLUS a real cash
--      refund event (record_sales_return_refund) and that event's own
--      reversal (reverse_sales_return_refund_event) -- exactly the ledger
--      Phase 7.1's Settlement Source Adapter (and every Phase 8 Returns
--      report) actually reads.
--   4. One participates_in_settlement Adjustment on the SAME order,
--      approved, PLUS its own reversal.
--   5. A SEPARATE Sales Order + outbound is_cod Shipment with a REAL
--      not_collected -> collected COD transition (two separate top-level
--      statements, so their created_at genuinely differ -- same rationale
--      as phase7_upgrade_pre_fixture.sql).
--   6. A dedicated Settlement Route ('payment_collection', cash) + fee
--      version, a draft batch claiming the return-refund-event + the
--      adjustment (both real settlement sources at 0198), FINALIZED, with
--      a matching bank movement recorded (zero variance) -- a fully
--      historical, already-closed-out settlement batch.
--
-- Results are recorded into a PERMANENT (non-temp) scratch table,
-- public.p8u_scratch, mirroring public.p7u_scratch's exact convention, so
-- they survive into the separate psql invocation that applies 0199-latest
-- and the separate psql invocation that runs the post-upgrade assertions.
-- ============================================================================

create table if not exists public.p8u_scratch (label text primary key, value text);

insert into auth.users (id, email) values
  ('a8100000-0000-4000-8000-000000000001', 'test-p8u-admin@example.invalid')
  on conflict do nothing;

update public.profiles set full_name = 'P8U Upgrade Fixture Admin', status = 'active', store_access_scope = 'all'
  where id = 'a8100000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select 'a8100000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

set role authenticated;
set request.jwt.claims = '{"sub":"a8100000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 1-4) Sales Order + FULL Return (+ refund event + reversal) + Adjustment
-- (+ reversal) -- one shared do block (single frozen now(), fine here since
-- no lag()-based event ordering is exercised in this fixture).
-- ---------------------------------------------------------------------------
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid;
  v_pm_cash uuid; v_channel_id uuid;
  v_order record; v_order_id uuid; v_order_number text;
  v_order_json jsonb; v_item_id uuid; v_subtotal numeric; v_fee numeric; v_sale_row_version bigint;
  v_return record; v_return_id uuid; v_return_number text;
  v_return_json jsonb; v_return_gross numeric; v_return_fee numeric;
  v_refund_event record;
  v_refund_reversal record;
  v_type_id uuid;
  v_adj record; v_adj_id uuid; v_adj_number text;
  v_adjrow record; v_adj_charge numeric; v_adj_fee numeric; v_adj_row_version bigint;
  v_rev record; v_reversal_id uuid;
begin
  insert into public.stores (code, name_ar, status) values ('P8UPST', 'فرع ترقية 8', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P8UPK', 'عيار ترقية 8', 992, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p8upcat', 'تصنيف ترقية 8', 992, 'active') returning id into v_category_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 280.0000, 'a8100000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 12.0000, public.business_today(), 'p8u fixture');

  select id into v_pm_cash from public.payment_methods where key = 'cash';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';

  -- ---------------------------------------------------------------------
  -- 2) Sales Order — cash, known subtotal=1200.00 (fee=0.00).
  -- ---------------------------------------------------------------------
  select * into v_order from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_cash, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 3.0000, 'sale_price', 1200.00)),
    'عميل ترقية 8 (ما قبل الترقية)', null, null, null
  );
  v_order_id := v_order.id;
  v_order_number := v_order.order_number;

  v_order_json := public.get_sales_order(v_order_id);
  v_subtotal := (v_order_json ->> 'subtotal')::numeric;
  v_fee := (v_order_json ->> 'payment_fee_amount')::numeric;
  v_sale_row_version := (v_order_json ->> 'row_version')::bigint;
  v_item_id := (v_order_json -> 'items' -> 0 ->> 'id')::uuid;
  assert v_subtotal = 1200.00, format('BUG fixture setup: expected sale subtotal=1200.00, got %', v_subtotal);

  insert into p8u_scratch values ('store_id', v_store_id::text);
  insert into p8u_scratch values ('karat_id', v_karat_id::text);
  insert into p8u_scratch values ('category_id', v_category_id::text);
  insert into p8u_scratch values ('pm_cash_id', v_pm_cash::text);
  insert into p8u_scratch values ('channel_direct_id', v_channel_id::text);
  insert into p8u_scratch values ('order_id', v_order_id::text);
  insert into p8u_scratch values ('order_number', v_order_number);
  insert into p8u_scratch values ('order_subtotal', v_subtotal::text);
  insert into p8u_scratch values ('sale_date', public.business_today()::text);

  -- ---------------------------------------------------------------------
  -- 3) FULL Sales Return, approved, PLUS a real cash refund event + its
  -- reversal -- the ledger every Phase 8 Returns report reads.
  -- ---------------------------------------------------------------------
  select * into v_return from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار ترقية 8 — إرجاع كامل')),
    v_sale_row_version, 'collected', v_subtotal
  );
  v_return_id := v_return.id;
  v_return_number := v_return.return_number;
  perform public.approve_sales_return(v_return_id, (public.get_sales_return(v_return_id) ->> 'row_version')::bigint);

  v_return_json := public.get_sales_return(v_return_id);
  v_return_gross := (v_return_json ->> 'sales_revenue_reversal_amount')::numeric;
  v_return_fee := (v_return_json ->> 'payment_fee_reversal_amount')::numeric;
  assert v_return_gross = 1200.00, format('BUG fixture setup: expected return gross=1200.00, got %', v_return_gross);

  insert into p8u_scratch values ('return_id', v_return_id::text);
  insert into p8u_scratch values ('return_number', v_return_number);
  insert into p8u_scratch values ('return_gross', v_return_gross::text);

  select * into v_refund_event from public.record_sales_return_refund(
    v_return_id, v_return_gross, v_pm_cash, public.business_today(), 'استرداد نقدي فعلي — اختبار ترقية 8 (ما قبل الترقية)'
  );
  insert into p8u_scratch values ('refund_event_id', v_refund_event.id::text);
  insert into p8u_scratch values ('refund_event_amount', v_refund_event.amount::text);

  select * into v_refund_reversal from public.reverse_sales_return_refund_event(
    v_refund_event.id, 'تصحيح — اختبار ترقية 8 (ما قبل الترقية) عكس استرداد فعلي', public.business_today()
  );
  -- reverse_sales_return_refund_event() echoes back the ORIGINAL event's id
  -- (not the reversal row's own id -- confirmed by phase7_upgrade_pre_
  -- fixture.sql's own header comment on the same quirk); the TRUE reversal
  -- row id is looked up directly right below, outside this do block.

  -- ---------------------------------------------------------------------
  -- 4) participates_in_settlement Adjustment on the SAME order, approved,
  -- plus its own reversal.
  -- ---------------------------------------------------------------------
  select public.create_adjustment_type('p8u_service', 'خدمة ترقية 8') into v_type_id;
  insert into p8u_scratch values ('adj_type_id', v_type_id::text);

  select * into v_adj from public.create_sales_order_adjustment(
    v_order_id, v_type_id, v_store_id, public.business_today(),
    v_pm_cash, v_channel_id, true, 200.00, 60.00, 'خدمة ترقية 8 — ما قبل الترقية', null, 'REF-P8U-ADJ-1'
  );
  v_adj_id := v_adj.id;
  v_adj_number := v_adj.adjustment_number;

  select * into v_adjrow from public.get_sales_order_adjustment(v_adj_id);
  v_adj_row_version := v_adjrow.row_version;
  perform public.approve_sales_order_adjustment(v_adj_id, v_adj_row_version, null);

  select * into v_adjrow from public.get_sales_order_adjustment(v_adj_id);
  v_adj_charge := v_adjrow.customer_charge::numeric;
  v_adj_row_version := v_adjrow.row_version;
  assert v_adj_charge = 200.00, format('BUG fixture setup: expected adjustment customer_charge=200.00, got %', v_adj_charge);

  insert into p8u_scratch values ('adj_id', v_adj_id::text);
  insert into p8u_scratch values ('adj_number', v_adj_number);
  insert into p8u_scratch values ('adj_charge', v_adj_charge::text);

  select * into v_rev from public.reverse_sales_order_adjustment(
    v_adj_id, v_adj_row_version, public.business_today(), 'تصحيح إداري — اختبار ترقية 8', null
  );
  v_reversal_id := v_rev.reversal_id;
  insert into p8u_scratch values ('adjrev_id', v_reversal_id::text);

  raise notice 'P8U pre-upgrade fixtures created (all BEFORE Phase 8/0199 exists): sale=% (subtotal=%), return=% (gross=%, refund_event=%), adjustment=% (charge=%, reversed=%)',
    v_order_number, v_subtotal, v_return_number, v_return_gross, v_refund_event.id, v_adj_number, v_adj_charge, v_reversal_id;
end $$;

-- Correction (same quirk as phase7_upgrade_pre_fixture.sql): look up the
-- TRUE reversal row id for the refund event reversal. Must run AS POSTGRES
-- -- sales_return_refund_event_reversals has row security ENABLED with
-- ZERO policies defined for `authenticated` (still set from above), which
-- means Postgres's default-deny behavior hides every row from that role
-- entirely (a silent empty result, not an error) -- only a role that
-- bypasses RLS (the superuser this script connects as) can see it.
reset role;
do $$
declare
  v_event_id uuid := (select value::uuid from p8u_scratch where label = 'refund_event_id');
  v_true_reversal_id uuid;
begin
  select id into v_true_reversal_id from public.sales_return_refund_event_reversals where refund_event_id = v_event_id;
  if v_true_reversal_id is null then
    raise exception 'BUG fixture setup: no sales_return_refund_event_reversals row found for refund_event_id=%', v_event_id;
  end if;
  insert into p8u_scratch values ('refund_event_reversal_id', v_true_reversal_id::text);
end $$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- 5) Shipment COD lifecycle: a SEPARATE Sales Order + outbound is_cod
-- shipment + a REAL not_collected -> collected state transition (two
-- separate top-level statements so created_at genuinely differs).
-- ---------------------------------------------------------------------------
do $$
declare
  v_store_id uuid := (select value::uuid from p8u_scratch where label = 'store_id');
  v_karat_id uuid := (select value::uuid from p8u_scratch where label = 'karat_id');
  v_category_id uuid := (select value::uuid from p8u_scratch where label = 'category_id');
  v_pm_cash uuid := (select value::uuid from p8u_scratch where label = 'pm_cash_id');
  v_channel_id uuid := (select value::uuid from p8u_scratch where label = 'channel_direct_id');
  v_carrier_id uuid;
  v_zone_id uuid;
  v_order record;
  v_shipment record;
  v_rv bigint;
  v_ship_date date := public.business_today();
begin
  insert into public.shipping_carriers (code, name_ar, carrier_type, status)
    values ('P8UCARR', 'ناقل ترقية 8', 'external', 'active')
    returning id into v_carrier_id;

  select id into v_zone_id from public.shipping_zones where status = 'active' limit 1;
  if v_zone_id is null then
    raise exception 'BUG fixture setup: no active shipping_zones row found in seed.sql to reuse for the COD shipment';
  end if;

  select * into v_order from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_cash, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 300.00)),
    'عميل ترقية 8 (COD، ما قبل الترقية)', null, null, null
  );

  select * into v_shipment from public.create_shipment(
    v_order.id, v_store_id, v_ship_date, 'outbound',
    v_carrier_id, v_zone_id, 25.00,
    null, 'delivery', null, null, null, null, null,
    true, 300.00, 60.00, 'اختبار ترقية 8 — لا يوجد تسعير معتمد لهذا الناقل/المنطقة، تكلفة يدوية'
  );

  select (public.get_shipment(v_shipment.id) ->> 'row_version')::bigint into v_rv;
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_shipment.id, v_rv, 'not_collected', v_ship_date);

  perform set_config('p8u.cod_shipment_id', v_shipment.id::text, false);
  perform set_config('p8u.cod_row_version', v_rv::text, false);
  perform set_config('p8u.cod_ship_date', v_ship_date::text, false);

  insert into p8u_scratch values ('cod_order_id', v_order.id::text);
  insert into p8u_scratch values ('cod_order_number', v_order.order_number);
  insert into p8u_scratch values ('cod_carrier_id', v_carrier_id::text);
  insert into p8u_scratch values ('cod_zone_id', v_zone_id::text);
  insert into p8u_scratch values ('cod_shipment_id', v_shipment.id::text);
  insert into p8u_scratch values ('cod_shipment_number', v_shipment.shipment_number);
  insert into p8u_scratch values ('cod_expected_amount', '300.00');

  raise notice 'P8U: COD shipment=% (number=%) — first half of the transition (not_collected) recorded', v_shipment.id, v_shipment.shipment_number;
end $$;

do $$
declare
  v_shipment_id uuid := current_setting('p8u.cod_shipment_id')::uuid;
  v_rv bigint := current_setting('p8u.cod_row_version')::bigint;
  v_ship_date date := current_setting('p8u.cod_ship_date')::date;
begin
  perform public.record_shipment_cod_collection_state(v_shipment_id, v_rv, 'collected', v_ship_date);
  raise notice 'P8U: COD shipment=% — second half (collected) recorded, completing a REAL not_collected -> collected transition', v_shipment_id;
end $$;

-- ---------------------------------------------------------------------------
-- 6) A dedicated Settlement Route + fee version, a draft batch claiming the
-- real return-refund-event + adjustment sources above, FINALIZED, with a
-- matching (zero-variance) bank movement -- a fully historical,
-- already-closed-out settlement batch, entirely under the OLD (0198)
-- contract.
-- ---------------------------------------------------------------------------
do $$
declare
  v_pm_cash uuid := (select value::uuid from p8u_scratch where label = 'pm_cash_id');
  v_channel_id uuid := (select value::uuid from p8u_scratch where label = 'channel_direct_id');
  v_route_id uuid;
  v_fee_id uuid;
  v_sources jsonb;
  v_batch_id uuid;
  v_expected numeric;
  v_today date := public.business_today();
begin
  select public.create_settlement_route('p8u-cash-route', 'مسار نقد ترقية 8', 'payment_collection', 'P8U Cash Route', v_pm_cash, v_channel_id) into v_route_id;
  select public.create_settlement_route_fee_version(v_route_id, v_today - 30, 'source_snapshot', null, null, null, 5.00, null, 'p8u fee') into v_fee_id;

  select coalesce(jsonb_agg(jsonb_build_object('source_kind', src.source_kind, 'source_event_id', src.source_event_id)), '[]'::jsonb)
  into v_sources
  from public.list_unsettled_settlement_sources(v_route_id, v_today - 1, v_today, null, null, 2000, 0) src;

  if jsonb_array_length(v_sources) = 0 then
    raise exception 'BUG fixture setup: expected at least the refund-event + adjustment sources to be discoverable by list_unsettled_settlement_sources, got zero';
  end if;

  -- A freshly-created draft's row_version is always 1 by column default --
  -- no need to SELECT it back (settlement_batches has row security ENABLED
  -- with ZERO policies for `authenticated`, same as sales_return_refund_
  -- event_reversals above; a raw SELECT here would silently return NULL,
  -- not an error). Matches upgrade_phase7_settlements.test.sql's own
  -- convention (hard-codes 1 for a batch it just created).
  select t.id into v_batch_id from public.create_draft_settlement_batch(v_route_id, v_today, 'P8U-BATCH-1') as t;
  perform public.finalize_settlement_batch(v_batch_id, 1, v_sources);

  -- get_settlement_batch() is the safe SECURITY DEFINER read path for
  -- `authenticated` (same RLS reason as above) -- original_expected_bank_
  -- settlement comes back as TEXT (finance-safe transport, §18-style).
  select original_expected_bank_settlement::numeric into v_expected
    from public.get_settlement_batch(v_batch_id);
  if v_expected is not null then
    perform public.record_settlement_bank_movement(v_batch_id, v_today, v_expected, 'P8U-MOVEMENT-1');
  end if;

  insert into p8u_scratch values ('settlement_route_id', v_route_id::text);
  insert into p8u_scratch values ('settlement_batch_id', v_batch_id::text);
  insert into p8u_scratch values ('settlement_expected', coalesce(v_expected::text, ''));
  insert into p8u_scratch values ('settlement_date', v_today::text);

  raise notice 'P8U: settlement route=% batch=% finalized (expected=%) with a matching bank movement recorded -- ALL via pre-0199 RPCs, BEFORE Phase 8 exists', v_route_id, v_batch_id, v_expected;
end $$;

reset role;
reset request.jwt.claims;

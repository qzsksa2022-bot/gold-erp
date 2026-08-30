-- ============================================================================
-- Phase 7 (Settlements Core) — PRE-upgrade fixture. Runs against a database
-- that has ONLY migrations 0001-0166 + the real supabase/seed.sql applied
-- (i.e. BEFORE any Phase 7 migration, 0167+, exists — no settlements.*
-- tables/RPCs exist yet at all). Creates real data using the OLD (pre-
-- Phase-7) Sales/Returns/Adjustments RPC contracts exactly as a real
-- production database would already have accumulated:
--
--   1. One store + minimal karat/category/gold-price/manufacturing-fee
--      master data.
--   2. One Sales Order on the 'cash' payment method / 'direct_store'
--      collection channel (known subtotal, 0% fee — cash is seeded at 0%,
--      chosen deliberately so the SAME payment method can be reused for the
--      Return and the Adjustment below without tripping visa/tabby's
--      refund_fee_policy='manual' requirement for an explicit fee-reversal
--      override — irrelevant complexity this fixture does not need to
--      exercise; the Settlement Source Adapter's discovery/matching logic
--      requires every source's own payment_method_id to equal the route's,
--      so all three sources below deliberately share the one method).
--   3. One FULL Sales Return, approved, against that Sales Order.
--   4. One participates_in_settlement=true Adjustment, approved, on that
--      same Sales Order — plus its reversal.
--
-- None of this uses any settlements.* schema/RPC — none exists yet at this
-- migration number. The entire point is proving Phase 7's Settlement Source
-- Adapter (0176) can discover this data AFTER it becomes historical, having
-- been created genuinely BEFORE Phase 7 ever existed — no synthetic
-- post-upgrade-only fixture is required for the discovery proof to be real.
--
-- Results are recorded in a PERMANENT (non-temp) scratch table,
-- public.p7u_scratch, mirroring public.p6u61_scratch's exact convention
-- (supabase/tests/fixtures/patch_6_1_upgrade_pre_fixture.sql), so they
-- survive into the separate psql invocation that applies 0167-0183 and the
-- separate psql invocation that runs the actual post-upgrade assertions.
--
-- NOTE: this script is deliberately NOT wrapped in begin/rollback (its data
-- must be COMMITTED, not rolled back — the whole point is to leave real
-- pre-Phase-7 data behind for 0167-0183 to be proven against) and psql runs
-- each top-level statement in its own implicit transaction, so SET LOCAL
-- (transaction-scoped) cannot be used here — plain SET (session-scoped) is
-- used instead, exactly like patch_6_1_upgrade_pre_fixture.sql.
-- ============================================================================

create table if not exists public.p7u_scratch (label text primary key, value text);

insert into auth.users (id, email) values
  ('a7100000-0000-4000-8000-000000000001', 'test-p7u-admin@example.invalid')
  on conflict do nothing;

update public.profiles set full_name = 'P7U Upgrade Fixture Admin', status = 'active', store_access_scope = 'all'
  where id = 'a7100000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select 'a7100000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

set role authenticated;
set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid;
  v_pm_cash uuid; v_channel_id uuid;
  v_order record; v_order_id uuid; v_order_number text;
  v_order_json jsonb; v_item_id uuid; v_subtotal numeric; v_fee numeric; v_sale_row_version bigint;
  v_return record; v_return_id uuid; v_return_number text;
  v_return_json jsonb; v_return_gross numeric; v_return_fee numeric;
  v_type_id uuid;
  v_adj record; v_adj_id uuid; v_adj_number text;
  v_adjrow record; v_adj_charge numeric; v_adj_fee numeric; v_adj_row_version bigint;
  v_rev record; v_reversal_id uuid;
  v_adjrow2 record; v_reversal_gross numeric; v_reversal_fee_raw numeric;
begin
  insert into public.stores (code, name_ar, status) values ('P7UPST', 'فرع ترقية 7', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P7UPK', 'عيار ترقية 7', 991, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p7upcat', 'تصنيف ترقية 7', 991, 'active') returning id into v_category_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 270.0000, 'a7100000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p7u fixture');

  select id into v_pm_cash from public.payment_methods where key = 'cash';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';

  -- ---------------------------------------------------------------------
  -- 1) Sales Order — cash, known subtotal=800.00 (fee=0.00, cash is seeded
  -- at 0%).
  -- ---------------------------------------------------------------------
  select * into v_order from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_cash, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 2.0000, 'sale_price', 800.00)),
    'عميل ترقية 7 (ما قبل الترقية)', null, null, null
  );
  v_order_id := v_order.id;
  v_order_number := v_order.order_number;

  v_order_json := public.get_sales_order(v_order_id);
  v_subtotal := (v_order_json ->> 'subtotal')::numeric;
  v_fee := (v_order_json ->> 'payment_fee_amount')::numeric;
  v_sale_row_version := (v_order_json ->> 'row_version')::bigint;
  v_item_id := (v_order_json -> 'items' -> 0 ->> 'id')::uuid;
  assert v_subtotal = 800.00, format('BUG fixture setup: expected sale subtotal=800.00, got %', v_subtotal);
  assert v_fee = 0.00, format('BUG fixture setup: expected sale fee=0.00 (cash), got %', v_fee);

  insert into p7u_scratch values ('store_id', v_store_id::text);
  insert into p7u_scratch values ('karat_id', v_karat_id::text);
  insert into p7u_scratch values ('category_id', v_category_id::text);
  insert into p7u_scratch values ('pm_cash_id', v_pm_cash::text);
  insert into p7u_scratch values ('channel_direct_id', v_channel_id::text);
  insert into p7u_scratch values ('order_id', v_order_id::text);
  insert into p7u_scratch values ('order_number', v_order_number);
  insert into p7u_scratch values ('order_subtotal', v_subtotal::text);
  insert into p7u_scratch values ('order_fee', v_fee::text);

  -- ---------------------------------------------------------------------
  -- 2) FULL Sales Return, approved — same store, cash (fee reversal stays
  -- 0.00, no override needed).
  -- ---------------------------------------------------------------------
  select * into v_return from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار ترقية 7 — إرجاع كامل')),
    v_sale_row_version, 'collected', v_subtotal
  );
  v_return_id := v_return.id;
  v_return_number := v_return.return_number;
  perform public.approve_sales_return(v_return_id, (public.get_sales_return(v_return_id) ->> 'row_version')::bigint);

  v_return_json := public.get_sales_return(v_return_id);
  v_return_gross := (v_return_json ->> 'sales_revenue_reversal_amount')::numeric;
  v_return_fee := (v_return_json ->> 'payment_fee_reversal_amount')::numeric;
  assert v_return_gross = 800.00, format('BUG fixture setup: expected return sales_revenue_reversal_amount=800.00, got %', v_return_gross);
  assert v_return_fee = 0.00, format('BUG fixture setup: expected return payment_fee_reversal_amount=0.00, got %', v_return_fee);

  insert into p7u_scratch values ('return_id', v_return_id::text);
  insert into p7u_scratch values ('return_number', v_return_number);
  insert into p7u_scratch values ('return_gross', v_return_gross::text);
  insert into p7u_scratch values ('return_fee', v_return_fee::text);

  -- ---------------------------------------------------------------------
  -- 3) participates_in_settlement Adjustment, approved, on the SAME Sales
  -- Order — cash again — plus its reversal.
  -- ---------------------------------------------------------------------
  select public.create_adjustment_type('p7u_service', 'خدمة ترقية 7') into v_type_id;
  insert into p7u_scratch values ('adj_type_id', v_type_id::text);

  select * into v_adj from public.create_sales_order_adjustment(
    v_order_id, v_type_id, v_store_id, public.business_today(),
    v_pm_cash, v_channel_id, true, 150.00, 50.00, 'خدمة ترقية 7 — ما قبل الترقية', null, 'REF-P7U-ADJ-1'
  );
  v_adj_id := v_adj.id;
  v_adj_number := v_adj.adjustment_number;

  select * into v_adjrow from public.get_sales_order_adjustment(v_adj_id);
  v_adj_row_version := v_adjrow.row_version;
  perform public.approve_sales_order_adjustment(v_adj_id, v_adj_row_version, null);

  select * into v_adjrow from public.get_sales_order_adjustment(v_adj_id);
  v_adj_charge := v_adjrow.customer_charge::numeric;
  v_adj_fee := v_adjrow.original_payment_fee_amount::numeric;
  v_adj_row_version := v_adjrow.row_version;
  assert v_adj_charge = 150.00, format('BUG fixture setup: expected adjustment customer_charge=150.00, got %', v_adj_charge);
  assert v_adj_fee = 0.00, format('BUG fixture setup: expected adjustment fee=0.00 (cash), got %', v_adj_fee);

  insert into p7u_scratch values ('adj_id', v_adj_id::text);
  insert into p7u_scratch values ('adj_number', v_adj_number);
  insert into p7u_scratch values ('adj_charge', v_adj_charge::text);
  insert into p7u_scratch values ('adj_fee', v_adj_fee::text);

  select * into v_rev from public.reverse_sales_order_adjustment(
    v_adj_id, v_adj_row_version, public.business_today(), 'تصحيح إداري — اختبار ترقية 7', null
  );
  v_reversal_id := v_rev.reversal_id;

  select * into v_adjrow2 from public.get_sales_order_adjustment(v_adj_id);
  v_reversal_gross := v_adjrow2.reversal_customer_charge_impact::numeric;
  v_reversal_fee_raw := v_adjrow2.reversal_payment_fee_impact::numeric;
  assert v_reversal_gross = -150.00, format('BUG fixture setup: expected reversal_customer_charge_impact=-150.00, got %', v_reversal_gross);
  assert v_reversal_fee_raw = 0.00, format('BUG fixture setup: expected reversal_payment_fee_impact=0.00, got %', v_reversal_fee_raw);

  insert into p7u_scratch values ('adjrev_id', v_reversal_id::text);
  insert into p7u_scratch values ('adjrev_gross', v_reversal_gross::text);
  insert into p7u_scratch values ('adjrev_feeraw', v_reversal_fee_raw::text);

  raise notice 'P7U pre-upgrade fixtures created (all BEFORE Phase 7/0167 exists): sale=% (subtotal=%), return=% (gross=%), adjustment=% (charge=%), reversal=% (gross_impact=%)',
    v_order_number, v_subtotal, v_return_number, v_return_gross, v_adj_number, v_adj_charge, v_reversal_id, v_reversal_gross;
end $$;

-- ============================================================================
-- Phase 7 Integrity Patch 7.1 (§34 item D) extension — adds, on top of the
-- ORIGINAL Phase 7 fixture data above (unchanged, none of it rewritten):
--   1) An ACTUAL cash refund event on the SAME already-approved Return
--      above, via record_sales_return_refund() (0089/0097/0107 — the real
--      append-only cash ledger, pre-existing, genuinely buildable under the
--      OLD 0001-0166 schema) — plus ITS reversal via reverse_sales_return_
--      refund_event() (0107, likewise pre-existing). This is the ledger
--      Patch 7.1's Settlement Source Adapter (0184 §1) sources
--      'return_refund_event'/'return_refund_event_reversal' from
--      EXCLUSIVELY — replacing the OLD (0176) adapter's approval-status-
--      driven 'return_refund'/'return_refund_reversal', which Patch 7.1
--      explicitly stops trusting (0176's kind is never emitted again from
--      0184 onward, though it stays valid on rows already finalized under
--      it — see 0184's own header comment).
--   2) A Shipment COD lifecycle with a REAL state transition
--      (not_collected -> collected), via create_shipment() (0129, Phase 5)
--      + record_shipment_cod_collection_state() (0131, Phase 5/Hotfix
--      5.1.1) — both pre-existing, unaffected by Phase 7 either way. A
--      SEPARATE Sales Order is used (never the one above) because a Sale
--      with a linked outbound is_cod shipment is EXCLUDED from the 'sale'
--      settlement source entirely (both the OLD and NEW adapters) — its
--      money movement is represented ENTIRELY by the COD source instead.
--
-- Both additions are recorded into the SAME public.p7u_scratch table, under
-- new labels, so they survive into the same downstream 0167-latest
-- migration step and the same upgrade_phase7_settlements.test.sql
-- assertions file as everything above.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Actual cash refund event (full target amount, for clean parity with the
-- return's own already-recorded gross) + its reversal.
-- ---------------------------------------------------------------------------
do $$
declare
  v_return_id uuid := (select value::uuid from p7u_scratch where label = 'return_id');
  v_pm_cash uuid := (select value::uuid from p7u_scratch where label = 'pm_cash_id');
  v_return_gross numeric := (select value::numeric from p7u_scratch where label = 'return_gross');
  v_event record;
  v_reversal record;
begin
  select * into v_event from public.record_sales_return_refund(
    v_return_id, v_return_gross, v_pm_cash, public.business_today(), 'استرداد نقدي فعلي — اختبار ترقية 7.1 (ما قبل الترقية)'
  );
  assert v_event.amount::numeric = v_return_gross, format('BUG fixture setup: expected refund event amount=%s, got %s', v_return_gross, v_event.amount);

  insert into p7u_scratch values ('refund_event_id', v_event.id::text);
  insert into p7u_scratch values ('refund_event_amount', v_event.amount);

  select * into v_reversal from public.reverse_sales_return_refund_event(
    v_event.id, 'تصحيح — اختبار ترقية 7.1 (ما قبل الترقية) عكس استرداد فعلي', public.business_today()
  );

  insert into p7u_scratch values ('refund_event_reversal_id', v_reversal.id::text);

  raise notice 'P7U Patch-7.1 extension: actual cash refund event=% (amount=%) + its reversal=% created on return=% — ALL via pre-166 RPCs, BEFORE Patch 7.1/0184 exists', v_event.id, v_event.amount, v_reversal.id, v_return_id;
end $$;

-- ---------------------------------------------------------------------------
-- Shipment COD lifecycle: a SEPARATE Sales Order + outbound is_cod shipment
-- + a REAL not_collected -> collected state transition.
-- ---------------------------------------------------------------------------
-- Split into TWO separate top-level statements (not one shared do $$ block)
-- deliberately: `now()` is frozen for an ENTIRE transaction, and psql gives
-- each top-level statement its own implicit transaction — recording the
-- 'not_collected' event and the 'collected' event in two SEPARATE
-- statements (handing the shipment id/row_version across via set_config,
-- the same session-GUC convention already used throughout this file) means
-- their created_at timestamps genuinely differ (real, distinct transaction
-- start times), so 0184's lag()-based ordering (business_date, created_at,
-- id) resolves the SAME-business-date pair deterministically by created_at
-- — never falling back to an effectively-random id tiebreak, which is what
-- would happen if both events were recorded inside one shared do block
-- (identical business_date AND identical frozen now()). The shipment/sale
-- both stay dated business_today() (no backdating needed, and none is safe
-- here regardless — 'cash''s seeded payment_method_fee_versions.
-- effective_from is business_today() itself, a <= range with no earlier
-- coverage, so create_sales_order() would reject any earlier date).
do $$
declare
  v_store_id uuid := (select value::uuid from p7u_scratch where label = 'store_id');
  v_karat_id uuid := (select value::uuid from p7u_scratch where label = 'karat_id');
  v_category_id uuid := (select value::uuid from p7u_scratch where label = 'category_id');
  v_pm_cash uuid := (select value::uuid from p7u_scratch where label = 'pm_cash_id');
  v_channel_id uuid := (select value::uuid from p7u_scratch where label = 'channel_direct_id');
  v_carrier_id uuid;
  v_zone_id uuid;
  v_order record;
  v_shipment record;
  v_rv bigint;
  v_ship_date date := public.business_today();
begin
  insert into public.shipping_carriers (code, name_ar, carrier_type, status)
    values ('P7UCARR', 'ناقل ترقية 7.1', 'external', 'active')
    returning id into v_carrier_id;

  select id into v_zone_id from public.shipping_zones where status = 'active' limit 1;
  if v_zone_id is null then
    raise exception 'BUG fixture setup: no active shipping_zones row found in seed.sql to reuse for the COD shipment';
  end if;

  select * into v_order from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_cash, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 250.00)),
    'عميل ترقية 7.1 (COD، ما قبل الترقية)', null, null, null
  );

  select * into v_shipment from public.create_shipment(
    v_order.id, v_store_id, v_ship_date, 'outbound',
    v_carrier_id, v_zone_id, 25.00,
    null, 'delivery', null, null, null, null, null,
    true, 250.00, 60.00, 'اختبار ترقية 7.1 — لا يوجد تسعير معتمد لهذا الناقل/المنطقة، تكلفة يدوية'
  );

  select (public.get_shipment(v_shipment.id) ->> 'row_version')::bigint into v_rv;

  -- First half of the REAL state transition: 'not_collected' (the
  -- shipment's very first COD event — prev_state is implicitly NULL,
  -- correctly produces NO source on its own).
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_shipment.id, v_rv, 'not_collected', v_ship_date);

  perform set_config('p7u.cod_shipment_id', v_shipment.id::text, false);
  perform set_config('p7u.cod_row_version', v_rv::text, false);
  perform set_config('p7u.cod_ship_date', v_ship_date::text, false);

  insert into p7u_scratch values ('cod_order_id', v_order.id::text);
  insert into p7u_scratch values ('cod_order_number', v_order.order_number);
  insert into p7u_scratch values ('cod_carrier_id', v_carrier_id::text);
  insert into p7u_scratch values ('cod_zone_id', v_zone_id::text);
  insert into p7u_scratch values ('cod_shipment_id', v_shipment.id::text);
  insert into p7u_scratch values ('cod_shipment_number', v_shipment.shipment_number);
  insert into p7u_scratch values ('cod_expected_amount', '250.00');

  raise notice 'P7U Patch-7.1 extension: COD shipment=% (number=%, carrier=%) — first half of the transition (not_collected, dated %) recorded — ALL via pre-166 RPCs, BEFORE Patch 7.1/0184 exists', v_shipment.id, v_shipment.shipment_number, v_carrier_id, v_ship_date;
end $$;

-- Second half of the SAME transition, as a genuinely SEPARATE top-level
-- statement (see the comment above) — 'collected', same business_date, but
-- a real, later created_at (a new transaction actually started later in
-- wall-clock time), which is what makes 0184's lag()-based adapter resolve
-- this as a deterministic not_collected -> collected transition rather than
-- an id-tiebreak coin flip.
do $$
declare
  v_shipment_id uuid := current_setting('p7u.cod_shipment_id')::uuid;
  v_rv bigint := current_setting('p7u.cod_row_version')::bigint;
  v_ship_date date := current_setting('p7u.cod_ship_date')::date;
begin
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_shipment_id, v_rv, 'collected', v_ship_date);

  raise notice 'P7U Patch-7.1 extension: COD shipment=% — second half of the transition (collected, dated %) recorded, completing a REAL not_collected -> collected transition — ALL via pre-166 RPCs, BEFORE Patch 7.1/0184 exists', v_shipment_id, v_ship_date;
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- Correction: reverse_sales_return_refund_event() (0107) RETURNS TABLE (id
-- uuid) but its body sets `id := p_event_id` — i.e. it echoes back the
-- ORIGINAL event's own id, not the reversal row's OWN id (confirmed by
-- direct inspection of 0107's function body). 0184's Settlement Source
-- Adapter keys its 'return_refund_event_reversal' candidate on
-- sales_return_refund_event_reversals.id itself (the reversal row's OWN
-- primary key), so the scratch value recorded above under
-- 'refund_event_reversal_id' must be corrected to the TRUE reversal row id
-- — looked up directly (as postgres; this table carries zero SELECT RLS
-- policies for `authenticated`, same access model as every other Returns
-- table since 0082).
-- ---------------------------------------------------------------------------
do $$
declare
  v_event_id uuid := (select value::uuid from p7u_scratch where label = 'refund_event_id');
  v_true_reversal_id uuid;
begin
  select id into v_true_reversal_id from public.sales_return_refund_event_reversals where refund_event_id = v_event_id;
  if v_true_reversal_id is null then
    raise exception 'BUG fixture setup: no sales_return_refund_event_reversals row found for refund_event_id=%', v_event_id;
  end if;

  update p7u_scratch set value = v_true_reversal_id::text where label = 'refund_event_reversal_id';

  raise notice 'P7U Patch-7.1 extension: corrected refund_event_reversal_id in scratch to the TRUE reversal row id=% (was previously the echoed-back event id)', v_true_reversal_id;
end $$;

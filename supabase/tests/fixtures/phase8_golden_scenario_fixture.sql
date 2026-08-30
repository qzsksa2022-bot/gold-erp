-- ============================================================================
-- Phase 8 §81 — Golden Financial Scenario fixture.
-- ============================================================================
-- Builds one hand-traceable scenario spanning Sales -> Returns -> Shipping
-- -> Adjustments -> Settlements, using the REAL production RPCs (not raw
-- inserts) so every stored figure comes from the actual calculation
-- engines already approved in prior phases -- Phase 8 only has to
-- aggregate/report these correctly, never recompute them (§1).
--
-- Business-date layout (deliberately split across TWO calendar months so
-- the reversal-dated movement-ledger logic in get_dashboard_summary() /
-- get_dashboard_trends() (0200) is actually exercised, not just the
-- same-period case). All dates are in the PAST relative to this
-- environment's actual business_today() at run time (fixed July calendar
-- dates below are safely in the past for as long as this suite is run
-- within/after August 2026; the handful of "today"-pinned events further
-- down call public.business_today() directly rather than a hardcoded
-- literal, precisely so they never drift stale as real time advances) --
-- create_sales_order()/create_sales_return()/etc. all reject future
-- business dates, so the whole scenario must land on-or-before "today":
--   July 2026 (the "P1" reporting window, 2026-07-01..2026-07-31):
--     - Sale created, sale_date = 2026-07-05.
--     - Return approved,          return_date            = 2026-07-10.
--     - Refund cash issued,       refund_business_date    = 2026-07-11.
--     - Adjustment approved,      adjustment_date         = 2026-07-12.
--     - Shipment (outbound),      shipment_date           = 2026-07-06.
--     - Settlement batch A finalized, settlement_date     = 2026-07-20,
--       bank movement recorded,   movement_business_date  = 2026-07-21
--       (movement == expected -> zero variance in July).
--     - Settlement batch B finalized, settlement_date     = 2026-07-22
--       (left un-cancelled in July; cancelled in August instead, to prove
--       §85's cancellation_business_date placement).
--   August 2026, before "today" (the "P2" window, 2026-08-01..2026-08-28):
--     - Return REVERSED,          reversal_business_date  = 2026-08-03.
--     - Refund event REVERSED,    reversal_business_date  = 2026-08-04.
--     - Adjustment REVERSED,      reversal_business_date  = 2026-08-05.
--     - Settlement batch B CANCELLED, cancellation_business_date = 2026-08-15.
--
-- Every actor-facing insert runs as the fixture's own super-admin test
-- actor (full permissions), matching how postgrest_http_test_setup.sql
-- and every other Phase 1-7 test fixture builds its data.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Actors
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('80000000-0000-4000-8000-000000000001', 'p8-golden-super@example.invalid'),
  ('80000000-0000-4000-8000-000000000002', 'p8-golden-limited@example.invalid')
on conflict (id) do nothing;

update public.profiles set full_name = 'Phase8 Golden Super Admin', status = 'active', store_access_scope = 'all'
  where id = '80000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Phase8 Golden Limited Actor', status = 'active', store_access_scope = 'all'
  where id = '80000000-0000-4000-8000-000000000002';

insert into public.user_roles (user_id, role_id)
  select '80000000-0000-4000-8000-000000000001', r.id from public.roles r where r.key = 'super_admin'
on conflict do nothing;

-- Limited actor: sales_employee role only (dashboard.view, sales.view,
-- sales.create, returns.view, returns.create -- NO *.view_profit, NO
-- dashboard.view_financials, NO settlements/shipments/adjustments.view) --
-- used by the SQL test to prove financial-key redaction end-to-end.
insert into public.user_roles (user_id, role_id)
  select '80000000-0000-4000-8000-000000000002', r.id from public.roles r where r.key = 'sales_employee'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Master data
-- ---------------------------------------------------------------------------
insert into public.stores (id, code, name_ar, status) values
  ('80100000-0000-4000-8000-000000000001', 'P8-G-STORE', 'متجر السيناريو الذهبي', 'active')
on conflict (id) do nothing;

insert into public.karats (id, code, purity_per_mille, name_ar, name_en, sort_order, status) values
  ('80100000-0000-4000-8000-000000000002', 'P8-G-K21', 875.000, 'عيار السيناريو 21', 'Golden Scenario K21', 950, 'active')
on conflict (id) do nothing;

insert into public.product_categories (id, code, name_ar, sort_order, status) values
  ('80100000-0000-4000-8000-000000000003', 'P8-G-CAT', 'خواتم السيناريو', 950, 'active')
on conflict (id) do nothing;

insert into public.payment_methods (id, key, name_ar, fee_model, status, supports_refunds, refund_fee_policy) values
  ('80100000-0000-4000-8000-000000000004', 'p8-g-cash', 'نقدًا - سيناريو', 'percentage', 'active', true, 'full_reversal')
on conflict (id) do nothing;

insert into public.collection_channels (id, key, name_ar, status) values
  ('80100000-0000-4000-8000-000000000005', 'p8-g-direct', 'مباشر - سيناريو', 'active')
on conflict (id) do nothing;

insert into public.shipping_carriers (id, code, name_ar, carrier_type, status) values
  ('80100000-0000-4000-8000-000000000006', 'P8-G-CARRIER', 'ناقل السيناريو', 'external', 'active')
on conflict (id) do nothing;

insert into public.shipping_zones (id, code, name_ar, status) values
  ('80100000-0000-4000-8000-000000000007', 'P8-G-ZONE', 'منطقة السيناريو', 'active')
on conflict (id) do nothing;

insert into public.adjustment_types (id, code, name_ar, status) values
  ('80100000-0000-4000-8000-000000000008', 'P8-G-ADJ', 'خدمة السيناريو', 'active')
on conflict (id) do nothing;

insert into public.settlement_routes (id, code, name_ar, route_kind, payment_method_id, collection_channel_id, status) values
  ('80100000-0000-4000-8000-000000000009', 'P8-G-ROUTE', 'مسار السيناريو', 'payment_collection', '80100000-0000-4000-8000-000000000004', '80100000-0000-4000-8000-000000000005', 'active')
on conflict (id) do nothing;

-- Financial master data. daily_gold_prices requires an EXACT price_date
-- match (gold_price_version_for_karat_on_date, 0061) -- seed every day the
-- fixture's sale_date could land on.
insert into public.daily_gold_prices (id, price_date, karat_id, price_per_gram, source_type, is_manual_override, created_by, updated_by)
select gen_random_uuid(), d::date, '80100000-0000-4000-8000-000000000002', 200.00, 'manual', true, '80000000-0000-4000-8000-000000000001', '80000000-0000-4000-8000-000000000001'
from generate_series('2026-07-01'::date, '2026-08-28'::date, interval '1 day') d
on conflict do nothing;

insert into public.manufacturing_fee_versions (id, karat_id, fee_per_gram, effective_from, status, created_by)
values (gen_random_uuid(), '80100000-0000-4000-8000-000000000002', 50.00, '2026-01-01', 'active', '80000000-0000-4000-8000-000000000001')
on conflict do nothing;

-- VAT rate is a GLOBAL, non-karat-scoped version -- seed.sql already
-- inserts one OPEN-ENDED active 15% row anchored at whatever "today" was
-- when seed.sql ran (business_today() at seed time). Since this fixture's
-- dates must be in the PAST relative to "today" (create_sales_order/etc.
-- reject future business dates) but seed.sql's own VAT row only covers
-- "today" onward, a second, CLOSED-range row for the fixture's own past
-- window is inserted here -- vat_rate_versions_no_overlap (a plain
-- EXCLUDE, not scoped per-entity) permits this because [2026-01-01,
-- 2026-08-28] does not overlap the seeded [today, infinity) row.
insert into public.vat_rate_versions (id, rate_percent, effective_from, effective_to, status, created_by)
values (gen_random_uuid(), 15.00, '2026-01-01', '2026-08-28', 'active', '80000000-0000-4000-8000-000000000001')
on conflict do nothing;

insert into public.payment_method_fee_versions (id, payment_method_id, percentage_fee, fixed_fee, effective_from, status, created_by)
values (gen_random_uuid(), '80100000-0000-4000-8000-000000000004', 2.00, 0.00, '2026-01-01', 'active', '80000000-0000-4000-8000-000000000001')
on conflict do nothing;

insert into public.settlement_route_fee_versions (id, settlement_route_id, effective_from, transaction_fee_strategy, transaction_fee_model, percentage_fee, fixed_fee, batch_fee_fixed, cod_fee_reversal_policy, status, created_by)
values (gen_random_uuid(), '80100000-0000-4000-8000-000000000009', '2026-01-01', 'route_formula', 'percentage', 2.00, 0.00, 5.00, null, 'active', '80000000-0000-4000-8000-000000000001')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- The scenario itself -- run as the super-admin test actor.
-- ---------------------------------------------------------------------------
do $$
declare
  v_actor uuid := '80000000-0000-4000-8000-000000000001';
  v_store uuid := '80100000-0000-4000-8000-000000000001';
  v_karat uuid := '80100000-0000-4000-8000-000000000002';
  v_cat uuid := '80100000-0000-4000-8000-000000000003';
  v_pm uuid := '80100000-0000-4000-8000-000000000004';
  v_ch uuid := '80100000-0000-4000-8000-000000000005';
  v_carrier uuid := '80100000-0000-4000-8000-000000000006';
  v_zone uuid := '80100000-0000-4000-8000-000000000007';
  v_adjtype uuid := '80100000-0000-4000-8000-000000000008';
  v_route uuid := '80100000-0000-4000-8000-000000000009';
  v_order_id uuid; v_order_item_id uuid; v_order_version bigint;
  v_return_id uuid; v_return_version bigint;
  v_refund_event_id uuid;
  v_adj_id uuid; v_adj_version bigint;
  v_ship_id uuid;
  v_batch_a uuid; v_batch_a_ver bigint;
  v_batch_b uuid; v_batch_b_ver bigint;
  v_sources jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated')::text, true);

  -- Sale: one item, 10g @ 21k, sale_price 3500.00. sale_date = Aug 5.
  select t.id into v_order_id from public.create_sales_order(
    v_store, '2026-07-05'::date, v_pm, v_ch,
    jsonb_build_array(jsonb_build_object(
      'category_id', v_cat, 'karat_id', v_karat, 'weight_grams', 10.000, 'sale_price', 3500.00,
      'item_name', 'Golden Scenario Ring'
    )),
    'Golden Scenario Customer', null, 'Phase 8 §81 fixture'
  ) as t;

  select so.row_version, soi.id into v_order_version, v_order_item_id
  from public.sales_orders so join public.sales_order_items soi on soi.sales_order_id = so.id
  where so.id = v_order_id and soi.status = 'active';

  -- Return: full-item return, approved (return_date = Aug 10).
  select t.id into v_return_id from public.create_sales_return(
    v_order_id, v_store, '2026-07-10'::date, 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_order_item_id)),
    v_order_version, 'collected', 3500.00
  ) as t;

  select row_version into v_return_version from public.sales_returns where id = v_return_id;
  perform public.approve_sales_return(v_return_id, v_return_version);

  -- Actual refund cash issued "today" -- approve_sales_return() just above
  -- stamps its own approval as now()/business_today() (no explicit date
  -- param), so the refund event's date must track the SAME business_today()
  -- (STABLE within this transaction, so both calls see an identical value)
  -- rather than a hardcoded literal -- a fixed past literal drifts stale
  -- and starts failing record_sales_return_refund()'s own "refund date >=
  -- return approval date" check the moment real wall-clock time advances
  -- past it (exactly the failure this comment replaces). Lands in the "P2"
  -- (August) reporting window for as long as this suite is run within
  -- August 2026 -- the fixture's whole hardcoded-calendar-month design
  -- (see the header comment) is a separate, pre-existing constraint this
  -- fix does not attempt to lift.
  select t.id into v_refund_event_id from public.record_sales_return_refund(
    v_return_id, 3500.00, v_pm, public.business_today(), 'Golden scenario refund'
  ) as t;

  -- Shipment (outbound), shipment_date = Aug 6, customer charge 30,
  -- actual carrier cost recorded 20.
  select t.id into v_ship_id from public.create_shipment(
    p_sales_order_id => v_order_id, p_store_id => v_store, p_shipment_date => '2026-07-06'::date,
    p_direction => 'outbound', p_carrier_id => v_carrier, p_shipping_zone_id => v_zone,
    p_customer_shipping_charge => 30.00,
    p_manual_expected_cost => 25.00, p_manual_expected_cost_reason => 'Golden scenario fixture -- no rate card configured'
  ) as t;
  perform public.record_shipment_actual_cost(v_ship_id, 1, 20.00, '2026-07-06'::date, 'Golden scenario carrier cost');

  -- Settlement batch A: finalized settlement_date = Aug 20, sourced from
  -- the Sale's payment collection ONLY (the Adjustment below does not
  -- exist yet, so list_unsettled_settlement_sources cannot claim it here
  -- -- keeping the two settleable sources cleanly split between batch A
  -- and batch B), bank movement Aug 21 matching expected exactly (zero
  -- variance).
  select t.id into v_batch_a
  from public.create_draft_settlement_batch(v_route, '2026-07-20'::date, 'GOLDEN-A') as t;
  select row_version into v_batch_a_ver from public.settlement_batches where id = v_batch_a;

  select coalesce(jsonb_agg(jsonb_build_object('source_kind', src.source_kind, 'source_event_id', src.source_event_id)), '[]'::jsonb)
  into v_sources
  from public.list_unsettled_settlement_sources(v_route, '2026-07-01'::date, '2026-07-31'::date, null, null, 100, 0) src;

  perform public.finalize_settlement_batch(v_batch_a, v_batch_a_ver, v_sources);

  -- Same reasoning as the refund event above -- finalize_settlement_batch()
  -- just above stamps its own finalized_at as now(); the bank movement date
  -- must track the SAME business_today(), not a hardcoded literal that
  -- drifts stale as real time passes.
  perform public.record_settlement_bank_movement(
    v_batch_a, public.business_today(),
    (select expected_bank_settlement from public.settlement_batches where id = v_batch_a),
    'GOLDEN-A-MOVEMENT'
  );

  -- Adjustment: approved (adjustment_date = Jul 12), customer_charge 100,
  -- direct_cost 40 -- created AFTER batch A finalizes so it becomes the
  -- ONLY unclaimed source available for batch B below.
  select t.id into v_adj_id from public.create_sales_order_adjustment(
    v_order_id, v_adjtype, v_store, '2026-07-12'::date, v_pm, v_ch, true, 100.00, 40.00, 'Golden scenario adjustment'
  ) as t;

  select row_version into v_adj_version from public.sales_order_adjustments where id = v_adj_id;
  perform public.approve_sales_order_adjustment(v_adj_id, v_adj_version);

  -- Settlement batch B: a second, independent batch on the SAME route,
  -- sourced from the Adjustment above -- gives it a nonzero expected
  -- figure worth cancelling later (§85's cancellation_business_date
  -- placement).
  select t.id into v_batch_b
  from public.create_draft_settlement_batch(v_route, '2026-07-22'::date, 'GOLDEN-B') as t;
  select row_version into v_batch_b_ver from public.settlement_batches where id = v_batch_b;

  -- Batch A already claimed the Sale's source_kind='sale' event -- Batch B
  -- settles the Adjustment instead (participates_in_settlement=true above,
  -- same payment_method/collection_channel as the route), a second,
  -- independent settleable source.
  select coalesce(jsonb_agg(jsonb_build_object('source_kind', src.source_kind, 'source_event_id', src.source_event_id)), '[]'::jsonb)
  into v_sources
  from public.list_unsettled_settlement_sources(v_route, '2026-07-01'::date, '2026-07-31'::date, null, null, 100, 0) src;

  perform public.finalize_settlement_batch(v_batch_b, v_batch_b_ver, v_sources, 10.00, 'Golden scenario fixed batch fee override');
end $$;

-- "Today" (whatever public.business_today() resolves to at run time): the
-- undo events for the Return, the Refund cash event, and the Adjustment,
-- plus batch B's cancellation -- all pinned to business_today() since approve_sales_return()/
-- approve_sales_order_adjustment()/finalize_settlement_batch() stamp their
-- own approved_at/finalized_at as now(), and every chained event's date
-- must be >= that real timestamp and <= today (never future).
do $$
declare
  v_actor uuid := '80000000-0000-4000-8000-000000000001';
  v_return_id uuid;
  v_return_version bigint;
  v_refund_event_id uuid;
  v_adj_id uuid;
  v_adj_version bigint;
  v_batch_b uuid;
  v_batch_b_ver bigint;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated')::text, true);

  select id, row_version into v_return_id, v_return_version
  from public.sales_returns where order_subtotal_snapshot = 3500.00 and status = 'approved'
  order by created_at desc limit 1;
  perform public.reverse_sales_return(v_return_id, v_return_version, 'Golden scenario return reversal', public.business_today());

  select e.id into v_refund_event_id
  from public.sales_return_refund_events e
  where e.sales_return_id = v_return_id
  order by e.created_at desc limit 1;
  perform public.reverse_sales_return_refund_event(v_refund_event_id, 'Golden scenario refund reversal', public.business_today());

  select id, row_version into v_adj_id, v_adj_version
  from public.sales_order_adjustments where customer_charge = 100.00 and direct_cost = 40.00 and status = 'approved'
  order by created_at desc limit 1;
  perform public.reverse_sales_order_adjustment(v_adj_id, v_adj_version, public.business_today(), 'Golden scenario adjustment reversal');

  select id, row_version into v_batch_b, v_batch_b_ver
  from public.settlement_batches where provider_statement_reference = 'GOLDEN-B' order by created_at desc limit 1;
  perform public.cancel_settlement_batch(v_batch_b, v_batch_b_ver, public.business_today(), 'Golden scenario batch B cancellation');
end $$;


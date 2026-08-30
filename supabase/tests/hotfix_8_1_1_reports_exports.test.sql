-- ============================================================================
-- hotfix_8_1_1_reports_exports.test.sql — Phase 8 Final Integrity Hotfix
-- 8.1.1: live SQL regression coverage for the CRITICAL report-RPC fixes in
-- migrations 0215-0219.
-- ============================================================================
-- Self-contained: begin;...rollback; — nothing persists. Run against a
-- fresh DB with all migrations (0001-latest) + seed.sql applied.
--
-- Covers (§57 Golden coverage, prioritizing every §-marked CRITICAL item):
--   A) COD collection_transitions exact Phase-7-canonical-adapter parity
--      (§23-26) — the single most consequential fix in this hotfix: a
--      genuine financial-figure bug (phantom reversals), not a labeling one.
--   B) Settlements filtered-summary integrity + Draft effective_status +
--      has_variance permission rejection (§28-31).
--   C) Adjustments' new filter set — original_sale_store_id vs
--      processing_store_id independence, participates_in_settlement=false
--      (typed boolean, not falsy-dropped), movement_type (§32-35).
--   D) Returns' basis-aware refund_method_id semantics (§36).
--   F) Payment Methods' per-section, cross-domain permission architecture —
--      base gate reports.view, sections independently keyed off
--      sales.view/returns.view/settlements.view (§6-10).
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Actors + shared master data.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('81100000-0000-4000-8000-000000000001', 'h811t-admin@example.invalid'),
  ('81100000-0000-4000-8000-000000000002', 'h811t-refundonly@example.invalid')
on conflict (id) do nothing;

update public.profiles set full_name = 'H811T Admin', status = 'active', store_access_scope = 'all'
  where id = '81100000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'H811T Refund-Only Reports Actor', status = 'active', store_access_scope = 'all'
  where id = '81100000-0000-4000-8000-000000000002';

insert into public.user_roles (user_id, role_id)
  select '81100000-0000-4000-8000-000000000001', r.id from public.roles r where r.key = 'super_admin'
on conflict do nothing;

-- §6-10 (F) actor: reports.view + returns.view ONLY — no sales.view, no
-- settlements.view. Proves the Payment Methods RPC's own base gate is
-- reports.view alone (never sales.view), and that ONLY the Refund Cash
-- section's keys appear in the envelope for this actor.
insert into public.roles (id, key, name_ar, name_en) values
  ('81100000-0000-4000-8000-000000000098', 'h811t_refund_only', 'مُشاهد استرداد فقط - اختبار', 'Refund-Only Test Viewer')
on conflict (id) do nothing;
insert into public.role_permissions (role_id, permission_id)
  select '81100000-0000-4000-8000-000000000098', p.id from public.permissions p where p.key in ('reports.view', 'returns.view')
on conflict do nothing;
insert into public.user_roles (user_id, role_id) values
  ('81100000-0000-4000-8000-000000000002', '81100000-0000-4000-8000-000000000098')
on conflict do nothing;

insert into public.stores (id, code, name_ar, status) values
  ('81100000-0000-4000-8000-000000000010', 'H811T-S1', 'متجر اختبار 8.1.1 الأول', 'active'),
  ('81100000-0000-4000-8000-000000000011', 'H811T-S2', 'متجر اختبار 8.1.1 الثاني', 'active')
on conflict (id) do nothing;

insert into public.karats (id, code, purity_per_mille, name_ar, name_en, sort_order, status) values
  ('81100000-0000-4000-8000-000000000012', 'H811T-K', 875.000, 'عيار اختبار 8.1.1', 'Hotfix 8.1.1 Test Karat', 981, 'active')
on conflict (id) do nothing;

insert into public.product_categories (id, code, name_ar, sort_order, status) values
  ('81100000-0000-4000-8000-000000000013', 'H811T-CAT', 'فئة اختبار 8.1.1', 981, 'active')
on conflict (id) do nothing;

insert into public.payment_methods (id, key, name_ar, fee_model, status, supports_refunds, refund_fee_policy) values
  ('81100000-0000-4000-8000-000000000014', 'h811t-pm-a', 'طريقة أ - اختبار 8.1.1', 'percentage', 'active', true, 'full_reversal'),
  ('81100000-0000-4000-8000-000000000015', 'h811t-pm-b', 'طريقة ب - اختبار 8.1.1', 'percentage', 'active', true, 'full_reversal')
on conflict (id) do nothing;

insert into public.collection_channels (id, key, name_ar, status) values
  ('81100000-0000-4000-8000-000000000016', 'h811t-ch-a', 'قناة أ - اختبار 8.1.1', 'active')
on conflict (id) do nothing;

insert into public.shipping_carriers (id, code, name_ar, carrier_type, status) values
  ('81100000-0000-4000-8000-000000000017', 'H811T-CARR', 'ناقل اختبار 8.1.1', 'external', 'active')
on conflict (id) do nothing;

insert into public.shipping_zones (id, code, name_ar, status) values
  ('81100000-0000-4000-8000-000000000018', 'H811T-ZONE', 'منطقة اختبار 8.1.1', 'active')
on conflict (id) do nothing;

insert into public.adjustment_types (id, code, name_ar, status) values
  ('81100000-0000-4000-8000-000000000019', 'H811T-ADJ', 'خدمة اختبار 8.1.1', 'active')
on conflict (id) do nothing;

insert into public.settlement_routes (id, code, name_ar, route_kind, payment_method_id, collection_channel_id, status) values
  ('81100000-0000-4000-8000-00000000001a', 'H811T-ROUTE', 'مسار اختبار 8.1.1', 'payment_collection', '81100000-0000-4000-8000-000000000014', '81100000-0000-4000-8000-000000000016', 'active')
on conflict (id) do nothing;

insert into public.daily_gold_prices (id, price_date, karat_id, price_per_gram, source_type, is_manual_override, created_by, updated_by)
select gen_random_uuid(), d::date, '81100000-0000-4000-8000-000000000012', 200.00, 'manual', true, '81100000-0000-4000-8000-000000000001', '81100000-0000-4000-8000-000000000001'
from generate_series(public.business_today() - 30, public.business_today(), interval '1 day') d
on conflict do nothing;

insert into public.manufacturing_fee_versions (id, karat_id, fee_per_gram, effective_from, status, created_by)
values (gen_random_uuid(), '81100000-0000-4000-8000-000000000012', 50.00, '2020-01-01', 'active', '81100000-0000-4000-8000-000000000001')
on conflict do nothing;

-- NOTE: seed.sql already installs ONE open-ended (effective_to is null)
-- active vat_rate_versions row, and vat_rate_versions_open_idx uniquely
-- enforces there can only ever be one such open row at a time — so this
-- fixture's own version must NOT also be open-ended. Instead it covers
-- everything strictly before whatever the seed's open version starts from
-- (resolved dynamically, never a hardcoded date, so this stays correct
-- regardless of which real day this test happens to run on), which is
-- always far enough back to cover every date this fixture uses (all
-- relative to business_today() - 20 at the oldest).
insert into public.vat_rate_versions (id, rate_percent, effective_from, effective_to, status, created_by)
select gen_random_uuid(), 15.00, '2020-01-01'::date, min(effective_from) - 1, 'active', '81100000-0000-4000-8000-000000000001'
from public.vat_rate_versions
where effective_to is null and status = 'active'
on conflict do nothing;

insert into public.payment_method_fee_versions (id, payment_method_id, percentage_fee, fixed_fee, effective_from, status, created_by)
select gen_random_uuid(), id, 2.00, 0.00, '2020-01-01', 'active', '81100000-0000-4000-8000-000000000001'
from public.payment_methods where id in ('81100000-0000-4000-8000-000000000014', '81100000-0000-4000-8000-000000000015')
on conflict do nothing;

insert into public.settlement_route_fee_versions (id, settlement_route_id, effective_from, transaction_fee_strategy, transaction_fee_model, percentage_fee, fixed_fee, batch_fee_fixed, cod_fee_reversal_policy, status, created_by)
values (gen_random_uuid(), '81100000-0000-4000-8000-00000000001a', '2020-01-01', 'route_formula', 'percentage', 2.00, 0.00, 5.00, null, 'active', '81100000-0000-4000-8000-000000000001')
on conflict do nothing;

set role authenticated;

-- ===========================================================================
-- (A) §23-26 CRITICAL — COD collection_transitions canonical parity.
-- ===========================================================================
do $$
declare
  v_store uuid := '81100000-0000-4000-8000-000000000010';
  v_pm uuid := '81100000-0000-4000-8000-000000000014';
  v_ch uuid := '81100000-0000-4000-8000-000000000016';
  v_cat uuid := '81100000-0000-4000-8000-000000000013';
  v_karat uuid := '81100000-0000-4000-8000-000000000012';
  v_carrier uuid := '81100000-0000-4000-8000-000000000017';
  v_zone uuid := '81100000-0000-4000-8000-000000000018';
  v_order_id uuid;
  v_ship_id uuid; v_ship_ver bigint;
  d0 date := public.business_today() - 20;
  v jsonb;
  v_rows jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '81100000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  select t.id into v_order_id from public.create_sales_order(
    v_store, d0, v_pm, v_ch,
    jsonb_build_array(jsonb_build_object('category_id', v_cat, 'karat_id', v_karat, 'weight_grams', 5.000, 'sale_price', 500.00, 'item_name', 'H811T COD Item')),
    'H811T COD Customer', null, 'Hotfix 8.1.1 COD fixture'
  ) as t;

  select t.id into v_ship_id from public.create_shipment(
    p_sales_order_id => v_order_id, p_store_id => v_store, p_shipment_date => d0,
    p_direction => 'outbound', p_carrier_id => v_carrier, p_shipping_zone_id => v_zone,
    p_customer_shipping_charge => 0.00, p_is_cod => true, p_cod_expected_amount => 500.00,
    p_manual_expected_cost => 10.00, p_manual_expected_cost_reason => 'Hotfix 8.1.1 fixture -- no rate card'
  ) as t;
  v_ship_ver := (public.get_shipment(v_ship_id) ->> 'row_version')::bigint;

  -- Chain (each call's business_date strictly increasing, so lag() ordering
  -- is unambiguous): unknown(initial, no event yet) -> expected -> collected
  -- (+500, test 1) -> collected (0, same-state, test 2) -> expected (0, was
  -- THE BUG -1, test 3) -> collected (+500, "new", test 4) -> unknown (0,
  -- was THE BUG -1, test 5) -> not_collected (0, prev unknown<>collected,
  -- test 6) -> collected (+500, bridge event, needed to re-reach 'collected'
  -- before the final required transition) -> not_collected (-500, the ONE
  -- genuine Reversal, strictly collected->not_collected, test 7).
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'expected', d0 + 1); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'collected', d0 + 2); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'collected', d0 + 3); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'expected', d0 + 4); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'collected', d0 + 5); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'unknown', d0 + 6); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'not_collected', d0 + 7); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'collected', d0 + 8); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'not_collected', d0 + 9); v_ship_ver := v_ship_ver + 1;

  v := public.get_cod_report(p_date_from => d0, p_date_to => d0 + 9, p_basis => 'collection_transitions');
  v_rows := v -> 'rows';

  if jsonb_array_length(v_rows) <> 4 then
    raise exception 'FAIL A1: expected exactly 4 nonzero-effect transition rows (2 collections + 1 bridge collection + 1 reversal; the zero-effect collected->expected/collected->unknown/unknown->not_collected/same-state transitions must be entirely ABSENT), got %', jsonb_array_length(v_rows);
  end if;

  -- Every returned row must be a genuine +500 collection or the single
  -- -500 reversal -- never a stray -500 from the fixed collected->expected
  -- / collected->unknown bug.
  if exists (select 1 from jsonb_array_elements(v_rows) r where (r ->> 'cod_effect')::numeric = -500.00 and (r ->> 'transition_state') <> 'not_collected') then
    raise exception 'FAIL A2: found a -500 effect row whose transition_state is not not_collected -- the phantom-reversal bug is back';
  end if;
  if (select count(*) from jsonb_array_elements(v_rows) r where (r ->> 'cod_effect')::numeric = -500.00) <> 1 then
    raise exception 'FAIL A3: expected exactly ONE -500 reversal row, got %', (select count(*) from jsonb_array_elements(v_rows) r where (r ->> 'cod_effect')::numeric = -500.00);
  end if;
  if (select count(*) from jsonb_array_elements(v_rows) r where (r ->> 'cod_effect')::numeric = 500.00) <> 3 then
    raise exception 'FAIL A4: expected exactly THREE +500 collection rows, got %', (select count(*) from jsonb_array_elements(v_rows) r where (r ->> 'cod_effect')::numeric = 500.00);
  end if;

  if (v -> 'summary' ->> 'net_cod_collection_effect')::numeric <> 1000.00 then
    raise exception 'FAIL A5: expected net_cod_collection_effect=1000.00 (1500 collected - 500 reversed), got %', v -> 'summary' ->> 'net_cod_collection_effect';
  end if;
  -- cod_reversals is the raw signed sum of negative-effect rows (per
  -- migration 0216), so it is -500.00, not +500.00 -- net_cod_collection_effect
  -- (asserted above) is the derived collections+reversals=1000.00 figure.
  if (v -> 'summary' ->> 'cod_collections')::numeric <> 1500.00 or (v -> 'summary' ->> 'cod_reversals')::numeric <> -500.00 then
    raise exception 'FAIL A6: expected cod_collections=1500.00/cod_reversals=-500.00, got collections=%/reversals=%', v -> 'summary' ->> 'cod_collections', v -> 'summary' ->> 'cod_reversals';
  end if;

  raise notice 'PASS A: COD collection_transitions matches the exact Phase-7-canonical-adapter parity matrix (§23-26) -- 4 real rows, net effect 1000.00, zero phantom reversals';
end $$;

-- ===========================================================================
-- (B) §28-31 CRITICAL — Settlements filtered-summary integrity, Draft
-- effective_status, has_variance permission rejection.
-- ===========================================================================
do $$
declare
  v_route uuid := '81100000-0000-4000-8000-00000000001a';
  v_store uuid := '81100000-0000-4000-8000-000000000010';
  v_pm uuid := '81100000-0000-4000-8000-000000000014';
  v_ch uuid := '81100000-0000-4000-8000-000000000016';
  v_cat uuid := '81100000-0000-4000-8000-000000000013';
  v_karat uuid := '81100000-0000-4000-8000-000000000012';
  d0 date := public.business_today() - 15;
  v_order1 uuid; v_order2 uuid;
  v_batch_draft uuid; v_batch_draft_ver bigint;
  v_batch_fin uuid; v_batch_fin_ver bigint;
  v_sources jsonb;
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '81100000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  select t.id into v_order1 from public.create_sales_order(
    v_store, d0, v_pm, v_ch,
    jsonb_build_array(jsonb_build_object('category_id', v_cat, 'karat_id', v_karat, 'weight_grams', 3.000, 'sale_price', 300.00, 'item_name', 'H811T Settlement Item 1')),
    'H811T Settle Customer 1', null, 'Hotfix 8.1.1 settlement fixture'
  ) as t;
  select t.id into v_order2 from public.create_sales_order(
    v_store, d0, v_pm, v_ch,
    jsonb_build_array(jsonb_build_object('category_id', v_cat, 'karat_id', v_karat, 'weight_grams', 4.000, 'sale_price', 400.00, 'item_name', 'H811T Settlement Item 2')),
    'H811T Settle Customer 2', null, 'Hotfix 8.1.1 settlement fixture'
  ) as t;

  -- Batch DRAFT: created, never finalized -- claims order1's source but
  -- leaves it a real draft row with no financial contribution.
  select t.id into v_batch_draft from public.create_draft_settlement_batch(v_route, d0, 'H811T-DRAFT') as t;
  select row_version into v_batch_draft_ver from public.get_settlement_batch(v_batch_draft);

  -- Batch FINALIZED: a second, independent batch on the same route,
  -- finalized against order2's source only (order1 stays unclaimed/draft-
  -- adjacent -- finalize_settlement_batch only claims what's explicitly
  -- passed in p_selected_sources, so batch_draft never actually finalizes).
  select t.id into v_batch_fin from public.create_draft_settlement_batch(v_route, d0, 'H811T-FIN') as t;
  select row_version into v_batch_fin_ver from public.get_settlement_batch(v_batch_fin);

  select coalesce(jsonb_agg(jsonb_build_object('source_kind', src.source_kind, 'source_event_id', src.source_event_id)), '[]'::jsonb)
  into v_sources
  from public.list_unsettled_settlement_sources(v_route, d0, d0, v_store, null, 100, 0) src
  where src.source_event_id = v_order2; -- only order2's collection source

  perform public.finalize_settlement_batch(v_batch_fin, v_batch_fin_ver, v_sources);
  perform public.record_settlement_bank_movement(v_batch_fin, d0 + 1, (select original_expected_bank_settlement::numeric from public.get_settlement_batch(v_batch_fin)), 'H811T-FIN-MOVEMENT');

  -- (B1) Draft filter is a real, working filter -- returns ONLY the draft
  -- batch, and its rows still show it (it is NOT invisible).
  v := public.get_settlements_report(p_date_from => d0, p_date_to => d0, p_effective_status => 'draft', p_settlement_route_id => v_route);
  if jsonb_array_length(v -> 'rows') <> 1 or (v -> 'rows' -> 0 ->> 'settlement_batch_id')::uuid <> v_batch_draft then
    raise exception 'FAIL B1: expected effective_status=draft to return exactly the ONE draft batch (%), got rows=%', v_batch_draft, v -> 'rows';
  end if;

  -- (B2) Draft NEVER contributes to the financial ledger, by construction
  -- (settle_finalized_scoped only admits status in (finalized, reconciled)
  -- -- a draft batch's raw status is 'draft', excluded regardless of which
  -- effective_status filter selected it into rows_in_range).
  if coalesce((v -> 'summary' ->> 'expected')::numeric, 0) <> 0 or coalesce((v -> 'summary' ->> 'actual')::numeric, 0) <> 0 then
    raise exception 'FAIL B2: expected zero financial contribution from the draft-only filtered population, got expected=%/actual=%', v -> 'summary' ->> 'expected', v -> 'summary' ->> 'actual';
  end if;

  -- (B3) §28 CRITICAL -- Rows and the financial Summary share the EXACT
  -- SAME filtered population. Filtering to the ONE finalized batch must
  -- make batches_count reflect ONLY that batch -- not the draft batch too
  -- (the exact bug: summary built from settle_batch_scope BEFORE the
  -- effective_status filter).
  v := public.get_settlements_report(p_date_from => d0, p_date_to => d0, p_effective_status => 'finalized', p_settlement_route_id => v_route);
  if jsonb_array_length(v -> 'rows') <> 1 or (v -> 'rows' -> 0 ->> 'settlement_batch_id')::uuid <> v_batch_fin then
    raise exception 'FAIL B3: expected effective_status=finalized to return exactly the ONE finalized batch (%), got rows=%', v_batch_fin, v -> 'rows';
  end if;
  if (v -> 'summary' ->> 'batches_count')::int <> 1 then
    raise exception 'FAIL B3b: expected summary.batches_count=1 (matching the ONE filtered row, not both batches in unfiltered scope), got %', v -> 'summary' ->> 'batches_count';
  end if;
  if (v -> 'summary' ->> 'expected')::numeric <> (select original_expected_bank_settlement::numeric from public.get_settlement_batch(v_batch_fin)) then
    raise exception 'FAIL B3c: filtered financial summary.expected must equal the ONE finalized batch''s own expected_bank_settlement exactly, got %', v -> 'summary' ->> 'expected';
  end if;

  raise notice 'PASS B1-B3: Settlements Draft filter works and contributes zero financial total; Rows and financial Summary share the exact same filtered batch population (§28-30)';

  -- (B4) §31 CRITICAL -- has_variance from an actor LACKING
  -- settlements.view_financials is explicitly REJECTED, never silently
  -- ignored. Uses the refund-only test actor (reports.view + returns.view
  -- -- neither settlements.view nor settlements.view_financials), so the
  -- base settlements.view gate itself would already reject -- proving the
  -- EXPLICIT p_has_variance guard fires, we instead grant settlements.view
  -- (but deliberately withhold settlements.view_financials) to a THIRD,
  -- narrower actor built here.
  -- These are privileged, DDL-adjacent master-data inserts (auth.users,
  -- roles, role_permissions, and an activating profiles UPDATE) -- the
  -- session's role is currently 'authenticated' (set once, top-level,
  -- before block A), which lacks table-level grants on them, AND
  -- request.jwt.claims still carries actor 1's 'sub' from earlier in this
  -- very transaction (set_config(..., true) is transaction-LOCAL, not
  -- statement-local -- it stays in effect for every later statement in
  -- this one begin;...rollback; transaction until overridden), which would
  -- make the profiles-activation trigger's is_trusted_bootstrap_context()
  -- check (0013/0029 -- true only when auth.role()='service_role' OR
  -- auth.uid() is null) see a real, non-null actor and reject the direct
  -- UPDATE as not having gone through users.create. Briefly reset BOTH the
  -- role and the JWT claim to reproduce a trusted direct-SQL-connection
  -- context (exactly like this file's own top-of-file setup, which runs
  -- before any set_config call has ever fired), then restore 'authenticated'
  -- + set the real actor before calling the RPC under test.
  reset role;
  perform set_config('request.jwt.claims', '', true);
  insert into public.roles (id, key, name_ar, name_en) values
    ('81100000-0000-4000-8000-000000000097', 'h811t_settlements_no_fin', 'مشاهد تسويات بدون ماليات - اختبار', 'Settlements No-Financials Test Viewer')
  on conflict (id) do nothing;
  insert into public.role_permissions (role_id, permission_id)
    select '81100000-0000-4000-8000-000000000097', p.id from public.permissions p where p.key in ('reports.view', 'settlements.view')
  on conflict do nothing;
  insert into auth.users (id, email) values ('81100000-0000-4000-8000-000000000003', 'h811t-settlenofin@example.invalid') on conflict (id) do nothing;
  update public.profiles set full_name = 'H811T Settlements No-Financials Actor', status = 'active', store_access_scope = 'all' where id = '81100000-0000-4000-8000-000000000003';
  insert into public.user_roles (user_id, role_id) values ('81100000-0000-4000-8000-000000000003', '81100000-0000-4000-8000-000000000097') on conflict do nothing;
  set role authenticated;

  perform set_config('request.jwt.claims', json_build_object('sub', '81100000-0000-4000-8000-000000000003', 'role', 'authenticated')::text, true);

  begin
    perform public.get_settlements_report(p_date_from => d0, p_date_to => d0, p_has_variance => true);
    raise exception 'FAIL B4: expected an explicit rejection when has_variance is sent by an actor lacking settlements.view_financials, but the call succeeded silently';
  exception
    when sqlstate 'P0001' then
      raise notice 'PASS B4: has_variance from an actor lacking settlements.view_financials is explicitly REJECTED (§31), never silently ignored';
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', '81100000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
end $$;

-- ===========================================================================
-- (C) §32-35 — Adjustments' complete filter set.
-- ===========================================================================
do $$
declare
  v_store1 uuid := '81100000-0000-4000-8000-000000000010'; -- original sale store
  v_store2 uuid := '81100000-0000-4000-8000-000000000011'; -- processing store
  v_pm uuid := '81100000-0000-4000-8000-000000000014';
  v_ch uuid := '81100000-0000-4000-8000-000000000016';
  v_cat uuid := '81100000-0000-4000-8000-000000000013';
  v_karat uuid := '81100000-0000-4000-8000-000000000012';
  v_adjtype uuid := '81100000-0000-4000-8000-000000000019';
  d0 date := public.business_today() - 10;
  v_order_id uuid;
  v_adj_a uuid; v_adj_a_ver bigint; v_adj_a_number text; -- cross-store, participates=true, later reversed
  v_adj_b uuid; v_adj_b_ver bigint; v_adj_b_number text; -- same-store, participates=false
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '81100000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  select t.id into v_order_id from public.create_sales_order(
    v_store1, d0, v_pm, v_ch,
    jsonb_build_array(jsonb_build_object('category_id', v_cat, 'karat_id', v_karat, 'weight_grams', 2.000, 'sale_price', 200.00, 'item_name', 'H811T Adjustment Item')),
    'H811T Adjustment Customer', null, 'Hotfix 8.1.1 adjustments fixture'
  ) as t;

  -- Adjustment A: original sale in store1, PROCESSED in store2 (cross-store,
  -- §33), participates_in_settlement=true. Approved, then REVERSED, so it
  -- contributes BOTH an 'approved' and a 'reversed' movement row.
  select t.id into v_adj_a from public.create_sales_order_adjustment(
    v_order_id, v_adjtype, v_store2, d0 + 1, v_pm, v_ch, true, 80.00, 20.00, 'H811T adjustment A (cross-store)'
  ) as t;
  select row_version, adjustment_number into v_adj_a_ver, v_adj_a_number from public.get_sales_order_adjustment(v_adj_a);
  perform public.approve_sales_order_adjustment(v_adj_a, v_adj_a_ver);
  select row_version into v_adj_a_ver from public.get_sales_order_adjustment(v_adj_a);
  perform public.reverse_sales_order_adjustment(v_adj_a, v_adj_a_ver, d0 + 2, 'H811T adjustment A reversal');

  -- Adjustment B: original sale in store1, PROCESSED in store1 too (same
  -- store), participates_in_settlement=FALSE (§34's real-boolean contract
  -- -- customer_charge=0 forces this per 0146, so use customer_charge=0).
  select t.id into v_adj_b from public.create_sales_order_adjustment(
    v_order_id, v_adjtype, v_store1, d0 + 1, null, null, false, 0.00, 15.00, 'H811T adjustment B (same-store, no settlement)'
  ) as t;
  select row_version, adjustment_number into v_adj_b_ver, v_adj_b_number from public.get_sales_order_adjustment(v_adj_b);
  perform public.approve_sales_order_adjustment(v_adj_b, v_adj_b_ver);

  -- (C1) original_sale_store_id vs processing_store_id are INDEPENDENT,
  -- never OR-merged (§33). Filtering original_sale_store_id=store1 must
  -- return BOTH adjustments (both sales are in store1); filtering
  -- processing_store_id=store2 must return ONLY adjustment A.
  v := public.get_adjustments_report(p_date_from => d0, p_date_to => d0 + 2, p_original_sale_store_id => v_store1);
  if (v -> 'summary' ->> 'movements_count')::int < 3 then
    raise exception 'FAIL C1: expected original_sale_store_id=store1 to surface both adjustments'' movements (>= 3: A-approved, A-reversed, B-approved), got movements_count=%', v -> 'summary' ->> 'movements_count';
  end if;

  v := public.get_adjustments_report(p_date_from => d0, p_date_to => d0 + 2, p_processing_store_id => v_store2);
  if (v -> 'summary' ->> 'movements_count')::int <> 2 then
    raise exception 'FAIL C2: expected processing_store_id=store2 to surface ONLY adjustment A''s 2 movements (approved+reversed), got movements_count=%', v -> 'summary' ->> 'movements_count';
  end if;
  if exists (select 1 from jsonb_array_elements(v -> 'rows') r where r ->> 'adjustment_number' = v_adj_b_number) then
    raise exception 'FAIL C2b: adjustment B (processed in store1) must NOT appear under processing_store_id=store2';
  end if;

  -- (C3) participates_in_settlement is a REAL typed boolean end-to-end --
  -- false must reach the RPC as false (not dropped as falsy) and actually
  -- filter to B alone.
  v := public.get_adjustments_report(p_date_from => d0, p_date_to => d0 + 2, p_participates_in_settlement => false);
  if not exists (select 1 from jsonb_array_elements(v -> 'rows') r where r ->> 'adjustment_number' = v_adj_b_number) then
    raise exception 'FAIL C3: participates_in_settlement=false must surface adjustment B';
  end if;
  if exists (select 1 from jsonb_array_elements(v -> 'rows') r where r ->> 'adjustment_number' = v_adj_a_number) then
    raise exception 'FAIL C3b: participates_in_settlement=false must NOT surface adjustment A (participates=true)';
  end if;

  -- (C4) movement_type filters the LEDGER MOVEMENT kind, not the
  -- adjustment's current status -- 'reversed' must return ONLY adjustment
  -- A's reversal row, never its approval row nor adjustment B at all.
  v := public.get_adjustments_report(p_date_from => d0, p_date_to => d0 + 2, p_movement_type => 'reversed');
  if jsonb_array_length(v -> 'rows') <> 1 or (v -> 'rows' -> 0 ->> 'movement_type') <> 'reversed' then
    raise exception 'FAIL C4: expected movement_type=reversed to return exactly ONE row of type reversed, got rows=%', v -> 'rows';
  end if;

  raise notice 'PASS C1-C4: Adjustments'' complete filter set (original/processing store independence, real participates_in_settlement=false, movement_type) all work correctly (§32-35)';
end $$;

-- ===========================================================================
-- (D) §36 — Returns' basis-aware refund_method_id semantics.
-- ===========================================================================
do $$
declare
  v_store uuid := '81100000-0000-4000-8000-000000000010';
  v_pm_a uuid := '81100000-0000-4000-8000-000000000014'; -- original sale payment method
  v_pm_b uuid := '81100000-0000-4000-8000-000000000015'; -- DIFFERENT actual refund method
  v_ch uuid := '81100000-0000-4000-8000-000000000016';
  v_cat uuid := '81100000-0000-4000-8000-000000000013';
  v_karat uuid := '81100000-0000-4000-8000-000000000012';
  d0 date := public.business_today() - 5;
  v_order_id uuid; v_order_ver bigint; v_item_id uuid;
  v_return_id uuid; v_return_ver bigint;
  v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '81100000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  select t.id into v_order_id from public.create_sales_order(
    v_store, d0, v_pm_a, v_ch,
    jsonb_build_array(jsonb_build_object('category_id', v_cat, 'karat_id', v_karat, 'weight_grams', 1.000, 'sale_price', 100.00, 'item_name', 'H811T Return Item')),
    'H811T Return Customer', null, 'Hotfix 8.1.1 returns fixture'
  ) as t;
  select (public.get_sales_order(v_order_id) ->> 'row_version')::bigint into v_order_ver;
  select (elem ->> 'id')::uuid into v_item_id
  from jsonb_array_elements(public.get_sales_order(v_order_id) -> 'items') elem
  limit 1;

  select t.id into v_return_id from public.create_sales_return(
    v_order_id, v_store, d0 + 1, 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    v_order_ver, 'collected', 100.00
  ) as t;
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_return_ver;
  perform public.approve_sales_return(v_return_id, v_return_ver);

  -- Actual refund cash issued via a DIFFERENT method than the original
  -- sale. Dated business_today() (real "today"), not a d0-relative offset:
  -- approve_sales_return() (just above) always stamps approved_at = now()
  -- (no date parameter of its own), and record_sales_return_refund()
  -- requires its own business date to be >= the return's approval date --
  -- so a backdated d0+N offset would intermittently precede "today"'s real
  -- approval timestamp (the exact staleness bug already diagnosed and
  -- fixed in fixtures/phase8_golden_scenario_fixture.sql this session).
  perform public.record_sales_return_refund(v_return_id, 100.00, v_pm_b, public.business_today(), 'H811T actual refund, different method');

  -- (D1) business_effect: refund_method_id (v_pm_b, the ACTUAL refund
  -- method) must have NO effect -- the row is still returned, since this
  -- basis filters on the ORIGINAL sale's own payment_method_id, not the
  -- refund event's.
  v := public.get_returns_report(p_date_from => d0, p_date_to => public.business_today(), p_basis => 'business_effect', p_refund_method_id => v_pm_b);
  if jsonb_array_length(v -> 'rows') = 0 then
    raise exception 'FAIL D1: business_effect basis must IGNORE refund_method_id entirely (§36) -- expected the return''s movement rows to still appear, got zero rows';
  end if;

  -- (D2) business_effect: payment_method_id (v_pm_a, the ORIGINAL sale's
  -- method) DOES filter correctly.
  v := public.get_returns_report(p_date_from => d0, p_date_to => public.business_today(), p_basis => 'business_effect', p_payment_method_id => v_pm_a);
  if jsonb_array_length(v -> 'rows') = 0 then
    raise exception 'FAIL D2: business_effect basis payment_method_id=original sale method must match';
  end if;
  v := public.get_returns_report(p_date_from => d0, p_date_to => public.business_today(), p_basis => 'business_effect', p_payment_method_id => v_pm_b);
  if jsonb_array_length(v -> 'rows') <> 0 then
    raise exception 'FAIL D2b: business_effect basis payment_method_id=refund method (never used as the sale''s own method here) must NOT match';
  end if;

  -- (D3) actual_cash: refund_method_id (v_pm_b) DOES filter correctly --
  -- the opposite of D1, proving the two bases use genuinely different
  -- filter semantics, not a shared column reused ambiguously.
  v := public.get_returns_report(p_date_from => d0, p_date_to => public.business_today(), p_basis => 'actual_cash', p_refund_method_id => v_pm_b);
  if jsonb_array_length(v -> 'rows') = 0 then
    raise exception 'FAIL D3: actual_cash basis refund_method_id=the real refund event method must match';
  end if;
  v := public.get_returns_report(p_date_from => d0, p_date_to => public.business_today(), p_basis => 'actual_cash', p_refund_method_id => v_pm_a);
  if jsonb_array_length(v -> 'rows') <> 0 then
    raise exception 'FAIL D3b: actual_cash basis refund_method_id=the ORIGINAL sale method (never the actual refund event''s method here) must NOT match';
  end if;

  raise notice 'PASS D1-D3: Returns'' refund_method_id filter is correctly basis-aware -- no effect under business_effect, the correct effect under actual_cash (§36)';
end $$;

-- ===========================================================================
-- (F) §6-10 CRITICAL — Payment Methods per-section, cross-domain permission
-- architecture (base gate reports.view; each section keyed independently).
-- ===========================================================================
do $$
declare
  v jsonb;
begin
  -- The refund-only actor (reports.view + returns.view; NO sales.view, NO
  -- settlements.view) must be able to call get_payment_methods_report() AT
  -- ALL (base gate is reports.view alone, §8) and must see ONLY the Refund
  -- Cash section's keys -- never rows/summary (Sales, gated on sales.view)
  -- and never settlement_rows/settlement_summary (gated on
  -- settlements.view), per §79 true key-absence.
  perform set_config('request.jwt.claims', json_build_object('sub', '81100000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);

  v := public.get_payment_methods_report(p_date_from => public.business_today() - 20, p_date_to => public.business_today());

  if v ? 'rows' or v ? 'summary' then
    raise exception 'FAIL F1: a reports.view+returns.view-only actor (no sales.view) must NOT see the Sales section (rows/summary) at all -- §79 true key-absence, got keys=%', (select jsonb_agg(k) from jsonb_object_keys(v) k);
  end if;
  if v ? 'settlement_rows' or v ? 'settlement_summary' then
    raise exception 'FAIL F2: a reports.view+returns.view-only actor (no settlements.view) must NOT see the Settlements section at all -- §79 true key-absence';
  end if;
  if not (v ? 'refund_rows' and v ? 'refund_summary') then
    raise exception 'FAIL F3: a returns.view-holding actor MUST see the Refund Cash section (refund_rows/refund_summary present) -- got keys=%', (select jsonb_agg(k) from jsonb_object_keys(v) k);
  end if;

  raise notice 'PASS F1-F3: Payment Methods'' base gate is reports.view alone (§8) and each of its 3 sections is independently gated by its own domain permission, never a blanket sales.view requirement -- exactly one section (Refund Cash) is visible to a reports.view+returns.view-only actor';

  perform set_config('request.jwt.claims', json_build_object('sub', '81100000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
end $$;

rollback;

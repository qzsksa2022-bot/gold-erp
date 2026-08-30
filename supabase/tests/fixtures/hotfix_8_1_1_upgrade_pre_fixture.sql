-- ============================================================================
-- Phase 8 — Final Integrity Hotfix 8.1.1 (§60) — 0214->latest upgrade-safety
-- pre-fixture.
-- ============================================================================
-- Runs against a database that has ONLY migrations 0001-0214 (the FROZEN
-- pre-Hotfix-8.1.1 baseline, §0 -- everything through Patch 8.1, nothing of
-- this hotfix yet) + the real supabase/seed.sql applied. Builds the two
-- data shapes this hotfix's own report-RPC fixes are most sensitive to
-- history for -- via the OLD (0214-era) RPC contracts, all COMMITTED, never
-- rolled back (a real production upgrade never rolls back its history):
--
--   1. The exact same 9-call COD collection-state chain as this hotfix's
--      own transaction-scoped regression coverage (supabase/tests/
--      hotfix_8_1_1_reports_exports.test.sql section A) -- proving the
--      §23-26 collection_transitions canonical-Reversal fix (0216) reads
--      HISTORICAL shipment_cod_events rows (written entirely before 0216
--      existed) correctly, not just events created after the fix shipped.
--      record_shipment_cod_collection_state() itself is UNCHANGED by this
--      hotfix (only the report RPC that reads its event history changed),
--      so creating this chain under 0214 and reading it after upgrading to
--      latest is a meaningful proof that 0216 is retroactively correct.
--   2. A genuinely never-finalized DRAFT settlement batch (create_draft_
--      settlement_batch() is also UNCHANGED by this hotfix) plus a
--      SEPARATE, FINALIZED batch on the same route with a matching bank
--      movement (zero variance) -- proving §28-31's filtered-summary fix
--      (0218) AND the §28-31 follow-up store-scope zero-lines fix (0220)
--      both correctly recognize a draft batch that has existed, with ZERO
--      settlement_batch_lines, since BEFORE either fix existed.
--
-- Scratch table (mirrors p7u_scratch/p8u_scratch's exact convention) so the
-- post-upgrade test file can look up every id/number by label without
-- re-deriving them.
-- ============================================================================
create table if not exists public.h811tu_scratch (label text primary key, value text);

-- ---------------------------------------------------------------------------
-- Actor + master data (all fresh ids, namespaced h811tu- to avoid any
-- collision with seed.sql or other fixtures).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('81140000-0000-4000-8000-000000000001', 'h811tu-admin@example.invalid')
on conflict (id) do nothing;

update public.profiles set full_name = 'H811TU Upgrade Admin', status = 'active', store_access_scope = 'all'
  where id = '81140000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select '81140000-0000-4000-8000-000000000001', r.id from public.roles r where r.key = 'super_admin'
on conflict do nothing;

insert into public.stores (id, code, name_ar, status) values
  ('81140000-0000-4000-8000-000000000010', 'H811TU-S1', 'متجر ترقية 8.1.1 الأول', 'active')
on conflict (id) do nothing;

insert into public.karats (id, code, purity_per_mille, name_ar, name_en, sort_order, status) values
  ('81140000-0000-4000-8000-000000000012', 'H811TU-K', 875.000, 'عيار ترقية 8.1.1', 'Hotfix 8.1.1 Upgrade Karat', 982, 'active')
on conflict (id) do nothing;

insert into public.product_categories (id, code, name_ar, sort_order, status) values
  ('81140000-0000-4000-8000-000000000013', 'H811TU-CAT', 'فئة ترقية 8.1.1', 982, 'active')
on conflict (id) do nothing;

insert into public.payment_methods (id, key, name_ar, fee_model, status, supports_refunds, refund_fee_policy) values
  ('81140000-0000-4000-8000-000000000014', 'h811tu-pm-a', 'طريقة ترقية 8.1.1', 'percentage', 'active', true, 'full_reversal')
on conflict (id) do nothing;

insert into public.collection_channels (id, key, name_ar, status) values
  ('81140000-0000-4000-8000-000000000016', 'h811tu-ch-a', 'قناة ترقية 8.1.1', 'active')
on conflict (id) do nothing;

insert into public.shipping_carriers (id, code, name_ar, carrier_type, status) values
  ('81140000-0000-4000-8000-000000000017', 'H811TU-CARR', 'ناقل ترقية 8.1.1', 'external', 'active')
on conflict (id) do nothing;

insert into public.shipping_zones (id, code, name_ar, status) values
  ('81140000-0000-4000-8000-000000000018', 'H811TU-ZONE', 'منطقة ترقية 8.1.1', 'active')
on conflict (id) do nothing;

insert into public.settlement_routes (id, code, name_ar, route_kind, payment_method_id, collection_channel_id, status) values
  ('81140000-0000-4000-8000-00000000001a', 'H811TU-ROUTE', 'مسار ترقية 8.1.1', 'payment_collection', '81140000-0000-4000-8000-000000000014', '81140000-0000-4000-8000-000000000016', 'active')
on conflict (id) do nothing;

insert into public.daily_gold_prices (id, price_date, karat_id, price_per_gram, source_type, is_manual_override, created_by, updated_by)
select gen_random_uuid(), d::date, '81140000-0000-4000-8000-000000000012', 200.00, 'manual', true, '81140000-0000-4000-8000-000000000001', '81140000-0000-4000-8000-000000000001'
from generate_series(public.business_today() - 30, public.business_today(), interval '1 day') d
on conflict do nothing;

insert into public.manufacturing_fee_versions (id, karat_id, fee_per_gram, effective_from, status, created_by)
values (gen_random_uuid(), '81140000-0000-4000-8000-000000000012', 50.00, '2020-01-01', 'active', '81140000-0000-4000-8000-000000000001')
on conflict do nothing;

-- Same "must not collide with seed.sql's own single open vat_rate_versions
-- row" reasoning as hotfix_8_1_1_reports_exports.test.sql's own fixture
-- setup -- see that file's own comment for the full rationale.
insert into public.vat_rate_versions (id, rate_percent, effective_from, effective_to, status, created_by)
select gen_random_uuid(), 15.00, '2020-01-01'::date, min(effective_from) - 1, 'active', '81140000-0000-4000-8000-000000000001'
from public.vat_rate_versions
where effective_to is null and status = 'active'
on conflict do nothing;

insert into public.payment_method_fee_versions (id, payment_method_id, percentage_fee, fixed_fee, effective_from, status, created_by)
select gen_random_uuid(), id, 2.00, 0.00, '2020-01-01', 'active', '81140000-0000-4000-8000-000000000001'
from public.payment_methods where id = '81140000-0000-4000-8000-000000000014'
on conflict do nothing;

insert into public.settlement_route_fee_versions (id, settlement_route_id, effective_from, transaction_fee_strategy, transaction_fee_model, percentage_fee, fixed_fee, batch_fee_fixed, cod_fee_reversal_policy, status, created_by)
values (gen_random_uuid(), '81140000-0000-4000-8000-00000000001a', '2020-01-01', 'route_formula', 'percentage', 2.00, 0.00, 5.00, null, 'active', '81140000-0000-4000-8000-000000000001')
on conflict do nothing;

set role authenticated;

-- ===========================================================================
-- (1) The exact 9-call COD collection-state chain (§23-26), written
-- entirely under 0214 -- 0216 (the fix) does not exist yet.
-- ===========================================================================
do $$
declare
  v_store uuid := '81140000-0000-4000-8000-000000000010';
  v_pm uuid := '81140000-0000-4000-8000-000000000014';
  v_ch uuid := '81140000-0000-4000-8000-000000000016';
  v_cat uuid := '81140000-0000-4000-8000-000000000013';
  v_karat uuid := '81140000-0000-4000-8000-000000000012';
  v_carrier uuid := '81140000-0000-4000-8000-000000000017';
  v_zone uuid := '81140000-0000-4000-8000-000000000018';
  v_order_id uuid;
  v_ship_id uuid; v_ship_ver bigint;
  d0 date := public.business_today() - 20;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '81140000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  select t.id into v_order_id from public.create_sales_order(
    v_store, d0, v_pm, v_ch,
    jsonb_build_array(jsonb_build_object('category_id', v_cat, 'karat_id', v_karat, 'weight_grams', 5.000, 'sale_price', 500.00, 'item_name', 'H811TU COD Item')),
    'H811TU COD Customer', null, 'Hotfix 8.1.1 upgrade pre-fixture'
  ) as t;

  select t.id into v_ship_id from public.create_shipment(
    p_sales_order_id => v_order_id, p_store_id => v_store, p_shipment_date => d0,
    p_direction => 'outbound', p_carrier_id => v_carrier, p_shipping_zone_id => v_zone,
    p_customer_shipping_charge => 0.00, p_is_cod => true, p_cod_expected_amount => 500.00,
    p_manual_expected_cost => 10.00, p_manual_expected_cost_reason => 'Hotfix 8.1.1 upgrade fixture -- no rate card'
  ) as t;
  v_ship_ver := (public.get_shipment(v_ship_id) ->> 'row_version')::bigint;

  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'expected', d0 + 1); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'collected', d0 + 2); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'collected', d0 + 3); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'expected', d0 + 4); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'collected', d0 + 5); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'unknown', d0 + 6); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'not_collected', d0 + 7); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'collected', d0 + 8); v_ship_ver := v_ship_ver + 1;
  perform public.record_shipment_cod_collection_state(v_ship_id, v_ship_ver, 'not_collected', d0 + 9); v_ship_ver := v_ship_ver + 1;

  insert into public.h811tu_scratch values ('cod_shipment_id', v_ship_id::text);
  insert into public.h811tu_scratch values ('cod_date_from', d0::text);
  insert into public.h811tu_scratch values ('cod_date_to', (d0 + 9)::text);
end $$;

-- ===========================================================================
-- (2) A never-finalized DRAFT batch (zero settlement_batch_lines) + a
-- SEPARATE finalized batch with a matching bank movement, on the same
-- route -- both created entirely under 0214, before 0218/0220 exist.
-- ===========================================================================
do $$
declare
  v_route uuid := '81140000-0000-4000-8000-00000000001a';
  v_store uuid := '81140000-0000-4000-8000-000000000010';
  v_pm uuid := '81140000-0000-4000-8000-000000000014';
  v_ch uuid := '81140000-0000-4000-8000-000000000016';
  v_cat uuid := '81140000-0000-4000-8000-000000000013';
  v_karat uuid := '81140000-0000-4000-8000-000000000012';
  d0 date := public.business_today() - 15;
  v_order2 uuid;
  v_batch_draft uuid; v_batch_draft_ver bigint;
  v_batch_fin uuid; v_batch_fin_ver bigint;
  v_sources jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '81140000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

  select t.id into v_order2 from public.create_sales_order(
    v_store, d0, v_pm, v_ch,
    jsonb_build_array(jsonb_build_object('category_id', v_cat, 'karat_id', v_karat, 'weight_grams', 4.000, 'sale_price', 400.00, 'item_name', 'H811TU Settlement Item')),
    'H811TU Settle Customer', null, 'Hotfix 8.1.1 upgrade pre-fixture'
  ) as t;

  select t.id into v_batch_draft from public.create_draft_settlement_batch(v_route, d0, 'H811TU-DRAFT') as t;
  select row_version into v_batch_draft_ver from public.get_settlement_batch(v_batch_draft);

  select t.id into v_batch_fin from public.create_draft_settlement_batch(v_route, d0, 'H811TU-FIN') as t;
  select row_version into v_batch_fin_ver from public.get_settlement_batch(v_batch_fin);

  select coalesce(jsonb_agg(jsonb_build_object('source_kind', src.source_kind, 'source_event_id', src.source_event_id)), '[]'::jsonb)
  into v_sources
  from public.list_unsettled_settlement_sources(v_route, d0, d0, v_store, null, 100, 0) src
  where src.source_event_id = v_order2;

  perform public.finalize_settlement_batch(v_batch_fin, v_batch_fin_ver, v_sources);
  perform public.record_settlement_bank_movement(v_batch_fin, d0 + 1, (select original_expected_bank_settlement::numeric from public.get_settlement_batch(v_batch_fin)), 'H811TU-FIN-MOVEMENT');

  insert into public.h811tu_scratch values ('settlement_route_id', v_route::text);
  insert into public.h811tu_scratch values ('settlement_batch_draft_id', v_batch_draft::text);
  insert into public.h811tu_scratch values ('settlement_batch_fin_id', v_batch_fin::text);
  insert into public.h811tu_scratch values ('settlement_date', d0::text);
end $$;

reset role;

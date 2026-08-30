-- ============================================================================
-- Integration test: Phase 7 — Settlements Core (0167-0183)
-- ============================================================================
-- Single-transaction, rolled-back-at-the-end regression test, mirroring
-- adjustments_core_phase6.test.sql's own convention exactly.
--
-- Prefix 'a7000000-...' is not used by any other test file's fixtures
-- (checked against every prefix currently in use across supabase/tests/).
--
--   01 = full-permission actor (settlements.* all 10 keys + sales/returns/
--        adjustments/master-data perms needed to build fixtures) — "manager"
--   02 = settlements.view ONLY (no view_financials) — money redaction
--   03 = settlements.view + settlements.view_financials ONLY (no create/
--        finalize/manage_routes/... ) — financial-view-only actor, also the
--        baseline denial actor for every route/fee-version RPC
--   04 = settlements.create ONLY (no finalize) — source discovery/preview
--        positive path + finalize denial
--   05 = settlements.finalize ONLY (no process_closed_day, no
--        override_batch_fee) — finalize baseline + both overrides' denial
--   06 = settlements.finalize + settlements.process_closed_day (no
--        override_batch_fee) — closed-day override positive path
--   07 = settlements.finalize + settlements.override_batch_fee (no
--        process_closed_day) — batch-fee override positive path
--   08 = settlements.record_bank_movement ONLY
--   09 = settlements.reconcile ONLY (no reconcile_variance) — zero-variance
--        positive path + nonzero-variance denial
--   10 = settlements.reconcile + settlements.reconcile_variance — nonzero-
--        variance positive path
--   11 = settlements.cancel ONLY
--   12 = settlements.view + view_financials + create, store_access_scope=
--        'single', default_store_id=Store A — §6 whole-batch privacy +
--        §5 discovery-time AND-rule (negative side: sees Store A alone)
--   13 = settlements.view + view_financials + create, store_access_scope=
--        'single', default_store_id=Store C — sees NEITHER side of any
--        cross-store fixture (§6/§5 negative baseline)
--   14 = zero settlements.* permissions at all — blanket denial baseline
--
-- Patch 7.1 additions (§31 coverage, section 8 below):
--   15 = audit_logs.view ONLY (neither sales.view_profit nor settlements.
--        view_financials) — audit permission-matrix combination 1/4
--   16 = audit_logs.view + sales.view_profit (no settlements.view_financials)
--        — combination 2/4
--   17 = audit_logs.view + settlements.view_financials (no sales.view_profit)
--        — combination 3/4 (actor 01 already covers combination 4/4, both)
--   18 = settlements.create ONLY (a SECOND create-only actor, distinct from
--        04) — proves get_draft_settlement_batch_for_edit()'s own-drafts-only
--        restriction (§7) from the OTHER side (04's draft must be invisible
--        to 18)
--   19 = settlements.manage_routes ONLY (no payment_methods.view/collection_
--        channels.view/shipping_rates.view/settlements.view_financials) —
--        the §23 narrow-lookup-RPC workflow
--   20 = settlements.view + view_financials + create, store_access_scope=
--        'multiple' via user_store_access = {Store A, Store B} — the §5/§6
--        AND-rule POSITIVE case (sees a cross-store Adjustment/batch that
--        actors 12/13, each single-store, correctly cannot)
--
-- Requires migrations 0001-latest + supabase/seed.sql already applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/settlements_phase7.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — actors, stores, karat/category/gold-price/mfg-fee master data,
-- a shipping carrier (for the cod_carrier route), reusing seeded payment
-- methods (visa = 2.5%/0-fixed, cash = 0%) and the seeded 'direct_store'
-- collection channel.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a7000000-0000-4000-8000-000000000001', 'test-p7-manager@example.invalid'),
  ('a7000000-0000-4000-8000-000000000002', 'test-p7-view@example.invalid'),
  ('a7000000-0000-4000-8000-000000000003', 'test-p7-viewfin@example.invalid'),
  ('a7000000-0000-4000-8000-000000000004', 'test-p7-create@example.invalid'),
  ('a7000000-0000-4000-8000-000000000005', 'test-p7-finalize@example.invalid'),
  ('a7000000-0000-4000-8000-000000000006', 'test-p7-finalizeclosed@example.invalid'),
  ('a7000000-0000-4000-8000-000000000007', 'test-p7-finalizeoverride@example.invalid'),
  ('a7000000-0000-4000-8000-000000000008', 'test-p7-bankmovement@example.invalid'),
  ('a7000000-0000-4000-8000-000000000009', 'test-p7-reconcile@example.invalid'),
  ('a7000000-0000-4000-8000-000000000010', 'test-p7-reconcilevariance@example.invalid'),
  ('a7000000-0000-4000-8000-000000000011', 'test-p7-cancel@example.invalid'),
  ('a7000000-0000-4000-8000-000000000012', 'test-p7-storeaonly@example.invalid'),
  ('a7000000-0000-4000-8000-000000000013', 'test-p7-storeconly@example.invalid'),
  ('a7000000-0000-4000-8000-000000000014', 'test-p7-noperms@example.invalid'),
  ('a7000000-0000-4000-8000-000000000015', 'test-p7-audit-only@example.invalid'),
  ('a7000000-0000-4000-8000-000000000016', 'test-p7-audit-salesprofit@example.invalid'),
  ('a7000000-0000-4000-8000-000000000017', 'test-p7-audit-settlefin@example.invalid'),
  ('a7000000-0000-4000-8000-000000000018', 'test-p7-createonly2@example.invalid'),
  ('a7000000-0000-4000-8000-000000000019', 'test-p7-manageroutesonly@example.invalid'),
  ('a7000000-0000-4000-8000-000000000020', 'test-p7-storeaandb@example.invalid');

update public.profiles set full_name = 'P7 Manager', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'P7 View-Only', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000002';
update public.profiles set full_name = 'P7 View+Financials', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000003';
update public.profiles set full_name = 'P7 Create-Only', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000004';
update public.profiles set full_name = 'P7 Finalize-Only', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000005';
update public.profiles set full_name = 'P7 Finalize+ClosedDay', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000006';
update public.profiles set full_name = 'P7 Finalize+Override', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000007';
update public.profiles set full_name = 'P7 Bank-Movement-Only', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000008';
update public.profiles set full_name = 'P7 Reconcile-Only', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000009';
update public.profiles set full_name = 'P7 Reconcile+Variance', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000010';
update public.profiles set full_name = 'P7 Cancel-Only', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000011';
-- 012/013 are store-scoped — set below once Store A/C ids are known.
update public.profiles set full_name = 'P7 Store-A-Only', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000012';
update public.profiles set full_name = 'P7 Store-C-Only', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000013';
update public.profiles set full_name = 'P7 No-Perms', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000014';
update public.profiles set full_name = 'P7 Audit-Only', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000015';
update public.profiles set full_name = 'P7 Audit+SalesProfit', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000016';
update public.profiles set full_name = 'P7 Audit+SettleFin', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000017';
update public.profiles set full_name = 'P7 Create-Only-2', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000018';
update public.profiles set full_name = 'P7 ManageRoutes-Only', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000019';
-- 020 is store-scoped ('multiple') — set below once Store A/B ids are known.
update public.profiles set full_name = 'P7 Store-A-and-B', status = 'active', store_access_scope = 'all' where id = 'a7000000-0000-4000-8000-000000000020';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'gold_prices.view', 'gold_prices.edit', 'manufacturing_fees.view', 'manufacturing_fees.manage',
    'payment_methods.view', 'collection_channels.view', 'shipping_rates.view', 'shipping_rates.manage',
    'sales.create', 'sales.view', 'sales.view_profit', 'sales.close_day',
    'returns.create', 'returns.view', 'returns.approve', 'returns.reverse', 'returns.record_refund',
    'adjustments.view', 'adjustments.create', 'adjustments.approve', 'adjustments.reverse',
    'adjustments.manage_cost', 'adjustments.manage_types',
    'shipments.create', 'shipments.view', 'shipments.manage_cost',
    'settlements.view', 'settlements.view_financials', 'settlements.create', 'settlements.finalize',
    'settlements.record_bank_movement', 'settlements.reconcile', 'settlements.reconcile_variance',
    'settlements.cancel', 'settlements.override_batch_fee', 'settlements.process_closed_day',
    'settlements.manage_routes', 'audit_logs.view'
  );

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions where key in ('settlements.view');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000003', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000004', id, 'grant' from public.permissions where key in ('settlements.create');
-- Actors 05-11 each get settlements.view + view_financials ADDITIONALLY to
-- their one specific tested write permission — never used to prove a view
-- denial (actors 02/03/14 own that), only so this file can read back the
-- state its own write RPCs just changed without switching actor context.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000005', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials', 'settlements.create', 'settlements.finalize');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000006', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials', 'settlements.finalize', 'settlements.process_closed_day');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000007', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials', 'settlements.finalize', 'settlements.override_batch_fee');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000008', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials', 'settlements.record_bank_movement');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000009', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials', 'settlements.reconcile');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000010', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials', 'settlements.reconcile', 'settlements.reconcile_variance');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000011', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials', 'settlements.cancel');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000012', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials', 'settlements.create');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000013', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials', 'settlements.create');
-- 014 deliberately gets ZERO permission grants.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000015', id, 'grant' from public.permissions where key in ('audit_logs.view');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000016', id, 'grant' from public.permissions where key in ('audit_logs.view', 'sales.view_profit');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000017', id, 'grant' from public.permissions where key in ('audit_logs.view', 'settlements.view_financials');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000018', id, 'grant' from public.permissions where key in ('settlements.create');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000019', id, 'grant' from public.permissions where key in ('settlements.manage_routes');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7000000-0000-4000-8000-000000000020', id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.view_financials', 'settlements.create');

set role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_a uuid; v_store_b uuid; v_store_c uuid; v_store_d uuid;
  v_karat uuid; v_category uuid; v_carrier uuid;
begin
  insert into public.stores (code, name_ar, status) values ('P7STA', 'فرع تسويات 7 - أ', 'active') returning id into v_store_a;
  insert into public.stores (code, name_ar, status) values ('P7STB', 'فرع تسويات 7 - ب', 'active') returning id into v_store_b;
  insert into public.stores (code, name_ar, status) values ('P7STC', 'فرع تسويات 7 - ج', 'active') returning id into v_store_c;
  insert into public.stores (code, name_ar, status) values ('P7STD', 'فرع تسويات 7 - د', 'active') returning id into v_store_d;
  perform set_config('p7t.store_a', v_store_a::text, false);
  perform set_config('p7t.store_b', v_store_b::text, false);
  perform set_config('p7t.store_c', v_store_c::text, false);
  perform set_config('p7t.store_d', v_store_d::text, false);

  insert into public.karats (code, name_ar, sort_order, status) values ('P7K1', 'عيار تسويات 7', 992, 'active') returning id into v_karat;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p7cat1', 'تصنيف تسويات 7', 992, 'active') returning id into v_category;
  perform set_config('p7t.karat', v_karat::text, false);
  perform set_config('p7t.category', v_category::text, false);

  -- Named 'pm_visa' for historical readability inside this file, but
  -- deliberately resolves to 'tabby' (8%, refund_fee_policy=
  -- proportional_reversal, automatic) rather than the actually-seeded visa
  -- (refund_fee_policy=manual, which would force approve_sales_return() to
  -- take an explicit p_fee_reversal_override — irrelevant complexity this
  -- fixture does not need to exercise the Sign Convention).
  perform set_config('p7t.pm_visa', (select id::text from public.payment_methods where key = 'tabby'), false);
  perform set_config('p7t.pm_cash', (select id::text from public.payment_methods where key = 'cash'), false);
  perform set_config('p7t.channel_direct', (select id::text from public.collection_channels where key = 'direct_store'), false);

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat, 300.0000, 'a7000000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat, 10.0000, public.business_today() - 10, 'p7 fixture');

  insert into public.shipping_carriers (code, name_ar, carrier_type, status)
    values ('P7CARRIER1', 'ناقل تسويات 7', 'external', 'active')
    returning id into v_carrier;
  perform set_config('p7t.carrier', v_carrier::text, false);
end $$;

-- Actors 012/013 are store-scoped — set now that Store A/C ids are known.
-- Must run as the superuser connection role (actor 001 does not hold
-- users.manage_store_access), exactly like adjustments_core_phase6.test.sql.
reset role;
reset request.jwt.claims;
do $$
begin
  update public.profiles set store_access_scope = 'single', default_store_id = current_setting('p7t.store_a')::uuid
    where id = 'a7000000-0000-4000-8000-000000000012';
  update public.profiles set store_access_scope = 'single', default_store_id = current_setting('p7t.store_c')::uuid
    where id = 'a7000000-0000-4000-8000-000000000013';
  update public.profiles set store_access_scope = 'multiple'
    where id = 'a7000000-0000-4000-8000-000000000020';
  insert into public.user_store_access (user_id, store_id) values
    ('a7000000-0000-4000-8000-000000000020', current_setting('p7t.store_a')::uuid),
    ('a7000000-0000-4000-8000-000000000020', current_setting('p7t.store_b')::uuid);
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$ begin raise notice 'SETUP OK: 20 actors, 4 stores, karat/category/gold-price/mfg-fee, shipping carrier'; end $$;

-- ---------------------------------------------------------------------------
-- 1. Route + fee-version lifecycle (item 10/11/12/36/37).
-- ---------------------------------------------------------------------------
do $$
declare
  v_route_visa uuid; v_route_visa_b uuid; v_route_cod uuid;
  v_dup_failed boolean;
  v_fee1 uuid; v_fee2 uuid;
  v_rejected boolean;
begin
  -- 1.1 create payment_collection route on visa (collection_channel NULL —
  -- matches any channel, item 36).
  select public.create_settlement_route('p7-visa-route', 'مسار فيزا 7', 'payment_collection', 'P7 Visa Route', current_setting('p7t.pm_visa')::uuid) into v_route_visa;
  perform set_config('p7t.route_visa', v_route_visa::text, false);

  -- 1.2 a SECOND active route targeting the exact same matching key
  -- (payment_method_id=visa, channel=null) must collide on the DB-level
  -- unique index (item 36) — create_settlement_route does not layer a
  -- friendly wrapper message on top of this particular race, matching
  -- 0178's own documented posture for the claims-uniqueness index.
  v_dup_failed := false;
  begin
    perform public.create_settlement_route('p7-visa-route-dup', 'مسار فيزا مكرر', 'payment_collection', null, current_setting('p7t.pm_visa')::uuid);
  exception when others then
    v_dup_failed := true;
  end;
  if not v_dup_failed then
    raise exception 'FAIL: a second ACTIVE route on the same (payment_method, channel) matching key was NOT rejected';
  end if;

  -- 1.3 cod_carrier route.
  select public.create_settlement_route('p7-cod-route', 'مسار COD 7', 'cod_carrier', null, null, null, current_setting('p7t.carrier')::uuid) into v_route_cod;
  perform set_config('p7t.route_cod', v_route_cod::text, false);

  -- 1.4 duplicate cod_carrier route on the same carrier — same DB-level
  -- unique index collision (item 36).
  v_dup_failed := false;
  begin
    perform public.create_settlement_route('p7-cod-route-dup', 'مسار COD مكرر', 'cod_carrier', null, null, null, current_setting('p7t.carrier')::uuid);
  exception when others then
    v_dup_failed := true;
  end;
  if not v_dup_failed then
    raise exception 'FAIL: a second ACTIVE cod_carrier route on the same carrier was NOT rejected';
  end if;

  -- 1.5 disable/enable ambiguous-match guard (item 36/37) — disable
  -- route_visa, create a replacement route_visa_b on the SAME key (now
  -- free), then prove enable_settlement_route(route_visa) is rejected with
  -- a clear Arabic error while route_visa_b is active, then succeeds once
  -- route_visa_b is disabled again.
  perform public.disable_settlement_route(v_route_visa);
  if (select status from public.settlement_routes where id = v_route_visa) <> 'disabled' then
    raise exception 'FAIL: disable_settlement_route did not set status=disabled';
  end if;
  if not exists (select 1 from public.settlement_route_filter_lookups() where id = v_route_visa) then
    raise exception 'FAIL: a disabled route disappeared from settlement_route_filter_lookups() — must stay historically visible (item 37)';
  end if;

  select public.create_settlement_route('p7-visa-route-b', 'مسار فيزا 7 ب', 'payment_collection', null, current_setting('p7t.pm_visa')::uuid) into v_route_visa_b;
  perform set_config('p7t.route_visa_b', v_route_visa_b::text, false);

  begin
    perform public.enable_settlement_route(v_route_visa);
    raise exception 'FAIL: enable_settlement_route did not reject re-activating an ambiguous-match route while route_visa_b is active on the same key';
  exception when others then
    if sqlerrm not like '%يوجد مسار نشط آخر بنفس معايير المطابقة%' then raise; end if;
  end;

  perform public.disable_settlement_route(v_route_visa_b);
  perform public.enable_settlement_route(v_route_visa);
  if (select status from public.settlement_routes where id = v_route_visa) <> 'active' then
    raise exception 'FAIL: enable_settlement_route did not re-activate once the ambiguous match was cleared';
  end if;

  -- 1.6 update_settlement_route only touches name/description, never the
  -- matching key.
  perform public.update_settlement_route(v_route_visa, 'مسار فيزا 7 (محدث)', 'P7 Visa Route (updated)', 'ملاحظة تحديث');
  if (select name_ar from public.settlement_routes where id = v_route_visa) <> 'مسار فيزا 7 (محدث)' then
    raise exception 'FAIL: update_settlement_route did not update name_ar';
  end if;

  raise notice 'PASS: 1.1-1.6 route CRUD — ambiguous-match rejected on both create AND enable (payment_collection + cod_carrier), disabled routes stay historically visible, update never touches the matching key';

  -- ---------------------------------------------------------------------
  -- 1.7 Fee-version lifecycle (item 11/12) — no-overlap + ambiguous
  -- ongoing-vs-future rejection + cancel-reopens-predecessor.
  -- ---------------------------------------------------------------------
  select public.create_settlement_route_fee_version(v_route_visa, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'p7 fee v1') into v_fee1;
  perform set_config('p7t.fee_visa_1', v_fee1::text, false);

  -- Cancelling a version that is ALREADY effective (fee1 is, right now) is
  -- rejected — tested here, BEFORE fee2 exists, since creating fee2 below
  -- closes fee1 out to status='ended' (a different, earlier rejection
  -- branch — "not active at all" — would fire instead once that happens).
  v_rejected := false;
  begin
    perform public.cancel_settlement_route_fee_version(v_fee1);
  exception when others then
    if sqlerrm like '%يُسمح فقط بإلغاء إصدار مستقبلي%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: cancel_settlement_route_fee_version did NOT reject cancelling an already-effective version'; end if;

  -- A version dated BEFORE the open version's own effective_from is
  -- rejected outright.
  v_rejected := false;
  begin
    perform public.create_settlement_route_fee_version(v_route_visa, public.business_today() - 40, 'source_snapshot', null, null, null, 5.00, null, null);
  exception when others then
    if sqlerrm like '%لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: fee version with effective_from BEFORE the open version''s own was NOT rejected'; end if;

  -- A strictly-future version closes out fee1 and opens fee2.
  select public.create_settlement_route_fee_version(v_route_visa, public.business_today() + 30, 'source_snapshot', null, null, null, 7.00, null, 'p7 fee v2 (future)') into v_fee2;
  if (select effective_to from public.settlement_route_fee_versions where id = v_fee1) <> (public.business_today() + 30 - 1) then
    raise exception 'FAIL: creating fee2 did not close fee1''s effective_to correctly';
  end if;

  -- A SECOND future version, dated at/before fee2's own effective_from,
  -- while fee2 is still not-yet-effective, is rejected (ambiguous
  -- ongoing-vs-future).
  v_rejected := false;
  begin
    perform public.create_settlement_route_fee_version(v_route_visa, public.business_today() + 10, 'source_snapshot', null, null, null, 8.00, null, null);
  exception when others then
    if sqlerrm like '%يوجد بالفعل إصدار رسوم مستقبلي مجدوَل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: a second future fee version scheduled at/before an already-pending future version was NOT rejected'; end if;

  -- Cancelling the strictly-future fee2 succeeds and reopens fee1.
  perform public.cancel_settlement_route_fee_version(v_fee2);
  if (select status from public.settlement_route_fee_versions where id = v_fee2) <> 'cancelled' then
    raise exception 'FAIL: cancel_settlement_route_fee_version did not mark fee2 cancelled';
  end if;
  if (select status from public.settlement_route_fee_versions where id = v_fee1) <> 'active'
    or (select effective_to from public.settlement_route_fee_versions where id = v_fee1) is not null then
    raise exception 'FAIL: cancelling fee2 did not reopen fee1 (status=active, effective_to=null)';
  end if;

  raise notice 'PASS: 1.7 fee-version lifecycle — no-overlap enforced, ambiguous ongoing-vs-future rejected, cancel-of-future reopens predecessor, cancel-of-effective rejected';

  -- ---------------------------------------------------------------------
  -- 1.8 route_formula creation-time invariants (item 12).
  -- ---------------------------------------------------------------------
  v_rejected := false;
  begin
    perform public.create_settlement_route_fee_version(v_route_cod, public.business_today() - 30, 'route_formula', 'percentage', 4.0, 0, 3.00, null, null);
  exception when others then
    if sqlerrm like '%سياسة عكس رسوم COD%مطلوبة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: route_formula on a cod_carrier route WITHOUT cod_fee_reversal_policy was NOT rejected'; end if;

  v_rejected := false;
  begin
    perform public.create_settlement_route_fee_version(v_route_visa, public.business_today() + 60, 'route_formula', 'percentage', 2.0, 0, 5.00, 'full', null);
  exception when others then
    if sqlerrm like '%سياسة عكس رسوم COD لا تنطبق إلا على مسارات COD الناقل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: cod_fee_reversal_policy on a NON-cod_carrier route was NOT rejected'; end if;

  -- The real cod_carrier fee version, used later.
  perform public.create_settlement_route_fee_version(v_route_cod, public.business_today() - 30, 'route_formula', 'percentage', 4.0, 0, 3.00, 'full', 'p7 cod fee');

  raise notice 'PASS: 1.8 route_formula invariants — cod_fee_reversal_policy required exactly for cod_carrier + route_formula, rejected everywhere else';
end $$;

-- 1.9 route/fee-version RPCs require settlements.manage_routes — consolidated
-- denial for every write RPC in this family, as actor 03 (view+financials,
-- no manage_routes).
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare
  v_denied boolean;
begin
  v_denied := false;
  begin perform public.create_settlement_route('p7-denied', 'مرفوض', 'payment_collection', null, current_setting('p7t.pm_cash')::uuid);
  exception when others then if sqlerrm like '%صلاحية إدارة مسارات التسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: create_settlement_route did not require settlements.manage_routes'; end if;

  v_denied := false;
  begin perform public.update_settlement_route(current_setting('p7t.route_visa')::uuid, 'محاولة', null, null);
  exception when others then if sqlerrm like '%صلاحية إدارة مسارات التسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: update_settlement_route did not require settlements.manage_routes'; end if;

  v_denied := false;
  begin perform public.disable_settlement_route(current_setting('p7t.route_visa')::uuid);
  exception when others then if sqlerrm like '%صلاحية إدارة مسارات التسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: disable_settlement_route did not require settlements.manage_routes'; end if;

  v_denied := false;
  begin perform public.enable_settlement_route(current_setting('p7t.route_visa_b')::uuid);
  exception when others then if sqlerrm like '%صلاحية إدارة مسارات التسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: enable_settlement_route did not require settlements.manage_routes'; end if;

  v_denied := false;
  begin perform public.create_settlement_route_fee_version(current_setting('p7t.route_visa')::uuid, public.business_today() + 90, 'source_snapshot', null, null, null, 1.00, null, null);
  exception when others then if sqlerrm like '%صلاحية إدارة مسارات التسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: create_settlement_route_fee_version did not require settlements.manage_routes'; end if;

  v_denied := false;
  begin perform public.cancel_settlement_route_fee_version(current_setting('p7t.fee_visa_1')::uuid);
  exception when others then if sqlerrm like '%صلاحية إدارة مسارات التسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: cancel_settlement_route_fee_version did not require settlements.manage_routes'; end if;

  v_denied := false;
  begin perform 1 from public.settlement_routes_admin_list() limit 1;
  exception when others then v_denied := true; end;
  if not (v_denied or not exists (select 1 from public.settlement_routes_admin_list())) then
    raise exception 'FAIL: settlement_routes_admin_list() unexpectedly returned rows for an actor without settlements.manage_routes';
  end if;

  raise notice 'PASS: 1.9 — every route/fee-version write RPC (+admin list) requires settlements.manage_routes';
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 2. Source Discovery + Sign Convention (0176's own header — the highest-
-- risk logic in this module). One Sale, one full approved Return, one
-- participates_in_settlement Adjustment (approved) processed at a DIFFERENT
-- store than its Sale + its reversal.
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record;
  v_item_id uuid;
  v_return record;
  v_type_id uuid;
  v_adjrow record;
  v_adj_charge numeric;
  v_adj_fee numeric;
  v_reversal_gross numeric;
  v_reversal_fee_raw numeric;
  v_row record;
  v_route_chan uuid;
  v_refund_event record;
begin
  -- 0) A SECOND payment_collection route, same payment method (pm_visa) but
  -- with a REAL collection_channel_id (channel_direct) — required by Patch
  -- 7.1 §4's exact `is not distinct from` route/channel matching: route_visa
  -- (NULL channel, created in section 1) can now NEVER match a Sale/
  -- Adjustment (both carry a real NOT NULL collection_channel_id) — only a
  -- channel-matched route can. Conversely, Return-derived sources carry NO
  -- channel column at all (implicit NULL) and can ONLY ever match a
  -- NULL-channel route — so route_visa remains the correct route for the
  -- Return sources below, and this new route_visa_chan is the correct route
  -- for Sale/Adjustment/Adjustment-Reversal.
  select public.create_settlement_route('p7-visa-chan-route', 'مسار فيزا 7 (قناة مباشرة)', 'payment_collection', 'P7 Visa Channel Route', current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid) into v_route_chan;
  perform set_config('p7t.route_visa_chan', v_route_chan::text, false);
  perform public.create_settlement_route_fee_version(v_route_chan, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'p7 fee visachan v1');

  -- A) Sale — Store A, visa (2.5%), 1000.00 subtotal.
  select * into v_row from public.create_sales_order(
    current_setting('p7t.store_a')::uuid, public.business_today(),
    current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل تسوية 7', '0522222222', null
  );
  perform set_config('p7t.order1', v_row.id::text, false);
  perform set_config('p7t.order1_number', v_row.order_number, false);

  select (public.get_sales_order(v_row.id) ->> 'subtotal')::numeric as subtotal,
         (public.get_sales_order(v_row.id) ->> 'payment_fee_amount')::numeric as fee,
         (public.get_sales_order(v_row.id) ->> 'row_version')::bigint as row_version,
         (public.get_sales_order(v_row.id) -> 'items' -> 0 ->> 'id')::uuid as item_id
  into v_order;
  perform set_config('p7t.order1_subtotal', v_order.subtotal::text, false);
  perform set_config('p7t.order1_fee', v_order.fee::text, false);
  if v_order.fee <= 0 then
    raise exception 'FAIL: fixture assumption broken — visa sale must carry a NONZERO fee to meaningfully exercise the sign convention, got %', v_order.fee;
  end if;

  -- B) full Return Refund, approved, processed at the SAME store (kept
  -- simple — the cross-store scenario is exercised by the Adjustment below),
  -- PLUS an ACTUAL cash refund event for the full approved amount — Patch
  -- 7.1 §1: gross sourcing now comes EXCLUSIVELY from the real refund-event
  -- ledger (sales_return_refund_events), never sales_returns.status/target
  -- amounts. approve_sales_return() also independently produces a nonzero
  -- payment_fee_reversal_amount, which §2 exposes as its OWN return_fee_
  -- reversal source (never conflated with the cash event).
  select * into v_row from public.create_sales_return(
    current_setting('p7t.order1')::uuid, current_setting('p7t.store_a')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_order.item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار تسويات 7')),
    v_order.row_version, 'collected', v_order.subtotal
  );
  perform set_config('p7t.return1', v_row.id::text, false);
  perform set_config('p7t.return1_number', v_row.return_number, false);
  perform public.approve_sales_return(v_row.id, (public.get_sales_return(v_row.id) ->> 'row_version')::bigint);

  select (public.get_sales_return(current_setting('p7t.return1')::uuid) ->> 'sales_revenue_reversal_amount')::numeric as gross,
         (public.get_sales_return(current_setting('p7t.return1')::uuid) ->> 'payment_fee_reversal_amount')::numeric as fee
  into v_return;
  perform set_config('p7t.return1_gross', v_return.gross::text, false);
  perform set_config('p7t.return1_fee', v_return.fee::text, false);
  if v_return.fee <= 0 then
    raise exception 'FAIL: fixture assumption broken — the full return must carry a NONZERO payment_fee_reversal_amount to meaningfully exercise return_fee_reversal (§2), got %', v_return.fee;
  end if;

  select * into v_refund_event from public.record_sales_return_refund(
    current_setting('p7t.return1')::uuid, v_return.gross, current_setting('p7t.pm_visa')::uuid,
    public.business_today(), 'استرداد نقدي فعلي كامل — اختبار تسويات 7'
  );
  perform set_config('p7t.refund_event1', v_refund_event.id::text, false);

  -- D) Approved Adjustment — processing store = Store B, deliberately
  -- DIFFERENT from the linked Sale's own Store A (§5's cross-store AND-rule,
  -- exercised in sections 6/8 below).
  select public.create_adjustment_type('p7_service', 'خدمة تسوية 7') into v_type_id;
  perform set_config('p7t.type_service', v_type_id::text, false);

  select * into v_row from public.create_sales_order_adjustment(
    current_setting('p7t.order1')::uuid, v_type_id, current_setting('p7t.store_b')::uuid, public.business_today(),
    current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid,
    true, 200.00, 40.00, 'خدمة تسوية 7', null, 'REF-P7-ADJ-1'
  );
  perform set_config('p7t.adj1', v_row.id::text, false);

  select * into v_adjrow from public.get_sales_order_adjustment(v_row.id);
  perform public.approve_sales_order_adjustment(v_row.id, v_adjrow.row_version, null);

  select * into v_adjrow from public.get_sales_order_adjustment(current_setting('p7t.adj1')::uuid);
  v_adj_charge := v_adjrow.customer_charge::numeric;
  v_adj_fee := v_adjrow.original_payment_fee_amount::numeric;
  perform set_config('p7t.adj1_charge', v_adj_charge::text, false);
  perform set_config('p7t.adj1_fee', v_adj_fee::text, false);
  if v_adj_fee <= 0 then
    raise exception 'FAIL: fixture assumption broken — the visa Adjustment must carry a NONZERO fee, got %', v_adj_fee;
  end if;

  -- E) Adjustment Reversal.
  select * into v_row from public.reverse_sales_order_adjustment(
    current_setting('p7t.adj1')::uuid, v_adjrow.row_version,
    public.business_today(), 'تصحيح إداري — اختبار تسويات 7', null
  );
  perform set_config('p7t.adjrev1', v_row.reversal_id::text, false);

  select * into v_adjrow from public.get_sales_order_adjustment(current_setting('p7t.adj1')::uuid);
  v_reversal_gross := v_adjrow.reversal_customer_charge_impact::numeric;
  v_reversal_fee_raw := v_adjrow.reversal_payment_fee_impact::numeric;
  perform set_config('p7t.adjrev1_gross', v_reversal_gross::text, false);
  perform set_config('p7t.adjrev1_feeraw', v_reversal_fee_raw::text, false);

  raise notice 'PASS: fixtures — routes(visa NULL-channel=%, visa channel-matched=%), Sale(subtotal=%, fee=%), Return(gross_reversal=%, fee_reversal=%, actual refund event=%), Adjustment(charge=%, fee=%) processed at a DIFFERENT store than its Sale, Reversal(charge_impact=%, fee_impact_raw=%)',
    current_setting('p7t.route_visa'), v_route_chan, v_order.subtotal, v_order.fee, v_return.gross, v_return.fee, v_refund_event.id, v_adj_charge, v_adj_fee, v_reversal_gross, v_reversal_fee_raw;
end $$;

-- Sign Convention proof (Patch 7.1's own header, verbatim per source kind)
-- — actor 04 (settlements.create ONLY) is enough for both list_unsettled_
-- settlement_sources() and preview_settlement_batch(). Sale/Adjustment/
-- Adjustment-Reversal are queried on the CHANNEL-matched route (route_visa_
-- chan, §4); Return Refund Event/Return Fee Reversal are queried on the
-- NULL-channel route (route_visa, §1/§2/§4) — a single route can never match
-- both shapes at once under Patch 7.1's exact-match contract.
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare
  v_sale record; v_refundevt record; v_feerev record; v_adj record; v_adjrev record;
  v_expected_sale_gross numeric; v_expected_sale_fee numeric; v_expected_sale_expected numeric;
  v_expected_refundevt_gross numeric; v_expected_refundevt_fee numeric; v_expected_refundevt_expected numeric;
  v_expected_feerev_gross numeric; v_expected_feerev_fee numeric; v_expected_feerev_expected numeric;
  v_expected_adj_gross numeric; v_expected_adj_fee numeric; v_expected_adj_expected numeric;
  v_expected_adjrev_gross numeric; v_expected_adjrev_fee numeric; v_expected_adjrev_expected numeric;
  v_preview record;
begin
  select * into v_sale from public.list_unsettled_settlement_sources(
    current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1, null, current_setting('p7t.order1_number')
  ) where source_kind = 'sale' and source_event_id = current_setting('p7t.order1')::uuid;

  v_expected_sale_gross := current_setting('p7t.order1_subtotal')::numeric;
  v_expected_sale_fee := current_setting('p7t.order1_fee')::numeric;
  v_expected_sale_expected := v_expected_sale_gross - v_expected_sale_fee;
  if v_sale.gross_collection_impact::numeric <> v_expected_sale_gross or v_sale.provider_fee_impact::numeric <> v_expected_sale_fee or v_sale.expected_settlement_impact::numeric <> v_expected_sale_expected then
    raise exception 'FAIL Sign Convention A (Sale): expected gross=% fee=% expected=%, got gross=% fee=% expected=%',
      v_expected_sale_gross, v_expected_sale_fee, v_expected_sale_expected, v_sale.gross_collection_impact, v_sale.provider_fee_impact, v_sale.expected_settlement_impact;
  end if;

  -- B) Return Refund Event (§1) — gross = -e.amount, fee = 0 (the actual
  -- cash event carries no fee of its own — the fee credit is Return Fee
  -- Reversal below, an INDEPENDENT source).
  select * into v_refundevt from public.list_unsettled_settlement_sources(
    current_setting('p7t.route_visa')::uuid, public.business_today() - 1, public.business_today() + 1
  ) where source_kind = 'return_refund_event' and source_event_id = current_setting('p7t.refund_event1')::uuid;

  v_expected_refundevt_gross := -current_setting('p7t.return1_gross')::numeric;
  v_expected_refundevt_fee := 0;
  v_expected_refundevt_expected := v_expected_refundevt_gross - v_expected_refundevt_fee;
  if v_refundevt.gross_collection_impact::numeric <> v_expected_refundevt_gross or v_refundevt.provider_fee_impact::numeric <> v_expected_refundevt_fee or v_refundevt.expected_settlement_impact::numeric <> v_expected_refundevt_expected then
    raise exception 'FAIL Sign Convention B (Return Refund Event, §1): expected gross=% fee=% expected=%, got gross=% fee=% expected=%',
      v_expected_refundevt_gross, v_expected_refundevt_fee, v_expected_refundevt_expected, v_refundevt.gross_collection_impact, v_refundevt.provider_fee_impact, v_refundevt.expected_settlement_impact;
  end if;

  -- C) Return Fee Reversal (§2) — an INDEPENDENT source keyed to the Return
  -- header (sr.id), never the refund event. gross = 0, fee =
  -- -payment_fee_reversal_amount => expected = +payment_fee_reversal_amount
  -- (a fee credit). Hotfix 7.1.1 §1/§3 (CRITICAL): this candidate's route
  -- match now comes from the ORIGINAL SALE's own collection channel (via
  -- sales_returns.sales_order_id -> sales_orders), never a hardcoded NULL —
  -- order1 was created with a REAL channel (channel_direct), so
  -- return_fee_reversal now belongs to route_visa_chan, NOT route_visa
  -- (route_visa remains correct ONLY for return_refund_event/_reversal, the
  -- actual cash ledger, which still keys off refund_method_id with an
  -- implicit NULL channel — unchanged, §3).
  select * into v_feerev from public.list_unsettled_settlement_sources(
    current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1
  ) where source_kind = 'return_fee_reversal' and source_event_id = current_setting('p7t.return1')::uuid;

  v_expected_feerev_gross := 0;
  v_expected_feerev_fee := -current_setting('p7t.return1_fee')::numeric;
  v_expected_feerev_expected := v_expected_feerev_gross - v_expected_feerev_fee;
  if v_feerev.gross_collection_impact::numeric <> v_expected_feerev_gross or v_feerev.provider_fee_impact::numeric <> v_expected_feerev_fee or v_feerev.expected_settlement_impact::numeric <> v_expected_feerev_expected then
    raise exception 'FAIL Sign Convention C (Return Fee Reversal, §2): expected gross=% fee=% expected=%, got gross=% fee=% expected=%',
      v_expected_feerev_gross, v_expected_feerev_fee, v_expected_feerev_expected, v_feerev.gross_collection_impact, v_feerev.provider_fee_impact, v_feerev.expected_settlement_impact;
  end if;

  select * into v_adj from public.list_unsettled_settlement_sources(
    current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1
  ) where source_kind = 'adjustment_approved' and source_event_id = current_setting('p7t.adj1')::uuid;

  v_expected_adj_gross := current_setting('p7t.adj1_charge')::numeric;
  v_expected_adj_fee := current_setting('p7t.adj1_fee')::numeric;
  v_expected_adj_expected := v_expected_adj_gross - v_expected_adj_fee;
  if v_adj.gross_collection_impact::numeric <> v_expected_adj_gross or v_adj.provider_fee_impact::numeric <> v_expected_adj_fee or v_adj.expected_settlement_impact::numeric <> v_expected_adj_expected then
    raise exception 'FAIL Sign Convention D (Adjustment): expected gross=% fee=% expected=%, got gross=% fee=% expected=%',
      v_expected_adj_gross, v_expected_adj_fee, v_expected_adj_expected, v_adj.gross_collection_impact, v_adj.provider_fee_impact, v_adj.expected_settlement_impact;
  end if;

  select * into v_adjrev from public.list_unsettled_settlement_sources(
    current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1
  ) where source_kind = 'adjustment_reversal' and source_event_id = current_setting('p7t.adjrev1')::uuid;

  v_expected_adjrev_gross := current_setting('p7t.adjrev1_gross')::numeric;
  v_expected_adjrev_fee := -current_setting('p7t.adjrev1_feeraw')::numeric;
  v_expected_adjrev_expected := v_expected_adjrev_gross - v_expected_adjrev_fee;
  if v_adjrev.gross_collection_impact::numeric <> v_expected_adjrev_gross or v_adjrev.provider_fee_impact::numeric <> v_expected_adjrev_fee or v_adjrev.expected_settlement_impact::numeric <> v_expected_adjrev_expected then
    raise exception 'FAIL Sign Convention E (Adjustment Reversal): expected gross=% fee=% expected=%, got gross=% fee=% expected=%',
      v_expected_adjrev_gross, v_expected_adjrev_fee, v_expected_adjrev_expected, v_adjrev.gross_collection_impact, v_adjrev.provider_fee_impact, v_adjrev.expected_settlement_impact;
  end if;

  -- Three independent expectation sets — one per route (batch1 = channel
  -- route, section 3 below; batch1_ret = NULL-channel Return route, ONLY
  -- return_refund_event now (§1/§3); batch1_feerev = the SAME channel route
  -- as batch1, ONLY return_fee_reversal (§1/§3 moved it there — it is no
  -- longer a NULL-channel-only source).
  perform set_config('p7t.expect_gross', (v_expected_sale_gross + v_expected_adj_gross + v_expected_adjrev_gross)::text, false);
  perform set_config('p7t.expect_fee', (v_expected_sale_fee + v_expected_adj_fee + v_expected_adjrev_fee)::text, false);
  perform set_config('p7t.expect_before_batch_fee', (
    (v_expected_sale_gross + v_expected_adj_gross + v_expected_adjrev_gross)
    - (v_expected_sale_fee + v_expected_adj_fee + v_expected_adjrev_fee)
  )::text, false);

  -- batch1_ret (route_visa) — return_refund_event ALONE now.
  perform set_config('p7t.expect_ret_gross', v_expected_refundevt_gross::text, false);
  perform set_config('p7t.expect_ret_fee', v_expected_refundevt_fee::text, false);

  -- batch1_feerev (route_visa_chan) — return_fee_reversal ALONE.
  perform set_config('p7t.expect_feerev_gross', v_expected_feerev_gross::text, false);
  perform set_config('p7t.expect_feerev_fee', v_expected_feerev_fee::text, false);

  raise notice 'PASS: Sign Convention A/B/C/D/E — list_unsettled_settlement_sources() returns EXACTLY the signed gross/fee/expected figures Patch 7.1 documents for Sale/Return-Refund-Event(§1)/Return-Fee-Reversal(§2)/Adjustment/Adjustment-Reversal';

  -- preview_settlement_batch() totals — channel route (Sale + Adjustment +
  -- Adjustment Reversal), 3 sources.
  select * into v_preview from public.preview_settlement_batch(
    current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order1')),
      jsonb_build_object('source_kind', 'adjustment_approved', 'source_event_id', current_setting('p7t.adj1')),
      jsonb_build_object('source_kind', 'adjustment_reversal', 'source_event_id', current_setting('p7t.adjrev1'))
    ),
    public.business_today()
  );

  if jsonb_array_length(v_preview.lines) <> 3 then
    raise exception 'FAIL: preview_settlement_batch() (channel route) lines count expected 3, got %', jsonb_array_length(v_preview.lines);
  end if;
  if v_preview.gross_source_impact::numeric <> current_setting('p7t.expect_gross')::numeric then
    raise exception 'FAIL: preview gross_source_impact expected %, got %', current_setting('p7t.expect_gross'), v_preview.gross_source_impact;
  end if;
  if v_preview.provider_fee_impact::numeric <> current_setting('p7t.expect_fee')::numeric then
    raise exception 'FAIL: preview provider_fee_impact expected %, got %', current_setting('p7t.expect_fee'), v_preview.provider_fee_impact;
  end if;
  if v_preview.expected_before_batch_fee::numeric <> current_setting('p7t.expect_before_batch_fee')::numeric then
    raise exception 'FAIL: preview expected_before_batch_fee mismatch, expected %, got %', current_setting('p7t.expect_before_batch_fee'), v_preview.expected_before_batch_fee;
  end if;
  -- Hotfix 7.1.1 §9 — preview_settlement_batch() now returns
  -- configured_batch_fee/effective_batch_fee/batch_fee_overridden instead of
  -- a single batch_fee column; no override was passed above, so configured
  -- and effective must be equal and batch_fee_overridden must be false.
  if v_preview.configured_batch_fee::numeric <> 5.00 or v_preview.effective_batch_fee::numeric <> 5.00 or v_preview.batch_fee_overridden then
    raise exception 'FAIL: preview configured/effective batch fee expected the route''s configured 5.00 with no override, got configured=% effective=% overridden=%', v_preview.configured_batch_fee, v_preview.effective_batch_fee, v_preview.batch_fee_overridden;
  end if;
  if not v_preview.fee_version_resolved or v_preview.transaction_fee_strategy <> 'source_snapshot' then
    raise exception 'FAIL: preview fee_version_resolved/transaction_fee_strategy incorrect';
  end if;

  -- preview_settlement_batch() totals — NULL-channel Return route
  -- (route_visa), Return Refund Event ALONE now (Hotfix 7.1.1 §1/§3 moved
  -- Return Fee Reversal off this route — see below).
  select * into v_preview from public.preview_settlement_batch(
    current_setting('p7t.route_visa')::uuid, public.business_today() - 1, public.business_today() + 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'return_refund_event', 'source_event_id', current_setting('p7t.refund_event1'))
    ),
    public.business_today()
  );

  if jsonb_array_length(v_preview.lines) <> 1 then
    raise exception 'FAIL: preview_settlement_batch() (return route) lines count expected 1 (return_refund_event alone, §1/§3), got %', jsonb_array_length(v_preview.lines);
  end if;
  if v_preview.gross_source_impact::numeric <> current_setting('p7t.expect_ret_gross')::numeric then
    raise exception 'FAIL: preview (return route) gross_source_impact expected %, got %', current_setting('p7t.expect_ret_gross'), v_preview.gross_source_impact;
  end if;
  if v_preview.provider_fee_impact::numeric <> current_setting('p7t.expect_ret_fee')::numeric then
    raise exception 'FAIL: preview (return route) provider_fee_impact expected %, got %', current_setting('p7t.expect_ret_fee'), v_preview.provider_fee_impact;
  end if;

  -- preview_settlement_batch() totals — the CHANNEL route (route_visa_chan),
  -- Return Fee Reversal ALONE. Hotfix 7.1.1 §1/§3 (CRITICAL): this source's
  -- route now comes from the ORIGINAL SALE's own channel (order1 ->
  -- channel_direct), so it settles on the SAME route as the Sale/Adjustment
  -- sources above, never on the NULL-channel Return route.
  select * into v_preview from public.preview_settlement_batch(
    current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'return_fee_reversal', 'source_event_id', current_setting('p7t.return1'))
    ),
    public.business_today()
  );

  if jsonb_array_length(v_preview.lines) <> 1 then
    raise exception 'FAIL: preview_settlement_batch() (return_fee_reversal on channel route, §1/§3) lines count expected 1, got %', jsonb_array_length(v_preview.lines);
  end if;
  if v_preview.gross_source_impact::numeric <> current_setting('p7t.expect_feerev_gross')::numeric then
    raise exception 'FAIL: preview (return_fee_reversal on channel route) gross_source_impact expected %, got %', current_setting('p7t.expect_feerev_gross'), v_preview.gross_source_impact;
  end if;
  if v_preview.provider_fee_impact::numeric <> current_setting('p7t.expect_feerev_fee')::numeric then
    raise exception 'FAIL: preview (return_fee_reversal on channel route) provider_fee_impact expected %, got %', current_setting('p7t.expect_feerev_fee'), v_preview.provider_fee_impact;
  end if;

  raise notice 'PASS: preview_settlement_batch() totals match the sum of the signed candidate rows exactly on ALL THREE routes/source combinations — including return_fee_reversal now correctly settling on the ORIGINAL SALE''s channel route rather than a hardcoded NULL (Hotfix 7.1.1 §1/§3)';
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 3. Finalization (item 23) — THE authority function.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare
  v_batch record;
  v_batch_ret record;
  v_batch_feerev record;
begin
  select * into v_batch from public.create_draft_settlement_batch(current_setting('p7t.route_visa_chan')::uuid, public.business_today(), 'STMT-P7-1', 'دفعة تسوية 7 الرئيسية');
  perform set_config('p7t.batch1', v_batch.id::text, false);
  perform set_config('p7t.batch1_number', v_batch.settlement_number, false);

  -- A SECOND draft, on the NULL-channel Return route — for
  -- return_refund_event ALONE (the actual cash ledger, unchanged §3).
  select * into v_batch_ret from public.create_draft_settlement_batch(current_setting('p7t.route_visa')::uuid, public.business_today(), 'STMT-P7-1-RET', 'دفعة تسوية 7 المرتجعات');
  perform set_config('p7t.batch1_ret', v_batch_ret.id::text, false);

  -- A THIRD draft, on the SAME channel route as batch1 — Hotfix 7.1.1 §1/§3
  -- (CRITICAL) moved return_fee_reversal off the NULL-channel Return route
  -- onto the ORIGINAL SALE's own channel route, so it settles here instead
  -- of alongside return_refund_event. Kept as its own separate batch (rather
  -- than folded into batch1) purely to keep batch1's own long-standing
  -- 3-line assertions below untouched.
  select * into v_batch_feerev from public.create_draft_settlement_batch(current_setting('p7t.route_visa_chan')::uuid, public.business_today(), 'STMT-P7-1-FEEREV', 'دفعة تسوية 7 عكس رسوم المرتجع');
  perform set_config('p7t.batch1_feerev', v_batch_feerev.id::text, false);

  raise notice 'PASS: create_draft_settlement_batch() succeeded for a create-only actor, number=% (channel route) / % (return route) / % (return fee-reversal, §1/§3)', v_batch.settlement_number, v_batch_ret.settlement_number, v_batch_feerev.settlement_number;
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
declare
  v_result record;
  v_batch record;
  v_lines jsonb;
  v_line jsonb;
  v_denied boolean;
begin
  select * into v_result from public.finalize_settlement_batch(
    current_setting('p7t.batch1')::uuid, 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order1')),
      jsonb_build_object('source_kind', 'adjustment_approved', 'source_event_id', current_setting('p7t.adj1')),
      jsonb_build_object('source_kind', 'adjustment_reversal', 'source_event_id', current_setting('p7t.adjrev1'))
    ),
    null, null, null
  );
  if v_result.row_version <> 2 then
    raise exception 'FAIL: finalize row_version expected 2, got %', v_result.row_version;
  end if;

  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch1')::uuid);
  if v_batch.status <> 'finalized' or v_batch.effective_status <> 'finalized' then
    raise exception 'FAIL: batch status after finalize expected finalized, got % / %', v_batch.status, v_batch.effective_status;
  end if;
  if v_batch.original_gross_source_impact::numeric <> current_setting('p7t.expect_gross')::numeric then
    raise exception 'FAIL: finalized original_gross_source_impact expected %, got %', current_setting('p7t.expect_gross'), v_batch.original_gross_source_impact;
  end if;
  if v_batch.original_provider_fee_impact::numeric <> current_setting('p7t.expect_fee')::numeric then
    raise exception 'FAIL: finalized original_provider_fee_impact expected %, got %', current_setting('p7t.expect_fee'), v_batch.original_provider_fee_impact;
  end if;
  if v_batch.original_batch_fee::numeric <> 5.00 or v_batch.is_batch_fee_override then
    raise exception 'FAIL: finalized original_batch_fee expected 5.00 (no override), got % / %', v_batch.original_batch_fee, v_batch.is_batch_fee_override;
  end if;
  if v_batch.original_expected_before_batch_fee::numeric <> current_setting('p7t.expect_before_batch_fee')::numeric then
    raise exception 'FAIL: original_expected_before_batch_fee mismatch after finalize';
  end if;
  if v_batch.original_expected_bank_settlement::numeric <> (current_setting('p7t.expect_before_batch_fee')::numeric - 5.00) then
    raise exception 'FAIL: original_expected_bank_settlement expected before_batch_fee - 5.00, got %', v_batch.original_expected_bank_settlement;
  end if;
  if v_batch.settlement_calculation_version <> 2 then
    raise exception 'FAIL: settlement_calculation_version expected 2 (finalized under the Patch 7.1-corrected logic), got %', v_batch.settlement_calculation_version;
  end if;

  v_lines := v_batch.lines;
  if jsonb_array_length(v_lines) <> 3 then
    raise exception 'FAIL: settlement_batch_lines count expected 3 (sale+adjustment+adjustment_reversal), got %', jsonb_array_length(v_lines);
  end if;
  for v_line in select * from jsonb_array_elements(v_lines) loop
    if v_line ->> 'source_kind' = 'adjustment_approved' or v_line ->> 'source_kind' = 'adjustment_reversal' then
      if v_line ->> 'primary_store_name' <> 'فرع تسويات 7 - ب' then
        raise exception 'FAIL: an adjustment line''s primary_store_name (processing store) expected Store B, got %', v_line ->> 'primary_store_name';
      end if;
      if v_line ->> 'secondary_store_name' <> 'فرع تسويات 7 - أ' then
        raise exception 'FAIL: an adjustment line''s secondary_store_name (original sale store) expected Store A, got %', v_line ->> 'secondary_store_name';
      end if;
    end if;
  end loop;

  raise notice 'PASS: finalize_settlement_batch() — batch totals/settlement_calculation_version=2 correct, 3 immutable settlement_batch_lines snapshotted correctly (primary=processing store, secondary=original sale store for Adjustment lines)';

  -- Sources are now claimed — list_unsettled_settlement_sources() no longer
  -- offers them (item 25).
  if exists (
    select 1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1)
    where (source_kind, source_event_id) in (
      ('sale', current_setting('p7t.order1')::uuid),
      ('adjustment_approved', current_setting('p7t.adj1')::uuid), ('adjustment_reversal', current_setting('p7t.adjrev1')::uuid)
    )
  ) then
    raise exception 'FAIL: a claimed source is still offered by list_unsettled_settlement_sources() after finalization';
  end if;

  -- Re-finalizing an already-finalized batch fails.
  begin
    perform public.finalize_settlement_batch(current_setting('p7t.batch1')::uuid, 2, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order1'))), null, null, null);
    raise exception 'FAIL: re-finalizing an already-finalized batch was NOT rejected';
  exception when others then
    if sqlerrm not like '%ليست في حالة مسودة%' then raise; end if;
  end;

  raise notice 'PASS: settlement_source_claims block re-offering claimed sources; re-finalizing an already-finalized batch is rejected';
end $$;

-- Finalize batch1_ret — the NULL-channel Return route, return_refund_event
-- ALONE (Hotfix 7.1.1 §1/§3 moved return_fee_reversal off this route).
do $$
declare
  v_result record;
  v_batch record;
  v_lines jsonb;
  v_line jsonb;
begin
  select * into v_result from public.finalize_settlement_batch(
    current_setting('p7t.batch1_ret')::uuid, 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'return_refund_event', 'source_event_id', current_setting('p7t.refund_event1'))
    ),
    null, null, null
  );
  if v_result.row_version <> 2 then
    raise exception 'FAIL: finalize (return route) row_version expected 2, got %', v_result.row_version;
  end if;

  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch1_ret')::uuid);
  if v_batch.status <> 'finalized' then
    raise exception 'FAIL: batch1_ret status after finalize expected finalized, got %', v_batch.status;
  end if;
  if v_batch.original_gross_source_impact::numeric <> current_setting('p7t.expect_ret_gross')::numeric then
    raise exception 'FAIL: batch1_ret original_gross_source_impact expected %, got %', current_setting('p7t.expect_ret_gross'), v_batch.original_gross_source_impact;
  end if;
  if v_batch.original_provider_fee_impact::numeric <> current_setting('p7t.expect_ret_fee')::numeric then
    raise exception 'FAIL: batch1_ret original_provider_fee_impact expected %, got %', current_setting('p7t.expect_ret_fee'), v_batch.original_provider_fee_impact;
  end if;

  v_lines := v_batch.lines;
  if jsonb_array_length(v_lines) <> 1 then
    raise exception 'FAIL: batch1_ret settlement_batch_lines count expected 1 (return_refund_event alone, §1/§3), got %', jsonb_array_length(v_lines);
  end if;
  v_line := v_lines -> 0;
  if v_line ->> 'source_kind' <> 'return_refund_event' then
    raise exception 'FAIL: batch1_ret''s single line expected source_kind=return_refund_event, got %', v_line ->> 'source_kind';
  end if;
  if v_line ->> 'secondary_store_name' is not null then
    raise exception 'FAIL: a return_refund_event line must carry NO secondary store (Returns have no cross-store duality, §1), got %', v_line ->> 'secondary_store_name';
  end if;

  raise notice 'PASS: finalize_settlement_batch() on the NULL-channel Return route — return_refund_event(§1) settled alone, correctly excluding return_fee_reversal (moved to the channel route by Hotfix 7.1.1 §1/§3) and the dead return_refund/return_refund_reversal kinds';
end $$;

-- Finalize batch1_feerev — the SAME channel route as batch1, return_fee_
-- reversal ALONE (Hotfix 7.1.1 §1/§3, CRITICAL): its route now comes from
-- the ORIGINAL SALE's own collection channel via sales_returns.
-- sales_order_id -> sales_orders, never a hardcoded NULL.
do $$
declare
  v_result record;
  v_batch record;
  v_lines jsonb;
  v_line jsonb;
begin
  select * into v_result from public.finalize_settlement_batch(
    current_setting('p7t.batch1_feerev')::uuid, 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'return_fee_reversal', 'source_event_id', current_setting('p7t.return1'))
    ),
    null, null, null
  );
  if v_result.row_version <> 2 then
    raise exception 'FAIL: finalize (return_fee_reversal, channel route) row_version expected 2, got %', v_result.row_version;
  end if;

  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch1_feerev')::uuid);
  if v_batch.status <> 'finalized' then
    raise exception 'FAIL: batch1_feerev status after finalize expected finalized, got %', v_batch.status;
  end if;
  if v_batch.original_gross_source_impact::numeric <> current_setting('p7t.expect_feerev_gross')::numeric then
    raise exception 'FAIL: batch1_feerev original_gross_source_impact expected %, got %', current_setting('p7t.expect_feerev_gross'), v_batch.original_gross_source_impact;
  end if;
  if v_batch.original_provider_fee_impact::numeric <> current_setting('p7t.expect_feerev_fee')::numeric then
    raise exception 'FAIL: batch1_feerev original_provider_fee_impact expected %, got %', current_setting('p7t.expect_feerev_fee'), v_batch.original_provider_fee_impact;
  end if;

  v_lines := v_batch.lines;
  if jsonb_array_length(v_lines) <> 1 then
    raise exception 'FAIL: batch1_feerev settlement_batch_lines count expected 1, got %', jsonb_array_length(v_lines);
  end if;
  v_line := v_lines -> 0;
  if v_line ->> 'source_kind' <> 'return_fee_reversal' then
    raise exception 'FAIL: batch1_feerev''s single line expected source_kind=return_fee_reversal, got %', v_line ->> 'source_kind';
  end if;

  raise notice 'PASS: finalize_settlement_batch() settled return_fee_reversal(§2) on the ORIGINAL SALE''s own channel route (Hotfix 7.1.1 §1/§3, CRITICAL) instead of a hardcoded NULL-channel route';
end $$;

-- Finalizing with a stale/already-claimed selection fails cleanly (layer 1
-- of the double-claim safety net, 0178's own header).
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare v_batch2 record; begin
  select * into v_batch2 from public.create_draft_settlement_batch(current_setting('p7t.route_visa_chan')::uuid, public.business_today());
  perform set_config('p7t.batch_stale', v_batch2.id::text, false);
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
declare v_rejected boolean := false; begin
  begin
    perform public.finalize_settlement_batch(current_setting('p7t.batch_stale')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order1'))), null, null, null);
  exception when others then
    if sqlerrm like '%بعض المصادر المختارة لم تعد متاحة للتسوية%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: finalizing with an already-claimed source was NOT rejected'; end if;
  raise notice 'PASS: finalizing a draft batch selecting an already-claimed source is rejected with the layer-1 clean error';
end $$;

-- TRUSTED-write proof (item 38/0172) — even a raw superuser UPDATE of a
-- frozen financial/snapshot column on a finalized batch is blocked by
-- settlement_batches_reject_financial_mutation. Not merely an RPC-level
-- proof — this bypasses every RPC entirely.
reset role;
reset request.jwt.claims;
do $$
declare v_rejected boolean := false; begin
  begin
    update public.settlement_batches set gross_source_impact = gross_source_impact + 1 where id = current_setting('p7t.batch1')::uuid;
  exception when others then
    if sqlerrm like '%الحقائق المالية%اللقطة%غير قابلة للتعديل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: a raw superuser UPDATE of gross_source_impact on a finalized batch was NOT rejected by settlement_batches_reject_financial_mutation'; end if;
  raise notice 'PASS: TRUSTED-write proof — settlement_batches_reject_financial_mutation blocks a raw direct UPDATE of a frozen financial column, even as superuser';
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 4. Batch fee override + closed-day override — both permission-gated, both
-- requiring a mandatory reason.
-- ---------------------------------------------------------------------------
do $$
declare v_route_cash uuid; v_order2 record; v_order3 record; v_order4 record; begin
  -- §4 — channel_direct specified explicitly: a NULL-channel route can never
  -- match these Sales (which always carry a real, NOT NULL, collection_
  -- channel_id) under Patch 7.1's exact IS NOT DISTINCT FROM matching.
  select public.create_settlement_route('p7-cash-route', 'مسار نقد 7', 'payment_collection', null, current_setting('p7t.pm_cash')::uuid, current_setting('p7t.channel_direct')::uuid) into v_route_cash;
  perform set_config('p7t.route_cash', v_route_cash::text, false);
  perform public.create_settlement_route_fee_version(v_route_cash, public.business_today() - 30, 'source_snapshot', null, null, null, 10.00, null, 'p7 cash fee');

  select * into v_order2 from public.create_sales_order(
    current_setting('p7t.store_a')::uuid, public.business_today(), current_setting('p7t.pm_cash')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 1.0000, 'sale_price', 500.00))
  );
  perform set_config('p7t.order2', v_order2.id::text, false);

  select * into v_order3 from public.create_sales_order(
    current_setting('p7t.store_a')::uuid, public.business_today(), current_setting('p7t.pm_cash')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 1.0000, 'sale_price', 300.00))
  );
  perform set_config('p7t.order3', v_order3.id::text, false);

  select * into v_order4 from public.create_sales_order(
    current_setting('p7t.store_d')::uuid, public.business_today(), current_setting('p7t.pm_cash')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 1.0000, 'sale_price', 150.00))
  );
  perform set_config('p7t.order4', v_order4.id::text, false);

  perform public.close_sales_day(current_setting('p7t.store_d')::uuid, public.business_today(), 'إغلاق اختباري تسويات 7');
end $$;

-- 4a. Batch fee override.
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$ declare v_b record; begin
  select * into v_b from public.create_draft_settlement_batch(current_setting('p7t.route_cash')::uuid, public.business_today());
  perform set_config('p7t.batch2', v_b.id::text, false);
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$ declare v_rejected boolean := false; begin
  begin
    perform public.finalize_settlement_batch(current_setting('p7t.batch2')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order2'))), 25.00, 'تجاوز اختباري', null);
  exception when others then
    if sqlerrm like '%صلاحية تجاوز رسوم الدفعة الافتراضية%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: a finalize-only actor (no override_batch_fee) was able to override the batch fee'; end if;
  raise notice 'PASS: finalize-only actor cannot override the batch fee';
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000007","role":"authenticated"}';
do $$ declare v_rejected boolean := false; v_batch record; begin
  begin
    perform public.finalize_settlement_batch(current_setting('p7t.batch2')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order2'))), 25.00, null, null);
  exception when others then
    if sqlerrm like '%يجب إدخال سبب لتجاوز رسوم الدفعة الافتراضية%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: batch fee override without a reason was NOT rejected'; end if;

  begin
    perform public.finalize_settlement_batch(current_setting('p7t.batch2')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order2'))), -1.00, 'تجاوز سالب', null);
    raise exception 'FAIL: a NEGATIVE batch fee override was NOT rejected';
  exception when others then
    if sqlerrm not like '%لا يمكن أن تكون سالبة%' then raise; end if;
  end;

  perform public.finalize_settlement_batch(current_setting('p7t.batch2')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order2'))), 25.00, 'تجاوز اختباري 7', null);
  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch2')::uuid);
  if v_batch.original_batch_fee::numeric <> 25.00 or not v_batch.is_batch_fee_override or v_batch.configured_batch_fee::numeric <> 10.00 or v_batch.override_reason <> 'تجاوز اختباري 7' then
    raise exception 'FAIL: batch fee override did not snapshot correctly — batch_fee=%, is_override=%, configured=%, reason=%', v_batch.original_batch_fee, v_batch.is_batch_fee_override, v_batch.configured_batch_fee, v_batch.override_reason;
  end if;
  if v_batch.original_expected_bank_settlement::numeric <> 475.00 then
    raise exception 'FAIL: original_expected_bank_settlement expected 500.00 - 0.00 - 25.00 = 475.00, got %', v_batch.original_expected_bank_settlement;
  end if;
  raise notice 'PASS: 4a batch fee override — permission-gated, mandatory reason, negative rejected, snapshot correct (batch_fee=25.00 overriding configured 10.00)';
end $$;

-- 4b. Closed-day override.
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$ declare v_b record; begin
  select * into v_b from public.create_draft_settlement_batch(current_setting('p7t.route_cash')::uuid, public.business_today());
  perform set_config('p7t.batch4', v_b.id::text, false);
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$ declare v_rejected boolean := false; begin
  begin
    perform public.finalize_settlement_batch(current_setting('p7t.batch4')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order4'))), null, null, null);
  exception when others then
    if sqlerrm like '%في يوم مقفل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: finalizing a source on a closed business day, without process_closed_day, was NOT rejected'; end if;
  raise notice 'PASS: finalize-only actor (no process_closed_day) is rejected on a closed-day source';
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$ declare v_rejected boolean := false; v_batch record; begin
  begin
    perform public.finalize_settlement_batch(current_setting('p7t.batch4')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order4'))), null, null, null);
  exception when others then
    if sqlerrm like '%يجب إدخال سبب لاعتماد تسوية في يوم مقفل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: closed-day finalization WITHOUT a reason was NOT rejected'; end if;

  perform public.finalize_settlement_batch(current_setting('p7t.batch4')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order4'))), null, null, 'معالجة يوم مقفل — اختبار تسويات 7');
  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch4')::uuid);
  if v_batch.status <> 'finalized' then raise exception 'FAIL: closed-day finalize with a reason did not succeed'; end if;
  raise notice 'PASS: 4b closed-day override — permission-gated, mandatory reason, succeeds once both are satisfied';
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 5. Bank movement + reconcile + cancel — full lifecycle.
-- ---------------------------------------------------------------------------
-- 5a. Zero-variance reconcile (batch2, expected_bank_settlement=475.00),
-- then reverse the movement (max-one-reversal enforced), then cancel —
-- claims released, batch row itself untouched by cancellation.
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000008","role":"authenticated"}';
do $$ declare v_event uuid; begin
  select public.record_settlement_bank_movement(current_setting('p7t.batch2')::uuid, public.business_today(), 475.00, 'REF-BANK-P7-1', null) into v_event;
  perform set_config('p7t.batch2_event', v_event::text, false);
  raise notice 'PASS: record_settlement_bank_movement() succeeded for a record_bank_movement-only actor';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000009","role":"authenticated"}';
do $$ declare v_result record; begin
  select * into v_result from public.reconcile_settlement_batch(current_setting('p7t.batch2')::uuid, 2, null);
  if v_result.actual_bank_movement::numeric <> 475.00 or v_result.variance::numeric <> 0 then
    raise exception 'FAIL: zero-variance reconcile expected actual=475.00 variance=0, got actual=% variance=%', v_result.actual_bank_movement, v_result.variance;
  end if;
  raise notice 'PASS: 5a zero-variance reconcile succeeds for settlements.reconcile alone, no reason required';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000008","role":"authenticated"}';
do $$ declare v_reversal_id uuid; v_rejected boolean := false; begin
  select public.reverse_settlement_bank_movement(current_setting('p7t.batch2_event')::uuid, public.business_today(), 'عكس اختباري تسويات 7') into v_reversal_id;

  begin
    perform public.reverse_settlement_bank_movement(current_setting('p7t.batch2_event')::uuid, public.business_today(), 'محاولة عكس ثانية');
  exception when others then
    if sqlerrm like '%هذه الحركة البنكية مُعكوسة بالفعل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: a SECOND reversal of the same bank movement event was NOT rejected'; end if;
  raise notice 'PASS: 5a max-one-reversal enforced on a bank movement event';
end $$;

reset role; reset request.jwt.claims;
do $$ declare v_before record; begin
  select status, row_version, gross_source_impact, expected_bank_settlement into v_before from public.settlement_batches where id = current_setting('p7t.batch2')::uuid;
  perform set_config('p7t.batch2_status_before', v_before.status, false);
  perform set_config('p7t.batch2_rowversion_before', v_before.row_version::text, false);
  perform set_config('p7t.batch2_gross_before', v_before.gross_source_impact::text, false);
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000011","role":"authenticated"}';
do $$ declare v_batch record; begin
  perform public.cancel_settlement_batch(current_setting('p7t.batch2')::uuid, 3, public.business_today(), 'إلغاء اختباري تسويات 7');
  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch2')::uuid);
  if v_batch.effective_status <> 'cancelled' then
    raise exception 'FAIL: effective_status after cancel_settlement_batch expected cancelled, got %', v_batch.effective_status;
  end if;
  if v_batch.status <> current_setting('p7t.batch2_status_before') then
    raise exception 'FAIL: cancellation must NEVER touch settlement_batches.status itself — expected %, got %', current_setting('p7t.batch2_status_before'), v_batch.status;
  end if;
  raise notice 'PASS: 5a cancel_settlement_batch() sets effective_status=cancelled while the underlying status column stays %', v_batch.status;
end $$;

reset role; reset request.jwt.claims;
do $$ declare v_after record; begin
  select status, row_version, gross_source_impact into v_after from public.settlement_batches where id = current_setting('p7t.batch2')::uuid;
  if v_after.status <> current_setting('p7t.batch2_status_before')
    or v_after.row_version <> current_setting('p7t.batch2_rowversion_before')::bigint
    or v_after.gross_source_impact <> current_setting('p7t.batch2_gross_before')::numeric then
    raise exception 'FAIL: RAW settlement_batches row was mutated by cancel_settlement_batch() — before (status=%, row_version=%, gross=%) after (status=%, row_version=%, gross=%)',
      current_setting('p7t.batch2_status_before'), current_setting('p7t.batch2_rowversion_before'), current_setting('p7t.batch2_gross_before'),
      v_after.status, v_after.row_version, v_after.gross_source_impact;
  end if;
  raise notice 'PASS: 5a raw settlement_batches row (status/row_version/gross_source_impact) is BYTE-FOR-BYTE untouched by cancellation, proven via a direct superuser column comparison before/after';
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$ begin
  if not exists (
    select 1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_cash')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'sale' and source_event_id = current_setting('p7t.order2')::uuid
  ) then
    raise exception 'FAIL: the cancelled batch''s source did not become reclaimable again via list_unsettled_settlement_sources()';
  end if;
  raise notice 'PASS: 5a cancellation released the claim — order2''s Sale is reclaimable again via list_unsettled_settlement_sources()';
end $$;

-- 5b. Nonzero-variance reconcile (batch3, expected_bank_settlement = 300.00
-- - 0.00 - 10.00 = 290.00, actual movement = 300.00 -> variance=+10.00).
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$ declare v_b record; begin
  select * into v_b from public.create_draft_settlement_batch(current_setting('p7t.route_cash')::uuid, public.business_today());
  perform set_config('p7t.batch3', v_b.id::text, false);
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$ declare v_batch record; begin
  perform public.finalize_settlement_batch(current_setting('p7t.batch3')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order3'))), null, null, null);
  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch3')::uuid);
  if v_batch.original_expected_bank_settlement::numeric <> 290.00 then
    raise exception 'FAIL: batch3 original_expected_bank_settlement fixture assumption broken, expected 290.00, got %', v_batch.original_expected_bank_settlement;
  end if;
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000008","role":"authenticated"}';
do $$ declare v_event uuid; begin
  select public.record_settlement_bank_movement(current_setting('p7t.batch3')::uuid, public.business_today(), 300.00, 'REF-BANK-P7-2', null) into v_event;
  perform set_config('p7t.batch3_event', v_event::text, false);
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000009","role":"authenticated"}';
do $$ declare v_rejected boolean := false; begin
  begin
    perform public.reconcile_settlement_batch(current_setting('p7t.batch3')::uuid, 2, null);
  exception when others then
    if sqlerrm like '%يوجد فرق مطابقة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: a reconcile-only actor (no reconcile_variance) reconciled a NONZERO-variance batch'; end if;
  raise notice 'PASS: reconcile-only actor is rejected on a nonzero-variance batch';
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000010","role":"authenticated"}';
do $$ declare v_rejected boolean := false; v_result record; begin
  begin
    perform public.reconcile_settlement_batch(current_setting('p7t.batch3')::uuid, 2, null);
  exception when others then
    if sqlerrm like '%يجب إدخال سبب لفرق المطابقة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: nonzero-variance reconcile WITHOUT a reason was NOT rejected'; end if;

  select * into v_result from public.reconcile_settlement_batch(current_setting('p7t.batch3')::uuid, 2, 'فرق مطابقة اختباري تسويات 7');
  if v_result.variance::numeric <> 10.00 then
    raise exception 'FAIL: nonzero-variance reconcile expected variance=10.00, got %', v_result.variance;
  end if;
  raise notice 'PASS: 5b nonzero-variance reconcile requires settlements.reconcile_variance + a mandatory reason, variance=10.00 computed correctly';
end $$;

-- Reverse + cancel batch3 too, for a clean second full lifecycle proof.
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000008","role":"authenticated"}';
do $$ begin perform public.reverse_settlement_bank_movement(current_setting('p7t.batch3_event')::uuid, public.business_today(), 'عكس فرق المطابقة 7'); end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000011","role":"authenticated"}';
do $$ begin perform public.cancel_settlement_batch(current_setting('p7t.batch3')::uuid, 3, public.business_today(), 'إلغاء دفعة فرق المطابقة 7'); end $$;

-- 5c. Wrong-status denials via a never-finalized draft batch: record_
-- settlement_bank_movement/reconcile/cancel on a draft.
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$ declare v_b record; begin
  select * into v_b from public.create_draft_settlement_batch(current_setting('p7t.route_cash')::uuid, public.business_today());
  perform set_config('p7t.batch5_draft', v_b.id::text, false);
end $$;
do $$ declare v_rejected boolean; begin
  set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000008","role":"authenticated"}';
  v_rejected := false;
  begin perform public.record_settlement_bank_movement(current_setting('p7t.batch5_draft')::uuid, public.business_today(), 1.00, null, null);
  exception when others then if sqlerrm like '%ما زالت مسودة%' then v_rejected := true; else raise; end if; end;
  if not v_rejected then raise exception 'FAIL: recording a bank movement against a DRAFT batch was NOT rejected'; end if;

  set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000009","role":"authenticated"}';
  v_rejected := false;
  begin perform public.reconcile_settlement_batch(current_setting('p7t.batch5_draft')::uuid, 1, null);
  exception when others then if sqlerrm like '%ما زالت مسودة%' then v_rejected := true; else raise; end if; end;
  if not v_rejected then raise exception 'FAIL: reconciling a DRAFT batch was NOT rejected'; end if;

  set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000011","role":"authenticated"}';
  v_rejected := false;
  begin perform public.cancel_settlement_batch(current_setting('p7t.batch5_draft')::uuid, 1, public.business_today(), 'محاولة إلغاء مسودة');
  exception when others then if sqlerrm like '%ما زالت مسودة%' then v_rejected := true; else raise; end if; end;
  if not v_rejected then raise exception 'FAIL: cancelling a DRAFT batch was NOT rejected'; end if;

  raise notice 'PASS: 5c bank-movement/reconcile/cancel all correctly reject a still-DRAFT batch';
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 6. Read RPCs — money-field redaction, effective_status derivation, and
-- Patch 7.1 §6's whole-batch all-or-nothing store privacy (replacing 0182's
-- OLD per-line OR-rule: a batch with even ONE invisible-store line was
-- previously shown with that line hidden but every header/aggregate figure
-- still computed over ALL lines including the hidden one — a partial-batch
-- leak. Now the ENTIRE batch fails closed, identically to a genuinely
-- missing id, the moment even one line's store is invisible).
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$ declare v_row record; v_batch record; begin
  select * into v_row from public.list_settlement_batches(null, null, null, null, current_setting('p7t.batch1_number'));
  if v_row.id is null then raise exception 'FAIL: settlements.view-only actor could not list the batch at all (operational visibility must remain)'; end if;
  if v_row.status is null or v_row.route_code is null then
    raise exception 'FAIL: settlements.view-only actor should still see operational fields (status/route_code)';
  end if;
  if v_row.source_count is null then
    raise exception 'FAIL: source_count (§25) is operational, not financial — must stay visible without settlements.view_financials';
  end if;
  if v_row.original_gross_source_impact is not null or v_row.original_provider_fee_impact is not null or v_row.original_expected_bank_settlement is not null
     or v_row.effective_actual_settlement_contribution is not null or v_row.effective_variance_contribution is not null then
    raise exception 'FAIL: settlements.view-only actor (no view_financials) saw a money figure via list_settlement_batches()';
  end if;

  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch1')::uuid);
  if v_batch.status is null then raise exception 'FAIL: view-only actor could not read batch header at all'; end if;
  if v_batch.original_gross_source_impact is not null or v_batch.original_expected_bank_settlement is not null or v_batch.transaction_fee_strategy is not null then
    raise exception 'FAIL: settlements.view-only actor saw a money/financial-config figure via get_settlement_batch()';
  end if;
  if v_batch.lines <> '[]'::jsonb or v_batch.bank_movements <> '[]'::jsonb then
    raise exception 'FAIL: settlements.view-only actor saw line/bank-movement detail via get_settlement_batch() — must be empty, never redacted-but-present';
  end if;
  raise notice 'PASS: 6a settlements.view alone — operational fields (incl. source_count) visible, every money figure NULL, lines/bank_movements empty (item 40)';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$ declare v_row record; v_batch record; begin
  select * into v_row from public.list_settlement_batches(null, null, null, null, current_setting('p7t.batch1_number'));
  if v_row.original_gross_source_impact::numeric <> current_setting('p7t.expect_gross')::numeric then
    raise exception 'FAIL: view_financials actor should see the real original_gross_source_impact via list_settlement_batches(), expected %, got %', current_setting('p7t.expect_gross'), v_row.original_gross_source_impact;
  end if;
  if v_row.source_count <> 3 then
    raise exception 'FAIL: batch1 source_count (§25) expected 3, got %', v_row.source_count;
  end if;

  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch1')::uuid);
  if v_batch.lines is null or jsonb_array_length(v_batch.lines) <> 3 then
    raise exception 'FAIL: a view_financials actor with full store scope should see all 3 lines, got %', v_batch.lines;
  end if;
  raise notice 'PASS: 6a settlements.view_financials — real money figures + full line detail + source_count visible';
end $$;

-- effective_status derivation — batch2 was cancelled in section 5. Named
-- parameters used for p_limit/p_offset — list_settlement_batches() (0191)
-- inserted 8 new filter parameters BEFORE the old trailing p_limit/p_offset
-- positions, so a positional 7-arg call from before Patch 7.1 would silently
-- misfire against the new signature.
do $$ declare v_num text; v_row record; begin
  select settlement_number into v_num from public.list_settlement_batches(p_settlement_route_id := current_setting('p7t.route_cash')::uuid, p_limit := 200, p_offset := 0) where id = current_setting('p7t.batch2')::uuid;
  perform set_config('p7t.batch2_number', v_num, false);
  -- effective_status must derive 'cancelled' for batch2 even though its raw
  -- status column stays 'reconciled' (proven again here via the read RPC).
  select * into v_row from public.list_settlement_batches(null, current_setting('p7t.route_cash')::uuid, null, null, v_num);
  if v_row.effective_status <> 'cancelled' then
    raise exception 'FAIL: list_settlement_batches() effective_status for the cancelled batch2 expected cancelled, got %', v_row.effective_status;
  end if;
  raise notice 'PASS: 6b effective_status is derived from cancellation existence (list_settlement_batches), never a stored status value';
end $$;

-- §6 whole-batch all-or-nothing store privacy — actor 12 (Store-A-only)
-- cannot see Store B at all; batch1 contains Adjustment lines whose PRIMARY
-- store (the processing store) is Store B, so the ENTIRE batch1 — header,
-- every aggregate, every line, even the Sale line whose OWN store (A) IS
-- visible — is now invisible to actor 12 (never "the lines I can't see are
-- hidden, the rest stays"). batch1_ret (both lines primary=Store A, no
-- secondary store at all — Returns carry no cross-store duality) remains
-- FULLY visible to actor 12: the same actor, same store scope, the ONLY
-- difference is whether any one line's store is invisible — proving this is
-- truly a per-BATCH gate, not a blanket "store-scoped actors see less".
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000012","role":"authenticated"}';
do $$ declare v_rejected boolean := false; v_batch record; begin
  begin
    perform public.get_settlement_batch(current_setting('p7t.batch1')::uuid);
    raise exception 'FAIL: a Store-A-only actor (cannot see Store B) was able to read batch1, which contains an Adjustment line whose primary store is Store B (§6)';
  exception when others then
    if sqlerrm like '%دفعة التسوية غير موجودة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: batch1 was not rejected for the Store-A-only actor'; end if;

  -- Hotfix 7.1.1 §1/§3 moved return_fee_reversal off this route (it now
  -- settles on route_visa_chan as its own batch, batch1_feerev) — batch1_ret
  -- now carries return_refund_event ALONE.
  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch1_ret')::uuid);
  if v_batch.status is null or jsonb_array_length(v_batch.lines) <> 1 then
    raise exception 'FAIL: a Store-A-only actor should see batch1_ret''s one line (primary=Store A, no secondary store), got %', v_batch.lines;
  end if;

  if exists (select 1 from public.list_settlement_batches(p_limit := 500) l where l.id = current_setting('p7t.batch1')::uuid) then
    raise exception 'FAIL: batch1 must be entirely ABSENT from list_settlement_batches() for the Store-A-only actor, not merely have hidden lines';
  end if;

  raise notice 'PASS: 6c §6 whole-batch privacy — batch1 (one invisible-store line) is entirely invisible (get + list) to a Store-A-only actor; batch1_ret (its one line Store-A-visible) remains fully visible to the SAME actor';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000013","role":"authenticated"}';
do $$ declare v_rejected boolean; begin
  v_rejected := false;
  begin
    perform public.get_settlement_batch(current_setting('p7t.batch1')::uuid);
  exception when others then
    if sqlerrm like '%دفعة التسوية غير موجودة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: batch1 was not rejected for the Store-C-only actor'; end if;

  v_rejected := false;
  begin
    perform public.get_settlement_batch(current_setting('p7t.batch1_ret')::uuid);
  exception when others then
    if sqlerrm like '%دفعة التسوية غير موجودة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL: batch1_ret (Store A only) was not rejected for the Store-C-only actor'; end if;

  raise notice 'PASS: 6c Store-C-only actor (neither Store A nor B visible) cannot see batch1 OR batch1_ret at all — fails closed with the SAME not-found error a genuinely missing id would raise, never distinguishable';
end $$;

-- settlement_store_filter_lookups() — scoped to the actor's own visible
-- stores.
do $$ declare v_count integer; begin
  select count(*) into v_count from public.settlement_store_filter_lookups();
  if v_count <> 1 then raise exception 'FAIL: settlement_store_filter_lookups() for a Store-C-only actor expected exactly 1 store, got %', v_count; end if;
  raise notice 'PASS: 6d settlement_store_filter_lookups() scoped to the actor''s own visible stores';
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 7. Permission-matrix denials — one denial per RPC family for an actor
-- (14 = zero settlements.* permissions) missing the specific permission.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000014","role":"authenticated"}';
do $$
declare v_denied boolean;
begin
  v_denied := false;
  begin perform public.list_unsettled_settlement_sources(current_setting('p7t.route_visa')::uuid, public.business_today(), public.business_today());
  exception when others then if sqlerrm like '%صلاحية إنشاء تسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: list_unsettled_settlement_sources() did not require settlements.create'; end if;

  v_denied := false;
  begin perform public.preview_settlement_batch(current_setting('p7t.route_visa')::uuid, public.business_today(), public.business_today(), jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order1'))));
  exception when others then if sqlerrm like '%صلاحية إنشاء تسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: preview_settlement_batch() did not require settlements.create'; end if;

  v_denied := false;
  begin perform public.create_draft_settlement_batch(current_setting('p7t.route_visa')::uuid, public.business_today());
  exception when others then if sqlerrm like '%صلاحية إنشاء تسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: create_draft_settlement_batch() did not require settlements.create'; end if;

  v_denied := false;
  begin perform public.finalize_settlement_batch(current_setting('p7t.batch5_draft')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order1'))), null, null, null);
  exception when others then if sqlerrm like '%صلاحية اعتماد دفعة تسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: finalize_settlement_batch() did not require settlements.finalize'; end if;

  v_denied := false;
  begin perform public.record_settlement_bank_movement(current_setting('p7t.batch1')::uuid, public.business_today(), 1.00, null, null);
  exception when others then if sqlerrm like '%صلاحية تسجيل حركة بنكية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: record_settlement_bank_movement() did not require settlements.record_bank_movement'; end if;

  v_denied := false;
  begin perform public.reverse_settlement_bank_movement(current_setting('p7t.batch3_event')::uuid, public.business_today(), 'سبب');
  exception when others then if sqlerrm like '%صلاحية تسجيل حركة بنكية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: reverse_settlement_bank_movement() did not require settlements.record_bank_movement'; end if;

  v_denied := false;
  begin perform public.reconcile_settlement_batch(current_setting('p7t.batch1')::uuid, 2, null);
  exception when others then if sqlerrm like '%صلاحية مطابقة دفعة تسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: reconcile_settlement_batch() did not require settlements.reconcile'; end if;

  v_denied := false;
  begin perform public.cancel_settlement_batch(current_setting('p7t.batch1')::uuid, 2, public.business_today(), 'سبب');
  exception when others then if sqlerrm like '%صلاحية إلغاء دفعة تسوية%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: cancel_settlement_batch() did not require settlements.cancel'; end if;

  v_denied := false;
  begin perform public.get_settlement_batch(current_setting('p7t.batch1')::uuid);
  exception when others then if sqlerrm like '%صلاحية عرض التسويات%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: get_settlement_batch() did not require settlements.view'; end if;

  v_denied := false;
  begin perform public.list_settlement_batches();
  exception when others then if sqlerrm like '%صلاحية عرض التسويات%' then v_denied := true; else raise; end if; end;
  if not v_denied then raise exception 'FAIL: list_settlement_batches() did not require settlements.view'; end if;

  raise notice 'PASS: 7 — every settlements RPC family rejects an actor with ZERO settlements.* permissions (create/finalize/record_bank_movement/reconcile/cancel/view)';
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ============================================================================
-- 8. Patch 7.1 §31 — comprehensive NEW coverage for scenarios sections 0-7
-- never touched at all. Fixtures reuse the actors/stores/master data from
-- section 0; new config keys are prefixed 'p7t.s8_*' to stay visually
-- distinct from the sections-0-7 fixtures they build alongside. Actor 01
-- (full permissions) is used for fixture-building AND read-back throughout
-- unless a subsection specifically needs a narrower actor to prove a
-- permission/visibility boundary.
-- ============================================================================
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 8.1 Actual refund events (§1/§3) — split events on TWO DIFFERENT refund
-- methods (route match uses the EVENT's own method, never the original
-- sale's), target != actual, reversal of ONE event only (the other stays
-- untouched), and the administrative reverse_sales_return() proven NOT to
-- fabricate any cash source (only a return_fee_reversal_reversal, §2).
-- ---------------------------------------------------------------------------
do $$
declare v_route_cash_null uuid; begin
  select public.create_settlement_route('p7-cash-null-route', 'مسار نقد 7 (بدون قناة)', 'payment_collection', null, current_setting('p7t.pm_cash')::uuid) into v_route_cash_null;
  perform set_config('p7t.route_cash_null', v_route_cash_null::text, false);
  perform public.create_settlement_route_fee_version(v_route_cash_null, public.business_today() - 30, 'source_snapshot', null, null, null, 0, null, 'p7 s8 cash-null fee');
  raise notice 'PASS: 8.1 setup — a NULL-channel pm_cash route (route_cash_null) for the split-refund-method fixture below';
end $$;

do $$
declare
  v_order record; v_row record; v_event1 record; v_event2 record; v_reversal record;
  v_c1 record; v_c2 record; v_c1_after record; v_c2rev record; v_feerev record;
  v_fee_before numeric;
begin
  select * into v_row from public.create_sales_order(
    current_setting('p7t.store_a')::uuid, public.business_today(),
    current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 2.0000, 'sale_price', 2000.00)),
    'عميل تسوية 7 - س8', '0522222208', null
  );
  perform set_config('p7t.s8_order', v_row.id::text, false);

  select (public.get_sales_order(v_row.id) ->> 'row_version')::bigint as row_version,
         (public.get_sales_order(v_row.id) -> 'items' -> 0 ->> 'id')::uuid as item_id
  into v_order;

  select * into v_row from public.create_sales_return(
    current_setting('p7t.s8_order')::uuid, current_setting('p7t.store_a')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_order.item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار تسويات 7 - س8')),
    v_order.row_version, 'collected', 800.00,
    p_refund_difference_reason := 'اختبار تسويات 7 - س8 — استرداد جزئي متعمد (800 هدف، 500 مسدد فعليًا عبر حدثين، 200 منهما معكوس)'
  );
  perform set_config('p7t.s8_return', v_row.id::text, false);
  perform public.approve_sales_return(v_row.id, (public.get_sales_return(v_row.id) ->> 'row_version')::bigint);

  select (public.get_sales_return(current_setting('p7t.s8_return')::uuid) ->> 'payment_fee_reversal_amount')::numeric into v_fee_before;
  perform set_config('p7t.s8_return_fee', v_fee_before::text, false);
  if v_fee_before <= 0 then
    raise exception 'FAIL: fixture assumption broken — the s8 return must carry a NONZERO payment_fee_reversal_amount, got %', v_fee_before;
  end if;

  -- Split, on TWO DIFFERENT methods — event1 on pm_visa (matches the
  -- original sale's own method), event2 on pm_cash (deliberately DIFFERENT
  -- — §1/§3-E: route match uses the EVENT's own refund_method_id, never the
  -- original sale's).
  select * into v_event1 from public.record_sales_return_refund(
    current_setting('p7t.s8_return')::uuid, 300.00, current_setting('p7t.pm_visa')::uuid,
    public.business_today(), 'دفعة أولى — س8 (نفس طريقة البيع)'
  );
  perform set_config('p7t.s8_event1', v_event1.id::text, false);

  select * into v_event2 from public.record_sales_return_refund(
    current_setting('p7t.s8_return')::uuid, 200.00, current_setting('p7t.pm_cash')::uuid,
    public.business_today(), 'دفعة ثانية — س8 (طريقة مختلفة عن طريقة البيع)'
  );
  perform set_config('p7t.s8_event2', v_event2.id::text, false);

  -- target(800.00) != actual-so-far (300+200=500.00) — Patch 7.1 §1's own
  -- point: gross sourcing tracks the REAL cash ledger, never the
  -- administrative target.
  select * into v_c1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'return_refund_event' and source_event_id = v_event1.id;
  if v_c1.gross_collection_impact::numeric <> -300.00 or v_c1.provider_fee_impact::numeric <> 0 then
    raise exception 'FAIL 8.1: event1 (visa, 300.00) candidate expected gross=-300.00 fee=0, got gross=% fee=%', v_c1.gross_collection_impact, v_c1.provider_fee_impact;
  end if;

  select * into v_c2 from public.list_unsettled_settlement_sources(current_setting('p7t.route_cash_null')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'return_refund_event' and source_event_id = v_event2.id;
  if v_c2.gross_collection_impact::numeric <> -200.00 or v_c2.provider_fee_impact::numeric <> 0 then
    raise exception 'FAIL 8.1: event2 (cash, 200.00, method DIFFERS from the sale''s own visa) candidate expected gross=-200.00 fee=0, got gross=% fee=%', v_c2.gross_collection_impact, v_c2.provider_fee_impact;
  end if;

  raise notice 'PASS: 8.1a split actual refunds (target 800.00 != actual-so-far 500.00) — TWO independent return_refund_event candidates (visa 300.00 + cash 200.00), each routed on its OWN refund method (§1/§3-E), target != sum(actual events)';

  -- Reverse event2 ONLY. event1 must stay untouched; a NEW return_refund_
  -- event_reversal candidate (+200.00) appears on the SAME cash-method
  -- route (§1/§3-C/§3-E: route match uses the ORIGINAL event's method).
  select * into v_reversal from public.reverse_sales_return_refund_event(
    v_event2.id, 'تصحيح — س8 عكس الدفعة الثانية فقط', public.business_today()
  );
  perform set_config('p7t.s8_event2_reversal', v_reversal.id::text, false);

  select * into v_c1_after from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'return_refund_event' and source_event_id = v_event1.id;
  if v_c1_after.gross_collection_impact::numeric <> -300.00 then
    raise exception 'FAIL 8.1: event1 must be UNTOUCHED by event2''s reversal, still gross=-300.00, got %', v_c1_after.gross_collection_impact;
  end if;

  select * into v_c2rev from public.list_unsettled_settlement_sources(current_setting('p7t.route_cash_null')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'return_refund_event_reversal' and source_event_id = v_reversal.id;
  if v_c2rev.gross_collection_impact::numeric <> 200.00 or v_c2rev.provider_fee_impact::numeric <> 0 then
    raise exception 'FAIL 8.1: event2''s reversal candidate expected gross=+200.00 fee=0 (restoring ONLY event2''s own amount), got gross=% fee=%', v_c2rev.gross_collection_impact, v_c2rev.provider_fee_impact;
  end if;

  raise notice 'PASS: 8.1b actual refund event reversal — ONLY event2''s reversal shows +200.00; event1 (unreversed) stays untouched at -300.00 (§1/§3-C)';

  -- Administrative reverse_sales_return() — must NOT fabricate any NEW
  -- return_refund_event/_reversal row (event1/event2-reversal candidates
  -- stay EXACTLY as they are); it produces ONLY a return_fee_reversal_
  -- reversal (payment_fee_reversal_amount is nonzero here).
  perform public.reverse_sales_return(
    current_setting('p7t.s8_return')::uuid,
    (public.get_sales_return(current_setting('p7t.s8_return')::uuid) ->> 'row_version')::bigint,
    'تراجع إداري — س8 (لا يفبرك مصدر نقدي)',
    public.business_today()
  );

  select * into v_c1_after from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'return_refund_event' and source_event_id = v_event1.id;
  if v_c1_after.gross_collection_impact::numeric <> -300.00 then
    raise exception 'FAIL 8.1: the administrative reverse_sales_return() must NOT change event1''s own cash candidate';
  end if;
  select * into v_c2rev from public.list_unsettled_settlement_sources(current_setting('p7t.route_cash_null')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'return_refund_event_reversal' and source_event_id = v_reversal.id;
  if v_c2rev.gross_collection_impact::numeric <> 200.00 then
    raise exception 'FAIL 8.1: the administrative reverse_sales_return() must NOT change event2''s reversal candidate either';
  end if;

  -- Hotfix 7.1.1 §1 (CRITICAL) — return_fee_reversal is now a HISTORICAL
  -- EVENT, not a current-state view: it must keep firing on approved_at IS
  -- NOT NULL regardless of the return's CURRENT status, so it must still be
  -- here even after the administrative reversal (sr.status is no longer
  -- 'approved'). The OLD (Patch 7.1) behavior — where this candidate
  -- disappeared the moment status flipped away from 'approved' — was
  -- exactly the bug this hotfix fixes; asserting disappearance here would
  -- now be asserting the bug. Also §1/§3: this candidate's route is the
  -- ORIGINAL SALE's channel (s8_order -> channel_direct), i.e.
  -- route_visa_chan, not route_visa.
  select * into v_feerev from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'return_fee_reversal' and source_event_id = current_setting('p7t.s8_return')::uuid;
  if v_feerev.gross_collection_impact::numeric <> 0 or v_feerev.provider_fee_impact::numeric <> -v_fee_before then
    raise exception 'FAIL 8.1c: return_fee_reversal must STILL be offered (a permanent historical fact, §1) after the administrative reversal, with gross=0 fee=-%, got gross=% fee=%', v_fee_before, v_feerev.gross_collection_impact, v_feerev.provider_fee_impact;
  end if;

  -- ...and return_fee_reversal_reversal (§2) now ALSO appears, independently
  -- dated at reversal_business_date, on the SAME channel route — both
  -- coexist (net impact = 0) because neither has been claimed by a batch
  -- yet, exactly as §1 specifies.
  select * into v_c2rev from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'return_fee_reversal_reversal' and source_event_id = current_setting('p7t.s8_return')::uuid;
  if v_c2rev.gross_collection_impact::numeric <> 0 or v_c2rev.provider_fee_impact::numeric <> v_fee_before then
    raise exception 'FAIL 8.1c: return_fee_reversal_reversal must appear with gross=0 fee=+payment_fee_reversal_amount(%) after the admin reversal, got gross=% fee=%', v_fee_before, v_c2rev.gross_collection_impact, v_c2rev.provider_fee_impact;
  end if;
  if (v_feerev.provider_fee_impact::numeric + v_c2rev.provider_fee_impact::numeric) <> 0 then
    raise exception 'FAIL 8.1c: return_fee_reversal + return_fee_reversal_reversal must NET TO ZERO while both remain unclaimed (§1''s coexistence requirement), got %', v_feerev.provider_fee_impact::numeric + v_c2rev.provider_fee_impact::numeric;
  end if;

  raise notice 'PASS: 8.1c administrative reverse_sales_return() fabricates NO cash source — the refund-ledger candidates are byte-for-byte unchanged; return_fee_reversal(§1, now a permanent historical fact) and return_fee_reversal_reversal(§2) BOTH coexist on the original sale''s channel route, netting to zero while unclaimed (Hotfix 7.1.1 §1, CRITICAL)';
end $$;

-- Full refund (target == subtotal, ONE event, no split) — the simple
-- contrasting case to 8.1's partial/split scenario.
do $$
declare v_row record; v_order record; v_event record; v_c record; begin
  select * into v_row from public.create_sales_order(
    current_setting('p7t.store_a')::uuid, public.business_today(),
    current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 0.5000, 'sale_price', 100.00))
  );
  select (public.get_sales_order(v_row.id) ->> 'row_version')::bigint as row_version,
         (public.get_sales_order(v_row.id) -> 'items' -> 0 ->> 'id')::uuid as item_id
  into v_order;

  select * into v_row from public.create_sales_return(
    v_row.id, current_setting('p7t.store_a')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_order.item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار تسويات 7 - استرداد كامل')),
    v_order.row_version, 'collected', 100.00
  );
  perform public.approve_sales_return(v_row.id, (public.get_sales_return(v_row.id) ->> 'row_version')::bigint);

  select * into v_event from public.record_sales_return_refund(v_row.id, 100.00, current_setting('p7t.pm_visa')::uuid, public.business_today(), 'استرداد كامل فوري');

  select * into v_c from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'return_refund_event' and source_event_id = v_event.id;
  if v_c.gross_collection_impact::numeric <> -100.00 then
    raise exception 'FAIL: full-refund return_refund_event candidate expected gross=-100.00, got %', v_c.gross_collection_impact;
  end if;
  raise notice 'PASS: 8.1d a FULL refund (target == subtotal, one event, no split) sources correctly as a single return_refund_event candidate';
end $$;

-- ---------------------------------------------------------------------------
-- 8.2 Adjustment discovery — a participates_in_settlement=false Adjustment
-- must NEVER appear as a candidate (under ANY actor, including full-
-- permission), and cross-store Adjustment discovery requires BOTH stores
-- visible (§5's AND-rule — the discovery-time half; §6's whole-batch privacy
-- for an already-FINALIZED batch was covered in section 6 using adj1/
-- adjrev1, already claimed by then and unusable for a discovery-time proof).
-- ---------------------------------------------------------------------------
do $$
declare v_type_id uuid; v_row record; v_adjrow record; begin
  select public.create_adjustment_type('p7_service_np', 'خدمة تسوية 7 - غير مشمولة') into v_type_id;

  select * into v_row from public.create_sales_order_adjustment(
    current_setting('p7t.order1')::uuid, v_type_id, current_setting('p7t.store_b')::uuid, public.business_today(),
    current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid,
    false, 200.00, 40.00, 'خدمة تسوية 7 لا تشارك في التسوية', null, 'REF-P7-ADJ-NP'
  );
  perform set_config('p7t.s8_adj_np', v_row.id::text, false);

  select * into v_adjrow from public.get_sales_order_adjustment(v_row.id);
  perform public.approve_sales_order_adjustment(v_row.id, v_adjrow.row_version, null);

  if exists (
    select 1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'adjustment_approved' and source_event_id = current_setting('p7t.s8_adj_np')::uuid
  ) then
    raise exception 'FAIL 8.2: a participates_in_settlement=false Adjustment appeared as a settlement candidate — it must NEVER be a candidate regardless of approval status';
  end if;
  raise notice 'PASS: 8.2a a participates_in_settlement=false Adjustment NEVER appears as a candidate, even under a full-permission actor';
end $$;

-- Cross-store AND-rule (§5), discovery-time — a FRESH, unclaimed
-- cross-store Adjustment (processing=Store B, original sale=Store A).
do $$
declare v_order record; v_row record; v_type_id uuid; v_adjrow record; begin
  select * into v_row from public.create_sales_order(
    current_setting('p7t.store_a')::uuid, public.business_today(),
    current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 1.0000, 'sale_price', 400.00))
  );
  perform set_config('p7t.s8_order2', v_row.id::text, false);

  select public.create_adjustment_type('p7_service_s8b', 'خدمة تسوية 7 - س8ب') into v_type_id;
  select * into v_row from public.create_sales_order_adjustment(
    current_setting('p7t.s8_order2')::uuid, v_type_id, current_setting('p7t.store_b')::uuid, public.business_today(),
    current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid,
    true, 80.00, 16.00, 'خدمة تسوية 7 عبر المتاجر — س8ب', null, 'REF-P7-ADJ-S8B'
  );
  perform set_config('p7t.s8_adj_cross', v_row.id::text, false);
  select * into v_adjrow from public.get_sales_order_adjustment(v_row.id);
  perform public.approve_sales_order_adjustment(v_row.id, v_adjrow.row_version, null);
end $$;

-- actor 12 (Store A only — cannot see Store B): must NOT discover it.
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000012","role":"authenticated"}';
do $$ begin
  if exists (
    select 1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'adjustment_approved' and source_event_id = current_setting('p7t.s8_adj_cross')::uuid
  ) then
    raise exception 'FAIL 8.2b: a Store-A-only actor (cannot see Store B, the processing store) discovered a cross-store Adjustment candidate — §5 requires BOTH stores visible';
  end if;
end $$;

-- actor 13 (Store C only — cannot see Store A OR Store B): must NOT discover it.
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000013","role":"authenticated"}';
do $$ begin
  if exists (
    select 1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'adjustment_approved' and source_event_id = current_setting('p7t.s8_adj_cross')::uuid
  ) then
    raise exception 'FAIL 8.2c: a Store-C-only actor (sees neither side) discovered a cross-store Adjustment candidate';
  end if;
end $$;

-- actor 20 (Store A AND Store B via 'multiple' scope) — the POSITIVE case:
-- BOTH stores visible -> the candidate IS discoverable.
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000020","role":"authenticated"}';
do $$ declare v_c record; begin
  select * into v_c from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'adjustment_approved' and source_event_id = current_setting('p7t.s8_adj_cross')::uuid;
  if v_c.source_event_id is null then
    raise exception 'FAIL 8.2d: an actor who can see BOTH Store A and Store B failed to discover the cross-store Adjustment candidate — §5''s AND-rule reduces to a normal pass when both sides ARE visible';
  end if;
  if v_c.gross_collection_impact::numeric <> 80.00 or v_c.provider_fee_impact::numeric <> 6.40 then
    raise exception 'FAIL 8.2d: cross-store Adjustment candidate values incorrect, got gross=% fee=%', v_c.gross_collection_impact, v_c.provider_fee_impact;
  end if;
  raise notice 'PASS: 8.2b/c/d §5 cross-store AND-rule, discovery-time — invisible to Store-A-only AND Store-C-only actors (either side alone is not enough), visible to an actor who can see BOTH stores';
end $$;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- seed.sql's payment_method_fee_versions/vat_rate_versions both open at
-- business_today() (whatever day this DB was seeded) with no historical
-- coverage before it. The COD fixture below needs a Sale dated well in the
-- past so its 8-day COD event sequence has room to fit between the Sale and
-- business_today() without ever going into the future. No RPC widens an
-- already-open version's own effective_from backwards, and effective_from
-- is DB-immutable via trigger once a row exists — so, as postgres (bypasses
-- RLS), replace tabby's single seeded fee version with an equivalent one
-- that opens 60 days back (same percentage/fixed — this cannot change any
-- ALREADY-computed sale's frozen payment_fee_amount snapshot, only which
-- dates a FUTURE lookup can resolve).
reset role;
reset request.jwt.claims;
alter table public.payment_method_fee_versions disable trigger payment_method_fee_versions_enforce_immutable;
do $$
declare v_pm_tabby uuid; begin
  select id into v_pm_tabby from public.payment_methods where key = 'tabby';
  -- Widen IN PLACE (not delete+insert — existing sales_orders rows already
  -- carry a payment_fee_version_id FK to this exact row).
  update public.payment_method_fee_versions
  set effective_from = public.business_today() - 60
  where payment_method_id = v_pm_tabby and status = 'active' and effective_to is null;

  update public.vat_rate_versions set effective_from = public.business_today() - 60
  where status = 'active' and effective_to is null;
end $$;
alter table public.payment_method_fee_versions enable trigger payment_method_fee_versions_enforce_immutable;
set role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 8.3 COD adapter (§20/§21/§22) — noise states (expected/unknown) produce NO
-- source, a repeated 'collected' state does NOT double-count, and a
-- re-collection cycle pairs each reversal with its OWN immediately-prior
-- collection (proven via fee_lookup_date's downstream effect at FINALIZE,
-- using TWO fee versions dated so a wrong "last collected ever" pairing
-- would resolve a visibly DIFFERENT — and wrong — fee).
--
-- Timeline (shipment dated D=business_today()-10, cod_expected_amount=
-- 1000.00): D+1 not_collected (noise) -> D+2 unknown (noise) -> D+3
-- collected (collection #1, genuine transition in) -> D+4 collected (repeat
-- — must NOT double-count) -> D+5 not_collected (reversal #1 — its
-- IMMEDIATELY preceding event is D+4, so it pairs with D+4, not the older
-- D+3) -> D+6 expected (noise) -> D+7 collected (collection #2,
-- re-collection) -> D+8 not_collected (reversal #2, pairs with #2 @ D+7,
-- never any earlier cycle's date).
-- ---------------------------------------------------------------------------
do $$
declare
  v_row record; v_rv bigint; v_shipdate date := public.business_today() - 10;
  v_c1 record; v_c2 record; v_r1 record; v_r2 record;
  v_collection_count integer; v_reversal_count integer;
  v_batch record; v_lines jsonb; v_line jsonb;
  v_r1_fee numeric; v_c1_fee numeric; v_c2_fee numeric; v_r2_fee numeric;
  v_order_cod uuid;
begin
  -- A DEDICATED sale, dated well in the past — the shipment below (and its
  -- 8-day COD event sequence) must be dated on/after the sale's own date,
  -- and every event must stay <= business_today(), so this cannot reuse
  -- s8_order2 (dated business_today()). gold_price_version_for_karat_on_
  -- date() requires an EXACT price_date match (no <= range), so a dedicated
  -- price row is needed for this backdated date too — dated exactly at
  -- v_shipdate (business_today()-10), the earliest date manufacturing_fee_
  -- version_for_karat_on_date() covers (section 0's fixture opened it at
  -- business_today()-10).
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (v_shipdate, current_setting('p7t.karat')::uuid, 300.0000, 'a7000000-0000-4000-8000-000000000001');

  select id into v_order_cod from public.create_sales_order(
    current_setting('p7t.store_a')::uuid, v_shipdate,
    current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 1.0000, 'sale_price', 10.00))
  );

  select * into v_row from public.create_shipment(
    v_order_cod, current_setting('p7t.store_a')::uuid, v_shipdate, 'outbound',
    current_setting('p7t.carrier')::uuid, (select id from public.shipping_zones where status = 'active' limit 1), 25.00,
    null, 'delivery', null, null, null, null, null,
    true, 1000.00, 60.00, 'اختبار تسويات 7 — لا يوجد تسعير معتمد لهذا الناقل، تكلفة يدوية'
  );
  perform set_config('p7t.s8_shipment', v_row.id::text, false);

  select (public.get_shipment(v_row.id) ->> 'row_version')::bigint into v_rv;
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_row.id, v_rv, 'not_collected', v_shipdate + 1); -- noise
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_row.id, v_rv, 'unknown', v_shipdate + 2);       -- noise
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_row.id, v_rv, 'collected', v_shipdate + 3);     -- collection #1
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_row.id, v_rv, 'collected', v_shipdate + 4);     -- repeat, no double count
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_row.id, v_rv, 'not_collected', v_shipdate + 5); -- reversal #1 (pairs with #1)
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_row.id, v_rv, 'expected', v_shipdate + 6);      -- noise
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_row.id, v_rv, 'collected', v_shipdate + 7);     -- collection #2 (re-collection)
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_row.id, v_rv, 'not_collected', v_shipdate + 8); -- reversal #2 (must pair with #2, NOT #1)

  select count(*) into v_collection_count from public.list_unsettled_settlement_sources(current_setting('p7t.route_cod')::uuid, v_shipdate - 1, v_shipdate + 10)
    where source_kind = 'cod_collection';
  select count(*) into v_reversal_count from public.list_unsettled_settlement_sources(current_setting('p7t.route_cod')::uuid, v_shipdate - 1, v_shipdate + 10)
    where source_kind = 'cod_reversal';
  if v_collection_count <> 2 then
    raise exception 'FAIL 8.3a: expected exactly 2 cod_collection candidates (the repeat @ D+4 and every noise state must produce NONE), got %', v_collection_count;
  end if;
  if v_reversal_count <> 2 then
    raise exception 'FAIL 8.3a: expected exactly 2 cod_reversal candidates (every noise state must produce NONE), got %', v_reversal_count;
  end if;

  select * into v_c1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_cod')::uuid, v_shipdate - 1, v_shipdate + 10)
    where source_kind = 'cod_collection' and source_business_date = v_shipdate + 3;
  select * into v_c2 from public.list_unsettled_settlement_sources(current_setting('p7t.route_cod')::uuid, v_shipdate - 1, v_shipdate + 10)
    where source_kind = 'cod_collection' and source_business_date = v_shipdate + 7;
  select * into v_r1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_cod')::uuid, v_shipdate - 1, v_shipdate + 10)
    where source_kind = 'cod_reversal' and source_business_date = v_shipdate + 5;
  select * into v_r2 from public.list_unsettled_settlement_sources(current_setting('p7t.route_cod')::uuid, v_shipdate - 1, v_shipdate + 10)
    where source_kind = 'cod_reversal' and source_business_date = v_shipdate + 8;
  if v_c1.source_event_id is null or v_c2.source_event_id is null or v_r1.source_event_id is null or v_r2.source_event_id is null then
    raise exception 'FAIL 8.3a: one of the 4 expected COD candidates (collection@D+3/D+7, reversal@D+5/D+8) is missing';
  end if;
  perform set_config('p7t.s8_cod_c1', v_c1.source_event_id::text, false);
  perform set_config('p7t.s8_cod_c2', v_c2.source_event_id::text, false);
  perform set_config('p7t.s8_cod_r1', v_r1.source_event_id::text, false);
  perform set_config('p7t.s8_cod_r2', v_r2.source_event_id::text, false);

  raise notice 'PASS: 8.3a COD state transitions — exactly 2 cod_collection + 2 cod_reversal candidates (repeat @ D+4 and every noise state (not_collected/unknown/expected) correctly produce NO source)';

  -- §21/§22-C — re-collection pairing, proven via FINALIZE's fee resolution.
  -- fee_lookup_date for a cod_reversal is the date of the row IMMEDIATELY
  -- PRECEDING it in the shipment's own event timeline (which, by the
  -- reversal predicate itself, is guaranteed to have state='collected') —
  -- for reversal #1 @ D+5, that is D+4 (the REPEATED collected row, not the
  -- original transition @ D+3 — lag() walks the raw timeline, not just
  -- "genuine transition" candidates); for reversal #2 @ D+8, that is D+7
  -- (collection #2, its own re-collection). FV2 (10%) opens at D+5 — AFTER
  -- D+4 but BEFORE D+7 — so a CORRECT implementation resolves reversal #1
  -- via FV1 (4%, fee=-40.00, from D+4) and reversal #2 via FV2 (10%,
  -- fee=-100.00, from D+7): two reversals of the identical shape resolving
  -- to two DIFFERENT fee versions, proving fee_lookup_date is derived
  -- per-event from its own correct adjacent pairing, never a shared/stale
  -- value or a "last collected ever" lookup that could cross-pair a later
  -- collection back to an earlier cycle's reversal.
  perform public.create_settlement_route_fee_version(current_setting('p7t.route_cod')::uuid, v_shipdate + 5, 'route_formula', 'percentage', 10.0, 0, 3.00, 'full', 'p7 s8 cod fee v2 (10%)');

  select * into v_batch from public.create_draft_settlement_batch(current_setting('p7t.route_cod')::uuid, public.business_today());
  perform public.finalize_settlement_batch(
    v_batch.id, 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'cod_collection', 'source_event_id', current_setting('p7t.s8_cod_c1')),
      jsonb_build_object('source_kind', 'cod_collection', 'source_event_id', current_setting('p7t.s8_cod_c2')),
      jsonb_build_object('source_kind', 'cod_reversal', 'source_event_id', current_setting('p7t.s8_cod_r1')),
      jsonb_build_object('source_kind', 'cod_reversal', 'source_event_id', current_setting('p7t.s8_cod_r2'))
    )
  );
  perform set_config('p7t.s8_cod_batch', v_batch.id::text, false);

  select v_batch2.lines into v_lines from public.get_settlement_batch(v_batch.id) v_batch2;
  for v_line in select * from jsonb_array_elements(v_lines) loop
    if v_line ->> 'source_kind' = 'cod_collection' and v_line ->> 'source_business_date' = (v_shipdate + 3)::text then
      v_c1_fee := (v_line ->> 'provider_fee_impact')::numeric;
    elsif v_line ->> 'source_kind' = 'cod_collection' and v_line ->> 'source_business_date' = (v_shipdate + 7)::text then
      v_c2_fee := (v_line ->> 'provider_fee_impact')::numeric;
    elsif v_line ->> 'source_kind' = 'cod_reversal' and v_line ->> 'source_business_date' = (v_shipdate + 5)::text then
      v_r1_fee := (v_line ->> 'provider_fee_impact')::numeric;
    elsif v_line ->> 'source_kind' = 'cod_reversal' and v_line ->> 'source_business_date' = (v_shipdate + 8)::text then
      v_r2_fee := (v_line ->> 'provider_fee_impact')::numeric;
    end if;
  end loop;

  if v_c1_fee <> 40.00 then raise exception 'FAIL 8.3b: collection#1 (D+3, FV1 4%%) fee expected 40.00, got %', v_c1_fee; end if;
  if v_c2_fee <> 100.00 then raise exception 'FAIL 8.3b: collection#2 (D+7, FV2 10%%) fee expected 100.00, got %', v_c2_fee; end if;
  if v_r1_fee <> -40.00 then
    raise exception 'FAIL 8.3b: reversal#1''s fee expected -40.00 (FV1 4%%, from its immediately-preceding collected row @ D+4) — got %', v_r1_fee;
  end if;
  if v_r2_fee <> -100.00 then raise exception 'FAIL 8.3b: reversal#2''s fee expected -100.00 (FV2 10%%, correctly paired with collection#2 @ D+7), got %', v_r2_fee; end if;

  raise notice 'PASS: 8.3b §21/§22-C re-collection fee_lookup_date pairing — reversal#1 resolves via D+4 (its immediately-preceding collected row, itself the REPEAT — FV1 4%%=-40.00) while reversal#2 resolves via D+7 (its OWN re-collection — FV2 10%%=-100.00): two reversals of the identical shape correctly resolving to two DIFFERENT fee versions, never a stale/shared/wrong-cycle date';
end $$;

-- ---------------------------------------------------------------------------
-- 8.4 Route NULL-channel EXACT semantics (§4) — a route with collection_
-- channel_id IS NULL must NOT match a Sale/Adjustment (which always carry a
-- real, NOT NULL, channel) — only Return-derived sources (which have no
-- channel column of their own, an implicit NULL) can ever match a
-- NULL-channel route. This is the flip side of what section 2's fixture
-- already relies on structurally; asserted explicitly here.
-- ---------------------------------------------------------------------------
do $$ begin
  if exists (
    select 1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'sale' and source_event_id = current_setting('p7t.order1')::uuid
  ) then
    raise exception 'FAIL 8.4: route_visa (NULL channel) must NEVER match a Sale (real, NOT NULL channel) — §4 exact IS NOT DISTINCT FROM matching';
  end if;
  if exists (
    select 1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'adjustment_approved' and source_event_id = current_setting('p7t.adj1')::uuid
  ) then
    raise exception 'FAIL 8.4: route_visa (NULL channel) must NEVER match an Adjustment (real, NOT NULL channel) — §4';
  end if;
  -- ...but DOES match the Return-derived source on the exact same route
  -- (route_visa) — proven already many times above; re-asserted here for
  -- direct side-by-side contrast in one place.
  if not exists (
    select 1 from public.list_unsettled_settlement_sources(current_setting('p7t.route_visa')::uuid, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'return_refund_event' and source_event_id = current_setting('p7t.s8_event1')::uuid
  ) then
    raise exception 'FAIL 8.4: route_visa (NULL channel) should match a Return-derived source (implicit NULL channel)';
  end if;
  raise notice 'PASS: 8.4 §4 NULL-channel exact semantics — route_visa matches ONLY the channel-less Return source, never Sale/Adjustment (both carry a real channel)';
end $$;

-- ---------------------------------------------------------------------------
-- 8.5 route_formula fee precision + Preview/Finalize parity (§14/§17) — a
-- percentage_fee/fixed_fee combination DELIBERATELY chosen so early-rounding
-- (round the percentage component ALONE, then add the fixed component) and
-- single-final-rounding (accumulate both at full precision, round ONCE at
-- the end) produce DIFFERENT results on the same gross: pct=0.618%%,
-- fixed=0.9532 (4dp, only reachable post-§18), gross=10.00 ->
-- old (double-round) = round(round(10*0.618/100,2)+0.9532,2) = 1.01
-- new (single-round) = round(10*0.618/100+0.9532,2)             = 1.02
-- preview_settlement_batch() and finalize_settlement_batch() must produce
-- the IDENTICAL 1.02 (never 0 from preview, per the old bug 0185's own
-- header names, and never differing between the two).
-- ---------------------------------------------------------------------------
do $$
declare
  v_carrier2 uuid; v_route_cod2 uuid; v_shipment record; v_rv bigint;
  v_event_id uuid; v_preview record; v_line jsonb; v_batch record; v_lines jsonb;
  v_finalize_fee numeric; v_preview_fee numeric;
begin
  insert into public.shipping_carriers (code, name_ar, carrier_type, status)
    values ('P7CARRIER2', 'ناقل تسويات 7 - ب', 'external', 'active')
    returning id into v_carrier2;

  select public.create_settlement_route('p7-cod-route-2', 'مسار COD 7 - ب', 'cod_carrier', null, null, null, v_carrier2) into v_route_cod2;
  perform public.create_settlement_route_fee_version(v_route_cod2, public.business_today() - 30, 'route_formula', 'percentage_plus_fixed', 0.618, 0.9532, 0, 'none', 'p7 s8 — rounding-divergence fixture');

  select * into v_shipment from public.create_shipment(
    current_setting('p7t.s8_order2')::uuid, current_setting('p7t.store_a')::uuid, public.business_today(), 'outbound',
    v_carrier2, (select id from public.shipping_zones where status = 'active' limit 1), 25.00,
    null, 'delivery', null, null, null, null, null,
    true, 10.00, 5.00, 'اختبار تسويات 7 — دقة الحساب'
  );
  select (public.get_shipment(v_shipment.id) ->> 'row_version')::bigint into v_rv;
  select row_version into v_rv from public.record_shipment_cod_collection_state(v_shipment.id, v_rv, 'collected', public.business_today());

  select source_event_id into v_event_id from public.list_unsettled_settlement_sources(v_route_cod2, public.business_today() - 1, public.business_today() + 1)
    where source_kind = 'cod_collection';

  select * into v_preview from public.preview_settlement_batch(
    v_route_cod2, public.business_today() - 1, public.business_today() + 1,
    jsonb_build_array(jsonb_build_object('source_kind', 'cod_collection', 'source_event_id', v_event_id)),
    public.business_today()
  );
  v_line := v_preview.lines -> 0;
  v_preview_fee := (v_line ->> 'provider_fee_impact')::numeric;
  if v_preview_fee <> 1.02 then
    raise exception 'FAIL 8.5: preview route_formula fee expected 1.02 (single-final-round, §17), got % (1.01 would mean the OLD double-rounding bug; 0.00 would mean preview never computed a route_formula fee at all, §14''s own named bug)', v_preview_fee;
  end if;

  select * into v_batch from public.create_draft_settlement_batch(v_route_cod2, public.business_today());
  perform public.finalize_settlement_batch(v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'cod_collection', 'source_event_id', v_event_id)));
  select g.lines into v_lines from public.get_settlement_batch(v_batch.id) g;
  v_finalize_fee := ((v_lines -> 0) ->> 'provider_fee_impact')::numeric;
  if v_finalize_fee <> 1.02 then
    raise exception 'FAIL 8.5: finalize route_formula fee expected 1.02, got %', v_finalize_fee;
  end if;
  if v_finalize_fee <> v_preview_fee then
    raise exception 'FAIL 8.5: preview (%) and finalize (%) route_formula fees must be IDENTICAL (§14 parity)', v_preview_fee, v_finalize_fee;
  end if;

  raise notice 'PASS: 8.5 §14/§17 — preview_settlement_batch() and finalize_settlement_batch() both resolve the SAME route_formula fee (1.02, single-final-round — NOT 1.01, the old double-rounding result, and NOT 0.00, the old preview-never-computes-it bug)';
end $$;

-- ---------------------------------------------------------------------------
-- 8.6 settlement_date chronology (§10) — a future settlement_date is
-- rejected at create AND update; a source dated AFTER the batch's own
-- settlement_date is rejected at finalize.
-- ---------------------------------------------------------------------------
do $$
declare v_rejected boolean; v_b record; begin
  v_rejected := false;
  begin
    perform public.create_draft_settlement_batch(current_setting('p7t.route_visa_chan')::uuid, public.business_today() + 1);
  exception when others then
    if sqlerrm like '%تاريخ التسوية%لا يمكن أن يكون في المستقبل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.6a: create_draft_settlement_batch() with a FUTURE settlement_date was NOT rejected'; end if;

  select * into v_b from public.create_draft_settlement_batch(current_setting('p7t.route_visa_chan')::uuid, public.business_today());
  v_rejected := false;
  begin
    perform public.update_draft_settlement_batch(v_b.id, 1, p_settlement_date := public.business_today() + 1);
  exception when others then
    if sqlerrm like '%تاريخ التسوية%لا يمكن أن يكون في المستقبل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.6a: update_draft_settlement_batch() with a FUTURE settlement_date was NOT rejected'; end if;

  raise notice 'PASS: 8.6a §10 — a future settlement_date is rejected at BOTH create_draft_settlement_batch() and update_draft_settlement_batch()';
end $$;

do $$ declare v_b record; v_rejected boolean := false; v_order record; begin
  -- A FRESH sale (dated business_today(), pm_visa/channel_direct so it
  -- matches route_visa_chan) — s8_order2's own Sale can no longer be used
  -- for this proof: 8.5 attached an is_cod outbound shipment to it, which
  -- permanently excludes a sales_order from ever being a 'sale' settlement
  -- candidate again (§ Sale-candidate predicate, 0184) regardless of date.
  select * into v_order from public.create_sales_order(
    current_setting('p7t.store_a')::uuid, public.business_today(),
    current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 1.0000, 'sale_price', 300.00))
  );

  -- settlement_date = 5 days ago; the fresh sale is dated business_today()
  -- (today) — AFTER the batch's own settlement_date.
  select * into v_b from public.create_draft_settlement_batch(current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 5);
  begin
    perform public.finalize_settlement_batch(v_b.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null);
  exception when others then
    if sqlerrm like '%مصدر مؤرَّخًا بعدها%' or sqlerrm like '%بتاريخ لاحق لتاريخ التسوية%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.6b: finalize_settlement_batch() with a source dated AFTER the batch''s own settlement_date was NOT rejected'; end if;
  raise notice 'PASS: 8.6b §10 — finalize_settlement_batch() rejects a source dated after the batch''s own settlement_date';
end $$;

-- ---------------------------------------------------------------------------
-- 8.7/8.8/8.9 — one coherent fixture (batch_dc) proving, in order:
--  8.7  Daily Close on finalize is keyed on the batch's settlement_date, NOT
--       the source's own business_date (§11) — the source's date is left
--       OPEN throughout, only settlement_date is closed, yet finalize is
--       still rejected without override.
--  8.7  record_settlement_bank_movement()/reverse_settlement_bank_movement()
--       each key Daily Close on THEIR OWN date (movement_business_date /
--       reversal_business_date), independent of settlement_date (§12).
--  8.8  once reconciled, a NEW bank movement is rejected outright (§13,
--       independent of any closed-day permission — the actor here holds
--       EVERY permission including process_closed_day and is still
--       rejected), while reverse_settlement_bank_movement() on the
--       already-recorded movement still succeeds.
--  8.9  cancel_settlement_batch() on the now-reconciled-then-fully-reversed
--       batch, with a REAL nonzero original_variance (expected minus a net
--       actual of 0.00 after reversal) — get_settlement_batch() and
--       list_settlement_batches() must both keep original_*/historical_*
--       permanently at their pre-cancel values while effective_* collapses
--       to 0.00/'cancelled' (§26).
-- ---------------------------------------------------------------------------
do $$
declare v_order record; v_b record; begin
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today() - 4, current_setting('p7t.karat')::uuid, 300.0000, 'a7000000-0000-4000-8000-000000000001');

  -- D0 = business_today()-4 — the Sale's own date. Deliberately left OPEN
  -- for the rest of this fixture, to prove finalize never looks at it.
  select * into v_order from public.create_sales_order(
    current_setting('p7t.store_a')::uuid, public.business_today() - 4,
    current_setting('p7t.pm_visa')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 1.0000, 'sale_price', 900.00))
  );
  perform set_config('p7t.order_dc', v_order.id::text, false);

  -- D1 = business_today()-3 — the BATCH's settlement_date. Closed BEFORE
  -- finalize, while D0 stays open.
  select * into v_b from public.create_draft_settlement_batch(current_setting('p7t.route_visa_chan')::uuid, public.business_today() - 3);
  perform set_config('p7t.batch_dc', v_b.id::text, false);
  perform public.close_sales_day(current_setting('p7t.store_a')::uuid, public.business_today() - 3, 'إغلاق اختباري تسويات 7 — 8.7 تاريخ تسوية الدفعة');
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$ declare v_rejected boolean := false; begin
  -- actor 005: settlements.create+finalize, NO process_closed_day. Rejected
  -- purely because settlement_date (D1) is closed — the source's own date
  -- (D0, business_today()-4) was never touched.
  begin
    perform public.finalize_settlement_batch(current_setting('p7t.batch_dc')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order_dc'))), null, null, null);
  exception when others then
    if sqlerrm like '%في يوم مقفل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.7a: finalize_settlement_batch() was NOT rejected for a closed settlement_date, even though the source''s own business_date was left open — proves the closed-day check is NOT still keyed on source_business_date'; end if;
  raise notice 'PASS: 8.7a §11 — finalize''s Daily Close check keys on the batch''s settlement_date, not the source''s own (still-open) business_date';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$ declare v_batch record; v_expected numeric; begin
  perform public.finalize_settlement_batch(current_setting('p7t.batch_dc')::uuid, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7t.order_dc'))), null, null, 'معالجة يوم مقفل — 8.7 تسوية');
  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch_dc')::uuid);
  if v_batch.status <> 'finalized' then raise exception 'FAIL 8.7b: closed-settlement_date finalize with a reason did not succeed'; end if;
  v_expected := v_batch.original_expected_bank_settlement::numeric;
  perform set_config('p7t.batch_dc_expected', v_expected::text, false);
  raise notice 'PASS: 8.7b finalize succeeds once process_closed_day + a reason are both supplied (expected_bank_settlement=%)', v_expected;
end $$;

do $$ declare v_move_id uuid; begin
  -- D2 = business_today()-2, OPEN when the movement is recorded — the
  -- movement is accepted with NO reason at all, even though settlement_date
  -- (D1) is closed: proves record_settlement_bank_movement() checks its OWN
  -- date, never settlement_date.
  select public.record_settlement_bank_movement(
    p_settlement_batch_id := current_setting('p7t.batch_dc')::uuid,
    p_movement_business_date := public.business_today() - 2,
    p_amount := current_setting('p7t.batch_dc_expected')::numeric,
    p_closed_day_reason := null
  ) into v_move_id;
  perform set_config('p7t.move_dc', v_move_id::text, false);
  raise notice 'PASS: 8.7c record_settlement_bank_movement() on an OPEN movement date succeeds without any closed-day reason, despite the batch''s own settlement_date being closed';
end $$;

do $$ begin
  perform public.reconcile_settlement_batch(current_setting('p7t.batch_dc')::uuid, 2);
end $$;
do $$ declare v_batch record; begin
  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch_dc')::uuid);
  if v_batch.status <> 'reconciled' or v_batch.historical_actual_bank_movement::numeric <> current_setting('p7t.batch_dc_expected')::numeric or v_batch.original_variance::numeric <> 0 then
    raise exception 'FAIL 8.8a: reconcile did not settle to zero variance as expected (status=%, actual=%, variance=%)', v_batch.status, v_batch.historical_actual_bank_movement, v_batch.original_variance;
  end if;
  raise notice 'PASS: 8.8a reconcile_settlement_batch() settles to zero variance (single movement == expected)';
end $$;

do $$ declare v_rejected boolean := false; begin
  -- actor 001 — EVERY permission including process_closed_day/a reason
  -- available — and still rejected: §13's reconciled-block is a status
  -- check, unconditional on closed-day permission.
  begin
    perform public.record_settlement_bank_movement(
      p_settlement_batch_id := current_setting('p7t.batch_dc')::uuid,
      p_movement_business_date := public.business_today(),
      p_amount := 1.00,
      p_closed_day_reason := 'محاولة اختبارية 8.8'
    );
  exception when others then
    if sqlerrm like '%مُطابَقة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.8b: a NEW bank movement was accepted on an already-reconciled batch'; end if;
  raise notice 'PASS: 8.8b §13 — a NEW bank movement is rejected outright once a batch is reconciled, regardless of any closed-day permission held';
end $$;

do $$ begin
  -- Close D2 (the movement's own date) AFTER it was recorded on it while
  -- open — now prove reverse_settlement_bank_movement() keys its OWN
  -- (reversal_business_date) date-check off D2, independent of D1.
  perform public.close_sales_day(current_setting('p7t.store_a')::uuid, public.business_today() - 2, 'إغلاق اختباري تسويات 7 — 8.7 تاريخ الحركة');
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000008","role":"authenticated"}';
do $$ declare v_rejected boolean := false; begin
  -- actor 008: settlements.record_bank_movement only, NO process_closed_day.
  begin
    perform public.reverse_settlement_bank_movement(current_setting('p7t.move_dc')::uuid, public.business_today() - 2, 'عكس اختباري 8.7', null);
  exception when others then
    if sqlerrm like '%في يوم مقفل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.7d: reverse_settlement_bank_movement() on a closed reversal date was NOT rejected for a no-process_closed_day actor'; end if;
  raise notice 'PASS: 8.7d §12 — reverse_settlement_bank_movement() rejects a closed reversal_business_date without process_closed_day, still allowed at all despite the batch being reconciled (§13)';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$ declare v_batch record; begin
  perform public.reverse_settlement_bank_movement(current_setting('p7t.move_dc')::uuid, public.business_today() - 2, 'عكس اختباري 8.7 — بسبب', 'معالجة يوم مقفل — 8.7 عكس');
  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch_dc')::uuid);
  if v_batch.historical_actual_bank_movement::numeric <> 0 then
    raise exception 'FAIL 8.7e: after fully reversing the only movement, historical_actual_bank_movement expected 0.00, got %', v_batch.historical_actual_bank_movement;
  end if;
  if v_batch.original_variance::numeric <> (0 - current_setting('p7t.batch_dc_expected')::numeric) then
    raise exception 'FAIL 8.7e: original_variance expected -% (0 actual - expected), got %', current_setting('p7t.batch_dc_expected'), v_batch.original_variance;
  end if;
  raise notice 'PASS: 8.7e reverse_settlement_bank_movement() still succeeds on a reconciled batch once process_closed_day + a reason are supplied; historical_actual_bank_movement/original_variance now reflect the full reversal (real, nonzero variance = -%)', current_setting('p7t.batch_dc_expected');
end $$;

-- 8.9 — cancel the now-fully-reversed, reconciled batch (a real, nonzero
-- original_variance is on record from 8.7e) and prove original-vs-effective.
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000011","role":"authenticated"}';
do $$ declare v_rejected boolean := false; v_rv bigint; begin
  -- actor 011: settlements.cancel only, NO process_closed_day. cancellation_
  -- business_date (D2, closed) is rejected without it.
  select row_version into v_rv from public.get_settlement_batch(current_setting('p7t.batch_dc')::uuid);
  begin
    perform public.cancel_settlement_batch(current_setting('p7t.batch_dc')::uuid, v_rv, public.business_today() - 2, 'إلغاء اختباري 8.9', null);
  exception when others then
    if sqlerrm like '%في يوم مقفل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.9a: cancel_settlement_batch() on a closed cancellation_business_date was NOT rejected for a no-process_closed_day actor'; end if;
  raise notice 'PASS: 8.9a §12 — cancel_settlement_batch() rejects a closed cancellation_business_date without process_closed_day';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_expected numeric; v_batch record; v_list record; v_rv bigint;
begin
  v_expected := current_setting('p7t.batch_dc_expected')::numeric;
  select row_version into v_rv from public.get_settlement_batch(current_setting('p7t.batch_dc')::uuid);
  perform public.cancel_settlement_batch(current_setting('p7t.batch_dc')::uuid, v_rv, public.business_today() - 2, 'إلغاء اختباري 8.9 — بسبب', 'معالجة يوم مقفل — 8.9 إلغاء');

  select * into v_batch from public.get_settlement_batch(current_setting('p7t.batch_dc')::uuid);
  if v_batch.status <> 'reconciled' then
    raise exception 'FAIL 8.9b: raw status column expected to stay ''reconciled'' (cancellation is recorded in a side table, not a status overwrite) — got %', v_batch.status;
  end if;
  if v_batch.effective_status <> 'cancelled' then
    raise exception 'FAIL 8.9b: effective_status expected ''cancelled'', got %', v_batch.effective_status;
  end if;
  if v_batch.original_expected_bank_settlement::numeric <> v_expected
     or v_batch.historical_actual_bank_movement::numeric <> 0
     or v_batch.original_variance::numeric <> (0 - v_expected) then
    raise exception 'FAIL 8.9b: original_*/historical_* must stay PERMANENTLY at their pre-cancel values (expected=%, actual=0, variance=-%) — got expected=%, actual=%, variance=%',
      v_expected, v_expected, v_batch.original_expected_bank_settlement, v_batch.historical_actual_bank_movement, v_batch.original_variance;
  end if;
  if v_batch.effective_expected_settlement_contribution::numeric <> 0
     or v_batch.effective_actual_settlement_contribution::numeric <> 0
     or v_batch.effective_variance_contribution::numeric <> 0 then
    raise exception 'FAIL 8.9b: effective_* must ALL collapse to 0.00 once cancelled — got expected=%, actual=%, variance=%',
      v_batch.effective_expected_settlement_contribution, v_batch.effective_actual_settlement_contribution, v_batch.effective_variance_contribution;
  end if;

  select * into v_list from public.list_settlement_batches(p_settlement_route_id := current_setting('p7t.route_visa_chan')::uuid, p_effective_status := array['cancelled'])
    where id = current_setting('p7t.batch_dc')::uuid;
  if v_list.id is null then
    raise exception 'FAIL 8.9c: list_settlement_batches(p_effective_status := ARRAY[''cancelled'']) did not surface the cancelled batch_dc';
  end if;
  if v_list.original_expected_bank_settlement::numeric <> v_expected or v_list.effective_expected_settlement_contribution::numeric <> 0 or v_list.effective_variance_contribution::numeric <> 0 then
    raise exception 'FAIL 8.9c: list_settlement_batches() original-vs-effective mismatch for the cancelled batch — original=%, effective_expected=%, effective_variance=%',
      v_list.original_expected_bank_settlement, v_list.effective_expected_settlement_contribution, v_list.effective_variance_contribution;
  end if;

  raise notice 'PASS: 8.9b/c §26 — get_settlement_batch() AND list_settlement_batches() both keep original_*/historical_* permanently at their real pre-cancel values (expected=%, variance=-%) while effective_* collapses to 0.00/''cancelled''', v_expected, v_expected;
end $$;

-- ---------------------------------------------------------------------------
-- 8.11 list_settlement_batches() complete filter set (§25) — route_kind,
-- payment_method_id, collection_channel_id, shipping_carrier_id each
-- discriminate correctly across THREE drafts on three differently-shaped
-- routes; has_variance separates a real +1.00-variance finalized batch
-- (batch_var) from a draft (expected_bank_settlement is null -> eff_variance
-- 0), and is refused outright without settlements.view_financials rather
-- than silently ignored.
-- ---------------------------------------------------------------------------
do $$
declare v_d_visachan record; v_d_cash record; v_d_cod record; v_order_var record; v_batch_var record; v_expected numeric; begin
  select * into v_d_visachan from public.create_draft_settlement_batch(current_setting('p7t.route_visa_chan')::uuid, public.business_today());
  perform set_config('p7t.d_visachan', v_d_visachan.id::text, false);
  select * into v_d_cash from public.create_draft_settlement_batch(current_setting('p7t.route_cash')::uuid, public.business_today());
  perform set_config('p7t.d_cash', v_d_cash.id::text, false);
  select * into v_d_cod from public.create_draft_settlement_batch(current_setting('p7t.route_cod')::uuid, public.business_today());
  perform set_config('p7t.d_cod', v_d_cod.id::text, false);

  -- A fresh, non-cancelled, real-variance batch for the has_variance proof —
  -- batch3 (section 5b) is no longer usable: it was reversed AND cancelled
  -- right after its own proof, so its effective_variance is now 0 (§26).
  select * into v_order_var from public.create_sales_order(
    current_setting('p7t.store_a')::uuid, public.business_today(),
    current_setting('p7t.pm_cash')::uuid, current_setting('p7t.channel_direct')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p7t.category')::uuid, 'karat_id', current_setting('p7t.karat')::uuid, 'weight_grams', 1.0000, 'sale_price', 200.00))
  );
  select * into v_batch_var from public.create_draft_settlement_batch(current_setting('p7t.route_cash')::uuid, public.business_today());
  perform public.finalize_settlement_batch(v_batch_var.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order_var.id)), null, null, null);
  select original_expected_bank_settlement::numeric into v_expected from public.get_settlement_batch(v_batch_var.id);
  perform public.record_settlement_bank_movement(v_batch_var.id, public.business_today(), v_expected + 1.00, 'REF-P7-8.11-VAR', null);
  perform set_config('p7t.batch_var', v_batch_var.id::text, false);
end $$;

do $$
declare v_found boolean; begin
  -- route_kind := 'cod_carrier' -> ONLY the cod draft.
  select exists(select 1 from public.list_settlement_batches(p_route_kind := 'cod_carrier') where id = current_setting('p7t.d_cod')::uuid) into v_found;
  if not v_found then raise exception 'FAIL 8.11a: p_route_kind=''cod_carrier'' missed the cod draft'; end if;
  if exists(select 1 from public.list_settlement_batches(p_route_kind := 'cod_carrier') where id in (current_setting('p7t.d_visachan')::uuid, current_setting('p7t.d_cash')::uuid)) then
    raise exception 'FAIL 8.11a: p_route_kind=''cod_carrier'' incorrectly included a payment_collection draft';
  end if;

  -- payment_method_id := pm_cash -> ONLY the cash draft.
  select exists(select 1 from public.list_settlement_batches(p_payment_method_id := current_setting('p7t.pm_cash')::uuid) where id = current_setting('p7t.d_cash')::uuid) into v_found;
  if not v_found then raise exception 'FAIL 8.11b: p_payment_method_id=pm_cash missed the cash draft'; end if;
  if exists(select 1 from public.list_settlement_batches(p_payment_method_id := current_setting('p7t.pm_cash')::uuid) where id in (current_setting('p7t.d_visachan')::uuid, current_setting('p7t.d_cod')::uuid)) then
    raise exception 'FAIL 8.11b: p_payment_method_id=pm_cash incorrectly included a non-cash draft';
  end if;

  -- collection_channel_id := channel_direct -> BOTH visachan and cash
  -- drafts (both carry channel_direct), NEVER the cod draft (NULL channel).
  if not exists(select 1 from public.list_settlement_batches(p_collection_channel_id := current_setting('p7t.channel_direct')::uuid) where id = current_setting('p7t.d_visachan')::uuid)
     or not exists(select 1 from public.list_settlement_batches(p_collection_channel_id := current_setting('p7t.channel_direct')::uuid) where id = current_setting('p7t.d_cash')::uuid) then
    raise exception 'FAIL 8.11c: p_collection_channel_id=channel_direct missed a matching draft';
  end if;
  if exists(select 1 from public.list_settlement_batches(p_collection_channel_id := current_setting('p7t.channel_direct')::uuid) where id = current_setting('p7t.d_cod')::uuid) then
    raise exception 'FAIL 8.11c: p_collection_channel_id=channel_direct incorrectly included the NULL-channel cod draft';
  end if;

  -- shipping_carrier_id := carrier1 -> ONLY the cod draft.
  select exists(select 1 from public.list_settlement_batches(p_shipping_carrier_id := current_setting('p7t.carrier')::uuid) where id = current_setting('p7t.d_cod')::uuid) into v_found;
  if not v_found then raise exception 'FAIL 8.11d: p_shipping_carrier_id=carrier1 missed the cod draft'; end if;
  if exists(select 1 from public.list_settlement_batches(p_shipping_carrier_id := current_setting('p7t.carrier')::uuid) where id in (current_setting('p7t.d_visachan')::uuid, current_setting('p7t.d_cash')::uuid)) then
    raise exception 'FAIL 8.11d: p_shipping_carrier_id=carrier1 incorrectly included a payment_collection draft';
  end if;

  -- effective_status := ARRAY['draft'] -> all three fresh drafts, none of
  -- the finalized/reconciled/cancelled batches from earlier sections.
  if not exists(select 1 from public.list_settlement_batches(p_effective_status := array['draft']) where id = current_setting('p7t.d_cod')::uuid) then
    raise exception 'FAIL 8.11e: p_effective_status=ARRAY[''draft''] missed the cod draft';
  end if;
  if exists(select 1 from public.list_settlement_batches(p_effective_status := array['draft']) where id = current_setting('p7t.batch3')::uuid) then
    raise exception 'FAIL 8.11e: p_effective_status=ARRAY[''draft''] incorrectly included the (reconciled) batch3';
  end if;

  raise notice 'PASS: 8.11a-e §25 — route_kind/payment_method_id/collection_channel_id/shipping_carrier_id/effective_status all discriminate correctly across three differently-shaped drafts';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$ declare v_rejected boolean := false; begin
  -- actor 002: settlements.view ONLY, no view_financials.
  begin
    perform public.list_settlement_batches(p_has_variance := true);
  exception when others then
    if sqlerrm like '%يتطلب ترشيح الفروقات المالية صلاحية settlements.view_financials%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.11f: p_has_variance was NOT refused for an actor lacking settlements.view_financials'; end if;
  raise notice 'PASS: 8.11f §25 — p_has_variance is refused outright (not silently ignored) without settlements.view_financials';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$ declare v_found boolean; begin
  -- has_variance := true -> batch_var (real +1.00 variance, still
  -- finalized/not reconciled/not cancelled), NEVER the fresh drafts
  -- (expected_bank_settlement is null -> eff_variance forced to 0
  -- regardless of has_variance's boolean value).
  select exists(select 1 from public.list_settlement_batches(p_has_variance := true) where id = current_setting('p7t.batch_var')::uuid) into v_found;
  if not v_found then raise exception 'FAIL 8.11g: p_has_variance=true missed batch_var''s real +1.00 variance'; end if;
  if exists(select 1 from public.list_settlement_batches(p_has_variance := true) where id = current_setting('p7t.d_cod')::uuid) then
    raise exception 'FAIL 8.11g: p_has_variance=true incorrectly included a draft (null expected_bank_settlement)';
  end if;

  select exists(select 1 from public.list_settlement_batches(p_has_variance := false) where id = current_setting('p7t.d_cod')::uuid) into v_found;
  if not v_found then raise exception 'FAIL 8.11h: p_has_variance=false missed the cod draft (null expected -> eff_variance 0)'; end if;
  if exists(select 1 from public.list_settlement_batches(p_has_variance := false) where id = current_setting('p7t.batch_var')::uuid) then
    raise exception 'FAIL 8.11h: p_has_variance=false incorrectly included batch_var''s real +1.00 variance';
  end if;

  raise notice 'PASS: 8.11g/h §25 — p_has_variance correctly separates a real non-cancelled variance from a draft''s forced-zero eff_variance, both directions';
end $$;

-- ---------------------------------------------------------------------------
-- 8.12 create-only workflow (§7/§24) — get_draft_settlement_batch_for_edit()
-- restricts a create-only (no settlements.view) actor to drafts THEY
-- created, failing closed with the SAME not-found error for someone else's
-- draft (never distinguishable from a bad id); a settlements.view holder is
-- unrestricted. settlement_create_store_lookups() is gated on settlements.
-- create alone (0 rows, not an exception, for an actor without it).
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$ declare v_b record; begin
  -- actor 004: settlements.create ONLY (no settlements.view).
  select * into v_b from public.create_draft_settlement_batch(current_setting('p7t.route_visa_chan')::uuid, public.business_today());
  perform set_config('p7t.batch_own4', v_b.id::text, false);
end $$;
do $$ declare v_row record; begin
  select * into v_row from public.get_draft_settlement_batch_for_edit(current_setting('p7t.batch_own4')::uuid);
  if v_row.id is null then raise exception 'FAIL 8.12a: get_draft_settlement_batch_for_edit() denied the creating actor their OWN draft'; end if;
  raise notice 'PASS: 8.12a a create-only actor can access their OWN draft via get_draft_settlement_batch_for_edit()';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000018","role":"authenticated"}';
do $$ declare v_rejected boolean := false; v_rows integer; begin
  -- actor 018: settlements.create ONLY too, but did NOT create batch_own4.
  begin
    perform public.get_draft_settlement_batch_for_edit(current_setting('p7t.batch_own4')::uuid);
  exception when others then
    if sqlerrm like '%مسودة التسوية غير موجودة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.12b: a create-only actor accessed a draft they did NOT create via get_draft_settlement_batch_for_edit()'; end if;

  select count(*) into v_rows from public.settlement_create_store_lookups();
  if v_rows <> 4 then raise exception 'FAIL 8.12c: settlement_create_store_lookups() for a settlements.create actor (scope=all) expected all 4 stores, got %', v_rows; end if;

  raise notice 'PASS: 8.12b/c §7/§24 — a create-only actor is denied (not-found) another create-only actor''s draft, but sees the full create-gated store lookup (%)', v_rows;
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$ declare v_row record; begin
  -- actor 001 holds settlements.view -> unrestricted, reaches batch_own4
  -- (created by actor 004) despite not having created it.
  select * into v_row from public.get_draft_settlement_batch_for_edit(current_setting('p7t.batch_own4')::uuid);
  if v_row.id is null then raise exception 'FAIL 8.12d: a settlements.view holder was denied a draft they did not create'; end if;
  raise notice 'PASS: 8.12d §7 — a settlements.view holder is unrestricted by get_draft_settlement_batch_for_edit()''s draft-ownership check';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000014","role":"authenticated"}';
do $$ declare v_rows integer; begin
  -- actor 014: ZERO settlements permissions at all — 0 rows, not an
  -- exception (the gate is a WHERE-clause condition, not a raise).
  select count(*) into v_rows from public.settlement_create_store_lookups();
  if v_rows <> 0 then raise exception 'FAIL 8.12e: settlement_create_store_lookups() for a zero-permission actor expected 0 rows, got %', v_rows; end if;
  raise notice 'PASS: 8.12e settlement_create_store_lookups() silently returns 0 rows (not an exception) for an actor lacking settlements.create';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 8.13 manage_routes-only workflow (§24) — the four narrow lookup RPCs from
-- 0190 all work for an actor holding ONLY settlements.manage_routes, with
-- NONE of payment_methods.view/collection_channels.view/shipping_rates.view/
-- settlements.view_financials.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000019","role":"authenticated"}';
do $$
declare v_pm integer; v_cc integer; v_carrier integer; v_fv integer;
begin
  select count(*) into v_pm from public.settlement_route_payment_method_lookups();
  select count(*) into v_cc from public.settlement_route_collection_channel_lookups();
  select count(*) into v_carrier from public.settlement_route_carrier_lookups();
  select count(*) into v_fv from public.list_settlement_route_fee_versions_for_management(current_setting('p7t.route_visa_chan')::uuid);
  if v_pm = 0 or v_cc = 0 or v_carrier = 0 or v_fv = 0 then
    raise exception 'FAIL 8.13: a manage_routes-only actor got an empty result from one of the four §24 lookup RPCs (payment_method=%, collection_channel=%, carrier=%, fee_versions=%) — none require payment_methods.view/collection_channels.view/shipping_rates.view/settlements.view_financials', v_pm, v_cc, v_carrier, v_fv;
  end if;
  raise notice 'PASS: 8.13 §24 — all four manage_routes-only lookup RPCs (payment_method=%, collection_channel=%, carrier=%, fee_versions=%) work for an actor holding ONLY settlements.manage_routes', v_pm, v_cc, v_carrier, v_fv;
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000014","role":"authenticated"}';
do $$ declare v_rows integer; begin
  -- actor 014: ZERO permissions — same silent-empty (WHERE-clause) gate as
  -- settlement_create_store_lookups(), never an exception.
  select count(*) into v_rows from public.settlement_route_payment_method_lookups();
  if v_rows <> 0 then raise exception 'FAIL 8.13b: settlement_route_payment_method_lookups() for a zero-permission actor expected 0 rows, got %', v_rows; end if;
  raise notice 'PASS: 8.13b settlement_route_payment_method_lookups() silently returns 0 rows (not an exception) for an actor lacking settlements.manage_routes';
end $$;

set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 8.14 audit_logs RLS permission matrix (§8) — the two financial branches
-- (A: Sales/Returns/Shipping/Adjustments, keyed on sales.view_profit; B:
-- Settlements, keyed on settlements.view_financials) are now genuinely
-- SEPARATE, never OR'd together. A 'sale.create' row (Branch A) and a
-- 'settlement.finalize' row (Branch B) already exist (order_dc / batch_var).
-- Actor 015 = audit_logs.view alone; 016 = +sales.view_profit; 017 =
-- +settlements.view_financials; 001 = both.
-- ---------------------------------------------------------------------------
do $$
declare v_sale_visible boolean; v_settle_visible boolean;
begin
  set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000015","role":"authenticated"}';
  select exists(select 1 from public.audit_logs where action = 'sale.create' and entity_id = current_setting('p7t.order_dc')::uuid) into v_sale_visible;
  select exists(select 1 from public.audit_logs where action = 'settlement.finalize' and entity_id = current_setting('p7t.batch_var')::uuid) into v_settle_visible;
  if v_sale_visible or v_settle_visible then
    raise exception 'FAIL 8.14a: actor 015 (audit_logs.view ALONE) saw a financial audit row it must not — sale.create visible=%, settlement.finalize visible=%', v_sale_visible, v_settle_visible;
  end if;

  set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000016","role":"authenticated"}';
  select exists(select 1 from public.audit_logs where action = 'sale.create' and entity_id = current_setting('p7t.order_dc')::uuid) into v_sale_visible;
  select exists(select 1 from public.audit_logs where action = 'settlement.finalize' and entity_id = current_setting('p7t.batch_var')::uuid) into v_settle_visible;
  if not v_sale_visible or v_settle_visible then
    raise exception 'FAIL 8.14b: actor 016 (audit_logs.view + sales.view_profit, NO settlements.view_financials) mismatch — sale.create visible=% (want true), settlement.finalize visible=% (want false — proves sales.view_profit grants NOTHING in Branch B)', v_sale_visible, v_settle_visible;
  end if;

  set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000017","role":"authenticated"}';
  select exists(select 1 from public.audit_logs where action = 'sale.create' and entity_id = current_setting('p7t.order_dc')::uuid) into v_sale_visible;
  select exists(select 1 from public.audit_logs where action = 'settlement.finalize' and entity_id = current_setting('p7t.batch_var')::uuid) into v_settle_visible;
  if v_sale_visible or not v_settle_visible then
    raise exception 'FAIL 8.14c: actor 017 (audit_logs.view + settlements.view_financials, NO sales.view_profit) mismatch — sale.create visible=% (want false — proves settlements.view_financials grants NOTHING in Branch A), settlement.finalize visible=% (want true)', v_sale_visible, v_settle_visible;
  end if;

  set local request.jwt.claims = '{"sub":"a7000000-0000-4000-8000-000000000001","role":"authenticated"}';
  select exists(select 1 from public.audit_logs where action = 'sale.create' and entity_id = current_setting('p7t.order_dc')::uuid) into v_sale_visible;
  select exists(select 1 from public.audit_logs where action = 'settlement.finalize' and entity_id = current_setting('p7t.batch_var')::uuid) into v_settle_visible;
  if not v_sale_visible or not v_settle_visible then
    raise exception 'FAIL 8.14d: actor 001 (BOTH permissions) must see both financial audit rows — sale.create visible=%, settlement.finalize visible=%', v_sale_visible, v_settle_visible;
  end if;

  raise notice 'PASS: 8.14a-d §8 — audit_logs Branch A (sales.view_profit) and Branch B (settlements.view_financials) are genuinely separate, never OR''d together across domains, across all 4 permission combinations';
end $$;

-- ---------------------------------------------------------------------------
-- 8.16 fixed_fee scale contract (§18) + source_snapshot rejected for a
-- cod_carrier route at fee-version CREATION itself (§19), not merely at
-- finalize (defense in depth — 0178/0185's finalize-time rejection is
-- covered elsewhere in this file already).
-- ---------------------------------------------------------------------------
do $$ declare v_fv uuid; v_rejected boolean := false; begin
  -- 4dp fixed_fee is ACCEPTED (numeric(12,4) column, §18).
  select public.create_settlement_route_fee_version(current_setting('p7t.route_visa_chan')::uuid, public.business_today() + 1, 'route_formula', 'percentage_plus_fixed', 1.00, 0.1234, 0, null, 'p7 8.16 — 4dp fixed_fee') into v_fv;
  if v_fv is null then raise exception 'FAIL 8.16a: create_settlement_route_fee_version() rejected a 4dp fixed_fee (0.1234), which the column''s own numeric(12,4) precision must accept'; end if;

  -- MORE than 4dp is still rejected.
  begin
    perform public.create_settlement_route_fee_version(current_setting('p7t.route_visa_chan')::uuid, public.business_today() + 2, 'route_formula', 'percentage_plus_fixed', 1.00, 0.12345, 0, null, 'p7 8.16 — 5dp fixed_fee');
  exception when others then
    if sqlerrm like '%الرسوم الثابتة%لا يحتوي على أكثر من 4 منازل عشرية%' or sqlerrm like '%لا يحتوي على أكثر من%منازل عشرية%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.16b: a fixed_fee with MORE than 4 decimal places (0.12345) was NOT rejected'; end if;

  raise notice 'PASS: 8.16a/b §18 — fixed_fee accepts up to 4dp (matching its numeric(12,4) column), rejects beyond it';
end $$;

do $$ declare v_rejected boolean := false; begin
  -- source_snapshot for a cod_carrier route is rejected at CREATION time
  -- itself (§19), not only deferred to finalize.
  begin
    perform public.create_settlement_route_fee_version(current_setting('p7t.route_cod')::uuid, public.business_today() + 1, 'source_snapshot', null, null, null, 0, 'none', 'p7 8.16 — source_snapshot on COD, must be rejected at creation');
  exception when others then
    if sqlerrm like '%source_snapshot غير صالحة لمسار COD ناقل%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 8.16c: create_settlement_route_fee_version(transaction_fee_strategy := ''source_snapshot'') on a cod_carrier route was NOT rejected at CREATION'; end if;
  raise notice 'PASS: 8.16c §19 — source_snapshot is rejected for a cod_carrier route at create_settlement_route_fee_version() itself, not only deferred to finalize';
end $$;

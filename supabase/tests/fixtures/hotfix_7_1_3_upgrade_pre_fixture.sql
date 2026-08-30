-- ============================================================================
-- Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3 — PRE-upgrade
-- fixture (§11/§13/§17 item E).
--
-- Runs against a database that has migrations 0001-0196 (the Hotfix 7.1.1
-- end state) + the real supabase/seed.sql applied, AFTER
-- hotfix_7_1_2_upgrade_pre_fixture.sql has already been applied in the same
-- run (§12's existing scenario) — i.e. still BEFORE 0197/0198 exist, so
-- sales_returns has NO collection_channel_id_snapshot column yet and
-- refresh_pending_sales_return_from_sale() (0100, frozen) is the ONLY
-- mechanism that can move payment_method_id off its creation-time value.
--
-- Builds TWO scenarios the ORIGINAL 0197 backfill (timestamp/"first update
-- after created_at" heuristic) would have reconstructed WRONG, and which the
-- corrected 0197 (source_sale_row_version-keyed) must reconstruct correctly:
--
--   Scenario 1 (§11, CRITICAL): Refreshed Pending Return, left PENDING.
--     Sale V1 A/A -> create Pending Return (basis=V1/A) -> Sale V2 B/B ->
--     refresh_pending_sales_return_from_sale() (basis becomes V2/B) -> Return
--     is left PENDING (not approved) at fixture-commit time. Under the OLD
--     0001-0196 contract, sales_returns.payment_method_id is ALREADY B here,
--     BEFORE 0197 ever runs — proving the "creation-time permanent snapshot"
--     assumption was false to begin with.
--
--   Scenario 2 (§13): Multi-refresh Return, left PENDING.
--     Sale V1 A/A -> create Return (basis=V1/A) -> Sale V2 B/B -> refresh
--     (basis=V2/B) -> Sale V3 C/C -> refresh again (basis=V3/C) -> left
--     PENDING. Exercises a backfill reconstruction basis of row_version=3,
--     confirming the audit-log match is not accidentally hard-coded to "the
--     second event" or similar.
--
-- Results recorded into a PERMANENT (non-temp) scratch table,
-- public.h713u_scratch, mirroring public.h712u_scratch's exact convention.
--
-- NOTE: deliberately NOT wrapped in begin/rollback (data must be COMMITTED)
-- and psql runs each top-level statement in its own implicit transaction, so
-- plain SET (session-scoped) is used, never SET LOCAL.
-- ============================================================================

create table if not exists public.h713u_scratch (label text primary key, value text);

insert into auth.users (id, email) values
  ('a7130000-0000-4000-8000-000000000001', 'test-h713u-admin@example.invalid')
  on conflict do nothing;

update public.profiles set full_name = 'H713U Upgrade Fixture Admin', status = 'active', store_access_scope = 'all'
  where id = 'a7130000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select 'a7130000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

set role authenticated;
set request.jwt.claims = '{"sub":"a7130000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 1. Master data + THREE fully independent (payment method, collection
--    channel, settlement route) triples — A/B/C — minted fresh (never reused
--    from supabase/seed.sql or hotfix_7_1_2's fixture) so there is no risk
--    of colliding with the settlement_routes payment/channel unique index,
--    and each uses fee_model='percentage'/refund_fee_policy=
--    'proportional_reversal' so a later post-upgrade approval always yields
--    a nonzero payment_fee_reversal_amount for a meaningful Discovery proof.
-- ---------------------------------------------------------------------------
do $$
declare
  v_store uuid; v_karat_id uuid; v_category_id uuid;
  v_pm_a uuid; v_pm_b uuid; v_pm_c uuid; v_chan_a uuid; v_chan_b uuid; v_chan_c uuid;
  v_route_a uuid; v_route_b uuid; v_route_c uuid;
begin
  insert into public.stores (code, name_ar, status) values ('H713US', 'فرع ترقية 7.1.3', 'active') returning id into v_store;
  insert into public.karats (code, name_ar, sort_order, status) values ('H713UK', 'عيار ترقية 7.1.3', 982, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h713ucat', 'تصنيف ترقية 7.1.3', 982, 'active') returning id into v_category_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 280.0000, 'a7130000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'h713u fixture');

  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, status)
    values ('h713u_pm_a', 'طريقة ترقية 7.1.3 - أ', 'percentage', 'proportional_reversal', 'active') returning id into v_pm_a;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, status)
    values ('h713u_pm_b', 'طريقة ترقية 7.1.3 - ب', 'percentage', 'proportional_reversal', 'active') returning id into v_pm_b;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, status)
    values ('h713u_pm_c', 'طريقة ترقية 7.1.3 - ج', 'percentage', 'proportional_reversal', 'active') returning id into v_pm_c;
  perform public.create_payment_method_fee_version(v_pm_a, 4.00, 0, public.business_today() - 30, 'h713u fee a');
  perform public.create_payment_method_fee_version(v_pm_b, 5.00, 0, public.business_today() - 30, 'h713u fee b');
  perform public.create_payment_method_fee_version(v_pm_c, 6.00, 0, public.business_today() - 30, 'h713u fee c');

  insert into public.collection_channels (key, name_ar, sort_order, status)
    values ('h713u_chan_a', 'قناة ترقية 7.1.3 - أ', 986, 'active') returning id into v_chan_a;
  insert into public.collection_channels (key, name_ar, sort_order, status)
    values ('h713u_chan_b', 'قناة ترقية 7.1.3 - ب', 987, 'active') returning id into v_chan_b;
  insert into public.collection_channels (key, name_ar, sort_order, status)
    values ('h713u_chan_c', 'قناة ترقية 7.1.3 - ج', 988, 'active') returning id into v_chan_c;

  select public.create_settlement_route('h713u-route-a', 'مسار ترقية 7.1.3 - أ', 'payment_collection', 'H713U Route A', v_pm_a, v_chan_a) into v_route_a;
  perform public.create_settlement_route_fee_version(v_route_a, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h713u fee a');
  select public.create_settlement_route('h713u-route-b', 'مسار ترقية 7.1.3 - ب', 'payment_collection', 'H713U Route B', v_pm_b, v_chan_b) into v_route_b;
  perform public.create_settlement_route_fee_version(v_route_b, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h713u fee b');
  select public.create_settlement_route('h713u-route-c', 'مسار ترقية 7.1.3 - ج', 'payment_collection', 'H713U Route C', v_pm_c, v_chan_c) into v_route_c;
  perform public.create_settlement_route_fee_version(v_route_c, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h713u fee c');

  perform set_config('h713u.store', v_store::text, false);
  perform set_config('h713u.karat_id', v_karat_id::text, false);
  perform set_config('h713u.category_id', v_category_id::text, false);
  perform set_config('h713u.pm_a', v_pm_a::text, false);
  perform set_config('h713u.pm_b', v_pm_b::text, false);
  perform set_config('h713u.pm_c', v_pm_c::text, false);
  perform set_config('h713u.chan_a', v_chan_a::text, false);
  perform set_config('h713u.chan_b', v_chan_b::text, false);
  perform set_config('h713u.chan_c', v_chan_c::text, false);
  perform set_config('h713u.route_a', v_route_a::text, false);
  perform set_config('h713u.route_b', v_route_b::text, false);
  perform set_config('h713u.route_c', v_route_c::text, false);

  insert into public.h713u_scratch values ('store', v_store::text);
  insert into public.h713u_scratch values ('pm_a', v_pm_a::text);
  insert into public.h713u_scratch values ('pm_b', v_pm_b::text);
  insert into public.h713u_scratch values ('pm_c', v_pm_c::text);
  insert into public.h713u_scratch values ('chan_a', v_chan_a::text);
  insert into public.h713u_scratch values ('chan_b', v_chan_b::text);
  insert into public.h713u_scratch values ('chan_c', v_chan_c::text);
  insert into public.h713u_scratch values ('route_a', v_route_a::text);
  insert into public.h713u_scratch values ('route_b', v_route_b::text);
  insert into public.h713u_scratch values ('route_c', v_route_c::text);

  raise notice 'H713U SETUP OK: store=%, routes a/b/c=%/%/%', v_store, v_route_a, v_route_b, v_route_c;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Scenario 1 (§11): Refreshed Pending Return, left PENDING, under the OLD
--    (pre-0197) contract. payment_method_id ALREADY moves to B here, purely
--    via the pre-existing, frozen refresh_pending_sales_return_from_sale()
--    (0100) — the exact fact the ORIGINAL 0197 design got wrong.
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_item_id uuid; v_subtotal numeric; v_rv bigint;
  v_return record;
  v_order_after jsonb; v_return_after jsonb;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h713u.store')::uuid, public.business_today(),
    current_setting('h713u.pm_a')::uuid, current_setting('h713u.chan_a')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h713u.category_id')::uuid, 'karat_id', current_setting('h713u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل ترقية 7.1.3 — سيناريو 1', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  v_rv := (public.get_sales_order(v_order.id) ->> 'row_version')::bigint;
  v_item_id := (public.get_sales_order(v_order.id) -> 'items' -> 0 ->> 'id')::uuid;

  select * into v_return from public.create_sales_return(
    v_order.id, current_setting('h713u.store')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار ترقية 7.1.3 — سيناريو 1')),
    v_rv, 'collected', v_subtotal
  );

  -- Sale V1 -> V2 (A/A -> B/B), item id preserved so the pending Return's
  -- reference survives (established idiom).
  perform public.update_sales_order(
    v_order.id, current_setting('h713u.pm_b')::uuid, current_setting('h713u.chan_b')::uuid,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', current_setting('h713u.category_id')::uuid, 'karat_id', current_setting('h713u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل ترقية 7.1.3 — سيناريو 1 (بعد التعديل)', null, null, null,
    (public.get_sales_order(v_order.id) ->> 'row_version')::bigint
  );

  -- The ONLY sanctioned pre-0197 mechanism that can move payment_method_id.
  perform public.refresh_pending_sales_return_from_sale(v_return.id, (public.get_sales_return(v_return.id) ->> 'row_version')::bigint);

  v_return_after := public.get_sales_return(v_return.id);
  v_order_after := public.get_sales_order(v_order.id);

  assert v_return_after ->> 'status' = 'pending', format('BUG fixture setup: expected the Return to remain pending, got %s', v_return_after ->> 'status');
  assert v_return_after ->> 'payment_method_id' = current_setting('h713u.pm_b'), format('BUG fixture setup: expected payment_method_id=B already under the OLD contract (0100''s refresh RPC is pre-existing/frozen), got %s', v_return_after ->> 'payment_method_id');
  assert (v_return_after ->> 'source_sale_row_version')::bigint = 2, format('BUG fixture setup: expected source_sale_row_version=2 after one refresh, got %s', v_return_after ->> 'source_sale_row_version');
  assert v_order_after ->> 'payment_method_id' = current_setting('h713u.pm_b'), 'BUG fixture setup: expected the Sale itself to be on Payment Method B';

  perform set_config('h713u.s1_order_id', v_order.id::text, false);
  perform set_config('h713u.s1_return_id', v_return.id::text, false);

  insert into public.h713u_scratch values ('s1_order_id', v_order.id::text);
  insert into public.h713u_scratch values ('s1_return_id', v_return.id::text);
  insert into public.h713u_scratch values ('s1_return_number', v_return.return_number);

  raise notice 'H713U SCENARIO 1 (§11) OK: order=% return=% — Return refreshed ONCE (A/A -> B/B) under the OLD 0001-0196 contract, left PENDING (payment_method_id=B, source_sale_row_version=2 ALREADY, before 0197 has ever run)', v_order.id, v_return.id;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Scenario 2 (§13): Multi-refresh Return, left PENDING. Basis moves
--    V1(A) -> V2(B) -> V3(C), two refreshes, still under the OLD contract.
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_item_id uuid; v_subtotal numeric; v_rv bigint;
  v_return record;
  v_return_after jsonb;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h713u.store')::uuid, public.business_today(),
    current_setting('h713u.pm_a')::uuid, current_setting('h713u.chan_a')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h713u.category_id')::uuid, 'karat_id', current_setting('h713u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 800.00)),
    'عميل ترقية 7.1.3 — سيناريو 2', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  v_rv := (public.get_sales_order(v_order.id) ->> 'row_version')::bigint;
  v_item_id := (public.get_sales_order(v_order.id) -> 'items' -> 0 ->> 'id')::uuid;

  select * into v_return from public.create_sales_return(
    v_order.id, current_setting('h713u.store')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار ترقية 7.1.3 — سيناريو 2')),
    v_rv, 'collected', v_subtotal
  );

  -- V1 -> V2 (A/A -> B/B) + refresh.
  perform public.update_sales_order(
    v_order.id, current_setting('h713u.pm_b')::uuid, current_setting('h713u.chan_b')::uuid,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', current_setting('h713u.category_id')::uuid, 'karat_id', current_setting('h713u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 800.00)),
    'عميل ترقية 7.1.3 — سيناريو 2 (V2)', null, null, null,
    (public.get_sales_order(v_order.id) ->> 'row_version')::bigint
  );
  perform public.refresh_pending_sales_return_from_sale(v_return.id, (public.get_sales_return(v_return.id) ->> 'row_version')::bigint);

  -- V2 -> V3 (B/B -> C/C) + refresh again.
  perform public.update_sales_order(
    v_order.id, current_setting('h713u.pm_c')::uuid, current_setting('h713u.chan_c')::uuid,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', current_setting('h713u.category_id')::uuid, 'karat_id', current_setting('h713u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 800.00)),
    'عميل ترقية 7.1.3 — سيناريو 2 (V3)', null, null, null,
    (public.get_sales_order(v_order.id) ->> 'row_version')::bigint
  );
  perform public.refresh_pending_sales_return_from_sale(v_return.id, (public.get_sales_return(v_return.id) ->> 'row_version')::bigint);

  v_return_after := public.get_sales_return(v_return.id);
  assert v_return_after ->> 'status' = 'pending', format('BUG fixture setup: expected the Return to remain pending, got %s', v_return_after ->> 'status');
  assert v_return_after ->> 'payment_method_id' = current_setting('h713u.pm_c'), format('BUG fixture setup: expected payment_method_id=C after two refreshes, got %s', v_return_after ->> 'payment_method_id');
  assert (v_return_after ->> 'source_sale_row_version')::bigint = 3, format('BUG fixture setup: expected source_sale_row_version=3 after two refreshes, got %s', v_return_after ->> 'source_sale_row_version');

  perform set_config('h713u.s2_order_id', v_order.id::text, false);
  perform set_config('h713u.s2_return_id', v_return.id::text, false);

  insert into public.h713u_scratch values ('s2_order_id', v_order.id::text);
  insert into public.h713u_scratch values ('s2_return_id', v_return.id::text);
  insert into public.h713u_scratch values ('s2_return_number', v_return.return_number);

  raise notice 'H713U SCENARIO 2 (§13) OK: order=% return=% — Return refreshed TWICE (A/A -> B/B -> C/C) under the OLD 0001-0196 contract, left PENDING (payment_method_id=C, source_sale_row_version=3)', v_order.id, v_return.id;
end $$;

-- ---------------------------------------------------------------------------
-- 4. "Byte-identical" snapshots (as postgres, bypassing RLS) — proves
--    0197-0198 never touch any pre-existing column on these rows, only ADD
--    collection_channel_id_snapshot.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;

do $$
begin
  insert into public.h713u_scratch select 's1_return_row_json_pre_upgrade', to_jsonb(r)::text from public.sales_returns r where r.id = current_setting('h713u.s1_return_id')::uuid;
  insert into public.h713u_scratch select 's2_return_row_json_pre_upgrade', to_jsonb(r)::text from public.sales_returns r where r.id = current_setting('h713u.s2_return_id')::uuid;
  raise notice 'H713U byte-identical pre-upgrade snapshots recorded into public.h713u_scratch.';
end $$;

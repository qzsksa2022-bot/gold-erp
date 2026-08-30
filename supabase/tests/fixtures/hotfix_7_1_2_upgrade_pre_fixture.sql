-- ============================================================================
-- Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2 — PRE-upgrade
-- fixture (§11/§15 item E).
-- Runs against a database that has migrations 0001-0196 (the Hotfix 7.1.1
-- end state) + the real supabase/seed.sql applied — i.e. BEFORE 0197/0198
-- exist, so sales_returns has NO collection_channel_id_snapshot column yet
-- and _settlement_unsettled_source_candidates() still matches return_fee_
-- reversal/_reversal via a LIVE join to sales_orders (0192's rule — the
-- exact bug this hotfix fixes).
--
-- Builds the EXACT §1/§9 route-drift scenario under the OLD contracts:
--   Sale (Payment Method A / Channel A) -> full Return -> Approve ->
--   Reverse -> edit the Sale to Payment Method B / Channel B (permitted
--   post-reversal by 0084's lock, which only checks status='approved').
--
-- Confirms, still under the OLD (pre-0197) contract, that the pre-existing
-- bug is real and reachable: Discovery already shows both fee events on
-- Route B (the Sale's NEW live route) instead of Route A — recorded into
-- the scratch table as the "before" baseline so the upgrade test can prove
-- 0197-0198 correct this without altering any already-committed row.
--
-- Results are recorded in a PERMANENT (non-temp) scratch table,
-- public.h712u_scratch, mirroring public.h711u_scratch's exact convention.
--
-- NOTE: deliberately NOT wrapped in begin/rollback (data must be COMMITTED)
-- and psql runs each top-level statement in its own implicit transaction, so
-- plain SET (session-scoped) is used, never SET LOCAL.
-- ============================================================================

create table if not exists public.h712u_scratch (label text primary key, value text);

insert into auth.users (id, email) values
  ('a7120000-0000-4000-8000-000000000001', 'test-h712u-admin@example.invalid')
  on conflict do nothing;

update public.profiles set full_name = 'H712U Upgrade Fixture Admin', status = 'active', store_access_scope = 'all'
  where id = 'a7120000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select 'a7120000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

set role authenticated;
set request.jwt.claims = '{"sub":"a7120000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 1. Master data + two routes (Route A: pm_a/chan_a, Route B: pm_b/chan_b).
-- ---------------------------------------------------------------------------
do $$
declare
  v_store uuid; v_karat_id uuid; v_category_id uuid;
  v_pm_a uuid; v_pm_b uuid; v_chan_a uuid; v_chan_b uuid;
  v_route_a uuid; v_route_b uuid;
begin
  insert into public.stores (code, name_ar, status) values ('H712US', 'فرع ترقية 7.1.2', 'active') returning id into v_store;
  insert into public.karats (code, name_ar, sort_order, status) values ('H712UK', 'عيار ترقية 7.1.2', 981, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h712ucat', 'تصنيف ترقية 7.1.2', 981, 'active') returning id into v_category_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 280.0000, 'a7120000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'h712u fixture');

  select id into v_pm_a from public.payment_methods where key = 'tabby';
  select id into v_pm_b from public.payment_methods where key = 'tamara';
  select id into v_chan_a from public.collection_channels where key = 'direct_store';
  select id into v_chan_b from public.collection_channels where key = 'salla_wallet';

  select public.create_settlement_route('h712u-route-a', 'مسار ترقية 7.1.2 - أ', 'payment_collection', 'H712U Route A', v_pm_a, v_chan_a) into v_route_a;
  select public.create_settlement_route('h712u-route-b', 'مسار ترقية 7.1.2 - ب', 'payment_collection', 'H712U Route B', v_pm_b, v_chan_b) into v_route_b;
  perform public.create_settlement_route_fee_version(v_route_a, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h712u fee a');
  perform public.create_settlement_route_fee_version(v_route_b, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h712u fee b');

  perform set_config('h712u.store', v_store::text, false);
  perform set_config('h712u.karat_id', v_karat_id::text, false);
  perform set_config('h712u.category_id', v_category_id::text, false);
  perform set_config('h712u.pm_a', v_pm_a::text, false);
  perform set_config('h712u.pm_b', v_pm_b::text, false);
  perform set_config('h712u.chan_a', v_chan_a::text, false);
  perform set_config('h712u.chan_b', v_chan_b::text, false);
  perform set_config('h712u.route_a', v_route_a::text, false);
  perform set_config('h712u.route_b', v_route_b::text, false);

  insert into public.h712u_scratch values ('store', v_store::text);
  insert into public.h712u_scratch values ('pm_a', v_pm_a::text);
  insert into public.h712u_scratch values ('pm_b', v_pm_b::text);
  insert into public.h712u_scratch values ('chan_a', v_chan_a::text);
  insert into public.h712u_scratch values ('chan_b', v_chan_b::text);
  insert into public.h712u_scratch values ('route_a', v_route_a::text);
  insert into public.h712u_scratch values ('route_b', v_route_b::text);

  raise notice 'H712U SETUP OK: store=%, route_a=%, route_b=%', v_store, v_route_a, v_route_b;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Sale A/A -> full Return -> Approve -> Reverse -> edit Sale to B/B, all
--    under the OLD (pre-0197) contract. The pending sales_return.payment_
--    method_id snapshot (0082/0100, pre-existing) captures A now; the NEW
--    collection_channel_id_snapshot column does not exist yet at this point
--    in migration history — it is added, and backfilled from audit history,
--    only once 0197 runs (later, in the actual upgrade test script).
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_item_id uuid; v_subtotal numeric; v_rv bigint;
  v_return record; v_return_fee numeric;
  v_order_after jsonb;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h712u.store')::uuid, public.business_today(),
    current_setting('h712u.pm_a')::uuid, current_setting('h712u.chan_a')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h712u.category_id')::uuid, 'karat_id', current_setting('h712u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل ترقية 7.1.2 — أ', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  v_rv := (public.get_sales_order(v_order.id) ->> 'row_version')::bigint;
  v_item_id := (public.get_sales_order(v_order.id) -> 'items' -> 0 ->> 'id')::uuid;

  select * into v_return from public.create_sales_return(
    v_order.id, current_setting('h712u.store')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار ترقية 7.1.2 — أ')),
    v_rv, 'collected', v_subtotal
  );
  perform public.approve_sales_return(v_return.id, (public.get_sales_return(v_return.id) ->> 'row_version')::bigint);
  v_return_fee := (public.get_sales_return(v_return.id) ->> 'payment_fee_reversal_amount')::numeric;
  assert v_return_fee > 0, format('BUG fixture setup: expected a nonzero payment_fee_reversal_amount, got %s', v_return_fee);

  perform public.reverse_sales_return(v_return.id, (public.get_sales_return(v_return.id) ->> 'row_version')::bigint, 'اختبار ترقية 7.1.2 — عكس قبل تعديل البيع', null);

  -- Edit the Sale to B/B AFTER the Return was reversed — permitted by
  -- 0084's lock (status='approved' only). New item set (no 'id') mirrors
  -- the established update_sales_order() idiom.
  perform public.update_sales_order(
    v_order.id, current_setting('h712u.pm_b')::uuid, current_setting('h712u.chan_b')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h712u.category_id')::uuid, 'karat_id', current_setting('h712u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل ترقية 7.1.2 — أ (بعد التعديل)', null, null, null,
    (public.get_sales_order(v_order.id) ->> 'row_version')::bigint
  );

  v_order_after := public.get_sales_order(v_order.id);
  assert v_order_after ->> 'payment_method_id' = current_setting('h712u.pm_b'), 'BUG fixture setup: expected the Sale to now be on Payment Method B';
  assert v_order_after ->> 'collection_channel_id' = current_setting('h712u.chan_b'), 'BUG fixture setup: expected the Sale to now be on Channel B';

  perform set_config('h712u.order_id', v_order.id::text, false);
  perform set_config('h712u.return_id', v_return.id::text, false);

  insert into public.h712u_scratch values ('order_id', v_order.id::text);
  insert into public.h712u_scratch values ('return_id', v_return.id::text);
  insert into public.h712u_scratch values ('return_number', v_return.return_number);
  insert into public.h712u_scratch values ('payment_fee_reversal_amount', v_return_fee::text);

  raise notice 'H712U ROUTE-DRIFT FIXTURE OK: order=% return=% (fee_reversal=%), Sale now on B/B AFTER Return was approved+reversed while it was A/A', v_order.id, v_return.id, v_return_fee;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Confirm the PRE-UPGRADE bug baseline: under the OLD (0192) matching
--    rule, Discovery already resolves both fee events to Route B (the
--    Sale's NEW live route) — NOT Route A, where the Return was actually
--    created/approved/reversed. This is the exact defect 0197-0198 fix.
-- ---------------------------------------------------------------------------
do $$
declare v_on_a int; v_on_b int;
begin
  select count(*) filter (where source_kind in ('return_fee_reversal', 'return_fee_reversal_reversal') and source_event_id = current_setting('h712u.return_id')::uuid)
  into v_on_a
  from public.list_unsettled_settlement_sources(current_setting('h712u.route_a')::uuid, public.business_today() - 5, public.business_today() + 1);

  select count(*) filter (where source_kind in ('return_fee_reversal', 'return_fee_reversal_reversal') and source_event_id = current_setting('h712u.return_id')::uuid)
  into v_on_b
  from public.list_unsettled_settlement_sources(current_setting('h712u.route_b')::uuid, public.business_today() - 5, public.business_today() + 1);

  insert into public.h712u_scratch values ('pre_upgrade_fee_events_on_route_a', v_on_a::text);
  insert into public.h712u_scratch values ('pre_upgrade_fee_events_on_route_b', v_on_b::text);

  raise notice 'H712U PRE-UPGRADE BASELINE: fee events on Route A=% (expected 0, the OLD bug never routes here) / Route B=% (expected 2, the OLD bug''s LIVE-join misroute) — confirms the §1 vulnerability is real BEFORE this hotfix''s migrations run', v_on_a, v_on_b;
end $$;

-- ---------------------------------------------------------------------------
-- 4. "Byte-identical" snapshot of the Return row (as postgres, bypassing
--    RLS) — proves 0197-0198 never touch this row's pre-existing columns,
--    only ADD collection_channel_id_snapshot to it.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;

do $$
begin
  insert into public.h712u_scratch select 'return_row_json_pre_upgrade', to_jsonb(r)::text from public.sales_returns r where r.id = current_setting('h712u.return_id')::uuid;
  insert into public.h712u_scratch select 'order_row_json_pre_upgrade', to_jsonb(o)::text from public.sales_orders o where o.id = current_setting('h712u.order_id')::uuid;
  raise notice 'H712U byte-identical pre-upgrade snapshots recorded into public.h712u_scratch.';
end $$;

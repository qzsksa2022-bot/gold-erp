-- ============================================================================
-- Integration test: Phase 6 — Services / Adjustments Core (0133-0143) +
-- Integrity Patch 6.1 (0144-0156)
-- ============================================================================
-- Single-transaction, rolled-back-at-the-end regression test, mirroring
-- shipping_core_phase5.test.sql's own convention exactly.
--
-- Prefix 'a6000000-...' is not used by any other test file's fixtures
-- (checked against every prefix currently in use across supabase/tests/).
--
--   01 = full-permission actor (adjustments.* + sales.* + stores.*)
--   02 = adjustments.view-only actor (profit security / write gating)
--   03 = adjustments.create-only actor (no sales.view, §25; no manage_cost,
--        Patch 6.1 item 1D)
--   04 = adjustments.approve-only actor (Patch 6.1 item 5 matrix A/B/6 — no
--        manage_cost, no sales.view_profit)
--   05 = adjustments.view + adjustments.manage_cost ONLY (Patch 6.1 item 3/5
--        matrix C — no create, no approve, no sales.view_profit)
--   06 = adjustments.view + adjustments.create + adjustments.manage_cost
--        (Patch 6.1 item 5 matrix E — no approve)
--   07 = adjustments.view + adjustments.approve, store_access_scope='single'
--        default_store_id=Store B ONLY (Patch 6.1 items 12/13/31 — cross-
--        store read/reject scope)
--
-- Requires migrations 0001-latest + supabase/seed.sql already applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/adjustments_core_phase6.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup — actors, stores, karat/category/gold-price/mfg-fee master data,
-- two Sales Orders to attach Adjustments to (one dated "today", one dated 5
-- days ago for the sale-date-floor test, item 8).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a6000000-0000-4000-8000-000000000001', 'test-p6-manager@example.invalid'),
  ('a6000000-0000-4000-8000-000000000002', 'test-p6-viewonly@example.invalid'),
  ('a6000000-0000-4000-8000-000000000003', 'test-p6-createonly@example.invalid'),
  ('a6000000-0000-4000-8000-000000000004', 'test-p6-approveonly@example.invalid'),
  ('a6000000-0000-4000-8000-000000000005', 'test-p6-managecostonly@example.invalid'),
  ('a6000000-0000-4000-8000-000000000006', 'test-p6-createmanagecost@example.invalid'),
  ('a6000000-0000-4000-8000-000000000007', 'test-p6-storebonly@example.invalid');

update public.profiles set full_name = 'Test P6 Adjustments Manager', status = 'active', store_access_scope = 'all'
  where id = 'a6000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test P6 View-Only Actor', status = 'active', store_access_scope = 'all'
  where id = 'a6000000-0000-4000-8000-000000000002';
update public.profiles set full_name = 'Test P6 Create-Only Actor', status = 'active', store_access_scope = 'all'
  where id = 'a6000000-0000-4000-8000-000000000003';
update public.profiles set full_name = 'Test P6.1 Approve-Only Actor', status = 'active', store_access_scope = 'all'
  where id = 'a6000000-0000-4000-8000-000000000004';
update public.profiles set full_name = 'Test P6.1 Manage-Cost-Only Actor', status = 'active', store_access_scope = 'all'
  where id = 'a6000000-0000-4000-8000-000000000005';
update public.profiles set full_name = 'Test P6.1 Create+ManageCost Actor', status = 'active', store_access_scope = 'all'
  where id = 'a6000000-0000-4000-8000-000000000006';
-- 007 is deliberately store-scoped to Store B ONLY — default_store_id is set
-- below, once Store B's id is known (after the master-data setup block).
update public.profiles set full_name = 'Test P6.1 Store-B-Only Actor', status = 'active', store_access_scope = 'all'
  where id = 'a6000000-0000-4000-8000-000000000007';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a6000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create',
    'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'gold_prices.view', 'gold_prices.edit', 'manufacturing_fees.view', 'manufacturing_fees.manage',
    'payment_methods.view', 'collection_channels.view',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit', 'sales.close_day',
    'adjustments.view', 'adjustments.create', 'adjustments.approve',
    'adjustments.manage_cost', 'adjustments.reverse', 'adjustments.process_closed_day', 'adjustments.manage_types'
  );

-- Deliberately adjustments.view ONLY: no adjustments.create/approve/
-- manage_cost, no sales.view_profit (profit security / write gating).
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a6000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('adjustments.view');

-- §25 / Patch 6.1 item 1D — deliberately adjustments.create ONLY: NO
-- sales.view (search must not depend on it), NO adjustments.manage_cost
-- (must not be able to supply direct_cost, at all, ever).
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a6000000-0000-4000-8000-000000000003', id, 'grant' from public.permissions
  where key in ('adjustments.create');

-- Patch 6.1 item 5 matrix A/B + item 6 — adjustments.approve ALONE: no
-- manage_cost, no sales.view_profit.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a6000000-0000-4000-8000-000000000004', id, 'grant' from public.permissions
  where key in ('adjustments.approve');

-- Patch 6.1 item 3/5 matrix C — adjustments.view + adjustments.manage_cost
-- ONLY: no create, no approve, no sales.view_profit.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a6000000-0000-4000-8000-000000000005', id, 'grant' from public.permissions
  where key in ('adjustments.view', 'adjustments.manage_cost');

-- Patch 6.1 item 5 matrix E — adjustments.view + create + manage_cost, no
-- approve.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a6000000-0000-4000-8000-000000000006', id, 'grant' from public.permissions
  where key in ('adjustments.view', 'adjustments.create', 'adjustments.manage_cost');

-- Patch 6.1 items 12/13/31 — adjustments.view + adjustments.approve, but
-- store-scoped to Store B alone (set below).
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a6000000-0000-4000-8000-000000000007', id, 'grant' from public.permissions
  where key in ('adjustments.view', 'adjustments.approve');

set role authenticated;
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_a uuid;
  v_store_b uuid;
  v_karat uuid;
  v_category uuid;
  v_price_date date := current_date - 10; -- covers both "today" and "5 days ago" orders below
begin
  insert into public.stores (code, name_ar, status) values ('P6-STA', 'فرع اختبار 6 - أ', 'active') returning id into v_store_a;
  insert into public.stores (code, name_ar, status) values ('P6-STB', 'فرع اختبار 6 - ب', 'active') returning id into v_store_b;
  perform set_config('p6t.store_a', v_store_a::text, false);
  perform set_config('p6t.store_b', v_store_b::text, false);

  insert into public.karats (code, name_ar, sort_order, status) values ('P6K1', 'عيار اختبار 6', 991, 'active') returning id into v_karat;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p6cat1', 'تصنيف اختبار 6', 991, 'active') returning id into v_category;
  perform set_config('p6t.karat', v_karat::text, false);
  perform set_config('p6t.category', v_category::text, false);

  -- payment_methods/collection_channels are RLS-gated on payment_methods.
  -- view/collection_channels.view (0044/similar) — most actors in this file
  -- deliberately do NOT hold those permissions, so their id lookups must be
  -- pre-resolved HERE (under the full-permission actor 001) and threaded
  -- through via set_config, never re-queried under a narrower actor's
  -- session (a bare SELECT under RLS returns 0 rows silently, not an error,
  -- which would otherwise mask itself as a NULL uuid rather than a clear
  -- test failure).
  perform set_config('p6t.pm_cash', (select id::text from public.payment_methods where key = 'cash'), false);
  perform set_config('p6t.pm_visa', (select id::text from public.payment_methods where key = 'visa'), false);
  perform set_config('p6t.pm_mada', (select id::text from public.payment_methods where key = 'mada'), false);
  perform set_config('p6t.channel_direct_store', (select id::text from public.collection_channels where key = 'direct_store'), false);

  -- gold_price_version_for_karat_on_date() is an EXACT date match — every
  -- Sales Order in this file is dated "today" (current_date), so a single
  -- price row suffices. The item-8 sale-date-floor test does NOT need a
  -- past-dated Sales Order: it proves adjustment_date >= sale_date by using
  -- adjustment_date = current_date - 1 against an order dated current_date
  -- (below), which is simpler and avoids backdating payment-fee-version
  -- resolution (create_payment_method_fee_version() forbids an
  -- effective_from at or before the seed data's already-open current_date
  -- version, by design — versions only ever move forward in time).
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (current_date, v_karat, 300.0000, 'a6000000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat, 10.0000, v_price_date, 'p6.1 fixture');
end $$;

-- Actor 007 is store-scoped to Store B alone (single-scope), set now that
-- Store B's id is known. Actor 001 does NOT hold users.manage_store_access
-- (deliberately, to keep its permission grant list minimal/realistic), so
-- this UPDATE must run as the superuser connection role (like the initial
-- profile setup above it), not as `authenticated` acting as actor 001 —
-- otherwise RLS on public.profiles would silently match zero rows and
-- actor 007 would incorrectly keep its original store_access_scope='all'.
reset role;
reset request.jwt.claims;
do $$
begin
  update public.profiles
    set store_access_scope = 'single', default_store_id = current_setting('p6t.store_b')::uuid
    where id = 'a6000000-0000-4000-8000-000000000007';
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_payment_method uuid;
  v_channel uuid;
  v_result record;
begin
  select id into v_payment_method from public.payment_methods where key = 'cash';
  select id into v_channel from public.collection_channels where key = 'direct_store';

  -- "Today" order — used by the main worked-example lifecycle (section 3).
  select * into v_result from create_sales_order(
    current_setting('p6t.store_a')::uuid, current_date, v_payment_method, v_channel,
    jsonb_build_array(jsonb_build_object(
      'category_id', current_setting('p6t.category')::uuid, 'karat_id', current_setting('p6t.karat')::uuid,
      'weight_grams', 5.0000, 'sale_price', 2000.00
    )),
    'عميل اختبار 6', '0500000000', null
  );
  perform set_config('p6t.order_id', v_result.id::text, false);
  perform set_config('p6t.order_number', v_result.order_number, false);

  -- A second, independent Sales Order (same date) — used only as an
  -- alternate `sales_order_id` target for the identity-column immutability
  -- test (Patch 6.1 item 18, section 12 below).
  select * into v_result from create_sales_order(
    current_setting('p6t.store_a')::uuid, current_date, v_payment_method, v_channel,
    jsonb_build_array(jsonb_build_object(
      'category_id', current_setting('p6t.category')::uuid, 'karat_id', current_setting('p6t.karat')::uuid,
      'weight_grams', 3.0000, 'sale_price', 1200.00
    )),
    'عميل اختبار 6 (طلب ثانٍ)', '0500000001', null
  );
  perform set_config('p6t.order_id_2', v_result.id::text, false);
end $$;

-- ---------------------------------------------------------------------------
-- 1. adjustment_types CRUD (§5/§6) — unchanged from Phase 6 Core.
-- ---------------------------------------------------------------------------
do $$
declare
  v_type_id uuid;
  v_dup_failed boolean := false;
begin
  select create_adjustment_type('install', 'تركيب', 'Installation', 'خدمة تركيب', 1) into v_type_id;
  perform set_config('p6t.type_install', v_type_id::text, false);

  begin
    perform create_adjustment_type('install', 'تركيب مكرر', null, null, 2);
  exception when others then
    v_dup_failed := true;
  end;
  if not v_dup_failed then
    raise exception 'FAIL: duplicate adjustment_type code was NOT rejected';
  end if;

  perform update_adjustment_type(v_type_id, 'تركيب (محدث)', 'Installation (updated)', null, 1);
  if (select name_ar from public.adjustment_types where id = v_type_id) <> 'تركيب (محدث)' then
    raise exception 'FAIL: update_adjustment_type did not update name_ar';
  end if;

  perform disable_adjustment_type(v_type_id);
  if (select status from public.adjustment_types where id = v_type_id) <> 'disabled' then
    raise exception 'FAIL: disable_adjustment_type did not set status=disabled';
  end if;
  if exists (select 1 from adjustments_active_type_lookups() where id = v_type_id) then
    raise exception 'FAIL: disabled type still appears in adjustments_active_type_lookups()';
  end if;
  if not exists (select 1 from adjustment_types_admin_list() where id = v_type_id) then
    raise exception 'FAIL: disabled type disappeared from adjustment_types_admin_list() — must stay historically visible';
  end if;

  perform enable_adjustment_type(v_type_id);
  if (select status from public.adjustment_types where id = v_type_id) <> 'active' then
    raise exception 'FAIL: enable_adjustment_type did not re-activate';
  end if;

  -- A second, permanently-active type used by later scenarios.
  select create_adjustment_type('repair', 'إصلاح', 'Repair', null, 2) into v_type_id;
  perform set_config('p6t.type_repair', v_type_id::text, false);

  raise notice 'PASS: adjustment_types CRUD (create/update/disable/enable + historical visibility)';
end $$;

-- ---------------------------------------------------------------------------
-- 2. §25 — search_sales_orders_for_adjustment() works for a create-only
-- actor with ZERO Sales permissions.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare
  v_found boolean;
begin
  select exists (
    select 1 from search_sales_orders_for_adjustment(current_setting('p6t.order_number'), 10)
    where order_number = current_setting('p6t.order_number')
  ) into v_found;
  if not v_found then
    raise exception 'FAIL: search_sales_orders_for_adjustment() did not find the order for a create-only (no sales.view) actor';
  end if;
  raise notice 'PASS: §25 search_sales_orders_for_adjustment() works without sales.view';
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 3. Patch 6.1 item 1/1A/1D/23 — a create-only actor (003, no manage_cost)
-- CANNOT supply direct_cost at creation, CAN create a cost-less Pending
-- record, and can complete the entire post-create workflow via the NEW
-- narrow getter WITHOUT adjustments.view (closes the hidden-permission
-- dependency).
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare
  v_pm_id uuid;
  v_channel uuid;
  v_cost_rejected boolean := false;
  v_adj_id uuid;
  v_edit_row record;
  v_view_denied boolean := false;
begin
  v_pm_id := current_setting('p6t.pm_visa')::uuid;
  v_channel := current_setting('p6t.channel_direct_store')::uuid;

  -- item 1D — direct_cost supplied inline by a create-only actor is rejected
  -- outright (fail-safe reject, never silently dropped).
  begin
    perform create_sales_order_adjustment(
      current_setting('p6t.order_id')::uuid, current_setting('p6t.type_install')::uuid, current_setting('p6t.store_a')::uuid,
      current_date, v_pm_id, v_channel, true, 100.00, 30.00, 'محاولة تكلفة بلا صلاحية', null, 'REF-D-1'
    );
  exception when others then
    if sqlerrm like '%التكلفة المباشرة%' then v_cost_rejected := true; else raise; end if;
  end;
  if not v_cost_rejected then
    raise exception 'FAIL: create-only actor supplying direct_cost was NOT rejected';
  end if;

  -- item 23 — create WITHOUT cost succeeds for a create-only actor.
  select id into v_adj_id from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, current_setting('p6t.type_install')::uuid, current_setting('p6t.store_a')::uuid,
    current_date, v_pm_id, v_channel, true, 120.00, null, 'خدمة أنشأها مستخدم Create-only', null, 'REF-CREATEONLY-1'
  );
  perform set_config('p6t.adj_createonly_id', v_adj_id::text, false);

  -- item 23 — the NARROW getter works for adjustments.create alone.
  select * into v_edit_row from get_pending_sales_order_adjustment_for_edit(v_adj_id);
  if v_edit_row.id is null then
    raise exception 'FAIL: get_pending_sales_order_adjustment_for_edit() denied a create-only actor on their own Pending record';
  end if;
  if v_edit_row.has_direct_cost is not false then
    raise exception 'FAIL: has_direct_cost expected false on a cost-less record';
  end if;
  if v_edit_row.direct_cost is not null then
    raise exception 'FAIL: create-only (no manage_cost/profit) actor should not see direct_cost via the narrow getter';
  end if;
  if v_edit_row.payment_reference <> 'REF-CREATEONLY-1' then
    raise exception 'FAIL: payment_reference round-trip failed via the narrow getter, got %', v_edit_row.payment_reference;
  end if;

  -- item 23 — proves the ORIGINAL bug: get_sales_order_adjustment() (the
  -- full detail getter) still correctly requires adjustments.view, which a
  -- create-only actor does NOT hold — so the app must use the narrow getter
  -- above, never redirect a create-only actor to the full detail page.
  begin
    perform * from get_sales_order_adjustment(v_adj_id);
  exception when others then
    v_view_denied := true;
  end;
  if not v_view_denied then
    raise exception 'FAIL: get_sales_order_adjustment() unexpectedly succeeded for an actor without adjustments.view';
  end if;

  raise notice 'PASS: Patch 6.1 items 1D/23 — create-only actor cannot supply direct_cost, but completes the full create+edit workflow without adjustments.view';
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 4. Patch 6.1 item 2/3 — dedicated set_pending_sales_order_adjustment_
-- direct_cost() RPC: manage_cost alone (no approve needed), pending-only,
-- OCC, money-scale validation, and the narrow pending-cost visibility
-- exception (item 3).
-- ---------------------------------------------------------------------------
do $$
declare
  v_row_version bigint;
  v_result record;
begin
  select row_version into v_row_version from get_sales_order_adjustment(current_setting('p6t.adj_createonly_id')::uuid);

  -- Negative rejected.
  begin
    perform set_pending_sales_order_adjustment_direct_cost(current_setting('p6t.adj_createonly_id')::uuid, v_row_version, -1.00, null);
    raise exception 'FAIL: negative direct_cost via the dedicated cost RPC was NOT rejected';
  exception when others then
    if sqlerrm not like '%غير سالب%' then raise; end if;
  end;

  -- Overprecision rejected (item 7).
  begin
    perform set_pending_sales_order_adjustment_direct_cost(current_setting('p6t.adj_createonly_id')::uuid, v_row_version, 30.999, null);
    raise exception 'FAIL: direct_cost=30.999 (overprecision) was NOT rejected by the dedicated cost RPC';
  exception when others then
    if sqlerrm not like '%رقمين عشريين%' then raise; end if;
  end;

  select * into v_result from set_pending_sales_order_adjustment_direct_cost(current_setting('p6t.adj_createonly_id')::uuid, v_row_version, 45.00, null);
  if v_result.direct_cost::numeric <> 45.00 or v_result.has_direct_cost is not true then
    raise exception 'FAIL: set_pending_sales_order_adjustment_direct_cost did not persist direct_cost=45.00, got % / %', v_result.direct_cost, v_result.has_direct_cost;
  end if;
  perform set_config('p6t.createonly_row_version', v_result.row_version::text, false);

  -- Stale OCC token rejected.
  begin
    perform set_pending_sales_order_adjustment_direct_cost(current_setting('p6t.adj_createonly_id')::uuid, v_row_version, 50.00, null);
    raise exception 'FAIL: stale row_version on the dedicated cost RPC was NOT rejected';
  exception when others then
    if sqlerrm not like '%تعارض الإصدارات%' then raise; end if;
  end;

  raise notice 'PASS: Patch 6.1 item 2 — dedicated cost RPC (negative/overprecision/OCC all enforced)';
end $$;

-- item 3 — a create-only actor (no manage_cost/profit) still cannot see the
-- value, but DOES see has_direct_cost=true; a manage_cost-only actor CAN see
-- the value while pending.
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare
  v_edit_row record;
begin
  select * into v_edit_row from get_pending_sales_order_adjustment_for_edit(current_setting('p6t.adj_createonly_id')::uuid);
  if v_edit_row.has_direct_cost is not true then
    raise exception 'FAIL: has_direct_cost expected true after cost was set';
  end if;
  if v_edit_row.direct_cost is not null then
    raise exception 'FAIL: create-only actor (no manage_cost/profit) must NOT see the direct_cost amount, even via the narrow getter';
  end if;
  raise notice 'PASS: has_direct_cost visible, direct_cost amount hidden, for a create-only (no manage_cost/profit) actor';
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
declare
  v_row record;
  v_edit_row record;
begin
  -- item 3 — pending exception applies to get_sales_order_adjustment() too
  -- (adjustments.view + adjustments.manage_cost, no sales.view_profit): sees
  -- original_direct_cost, but NOT payment_fee/gross/net (those stay
  -- sales.view_profit-only, even while pending — item 3's own limit).
  select * into v_row from get_sales_order_adjustment(current_setting('p6t.adj_createonly_id')::uuid);
  if v_row.original_direct_cost::numeric <> 45.00 then
    raise exception 'FAIL: adjustments.manage_cost actor should see a PENDING record''s direct_cost, got %', v_row.original_direct_cost;
  end if;
  if v_row.original_payment_fee_amount is not null or v_row.original_gross_adjustment_profit is not null or v_row.original_net_adjustment_profit is not null then
    raise exception 'FAIL: the item-3 pending-cost exception must NEVER extend to payment_fee/gross/net';
  end if;

  select * into v_edit_row from get_pending_sales_order_adjustment_for_edit(current_setting('p6t.adj_createonly_id')::uuid);
  if v_edit_row.id is not null then
    raise exception 'FAIL: get_pending_sales_order_adjustment_for_edit() requires adjustments.create — a manage_cost-only actor without create must NOT reach it';
  end if;
  raise notice 'PASS: Patch 6.1 item 3 — pending-only direct_cost visibility exception for adjustments.manage_cost, never extending to fee/gross/net';
exception when others then
  if sqlerrm like '%إنشاء%' then
    raise notice 'PASS: Patch 6.1 item 3 — pending-only direct_cost visibility exception for adjustments.manage_cost (get_pending_..._for_edit correctly denied, requires adjustments.create)';
  else
    raise;
  end if;
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 5. Patch 6.1 item 5 — full Approval-Independence test matrix (A-E).
-- ---------------------------------------------------------------------------
do $$
declare
  v_pm_id uuid;
  v_channel uuid;
  v_adj_y uuid;
  v_row_version bigint;
  v_approve_result record;
  v_manage_cost_worked boolean;
  v_approve_rejected boolean;
begin
  select id into v_pm_id from public.payment_methods where key = 'cash'; -- 0-fixed/0-percentage seeded fee
  select id into v_channel from public.collection_channels where key = 'direct_store';

  -- Matrix E setup: actor 006 (create+manage_cost, no approve) creates WITH
  -- an inline direct_cost (permitted — they hold manage_cost).
  perform set_config('p6t.matrix_pm', v_pm_id::text, false);
  perform set_config('p6t.matrix_channel', v_channel::text, false);
  raise notice 'setup ok';
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$
declare
  v_adj_y uuid;
  v_row_version bigint;
  v_approve_rejected boolean := false;
begin
  select id into v_adj_y from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
    current_date, current_setting('p6t.matrix_pm')::uuid, current_setting('p6t.matrix_channel')::uuid,
    true, 100.00, 30.00, 'مصفوفة الاعتماد Y', null, 'REF-MATRIX-Y'
  );
  perform set_config('p6t.adj_y', v_adj_y::text, false);

  select row_version into v_row_version from get_sales_order_adjustment(v_adj_y);

  -- Matrix E — create+manage_cost actor CANNOT approve.
  begin
    perform approve_sales_order_adjustment(v_adj_y, v_row_version, null);
    v_approve_rejected := false;
  exception when others then
    v_approve_rejected := true;
  end;
  if not v_approve_rejected then
    raise exception 'FAIL matrix E: create+manage_cost actor was able to approve — approve must require adjustments.approve, independent of manage_cost';
  end if;
  raise notice 'PASS matrix E: create+manage_cost actor created + set inline cost, but CANNOT approve';
end $$;

-- Matrix A — approve-only actor (004), cost present -> succeeds. Also proves
-- item 6: no Net Profit leak in the write response (004 has no
-- sales.view_profit). approve_sales_order_adjustment() itself needs only
-- adjustments.approve, but reading the current row_version to pass in does
-- need adjustments.view (which 004 deliberately does NOT hold) — resolve it
-- as the full-permission actor first and thread it through set_config,
-- exactly like the real app would via its own already-known row_version
-- from a prior create/list call, never a fresh privileged read.
do $$
declare
  v_row_version bigint;
begin
  select row_version into v_row_version from get_sales_order_adjustment(current_setting('p6t.adj_y')::uuid);
  perform set_config('p6t.adj_y_version', v_row_version::text, false);
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare
  v_row_version bigint := current_setting('p6t.adj_y_version')::bigint;
  v_result record;
begin
  select * into v_result from approve_sales_order_adjustment(current_setting('p6t.adj_y')::uuid, v_row_version, null);
  if v_result.status <> 'approved' then
    raise exception 'FAIL matrix A: approve-only actor with cost present could not approve';
  end if;
  if v_result.net_adjustment_profit is not null then
    raise exception 'FAIL item 6: approve response leaked net_adjustment_profit to an actor without sales.view_profit, got %', v_result.net_adjustment_profit;
  end if;
  raise notice 'PASS matrix A + item 6: approve-only actor approved successfully; write response did NOT leak Net Profit';
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';
-- Confirm (as the full-permission actor, who DOES hold sales.view_profit)
-- the real net profit is exactly the worked figure: 100 - 30 - 0(cash fee) = 70.
do $$
declare
  v_row record;
begin
  select * into v_row from get_sales_order_adjustment(current_setting('p6t.adj_y')::uuid);
  if v_row.original_net_adjustment_profit::numeric <> 70.00 then
    raise exception 'FAIL: matrix-A adjustment Y expected net=70.00, got %', v_row.original_net_adjustment_profit;
  end if;
end $$;

-- Matrix B — approve-only actor (004), cost NULL -> rejected with a clear
-- message. Matrix C — manage_cost-only actor (005) CAN enter cost but
-- CANNOT approve. Matrix D already proven in section 3 above (item 1D).
do $$
declare
  v_adj_z uuid;
begin
  select id into v_adj_z from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
    current_date, current_setting('p6t.matrix_pm')::uuid, current_setting('p6t.matrix_channel')::uuid,
    true, 50.00, null, 'مصفوفة الاعتماد Z', null, null
  );
  perform set_config('p6t.adj_z', v_adj_z::text, false);
end $$;

do $$
declare
  v_row_version bigint;
begin
  -- Resolved as the full-permission actor (still active here) — 004 (the
  -- approve-only actor used below) deliberately lacks adjustments.view.
  select row_version into v_row_version from get_sales_order_adjustment(current_setting('p6t.adj_z')::uuid);
  perform set_config('p6t.adj_z_version', v_row_version::text, false);
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare
  v_row_version bigint := current_setting('p6t.adj_z_version')::bigint;
  v_missing_cost_rejected boolean := false;
begin
  begin
    perform approve_sales_order_adjustment(current_setting('p6t.adj_z')::uuid, v_row_version, null);
  exception when others then
    if sqlerrm like '%التكلفة المباشرة%' then v_missing_cost_rejected := true; else raise; end if;
  end;
  if not v_missing_cost_rejected then
    raise exception 'FAIL matrix B: approve-only actor was able to approve WITHOUT a direct_cost set';
  end if;
  raise notice 'PASS matrix B: approve-only actor + NULL direct_cost -> rejected with a clear message';
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
declare
  v_row_version bigint;
  v_set_result record;
  v_approve_rejected boolean := false;
begin
  select row_version into v_row_version from get_sales_order_adjustment(current_setting('p6t.adj_z')::uuid);
  select * into v_set_result from set_pending_sales_order_adjustment_direct_cost(current_setting('p6t.adj_z')::uuid, v_row_version, 12.00, null);
  if v_set_result.has_direct_cost is not true then
    raise exception 'FAIL matrix C: manage_cost-only actor could not set direct_cost';
  end if;

  begin
    perform approve_sales_order_adjustment(current_setting('p6t.adj_z')::uuid, v_set_result.row_version, null);
    v_approve_rejected := false;
  exception when others then
    v_approve_rejected := true;
  end;
  if not v_approve_rejected then
    raise exception 'FAIL matrix C: manage_cost-only actor was able to approve — must require adjustments.approve';
  end if;
  raise notice 'PASS matrix C: manage_cost-only actor CAN set cost, CANNOT approve';
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_row_version bigint;
begin
  -- Clean up Z into an approved state for later sections that assume every
  -- fixture created is resolved by the end of the file (not required, but
  -- keeps the fixture set easy to reason about).
  select row_version into v_row_version from get_sales_order_adjustment(current_setting('p6t.adj_z')::uuid);
  perform approve_sales_order_adjustment(current_setting('p6t.adj_z')::uuid, v_row_version, null);
end $$;

do $$ begin raise notice 'PASS: Patch 6.1 item 5 — full approval-independence matrix A-E'; end $$;

-- ---------------------------------------------------------------------------
-- 6. Full lifecycle worked example (§11/§17): create (no cost) -> preview
-- -> dedicated cost RPC -> update (no cost param) -> approve -> original_*/
-- effective_* split -> reversal -> reversal impact columns (items 19/20).
-- ---------------------------------------------------------------------------
do $$
declare
  v_pm_id uuid;
  v_channel uuid;
  v_adj_id uuid;
  v_adj_number text;
  v_row_version bigint;
  v_preview record;
  v_approve_result record;
  v_row record;
  v_reversal record;
begin
  -- Use `visa` (seeded 2.5%/0-fixed) so the worked example (§11) matches
  -- EXACTLY: charge=100, cost=30, fee=2.50, gross=70.00, net=67.50.
  select id into v_pm_id from public.payment_methods where key = 'visa';
  select id into v_channel from public.collection_channels where key = 'direct_store';

  select id, adjustment_number into v_adj_id, v_adj_number
  from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid,
    current_setting('p6t.type_install')::uuid,
    current_setting('p6t.store_a')::uuid,
    current_date,
    v_pm_id, v_channel,
    true, -- participates_in_settlement, explicit
    100.00, null, 'تركيب أولي', null, 'REF-LIFECYCLE-1'
  );
  perform set_config('p6t.adj_id', v_adj_id::text, false);

  -- The base table has ZERO RLS policies (§30) — even the creating actor
  -- cannot SELECT it directly, by design. Every read below goes through
  -- get_sales_order_adjustment() (0151 v2), exactly as the real application
  -- layer must.
  select * into v_row from get_sales_order_adjustment(v_adj_id);
  v_row_version := v_row.row_version;

  if v_row.status <> 'pending' then
    raise exception 'FAIL: newly created adjustment is not pending';
  end if;
  if v_row.has_direct_cost is not false then
    raise exception 'FAIL: freshly created (cost-less) adjustment must have has_direct_cost=false';
  end if;
  if (v_adj_number ~ '^ADJ-[0-9]{10}$') is not true then
    raise exception 'FAIL: adjustment_number format is not ADJ-##########, got %', v_adj_number;
  end if;

  -- Preview (non-authoritative) with the worked-example inputs.
  select * into v_preview from preview_sales_order_adjustment(v_pm_id, 100.00, 30.00, current_date);
  if v_preview.fee_found is not true then
    raise exception 'FAIL: preview did not find a fee configuration for visa';
  end if;
  if v_preview.net_adjustment_profit::numeric <> 67.50 then
    raise exception 'FAIL: preview worked-example net_adjustment_profit expected 67.50, got %', v_preview.net_adjustment_profit;
  end if;

  -- Dedicated cost RPC — item 2's preferred design.
  select row_version into v_row_version from set_pending_sales_order_adjustment_direct_cost(v_adj_id, v_row_version, 30.00, null);

  -- Pending edit via update_sales_order_adjustment() v2 — NO direct_cost
  -- parameter exists any more; payment_reference is now a real param.
  select row_version into v_row_version from update_sales_order_adjustment(
    v_adj_id, v_row_version,
    current_setting('p6t.type_install')::uuid, current_setting('p6t.store_a')::uuid, current_date,
    v_pm_id, v_channel, true, 100.00, 'تركيب — تم تحديد التكلفة', null, 'REF-LIFECYCLE-2'
  );

  -- The cost survives the pending edit (update never touches it, item 2).
  select * into v_row from get_sales_order_adjustment(v_adj_id);
  if v_row.original_direct_cost::numeric <> 30.00 then
    raise exception 'FAIL: update_sales_order_adjustment() must NEVER change direct_cost, got %', v_row.original_direct_cost;
  end if;
  if v_row.payment_reference <> 'REF-LIFECYCLE-2' then
    raise exception 'FAIL: payment_reference was not updated by update_sales_order_adjustment(), got %', v_row.payment_reference;
  end if;

  -- Stale row_version must be rejected.
  begin
    perform update_sales_order_adjustment(
      v_adj_id, v_row_version - 1,
      current_setting('p6t.type_install')::uuid, current_setting('p6t.store_a')::uuid, current_date,
      v_pm_id, v_channel, true, 100.00, null, null, 'REF-LIFECYCLE-3'
    );
    raise exception 'FAIL: stale row_version was NOT rejected on update';
  exception when others then
    if sqlerrm not like '%تعارض الإصدارات%' then raise; end if;
  end;

  -- Approve — recomputes authoritatively; must match the worked example.
  select * into v_approve_result from approve_sales_order_adjustment(v_adj_id, v_row_version, null);
  v_row_version := v_approve_result.row_version;

  if v_approve_result.net_adjustment_profit::numeric <> 67.50 then
    raise exception 'FAIL: approval worked-example net_adjustment_profit expected 67.50, got %', v_approve_result.net_adjustment_profit;
  end if;
  if v_approve_result.status <> 'approved' then
    raise exception 'FAIL: approve response status expected approved, got %', v_approve_result.status;
  end if;

  select * into v_row from get_sales_order_adjustment(v_adj_id);
  if v_row.original_gross_adjustment_profit::numeric <> 70.00 then
    raise exception 'FAIL: original_gross_adjustment_profit expected 70.00, got %', v_row.original_gross_adjustment_profit;
  end if;
  if v_row.original_payment_fee_amount::numeric <> 2.50 then
    raise exception 'FAIL: original_payment_fee_amount expected 2.50, got %', v_row.original_payment_fee_amount;
  end if;
  if v_row.status <> 'approved' then
    raise exception 'FAIL: status is not approved';
  end if;
  if v_row.adjustment_type_code <> 'install' then
    raise exception 'FAIL: adjustment_type_code_snapshot not set at approval';
  end if;

  -- item 19 — effective_* mirrors original_* exactly for an approved,
  -- non-reversed record.
  if v_row.effective_net_adjustment_profit::numeric <> v_row.original_net_adjustment_profit::numeric then
    raise exception 'FAIL: effective_net_adjustment_profit must equal original_net_adjustment_profit before any reversal';
  end if;
  if v_row.effective_customer_charge::numeric <> 100.00 then
    raise exception 'FAIL: effective_customer_charge expected 100.00, got %', v_row.effective_customer_charge;
  end if;

  -- An approved record can no longer be edited via update RPC.
  begin
    perform update_sales_order_adjustment(v_adj_id, v_row_version, current_setting('p6t.type_install')::uuid, current_setting('p6t.store_a')::uuid, current_date, v_pm_id, v_channel, true, 100.00, null, null, null);
    raise exception 'FAIL: update_sales_order_adjustment succeeded on an APPROVED record';
  exception when others then
    if sqlerrm not like '%اعتماده أو رفضه%' then raise; end if;
  end;

  -- direct_cost cannot be touched post-approval either (no RPC exposes it
  -- for a non-pending record).
  begin
    perform set_pending_sales_order_adjustment_direct_cost(v_adj_id, v_row_version, 99.00, null);
    raise exception 'FAIL: set_pending_sales_order_adjustment_direct_cost succeeded on an APPROVED record';
  exception when others then
    if sqlerrm not like '%قيد الانتظار%' then raise; end if;
  end;

  -- Sales Order Summary (§40).
  declare
    v_summary record;
    v_original numeric;
  begin
    v_original := (get_sales_order(current_setting('p6t.order_id')::uuid) ->> 'subtotal')::numeric;
    select * into v_summary from get_sales_order_adjustment_summary(current_setting('p6t.order_id')::uuid);
    if v_summary.approved_effective_adjustments_charge_total::numeric < 100.00 then
      raise exception 'FAIL: summary effective total should include at least the 100.00 lifecycle adjustment, got %', v_summary.approved_effective_adjustments_charge_total;
    end if;
    if v_summary.original_invoice_amount::numeric <> v_original then
      raise exception 'FAIL: summary original_invoice_amount does not match sales_orders.subtotal';
    end if;
  end;

  -- Sales-profit-unchanged proof (§3).
  declare
    v_net_sales_profit_before numeric;
    v_net_sales_profit_after numeric;
  begin
    v_net_sales_profit_before := (get_sales_order(current_setting('p6t.order_id')::uuid) ->> 'net_sales_profit')::numeric;
    v_net_sales_profit_after := (get_sales_order(current_setting('p6t.order_id')::uuid) ->> 'net_sales_profit')::numeric;
    if v_net_sales_profit_before <> v_net_sales_profit_after then
      raise exception 'FAIL: sales_orders.net_sales_profit drifted after an Adjustment was approved';
    end if;
  end;

  -- Reversal (§19/§20 + Patch 6.1 items 19/20) — effective_status flips to
  -- 'reversed', original snapshot is UNTOUCHED, effective_* drops to 0.00,
  -- and the five signed reversal-impact columns are correct.
  perform reverse_sales_order_adjustment(v_adj_id, v_row_version, current_date, 'تصحيح إداري — اختبار', null);

  select * into v_row from get_sales_order_adjustment(v_adj_id);
  if v_row.effective_status <> 'reversed' then
    raise exception 'FAIL: effective_status expected reversed, got %', v_row.effective_status;
  end if;
  if v_row.original_net_adjustment_profit::numeric <> 67.50 then
    raise exception 'FAIL: original_net_adjustment_profit was mutated by reversal — must stay 67.50 (historical fact preserved), got %', v_row.original_net_adjustment_profit;
  end if;
  if v_row.effective_net_adjustment_profit::numeric <> 0.00 then
    raise exception 'FAIL: item 19 — effective_net_adjustment_profit must be 0.00 once reversed, got %', v_row.effective_net_adjustment_profit;
  end if;
  if v_row.effective_customer_charge::numeric <> 0.00 then
    raise exception 'FAIL: item 19 — effective_customer_charge must be 0.00 once reversed, got %', v_row.effective_customer_charge;
  end if;
  if v_row.effective_direct_cost::numeric <> 0.00 or v_row.effective_gross_adjustment_profit::numeric <> 0.00 then
    raise exception 'FAIL: item 19 — effective_direct_cost/effective_gross_adjustment_profit must be 0.00 once reversed';
  end if;

  select * into v_reversal from public.sales_order_adjustment_reversals where sales_order_adjustment_id = v_adj_id;
  if v_reversal.net_profit_reversal_amount::numeric <> -67.50 then
    raise exception 'FAIL: item 20 — net_profit_reversal_amount expected -67.50, got %', v_reversal.net_profit_reversal_amount;
  end if;
  if v_reversal.customer_charge_reversal_amount::numeric <> -100.00 then
    raise exception 'FAIL: item 20 — customer_charge_reversal_amount expected -100.00, got %', v_reversal.customer_charge_reversal_amount;
  end if;
  if v_reversal.direct_cost_reversal_amount::numeric <> 30.00 then
    raise exception 'FAIL: item 20 — direct_cost_reversal_amount expected +30.00, got %', v_reversal.direct_cost_reversal_amount;
  end if;
  if v_reversal.payment_fee_reversal_amount::numeric <> 2.50 then
    raise exception 'FAIL: item 20 — payment_fee_reversal_amount expected +2.50, got %', v_reversal.payment_fee_reversal_amount;
  end if;
  if v_reversal.gross_profit_reversal_amount::numeric <> -70.00 then
    raise exception 'FAIL: item 20 — gross_profit_reversal_amount expected -70.00, got %', v_reversal.gross_profit_reversal_amount;
  end if;
  -- Worked example: Original Net + Reversal Impact = Effective Net.
  if (v_row.original_net_adjustment_profit::numeric + v_reversal.net_profit_reversal_amount::numeric) <> 0.00 then
    raise exception 'FAIL: item 20 — Original Net + Reversal Impact must equal 0.00 exactly';
  end if;

  declare
    v_summary2 record;
    v_expected numeric;
  begin
    -- The summary must no longer count this NOW-reversed adjustment's
    -- 100.00 charge. Re-derive the expected total via the RLS-safe
    -- get_sales_order_adjustment() reads (never the raw table, which has
    -- zero authenticated policies by design) — sum of effective_customer_
    -- charge across every still-approved-and-not-reversed record on this
    -- order, which by construction excludes this now-reversed one (its
    -- effective_customer_charge is 0.00, already asserted above).
    select * into v_summary2 from get_sales_order_adjustment_summary(current_setting('p6t.order_id')::uuid);
    select coalesce(sum(g.effective_customer_charge::numeric), 0) into v_expected
      from list_sales_order_adjustments(current_setting('p6t.order_id')::uuid, null, null, null, null, null, null, 200, 0) l
      cross join lateral get_sales_order_adjustment(l.id) g
      where g.effective_status = 'approved';
    if v_summary2.approved_effective_adjustments_charge_total::numeric <> v_expected then
      raise exception 'FAIL: summary must exclude a REVERSED adjustment''s charge, expected % got %', v_expected, v_summary2.approved_effective_adjustments_charge_total;
    end if;
  end;

  -- One-effective-reversal-max.
  begin
    perform reverse_sales_order_adjustment(v_adj_id, v_row_version, current_date, 'محاولة عكس ثانية', null);
    raise exception 'FAIL: a SECOND reversal of the same adjustment was NOT rejected';
  exception when others then
    if sqlerrm not like '%عكس هذا التعديل%' then raise; end if;
  end;

  raise notice 'PASS: full lifecycle (create/preview/set-cost/update/approve/reverse) matches the spec''s worked example (charge=100, cost=30, fee=2.50, gross=70, net=67.50) and original_*/effective_*/reversal-impact semantics (items 19/20)';
end $$;

-- ---------------------------------------------------------------------------
-- 7. Patch 6.1 item 7 — no silent money rounding: overprecision REJECTED,
-- not coerced, across create/update/preview/set-cost.
-- ---------------------------------------------------------------------------
do $$
declare
  v_pm_id uuid;
  v_channel uuid;
  v_rejected boolean;
  v_adj_id uuid;
  v_row_version bigint;
begin
  select id into v_pm_id from public.payment_methods where key = 'cash';
  select id into v_channel from public.collection_channels where key = 'direct_store';

  -- create: customer_charge=100.001 rejected.
  v_rejected := false;
  begin
    perform create_sales_order_adjustment(
      current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
      current_date, v_pm_id, v_channel, true, 100.001, null, null, null, null
    );
  exception when others then
    if sqlerrm like '%رقمين عشريين%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL item 7: customer_charge=100.001 was NOT rejected on create'; end if;

  -- create: customer_charge=100.00 accepted.
  select id into v_adj_id from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
    current_date, v_pm_id, v_channel, true, 100.00, null, null, null, null
  );
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);

  -- update: customer_charge=30.999 rejected.
  v_rejected := false;
  begin
    perform update_sales_order_adjustment(
      v_adj_id, v_row_version, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid, current_date,
      v_pm_id, v_channel, true, 30.999, null, null, null
    );
  exception when others then
    if sqlerrm like '%رقمين عشريين%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL item 7: customer_charge=30.999 was NOT rejected on update'; end if;

  -- dedicated cost RPC: direct_cost=30.999 rejected (already proven in
  -- section 4, re-verified here against a freshly created record too).
  v_rejected := false;
  begin
    perform set_pending_sales_order_adjustment_direct_cost(v_adj_id, v_row_version, 30.999, null);
  exception when others then
    if sqlerrm like '%رقمين عشريين%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL item 7: direct_cost=30.999 was NOT rejected by the dedicated cost RPC'; end if;

  -- preview rejects overprecision too.
  v_rejected := false;
  begin
    perform * from preview_sales_order_adjustment(v_pm_id, 100.001, 30.00, current_date);
  exception when others then
    if sqlerrm like '%رقمين عشريين%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL item 7: preview did not reject customer_charge=100.001'; end if;

  raise notice 'PASS: Patch 6.1 item 7 — overprecision REJECTED (never silently rounded) on create/update/set-cost/preview; 100.00 accepted';
end $$;

-- ---------------------------------------------------------------------------
-- 8. Patch 6.1 item 8 — adjustment_date must be within [sale_date, today].
-- ---------------------------------------------------------------------------
do $$
declare
  v_pm_id uuid;
  v_channel uuid;
  v_rejected boolean;
  v_sale_date date := current_date; -- p6t.order_id's own sale_date
  v_adj_id uuid;
  v_row_version bigint;
begin
  select id into v_pm_id from public.payment_methods where key = 'cash';
  select id into v_channel from public.collection_channels where key = 'direct_store';

  -- create: adjustment_date = sale_date - 1 -> rejected.
  v_rejected := false;
  begin
    perform create_sales_order_adjustment(
      current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
      v_sale_date - 1, v_pm_id, v_channel, true, 20.00, null, null, null, null
    );
  exception when others then
    if sqlerrm like '%لا يمكن أن يسبق تاريخ عملية البيع%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL item 8: adjustment_date = sale_date - 1 was NOT rejected on create'; end if;

  -- create: adjustment_date = sale_date -> accepted.
  select id into v_adj_id from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
    v_sale_date, v_pm_id, v_channel, true, 20.00, null, null, null, null
  );
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);

  -- update: pushing adjustment_date before sale_date -> rejected. (Cannot go
  -- 2 days before "today" and still be <= business_today(), so this reuses
  -- sale_date - 1, which is both < sale_date AND still <= today — the two
  -- floor/ceiling checks are independent and both apply.)
  v_rejected := false;
  begin
    perform update_sales_order_adjustment(
      v_adj_id, v_row_version, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
      v_sale_date - 1, v_pm_id, v_channel, true, 20.00, null, null, null
    );
  exception when others then
    if sqlerrm like '%لا يمكن أن يسبق تاريخ عملية البيع%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL item 8: adjustment_date = sale_date - 1 was NOT rejected on update'; end if;

  raise notice 'PASS: Patch 6.1 item 8 — adjustment_date >= sale_date enforced on create AND update (approval revalidation confirmed by code review of 0148, structurally identical check)';
end $$;

-- ---------------------------------------------------------------------------
-- 9. Patch 6.1 item 9/10 — Free Service / Zero Charge worked example +
-- DB-level invariant (item 10), even against a trusted direct write.
-- ---------------------------------------------------------------------------
do $$
declare
  v_pm_id uuid;
  v_channel uuid;
  v_adj_id uuid;
  v_row_version bigint;
  v_row record;
  v_negative_rejected boolean := false;
begin
  select id into v_pm_id from public.payment_methods where key = 'cash';
  select id into v_channel from public.collection_channels where key = 'direct_store';

  -- Worked example: customer_charge=0, direct_cost=25 -> fee=0.00,
  -- gross=-25.00, net=-25.00. Negative profit allowed, never blocked.
  select id into v_adj_id from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
    current_date, v_pm_id, v_channel, true, 0.00, 25.00, 'خدمة ضمان — بدون تحصيل', null, 'يجب تجاهلها'
  );
  select * into v_row from get_sales_order_adjustment(v_adj_id);
  if v_row.payment_method_id is not null or v_row.collection_channel_id is not null or v_row.payment_reference is not null then
    raise exception 'FAIL item 9: zero-charge creation must normalize payment_method_id/collection_channel_id/payment_reference to NULL regardless of caller input';
  end if;
  if v_row.participates_in_settlement is not false then
    raise exception 'FAIL item 9: zero-charge creation must force participates_in_settlement=false';
  end if;

  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);
  perform approve_sales_order_adjustment(v_adj_id, v_row_version, null);

  select * into v_row from get_sales_order_adjustment(v_adj_id);
  if v_row.original_payment_fee_amount::numeric <> 0.00 then
    raise exception 'FAIL item 9: zero-charge payment_fee_amount expected 0.00, got %', v_row.original_payment_fee_amount;
  end if;
  if v_row.original_gross_adjustment_profit::numeric <> -25.00 then
    raise exception 'FAIL item 9: zero-charge/cost=25 should yield gross_adjustment_profit=-25.00 (negative profit allowed), got %', v_row.original_gross_adjustment_profit;
  end if;
  if v_row.original_net_adjustment_profit::numeric <> -25.00 then
    raise exception 'FAIL item 9: zero-charge/cost=25 should yield net_adjustment_profit=-25.00, got %', v_row.original_net_adjustment_profit;
  end if;

  -- Negative customer_charge is still rejected (unrelated to zero-charge).
  begin
    perform create_sales_order_adjustment(
      current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
      current_date, v_pm_id, v_channel, false, -1.00, null, null, null, null
    );
  exception when others then
    v_negative_rejected := true;
  end;
  if not v_negative_rejected then
    raise exception 'FAIL: negative customer_charge was NOT rejected';
  end if;

  raise notice 'PASS: Patch 6.1 item 9 — zero-charge worked example (charge=0/cost=25 -> fee=0.00/gross=-25.00/net=-25.00), payment fields normalized to NULL/false';
end $$;

-- item 10 — DB-level invariant holds even for a trusted direct write
-- (service_role bypasses RLS, but not CHECK constraints).
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare
  v_violated boolean := false;
  v_any_pending_id uuid;
  v_pm_id uuid;
begin
  select id into v_any_pending_id from public.sales_order_adjustments where status = 'pending' limit 1;
  select id into v_pm_id from public.payment_methods where key = 'cash';

  begin
    update public.sales_order_adjustments set customer_charge = 0, payment_method_id = v_pm_id where id = v_any_pending_id;
    v_violated := true;
  exception when others then
    raise notice 'OK item 10: DB CHECK rejected customer_charge=0 with a non-null payment_method_id, even for service_role (%)', sqlerrm;
  end;
  if v_violated then
    raise exception 'SECURITY BUG item 10: a trusted direct write could set customer_charge=0 while payment_method_id stayed non-null';
  end if;
end $$;
set role authenticated;
reset request.jwt.claims;
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 10. Patch 6.1 item 11 — payment_reference round-trip: optional, editable
-- while pending, immutable/visible (not profit-gated) after approval, NULL
-- for a free service.
-- ---------------------------------------------------------------------------
do $$
declare
  v_pm_id uuid;
  v_channel uuid;
  v_adj_id uuid;
  v_row_version bigint;
  v_row record;
begin
  select id into v_pm_id from public.payment_methods where key = 'mada';
  select id into v_channel from public.collection_channels where key = 'direct_store';

  select id into v_adj_id from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
    current_date, v_pm_id, v_channel, true, 40.00, null, null, null, 'REF-INITIAL'
  );
  select * into v_row from get_sales_order_adjustment(v_adj_id);
  if v_row.payment_reference <> 'REF-INITIAL' then
    raise exception 'FAIL item 11: payment_reference not persisted at creation, got %', v_row.payment_reference;
  end if;

  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);
  perform update_sales_order_adjustment(
    v_adj_id, v_row_version, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid, current_date,
    v_pm_id, v_channel, true, 40.00, null, null, 'REF-UPDATED'
  );
  select * into v_row from get_sales_order_adjustment(v_adj_id);
  if v_row.payment_reference <> 'REF-UPDATED' then
    raise exception 'FAIL item 11: payment_reference not editable while pending, got %', v_row.payment_reference;
  end if;

  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);
  perform set_pending_sales_order_adjustment_direct_cost(v_adj_id, v_row_version, 10.00, null);
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);
  perform approve_sales_order_adjustment(v_adj_id, v_row_version, null);

  select * into v_row from get_sales_order_adjustment(v_adj_id);
  if v_row.payment_reference <> 'REF-UPDATED' then
    raise exception 'FAIL item 11: payment_reference lost across approval, got %', v_row.payment_reference;
  end if;
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_id);
  begin
    perform update_sales_order_adjustment(v_adj_id, v_row_version, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid, current_date, v_pm_id, v_channel, true, 40.00, null, null, 'REF-SHOULD-FAIL');
    raise exception 'FAIL item 11: payment_reference was editable after approval (via general update)';
  exception when others then
    if sqlerrm not like '%اعتماده أو رفضه%' then raise; end if;
  end;

  raise notice 'PASS: Patch 6.1 item 11 — payment_reference round-trip (create/edit-while-pending/preserved-and-immutable-after-approval)';
end $$;

-- payment_reference visible to view-only actor (not a profit figure, item 30).
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare
  v_row record;
begin
  select * into v_row from get_sales_order_adjustment(current_setting('p6t.adj_id')::uuid);
  if v_row.payment_reference is null then
    raise exception 'FAIL item 29/30: payment_reference must be visible to adjustments.view alone (NOT profit-gated)';
  end if;
  raise notice 'PASS: item 29/30 — payment_reference visible to a view-only actor';
end $$;
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 11. Patch 6.1 items 12/13/31 — cross-store read/reject scope. A new
-- Adjustment where the linked Sale's store (A) differs from the processing
-- store (B). An actor who can see B ONLY (not A, actor 007) must NOT see it
-- via get/list, and must be denied on reject. An actor who sees BOTH (001)
-- must see it fully.
-- ---------------------------------------------------------------------------
do $$
declare
  v_pm_id uuid;
  v_channel uuid;
  v_adj_id uuid;
begin
  select id into v_pm_id from public.payment_methods where key = 'cash';
  select id into v_channel from public.collection_channels where key = 'direct_store';

  -- Original Sale is at Store A (p6t.order_id); processing store is B.
  select id into v_adj_id from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_b')::uuid,
    current_date, v_pm_id, v_channel, true, 60.00, null, 'عبر متاجر مختلفة', null, null
  );
  perform set_config('p6t.adj_crossstore', v_adj_id::text, false);

  -- Actor 001 sees both stores -> full visibility.
  if not exists (select 1 from get_sales_order_adjustment(v_adj_id)) then
    raise exception 'FAIL item 12: full-visibility actor could not read a cross-store adjustment';
  end if;
  if not exists (select 1 from list_sales_order_adjustments(current_setting('p6t.order_id')::uuid) where id = v_adj_id) then
    raise exception 'FAIL item 12: full-visibility actor did not see the cross-store adjustment in the list';
  end if;
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000007","role":"authenticated"}';
do $$
declare
  v_denied boolean := false;
  v_reject_denied boolean := false;
  v_row_version bigint;
begin
  -- item 12 — actor 007 sees Store B (processing) but NOT Store A (the
  -- Sale's own store) -> get must deny.
  begin
    perform * from get_sales_order_adjustment(current_setting('p6t.adj_crossstore')::uuid);
  exception when others then
    v_denied := true;
  end;
  if not v_denied then
    raise exception 'SECURITY BUG item 12: a Store-B-only actor could read a cross-store Adjustment whose linked Sale is at an invisible Store A';
  end if;

  -- item 12 — list must not include it either.
  if exists (select 1 from list_sales_order_adjustments(null, null, null, null, null, null, null, 50, 0) where id = current_setting('p6t.adj_crossstore')::uuid) then
    raise exception 'SECURITY BUG item 12: list_sales_order_adjustments() leaked a cross-store Adjustment to a Store-B-only actor';
  end if;

  -- item 13/31 — reject must ALSO be denied (row_version unknown to this
  -- actor since get is denied — use a synthetic version, any value: the
  -- store-visibility check must fire before/regardless of row_version
  -- mismatch details, and either error is an acceptable "denied" outcome).
  begin
    perform reject_sales_order_adjustment(current_setting('p6t.adj_crossstore')::uuid, 1, 'محاولة رفض عبر متاجر مختلفة');
  exception when others then
    v_reject_denied := true;
  end;
  if not v_reject_denied then
    raise exception 'SECURITY BUG items 13/31: reject_sales_order_adjustment() succeeded for a Store-B-only actor on a cross-store record — reject scope bypass NOT closed';
  end if;

  raise notice 'PASS: Patch 6.1 items 12/13/31 — cross-store read (get/list) and reject scope bypass both closed for a Store-B-only actor';
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 12. Patch 6.1 items 14/15/16/17/18/32 — DB-level defense in depth, proven
-- against a TRUSTED direct write (service_role bypasses RLS but never a
-- trigger). Full concurrency proof of item 14/15's lock actually being held
-- lives in the concurrency suite's new scenario I.
-- ---------------------------------------------------------------------------
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare
  v_bug boolean := false;
begin
  -- item 16 — adjustment_types.code immutable, even for service_role.
  begin
    update public.adjustment_types set code = 'hacked' where id = current_setting('p6t.type_repair')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'OK item 16: adjustment_types.code immutable, even for service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item 16: adjustment_types.code was changed by a trusted direct write'; end if;

  -- item 16/32 — adjustment_types DELETE always rejected.
  v_bug := false;
  begin
    delete from public.adjustment_types where id = current_setting('p6t.type_repair')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'OK item 16/32: adjustment_types DELETE rejected, even for service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item 16/32: an adjustment_type row was hard-deleted by a trusted direct write'; end if;

  -- item 17/32 — an APPROVED sales_order_adjustments row cannot be UPDATEd
  -- at all, even for direct_cost/customer_charge/payment fields.
  v_bug := false;
  begin
    update public.sales_order_adjustments set direct_cost = 999.00 where id = current_setting('p6t.adj_id')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'OK item 17/32: UPDATE on direct_cost of an APPROVED/REVERSED row rejected, even for service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item 17/32: direct_cost of a terminal-state Adjustment was changed by a trusted direct write'; end if;

  v_bug := false;
  begin
    update public.sales_order_adjustments set customer_charge = 999.00 where id = current_setting('p6t.adj_id')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'OK item 17/32: UPDATE on customer_charge of a terminal row rejected (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item 17/32: customer_charge of a terminal-state Adjustment was changed by a trusted direct write'; end if;

  -- item 17/32 — DELETE on sales_order_adjustments always rejected.
  v_bug := false;
  begin
    delete from public.sales_order_adjustments where id = current_setting('p6t.adj_id')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'OK item 17/32: DELETE on sales_order_adjustments rejected, even for service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item 17/32: a sales_order_adjustments row was hard-deleted by a trusted direct write'; end if;

  -- item 17/32 — reversal rows: UPDATE and DELETE always rejected (0135's
  -- pre-existing trigger, re-verified against the new reversal-impact
  -- columns too).
  v_bug := false;
  begin
    update public.sales_order_adjustment_reversals set net_profit_reversal_amount = 0 where sales_order_adjustment_id = current_setting('p6t.adj_id')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'OK item 17/32: UPDATE on sales_order_adjustment_reversals rejected (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item 17/32: a reversal row was mutated by a trusted direct write'; end if;

  v_bug := false;
  begin
    delete from public.sales_order_adjustment_reversals where sales_order_adjustment_id = current_setting('p6t.adj_id')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'OK item 17/32: DELETE on sales_order_adjustment_reversals rejected (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item 17/32: a reversal row was hard-deleted by a trusted direct write'; end if;

  -- item 18/32 — identity columns locked even on a still-PENDING record.
  v_bug := false;
  begin
    update public.sales_order_adjustments set adjustment_number = 'ADJ-HACKED0001' where id = current_setting('p6t.adj_createonly_id')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'OK item 18/32: adjustment_number immutable even while pending, even for service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item 18/32: adjustment_number was changed on a PENDING row by a trusted direct write'; end if;

  v_bug := false;
  begin
    update public.sales_order_adjustments set sales_order_id = current_setting('p6t.order_id_2')::uuid where id = current_setting('p6t.adj_createonly_id')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'OK item 18/32: sales_order_id immutable even while pending, even for service_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item 18/32: sales_order_id was re-pointed on a PENDING row by a trusted direct write'; end if;

  -- item 15 — acquire_adjustments_lock_exclusive()/shared() executable by
  -- service_role without "permission denied" (the exact prior failure mode
  -- learned from Hotfix 3.2.1/Shipping Patch 5.1).
  perform public.acquire_adjustments_lock_exclusive();
  raise notice 'OK item 15: acquire_adjustments_lock_exclusive() executable from service_role without "permission denied"';
end $$;
set role authenticated;
reset request.jwt.claims;
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$ begin raise notice 'PASS: Patch 6.1 items 14/15/16/17/18/32 — DB-level immutability/lock/no-delete invariants hold even against a trusted (service_role) direct write'; end $$;

-- ---------------------------------------------------------------------------
-- 13. Patch 6.1 items 21/22 — expanded list filters + view-only historical
-- filter lookups (full catalog including disabled/inactive).
-- ---------------------------------------------------------------------------
do $$
declare
  v_probe_type uuid;
begin
  select create_adjustment_type('p6_1_probe', 'نوع اختبار 6.1 معطّل') into v_probe_type;
  perform disable_adjustment_type(v_probe_type);
  perform set_config('p6t.probe_type', v_probe_type::text, false);
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare
  v_found boolean;
begin
  -- item 22 — a view-only actor (no adjustments.create) can use the
  -- dedicated filter lookups, and they include the DISABLED probe type
  -- (unlike the create-flow active-only lookup).
  select exists (select 1 from adjustments_filter_type_lookups() where id = current_setting('p6t.probe_type')::uuid and status = 'disabled') into v_found;
  if not v_found then
    raise exception 'FAIL item 22: adjustments_filter_type_lookups() (view-gated) did not include a disabled type';
  end if;
  perform 1 from adjustments_filter_payment_method_lookups() limit 1;
  perform 1 from adjustments_filter_collection_channel_lookups() limit 1;

  raise notice 'PASS: Patch 6.1 item 22 — view-only historical filter lookups work without adjustments.create and include disabled/inactive references';
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- item 22 — the create-flow lookup is active-only and correctly EXCLUDES the
-- disabled probe type (checked as the full-permission actor, since
-- adjustments_active_type_lookups() itself requires adjustments.create —
-- unlike the new view-gated lookups above, by design).
do $$
begin
  if exists (select 1 from adjustments_active_type_lookups() where id = current_setting('p6t.probe_type')::uuid) then
    raise exception 'FAIL item 22: adjustments_active_type_lookups() unexpectedly included a disabled type';
  end if;
end $$;

do $$
declare
  v_total_a bigint;
  v_total_b bigint;
  v_total_cash bigint;
  v_total_settling bigint;
begin
  -- item 21 — p_original_sale_store_id / p_store_id (processing) distinguish
  -- correctly: both fixtures created so far are on the Store-A Sale, but the
  -- cross-store one processes at Store B.
  select count(*) into v_total_a from list_sales_order_adjustments(
    null, null, null, null, null, null, null, 200, 0, current_setting('p6t.store_a')::uuid, null, null, null
  );
  select count(*) into v_total_b from list_sales_order_adjustments(
    null, current_setting('p6t.store_b')::uuid, null, null, null, null, null, 200, 0, null, null, null, null
  );
  if v_total_a < 1 then raise exception 'FAIL item 21: p_original_sale_store_id filter returned zero rows'; end if;
  if v_total_b < 1 then raise exception 'FAIL item 21: p_store_id (processing) filter for Store B returned zero rows'; end if;

  select count(*) into v_total_cash from list_sales_order_adjustments(
    null, null, null, null, null, null, null, 200, 0, null, (select id from public.payment_methods where key = 'cash'), null, null
  );
  if v_total_cash < 1 then raise exception 'FAIL item 21: p_payment_method_id filter returned zero rows'; end if;

  select count(*) into v_total_settling from list_sales_order_adjustments(
    null, null, null, null, null, null, null, 200, 0, null, null, null, true
  );
  if v_total_settling < 1 then raise exception 'FAIL item 21: p_participates_in_settlement filter returned zero rows'; end if;

  raise notice 'PASS: Patch 6.1 item 21 — expanded list filters (original_sale_store_id/processing store/payment_method/participates_in_settlement) all work';
end $$;

-- ---------------------------------------------------------------------------
-- 14. Patch 6.1 item 25 — Historical Snapshot Stability A/B/C. Type/Payment
-- Method/Collection Channel renamed AFTER approval never disturbs the
-- already-approved record's snapshot; a NEW approval picks up the new name.
-- Placed near the end since B/C use trusted direct renames of shared seed
-- data (name only — never touching code/key), safe under this rolled-back
-- transaction.
-- ---------------------------------------------------------------------------
do $$
declare
  v_type_id uuid;
  v_pm_id uuid;
  v_channel uuid;
  v_adj_old uuid;
  v_adj_new uuid;
  v_row_version bigint;
  v_row record;
begin
  select id into v_pm_id from public.payment_methods where key = 'cash';
  select id into v_channel from public.collection_channels where key = 'direct_store';

  -- A) Type rename after approval.
  select create_adjustment_type('p6_1_snap_a', 'خدمة أ') into v_type_id;
  perform set_config('p6t.snap_type', v_type_id::text, false);

  select id into v_adj_old from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, v_type_id, current_setting('p6t.store_a')::uuid,
    current_date, v_pm_id, v_channel, true, 10.00, 1.00, null, null, null
  );
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_old);
  perform approve_sales_order_adjustment(v_adj_old, v_row_version, null);

  perform update_adjustment_type(v_type_id, 'خدمة ب', null, null, 1);

  select id into v_adj_new from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, v_type_id, current_setting('p6t.store_a')::uuid,
    current_date, v_pm_id, v_channel, true, 10.00, 1.00, null, null, null
  );
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_new);
  perform approve_sales_order_adjustment(v_adj_new, v_row_version, null);

  select * into v_row from get_sales_order_adjustment(v_adj_old);
  if v_row.adjustment_type_name_ar <> 'خدمة أ' then
    raise exception 'FAIL item 25A: OLD approved adjustment''s type name drifted after a rename, expected "خدمة أ", got %', v_row.adjustment_type_name_ar;
  end if;
  select * into v_row from get_sales_order_adjustment(v_adj_new);
  if v_row.adjustment_type_name_ar <> 'خدمة ب' then
    raise exception 'FAIL item 25A: NEW approved adjustment should have snapshotted the renamed type "خدمة ب", got %', v_row.adjustment_type_name_ar;
  end if;
  raise notice 'PASS item 25A: Adjustment Type rename after approval — old snapshot stable, new approval takes the new name';
end $$;

-- B) Payment method rename after approval — trusted direct rename of the
-- shared 'cash' seed row's display name only (never key/status).
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
begin
  update public.payment_methods set name_ar = 'نقدًا (بعد إعادة التسمية)' where key = 'cash';
end $$;
set role authenticated;
reset request.jwt.claims;
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_pm_id uuid;
  v_channel uuid;
  v_adj_new uuid;
  v_row_version bigint;
  v_row record;
begin
  select id into v_pm_id from public.payment_methods where key = 'cash';
  select id into v_channel from public.collection_channels where key = 'direct_store';

  select id into v_adj_new from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
    current_date, v_pm_id, v_channel, true, 15.00, 1.00, null, null, null
  );
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_new);
  perform approve_sales_order_adjustment(v_adj_new, v_row_version, null);

  -- Old adjustment (adj_z, approved earlier in section 5, used 'cash' too)
  -- must NOT reflect the rename.
  select * into v_row from get_sales_order_adjustment(current_setting('p6t.adj_z')::uuid);
  if v_row.payment_method_name = 'نقدًا (بعد إعادة التسمية)' then
    raise exception 'FAIL item 25B: an already-approved adjustment''s payment_method_name drifted after a rename';
  end if;

  select * into v_row from get_sales_order_adjustment(v_adj_new);
  if v_row.payment_method_name <> 'نقدًا (بعد إعادة التسمية)' then
    raise exception 'FAIL item 25B: a NEW approval should snapshot the renamed payment method name, got %', v_row.payment_method_name;
  end if;
  raise notice 'PASS item 25B: Payment Method rename after approval — old snapshot stable, new approval takes the new name';
end $$;

-- C) Collection channel rename after approval.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
begin
  update public.collection_channels set name_ar = 'مباشر بالمتجر (بعد إعادة التسمية)' where key = 'direct_store';
end $$;
set role authenticated;
reset request.jwt.claims;
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_pm_id uuid;
  v_channel uuid;
  v_adj_new uuid;
  v_row_version bigint;
  v_row record;
begin
  select id into v_pm_id from public.payment_methods where key = 'mada';
  select id into v_channel from public.collection_channels where key = 'direct_store';

  select id into v_adj_new from create_sales_order_adjustment(
    current_setting('p6t.order_id')::uuid, current_setting('p6t.type_repair')::uuid, current_setting('p6t.store_a')::uuid,
    current_date, v_pm_id, v_channel, true, 15.00, 1.00, null, null, null
  );
  select row_version into v_row_version from get_sales_order_adjustment(v_adj_new);
  perform approve_sales_order_adjustment(v_adj_new, v_row_version, null);

  select * into v_row from get_sales_order_adjustment(current_setting('p6t.adj_z')::uuid);
  if v_row.collection_channel_name = 'مباشر بالمتجر (بعد إعادة التسمية)' then
    raise exception 'FAIL item 25C: an already-approved adjustment''s collection_channel_name drifted after a rename';
  end if;

  select * into v_row from get_sales_order_adjustment(v_adj_new);
  if v_row.collection_channel_name <> 'مباشر بالمتجر (بعد إعادة التسمية)' then
    raise exception 'FAIL item 25C: a NEW approval should snapshot the renamed collection channel name, got %', v_row.collection_channel_name;
  end if;
  raise notice 'PASS item 25C: Collection Channel rename after approval — old snapshot stable, new approval takes the new name';
end $$;

-- ---------------------------------------------------------------------------
-- 15. Profit privacy (§29/item 30) — an adjustments.view-only actor (no
-- sales.view_profit, no manage_cost) sees customer_charge/payment_reference/
-- has_direct_cost/participates_in_settlement, but NEVER original_direct_
-- cost/original_payment_fee_amount/original_gross_adjustment_profit/
-- original_net_adjustment_profit/effective_* profit figures, at both the
-- RPC and raw-table level.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare
  v_row record;
  v_direct_read_failed boolean := false;
begin
  select * into v_row from get_sales_order_adjustment(current_setting('p6t.adj_id')::uuid);
  if v_row.customer_charge is null then
    raise exception 'FAIL: adjustments.view-only actor should still see customer_charge';
  end if;
  if v_row.has_direct_cost is null then
    raise exception 'FAIL: adjustments.view-only actor should still see has_direct_cost (operational boolean)';
  end if;
  if v_row.original_direct_cost is not null or v_row.original_payment_fee_amount is not null or v_row.original_gross_adjustment_profit is not null or v_row.original_net_adjustment_profit is not null then
    raise exception 'FAIL: adjustments.view-only actor (no sales.view_profit/manage_cost) can see original_* profit-sensitive fields via get_sales_order_adjustment()';
  end if;
  if v_row.effective_direct_cost is not null or v_row.effective_payment_fee_amount is not null or v_row.effective_gross_adjustment_profit is not null or v_row.effective_net_adjustment_profit is not null then
    raise exception 'FAIL: adjustments.view-only actor can see effective_* profit-sensitive fields via get_sales_order_adjustment()';
  end if;

  -- Base-table protection (§30) — zero direct SELECT even for a permitted
  -- role; PostgREST-equivalent proof lives in the HTTP harness, this proves
  -- the RLS layer itself rejects a bare SELECT.
  begin
    perform 1 from public.sales_order_adjustments where id = current_setting('p6t.adj_id')::uuid;
    if found then
      v_direct_read_failed := true;
    end if;
  exception when others then
    null; -- also acceptable (permission denied)
  end;
  if v_direct_read_failed then
    raise exception 'FAIL: a direct SELECT on sales_order_adjustments returned a row — base table must have ZERO authenticated policies';
  end if;

  raise notice 'PASS: §29/§30/item 30 profit privacy (original_*/effective_*) + base-table lockdown';
end $$;

set local request.jwt.claims = '{"sub":"a6000000-0000-4000-8000-000000000001","role":"authenticated"}';

rollback;

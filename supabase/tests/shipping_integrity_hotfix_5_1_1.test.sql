-- ============================================================================
-- Integration test: Final Shipping Hotfix 5.1.1 (migrations 0131-0132)
-- ============================================================================
-- Run against a database that already has migrations 0001-latest applied
-- (see local_harness_setup.sql at the top of the repo's other *.test.sql
-- files for the exact recipe). Covers the DB-layer half of Hotfix 5.1.1's
-- spec:
--   item 6/7 — add_shipment_status_event()/record_shipment_cod_collection_
--   state() must reject a new event dated strictly before the LATEST
--   existing event of the SAME stream (status vs status, COD vs COD), not
--   just before shipments.shipment_date (0131).
--   item 5 — list_shipping_carrier_rate_versions_safe()/list_customer_
--   return_shipping_fee_versions_safe() must return base_cost/fee_amount as
--   TEXT, and stay gated on shipping_rates.view exactly like the tables'
--   own RLS SELECT policies (0132).
--
-- Items 1/2/3 (return-fee override reason wiring, stale-suggestion fix,
-- Preview/Create parity) are frontend-only fixes with no new SQL surface —
-- covered by tests/shipment-entry-form-return-fee.test.tsx and tests/
-- validation.test.ts (Vitest) instead. Item 4 (correct_status-only
-- permission) is a Server Action gate fix with no RPC/SQL change — the RPC
-- itself was already correct, so there is nothing new to assert here beyond
-- what shipping_core_phase5_concurrency.test.sql Section B/F already cover
-- for add_shipment_status_event() itself. Item 8 (list columns) and item 9
-- (HTTP coverage) are UI/script-level, not SQL. Item 10 (React/Vitest
-- tests) lives entirely under tests/.
--
-- Every migration below 0131 is UNMODIFIED by this hotfix — this file only
-- ADDS coverage.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/shipping_integrity_hotfix_5_1_1.test.sql
-- ============================================================================

begin;

insert into auth.users (id, email) values
  ('e5110000-0000-4000-8000-000000000001', 'test-h511-manager@example.invalid'),
  ('e5110000-0000-4000-8000-000000000002', 'test-h511-viewonly@example.invalid');

update public.profiles set full_name = 'Test H511 Manager', status = 'active', store_access_scope = 'all'
  where id = 'e5110000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test H511 View-Only', status = 'active', store_access_scope = 'all'
  where id = 'e5110000-0000-4000-8000-000000000002';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'e5110000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage', 'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit', 'manufacturing_fees.view', 'manufacturing_fees.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit', 'sales.close_day',
    'returns.view', 'returns.create', 'returns.approve', 'returns.reverse',
    'shipments.view', 'shipments.create', 'shipments.update_status', 'shipments.correct_status',
    'shipments.manage_cost', 'shipments.process_closed_day', 'shipping_rates.view', 'shipping_rates.manage',
    'audit_logs.view'
  );

-- View-only actor: shipments.view alone (item 10's operational-visibility
-- cases), and NOT shipping_rates.view (item 5's gating assertion needs a
-- real actor lacking it).
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'e5110000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('shipments.view');

-- The chronology assertions below (item 6/7) need real calendar-date room
-- between shipment_date and business_today() so a "strictly earlier than
-- the latest event" scenario actually exists (event dates can never be
-- future-dated, and a shipment can never predate its own sale). The seeded
-- VAT rate version (supabase/seed.sql) opens exactly at business_today()
-- with no historical predecessor, and create_vat_rate_version() itself
-- refuses to backdate a version before the currently-open one (by design —
-- you cannot rewrite VAT history). Widening the SAME already-open seeded
-- row's effective_from backward (superuser context, before `set role
-- authenticated` below — the same trusted-bootstrap context supabase/
-- seed.sql itself runs in) sidesteps that guard without creating a second
-- row or touching the RLS/RPC boundary under test anywhere in this file;
-- fully contained inside this transaction's rollback at the end.
update public.vat_rate_versions set effective_from = public.business_today() - 10 where effective_to is null and status = 'active';

-- ---------------------------------------------------------------------------
-- Fixtures — a dedicated Master Data set (H511*), independent from every
-- other Shipping test file's fixtures.
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"e5110000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_carrier_id uuid; v_zone_id uuid;
  v_order_id uuid;
  v_d0 date := public.business_today() - 5;
begin
  insert into public.stores (code, name_ar, status) values ('H511STA', 'متجر اختبار 5.1.1', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('H511K1', 'عيار اختبار 5.1.1', 991, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h511cat', 'تصنيف اختبار 5.1.1', 991, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('h511chan', 'قناة اختبار 5.1.1', 991, 'active') returning id into v_channel_id;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('h511pm', 'طريقة دفع اختبار 5.1.1', 'percentage', 'proportional_reversal', 991, 'active') returning id into v_pm_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (v_d0, v_karat_id, 300.0000, 'e5110000-0000-4000-8000-000000000001');
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'e5110000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, v_d0, 'h511 fixture');
  perform public.create_payment_method_fee_version(v_pm_id, 10, 0, v_d0, 'h511 fixture 10%');

  insert into public.shipping_carriers (code, name_ar, carrier_type, status) values ('H511CARR', 'شركة اختبار 5.1.1', 'external', 'active') returning id into v_carrier_id;
  insert into public.shipping_zones (code, name_ar, status) values ('H511ZONE', 'منطقة اختبار 5.1.1', 'active') returning id into v_zone_id;

  perform public.create_shipping_carrier_rate_version(v_carrier_id, v_zone_id, 'outbound', 22.00, v_d0, 'h511 outbound rate');

  -- A real sale, dated at v_d0, so a shipment can be created with
  -- shipment_date = v_d0 (must be >= sale_date, never in the future).
  select id into v_order_id from public.create_sales_order(
    v_store_id, v_d0, v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    'H511-ORDER'
  );

  perform set_config('h511.store_id', v_store_id::text, false);
  perform set_config('h511.carrier_id', v_carrier_id::text, false);
  perform set_config('h511.zone_id', v_zone_id::text, false);
  perform set_config('h511.order_id', v_order_id::text, false);
  perform set_config('h511.d0', v_d0::text, false);
end $$;

-- ============================================================================
-- Item 6/7 — add_shipment_status_event() chronology against the LATEST
-- existing status event, not just shipment_date.
-- ============================================================================
do $$
declare
  v_store_id uuid := current_setting('h511.store_id')::uuid;
  v_carrier_id uuid := current_setting('h511.carrier_id')::uuid;
  v_zone_id uuid := current_setting('h511.zone_id')::uuid;
  v_order_id uuid := current_setting('h511.order_id')::uuid;
  v_d0 date := current_setting('h511.d0')::date;
  v_shipment_id uuid;
  v_rv bigint;
  v_bug boolean := false;
begin
  select id into v_shipment_id from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := v_d0,
    p_direction := 'outbound', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 20.00
  );
  v_rv := (public.get_shipment(v_shipment_id)->>'row_version')::bigint;

  -- Latest status event so far: 'created' at v_d0. Advance it forward to
  -- v_d0+2 (still a NORMAL transition, no reason needed).
  select row_version into v_rv from public.add_shipment_status_event(
    v_shipment_id, 'ready_for_pickup', v_rv, v_d0 + 2
  );
  raise notice 'OK item6a: تقدُّم حالة طبيعي بتاريخ % نجح (يتقدَّم عن تاريخ آخر حدث)', v_d0 + 2;

  -- Now try to insert a FURTHER status event dated v_d0+1 -- >= shipment_
  -- date (v_d0) so the OLD (pre-0131) check would have let this through,
  -- but STRICTLY BEFORE the latest recorded event (v_d0+2) -- must now be
  -- rejected by the new item 6 check.
  begin
    perform public.add_shipment_status_event(v_shipment_id, 'picked_up', v_rv, v_d0 + 1);
    v_bug := true;
  exception when sqlstate 'P0001' then
    raise notice 'OK item6b: حدث حالة بتاريخ % (قبل آخر حدث مسجَّل بتاريخ %، لكن بعد تاريخ الشحنة %) رُفض بشكل صحيح (%)', v_d0 + 1, v_d0 + 2, v_d0, sqlerrm;
  end;
  if v_bug then
    raise exception 'BUG item6b: نجح تسجيل حدث حالة بتاريخ سابق لآخر حدث حالة مسجَّل — المشكلة الأصلية التي أصلحها Hotfix 5.1.1 لم تُصلَح';
  end if;

  -- The SAME date as the latest event must still be allowed (tolerance:
  -- reject strictly-earlier only, never same-day).
  select row_version into v_rv from public.add_shipment_status_event(
    v_shipment_id, 'picked_up', v_rv, v_d0 + 2
  );
  raise notice 'OK item6c: حدث حالة بنفس تاريخ آخر حدث مسجَّل (%) لا يزال مسموحًا به', v_d0 + 2;

  -- And a genuinely later date continues to work normally.
  select row_version into v_rv from public.add_shipment_status_event(
    v_shipment_id, 'in_transit', v_rv, v_d0 + 3
  );
  raise notice 'OK item6d: حدث حالة بتاريخ لاحق (%) نجح بشكل طبيعي', v_d0 + 3;

  perform set_config('h511.status_shipment_id', v_shipment_id::text, false);
end $$;

-- ============================================================================
-- Item 6/7 — record_shipment_cod_collection_state() chronology against the
-- LATEST existing COD event, mirroring the status-event fix exactly.
-- ============================================================================
do $$
declare
  v_store_id uuid := current_setting('h511.store_id')::uuid;
  v_carrier_id uuid := current_setting('h511.carrier_id')::uuid;
  v_zone_id uuid := current_setting('h511.zone_id')::uuid;
  v_order_id uuid := current_setting('h511.order_id')::uuid;
  v_d0 date := current_setting('h511.d0')::date;
  v_shipment_id uuid;
  v_rv bigint;
  v_bug boolean := false;
begin
  select id into v_shipment_id from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := v_d0,
    p_direction := 'outbound', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 20.00, p_is_cod := true, p_cod_expected_amount := 300.00
  );
  v_rv := (public.get_shipment(v_shipment_id)->>'row_version')::bigint;

  select row_version into v_rv from public.record_shipment_cod_collection_state(
    v_shipment_id, v_rv, 'expected', v_d0 + 2
  );
  raise notice 'OK item6e: حالة تحصيل COD بتاريخ % نجحت', v_d0 + 2;

  begin
    perform public.record_shipment_cod_collection_state(v_shipment_id, v_rv, 'collected', v_d0 + 1);
    v_bug := true;
  exception when sqlstate 'P0001' then
    raise notice 'OK item6f: حالة تحصيل COD بتاريخ % (قبل آخر حالة تحصيل مسجَّلة بتاريخ %، لكن بعد تاريخ الشحنة %) رُفضت بشكل صحيح (%)', v_d0 + 1, v_d0 + 2, v_d0, sqlerrm;
  end;
  if v_bug then
    raise exception 'BUG item6f: نجح تسجيل حالة تحصيل COD بتاريخ سابق لآخر حالة تحصيل مسجَّلة';
  end if;

  select row_version into v_rv from public.record_shipment_cod_collection_state(
    v_shipment_id, v_rv, 'collected', v_d0 + 2
  );
  raise notice 'OK item6g: حالة تحصيل COD بنفس تاريخ آخر حالة مسجَّلة (%) لا تزال مسموحة', v_d0 + 2;

  select row_version into v_rv from public.record_shipment_cod_collection_state(
    v_shipment_id, v_rv, 'not_collected', v_d0 + 3
  );
  raise notice 'OK item6h: حالة تحصيل COD بتاريخ لاحق (%) نجحت بشكل طبيعي', v_d0 + 3;
end $$;

-- ============================================================================
-- Item 5 — safe TEXT-returning list RPCs for shipping_carrier_rate_
-- versions.base_cost / customer_return_shipping_fee_versions.fee_amount
-- (migration 0132): correct value, correct wire type, correct gating.
-- ============================================================================
do $$
declare
  v_carrier_id uuid := current_setting('h511.carrier_id')::uuid;
  v_zone_id uuid := current_setting('h511.zone_id')::uuid;
  v_base_cost text;
  v_typeof text;
  v_bug boolean := false;
begin
  select base_cost, pg_typeof(base_cost)::text into v_base_cost, v_typeof
  from public.list_shipping_carrier_rate_versions_safe()
  where carrier_id = v_carrier_id and shipping_zone_id = v_zone_id and direction = 'outbound';

  assert v_base_cost = '22.00', format('item5a: base_cost يجب أن يكون ''22.00'' نصًّا، وُجد %s', v_base_cost);
  assert v_typeof = 'text', format('item5b: عمود base_cost المُعاد من list_shipping_carrier_rate_versions_safe() يجب أن يكون text وليس numeric خامًا، وُجد نوع %s', v_typeof);
  raise notice 'OK item5a/b: list_shipping_carrier_rate_versions_safe() تُعيد base_cost=% كنص (النوع الفعلي: %)', v_base_cost, v_typeof;

  -- Also create a customer return-shipping fee version to prove the second
  -- safe RPC the same way.
  perform public.create_customer_return_shipping_fee_version(v_zone_id, 33.50, current_setting('h511.d0')::date, 'h511 fee fixture');

  declare
    v_fee_amount text;
    v_fee_typeof text;
  begin
    select fee_amount, pg_typeof(fee_amount)::text into v_fee_amount, v_fee_typeof
    from public.list_customer_return_shipping_fee_versions_safe()
    where shipping_zone_id = v_zone_id;

    assert v_fee_amount = '33.50', format('item5c: fee_amount يجب أن يكون ''33.50'' نصًّا، وُجد %s', v_fee_amount);
    assert v_fee_typeof = 'text', format('item5d: عمود fee_amount المُعاد من list_customer_return_shipping_fee_versions_safe() يجب أن يكون text، وُجد نوع %s', v_fee_typeof);
    raise notice 'OK item5c/d: list_customer_return_shipping_fee_versions_safe() تُعيد fee_amount=% كنص (النوع الفعلي: %)', v_fee_amount, v_fee_typeof;
  end;

  -- Gating — a shipments.view-only actor (no shipping_rates.view) must be
  -- rejected by BOTH safe RPCs, same permission the tables' own RLS SELECT
  -- policies already require (0113/0122) -- this is a text-safe read path,
  -- never a widening of access.
  set local request.jwt.claims = '{"sub":"e5110000-0000-4000-8000-000000000002","role":"authenticated"}';

  begin
    perform 1 from public.list_shipping_carrier_rate_versions_safe() limit 1;
    v_bug := true;
  exception when sqlstate 'P0001' then
    raise notice 'OK item5e: list_shipping_carrier_rate_versions_safe() رُفضت لفاعل بلا shipping_rates.view (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item5e: list_shipping_carrier_rate_versions_safe() نجحت لفاعل بلا shipping_rates.view'; end if;

  v_bug := false;
  begin
    perform 1 from public.list_customer_return_shipping_fee_versions_safe() limit 1;
    v_bug := true;
  exception when sqlstate 'P0001' then
    raise notice 'OK item5f: list_customer_return_shipping_fee_versions_safe() رُفضت لفاعل بلا shipping_rates.view (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item5f: list_customer_return_shipping_fee_versions_safe() نجحت لفاعل بلا shipping_rates.view'; end if;

  set local request.jwt.claims = '{"sub":"e5110000-0000-4000-8000-000000000001","role":"authenticated"}';
end $$;

select 'ALL FINAL SHIPPING HOTFIX 5.1.1 TESTS PASSED (migrations 0131-0132, items 5/6/7)' as result;

rollback;

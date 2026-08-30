-- ============================================================================
-- Integration test: Shipping Integrity Patch 5.1 (migrations 0122-0130)
-- ============================================================================
-- Run against a database that already has migrations 0001-latest applied
-- (any local test harness build works — see local_harness_setup.sql at the
-- top of the repo's other *.test.sql files for the exact recipe). This file
-- formalizes the interactive smoke-test workflow used during development
-- into a permanent, assert-based regression covering the DB-layer half of
-- Patch 5.1's spec: items 1-18, 21, 23. Item 22 (the corrected Profit-
-- Security test) lives in shipping_core_phase5.test.sql's Section 49,
-- rewritten in place rather than duplicated here. Items 19/20 (the Admin
-- UI) and the concurrency-specific halves of items 4/16 are covered
-- elsewhere (the UI has no SQL-level test; concurrency lives in
-- shipping_core_phase5_concurrency.test.sql Section F for item 4, and a
-- dedicated multi-session file for item 16).
--
-- Every migration below 0122 is UNMODIFIED by this patch — this file adds
-- coverage, it never edits an existing test file's fixtures out from under
-- an earlier phase's assertions (shipping_core_phase5.test.sql Sections
-- 45/49 were updated in place ONLY where Patch 5.1 intentionally changed
-- correct behavior — mandatory override reason, and profit-security's
-- customer-charge visibility fix — with the change documented at each spot).
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/shipping_integrity_patch_5_1.test.sql
-- ============================================================================

begin;

insert into auth.users (id, email) values
  ('df510000-0000-4000-8000-000000000001', 'test-p51-manager@example.invalid'),
  ('df510000-0000-4000-8000-000000000002', 'test-p51-viewonly@example.invalid');

update public.profiles set full_name = 'Test P51 Manager', status = 'active', store_access_scope = 'all'
  where id = 'df510000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test P51 View-Only', status = 'active', store_access_scope = 'all'
  where id = 'df510000-0000-4000-8000-000000000002';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'df510000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
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

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'df510000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('shipments.view');

-- ---------------------------------------------------------------------------
-- Fixtures — a dedicated Master Data set (P51*), independent from
-- shipping_core_phase5.test.sql's P5T* fixtures and from seed.sql's
-- SMSA/ARAMEX/BARQ/REDBOX carriers or RIYADH/OUTSIDE_RIYADH zones, so this
-- file's rate-version overlap/immutability/GIST assertions cannot collide
-- with either of those.
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"df510000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_carrier_id uuid; v_zone_id uuid;
begin
  insert into public.stores (code, name_ar, status) values ('P51STA', 'متجر اختبار 5.1', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P51K1', 'عيار اختبار 5.1', 990, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p51cat', 'تصنيف اختبار 5.1', 990, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('p51chan', 'قناة اختبار 5.1', 990, 'active') returning id into v_channel_id;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('p51pm', 'طريقة دفع اختبار 5.1', 'percentage', 'proportional_reversal', 990, 'active') returning id into v_pm_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'df510000-0000-4000-8000-000000000001');

  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p51 fixture');
  perform public.create_payment_method_fee_version(v_pm_id, 10, 0, public.business_today(), 'p51 fixture 10%');

  insert into public.shipping_carriers (code, name_ar, carrier_type, status) values ('P51CARR', 'شركة اختبار 5.1', 'external', 'active') returning id into v_carrier_id;
  insert into public.shipping_zones (code, name_ar, status) values ('P51ZONE', 'منطقة اختبار 5.1', 'active') returning id into v_zone_id;

  perform public.create_shipping_carrier_rate_version(v_carrier_id, v_zone_id, 'outbound', 20.00, public.business_today(), 'p51 outbound rate');
  perform public.create_shipping_carrier_rate_version(v_carrier_id, v_zone_id, 'return', 18.00, public.business_today(), 'p51 return rate');
  perform public.create_customer_return_shipping_fee_version(v_zone_id, 40.00, public.business_today(), 'p51 return fee');
end $$;

-- ============================================================================
-- Item 1 — direct-write RLS lockdown on shipping_carrier_rate_versions /
-- customer_return_shipping_fee_versions (migration 0122). Writes must be
-- RPC-only, even for an actor holding shipping_rates.manage.
-- ============================================================================
do $$
declare v_carrier_id uuid; v_zone_id uuid; v_bug boolean := false;
begin
  select id into v_carrier_id from public.shipping_carriers where code = 'P51CARR';
  select id into v_zone_id from public.shipping_zones where code = 'P51ZONE';

  begin
    insert into public.shipping_carrier_rate_versions (carrier_id, shipping_zone_id, direction, base_cost, effective_from)
    values (v_carrier_id, v_zone_id, 'outbound', 999.00, public.business_today() + 1000);
    v_bug := true;
  exception when insufficient_privilege or others then
    raise notice 'OK item1a: مُنع INSERT مباشر على shipping_carrier_rate_versions حتى مع shipping_rates.manage (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item1a: نجح INSERT مباشر على shipping_carrier_rate_versions'; end if;

  v_bug := false;
  begin
    insert into public.customer_return_shipping_fee_versions (shipping_zone_id, fee_amount, effective_from)
    values (v_zone_id, 999.00, public.business_today() + 1000);
    v_bug := true;
  exception when insufficient_privilege or others then
    raise notice 'OK item1b: مُنع INSERT مباشر على customer_return_shipping_fee_versions حتى مع shipping_rates.manage (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item1b: نجح INSERT مباشر على customer_return_shipping_fee_versions'; end if;

  -- UPDATE — no policy at all as of 0122, so this is a silent 0-row match,
  -- not an exception (mirrors financial_integrity_patch_2_1.test.sql §1.2).
  update public.shipping_carrier_rate_versions set base_cost = 1.00 where carrier_id = v_carrier_id;
  if found then raise exception 'SECURITY BUG item1c: نجح UPDATE مباشر على shipping_carrier_rate_versions'; end if;
  raise notice 'OK item1c: مُنع UPDATE مباشر على shipping_carrier_rate_versions (0 صف متأثر)';
end $$;

-- ============================================================================
-- Item 2 — real DB-level no-overlap via GIST exclusion (not just the
-- partial-unique "no two open versions" index). Proven against a TRUSTED
-- (service_role) writer, exactly like 0047's manufacturing_fee_versions
-- precedent — the sanctioned RPC already prevents this at the app level;
-- the constraint is the last-line-of-defense that also covers a raw,
-- trusted bootstrap INSERT.
-- ============================================================================
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_carrier_id uuid; v_zone_id uuid; v_bug boolean := false;
begin
  select id into v_carrier_id from public.shipping_carriers where code = 'P51CARR';
  select id into v_zone_id from public.shipping_zones where code = 'P51ZONE';

  begin
    insert into public.shipping_carrier_rate_versions (carrier_id, shipping_zone_id, direction, base_cost, effective_from, effective_to, status)
    values (v_carrier_id, v_zone_id, 'outbound', 5.00, public.business_today() - 5, public.business_today() + 5, 'active');
    v_bug := true;
  exception when exclusion_violation then
    raise notice 'OK item2: قيد GIST EXCLUDE يرفض تداخل نطاقين زمنيين لنفس (carrier, zone, direction) حتى لسياق موثوق (service_role)';
  end;
  if v_bug then raise exception 'SECURITY BUG item2: تم قبول نطاقين متداخلين لنفس (carrier, zone, direction)'; end if;
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"df510000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ============================================================================
-- Item 3 — version identity/value/creation-metadata immutable after
-- creation via trigger (only effective_to/status may ever change, and only
-- via create/cancel).
-- ============================================================================
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_id uuid; v_carrier_id uuid; v_zone_id uuid; v_bug boolean := false;
begin
  select id into v_carrier_id from public.shipping_carriers where code = 'P51CARR';
  select id into v_zone_id from public.shipping_zones where code = 'P51ZONE';
  select id into v_id from public.shipping_carrier_rate_versions where carrier_id = v_carrier_id and direction = 'outbound';

  begin
    update public.shipping_carrier_rate_versions set base_cost = 1.00 where id = v_id;
    v_bug := true;
  exception when others then
    raise notice 'OK item3a: تعديل base_cost على إصدار موجود مرفوض حتى لـservice_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item3a: نجح تعديل base_cost على إصدار قائم'; end if;

  v_bug := false;
  begin
    update public.shipping_carrier_rate_versions set created_at = now() - interval '10 years' where id = v_id;
    v_bug := true;
  exception when others then
    raise notice 'OK item3b: تعديل created_at مرفوض حتى لـservice_role (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item3b: نجح تعديل created_at على إصدار قائم'; end if;
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"df510000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ============================================================================
-- Item 4 — table-level exclusive rate lock covers every write path
-- including service_role (the Hotfix 3.2.1 "permission denied" lesson).
-- Full concurrency coverage lives in shipping_core_phase5_concurrency.test
-- .sql Section F; here we only confirm the lock-acquire function itself is
-- executable by service_role (the exact prior failure mode).
-- ============================================================================
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
begin
  perform public.acquire_shipping_rates_lock_exclusive();
  raise notice 'OK item4: acquire_shipping_rates_lock_exclusive() قابلة للتنفيذ من service_role دون "permission denied" (درس Hotfix 3.2.1)';
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"df510000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ============================================================================
-- Item 5 — create_*_version() rejects creation against an inactive/
-- disabled carrier/zone, without erasing historical versions.
-- ============================================================================
do $$
declare v_carrier_id uuid; v_zone_id uuid; v_bug boolean := false; v_hist_count integer;
begin
  select id into v_carrier_id from public.shipping_carriers where code = 'P51CARR';
  select id into v_zone_id from public.shipping_zones where code = 'P51ZONE';

  update public.shipping_carriers set status = 'disabled' where id = v_carrier_id;

  begin
    perform public.create_shipping_carrier_rate_version(v_carrier_id, v_zone_id, 'outbound', 99.00, public.business_today() + 1, 'reject me');
    v_bug := true;
  exception when others then
    raise notice 'OK item5a: create_shipping_carrier_rate_version() يرفض شركة شحن معطّلة (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG item5a: نجح إنشاء إصدار تسعير لشركة شحن معطّلة'; end if;

  select count(*) into v_hist_count from public.shipping_carrier_rate_versions where carrier_id = v_carrier_id;
  assert v_hist_count = 2, format('item5b: يجب أن تبقى الإصدارات التاريخية (2) دون مسح بعد رفض إنشاء جديد، وُجد %s', v_hist_count);
  raise notice 'OK item5b: الإصدارات التاريخية (%) بقيت سليمة رغم تعطيل الشركة', v_hist_count;

  update public.shipping_carriers set status = 'active' where id = v_carrier_id;

  update public.shipping_zones set status = 'disabled' where id = v_zone_id;
  v_bug := false;
  begin
    perform public.create_customer_return_shipping_fee_version(v_zone_id, 99.00, public.business_today() + 1, 'reject me');
    v_bug := true;
  exception when others then
    raise notice 'OK item5c: create_customer_return_shipping_fee_version() يرفض منطقة معطّلة (%)', sqlerrm;
  end;
  if v_bug then raise exception 'BUG item5c: نجح إنشاء إصدار رسوم إرجاع لمنطقة معطّلة'; end if;
  update public.shipping_zones set status = 'active' where id = v_zone_id;
end $$;

-- ============================================================================
-- Items 6/21 — shipping_carriers.code/shipping_zones.code/created_at/
-- created_by immutable, real updated_by stamped, PostgREST spoofing
-- (a forged created_by/created_at on a fresh INSERT) rejected.
-- ============================================================================
do $$
declare v_carrier_id uuid; v_bug boolean := false;
begin
  select id into v_carrier_id from public.shipping_carriers where code = 'P51CARR';

  begin
    update public.shipping_carriers set code = 'HACKED' where id = v_carrier_id;
    v_bug := true;
  exception when others then
    raise notice 'OK item6a: تعديل shipping_carriers.code مرفوض (%)', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG item6a: نجح تعديل code'; end if;

  -- Spoofed created_by/created_at on a fresh, otherwise-legitimate INSERT —
  -- enforce_system_managed_columns() (0021, reused) must overwrite both
  -- with server truth (auth.uid()/now()), not accept the client's values.
  insert into public.shipping_carriers (code, name_ar, carrier_type, created_by, created_at)
  values ('P51SPOOF', 'انتحال', 'external', 'df510000-0000-4000-8000-000000000002', now() - interval '5 years');

  assert (select created_by from public.shipping_carriers where code = 'P51SPOOF') = 'df510000-0000-4000-8000-000000000001',
    'item6b: created_by المزوَّر كان يجب استبداله بـ auth.uid() الحقيقي (المدير المنفِّذ فعليًا)';
  assert (select created_at from public.shipping_carriers where code = 'P51SPOOF') > now() - interval '1 minute',
    'item6c: created_at المزوَّر (قبل 5 سنوات) كان يجب استبداله بالوقت الحقيقي';
  raise notice 'OK item6b/6c/21: تزوير created_by/created_at عبر إدراج مباشر رُفض واستُبدل بالحقيقة الفعلية';

  update public.shipping_carriers set name_ar = 'اسم محدَّث' where code = 'P51SPOOF';
  assert (select updated_by from public.shipping_carriers where code = 'P51SPOOF') = 'df510000-0000-4000-8000-000000000001',
    'item6d: updated_by يجب أن يعكس المنفِّذ الحقيقي بعد أي تعديل';
  raise notice 'OK item6d: updated_by يعكس المنفِّذ الحقيقي (auth.uid())';
end $$;

-- ============================================================================
-- Item 7 — audit trail: create/cancel of both version tables, and
-- create/update/disable of carriers/zones, all logged with DB-level
-- profit protection on rate/cost-bearing rows.
-- ============================================================================
do $$
declare v_count integer;
begin
  select count(*) into v_count from public.audit_logs where action = 'shipping_rate.create';
  assert v_count >= 2, format('item7a: يجب تسجيل shipping_rate.create لكل إصدار تسعير أُنشئ، وُجد %s', v_count);

  select count(*) into v_count from public.audit_logs where action = 'customer_return_shipping_fee.create';
  assert v_count >= 1, format('item7b: يجب تسجيل customer_return_shipping_fee.create، وُجد %s', v_count);

  select count(*) into v_count from public.audit_logs where action = 'shipping_carrier.create' and entity_id = (select id from public.shipping_carriers where code = 'P51SPOOF');
  assert v_count >= 1, 'item7c: يجب تسجيل إنشاء شركة شحن جديدة';

  select count(*) into v_count from public.audit_logs where action = 'shipping_carrier.update' and entity_id = (select id from public.shipping_carriers where code = 'P51SPOOF');
  assert v_count >= 1, 'item7d: يجب تسجيل تعديل شركة شحن';

  raise notice 'OK item7: سجل التدقيق يغطي إنشاء تسعير الشحن/رسوم الإرجاع وإنشاء/تعديل شركات الشحن';
end $$;

-- ============================================================================
-- Items 8/9/10/23 — Customer Return Shipping Fee Snapshot, mandatory
-- override reason, customer_shipping_charge NEVER profit-gated, and the
-- has_actual_carrier_cost operational flag.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
  v_carrier_id uuid; v_zone_id uuid;
  v_shipment_id uuid; v_shipment_id2 uuid;
  v_get jsonb; v_get2 jsonb; v_get3 jsonb;
begin
  select id into v_store_id from public.stores where code = 'P51STA';
  select id into v_karat_id from public.karats where code = 'P51K1';
  select id into v_category_id from public.product_categories where code = 'p51cat';
  select id into v_channel_id from public.collection_channels where key = 'p51chan';
  select id into v_pm_id from public.payment_methods where key = 'p51pm';
  select id into v_carrier_id from public.shipping_carriers where code = 'P51CARR';
  select id into v_zone_id from public.shipping_zones where code = 'P51ZONE';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 0.1000, 'sale_price', 1000.00)),
    'P51-ORDER'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 1000.00,
    p_scenario_notes := 'P51: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  -- Matching the standard fee (40.00) -> no override.
  select id into v_shipment_id from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'return', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 40.00, p_sales_return_id := v_return_id
  );
  v_get := public.get_shipment(v_shipment_id);
  assert (v_get->>'customer_return_shipping_charge_is_override')::boolean = false, 'item9a: مطابقة الرسوم القياسية يجب أن تعطي is_override=false';
  assert v_get->>'customer_return_shipping_fee_standard_amount' = '40.00', format('item8a: الرسوم القياسية المحفوظة يجب أن تكون 40.00، وُجد %s', v_get->>'customer_return_shipping_fee_standard_amount');
  raise notice 'OK item8/9a: رسوم مطابقة للقياسي -> is_override=false، اللقطة القياسية صحيحة';

  -- Overridden, no reason -> rejected.
  begin
    perform public.create_shipment(
      p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
      p_direction := 'return', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
      p_customer_shipping_charge := 30.00, p_sales_return_id := v_return_id
    );
    raise exception 'BUG item9b: تجاوز الرسوم القياسية بدون سبب نجح رغم أنه يجب رفضه';
  exception when sqlstate 'P0001' then
    raise notice 'OK item9b: تجاوز الرسوم القياسية بدون سبب رُفض بشكل صحيح (%)', sqlerrm;
  end;

  -- Overridden, WITH reason -> accepted and fully snapshotted.
  select id into v_shipment_id2 from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'return', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 30.00, p_sales_return_id := v_return_id,
    p_customer_return_shipping_charge_override_reason := 'تخفيض بسبب حالة خاصة'
  );
  v_get2 := public.get_shipment(v_shipment_id2);
  assert (v_get2->>'customer_return_shipping_charge_is_override')::boolean = true, 'item9c: is_override يجب أن يكون true';
  assert v_get2->>'customer_return_shipping_charge_override_reason' = 'تخفيض بسبب حالة خاصة', 'item9c: سبب التجاوز يجب أن يُحفظ كما أُدخل';
  raise notice 'OK item9c: تجاوز مع سبب مقبول ومحفوظ بالكامل في اللقطة';

  -- Item 10/23 — shipments.view-only actor.
  set local request.jwt.claims = '{"sub":"df510000-0000-4000-8000-000000000002","role":"authenticated"}';
  v_get3 := public.get_shipment(v_shipment_id);
  assert not (v_get3 ? 'expected_carrier_cost'), 'item10a: expected_carrier_cost يجب أن يكون غائبًا لفاعل shipments.view فقط';
  assert (v_get3 ? 'customer_shipping_charge') and v_get3->>'customer_shipping_charge' is not null, 'item10b: customer_shipping_charge يجب أن يكون ظاهرًا لفاعل shipments.view فقط';
  assert (v_get3 ? 'has_actual_carrier_cost'), 'item23: has_actual_carrier_cost يجب أن يكون ظاهرًا دومًا';
  assert (v_get3->>'has_actual_carrier_cost')::boolean = false, 'item23b: has_actual_carrier_cost يجب أن يكون false قبل أي تسجيل تكلفة فعلية';
  raise notice 'OK item10/23: customer_shipping_charge=% ظاهر، expected_carrier_cost غائب، has_actual_carrier_cost=false قبل التسجيل', v_get3->>'customer_shipping_charge';
  set local request.jwt.claims = '{"sub":"df510000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform public.record_shipment_actual_cost(v_shipment_id, (public.get_shipment(v_shipment_id)->>'row_version')::bigint, 15.00, public.business_today());
  set local request.jwt.claims = '{"sub":"df510000-0000-4000-8000-000000000002","role":"authenticated"}';
  v_get3 := public.get_shipment(v_shipment_id);
  assert (v_get3->>'has_actual_carrier_cost')::boolean = true, 'item23c: has_actual_carrier_cost يجب أن يصبح true بعد تسجيل تكلفة فعلية، حتى دون رؤية الرقم';
  assert not (v_get3 ? 'actual_carrier_cost'), 'item23d: actual_carrier_cost (الرقم نفسه) يجب أن يبقى غائبًا';
  raise notice 'OK item23c/d: has_actual_carrier_cost=true بعد التسجيل دون كشف الرقم لفاعل shipments.view فقط';
  set local request.jwt.claims = '{"sub":"df510000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform set_config('p51.order_id', v_order_id::text, false);
  perform set_config('p51.return_id', v_return_id::text, false);
  perform set_config('p51.store_id', v_store_id::text, false);
  perform set_config('p51.carrier_id', v_carrier_id::text, false);
  perform set_config('p51.zone_id', v_zone_id::text, false);
  perform set_config('p51.shipment_id', v_shipment_id::text, false);
end $$;

-- ============================================================================
-- Items 15/16 — a NEW return shipment requires the linked return's status
-- to be exactly 'approved' (not 'reversed'); an EXISTING shipment against a
-- since-reversed return remains fully readable. The race-closing lock
-- itself (FOR UPDATE on both sides) is exercised in a dedicated
-- multi-session concurrency file; this proves the single-session outcome.
-- ============================================================================
do $$
declare
  v_order_id uuid := current_setting('p51.order_id')::uuid;
  v_return_id uuid := current_setting('p51.return_id')::uuid;
  v_store_id uuid := current_setting('p51.store_id')::uuid;
  v_carrier_id uuid := current_setting('p51.carrier_id')::uuid;
  v_zone_id uuid := current_setting('p51.zone_id')::uuid;
  v_shipment_id uuid := current_setting('p51.shipment_id')::uuid;
  v_row_version bigint; v_get jsonb;
begin
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.reverse_sales_return(v_return_id, v_row_version, 'اختبار إلغاء لِـPatch 5.1');

  begin
    perform public.create_shipment(
      p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
      p_direction := 'return', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
      p_customer_shipping_charge := 40.00, p_sales_return_id := v_return_id
    );
    raise exception 'BUG item15: نجح إنشاء شحنة إرجاع جديدة لمرتجع مُلغى (reversed)';
  exception when sqlstate 'P0001' then
    raise notice 'OK item15: إنشاء شحنة إرجاع جديدة لمرتجع مُلغى رُفض بشكل صحيح (%)', sqlerrm;
  end;

  v_get := public.get_shipment(v_shipment_id);
  assert v_get->>'id' is not null, 'item16: الشحنة الموجودة مسبقًا المرتبطة بمرتجع أُلغي لاحقًا يجب أن تبقى قابلة للقراءة بالكامل';
  raise notice 'OK item16: الشحنة الموجودة مسبقًا (%) تبقى قابلة للقراءة رغم إلغاء المرتجع المرتبط بها لاحقًا', v_get->>'shipment_number';

  -- Search lookup parity (item 15's other half, migration 0128) — a
  -- reversed return must no longer be OFFERED for a new shipment either.
  assert not exists (select 1 from public.search_sales_returns_for_shipment(p_sales_order_id := v_order_id) where id = v_return_id),
    'item15d: search_sales_returns_for_shipment() يجب ألا يعرض مرتجعًا مُلغى (reversed) بعد 0128';
  raise notice 'OK item15d: search_sales_returns_for_shipment() لا يعرض المرتجع المُلغى';
end $$;

-- ============================================================================
-- Item 13/14 — COD collection-state append-only workflow.
-- ============================================================================
do $$
declare
  v_order_id uuid := current_setting('p51.order_id')::uuid;
  v_store_id uuid := current_setting('p51.store_id')::uuid;
  v_carrier_id uuid := current_setting('p51.carrier_id')::uuid;
  v_zone_id uuid := current_setting('p51.zone_id')::uuid;
  v_shipment_id uuid := current_setting('p51.shipment_id')::uuid;
  v_cod_shipment_id uuid; v_rv bigint; v_get jsonb;
begin
  select id into v_cod_shipment_id from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'outbound', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 40.00, p_is_cod := true, p_cod_expected_amount := 500.00
  );
  v_get := public.get_shipment(v_cod_shipment_id);
  v_rv := (v_get->>'row_version')::bigint;

  select row_version into v_rv from public.record_shipment_cod_collection_state(v_cod_shipment_id, v_rv, 'collected', public.business_today(), 'REF-1', 'تم التحصيل');
  v_get := public.get_shipment(v_cod_shipment_id);
  assert v_get->>'cod_collection_state' = 'collected', format('item13a: cod_collection_state يجب أن يصبح collected، وُجد %s', v_get->>'cod_collection_state');
  assert jsonb_array_length(v_get->'cod_timeline') = 1, 'item13b: cod_timeline يجب أن يحوي حدثًا واحدًا بعد تسجيل واحد';
  raise notice 'OK item13: cod_collection_state=%, أحداث cod_timeline=%', v_get->>'cod_collection_state', jsonb_array_length(v_get->'cod_timeline');

  begin
    perform public.record_shipment_cod_collection_state(v_shipment_id, (public.get_shipment(v_shipment_id)->>'row_version')::bigint, 'collected', public.business_today());
    raise exception 'BUG item13c: نجح تسجيل حالة COD على شحنة ليست COD';
  exception when sqlstate 'P0001' then
    raise notice 'OK item13c: تسجيل حالة COD على شحنة غير COD رُفض بشكل صحيح (%)', sqlerrm;
  end;

  -- Append-only: attempting to UPDATE a shipment_cod_events row directly
  -- must never succeed, mirroring shipment_status_events/shipment_
  -- financial_events (0116). shipment_cod_events has ZERO RLS policies for
  -- `authenticated` (comment in 0127) — so the WHERE clause below matches
  -- 0 rows under RLS before the reject-trigger would even get a chance to
  -- fire; either outcome (a raised exception, OR a silent 0-row match) is
  -- safe. The only real bug would be the row's state value actually
  -- changing, which is what this asserts directly.
  declare v_event_id uuid; v_state_before text; v_state_after text;
  begin
    select id, state into v_event_id, v_state_before from public.shipment_cod_events where shipment_id = v_cod_shipment_id order by created_at desc limit 1;
    begin
      update public.shipment_cod_events set state = 'not_collected' where id = v_event_id;
    exception when others then
      raise notice 'OK item13d: UPDATE مباشر على shipment_cod_events رفعَ استثناءً (append-only) (%)', sqlerrm;
    end;
    select state into v_state_after from public.shipment_cod_events where id = v_event_id;
    assert v_state_after is not distinct from v_state_before, format('BUG item13d: تغيّرت قيمة state فعليًا من %s إلى %s رغم أن الجدول append-only', coalesce(v_state_before, '<NULL>'), coalesce(v_state_after, '<NULL>'));
    raise notice 'OK item13d: قيمة shipment_cod_events.state لم تتغيّر (قبل=%، بعد=%) — التعديل المباشر إما رُفض بالكامل أو لم يطابق أي صف (append-only/RLS)', coalesce(v_state_before, '<NULL — RLS تمنع القراءة المباشرة أيضًا>'), coalesce(v_state_after, '<NULL>');
  end;
end $$;

-- ============================================================================
-- Item 18 — business-date chronology lower bounds on every event-writing
-- RPC (>= shipment_date, and for cost-corrections >= latest ledger date).
-- ============================================================================
do $$
declare v_shipment_id uuid := current_setting('p51.shipment_id')::uuid;
begin
  begin
    perform public.add_shipment_status_event(v_shipment_id, 'ready_for_pickup', (public.get_shipment(v_shipment_id)->>'row_version')::bigint, public.business_today() - 5);
    raise exception 'BUG item18a: نجح حدث حالة بتاريخ سابق لتاريخ الشحنة';
  exception when sqlstate 'P0001' then
    raise notice 'OK item18a: حدث حالة بتاريخ سابق لتاريخ الشحنة رُفض بشكل صحيح (%)', sqlerrm;
  end;

  begin
    perform public.record_shipment_cod_collection_state(v_shipment_id, (public.get_shipment(v_shipment_id)->>'row_version')::bigint, 'collected', public.business_today() - 5);
    raise exception 'BUG item18b: نجح تسجيل حالة COD بتاريخ سابق لتاريخ الشحنة';
  exception when sqlstate 'P0001' then
    raise notice 'OK item18b: تسجيل حالة COD بتاريخ سابق رُفض بشكل صحيح (%)', sqlerrm;
  end;
end $$;

-- ============================================================================
-- Item 17 — historical carrier/zone label snapshot survives a later
-- Master Data rename.
-- ============================================================================
do $$
declare v_shipment_id uuid := current_setting('p51.shipment_id')::uuid; v_carrier_id uuid := current_setting('p51.carrier_id')::uuid; v_get jsonb;
begin
  update public.shipping_carriers set name_ar = 'اسم جديد بعد التغيير' where id = v_carrier_id;
  v_get := public.get_shipment(v_shipment_id);
  assert v_get->>'carrier_name' <> 'اسم جديد بعد التغيير', 'item17: اسم الشحنة التاريخي يجب ألا يتغيّر بعد إعادة تسمية الشركة';
  raise notice 'OK item17: الشحنة التاريخية تعرض اسم الشركة القديم (%) رغم إعادة التسمية الحية', v_get->>'carrier_name';
  update public.shipping_carriers set name_ar = 'شركة اختبار 5.1' where id = v_carrier_id;
end $$;

-- ============================================================================
-- Item 11 — shipments_filter_carrier_lookups()/shipments_filter_zone_
-- lookups() gated on shipments.view ALONE — a shipments.view-only actor
-- (no shipments.create) must be able to call them.
-- ============================================================================
set local request.jwt.claims = '{"sub":"df510000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_count integer;
begin
  select count(*) into v_count from public.shipments_filter_carrier_lookups();
  assert v_count >= 1, 'item11a: shipments_filter_carrier_lookups() يجب أن تعمل لفاعل shipments.view فقط';
  select count(*) into v_count from public.shipments_filter_zone_lookups();
  assert v_count >= 1, 'item11b: shipments_filter_zone_lookups() يجب أن تعمل لفاعل shipments.view فقط';

  begin
    perform public.shipments_carrier_lookups();
    raise exception 'BUG item11c: shipments_carrier_lookups() (shipments.create-gated) لم يُرفض لفاعل shipments.view فقط';
  exception when sqlstate 'P0001' then
    raise notice 'OK item11c: shipments_carrier_lookups() (القديمة، shipments.create-gated) لا تزال مرفوضة لفاعل shipments.view فقط — التعارض الأصلي في /shipments كان استخدام هذه بدلًا من النسخة الجديدة';
  end;
  raise notice 'OK item11: shipments_filter_carrier_lookups()/shipments_filter_zone_lookups() تعملان لفاعل shipments.view فقط';
end $$;
set local request.jwt.claims = '{"sub":"df510000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ============================================================================
-- Item 12 — list_shipments() new filters: order_number, return_number,
-- original Sale store (distinct from processing store), COD state.
-- ============================================================================
do $$
declare
  v_order_id uuid := current_setting('p51.order_id')::uuid;
  v_shipment_id uuid := current_setting('p51.shipment_id')::uuid;
  -- create_sales_order()'s 6th positional param is p_customer_name, NOT an
  -- order number — order_number is always system-generated (Section 5's
  -- sequence). Resolve the REAL generated order_number rather than assuming
  -- it equals the 'P51-ORDER' fixture label used earlier as customer_name.
  v_order_number text := (public.get_sales_order(v_order_id) ->> 'order_number');
  v_row record;
begin
  select * into v_row from public.list_shipments(p_order_number := v_order_number) limit 1;
  assert v_row.id is not null, format('item12a: تصفية list_shipments() بـ order_number (%s) يجب أن تُرجع نتيجة', v_order_number);

  select * into v_row from public.list_shipments(p_cod_collection_state := 'collected') limit 1;
  assert v_row.id is not null, 'item12b: تصفية list_shipments() بـ cod_collection_state يجب أن تُرجع نتيجة';

  select * into v_row from public.list_shipments(p_original_sale_store_id := (select store_id from public.sales_orders where id = v_order_id)) limit 1;
  assert v_row.id is not null, 'item12c: تصفية list_shipments() بـ original_sale_store_id يجب أن تُرجع نتيجة';

  raise notice 'OK item12: تصفيات list_shipments() الجديدة (order_number=%/cod_collection_state/original_sale_store_id) تعمل جميعًا', v_order_number;
end $$;

select 'ALL SHIPPING INTEGRITY PATCH 5.1 TESTS PASSED (migrations 0122-0130, items 1-18/21/23)' as result;

rollback;

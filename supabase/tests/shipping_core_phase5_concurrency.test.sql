-- ============================================================================
-- Integration test: Phase 5 — Shipping Core, GENUINE multi-session
-- concurrency (mirrors sales_returns_concurrency.test.sql's own dblink
-- pattern exactly — same helper shapes, same "own prefix per file" and
-- "own store per race" discipline).
-- ============================================================================
-- NOT safe to run against a shared/staging database — real dblink sessions,
-- auto-committing statements, no wrapping transaction, explicit cleanup at
-- the end. Run ONLY against a throwaway/CI database.
--
-- Requires migrations 0001-latest (including 0113-0121) + supabase/seed.sql
-- already applied, and the `dblink` extension available. If the connecting
-- role needs a password over TCP, see this project's own established fix:
--   sudo -u postgres psql -c "alter user postgres password 'postgres';"
--
-- Connection string override, same convention as the other *_concurrency.
-- test.sql files:
--   psql -v dblink_conninfo="host=... port=... user=... password=..." \
--     -f supabase/tests/shipping_core_phase5_concurrency.test.sql
--
-- Covers the six named Concurrency Tests from the Phase 5 spec:
--   A — shipping-rates advisory lock (1005) vs create_shipment()'s rate
--       resolution: create_shipment() holds the SHARED lock open (session
--       A); a concurrent create_shipping_carrier_rate_version() (session B,
--       needs EXCLUSIVE) genuinely blocks for the full duration, then
--       succeeds cleanly once A commits — no torn write, exactly one new
--       rate version row.
--   B — concurrent add_shipment_status_event() optimistic-concurrency race:
--       two sessions race a status transition on the SAME shipment with the
--       SAME stale expected row_version. The shipment row FOR UPDATE lock
--       (0118, mirrors update_sales_order()'s 0075 fix) makes the second
--       session block for the first's full open transaction, then reject on
--       the now-stale row_version — never a silent Lost Update.
--   C — concurrent record_shipment_actual_cost() "double first-time-record"
--       race: two sessions race the FIRST actual-cost recording on the SAME
--       shipment with the SAME stale expected row_version. Proven caught by
--       the SAME row-lock-then-version-check mechanism as B (the version
--       check runs before the "already recorded" business check, so the
--       race is caught one layer earlier than the single-session unit test
--       already covered in shipping_core_phase5.test.sql's Section 46) —
--       exactly one actual_cost_recorded event ever exists.
--   D — Daily Close vs create_shipment() race: create_shipment() holds the
--       daily-close SHARED lock open for (store, shipment_date); a
--       concurrent close_sales_day() (EXCLUSIVE) genuinely blocks, then
--       proceeds only after the shipment's creating transaction commits —
--       reuses Sales/Returns' own daily_closings/lock mechanism exactly.
--   E — Daily Close vs record_shipment_actual_cost()/correct_shipment_
--       actual_cost() race: two sub-scenarios (E1 = record, E2 = correct),
--       each proving the SAME shared-vs-exclusive blocking behavior for a
--       shipment financial write gated against the COST's own business_date
--       (which may differ from shipment_date, Section 28).
--   F — Lock-order proof (reverse of A): create_shipping_carrier_rate_
--       version() (session A) holds the shipping-rates EXCLUSIVE lock open;
--       a concurrent create_shipment() (session B, needs SHARED to resolve
--       the rate) genuinely blocks, then — once A commits — resolves the
--       BRAND NEW rate version correctly (never a stale pre-lock read).
--       The real proof asked for by the spec: racing the two functions
--       against each other in either lock order (A vs F) never raises a
--       genuine Postgres deadlock (SQLSTATE 40P01) — structurally
--       impossible here since only create_shipment() ever acquires both
--       the daily-close AND shipping-rates locks, always in that same
--       fixed order (0117), and no other Shipping RPC acquires more than
--       one of the two.
--   G — Shipping Integrity Patch 5.1 item 16: reverse_sales_return() (session
--       A) vs create_shipment() (session B) racing the SAME sales_returns
--       row. reverse_sales_return() already locks its row FOR UPDATE
--       (0088/0096/0102); create_shipment()'s own return-lookup SELECT
--       gained the SAME FOR UPDATE as of migration 0125 specifically to
--       close this race. Session A holds its transaction open mid-reversal;
--       session B's concurrent create_shipment() attempt against the same
--       return must genuinely BLOCK (not read a stale 'approved' snapshot),
--       then — once A commits and the return is truly 'reversed' — B's
--       call must be REJECTED (never silently create a shipment against a
--       return that is, by the time B's own snapshot is taken, reversed).
-- ============================================================================

create extension if not exists dblink;

\if :{?dblink_conninfo}
\else
\set dblink_conninfo 'host=127.0.0.1 port=5432 user=postgres password=postgres'
\endif

select set_config('p5cc.dblink_conninfo', :'dblink_conninfo', false);

-- ---------------------------------------------------------------------------
-- Polling helpers — own name prefix so this file can coexist with the
-- other *_concurrency.test.sql files in the same database without
-- colliding. Dropped at the end.
-- ---------------------------------------------------------------------------
create or replace function public._p5cc_wait_busy(p_connname text, p_max_polls int default 30, p_interval numeric default 0.1)
returns boolean
language plpgsql
as $$
declare v_i int;
begin
  for v_i in 1..p_max_polls loop
    if dblink_is_busy(p_connname) = 1 then
      return true;
    end if;
    perform pg_sleep(p_interval);
  end loop;
  return dblink_is_busy(p_connname) = 1;
end;
$$;

create or replace function public._p5cc_wait_ready(p_connname text, p_max_polls int default 100, p_interval numeric default 0.1)
returns boolean
language plpgsql
as $$
declare v_i int;
begin
  for v_i in 1..p_max_polls loop
    if dblink_is_busy(p_connname) = 0 then
      return true;
    end if;
    perform pg_sleep(p_interval);
  end loop;
  return dblink_is_busy(p_connname) = 0;
end;
$$;

create or replace function public._p5cc_drain_pending(p_connname text)
returns void
language plpgsql
as $$
begin
  perform 1 from dblink_get_result(p_connname) as t(x text);
end;
$$;

-- ============================================================================
-- 0. Fixtures — own prefix 'e5.../P5CC', committed immediately (no wrapping
-- transaction) so both dblink sessions can see them right away. One actor
-- (full Shipping + Sales permissions) plays BOTH sides of every race, same
-- convention as sales_returns_concurrency.test.sql's R1/R2/R4-R7.
-- ============================================================================
insert into auth.users (id, email) values
  ('e5000000-0000-4000-8000-000000000001', 'test-p5cc-actor@example.invalid');

update public.profiles set full_name = 'P5CC actor', status = 'active', store_access_scope = 'all'
  where id = 'e5000000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'e5000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'collection_channels.view', 'collection_channels.manage', 'payment_methods.view', 'payment_methods.manage',
    'gold_prices.view', 'gold_prices.edit', 'manufacturing_fees.view', 'manufacturing_fees.manage',
    'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit', 'sales.close_day',
    'returns.view', 'returns.create', 'returns.approve', 'returns.reverse',
    'shipments.view', 'shipments.create', 'shipments.update_status', 'shipments.correct_status',
    'shipments.manage_cost', 'shipments.process_closed_day', 'shipping_rates.view', 'shipping_rates.manage'
  );

do $$
declare
  v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_carrier_smsa uuid; v_zone_riyadh uuid;
  v_store_codes text[] := array['P5CCSTA', 'P5CCSTB', 'P5CCSTC', 'P5CCSTD', 'P5CCSTE', 'P5CCSTE2', 'P5CCSTF', 'P5CCSTG'];
  v_store_names text[] := array['متجر تزامن شحن A', 'متجر تزامن شحن B', 'متجر تزامن شحن C', 'متجر تزامن شحن D', 'متجر تزامن شحن E', 'متجر تزامن شحن E2', 'متجر تزامن شحن F', 'متجر تزامن شحن G'];
  v_i int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}';

  for v_i in 1..array_length(v_store_codes, 1) loop
    insert into public.stores (code, name_ar, status) values (v_store_codes[v_i], v_store_names[v_i], 'active');
  end loop;

  insert into public.karats (code, name_ar, sort_order, status) values ('P5CCK1', 'عيار تزامن شحن', 993, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p5cccat', 'تصنيف تزامن شحن', 993, 'active') returning id into v_category_id;
  insert into public.collection_channels (key, name_ar, sort_order, status) values ('p5ccchan', 'قناة تزامن شحن', 993, 'active') returning id into v_channel_id;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, sort_order, status)
    values ('p5ccpm', 'دفع تزامن شحن', 'percentage', 'proportional_reversal', 993, 'active') returning id into v_pm_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'e5000000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p5cc fixture');
  perform public.create_payment_method_fee_version(v_pm_id, 10, 0, public.business_today(), 'p5cc fixture');

  -- Only RETURN-direction rates are seeded pre-Phase-5-test (migration
  -- 0114's own SMSA/ARAMEX=17 / BARQ/REDBOX=15 figures) — every race below
  -- uses OUTBOUND shipments, so a one-time OUTBOUND rate for SMSA/RIYADH is
  -- seeded here (own committed statement, not part of any race) as the
  -- baseline every "already-configured" race resolves against. Test F
  -- deliberately uses a DIFFERENT carrier (ARAMEX) with NO pre-existing
  -- outbound config at all, since Test F's own race is the very act of
  -- creating that carrier's first outbound version.
  select id into v_carrier_smsa from public.shipping_carriers where code = 'SMSA';
  select id into v_zone_riyadh from public.shipping_zones where code = 'RIYADH';
  perform public.create_shipping_carrier_rate_version(v_carrier_smsa, v_zone_riyadh, 'outbound', 20.00, public.business_today(), 'P5CC fixture: baseline outbound rate');
end $$;

-- ============================================================================
-- A — shipping-rates advisory lock (1005) vs create_shipment()
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P5CCSTA';
  select id into v_karat_id from public.karats where code = 'P5CCK1';
  select id into v_category_id from public.product_categories where code = 'p5cccat';
  select id into v_channel_id from public.collection_channels where key = 'p5ccchan';
  select id into v_pm_id from public.payment_methods where key = 'p5ccpm';

  perform public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P5CC-A-ORDER'
  );
end $$;

do $$
declare
  v_store_id uuid; v_carrier_id uuid; v_zone_id uuid; v_order_id uuid;
  v_busy boolean; v_ready boolean;
  v_b_failed boolean := false; v_b_error text;
  v_new_version_count int;
begin
  select id into v_store_id from public.stores where code = 'P5CCSTA';
  select id into v_carrier_id from public.shipping_carriers where code = 'SMSA';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P5CC-A-ORDER';

  perform dblink_connect('conn_a', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A creates a shipment (acquire_shipping_rates_lock_SHARED inside, 0117)
  -- and stays OPEN — holds the shared lock for the rest of its open txn.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.create_shipment(
      p_sales_order_id := '%s'::uuid, p_store_id := '%s'::uuid, p_shipment_date := public.business_today(),
      p_direction := 'outbound', p_carrier_id := '%s'::uuid, p_shipping_zone_id := '%s'::uuid,
      p_customer_shipping_charge := 30.00
    ); end $inner$;$sql$,
    v_order_id, v_store_id, v_carrier_id, v_zone_id
  ));

  -- B concurrently schedules a NEW future rate version for the SAME
  -- carrier/zone/direction (needs the EXCLUSIVE lock, 0114) — must block.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.create_shipping_carrier_rate_version('%s'::uuid, '%s'::uuid, 'outbound', 99.00, (public.business_today() + 1)::date, 'Test A race version')$sql$,
    v_carrier_id, v_zone_id
  ));

  v_busy := public._p5cc_wait_busy('conn_b');
  assert v_busy, 'FAIL A: create_shipping_carrier_rate_version() (اتصال B) لم يُحجب رغم أن create_shipment() (اتصال A) ما زال مفتوحًا ويحمل القفل المشترك لتسعير الشحن (1005)';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p5cc_wait_ready('conn_b');
  assert v_ready, 'FAIL A: create_shipping_carrier_rate_version() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p5cc_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  assert not v_b_failed, format('FAIL A: كان يجب أن ينجح إصدار السعر الجديد لاتصال B بعد التزام A بلا أي تعارض، وجد خطأ: %s', v_b_error);

  select count(*) into v_new_version_count from public.shipping_carrier_rate_versions
    where carrier_id = v_carrier_id and shipping_zone_id = v_zone_id and direction = 'outbound' and base_cost = 99.00;
  assert v_new_version_count = 1, format('FAIL A: يجب أن يوجد إصدار تسعير جديد واحد بالضبط (99.00) بعد نجاح B، وجد %s', v_new_version_count);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: A (قفل تسعير الشحن المشترك مقابل create_shipment) — اتصال B حُجب فعليًا طوال معاملة create_shipment() المفتوحة لاتصال A، ثم نجح إصدار السعر الجديد بعد الالتزام دون أي كتابة ممزقة';
end $$;

-- ============================================================================
-- B — concurrent add_shipment_status_event() optimistic-concurrency race
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_carrier_id uuid; v_zone_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P5CCSTB';
  select id into v_karat_id from public.karats where code = 'P5CCK1';
  select id into v_category_id from public.product_categories where code = 'p5cccat';
  select id into v_channel_id from public.collection_channels where key = 'p5ccchan';
  select id into v_pm_id from public.payment_methods where key = 'p5ccpm';
  select id into v_carrier_id from public.shipping_carriers where code = 'SMSA';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P5CC-B-ORDER'
  );

  perform public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'outbound', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 30.00
  );
end $$;

do $$
declare
  v_store_id uuid; v_order_id uuid; v_shipment_id uuid;
  v_busy boolean; v_ready boolean;
  v_b_failed boolean := false; v_b_error text;
  v_final_status text; v_final_version bigint; v_event_count int;
begin
  select id into v_store_id from public.stores where code = 'P5CCSTB';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P5CC-B-ORDER';
  select id into v_shipment_id from public.shipments where sales_order_id = v_order_id;

  perform dblink_connect('conn_a', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A advances created -> ready_for_pickup with expected_version=1 (the
  -- shipment's real starting version, per create_shipment()'s own INSERT —
  -- row_version's DEFAULT 1, never bumped further by that function) and
  -- stays OPEN — holds the shipment row's `for update` lock.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.add_shipment_status_event('%s'::uuid, 'ready_for_pickup', 1::bigint, public.business_today()); end $inner$;$sql$,
    v_shipment_id
  ));

  -- B races the SAME stale expected_version=1 concurrently — must block on
  -- A's still-open `for update` lock (0118, mirrors update_sales_order()'s
  -- 0075 lock-then-compare fix).
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select row_version from public.add_shipment_status_event('%s'::uuid, 'ready_for_pickup', 1::bigint, public.business_today())$sql$,
    v_shipment_id
  ));

  v_busy := public._p5cc_wait_busy('conn_b');
  assert v_busy, 'FAIL B: add_shipment_status_event() (اتصال B) لم يُحجب رغم أن add_shipment_status_event() (اتصال A) ما زال مفتوحًا ويحمل قفل صف الشحنة لنفس الشحنة';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p5cc_wait_ready('conn_b');
  assert v_ready, 'FAIL B: add_shipment_status_event() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  begin
    perform rv from dblink_get_result('conn_b', true) as t(rv bigint);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p5cc_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  assert v_b_failed, 'FAIL B: كان يجب أن يُرفض تحديث حالة اتصال B بإصدار قديم (row_version) بعد أن التزم A بتحديث الحالة أولاً على نفس الشحنة';
  assert v_b_error like '%تم تعديل هذه الشحنة%', format('FAIL B: رسالة خطأ B غير متوقعة (يُتوقع تعارض إصدار، وليس أي رفض آخر): %s', v_b_error);

  select current_status, row_version into v_final_status, v_final_version from public.shipments where id = v_shipment_id;
  assert v_final_status = 'ready_for_pickup', format('FAIL B: الحالة النهائية يجب أن تكون ready_for_pickup (من A فقط)، وجد %s', v_final_status);
  assert v_final_version = 2, format('FAIL B: row_version يجب أن يكون 2 بالضبط (حدث واحد ناجح فقط)، وجد %s', v_final_version);

  select count(*) into v_event_count from public.shipment_status_events where shipment_id = v_shipment_id and status = 'ready_for_pickup';
  assert v_event_count = 1, format('FAIL B: يجب أن يوجد حدث ready_for_pickup واحد بالضبط في السجل الزمني، وجد %s', v_event_count);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: B اتصال B حُجب فعليًا طوال معاملة add_shipment_status_event() المفتوحة لاتصال A على نفس الشحنة، ثم رُفض بوضوح بتعارض إصدار (row_version) بعد الالتزام — لا فقدان تحديث (Lost Update) ممكن حتى تحت تزامن حقيقي (%)', v_b_error;
end $$;

-- ============================================================================
-- C — concurrent record_shipment_actual_cost() "double first-time-record"
-- race
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_carrier_id uuid; v_zone_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P5CCSTC';
  select id into v_karat_id from public.karats where code = 'P5CCK1';
  select id into v_category_id from public.product_categories where code = 'p5cccat';
  select id into v_channel_id from public.collection_channels where key = 'p5ccchan';
  select id into v_pm_id from public.payment_methods where key = 'p5ccpm';
  select id into v_carrier_id from public.shipping_carriers where code = 'SMSA';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P5CC-C-ORDER'
  );

  perform public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'outbound', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 30.00
  );
end $$;

do $$
declare
  v_store_id uuid; v_order_id uuid; v_shipment_id uuid;
  v_busy boolean; v_ready boolean;
  v_b_failed boolean := false; v_b_error text;
  v_final_cost numeric; v_event_count int;
begin
  select id into v_store_id from public.stores where code = 'P5CCSTC';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P5CC-C-ORDER';
  select id into v_shipment_id from public.shipments where sales_order_id = v_order_id;

  perform dblink_connect('conn_a', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A records the FIRST actual cost (24.00) with expected_version=1 and
  -- stays OPEN — holds the shipment row's `for update` lock.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.record_shipment_actual_cost('%s'::uuid, 1::bigint, 24.00, public.business_today()); end $inner$;$sql$,
    v_shipment_id
  ));

  -- B races the SAME "first recording" concurrently, with the SAME stale
  -- expected_version=1 — record_shipment_actual_cost() locks the shipment
  -- row FIRST, THEN compares row_version (0118, same shape as B above),
  -- BEFORE it ever reaches the "already recorded" business check — so this
  -- race is caught one layer earlier than that check, never relying on it
  -- alone to prevent a double first-time record.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select row_version from public.record_shipment_actual_cost('%s'::uuid, 1::bigint, 99.00, public.business_today())$sql$,
    v_shipment_id
  ));

  v_busy := public._p5cc_wait_busy('conn_b');
  assert v_busy, 'FAIL C: record_shipment_actual_cost() (اتصال B) لم يُحجب رغم أن record_shipment_actual_cost() (اتصال A) ما زال مفتوحًا ويحمل قفل صف الشحنة لنفس الشحنة';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p5cc_wait_ready('conn_b');
  assert v_ready, 'FAIL C: record_shipment_actual_cost() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  begin
    perform rv from dblink_get_result('conn_b', true) as t(rv bigint);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p5cc_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  assert v_b_failed, 'FAIL C: كان يجب أن يُرفض تسجيل التكلفة الفعلية لاتصال B (تسجيل أول مزدوج) بعد أن التزم A بتسجيل التكلفة الفعلية أولاً على نفس الشحنة';
  assert v_b_error like '%تم تعديل هذه الشحنة%', format('FAIL C: رسالة خطأ B غير متوقعة (يُتوقع تعارض إصدار وليس رسالة "مسجلة سابقًا" لأن فحص الإصدار يسبقها)، وجد: %s', v_b_error);

  select actual_carrier_cost into v_final_cost from public.shipments where id = v_shipment_id;
  assert v_final_cost = 24.00, format('FAIL C: التكلفة الفعلية النهائية يجب أن تكون 24.00 (من A فقط)، وجد %s', v_final_cost);

  select count(*) into v_event_count from public.shipment_financial_events where shipment_id = v_shipment_id and event_type = 'actual_cost_recorded';
  assert v_event_count = 1, format('FAIL C: يجب أن يوجد حدث actual_cost_recorded واحد بالضبط بعد السباق، وجد %s', v_event_count);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: C اتصال B حُجب فعليًا طوال معاملة record_shipment_actual_cost() المفتوحة لاتصال A، ثم رُفض بتعارض إصدار بعد الالتزام — لا يمكن أبدًا وجود تسجيلين "أولين" لنفس الشحنة حتى تحت تزامن حقيقي (%)', v_b_error;
end $$;

-- ============================================================================
-- D — Daily Close vs create_shipment() race
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P5CCSTD';
  select id into v_karat_id from public.karats where code = 'P5CCK1';
  select id into v_category_id from public.product_categories where code = 'p5cccat';
  select id into v_channel_id from public.collection_channels where key = 'p5ccchan';
  select id into v_pm_id from public.payment_methods where key = 'p5ccpm';

  perform public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P5CC-D-ORDER'
  );
end $$;

do $$
declare
  v_store_id uuid; v_carrier_id uuid; v_zone_id uuid; v_order_id uuid; v_close_day date;
  v_busy boolean; v_ready boolean;
  v_closing_count int;
begin
  v_close_day := public.business_today();
  select id into v_store_id from public.stores where code = 'P5CCSTD';
  select id into v_carrier_id from public.shipping_carriers where code = 'SMSA';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P5CC-D-ORDER';

  perform dblink_connect('conn_a', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A creates a shipment for this exact (store, shipment_date) and stays
  -- OPEN — holds the SHARED daily-close lock (0117, Section 28) for the
  -- rest of its open transaction.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.create_shipment(
      p_sales_order_id := '%s'::uuid, p_store_id := '%s'::uuid, p_shipment_date := '%s'::date,
      p_direction := 'outbound', p_carrier_id := '%s'::uuid, p_shipping_zone_id := '%s'::uuid,
      p_customer_shipping_charge := 30.00
    ); end $inner$;$sql$,
    v_order_id, v_store_id, v_close_day, v_carrier_id, v_zone_id
  ));

  -- B attempts to close the SAME (store, day), asynchronously.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.close_sales_day('%s'::uuid, '%s'::date, 'Test D race')$sql$,
    v_store_id, v_close_day
  ));

  v_busy := public._p5cc_wait_busy('conn_b');
  assert v_busy, 'FAIL D: close_sales_day() (اتصال B) لم يُحجب رغم أن create_shipment() (اتصال A) ما زال مفتوحًا لنفس المتجر/اليوم';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p5cc_wait_ready('conn_b');
  assert v_ready, 'FAIL D: close_sales_day() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  perform closing_id from dblink_get_result('conn_b', true) as t(closing_id uuid);
  perform public._p5cc_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  select count(*) into v_closing_count from public.daily_closings where store_id = v_store_id and business_date = v_close_day;
  assert v_closing_count = 1, format('FAIL D: يجب أن يكون اليوم مغلقًا الآن بعد نجاح B، وجد %s صف إغلاق', v_closing_count);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: D close_sales_day() انتظر فعليًا حتى التزام create_shipment() المفتوحة لنفس المتجر/اليوم قبل أن يتابع — قفل الإغلاق اليومي المشترك/الحصري لـShipping مطابق تمامًا لآلية Sales/Returns';
end $$;

-- ============================================================================
-- E — Daily Close vs record_shipment_actual_cost() (E1) / correct_shipment_
-- actual_cost() (E2) race
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_carrier_id uuid; v_zone_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P5CCSTE';
  select id into v_karat_id from public.karats where code = 'P5CCK1';
  select id into v_category_id from public.product_categories where code = 'p5cccat';
  select id into v_channel_id from public.collection_channels where key = 'p5ccchan';
  select id into v_pm_id from public.payment_methods where key = 'p5ccpm';
  select id into v_carrier_id from public.shipping_carriers where code = 'SMSA';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P5CC-E-ORDER'
  );

  perform public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'outbound', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 30.00
  );
end $$;

-- ---- E1: record_shipment_actual_cost() vs close_sales_day() ----
do $$
declare
  v_store_id uuid; v_order_id uuid; v_shipment_id uuid; v_close_day date;
  v_busy boolean; v_ready boolean;
  v_closing_count int;
begin
  v_close_day := public.business_today();
  select id into v_store_id from public.stores where code = 'P5CCSTE';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P5CC-E-ORDER';
  select id into v_shipment_id from public.shipments where sales_order_id = v_order_id;

  perform dblink_connect('conn_a', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A records the actual cost for this exact business_date and stays OPEN
  -- — holds the SHARED daily-close lock (0118, gated on the cost's OWN
  -- business_date, Section 28) for the rest of its open transaction.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.record_shipment_actual_cost('%s'::uuid, 1::bigint, 24.00, '%s'::date); end $inner$;$sql$,
    v_shipment_id, v_close_day
  ));

  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.close_sales_day('%s'::uuid, '%s'::date, 'Test E1 race')$sql$,
    v_store_id, v_close_day
  ));

  v_busy := public._p5cc_wait_busy('conn_b');
  assert v_busy, 'FAIL E1: close_sales_day() (اتصال B) لم يُحجب رغم أن record_shipment_actual_cost() (اتصال A) ما زال مفتوحًا لنفس المتجر/تاريخ العملية المالية';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p5cc_wait_ready('conn_b');
  assert v_ready, 'FAIL E1: close_sales_day() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  perform closing_id from dblink_get_result('conn_b', true) as t(closing_id uuid);
  perform public._p5cc_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  select count(*) into v_closing_count from public.daily_closings where store_id = v_store_id and business_date = v_close_day;
  assert v_closing_count = 1, format('FAIL E1: يجب أن يكون اليوم مغلقًا الآن بعد نجاح B، وجد %s صف إغلاق', v_closing_count);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: E1 close_sales_day() انتظر فعليًا حتى التزام record_shipment_actual_cost() المفتوحة لنفس المتجر/تاريخ العملية المالية قبل أن يتابع';
end $$;

-- ---- E2 setup: a shipment with an EXISTING actual cost to correct ----
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_carrier_id uuid; v_zone_id uuid; v_shipment_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P5CCSTE2';
  select id into v_karat_id from public.karats where code = 'P5CCK1';
  select id into v_category_id from public.product_categories where code = 'p5cccat';
  select id into v_channel_id from public.collection_channels where key = 'p5ccchan';
  select id into v_pm_id from public.payment_methods where key = 'p5ccpm';
  select id into v_carrier_id from public.shipping_carriers where code = 'SMSA';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P5CC-E2-ORDER'
  );

  select id into v_shipment_id from public.create_shipment(
    p_sales_order_id := v_order_id, p_store_id := v_store_id, p_shipment_date := public.business_today(),
    p_direction := 'outbound', p_carrier_id := v_carrier_id, p_shipping_zone_id := v_zone_id,
    p_customer_shipping_charge := 30.00
  );

  perform public.record_shipment_actual_cost(v_shipment_id, 1::bigint, 24.00, public.business_today());
end $$;

-- ---- E2: correct_shipment_actual_cost() vs close_sales_day() ----
do $$
declare
  v_store_id uuid; v_order_id uuid; v_shipment_id uuid; v_close_day date;
  v_busy boolean; v_ready boolean;
  v_closing_count int; v_final_cost numeric;
begin
  v_close_day := public.business_today();
  select id into v_store_id from public.stores where code = 'P5CCSTE2';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P5CC-E2-ORDER';
  select id into v_shipment_id from public.shipments where sales_order_id = v_order_id;

  perform dblink_connect('conn_a', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A corrects the already-recorded actual cost (row_version=2 after the
  -- first recording above) and stays OPEN — holds the SHARED daily-close
  -- lock for the rest of its open transaction.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.correct_shipment_actual_cost('%s'::uuid, 2::bigint, 26.50, '%s'::date, 'Test E2 race correction'); end $inner$;$sql$,
    v_shipment_id, v_close_day
  ));

  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.close_sales_day('%s'::uuid, '%s'::date, 'Test E2 race')$sql$,
    v_store_id, v_close_day
  ));

  v_busy := public._p5cc_wait_busy('conn_b');
  assert v_busy, 'FAIL E2: close_sales_day() (اتصال B) لم يُحجب رغم أن correct_shipment_actual_cost() (اتصال A) ما زال مفتوحًا لنفس المتجر/تاريخ العملية المالية';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p5cc_wait_ready('conn_b');
  assert v_ready, 'FAIL E2: close_sales_day() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  perform closing_id from dblink_get_result('conn_b', true) as t(closing_id uuid);
  perform public._p5cc_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  select count(*) into v_closing_count from public.daily_closings where store_id = v_store_id and business_date = v_close_day;
  assert v_closing_count = 1, format('FAIL E2: يجب أن يكون اليوم مغلقًا الآن بعد نجاح B، وجد %s صف إغلاق', v_closing_count);

  select actual_carrier_cost into v_final_cost from public.shipments where id = v_shipment_id;
  assert v_final_cost = 26.50, format('FAIL E2: التكلفة الفعلية النهائية يجب أن تعكس تصحيح A (26.50)، وجد %s', v_final_cost);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: E2 close_sales_day() انتظر فعليًا حتى التزام correct_shipment_actual_cost() المفتوحة لنفس المتجر/تاريخ العملية المالية قبل أن يتابع، والتصحيح (26.50) محفوظ بشكل صحيح';
end $$;

-- ============================================================================
-- F — lock-order proof (reverse of A): create_shipping_carrier_rate_
-- version() (EXCLUSIVE) vs create_shipment() (SHARED), racing the two
-- Shipping functions that actually touch the shipping-rates advisory lock
-- (1005) against each other in BOTH possible orders (A did shared-first,
-- this does exclusive-first) — the real proof the spec's Section 19-style
-- language asks for: never a genuine Postgres deadlock (SQLSTATE 40P01)
-- between them, only ordinary blocking.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P5CCSTF';
  select id into v_karat_id from public.karats where code = 'P5CCK1';
  select id into v_category_id from public.product_categories where code = 'p5cccat';
  select id into v_channel_id from public.collection_channels where key = 'p5ccchan';
  select id into v_pm_id from public.payment_methods where key = 'p5ccpm';

  perform public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P5CC-F-ORDER'
  );
end $$;

do $$
declare
  v_store_id uuid; v_carrier_id uuid; v_zone_id uuid; v_order_id uuid;
  v_busy boolean; v_ready boolean;
  v_b_failed boolean := false; v_b_error text;
  v_shipment_cost numeric; v_shipment_rate_version uuid; v_new_version_id uuid;
begin
  select id into v_store_id from public.stores where code = 'P5CCSTF';
  -- ARAMEX/RIYADH/outbound has NO pre-existing configuration at all
  -- (neither the seed data nor this file's own P5CC fixture touches it) —
  -- A's own call below creates its very FIRST version.
  select id into v_carrier_id from public.shipping_carriers where code = 'ARAMEX';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';
  select id into v_order_id from public.sales_orders where store_id = v_store_id and customer_name = 'P5CC-F-ORDER';

  perform dblink_connect('conn_a', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A creates ARAMEX/RIYADH/outbound's first-ever rate version (EXCLUSIVE
  -- lock, 0114) and stays OPEN.
  perform dblink_exec('conn_a', format(
    $sql$do $inner$ begin perform public.create_shipping_carrier_rate_version('%s'::uuid, '%s'::uuid, 'outbound', 55.00, %L::date, 'Test F race version'); end $inner$;$sql$,
    v_carrier_id, v_zone_id, public.business_today()
  ));

  -- B concurrently attempts to create a shipment resolving that exact
  -- carrier/zone/direction (needs the SHARED lock to resolve the rate,
  -- 0117) — must block on A's still-open EXCLUSIVE hold.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select id from public.create_shipment(
      p_sales_order_id := '%s'::uuid, p_store_id := '%s'::uuid, p_shipment_date := public.business_today(),
      p_direction := 'outbound', p_carrier_id := '%s'::uuid, p_shipping_zone_id := '%s'::uuid,
      p_customer_shipping_charge := 80.00
    )$sql$,
    v_order_id, v_store_id, v_carrier_id, v_zone_id
  ));

  v_busy := public._p5cc_wait_busy('conn_b');
  assert v_busy, 'FAIL F: create_shipment() (اتصال B) لم يُحجب رغم أن create_shipping_carrier_rate_version() (اتصال A) ما زال مفتوحًا ويحمل القفل الحصري لتسعير الشحن (1005)';

  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p5cc_wait_ready('conn_b');
  assert v_ready, 'FAIL F: create_shipment() (اتصال B) لم يكتمل خلال المهلة بعد التزام A — احتمال طريق مسدود (deadlock) لم يُكتشف بواسطة Postgres نفسه';

  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p5cc_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  -- The critical proof for this test: no genuine Postgres deadlock, ever —
  -- structurally impossible here since only create_shipment() acquires
  -- BOTH the daily-close and shipping-rates locks (always daily-close
  -- first, then shipping-rates, 0117), and neither close_sales_day() nor
  -- create/cancel_*_rate_version() ever acquires more than its own single
  -- lock — so no two-resource cycle can ever form.
  if v_b_failed then
    assert v_b_error not like '%deadlock%' and v_b_error not like '%طريق مسدود%', format('FAIL F: طريق مسدود حقيقي اكتُشف بين create_shipping_carrier_rate_version() و create_shipment() — ترتيب الأقفال غير آمن: %s', v_b_error);
  end if;
  assert not v_b_failed, format('FAIL F: كان يجب أن ينجح create_shipment() لاتصال B بعد التزام A، إذ أصبح للتوّ يوجد تسعير معتمد (55.00) لهذا الاتجاه/الشركة/المنطقة، وجد خطأ: %s', v_b_error);

  select expected_carrier_cost, carrier_rate_version_id into v_shipment_cost, v_shipment_rate_version
    from public.shipments where sales_order_id = v_order_id;
  select id into v_new_version_id from public.shipping_carrier_rate_versions
    where carrier_id = v_carrier_id and shipping_zone_id = v_zone_id and direction = 'outbound' and base_cost = 55.00;

  assert v_shipment_cost = 55.00, format('FAIL F: التكلفة المتوقعة للشحنة يجب أن تعكس السعر الجديد الملتزَم به من A (55.00)، وجد %s', v_shipment_cost);
  assert v_shipment_rate_version = v_new_version_id, 'FAIL F: carrier_rate_version_id للشحنة يجب أن يشير بالضبط إلى إصدار A الملتزَم به حديثًا — لا قراءة مسبقة القفل قديمة (stale pre-lock read)';

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: F اتصال B حُجب فعليًا طوال معاملة create_shipping_carrier_rate_version() المفتوحة لاتصال A (القفل الحصري 1005)، ثم اكتمل بشكل طبيعي بعد الالتزام وحلّ السعر الجديد (55.00) بدقة — لا طريق مسدود (deadlock) بين الدالتين في أي من اتجاهي التسابق (A وF معًا)';
end $$;

-- ============================================================================
-- G — Shipping Integrity Patch 5.1 item 16: reverse_sales_return() vs
-- create_shipment() racing the same sales_returns row.
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_order_id uuid; v_item_id uuid; v_return_id uuid; v_row_version bigint;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P5CCSTG';
  select id into v_karat_id from public.karats where code = 'P5CCK1';
  select id into v_category_id from public.product_categories where code = 'p5cccat';
  select id into v_channel_id from public.collection_channels where key = 'p5ccchan';
  select id into v_pm_id from public.payment_methods where key = 'p5ccpm';

  select id into v_order_id from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P5CC-G-ORDER'
  );
  select (public.get_sales_order(v_order_id) -> 'items' -> 0 ->> 'id')::uuid into v_item_id;

  select id into v_return_id from public.create_sales_return(
    v_order_id, v_store_id, public.business_today(), 'other',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id)),
    (public.get_sales_order(v_order_id) ->> 'row_version')::bigint, 'collected', 500.00,
    p_scenario_notes := 'P5CC-G: سيناريو أخرى يتطلب ملاحظات'
  );
  select (public.get_sales_return(v_return_id) ->> 'row_version')::bigint into v_row_version;
  perform public.approve_sales_return(v_return_id, v_row_version);

  perform set_config('p5cc.g_order_id', v_order_id::text, false);
  perform set_config('p5cc.g_store_id', v_store_id::text, false);
  perform set_config('p5cc.g_return_id', v_return_id::text, false);
end $$;

do $$
declare
  v_order_id uuid := current_setting('p5cc.g_order_id')::uuid;
  v_store_id uuid := current_setting('p5cc.g_store_id')::uuid;
  v_return_id uuid := current_setting('p5cc.g_return_id')::uuid;
  v_carrier_id uuid; v_zone_id uuid;
  v_return_row_version bigint;
  v_busy boolean; v_ready boolean;
  v_b_failed boolean := false; v_b_error text;
  v_final_status text;
  v_shipment_count int;
begin
  select id into v_carrier_id from public.shipping_carriers where code = 'SMSA';
  select id into v_zone_id from public.shipping_zones where code = 'RIYADH';
  -- Direct table read (as the superuser session, bypassing RLS) — this
  -- block has no request.jwt.claims/authenticated role of its own (SET
  -- LOCAL from the previous do-block's own separate implicit transaction
  -- does not carry over), exactly like Test A/F's own outer id-lookup
  -- blocks above read public.stores/public.sales_orders directly rather
  -- than through an RPC.
  select row_version into v_return_row_version from public.sales_returns where id = v_return_id;

  perform dblink_connect('conn_a', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p5cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A reverses the return (locks the sales_returns row FOR UPDATE, 0088/
  -- 0096/0102) and stays OPEN.
  perform dblink_send_query('conn_a', format(
    $sql$select public.reverse_sales_return('%s'::uuid, %s::bigint, 'P5CC-G: اختبار تزامن')$sql$,
    v_return_id, v_return_row_version
  ));
  v_busy := public._p5cc_wait_busy('conn_a');
  assert v_busy, 'FAIL G: reverse_sales_return() (اتصال A) كان يجب أن يبدأ تنفيذه (حتى لو انتهى بسرعة) — تحقق من الاتصال';
  -- Drain A's own result immediately if it already finished before we could
  -- observe it busy (fast local connections) — the meaningful assertion is
  -- what happens to B below, not exactly how long A's own call takes.
  perform pg_sleep(0.05);

  -- B concurrently attempts a NEW return shipment against the SAME return,
  -- racing A's still-open reversal. create_shipment()'s FOR UPDATE (0125)
  -- must make B block on A's row lock rather than reading a stale
  -- 'approved' snapshot.
  perform dblink_exec('conn_b', 'begin');
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"e5000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select id from public.create_shipment(
      p_sales_order_id := '%s'::uuid, p_store_id := '%s'::uuid, p_shipment_date := public.business_today(),
      p_direction := 'return', p_carrier_id := '%s'::uuid, p_shipping_zone_id := '%s'::uuid,
      p_customer_shipping_charge := 35.00, p_sales_return_id := '%s'::uuid
    )$sql$,
    v_order_id, v_store_id, v_carrier_id, v_zone_id, v_return_id
  ));

  v_busy := public._p5cc_wait_busy('conn_b');
  assert v_busy, 'FAIL G: create_shipment() (اتصال B) لم يُحجب رغم أن reverse_sales_return() (اتصال A) ما زال يحمل قفل الصف لنفس المرتجع (FOR UPDATE)';

  -- A commits — the return is now genuinely 'reversed'.
  begin
    perform x from dblink_get_result('conn_a', true) as t(x uuid, return_number text);
  exception when others then
    null; -- A's own result is not the point of this test; ignore.
  end;
  perform public._p5cc_drain_pending('conn_a');
  perform dblink_exec('conn_a', 'commit');

  v_ready := public._p5cc_wait_ready('conn_b');
  assert v_ready, 'FAIL G: create_shipment() (اتصال B) لم يكتمل خلال المهلة بعد التزام A';

  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    v_b_failed := false;
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform public._p5cc_drain_pending('conn_b');
  perform dblink_exec('conn_b', 'commit');

  -- The real point of item 16: B must be REJECTED, never silently succeed
  -- against what became a reversed return the instant A's lock released.
  assert v_b_failed, 'FAIL G: create_shipment() (اتصال B) نجح رغم أن المرتجع أصبح reversed بفضل A — السباق لم يُغلق فعليًا';
  assert v_b_error like '%لم يعتمَد%' or v_b_error like '%أُلغي%' or v_b_error like '%reversed%' or v_b_error like '%معتمَدًا%',
    format('FAIL G: رسالة رفض B غير متوقعة (يجب أن تشير لحالة المرتجع)، وجد: %s', v_b_error);

  select status into v_final_status from public.sales_returns where id = v_return_id;
  assert v_final_status = 'reversed', format('FAIL G: حالة المرتجع النهائية يجب أن تكون reversed، وجد %s', v_final_status);

  select count(*) into v_shipment_count from public.shipments where sales_return_id = v_return_id;
  assert v_shipment_count = 0, format('FAIL G: لا يجب أن توجد أي شحنة لهذا المرتجع بعد رفض B، وجد %s', v_shipment_count);

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  raise notice 'OK: G (Patch 5.1 item 16) — اتصال B حُجب فعليًا طوال معاملة reverse_sales_return() المفتوحة لاتصال A (قفل الصف FOR UPDATE)، ثم رُفض بشكل صحيح بعد التزام A لأن المرتجع أصبح reversed — لا شحنة أُنشئت رغم التسابق، ولا طريق مسدود (deadlock)';
end $$;

-- ============================================================================
-- Cleanup — DELIBERATELY PARTIAL, unlike sales_returns_concurrency.test.
-- sql's full teardown. shipment_status_events/shipment_financial_events are
-- UNCONDITIONALLY trigger-protected against UPDATE/DELETE (0116) with NO
-- escape hatch at all — 0116's own comment on reject_shipment_status_
-- event_mutation() explains why: "unlike 0106's app.allow_refund_event_
-- backfill — Phase 5 has no legacy pre-existing data to backfill". That
-- makes every shipment row created above permanently un-deletable too (FK
-- ON DELETE RESTRICT from shipment_status_events/shipment_financial_events
-- to shipments, 0116), which transitively makes its sales_order and store
-- permanently un-deletable as well (shipments.sales_order_id/store_id are
-- also ON DELETE RESTRICT). This is not an oversight — it is the same
-- deliberate "no hard delete, ever" design this file's own header comment
-- (and the Phase 5 spec) documents for the shipment audit trail, so this
-- file's fixtures/races are only safe to run against a genuinely throwaway
-- database (see the header), never a shared/staging one. Only the parts of
-- this file's own footprint that CAN be cleanly removed are removed below;
-- the helper functions are dropped in every case.
-- ============================================================================
drop function if exists public._p5cc_wait_busy(text, int, numeric);
drop function if exists public._p5cc_wait_ready(text, int, numeric);
drop function if exists public._p5cc_drain_pending(text);

do $$ begin
  raise notice 'ALL shipping_core_phase5_concurrency.test.sql ASSERTIONS PASSED (A-G)';
end $$;

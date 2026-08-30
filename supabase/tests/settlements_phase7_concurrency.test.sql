-- ============================================================================
-- Integration test: Phase 7 — Settlements Core (0167-0183) + Integrity Patch
-- 7.1 (0184-0191), GENUINE multi-session concurrency (mirrors
-- adjustments_core_phase6_concurrency.test.sql / shipping_core_phase5_
-- concurrency.test.sql's own dblink pattern exactly).
-- ============================================================================
-- NOT safe to run against a shared/staging database — real dblink sessions,
-- auto-committing statements, no wrapping transaction, explicit (partial —
-- see the Cleanup section) teardown at the end. Run ONLY against a
-- throwaway/CI database.
--
-- Requires migrations 0001-latest (including 0167-0191, Patch 7.1) +
-- supabase/seed.sql already applied, and the `dblink` extension available.
--
-- Connection string override, same convention as every other *_concurrency.
-- test.sql file:
--   psql -v dblink_conninfo="host=... port=... user=... password=..." \
--     -f supabase/tests/settlements_phase7_concurrency.test.sql
--
-- Scenarios — lettered per the governing Patch 7.1 spec §29/§30 (the file's
-- own original two scenarios predate that lettering; they are relabeled B
-- and H below to match rather than kept under their old ad-hoc A/B names):
--   A — Global settlement number race: two concurrent create_draft_
--       settlement_batch() calls never produce the same settlement_number
--       (generate_settlement_number()'s SEQUENCE, proven under real
--       concurrent load, not just trusted by design).
--   B — Two concurrent finalize_settlement_batch() calls, from TWO different
--       draft batches on the same route, both selecting the SAME unsettled
--       Sale source. Only one succeeds; the other genuinely blocks on the
--       settlement_source_claims_active_unique_idx race (0173/0178's own
--       documented "layer 2" — the single most important invariant in this
--       whole module) and is rejected once the winner commits. No
--       double-counted claim ever exists.
--   C — Finalize vs draft update on the SAME batch: finalize_settlement_
--       batch()'s own `for update` row lock on settlement_batches genuinely
--       blocks a concurrent update_draft_settlement_batch() on the same
--       batch id; once finalize commits, the update deterministically fails
--       with "not draft" — never a lost/torn update.
--   D — Double finalize on the SAME batch id: exactly one of two concurrent
--       finalize_settlement_batch() calls wins (draft->finalized), the
--       other is genuinely blocked then cleanly rejected — never double-
--       finalized, never two sets of settlement_batch_lines.
--   E — Route fee version writer (create_settlement_route_fee_version(),
--       EXCLUSIVE Settlement Master lock, 0171/0167) vs Finalization on a
--       batch using that route (SHARED Settlement Master lock, 0178/0185) —
--       finalize genuinely blocks until the new fee version fully commits,
--       then resolves it whole, never a half-written mix.
--   F — Daily Close (close_sales_day(), EXCLUSIVE daily-close lock) vs
--       Finalization on a batch dated that same store/day (SHARED daily-
--       close lock, 0185 §11) — genuinely serialized, never a silent
--       missed closure.
--   G — Daily Close vs record_settlement_bank_movement() (also SHARED
--       daily-close lock, 0188 §12) — same guarantee as F for a bank
--       movement instead of a finalize.
--   H — Two concurrent reverse_settlement_bank_movement() calls on the SAME
--       bank movement event. Only one succeeds (0174's UNIQUE
--       bank_movement_event_id / 0179's own documented "layer 2").
--   I — Reconcile vs a concurrent record_settlement_bank_movement() insert
--       on the SAME batch: both RPCs' own `for update` lock on
--       settlement_batches genuinely serializes them; whichever loses the
--       race deterministically fails clean (0188 §13's reconciled-blocks-
--       new-movements rule) — never a movement recorded after
--       reconciliation that was never accounted for.
--   J — Cancel (releasing a batch's settlement_source_claims) vs a second
--       finalize attempting to claim that SAME just-released source via a
--       NEW draft batch: proven under genuine overlap that the source is
--       NEVER claimed by two active claims at once (settlement_source_
--       claims_active_unique_idx, 0173) — the second finalize sees it as
--       still claimed while cancel's release is uncommitted, then succeeds
--       only once the release is fully committed.
--   K — Cancellation vs a concurrent record_settlement_bank_movement()
--       insert on the SAME batch: settlement_batches' own `for update` lock
--       serializes them; whichever wins, the loser fails clean — never a
--       cancelled batch left with an active unreversed movement recorded
--       after cancellation (0188's cancelled-batch rejection).
-- ============================================================================

create extension if not exists dblink;

\if :{?dblink_conninfo}
\else
\set dblink_conninfo 'host=127.0.0.1 port=5432 user=postgres password=postgres'
\endif

select set_config('p7cc.dblink_conninfo', :'dblink_conninfo', false);

create or replace function public._p7cc_wait_busy(p_connname text, p_max_polls int default 30, p_interval numeric default 0.1)
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

create or replace function public._p7cc_wait_ready(p_connname text, p_max_polls int default 100, p_interval numeric default 0.1)
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

create or replace function public._p7cc_drain_pending(p_connname text)
returns void
language plpgsql
as $$
begin
  perform 1 from dblink_get_result(p_connname) as t(x text);
end;
$$;

-- ============================================================================
-- 0. Fixtures — own prefix 'a7100000-.../P7CC', committed immediately (each
-- top-level statement here auto-commits — this file wraps nothing in an
-- explicit transaction, matching every other *_concurrency.test.sql file).
-- ============================================================================
insert into auth.users (id, email) values
  ('a7100000-0000-4000-8000-000000000001', 'test-p7cc-actor@example.invalid');

update public.profiles set full_name = 'P7CC actor', status = 'active', store_access_scope = 'all'
  where id = 'a7100000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a7100000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'stores.view', 'stores.create', 'karats.view', 'karats.manage', 'categories.view', 'categories.manage',
    'gold_prices.view', 'gold_prices.edit', 'manufacturing_fees.view', 'manufacturing_fees.manage',
    'payment_methods.view', 'collection_channels.view',
    'sales.create', 'sales.view', 'sales.view_profit', 'sales.close_day',
    'settlements.view', 'settlements.view_financials', 'settlements.create', 'settlements.finalize',
    'settlements.record_bank_movement', 'settlements.reconcile', 'settlements.cancel', 'settlements.manage_routes'
  );

do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid; v_pm_id uuid;
  v_route_id uuid;
  v_order_a record; v_order_c record;
  v_batch_a record; v_batch_b record; v_batch_c record;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  insert into public.stores (code, name_ar, status) values ('P7CCSTA', 'متجر تزامن تسويات', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P7CCK1', 'عيار تزامن تسويات', 995, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p7cccat', 'تصنيف تزامن تسويات', 995, 'active') returning id into v_category_id;
  select id into v_channel_id from public.collection_channels where key = 'direct_store';
  -- Deliberately 'bank_transfer' — this file permanently commits its route
  -- (no wrapping transaction, unlike settlements_phase7.test.sql), so it
  -- must never collide with settlements_phase7.test.sql's own 'cash'/
  -- 'tabby' routes on settlement_routes_payment_collection_match_idx if
  -- both files are run against the same long-lived sandbox DB.
  select id into v_pm_id from public.payment_methods where key = 'bank_transfer';

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 300.0000, 'a7100000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today() - 10, 'p7cc fixture');

  -- Patch 7.1 §4 (0184): route/source channel matching is now `IS NOT
  -- DISTINCT FROM` (exact equality, NULL is no longer a wildcard) —
  -- sales_orders.collection_channel_id is always NOT NULL, so a route
  -- created with a null collection_channel_id can now NEVER match a Sale.
  -- v_channel_id must be passed explicitly here (6th arg) or every source
  -- below silently stops matching this route under 0184+.
  select public.create_settlement_route('p7cc-route', 'مسار تزامن تسويات', 'payment_collection', null, v_pm_id, v_channel_id) into v_route_id;
  perform public.create_settlement_route_fee_version(v_route_id, public.business_today() - 30, 'source_snapshot', null, null, null, 0, null, 'p7cc fee');
  perform set_config('p7cc.route', v_route_id::text, false);

  -- A) the contested Sale — TWO draft batches will race to claim it.
  select * into v_order_a from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 400.00)),
    'P7CC-ORDER-A'
  );
  perform set_config('p7cc.order_a', v_order_a.id::text, false);

  select * into v_batch_a from public.create_draft_settlement_batch(v_route_id, public.business_today());
  perform set_config('p7cc.batch_a', v_batch_a.id::text, false);
  select * into v_batch_b from public.create_draft_settlement_batch(v_route_id, public.business_today());
  perform set_config('p7cc.batch_b', v_batch_b.id::text, false);

  -- B) a separately-finalized batch with ONE bank movement event, whose
  -- reversal is raced by two concurrent sessions.
  select * into v_order_c from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 250.00)),
    'P7CC-ORDER-C'
  );
  select * into v_batch_c from public.create_draft_settlement_batch(v_route_id, public.business_today());
  perform public.finalize_settlement_batch(v_batch_c.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order_c.id)), null, null, null);
  perform set_config('p7cc.batch_c', v_batch_c.id::text, false);
  perform set_config('p7cc.event_c', (public.record_settlement_bank_movement(v_batch_c.id, public.business_today(), 250.00, 'REF-P7CC-1', null))::text, false);
end $$;

do $$ begin raise notice 'SETUP OK: 1 actor, 1 store, 1 route (source_snapshot, batch_fee=0), one contested unsettled Sale, one finalized batch with one bank movement event'; end $$;

-- ============================================================================
-- 0b. Additional fixtures for the 9 new §29/§30 scenarios (A/C/D/E/F/G/I/J/K)
-- added on top of this file's original two (now B/H). Same posture as
-- section 0 above — every statement here commits immediately, no wrapping
-- transaction (dblink sessions below genuinely need to see this committed).
-- ============================================================================
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid; v_channel_id uuid;
  v_pm_id uuid; v_pm_mada uuid; v_route_id uuid;
  v_store_f uuid; v_store_g uuid; v_route_e uuid;
  v_order record; v_batch record; v_fin record;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_store_id from public.stores where code = 'P7CCSTA';
  select id into v_karat_id from public.karats where code = 'P7CCK1';
  select id into v_category_id from public.product_categories where code = 'p7cccat';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';
  select id into v_pm_id from public.payment_methods where key = 'bank_transfer';
  select id into v_pm_mada from public.payment_methods where key = 'mada';
  v_route_id := current_setting('p7cc.route')::uuid;

  -- Dedicated stores for F/G (Daily Close scenarios) — close_sales_day() has
  -- no Reopen (0071's own header), so each MUST be a store no other
  -- scenario in this file ever touches again once its day is closed.
  insert into public.stores (code, name_ar, status) values ('P7CCSTF', 'متجر تزامن تسويات (F)', 'active') returning id into v_store_f;
  insert into public.stores (code, name_ar, status) values ('P7CCSTG', 'متجر تزامن تسويات (G)', 'active') returning id into v_store_g;
  perform set_config('p7cc.store_f', v_store_f::text, false);
  perform set_config('p7cc.store_g', v_store_g::text, false);

  -- Dedicated route for E (mada — a payment method distinct from p7cc-
  -- route's own bank_transfer, so its ACTIVE-route-per-method uniqueness
  -- index never collides) — E's own race WRITES a brand-new fee version on
  -- it, which must never change fee resolution for any OTHER scenario
  -- still using p7cc-route.
  select public.create_settlement_route('p7cc-route-e', 'مسار تزامن تسويات (E)', 'payment_collection', null, v_pm_mada, v_channel_id) into v_route_e;
  perform public.create_settlement_route_fee_version(v_route_e, public.business_today() - 30, 'source_snapshot', null, null, null, 0, null, 'p7cc route-e fixture');
  perform set_config('p7cc.route_e', v_route_e::text, false);

  -- C) fresh order + draft batch — finalize-vs-draft-update race.
  select * into v_order from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 220.00)),
    'P7CC-ORDER-C2'
  );
  perform set_config('p7cc.order_c2', v_order.id::text, false);
  select * into v_batch from public.create_draft_settlement_batch(v_route_id, public.business_today());
  perform set_config('p7cc.batch_c2', v_batch.id::text, false);

  -- D) fresh order + draft batch — double-finalize race.
  select * into v_order from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 230.00)),
    'P7CC-ORDER-D'
  );
  perform set_config('p7cc.order_d', v_order.id::text, false);
  select * into v_batch from public.create_draft_settlement_batch(v_route_id, public.business_today());
  perform set_config('p7cc.batch_d', v_batch.id::text, false);

  -- E) fresh order (mada, matching route-e's own payment method) + draft
  -- batch on the dedicated route-e — fee-version-writer-vs-finalize race.
  select * into v_order from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_mada, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 500.00)),
    'P7CC-ORDER-E'
  );
  perform set_config('p7cc.order_e', v_order.id::text, false);
  select * into v_batch from public.create_draft_settlement_batch(v_route_e, public.business_today());
  perform set_config('p7cc.batch_e', v_batch.id::text, false);

  -- F) fresh order at the DEDICATED store_f + draft batch — Daily Close vs
  -- Finalization race.
  select * into v_order from public.create_sales_order(
    v_store_f, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 210.00)),
    'P7CC-ORDER-F'
  );
  perform set_config('p7cc.order_f', v_order.id::text, false);
  select * into v_batch from public.create_draft_settlement_batch(v_route_id, public.business_today());
  perform set_config('p7cc.batch_f', v_batch.id::text, false);

  -- G) fresh order at the DEDICATED store_g, FINALIZED here (sequentially,
  -- not part of the race) with zero bank movements yet — Daily Close vs
  -- record_settlement_bank_movement() races the batch's FIRST movement.
  select * into v_order from public.create_sales_order(
    v_store_g, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 240.00)),
    'P7CC-ORDER-G'
  );
  perform set_config('p7cc.order_g', v_order.id::text, false);
  select * into v_batch from public.create_draft_settlement_batch(v_route_id, public.business_today());
  perform public.finalize_settlement_batch(v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null);
  perform set_config('p7cc.batch_g', v_batch.id::text, false);

  -- I) fresh order, FINALIZED here with expected_bank_settlement equal to
  -- its own gross exactly (source_snapshot fee 0, batch_fee 0) so recording
  -- ONE matching movement here brings it to a genuine zero-variance state —
  -- reconcile-vs-record-movement races a SECOND movement attempt.
  select * into v_order from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 300.00)),
    'P7CC-ORDER-I'
  );
  perform set_config('p7cc.order_i', v_order.id::text, false);
  select * into v_batch from public.create_draft_settlement_batch(v_route_id, public.business_today());
  perform public.finalize_settlement_batch(v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null);
  perform public.record_settlement_bank_movement(v_batch.id, public.business_today(), 300.00, 'REF-P7CC-I1', null);
  perform set_config('p7cc.batch_i', v_batch.id::text, false);

  -- J) fresh order, FINALIZED into batch_j_x (the race cancels THIS batch,
  -- releasing its claim) + a SECOND still-draft batch_j_y that races to
  -- reclaim the SAME source the instant it is released.
  select * into v_order from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 260.00)),
    'P7CC-ORDER-J'
  );
  perform set_config('p7cc.order_j', v_order.id::text, false);
  select * into v_batch from public.create_draft_settlement_batch(v_route_id, public.business_today());
  select * into v_fin from public.finalize_settlement_batch(v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null);
  perform set_config('p7cc.batch_j_x', v_batch.id::text, false);
  perform set_config('p7cc.batch_j_x_version', v_fin.row_version::text, false);
  select * into v_batch from public.create_draft_settlement_batch(v_route_id, public.business_today());
  perform set_config('p7cc.batch_j_y', v_batch.id::text, false);

  -- K) fresh order, FINALIZED with zero movements — cancel-vs-record-
  -- movement race (K races the batch's FIRST-ever movement attempt).
  select * into v_order from public.create_sales_order(
    v_store_id, public.business_today(), v_pm_id, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0, 'sale_price', 270.00)),
    'P7CC-ORDER-K'
  );
  perform set_config('p7cc.order_k', v_order.id::text, false);
  select * into v_batch from public.create_draft_settlement_batch(v_route_id, public.business_today());
  select * into v_fin from public.finalize_settlement_batch(v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null);
  perform set_config('p7cc.batch_k', v_batch.id::text, false);
  perform set_config('p7cc.batch_k_version', v_fin.row_version::text, false);
end $$;

do $$ begin raise notice 'SETUP OK (extra): 2 dedicated stores (F/G), 1 dedicated route (E), 8 more orders/batches for scenarios A/C/D/E/F/G/I/J/K'; end $$;

-- ============================================================================
-- A — Global settlement number race: two concurrent create_draft_
-- settlement_batch() calls (different batches, same route) — their
-- settlement_number values must NEVER collide. generate_settlement_number()
-- is SEQUENCE-based (0169/item 25) by design; this proves it holds under
-- genuine concurrent load from two separate sessions, not merely trusted.
-- ============================================================================
do $$
declare
  v_num_a text; v_num_b text; v_id_a uuid; v_id_b uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- Fire BOTH calls before reading either result, so their execution
  -- genuinely overlaps rather than running strictly sequentially.
  perform dblink_send_query('conn_a', format(
    $sql$select id, settlement_number from public.create_draft_settlement_batch('%s'::uuid, public.business_today(), null, 'P7CC race A-a')$sql$,
    current_setting('p7cc.route')
  ));
  perform dblink_send_query('conn_b', format(
    $sql$select id, settlement_number from public.create_draft_settlement_batch('%s'::uuid, public.business_today(), null, 'P7CC race A-b')$sql$,
    current_setting('p7cc.route')
  ));

  perform public._p7cc_wait_ready('conn_a');
  perform public._p7cc_wait_ready('conn_b');

  select id, settlement_number into v_id_a, v_num_a from dblink_get_result('conn_a') as t(id uuid, settlement_number text);
  perform public._p7cc_drain_pending('conn_a');
  select id, settlement_number into v_id_b, v_num_b from dblink_get_result('conn_b') as t(id uuid, settlement_number text);
  perform public._p7cc_drain_pending('conn_b');

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert v_id_a is not null and v_id_b is not null and v_num_a is not null and v_num_b is not null,
    'FAIL A: كلا الاستدعاءين المتزامنين لإنشاء مسودة تسوية يجب أن ينجحا ويُرجعا رقم تسوية';
  assert v_id_a <> v_id_b, 'FAIL A: يجب أن تُنشأ دفعتان مختلفتان فعليًا (معرّفان مختلفان)';
  assert v_num_a <> v_num_b, format('FAIL A: رقما التسوية يجب أن يكونا مختلفين تحت تزامن حقيقي عبر اتصالين منفصلين — الموجود: %s / %s', v_num_a, v_num_b);

  raise notice 'PASS A: two concurrent create_draft_settlement_batch() calls across two genuinely separate sessions produced distinct settlement_numbers (% / %) — SEQUENCE-based generate_settlement_number(), no collision', v_num_a, v_num_b;
end $$;

-- ============================================================================
-- B — Two concurrent finalize_settlement_batch() calls (from two different
-- draft batches on the same route) both selecting the SAME unsettled Sale.
-- Only one succeeds; the other is genuinely blocked by the concurrent open
-- transaction, then rejected once it commits (settlement_source_claims_
-- active_unique_idx, the single most important invariant in this module).
-- (Spec §29 letter B — this file's own original scenario, predating the
-- §29 lettering.)
-- ============================================================================
do $$
declare
  v_busy boolean;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_b_error text;
  v_claim_count integer;
  v_line_count integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A finalizes batch_a, claiming order_a — sent async, held OPEN (no
  -- commit yet) so B's concurrent attempt on the SAME source genuinely
  -- overlaps rather than running sequentially.
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.finalize_settlement_batch('%s'::uuid, 1, '%s'::jsonb, null, null, null)$sql$,
    current_setting('p7cc.batch_a'), jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7cc.order_a')))::text
  ));
  perform public._p7cc_wait_ready('conn_a');
  begin
    perform id from dblink_get_result('conn_a', true) as t(id uuid, settlement_number text, row_version bigint);
    perform public._p7cc_drain_pending('conn_a');
  exception when others then
    v_a_failed := true;
  end;
  -- A's finalize call has RUN (its INSERT into settlement_source_claims has
  -- happened) but A's TRANSACTION is still open — nothing committed yet.

  -- B concurrently finalizes batch_b, selecting the SAME order_a. B's own
  -- claim INSERT for the identical (source_kind, source_event_id) key
  -- must genuinely block on A's still-uncommitted conflicting insert
  -- (Postgres blocks a second inserter of a colliding unique key until the
  -- first resolves) — sent async and polled, never a synchronous call that
  -- would deadlock this script.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.finalize_settlement_batch('%s'::uuid, 1, '%s'::jsonb, null, null, null)$sql$,
    current_setting('p7cc.batch_b'), jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7cc.order_a')))::text
  ));

  v_busy := public._p7cc_wait_busy('conn_b');
  assert v_busy, 'FAIL B: محاولة الاعتماد الثانية (B) على نفس المصدر لم تُحجب رغم أن اعتماد A ما زال مفتوحًا ويحمل قفل المطالبة غير الملتزم';

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p7cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, settlement_number text, row_version bigint);
    perform public._p7cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform dblink_disconnect('conn_b');

  assert (v_a_failed or v_b_failed), 'FAIL B: إحدى محاولتي الاعتماد المتزامنتين على نفس المصدر يجب أن تُرفض';
  assert not (v_a_failed and v_b_failed), 'FAIL B: إحدى محاولتي الاعتماد على الأقل يجب أن تنجح';

  -- No double-counted claim — EXACTLY one active claim exists for order_a,
  -- and EXACTLY one settlement_batch_lines row was ever written for it,
  -- regardless of which side won the race.
  select count(*) into v_claim_count from public.list_unsettled_settlement_sources(
    current_setting('p7cc.route')::uuid, public.business_today() - 1, public.business_today() + 1
  ) where source_kind = 'sale' and source_event_id = current_setting('p7cc.order_a')::uuid;
  assert v_claim_count = 0, format('FAIL B: order_a يجب ألا يكون متاحًا بعد السباق (تمت المطالبة به مرة واحدة) — الموجود: %s صف متاح', v_claim_count);

  select count(*) into v_line_count from (
    select l ->> 'source_number' as x
    from public.get_settlement_batch(current_setting('p7cc.batch_a')::uuid) b, jsonb_array_elements(b.lines) l
    union all
    select l ->> 'source_number'
    from public.get_settlement_batch(current_setting('p7cc.batch_b')::uuid) b, jsonb_array_elements(b.lines) l
  ) t;
  assert v_line_count = 1, format('FAIL B: يجب أن يوجد سطر واحد بالضبط لـ order_a عبر batch_a/batch_b مجتمعين — الموجود: %s', v_line_count);

  raise notice 'PASS B: two concurrent finalize_settlement_batch() calls racing the SAME source — exactly one wins (settlement_source_claims_active_unique_idx), the other genuinely blocks then is cleanly rejected, no double-counted claim/line ever exists';
end $$;

-- ============================================================================
-- C — Finalize vs a concurrent update_draft_settlement_batch() on the SAME
-- batch id. Both RPCs open with `select ... for update` on settlement_
-- batches (0185/0189) — genuinely the same row lock scenario B already
-- proves for the claims table, now proven on the batch row itself. A holds
-- finalize's transaction open (committed nowhere yet); B's update, racing
-- with A's own PRE-finalize row_version, must block on A's lock, then —
-- once unblocked — deterministically observe status='finalized' (not
-- 'draft') and be rejected. Never a state where the batch reads as both
-- "updated" and "finalized", never a torn snapshot.
-- ============================================================================
do $$
declare
  v_busy boolean;
  v_b_failed boolean := false; v_b_error text;
  v_final record;
  v_line_count integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A finalizes batch_c2 (expected_version=1, its fresh-draft value) — sent
  -- async, held OPEN (no commit yet), holding the row's FOR UPDATE lock.
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.finalize_settlement_batch('%s'::uuid, 1, '%s'::jsonb, null, null, null)$sql$,
    current_setting('p7cc.batch_c2'), jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7cc.order_c2')))::text
  ));
  perform public._p7cc_wait_ready('conn_a');
  perform id from dblink_get_result('conn_a', true) as t(id uuid, settlement_number text, row_version bigint);
  perform public._p7cc_drain_pending('conn_a');
  -- A's finalize has RUN (status flipped to finalized inside A's own
  -- transaction) but A's TRANSACTION is still open — nothing committed yet.

  -- B concurrently tries to update the SAME batch using the SAME pre-
  -- finalize expected_version (1) — its own `for update` genuinely blocks
  -- on A's still-uncommitted row lock.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.update_draft_settlement_batch('%s'::uuid, 1, null, null, 'C race update', null, true, false)$sql$,
    current_setting('p7cc.batch_c2')
  ));

  v_busy := public._p7cc_wait_busy('conn_b');
  assert v_busy, 'FAIL C: تحديث المسودة (B) لم يُحجب رغم أن اعتماد A ما زال مفتوحًا ويحمل قفل الصف غير الملتزم على نفس الدفعة';

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p7cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, row_version bigint);
    perform public._p7cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL C: تحديث المسودة (B) كان يجب أن يُرفض بعد أن رأى الدفعة معتمدة (finalized) وليست مسودة، لكنه نجح — تحديث ضائع (lost update) على دفعة معتمدة';
  assert v_b_error like '%اعتمادها%', format('FAIL C: كان يجب رفض التحديث تحديدًا بسبب أن الدفعة لم تعد مسودة، لكن الخطأ الفعلي كان: %s', v_b_error);

  -- Single consistent end state: finalized, never touched by B's update
  -- (provider_statement_reference is still NULL — B's write never landed).
  select * into v_final from public.get_settlement_batch(current_setting('p7cc.batch_c2')::uuid);
  assert v_final.status = 'finalized', format('FAIL C: يجب أن تكون الدفعة finalized بعد نجاح A، الموجود: %s', v_final.status);
  assert v_final.provider_statement_reference is null, format('FAIL C: مرجع كشف مزوّد الدفعة يجب أن يبقى NULL — تحديث B المرفوض لم يكن يجب أن يُطبَّق أبدًا، الموجود: %s', v_final.provider_statement_reference);

  select count(*) into v_line_count from public.get_settlement_batch(current_setting('p7cc.batch_c2')::uuid) b, jsonb_array_elements(b.lines) l;
  assert v_line_count = 1, format('FAIL C: يجب أن يوجد سطر واحد بالضبط من اعتماد A، الموجود: %s', v_line_count);

  raise notice 'PASS C: finalize vs update_draft_settlement_batch() on the SAME batch — B genuinely blocked on A''s open row lock, then deterministically rejected once it observed status=finalized (not draft) — single consistent end state, never a lost update';
end $$;

-- ============================================================================
-- D — Double finalize_settlement_batch() on the SAME batch id (batch_d),
-- both calls selecting the same source (order_d). Exactly one must win
-- (draft->finalized); the other must be genuinely blocked by the same
-- settlement_batches row lock proven in C, then cleanly rejected — never
-- double-finalized, never two sets of settlement_batch_lines.
-- ============================================================================
do $$
declare
  v_busy boolean;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_final record;
  v_line_count integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A finalizes batch_d and stays OPEN — holds the row's FOR UPDATE lock.
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.finalize_settlement_batch('%s'::uuid, 1, '%s'::jsonb, null, null, null)$sql$,
    current_setting('p7cc.batch_d'), jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7cc.order_d')))::text
  ));
  perform public._p7cc_wait_ready('conn_a');
  begin
    perform id from dblink_get_result('conn_a', true) as t(id uuid, settlement_number text, row_version bigint);
    perform public._p7cc_drain_pending('conn_a');
  exception when others then
    v_a_failed := true;
  end;

  -- B races the SAME batch id (and the same source token) concurrently
  -- while A's transaction is still open — must genuinely block on A's row
  -- lock, not run to completion independently.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.finalize_settlement_batch('%s'::uuid, 1, '%s'::jsonb, null, null, null)$sql$,
    current_setting('p7cc.batch_d'), jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7cc.order_d')))::text
  ));

  v_busy := public._p7cc_wait_busy('conn_b');
  assert v_busy, 'FAIL D: محاولة الاعتماد الثانية (B) لنفس الدفعة لم تُحجب رغم أن اعتماد A ما زال مفتوحًا ويحمل قفل الصف غير الملتزم';

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p7cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, settlement_number text, row_version bigint);
    perform public._p7cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;
  perform dblink_disconnect('conn_b');

  assert (v_a_failed or v_b_failed), 'FAIL D: إحدى محاولتي الاعتماد المتزامنتين لنفس الدفعة يجب أن تُرفض';
  assert not (v_a_failed and v_b_failed), 'FAIL D: إحدى محاولتي الاعتماد على الأقل يجب أن تنجح';

  select * into v_final from public.get_settlement_batch(current_setting('p7cc.batch_d')::uuid);
  assert v_final.status = 'finalized', format('FAIL D: يجب أن تنتهي الدفعة بحالة finalized واحدة فقط، الموجود: %s', v_final.status);

  select count(*) into v_line_count from public.get_settlement_batch(current_setting('p7cc.batch_d')::uuid) b, jsonb_array_elements(b.lines) l;
  assert v_line_count = 1, format('FAIL D: يجب أن يوجد سطر واحد بالضبط (لا مجموعتان من السطور من اعتماد مزدوج)، الموجود: %s', v_line_count);

  raise notice 'PASS D: double finalize_settlement_batch() on the SAME batch — exactly one wins (draft->finalized), the other genuinely blocked then cleanly rejected, never double-finalized, never two sets of lines';
end $$;

-- ============================================================================
-- E — Route fee version writer (create_settlement_route_fee_version(),
-- EXCLUSIVE Settlement Master lock) vs finalize_settlement_batch() on a
-- batch using that SAME route (SHARED Settlement Master lock). A holds the
-- EXCLUSIVE lock open across its whole transaction while it writes a brand
-- new fee version; B's finalize must genuinely block acquiring the SHARED
-- lock, then — once A commits — resolve the NEW fee version WHOLE (never a
-- half-written mix of the old strategy with the new percentage/fixed
-- figures, and never the reverse).
-- ============================================================================
do $$
declare
  v_busy boolean;
  v_new_fee_id uuid;
  v_final record;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A writes a brand new fee version on route-e (route_formula, fixed fee
  -- 12.3400 — exercises §18's 4dp precision — batch fee 5.00) — this call
  -- ITSELF completes and returns inside A's transaction (nothing else is
  -- contending for the EXCLUSIVE lock yet), but A's TRANSACTION stays open,
  -- so the EXCLUSIVE advisory xact lock (pg_advisory_xact_lock, released
  -- only at commit/rollback) is still held throughout.
  perform dblink_send_query('conn_a', format(
    $sql$select public.create_settlement_route_fee_version('%s'::uuid, public.business_today(), 'route_formula', 'fixed', null, 12.3400, 5.00, null, 'p7cc race E new fee')$sql$,
    current_setting('p7cc.route_e')
  ));
  perform public._p7cc_wait_ready('conn_a');
  select fee_id into v_new_fee_id from dblink_get_result('conn_a', true) as t(fee_id uuid);
  perform public._p7cc_drain_pending('conn_a');
  assert v_new_fee_id is not null, 'FAIL E: إنشاء إصدار الرسوم الجديد (A) كان يجب أن ينجح ويُرجع معرّفًا';

  -- B concurrently finalizes batch_e (on the SAME route) — its own
  -- acquire_settlement_master_lock_shared() must genuinely block while A's
  -- EXCLUSIVE lock is still held (transaction still open).
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.finalize_settlement_batch('%s'::uuid, 1, '%s'::jsonb, null, null, null)$sql$,
    current_setting('p7cc.batch_e'), jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7cc.order_e')))::text
  ));

  v_busy := public._p7cc_wait_busy('conn_b');
  assert v_busy, 'FAIL E: اعتماد الدفعة (B) لم يُحجب رغم أن كتابة إصدار الرسوم (A) ما زالت مفتوحة وتحمل قفل بيانات التسوية الرئيسي الحصري';

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p7cc_wait_ready('conn_b');
  perform id from dblink_get_result('conn_b', true) as t(id uuid, settlement_number text, row_version bigint);
  perform public._p7cc_drain_pending('conn_b');
  perform dblink_disconnect('conn_b');

  -- The finalize that was BLOCKED then UNBLOCKED must resolve the fully-
  -- committed NEW fee version whole — strategy/model/fixed_fee/batch_fee
  -- ALL from the new row, never a stale/torn mix with the old source_
  -- snapshot/0 version that was active before A's write.
  select * into v_final from public.get_settlement_batch(current_setting('p7cc.batch_e')::uuid);
  assert v_final.transaction_fee_strategy = 'route_formula', format('FAIL E: يجب أن تعكس الدفعة استراتيجية الإصدار الجديد المُلتزَم بالكامل (route_formula)، الموجود: %s', v_final.transaction_fee_strategy);
  assert v_final.transaction_fixed_fee = '12.3400', format('FAIL E: يجب أن تعكس الدفعة الرسم الثابت الجديد بدقة 4 منازل عشرية (12.3400)، الموجود: %s', v_final.transaction_fixed_fee);
  -- 0191 §26 renamed this field original_batch_fee (permanent historical
  -- fact, never zeroed by cancellation) — batch_e is not cancelled, so it
  -- still simply reflects the batch fee snapshot at finalize time.
  assert v_final.original_batch_fee = '5.00', format('FAIL E: يجب أن تعكس الدفعة رسم الدفعة الجديد (5.00)، الموجود: %s', v_final.original_batch_fee);

  raise notice 'PASS E: route fee version writer (EXCLUSIVE Settlement Master lock) vs Finalization (SHARED) — B genuinely blocked until A''s new fee version fully committed, then resolved it WHOLE (strategy/fixed_fee/batch_fee all from the new row), never a half-written mix';
end $$;

-- ============================================================================
-- F — Daily Close (close_sales_day(), EXCLUSIVE daily-close lock) vs
-- Finalization on a batch dated the SAME store/day (acquire_daily_close_
-- lock_shared(), 0185 §11). A holds finalize's transaction open (so its
-- SHARED lock stays held); B's close_sales_day() must genuinely block on
-- the EXCLUSIVE acquisition until A commits. The actor deliberately lacks
-- settlements.process_closed_day, so finalize's own SUCCESS here is itself
-- the proof it observed the day as NOT YET closed (had it seen the day
-- closed, it would have raised for lack of that permission instead).
-- ============================================================================
do $$
declare
  v_busy boolean;
  v_close_failed boolean := false;
  v_close_error text;
  v_final record;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A finalizes batch_f (store_f's only line) — this acquires the SHARED
  -- daily-close lock for (store_f, business_today()) before checking
  -- daily_closings, and holds it open (transaction not yet committed).
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.finalize_settlement_batch('%s'::uuid, 1, '%s'::jsonb, null, null, null)$sql$,
    current_setting('p7cc.batch_f'), jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7cc.order_f')))::text
  ));
  perform public._p7cc_wait_ready('conn_a');
  perform id from dblink_get_result('conn_a', true) as t(id uuid, settlement_number text, row_version bigint);
  perform public._p7cc_drain_pending('conn_a');
  -- A's finalize SUCCEEDED (no exception) with settlements.process_closed_
  -- day withheld from this actor — proof it saw the day as still open.

  -- B concurrently tries to CLOSE store_f's day — needs the EXCLUSIVE lock
  -- for the SAME (store, date) — must genuinely block while A is open.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.close_sales_day('%s'::uuid, public.business_today(), 'P7CC race F close')$sql$,
    current_setting('p7cc.store_f')
  ));

  v_busy := public._p7cc_wait_busy('conn_b');
  assert v_busy, 'FAIL F: إغلاق اليوم (B) لم يُحجب رغم أن اعتماد A ما زال مفتوحًا ويحمل قفل إغلاق اليوم المشترك لنفس المتجر/اليوم';

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p7cc_wait_ready('conn_b');
  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    perform public._p7cc_drain_pending('conn_b');
  exception when others then
    v_close_failed := true;
    v_close_error := sqlerrm;
  end;
  perform dblink_disconnect('conn_b');

  assert not v_close_failed, format('FAIL F: إغلاق اليوم كان يجب أن ينجح بعد التزام A (لا سبب حقيقي للرفض هنا) — الخطأ الفعلي: %s', coalesce(v_close_error, ''));

  select * into v_final from public.get_settlement_batch(current_setting('p7cc.batch_f')::uuid);
  assert v_final.status = 'finalized', format('FAIL F: يجب أن تكون الدفعة finalized، الموجود: %s', v_final.status);
  assert exists (select 1 from public.daily_closings where store_id = current_setting('p7cc.store_f')::uuid and business_date = public.business_today()),
    'FAIL F: اليوم لم يُقفل فعليًا لمتجر F بعد نجاح close_sales_day()';

  raise notice 'PASS F: Daily Close (EXCLUSIVE) vs Finalization (SHARED daily-close lock) — B genuinely blocked on A''s open shared lock; A''s finalize succeeded WITHOUT settlements.process_closed_day, proving it saw the day as not-yet-closed; B then closed the day cleanly once A committed';
end $$;

-- ============================================================================
-- G — Daily Close (EXCLUSIVE) vs record_settlement_bank_movement() (also
-- SHARED daily-close lock, keyed on the MOVEMENT's own business date,
-- 0188 §12) on batch_g's FIRST movement. Same guarantee as F: the actor
-- lacks settlements.process_closed_day, so the movement's own SUCCESS here
-- is itself proof it observed the day as not-yet-closed.
-- ============================================================================
do $$
declare
  v_busy boolean;
  v_close_failed boolean := false;
  v_close_error text;
  v_movement_count integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A records batch_g's first bank movement — acquires the SHARED daily-
  -- close lock for (store_g, business_today()) and holds it open.
  perform dblink_send_query('conn_a', format(
    $sql$select public.record_settlement_bank_movement('%s'::uuid, public.business_today(), 240.00, 'REF-P7CC-G-RACE', null)$sql$,
    current_setting('p7cc.batch_g')
  ));
  perform public._p7cc_wait_ready('conn_a');
  perform x from dblink_get_result('conn_a', true) as t(x uuid);
  perform public._p7cc_drain_pending('conn_a');
  -- A's record SUCCEEDED (no exception) with settlements.process_closed_
  -- day withheld — proof it saw the day as still open.

  -- B concurrently tries to CLOSE store_g's day — must genuinely block.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.close_sales_day('%s'::uuid, public.business_today(), 'P7CC race G close')$sql$,
    current_setting('p7cc.store_g')
  ));

  v_busy := public._p7cc_wait_busy('conn_b');
  assert v_busy, 'FAIL G: إغلاق اليوم (B) لم يُحجب رغم أن تسجيل الحركة البنكية (A) ما زال مفتوحًا ويحمل قفل إغلاق اليوم المشترك لنفس المتجر/اليوم';

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p7cc_wait_ready('conn_b');
  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    perform public._p7cc_drain_pending('conn_b');
  exception when others then
    v_close_failed := true;
    v_close_error := sqlerrm;
  end;
  perform dblink_disconnect('conn_b');

  assert not v_close_failed, format('FAIL G: إغلاق اليوم كان يجب أن ينجح بعد التزام A — الخطأ الفعلي: %s', coalesce(v_close_error, ''));

  select count(*) into v_movement_count from public.get_settlement_batch(current_setting('p7cc.batch_g')::uuid) b, jsonb_array_elements(b.bank_movements) m;
  assert v_movement_count = 1, format('FAIL G: يجب أن توجد حركة بنكية واحدة بالضبط على الدفعة، الموجود: %s', v_movement_count);
  assert exists (select 1 from public.daily_closings where store_id = current_setting('p7cc.store_g')::uuid and business_date = public.business_today()),
    'FAIL G: اليوم لم يُقفل فعليًا لمتجر G بعد نجاح close_sales_day()';

  raise notice 'PASS G: Daily Close (EXCLUSIVE) vs record_settlement_bank_movement() (SHARED daily-close lock) — B genuinely blocked on A''s open shared lock; A''s movement succeeded WITHOUT settlements.process_closed_day, proving it saw the day as not-yet-closed; B then closed the day cleanly once A committed';
end $$;

-- ============================================================================
-- H — Two concurrent reverse_settlement_bank_movement() calls on the SAME
-- bank movement event. Only one succeeds (0174's UNIQUE bank_movement_
-- event_id, 0179's own documented "layer 2"). (Spec §29 letter H — this
-- file's own original second scenario, predating the §29 lettering.)
-- ============================================================================
do $$
declare
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_reversal_count integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A reverses the event (holds the event row''s FOR UPDATE lock,
  -- reverse_settlement_bank_movement()'s own opening statement, 0179) and
  -- stays open — genuine overlap, not sequential.
  perform dblink_send_query('conn_a', format(
    $sql$select public.reverse_settlement_bank_movement('%s'::uuid, public.business_today(), 'عكس أول (سباق H) — تزامن تسويات 7')$sql$,
    current_setting('p7cc.event_c')
  ));
  perform public._p7cc_wait_ready('conn_a');
  begin
    perform x from dblink_get_result('conn_a', true) as t(x uuid);
    perform public._p7cc_drain_pending('conn_a');
  exception when others then
    v_a_failed := true;
  end;

  -- B races the SAME event concurrently while A's transaction is still
  -- open (A's own call already returned above, but has not committed) —
  -- B's own FOR UPDATE attempt on the same event row genuinely blocks.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.reverse_settlement_bank_movement('%s'::uuid, public.business_today(), 'عكس ثانٍ (سباق H) — تزامن تسويات 7')$sql$,
    current_setting('p7cc.event_c')
  ));
  perform public._p7cc_wait_busy('conn_b');

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p7cc_wait_ready('conn_b');
  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    perform public._p7cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;
  perform dblink_disconnect('conn_b');

  assert (v_a_failed or v_b_failed), 'FAIL H: إحدى محاولتي عكس الحركة البنكية المتزامنتين يجب أن تُرفض';
  assert not (v_a_failed and v_b_failed), 'FAIL H: إحدى محاولتي العكس على الأقل يجب أن تنجح';

  select count(*) into v_reversal_count from public.get_settlement_batch(current_setting('p7cc.batch_c')::uuid) b, jsonb_array_elements(b.bank_movements) m
    where (m ->> 'id') = current_setting('p7cc.event_c') and (m ->> 'reversed')::boolean = true;
  assert v_reversal_count = 1, format('FAIL H: يجب أن توجد حركة عكسية واحدة بالضبط للحركة البنكية المتنازع عليها — الموجود: %s', v_reversal_count);

  raise notice 'PASS H: two concurrent reverse_settlement_bank_movement() calls on the SAME event — exactly one succeeds (max-one-reversal UNIQUE constraint), the other genuinely blocks on the row lock then is cleanly rejected on re-check';
end $$;

-- ============================================================================
-- I — reconcile_settlement_batch() vs a concurrent record_settlement_bank_
-- movement() insert on the SAME batch (batch_i, already finalized+
-- zero-variance-ready by the fixture: ONE movement recorded there already
-- exactly matches expected_bank_settlement). Both RPCs open with `select
-- ... for update` on settlement_batches (0180/0188) — the same row-lock
-- mechanism C/D/K all rely on. A reconciles and stays open; B's SECOND
-- movement attempt must genuinely block, then — once unblocked — observe
-- status='reconciled' and be cleanly rejected (0188 §13's reconciled-
-- blocks-new-movements rule) — never a movement recorded after
-- reconciliation that reconciled_at's own actual/variance never accounted
-- for.
-- ============================================================================
do $$
declare
  v_busy boolean;
  v_b_failed boolean := false; v_b_error text;
  v_final record;
  v_movement_count integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A reconciles batch_i (zero variance — the fixture's one movement
  -- already matches expected_bank_settlement exactly, so plain
  -- settlements.reconcile suffices, no reconcile_variance needed) and
  -- stays OPEN — holds the row's FOR UPDATE lock.
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.reconcile_settlement_batch('%s'::uuid, 2, null)$sql$,
    current_setting('p7cc.batch_i')
  ));
  perform public._p7cc_wait_ready('conn_a');
  perform id from dblink_get_result('conn_a', true) as t(id uuid, row_version bigint, actual_bank_movement text, variance text);
  perform public._p7cc_drain_pending('conn_a');

  -- B concurrently tries to record a SECOND bank movement on the SAME
  -- batch — its own `for update` genuinely blocks on A's still-open lock.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.record_settlement_bank_movement('%s'::uuid, public.business_today(), 50.00, 'REF-P7CC-I2', null)$sql$,
    current_setting('p7cc.batch_i')
  ));

  v_busy := public._p7cc_wait_busy('conn_b');
  assert v_busy, 'FAIL I: تسجيل الحركة البنكية الثانية (B) لم يُحجب رغم أن المطابقة (A) ما زالت مفتوحة وتحمل قفل الصف غير الملتزم';

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p7cc_wait_ready('conn_b');
  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    perform public._p7cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL I: تسجيل الحركة الثانية (B) كان يجب أن يُرفض بعد أن رأى الدفعة مُطابَقة (reconciled) — لا يجوز تسجيل حركة بعد المطابقة';
  assert v_b_error like '%مُطابَقة%', format('FAIL I: كان يجب رفض التسجيل تحديدًا بسبب أن الدفعة مُطابَقة بالفعل، لكن الخطأ الفعلي كان: %s', v_b_error);

  select * into v_final from public.get_settlement_batch(current_setting('p7cc.batch_i')::uuid);
  assert v_final.status = 'reconciled', format('FAIL I: يجب أن تكون الدفعة reconciled بعد نجاح A، الموجود: %s', v_final.status);

  select count(*) into v_movement_count from public.get_settlement_batch(current_setting('p7cc.batch_i')::uuid) b, jsonb_array_elements(b.bank_movements) m;
  assert v_movement_count = 1, format('FAIL I: يجب أن توجد حركة بنكية واحدة بالضبط (محاولة B المرفوضة لم تُسجَّل)، الموجود: %s', v_movement_count);

  raise notice 'PASS I: reconcile_settlement_batch() vs record_settlement_bank_movement() on the SAME batch — B genuinely blocked on A''s open row lock, then deterministically rejected once it observed status=reconciled — no movement ever recorded after reconciliation, no lost update';
end $$;

-- ============================================================================
-- J — Cancel (releasing settlement_source_claims) vs a second finalize
-- attempting to claim that SAME source via a NEW draft batch. batch_j_x is
-- already finalized (holding the sole active claim on order_j); this race
-- cancels batch_j_x (releasing its claim) while conn_b's finalize on the
-- FRESH batch_j_y tries to claim order_j — genuinely overlapping A's still-
-- open (uncommitted) cancel, so B is first proven to see the source as
-- still claimed (Postgres MVCC never allows a dirty read of another
-- session's uncommitted UPDATE), then retried AFTER A's commit, where it
-- must succeed. Never a window where the source is claimed by TWO active
-- claims at once (settlement_source_claims_active_unique_idx, 0173) —
-- verified directly against the table afterward.
-- ============================================================================
do $$
declare
  v_b_first_failed boolean := false; v_b_first_error text;
  v_b_second_failed boolean := false;
  v_available_count integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A cancels batch_j_x (zero bank movements — nothing to reverse first)
  -- and stays OPEN — its release UPDATE on settlement_source_claims is not
  -- yet committed, therefore invisible to any other session's plain read.
  perform dblink_send_query('conn_a', format(
    $sql$select public.cancel_settlement_batch('%s'::uuid, %s::bigint, public.business_today(), 'p7cc race J cancel')$sql$,
    current_setting('p7cc.batch_j_x'), current_setting('p7cc.batch_j_x_version')
  ));
  perform public._p7cc_wait_ready('conn_a');
  perform x from dblink_get_result('conn_a', true) as t(x uuid);
  perform public._p7cc_drain_pending('conn_a');
  -- A's cancel has RUN inside its own transaction but is still UNCOMMITTED.

  -- B, genuinely concurrently (while A's release is still uncommitted),
  -- tries to finalize the FRESH batch_j_y claiming the SAME source. The
  -- layer-1 availability check is a plain, non-locking read (never blocks
  -- on another session's uncommitted write) — the proof of genuine overlap
  -- is that this whole call executes and is fully drained BEFORE conn_a is
  -- committed below, so it can only ever see the PRE-release state.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  begin
    perform id from dblink('conn_b', format(
      $sql$select * from public.finalize_settlement_batch('%s'::uuid, 1, '%s'::jsonb, null, null, null)$sql$,
      current_setting('p7cc.batch_j_y'), jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7cc.order_j')))::text
    )) as t(id uuid, settlement_number text, row_version bigint);
  exception when others then
    v_b_first_failed := true;
    v_b_first_error := sqlerrm;
  end;

  assert v_b_first_failed, 'FAIL J: محاولة الاعتماد الأولى (B) على المصدر أثناء إلغاء A غير الملتزم كان يجب أن تُرفض — رأت المصدر ما زال مُطالَبًا به (لا قراءة قذرة)';
  assert v_b_first_error like '%لم تعد متاحة%', format('FAIL J: كان يجب رفض المحاولة الأولى تحديدًا بسبب عدم توفر المصدر، لكن الخطأ الفعلي كان: %s', v_b_first_error);

  -- Confirm order_j still reads as claimed (unavailable) while A's cancel
  -- remains uncommitted.
  select count(*) into v_available_count from public.list_unsettled_settlement_sources(
    current_setting('p7cc.route')::uuid, public.business_today() - 1, public.business_today() + 1
  ) where source_kind = 'sale' and source_event_id = current_setting('p7cc.order_j')::uuid;
  assert v_available_count = 0, format('FAIL J: المصدر يجب أن يبقى غير متاح ما دام إلغاء A لم يُلتزم بعد، الموجود: %s صف متاح', v_available_count);

  -- A commits — the release is now fully visible.
  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  -- B retries the SAME finalize call now that the release is fully
  -- committed — must succeed this time.
  begin
    perform id from dblink('conn_b', format(
      $sql$select * from public.finalize_settlement_batch('%s'::uuid, 1, '%s'::jsonb, null, null, null)$sql$,
      current_setting('p7cc.batch_j_y'), jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', current_setting('p7cc.order_j')))::text
    )) as t(id uuid, settlement_number text, row_version bigint);
  exception when others then
    v_b_second_failed := true;
  end;
  perform dblink_disconnect('conn_b');

  assert not v_b_second_failed, 'FAIL J: إعادة محاولة الاعتماد (B) بعد التزام إلغاء A كان يجب أن تنجح فعليًا — المصدر أصبح متاحًا الآن';

  raise notice 'PASS J: cancel-vs-reclaim race on the SAME source — B genuinely saw the source as still-claimed while A''s release was uncommitted (rejected), then succeeded only once A''s release fully committed';
end $$;

-- Direct table-level proof (this do block does NOT set role — runs as the
-- trusted superuser connection, bypassing RLS entirely — appropriate here
-- since settlement_source_claims_active_unique_idx, 0173, is a DB-level
-- constraint, not a permission concern): order_j must be held by EXACTLY
-- ONE active (unreleased) claim after the J race above — never two at once.
do $$
declare v_active_count integer;
begin
  select count(*) into v_active_count
  from public.settlement_source_claims
  where source_kind = 'sale' and source_event_id = current_setting('p7cc.order_j')::uuid and released_at is null;
  if v_active_count <> 1 then
    raise exception 'FAIL J: يجب أن توجد مطالبة نشطة واحدة بالضبط على المصدر بعد السباق (settlement_source_claims_active_unique_idx) — الموجود: %', v_active_count;
  end if;
  raise notice 'PASS J (invariant): settlement_source_claims_active_unique_idx held — exactly % active claim for order_j after the cancel-then-reclaim race, verified directly against the table', v_active_count;
end $$;

-- ============================================================================
-- K — cancel_settlement_batch() vs a concurrent record_settlement_bank_
-- movement() insert on the SAME batch (batch_k, already finalized with
-- zero movements). Both RPCs open with `select ... for update` on
-- settlement_batches — the same row-lock mechanism C/D/I rely on. A
-- cancels (batch has zero movements, so nothing to reverse first — cancel
-- succeeds) and stays open; B's movement insert must genuinely block, then
-- — once unblocked — observe the cancellation and be cleanly rejected
-- (0188's cancelled-batch rejection) — never a cancelled batch left with an
-- active movement recorded after cancellation.
-- ============================================================================
do $$
declare
  v_busy boolean;
  v_b_failed boolean := false; v_b_error text;
  v_final record;
  v_movement_count integer;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p7cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A cancels batch_k (zero movements — trivially satisfies the "every
  -- movement already reversed" requirement) and stays OPEN — holds the
  -- row's FOR UPDATE lock.
  perform dblink_send_query('conn_a', format(
    $sql$select public.cancel_settlement_batch('%s'::uuid, %s::bigint, public.business_today(), 'p7cc race K cancel')$sql$,
    current_setting('p7cc.batch_k'), current_setting('p7cc.batch_k_version')
  ));
  perform public._p7cc_wait_ready('conn_a');
  perform x from dblink_get_result('conn_a', true) as t(x uuid);
  perform public._p7cc_drain_pending('conn_a');

  -- B concurrently tries to record a NEW bank movement on the SAME batch —
  -- its own `for update` genuinely blocks on A's still-open lock.
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"a7100000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select public.record_settlement_bank_movement('%s'::uuid, public.business_today(), 55.00, 'REF-P7CC-K1', null)$sql$,
    current_setting('p7cc.batch_k')
  ));

  v_busy := public._p7cc_wait_busy('conn_b');
  assert v_busy, 'FAIL K: تسجيل الحركة البنكية (B) لم يُحجب رغم أن الإلغاء (A) ما زال مفتوحًا ويحمل قفل الصف غير الملتزم';

  perform dblink_exec('conn_a', 'commit');
  perform dblink_disconnect('conn_a');

  perform public._p7cc_wait_ready('conn_b');
  begin
    perform x from dblink_get_result('conn_b', true) as t(x uuid);
    perform public._p7cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
    v_b_error := sqlerrm;
  end;
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL K: تسجيل الحركة (B) كان يجب أن يُرفض بعد أن رأى الدفعة مُلغاة — لا يجوز تسجيل حركة بنكية جديدة على دفعة مُلغاة';
  assert v_b_error like '%مُلغاة%', format('FAIL K: كان يجب رفض التسجيل تحديدًا بسبب أن الدفعة مُلغاة، لكن الخطأ الفعلي كان: %s', v_b_error);

  select * into v_final from public.get_settlement_batch(current_setting('p7cc.batch_k')::uuid);
  assert v_final.effective_status = 'cancelled', format('FAIL K: يجب أن تكون الحالة الفعلية cancelled بعد نجاح A، الموجود: %s', v_final.effective_status);
  assert v_final.cancelled_at is not null, 'FAIL K: يجب أن يكون تاريخ الإلغاء مسجّلًا بعد نجاح A';

  select count(*) into v_movement_count from public.get_settlement_batch(current_setting('p7cc.batch_k')::uuid) b, jsonb_array_elements(b.bank_movements) m;
  assert v_movement_count = 0, format('FAIL K: يجب ألا توجد أي حركة بنكية على دفعة مُلغاة (محاولة B المرفوضة لم تُسجَّل)، الموجود: %s', v_movement_count);

  raise notice 'PASS K: cancel_settlement_batch() vs record_settlement_bank_movement() on the SAME batch — B genuinely blocked on A''s open row lock, then deterministically rejected once it observed the batch cancelled — never a cancelled batch left with an active unreversed movement recorded after cancellation';
end $$;

-- ============================================================================
-- Cleanup — DELIBERATELY PARTIAL, mirroring shipping_core_phase5_
-- concurrency.test.sql's own posture rather than sales_returns_concurrency.
-- test.sql's full teardown: settlement_batches/settlement_batch_lines/
-- settlement_source_claims/settlement_bank_movement_events/_reversals are
-- ALL unconditionally trigger-protected against UPDATE/DELETE (0172-0175)
-- with NO escape hatch at all — "no hard delete, ever" is this module's own
-- explicit design (0172's header). That makes every settlement_batches row
-- created above (and transitively its settlement_route/sales_order/store,
-- all ON DELETE RESTRICT) permanently un-deletable too. Only the parts of
-- this file's own footprint that CAN be cleanly removed are removed below;
-- the helper functions are dropped in every case. This file is therefore
-- only safe to run against a genuinely throwaway database (see the header).
-- ============================================================================
drop function if exists public._p7cc_wait_busy(text, int, numeric);
drop function if exists public._p7cc_wait_ready(text, int, numeric);
drop function if exists public._p7cc_drain_pending(text);

do $$ begin
  raise notice 'ALL settlements_phase7_concurrency.test.sql ASSERTIONS PASSED (A-K)';
end $$;

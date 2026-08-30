-- ============================================================================
-- Phase 7 Integrity Patch 7.1 — PRE-upgrade fixture (§34 item C). Runs
-- against a database that has migrations 0001-0183 (the ORIGINAL Phase 7
-- Settlements Core delivery's end state) + the real supabase/seed.sql
-- applied — i.e. BEFORE any Patch 7.1 migration (0184+) exists. Builds REAL
-- Settlement data using the OLD (pre-Patch-7.1) 0169-0183 RPC/schema
-- contracts exactly as a real production database would already have
-- accumulated by the time Patch 7.1 ships:
--
--   1. One settlement route (payment_collection, payment_method=cash,
--      collection_channel=NULL — under 0176's OLD matching rule a NULL
--      route channel is a wildcard for Sale/Adjustment sources AND the
--      mandatory shape for Return sources, so ONE route can legitimately
--      claim both kinds below) + one 'none'-strategy fee version (fee=0,
--      so expected_bank_settlement == gross exactly, keeping every
--      assertion below arithmetic-free/unambiguous).
--   2. A DRAFT batch — reserves nothing (item 18), no lines/claims/
--      movements at all. Proves an empty/unfinalized batch also survives
--      untouched.
--   3. A FINALIZED batch claiming a 'return_refund' source — the OLD
--      (0176) source_kind for an approved Sales Return, RETAINED (never
--      removed) by 0184's widened check constraint solely so pre-existing
--      rows like this one stay valid forever, even though 0184+'s adapter
--      never emits that kind again (0184 §1/§2, replaced by
--      'return_refund_event'). This is the single most direct proof this
--      migration's compatibility promise actually holds.
--   4. A RECONCILED batch (finalize -> record a zero-variance bank
--      movement -> reconcile) claiming a 'sale' source.
--   5. A CANCELLED batch (finalize -> record a bank movement -> REVERSE it
--      -> cancel, per item 33's "every movement already reversed"
--      precondition) claiming a 'sale' source — also the fixture's one
--      bank movement + its reversal (settlement_bank_movement_events +
--      settlement_bank_movement_reversals), and its settlement_source_
--      claims row is a RELEASED (not active) claim.
--
-- None of this uses any Patch-7.1-era (0184+) schema/RPC — none exists yet
-- at this migration number. The entire point is proving 0184-0191 (a) never
-- mutate any of these pre-existing rows in settlement_batches/settlement_
-- batch_lines/settlement_bank_movement_events/_reversals/settlement_batch_
-- cancellations/settlement_source_claims/settlement_route_fee_versions, and
-- (b) the NEW (0191) get_settlement_batch()/list_settlement_batches() still
-- read this OLD-shape data back correctly.
--
-- Results are recorded in a PERMANENT (non-temp) scratch table,
-- public.p71u_scratch, mirroring public.p7u_scratch's exact convention
-- (supabase/tests/fixtures/phase7_upgrade_pre_fixture.sql) — a simple
-- (label text primary key, value text) pair table — so they survive into
-- the separate psql invocation that applies 0184-0191 and the separate
-- psql invocation that runs the actual post-upgrade assertions. Every
-- pre-existing row of interest also gets its own to_jsonb(row)::text
-- snapshot recorded here (label suffixed '_json') — the post-upgrade test
-- re-snapshots the SAME row the SAME way and asserts byte-identical
-- equality, not merely "still exists"/"count unchanged".
--
-- NOTE: this script is deliberately NOT wrapped in begin/rollback (its data
-- must be COMMITTED, not rolled back) and psql runs each top-level
-- statement in its own implicit transaction, so SET LOCAL (transaction-
-- scoped) cannot be used here — plain SET (session-scoped) is used instead,
-- exactly like phase7_upgrade_pre_fixture.sql/patch_6_1_upgrade_pre_fixture.sql.
-- ============================================================================

create table if not exists public.p71u_scratch (label text primary key, value text);

insert into auth.users (id, email) values
  ('f7100000-0000-4000-8000-000000000001', 'test-p71u-admin@example.invalid')
  on conflict do nothing;

update public.profiles set full_name = 'P71U Upgrade Fixture Admin', status = 'active', store_access_scope = 'all'
  where id = 'f7100000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select 'f7100000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

set role authenticated;
set request.jwt.claims = '{"sub":"f7100000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 1. Master data + route + fee version.
-- ---------------------------------------------------------------------------
do $$
declare
  v_store_id uuid; v_karat_id uuid; v_category_id uuid;
  v_pm_cash uuid; v_channel_id uuid;
  v_route_id uuid; v_fee_version_id uuid;
begin
  insert into public.stores (code, name_ar, status) values ('P71CST', 'فرع ترقية 7.1 (C)', 'active') returning id into v_store_id;
  insert into public.karats (code, name_ar, sort_order, status) values ('P71CK', 'عيار ترقية 7.1', 981, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p71ccat', 'تصنيف ترقية 7.1', 981, 'active') returning id into v_category_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 280.0000, 'f7100000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'p71c fixture');

  select id into v_pm_cash from public.payment_methods where key = 'cash';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';

  -- payment_collection route, channel = NULL (0176's OLD matching rule:
  -- NULL route channel is a wildcard for Sale, and mandatory for Return —
  -- see header). 'none' fee strategy => every line's fee is forced to 0,
  -- so expected_bank_settlement == gross exactly for every batch below.
  select public.create_settlement_route('p71c-cash-route', 'مسار نقد ترقية 7.1 (C)', 'payment_collection', 'P71C Cash Route', v_pm_cash) into v_route_id;
  select public.create_settlement_route_fee_version(v_route_id, public.business_today(), 'none') into v_fee_version_id;

  perform set_config('p71c.store_id', v_store_id::text, false);
  perform set_config('p71c.karat_id', v_karat_id::text, false);
  perform set_config('p71c.category_id', v_category_id::text, false);
  perform set_config('p71c.pm_cash_id', v_pm_cash::text, false);
  perform set_config('p71c.channel_id', v_channel_id::text, false);
  perform set_config('p71c.route_id', v_route_id::text, false);
  perform set_config('p71c.fee_version_id', v_fee_version_id::text, false);

  insert into public.p71u_scratch values ('store_id', v_store_id::text);
  insert into public.p71u_scratch values ('route_id', v_route_id::text);
  insert into public.p71u_scratch values ('fee_version_id', v_fee_version_id::text);

  raise notice 'P71C SETUP OK: store=%, route=% (payment_collection, cash, channel=NULL, fee=none), fee_version=%', v_store_id, v_route_id, v_fee_version_id;
end $$;

-- ---------------------------------------------------------------------------
-- 2. DRAFT batch — reserves nothing at all (item 18).
-- ---------------------------------------------------------------------------
do $$
declare v_batch record;
begin
  select * into v_batch from public.create_draft_settlement_batch(
    current_setting('p71c.route_id')::uuid, public.business_today(), 'REF-P71C-DRAFT', 'مسودة اختبار ترقية 7.1 — بلا مصادر'
  );
  perform set_config('p71c.batch_draft_id', v_batch.id::text, false);
  insert into public.p71u_scratch values ('batch_draft_id', v_batch.id::text);
  insert into public.p71u_scratch values ('batch_draft_number', v_batch.settlement_number);
  raise notice 'P71C DRAFT BATCH OK: id=% number=%', v_batch.id, v_batch.settlement_number;
end $$;

-- ---------------------------------------------------------------------------
-- 3. FINALIZED batch claiming a 'return_refund' source (OLD 0176 source
--    kind, retained-but-never-emitted-again per 0184 §1/§2).
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_item_id uuid; v_subtotal numeric; v_sale_row_version bigint;
  v_return record; v_return_gross numeric; v_return_fee numeric;
  v_batch record; v_final record;
begin
  select * into v_order from public.create_sales_order(
    current_setting('p71c.store_id')::uuid, public.business_today(),
    current_setting('p71c.pm_cash_id')::uuid, current_setting('p71c.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p71c.category_id')::uuid, 'karat_id', current_setting('p71c.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 300.00)),
    'عميل ترقية 7.1 (C) — إرجاع', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  v_sale_row_version := (public.get_sales_order(v_order.id) ->> 'row_version')::bigint;
  v_item_id := (public.get_sales_order(v_order.id) -> 'items' -> 0 ->> 'id')::uuid;
  assert v_subtotal = 300.00, format('BUG fixture setup: expected order subtotal=300.00, got %s', v_subtotal);

  select * into v_return from public.create_sales_return(
    v_order.id, current_setting('p71c.store_id')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار ترقية 7.1 (C) — إرجاع كامل')),
    v_sale_row_version, 'collected', v_subtotal
  );
  perform public.approve_sales_return(v_return.id, (public.get_sales_return(v_return.id) ->> 'row_version')::bigint);

  v_return_gross := (public.get_sales_return(v_return.id) ->> 'sales_revenue_reversal_amount')::numeric;
  v_return_fee := (public.get_sales_return(v_return.id) ->> 'payment_fee_reversal_amount')::numeric;
  assert v_return_gross = 300.00, format('BUG fixture setup: expected return gross=300.00, got %s', v_return_gross);
  assert v_return_fee = 0.00, format('BUG fixture setup: expected return fee=0.00 (cash), got %s', v_return_fee);

  select * into v_batch from public.create_draft_settlement_batch(
    current_setting('p71c.route_id')::uuid, public.business_today(), 'REF-P71C-FIN', 'دفعة مُعتمَدة اختبار ترقية 7.1 — مصدر إرجاع (return_refund)'
  );
  select * into v_final from public.finalize_settlement_batch(
    v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'return_refund', 'source_event_id', v_return.id)), null, null, null
  );

  perform set_config('p71c.order_return_id', v_order.id::text, false);
  perform set_config('p71c.return_id', v_return.id::text, false);
  perform set_config('p71c.batch_finalized_id', v_batch.id::text, false);

  insert into public.p71u_scratch values ('order_return_id', v_order.id::text);
  insert into public.p71u_scratch values ('order_return_number', v_order.order_number);
  insert into public.p71u_scratch values ('return_id', v_return.id::text);
  insert into public.p71u_scratch values ('return_number', v_return.return_number);
  insert into public.p71u_scratch values ('return_gross', v_return_gross::text);
  insert into public.p71u_scratch values ('batch_finalized_id', v_batch.id::text);
  insert into public.p71u_scratch values ('batch_finalized_number', v_batch.settlement_number);
  insert into public.p71u_scratch values ('batch_finalized_expected_gross', (-v_return_gross)::text);

  raise notice 'P71C FINALIZED BATCH (return_refund source) OK: batch=% number=% return=% (gross=-%)', v_batch.id, v_batch.settlement_number, v_return.return_number, v_return_gross;
end $$;

-- ---------------------------------------------------------------------------
-- 4. RECONCILED batch claiming a 'sale' source: finalize -> zero-variance
--    bank movement -> reconcile.
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_subtotal numeric;
  v_batch record; v_final record; v_move_id uuid; v_recon record;
begin
  select * into v_order from public.create_sales_order(
    current_setting('p71c.store_id')::uuid, public.business_today(),
    current_setting('p71c.pm_cash_id')::uuid, current_setting('p71c.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p71c.category_id')::uuid, 'karat_id', current_setting('p71c.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 500.00)),
    'عميل ترقية 7.1 (C) — مطابقة', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  assert v_subtotal = 500.00, format('BUG fixture setup: expected order subtotal=500.00, got %s', v_subtotal);

  select * into v_batch from public.create_draft_settlement_batch(
    current_setting('p71c.route_id')::uuid, public.business_today(), 'REF-P71C-RECON', 'دفعة مُطابَقة اختبار ترقية 7.1'
  );
  select * into v_final from public.finalize_settlement_batch(
    v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null
  );

  select public.record_settlement_bank_movement(v_batch.id, public.business_today(), 500.00, 'BANKREF-P71C-RECON', 'حركة مطابقة تمامًا (بلا فرق)') into v_move_id;

  select * into v_recon from public.reconcile_settlement_batch(v_batch.id, v_final.row_version);
  assert v_recon.variance::numeric = 0, format('BUG fixture setup: expected zero variance on reconcile, got %s', v_recon.variance);

  perform set_config('p71c.order_recon_id', v_order.id::text, false);
  perform set_config('p71c.batch_reconciled_id', v_batch.id::text, false);
  perform set_config('p71c.move_reconciled_id', v_move_id::text, false);

  insert into public.p71u_scratch values ('order_recon_id', v_order.id::text);
  insert into public.p71u_scratch values ('order_recon_number', v_order.order_number);
  insert into public.p71u_scratch values ('batch_reconciled_id', v_batch.id::text);
  insert into public.p71u_scratch values ('batch_reconciled_number', v_batch.settlement_number);
  insert into public.p71u_scratch values ('batch_reconciled_expected_gross', v_subtotal::text);
  insert into public.p71u_scratch values ('move_reconciled_id', v_move_id::text);

  raise notice 'P71C RECONCILED BATCH (sale source) OK: batch=% number=% sale=% movement=% variance=%', v_batch.id, v_batch.settlement_number, v_order.order_number, v_move_id, v_recon.variance;
end $$;

-- ---------------------------------------------------------------------------
-- 5. CANCELLED batch claiming a 'sale' source: finalize -> bank movement ->
--    REVERSE that movement (item 33's precondition) -> cancel. This is also
--    the fixture's one bank-movement + reversal pair, and leaves a RELEASED
--    (not active) settlement_source_claims row.
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_subtotal numeric;
  v_batch record; v_final record; v_move_id uuid; v_reversal_id uuid; v_cancel_id uuid;
begin
  select * into v_order from public.create_sales_order(
    current_setting('p71c.store_id')::uuid, public.business_today(),
    current_setting('p71c.pm_cash_id')::uuid, current_setting('p71c.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('p71c.category_id')::uuid, 'karat_id', current_setting('p71c.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 600.00)),
    'عميل ترقية 7.1 (C) — إلغاء', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  assert v_subtotal = 600.00, format('BUG fixture setup: expected order subtotal=600.00, got %s', v_subtotal);

  select * into v_batch from public.create_draft_settlement_batch(
    current_setting('p71c.route_id')::uuid, public.business_today(), 'REF-P71C-CANCEL', 'دفعة مُلغاة اختبار ترقية 7.1'
  );
  select * into v_final from public.finalize_settlement_batch(
    v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null
  );

  select public.record_settlement_bank_movement(v_batch.id, public.business_today(), 600.00, 'BANKREF-P71C-CANCEL', 'حركة قبل الإلغاء') into v_move_id;
  select public.reverse_settlement_bank_movement(v_move_id, public.business_today(), 'اختبار ترقية 7.1 — عكس تمهيدًا للإلغاء') into v_reversal_id;

  -- settlement_batches carries ZERO SELECT RLS policies for `authenticated`
  -- (item 41) — a raw re-SELECT here would silently return 0 rows, not an
  -- error, leaving row_version NULL. record_settlement_bank_movement()/
  -- reverse_settlement_bank_movement() (0179) never touch settlement_
  -- batches.row_version at all (only finalize/reconcile/cancel do), so
  -- v_final.row_version (already known from finalize_settlement_batch's own
  -- return value) is still the correct expected_version for cancel.
  select public.cancel_settlement_batch(v_batch.id, v_final.row_version, public.business_today(), 'اختبار ترقية 7.1 — إلغاء بعد عكس الحركة البنكية') into v_cancel_id;

  perform set_config('p71c.order_cancel_id', v_order.id::text, false);
  perform set_config('p71c.batch_cancelled_id', v_batch.id::text, false);
  perform set_config('p71c.move_cancelled_id', v_move_id::text, false);
  perform set_config('p71c.reversal_cancelled_id', v_reversal_id::text, false);
  perform set_config('p71c.cancellation_id', v_cancel_id::text, false);

  insert into public.p71u_scratch values ('order_cancel_id', v_order.id::text);
  insert into public.p71u_scratch values ('order_cancel_number', v_order.order_number);
  insert into public.p71u_scratch values ('batch_cancelled_id', v_batch.id::text);
  insert into public.p71u_scratch values ('batch_cancelled_number', v_batch.settlement_number);
  insert into public.p71u_scratch values ('batch_cancelled_expected_gross', v_subtotal::text);
  insert into public.p71u_scratch values ('move_cancelled_id', v_move_id::text);
  insert into public.p71u_scratch values ('reversal_cancelled_id', v_reversal_id::text);
  insert into public.p71u_scratch values ('cancellation_id', v_cancel_id::text);

  raise notice 'P71C CANCELLED BATCH (sale source) OK: batch=% number=% sale=% movement=% reversal=% cancellation=%', v_batch.id, v_batch.settlement_number, v_order.order_number, v_move_id, v_reversal_id, v_cancel_id;
end $$;

-- ---------------------------------------------------------------------------
-- 6. "Byte-identical" snapshots — one to_jsonb(row)::text per row of
--    interest, taken as postgres (bypasses RLS; every one of these 7 tables
--    has ZERO SELECT policies for `authenticated`, item 41) — so the
--    post-upgrade test can re-snapshot the SAME row the SAME way and assert
--    textual equality, not merely "still exists"/"count unchanged".
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;

do $$
begin
  insert into public.p71u_scratch
    select 'route_row_json', to_jsonb(r)::text from public.settlement_routes r where r.id = current_setting('p71c.route_id')::uuid;
  insert into public.p71u_scratch
    select 'fee_version_row_json', to_jsonb(v)::text from public.settlement_route_fee_versions v where v.id = current_setting('p71c.fee_version_id')::uuid;

  insert into public.p71u_scratch
    select 'batch_draft_row_json', to_jsonb(b)::text from public.settlement_batches b where b.id = current_setting('p71c.batch_draft_id')::uuid;

  insert into public.p71u_scratch
    select 'batch_finalized_row_json', to_jsonb(b)::text from public.settlement_batches b where b.id = current_setting('p71c.batch_finalized_id')::uuid;
  insert into public.p71u_scratch
    select 'batch_finalized_line_row_json', to_jsonb(l)::text from public.settlement_batch_lines l where l.settlement_batch_id = current_setting('p71c.batch_finalized_id')::uuid;
  insert into public.p71u_scratch
    select 'batch_finalized_claim_row_json', to_jsonb(c)::text from public.settlement_source_claims c
      where c.settlement_batch_id = current_setting('p71c.batch_finalized_id')::uuid;

  insert into public.p71u_scratch
    select 'batch_reconciled_row_json', to_jsonb(b)::text from public.settlement_batches b where b.id = current_setting('p71c.batch_reconciled_id')::uuid;
  insert into public.p71u_scratch
    select 'batch_reconciled_line_row_json', to_jsonb(l)::text from public.settlement_batch_lines l where l.settlement_batch_id = current_setting('p71c.batch_reconciled_id')::uuid;
  insert into public.p71u_scratch
    select 'move_reconciled_row_json', to_jsonb(e)::text from public.settlement_bank_movement_events e where e.id = current_setting('p71c.move_reconciled_id')::uuid;

  insert into public.p71u_scratch
    select 'batch_cancelled_row_json', to_jsonb(b)::text from public.settlement_batches b where b.id = current_setting('p71c.batch_cancelled_id')::uuid;
  insert into public.p71u_scratch
    select 'batch_cancelled_line_row_json', to_jsonb(l)::text from public.settlement_batch_lines l where l.settlement_batch_id = current_setting('p71c.batch_cancelled_id')::uuid;
  insert into public.p71u_scratch
    select 'move_cancelled_row_json', to_jsonb(e)::text from public.settlement_bank_movement_events e where e.id = current_setting('p71c.move_cancelled_id')::uuid;
  insert into public.p71u_scratch
    select 'reversal_cancelled_row_json', to_jsonb(rv)::text from public.settlement_bank_movement_reversals rv where rv.id = current_setting('p71c.reversal_cancelled_id')::uuid;
  insert into public.p71u_scratch
    select 'cancellation_row_json', to_jsonb(cx)::text from public.settlement_batch_cancellations cx where cx.id = current_setting('p71c.cancellation_id')::uuid;

  raise notice 'P71C byte-identical snapshots recorded into public.p71u_scratch (13 row snapshots + scalar labels).';
end $$;

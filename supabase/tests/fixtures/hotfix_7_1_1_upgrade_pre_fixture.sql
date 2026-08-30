-- ============================================================================
-- Phase 7 — Final Integrity Hotfix 7.1.1 — PRE-upgrade fixture (§20 item D).
-- Runs against a database that has migrations 0001-0191 (the ORIGINAL Patch
-- 7.1 Settlements Core end state) + the real supabase/seed.sql applied —
-- i.e. BEFORE any Hotfix 7.1.1 migration (0192+) exists. Builds REAL
-- Settlement data using the OLD (pre-Hotfix) 0169-0191 RPC/schema contracts
-- exactly as a real production database would already have accumulated by
-- the time Hotfix 7.1.1 ships — in particular, a return_fee_reversal source
-- CLAIMED under the OLD (buggy) hardcoded-NULL-channel matching rule, which
-- §1/§3 of this hotfix corrects going forward. The entire point of this
-- fixture is proving 0192-0196 (a) never mutate any EXISTING claim/line/
-- batch row created under the old matching rule (existing claims are
-- permanent facts, never re-evaluated), and (b) every NEW hotfix-only
-- capability (preview batch-fee override, draft ownership check, store-
-- scope enforcement on lifecycle writes, reconcile redaction, fee-resolver
-- lockdown, narrow filter lookups) works correctly against this OLD-shape
-- data once 0192-0196 land on top.
--
--   1. A settlement route pair: one channel-matched (Sale/Adjustment) route
--      and one NULL-channel (Return) route — the OLD Patch-7.1 shape.
--   2. A Sale (real channel) + full Return (approved, with a real refund
--      event AND a nonzero payment_fee_reversal_amount) — under 0184's OLD
--      matching, return_refund_event/return_fee_reversal BOTH claimed
--      together on the NULL-channel route (the exact shape §1/§3 changes
--      going forward — but this EXISTING claim must never move or vanish).
--   3. A cross-store Adjustment (processing store != original sale's store)
--      claimed in its own finalized batch on the channel route.
--   4. A DRAFT batch (untouched, owned by the fixture admin — used to prove
--      §4's new ownership check on update_draft_settlement_batch() still
--      lets the OWNER edit their own old-shape draft after the upgrade).
--   5. A RECONCILED batch (finalize -> zero-variance bank movement ->
--      reconcile) claiming a plain Sale.
--   6. A CANCELLED batch (finalize -> bank movement -> reverse -> cancel)
--      claiming a plain Sale.
--
-- Results are recorded in a PERMANENT (non-temp) scratch table,
-- public.h711u_scratch, mirroring public.p71u_scratch's exact convention.
--
-- NOTE: deliberately NOT wrapped in begin/rollback (data must be COMMITTED)
-- and psql runs each top-level statement in its own implicit transaction, so
-- plain SET (session-scoped) is used, never SET LOCAL.
-- ============================================================================

create table if not exists public.h711u_scratch (label text primary key, value text);

insert into auth.users (id, email) values
  ('f7110000-0000-4000-8000-000000000001', 'test-h711u-admin@example.invalid')
  on conflict do nothing;

update public.profiles set full_name = 'H711U Upgrade Fixture Admin', status = 'active', store_access_scope = 'all'
  where id = 'f7110000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select 'f7110000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

set role authenticated;
set request.jwt.claims = '{"sub":"f7110000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 1. Master data + two routes (channel-matched + NULL-channel) + fee
--    versions — the OLD Patch-7.1 two-route shape.
-- ---------------------------------------------------------------------------
do $$
declare
  v_store_a uuid; v_store_b uuid; v_karat_id uuid; v_category_id uuid;
  v_pm_visa uuid; v_channel_id uuid;
  v_route_chan uuid; v_route_null uuid;
begin
  insert into public.stores (code, name_ar, status) values ('H711USA', 'فرع ترقية 7.1.1 - أ', 'active') returning id into v_store_a;
  insert into public.stores (code, name_ar, status) values ('H711USB', 'فرع ترقية 7.1.1 - ب', 'active') returning id into v_store_b;
  insert into public.karats (code, name_ar, sort_order, status) values ('H711UK', 'عيار ترقية 7.1.1', 982, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h711ucat', 'تصنيف ترقية 7.1.1', 982, 'active') returning id into v_category_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 280.0000, 'f7110000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'h711u fixture');

  select id into v_pm_visa from public.payment_methods where key = 'tabby';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';

  select public.create_settlement_route('h711u-chan-route', 'مسار قناة ترقية 7.1.1', 'payment_collection', 'H711U Channel Route', v_pm_visa, v_channel_id) into v_route_chan;
  perform public.create_settlement_route_fee_version(v_route_chan, public.business_today(), 'source_snapshot', null, null, null, 5.00, null, 'h711u fee — channel route');

  select public.create_settlement_route('h711u-null-route', 'مسار بدون قناة ترقية 7.1.1', 'payment_collection', 'H711U Null-Channel Route', v_pm_visa) into v_route_null;
  perform public.create_settlement_route_fee_version(v_route_null, public.business_today(), 'source_snapshot', null, null, null, 0, null, 'h711u fee — null-channel route');

  perform set_config('h711u.store_a', v_store_a::text, false);
  perform set_config('h711u.store_b', v_store_b::text, false);
  perform set_config('h711u.karat_id', v_karat_id::text, false);
  perform set_config('h711u.category_id', v_category_id::text, false);
  perform set_config('h711u.pm_visa', v_pm_visa::text, false);
  perform set_config('h711u.channel_id', v_channel_id::text, false);
  perform set_config('h711u.route_chan', v_route_chan::text, false);
  perform set_config('h711u.route_null', v_route_null::text, false);

  insert into public.h711u_scratch values ('store_a', v_store_a::text);
  insert into public.h711u_scratch values ('store_b', v_store_b::text);
  insert into public.h711u_scratch values ('route_chan', v_route_chan::text);
  insert into public.h711u_scratch values ('route_null', v_route_null::text);

  raise notice 'H711U SETUP OK: stores=%/%,  routes chan=% null=%', v_store_a, v_store_b, v_route_chan, v_route_null;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Sale (real channel) + full Return (approved, refund event + nonzero
--    fee reversal) — BOTH return_refund_event AND return_fee_reversal
--    claimed TOGETHER on the NULL-channel route, under the OLD (pre-hotfix)
--    hardcoded-NULL matching rule. This is the exact claim shape that must
--    survive 0192 byte-identical — 0192 only changes future DISCOVERY, it
--    must never reach back and alter an EXISTING claim/line.
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_item_id uuid; v_subtotal numeric; v_fee numeric; v_rv bigint;
  v_return record; v_return_gross numeric; v_return_fee numeric;
  v_refund_event record;
  v_batch record; v_final record;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h711u.store_a')::uuid, public.business_today(),
    current_setting('h711u.pm_visa')::uuid, current_setting('h711u.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h711u.category_id')::uuid, 'karat_id', current_setting('h711u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل ترقية 7.1.1 — إرجاع', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  v_fee := (public.get_sales_order(v_order.id) ->> 'payment_fee_amount')::numeric;
  v_rv := (public.get_sales_order(v_order.id) ->> 'row_version')::bigint;
  v_item_id := (public.get_sales_order(v_order.id) -> 'items' -> 0 ->> 'id')::uuid;
  assert v_fee > 0, format('BUG fixture setup: expected a nonzero visa fee, got %s', v_fee);

  select * into v_return from public.create_sales_return(
    v_order.id, current_setting('h711u.store_a')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار ترقية 7.1.1 — إرجاع كامل')),
    v_rv, 'collected', v_subtotal
  );
  perform public.approve_sales_return(v_return.id, (public.get_sales_return(v_return.id) ->> 'row_version')::bigint);

  v_return_gross := (public.get_sales_return(v_return.id) ->> 'sales_revenue_reversal_amount')::numeric;
  v_return_fee := (public.get_sales_return(v_return.id) ->> 'payment_fee_reversal_amount')::numeric;
  assert v_return_fee > 0, format('BUG fixture setup: expected a nonzero payment_fee_reversal_amount, got %s', v_return_fee);

  select * into v_refund_event from public.record_sales_return_refund(
    v_return.id, v_return_gross, current_setting('h711u.pm_visa')::uuid, public.business_today(), 'استرداد نقدي كامل — اختبار ترقية 7.1.1'
  );

  -- Finalized under the OLD (pre-hotfix) matching rule: both return_refund_
  -- event AND return_fee_reversal claimed TOGETHER on the NULL-channel route
  -- (0184's hardcoded `r.collection_channel_id is null` match for BOTH).
  select * into v_batch from public.create_draft_settlement_batch(
    current_setting('h711u.route_null')::uuid, public.business_today(), 'REF-H711U-RET', 'دفعة مُعتمَدة اختبار ترقية 7.1.1 — إرجاع (نمط قديم)'
  );
  select * into v_final from public.finalize_settlement_batch(
    v_batch.id, 1,
    jsonb_build_array(
      jsonb_build_object('source_kind', 'return_refund_event', 'source_event_id', v_refund_event.id),
      jsonb_build_object('source_kind', 'return_fee_reversal', 'source_event_id', v_return.id)
    ),
    null, null, null
  );

  perform set_config('h711u.order_return', v_order.id::text, false);
  perform set_config('h711u.return_id', v_return.id::text, false);
  perform set_config('h711u.refund_event_id', v_refund_event.id::text, false);
  perform set_config('h711u.batch_return_id', v_batch.id::text, false);

  insert into public.h711u_scratch values ('order_return', v_order.id::text);
  insert into public.h711u_scratch values ('return_id', v_return.id::text);
  insert into public.h711u_scratch values ('return_number', v_return.return_number);
  insert into public.h711u_scratch values ('refund_event_id', v_refund_event.id::text);
  insert into public.h711u_scratch values ('batch_return_id', v_batch.id::text);
  insert into public.h711u_scratch values ('batch_return_number', v_batch.settlement_number);

  raise notice 'H711U OLD-SHAPE RETURN BATCH OK: batch=% number=% return=% (gross=%, fee_reversal=%), BOTH claimed on NULL-channel route per the OLD matching rule', v_batch.id, v_batch.settlement_number, v_return.return_number, v_return_gross, v_return_fee;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Cross-store Adjustment (processing store B != original sale's store A)
--    claimed in its own finalized batch on the channel route (§5/§15 data
--    shape).
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_type_id uuid; v_adj record; v_adjrow record;
  v_batch record; v_final record;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h711u.store_a')::uuid, public.business_today(),
    current_setting('h711u.pm_visa')::uuid, current_setting('h711u.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h711u.category_id')::uuid, 'karat_id', current_setting('h711u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 400.00)),
    'عميل ترقية 7.1.1 — تعديل عبر متاجر', null, null, null
  );

  select public.create_adjustment_type('h711u_service', 'خدمة ترقية 7.1.1') into v_type_id;
  select * into v_adj from public.create_sales_order_adjustment(
    v_order.id, v_type_id, current_setting('h711u.store_b')::uuid, public.business_today(),
    current_setting('h711u.pm_visa')::uuid, current_setting('h711u.channel_id')::uuid,
    true, 80.00, 16.00, 'خدمة ترقية 7.1.1 عبر المتاجر', null, 'REF-H711U-ADJ'
  );
  select * into v_adjrow from public.get_sales_order_adjustment(v_adj.id);
  perform public.approve_sales_order_adjustment(v_adj.id, v_adjrow.row_version, null);

  select * into v_batch from public.create_draft_settlement_batch(
    current_setting('h711u.route_chan')::uuid, public.business_today(), 'REF-H711U-ADJB', 'دفعة تعديل عبر متاجر — اختبار ترقية 7.1.1'
  );
  select * into v_final from public.finalize_settlement_batch(
    v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'adjustment_approved', 'source_event_id', v_adj.id)), null, null, null
  );

  perform set_config('h711u.adj_id', v_adj.id::text, false);
  perform set_config('h711u.batch_adj_id', v_batch.id::text, false);

  insert into public.h711u_scratch values ('adj_id', v_adj.id::text);
  insert into public.h711u_scratch values ('batch_adj_id', v_batch.id::text);
  insert into public.h711u_scratch values ('batch_adj_number', v_batch.settlement_number);

  raise notice 'H711U CROSS-STORE ADJUSTMENT BATCH OK: batch=% number=% adjustment=% (processing=Store B, original sale=Store A)', v_batch.id, v_batch.settlement_number, v_adj.id;
end $$;

-- ---------------------------------------------------------------------------
-- 4. DRAFT batch — owned by the fixture admin, untouched (§4/§10 data
--    shape — proves the NEW ownership check still lets the OWNER edit it).
-- ---------------------------------------------------------------------------
do $$
declare v_batch record;
begin
  select * into v_batch from public.create_draft_settlement_batch(
    current_setting('h711u.route_chan')::uuid, public.business_today(), 'REF-H711U-DRAFT', 'مسودة اختبار ترقية 7.1.1'
  );
  perform set_config('h711u.batch_draft_id', v_batch.id::text, false);
  insert into public.h711u_scratch values ('batch_draft_id', v_batch.id::text);
  insert into public.h711u_scratch values ('batch_draft_number', v_batch.settlement_number);
  raise notice 'H711U DRAFT BATCH OK: id=% number=%', v_batch.id, v_batch.settlement_number;
end $$;

-- ---------------------------------------------------------------------------
-- 5. RECONCILED batch (finalize -> zero-variance bank movement -> reconcile)
--    claiming a plain Sale (§5/§7 data shape).
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_subtotal numeric; v_fee numeric; v_expected numeric;
  v_batch record; v_final record; v_move_id uuid; v_recon record;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h711u.store_a')::uuid, public.business_today(),
    current_setting('h711u.pm_visa')::uuid, current_setting('h711u.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h711u.category_id')::uuid, 'karat_id', current_setting('h711u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 500.00)),
    'عميل ترقية 7.1.1 — مطابقة', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  v_fee := (public.get_sales_order(v_order.id) ->> 'payment_fee_amount')::numeric;

  select * into v_batch from public.create_draft_settlement_batch(
    current_setting('h711u.route_chan')::uuid, public.business_today(), 'REF-H711U-RECON', 'دفعة مُطابَقة اختبار ترقية 7.1.1'
  );
  select * into v_final from public.finalize_settlement_batch(
    v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null
  );
  -- route_chan is source_snapshot (fee=sale's own snapshot) + batch_fee_
  -- fixed=5.00 (set above) -> expected_bank_settlement = gross - fee - 5.00.
  v_expected := v_subtotal - v_fee - 5.00;

  select public.record_settlement_bank_movement(v_batch.id, public.business_today(), v_expected, 'BANKREF-H711U-RECON', 'حركة مطابقة تمامًا') into v_move_id;

  select * into v_recon from public.reconcile_settlement_batch(v_batch.id, v_final.row_version);
  assert v_recon.variance::numeric = 0, format('BUG fixture setup: expected zero variance on reconcile, got %s', v_recon.variance);

  perform set_config('h711u.batch_reconciled_id', v_batch.id::text, false);
  perform set_config('h711u.move_reconciled_id', v_move_id::text, false);

  insert into public.h711u_scratch values ('batch_reconciled_id', v_batch.id::text);
  insert into public.h711u_scratch values ('batch_reconciled_number', v_batch.settlement_number);
  insert into public.h711u_scratch values ('move_reconciled_id', v_move_id::text);

  raise notice 'H711U RECONCILED BATCH OK: batch=% number=% movement=% variance=%', v_batch.id, v_batch.settlement_number, v_move_id, v_recon.variance;
end $$;

-- ---------------------------------------------------------------------------
-- 6. CANCELLED batch (finalize -> bank movement -> reverse -> cancel)
--    claiming a plain Sale (§5/§11 data shape).
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_subtotal numeric; v_fee numeric; v_expected numeric;
  v_batch record; v_final record; v_move_id uuid; v_reversal_id uuid; v_cancel_id uuid;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h711u.store_a')::uuid, public.business_today(),
    current_setting('h711u.pm_visa')::uuid, current_setting('h711u.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h711u.category_id')::uuid, 'karat_id', current_setting('h711u.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 600.00)),
    'عميل ترقية 7.1.1 — إلغاء', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  v_fee := (public.get_sales_order(v_order.id) ->> 'payment_fee_amount')::numeric;

  select * into v_batch from public.create_draft_settlement_batch(
    current_setting('h711u.route_chan')::uuid, public.business_today(), 'REF-H711U-CANCEL', 'دفعة مُلغاة اختبار ترقية 7.1.1'
  );
  select * into v_final from public.finalize_settlement_batch(
    v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null
  );
  v_expected := v_subtotal - v_fee - 5.00;

  select public.record_settlement_bank_movement(v_batch.id, public.business_today(), v_expected, 'BANKREF-H711U-CANCEL', 'حركة قبل الإلغاء') into v_move_id;
  select public.reverse_settlement_bank_movement(v_move_id, public.business_today(), 'اختبار ترقية 7.1.1 — عكس تمهيدًا للإلغاء') into v_reversal_id;
  select public.cancel_settlement_batch(v_batch.id, v_final.row_version, public.business_today(), 'اختبار ترقية 7.1.1 — إلغاء بعد عكس الحركة البنكية') into v_cancel_id;

  perform set_config('h711u.batch_cancelled_id', v_batch.id::text, false);
  perform set_config('h711u.move_cancelled_id', v_move_id::text, false);
  perform set_config('h711u.reversal_cancelled_id', v_reversal_id::text, false);
  perform set_config('h711u.cancellation_id', v_cancel_id::text, false);

  insert into public.h711u_scratch values ('batch_cancelled_id', v_batch.id::text);
  insert into public.h711u_scratch values ('batch_cancelled_number', v_batch.settlement_number);
  insert into public.h711u_scratch values ('move_cancelled_id', v_move_id::text);
  insert into public.h711u_scratch values ('reversal_cancelled_id', v_reversal_id::text);
  insert into public.h711u_scratch values ('cancellation_id', v_cancel_id::text);

  raise notice 'H711U CANCELLED BATCH OK: batch=% number=% movement=% reversal=% cancellation=%', v_batch.id, v_batch.settlement_number, v_move_id, v_reversal_id, v_cancel_id;
end $$;

-- ---------------------------------------------------------------------------
-- 7. "Byte-identical" snapshots (as postgres, bypassing RLS).
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;

do $$
begin
  insert into public.h711u_scratch select 'route_chan_row_json', to_jsonb(r)::text from public.settlement_routes r where r.id = current_setting('h711u.route_chan')::uuid;
  insert into public.h711u_scratch select 'route_null_row_json', to_jsonb(r)::text from public.settlement_routes r where r.id = current_setting('h711u.route_null')::uuid;

  insert into public.h711u_scratch select 'batch_return_row_json', to_jsonb(b)::text from public.settlement_batches b where b.id = current_setting('h711u.batch_return_id')::uuid;
  insert into public.h711u_scratch
    select 'batch_return_lines_json', jsonb_agg(to_jsonb(l) order by l.source_kind)::text from public.settlement_batch_lines l where l.settlement_batch_id = current_setting('h711u.batch_return_id')::uuid;
  insert into public.h711u_scratch
    select 'batch_return_claims_json', jsonb_agg(to_jsonb(c) order by c.source_kind)::text from public.settlement_source_claims c where c.settlement_batch_id = current_setting('h711u.batch_return_id')::uuid;

  insert into public.h711u_scratch select 'batch_adj_row_json', to_jsonb(b)::text from public.settlement_batches b where b.id = current_setting('h711u.batch_adj_id')::uuid;
  insert into public.h711u_scratch select 'batch_adj_line_row_json', to_jsonb(l)::text from public.settlement_batch_lines l where l.settlement_batch_id = current_setting('h711u.batch_adj_id')::uuid;

  insert into public.h711u_scratch select 'batch_draft_row_json', to_jsonb(b)::text from public.settlement_batches b where b.id = current_setting('h711u.batch_draft_id')::uuid;

  insert into public.h711u_scratch select 'batch_reconciled_row_json', to_jsonb(b)::text from public.settlement_batches b where b.id = current_setting('h711u.batch_reconciled_id')::uuid;
  insert into public.h711u_scratch select 'move_reconciled_row_json', to_jsonb(e)::text from public.settlement_bank_movement_events e where e.id = current_setting('h711u.move_reconciled_id')::uuid;

  insert into public.h711u_scratch select 'batch_cancelled_row_json', to_jsonb(b)::text from public.settlement_batches b where b.id = current_setting('h711u.batch_cancelled_id')::uuid;
  insert into public.h711u_scratch select 'move_cancelled_row_json', to_jsonb(e)::text from public.settlement_bank_movement_events e where e.id = current_setting('h711u.move_cancelled_id')::uuid;
  insert into public.h711u_scratch select 'reversal_cancelled_row_json', to_jsonb(rv)::text from public.settlement_bank_movement_reversals rv where rv.id = current_setting('h711u.reversal_cancelled_id')::uuid;
  insert into public.h711u_scratch select 'cancellation_row_json', to_jsonb(cx)::text from public.settlement_batch_cancellations cx where cx.id = current_setting('h711u.cancellation_id')::uuid;

  raise notice 'H711U byte-identical snapshots recorded into public.h711u_scratch.';
end $$;

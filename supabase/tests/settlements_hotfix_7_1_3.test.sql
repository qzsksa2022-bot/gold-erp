-- ============================================================================
-- settlements_hotfix_7_1_3.test.sql — Phase 7 Final Pending-Refresh
-- Consistency Hotfix 7.1.3: live SQL regression coverage for the corrected
-- sales_returns.collection_channel_id_snapshot semantics (0197 revised) —
-- it now moves in LOCKSTEP with payment_method_id/source_sale_row_version
-- through a sanctioned refresh_pending_sales_return_from_sale() (0100)
-- call, instead of being pinned forever to its creation-time value.
-- ============================================================================
-- Self-contained: begin;...rollback; — nothing persists. Run against a
-- fresh DB with all migrations (0001-latest, including the REVISED 0197-
-- 0198) + seed.sql applied.
--
-- Covers (spec §9-§10/§13):
--   A) Pending Refresh Scenario A-G — a Return created against Sale V1
--      (Method A/Channel A), the Sale is THEN edited to V2 (Method
--      B/Channel B) while the Return is still pending, approval is
--      rejected until a sanctioned refresh_pending_sales_return_from_
--      sale() call re-syncs BOTH payment_method_id AND (the point of this
--      hotfix) collection_channel_id_snapshot to B/B together — then
--      approval succeeds and Settlement Discovery resolves to Route B/B
--      exclusively, never A/A.
--   B) Post-Approval Historical Stability — continuing from A: reverse the
--      Return, edit the Sale AGAIN to Method C/Channel C (permitted
--      post-reversal, 0084) — both fee-reversal events must stay pinned to
--      B/B (the basis at approval/reversal time), never drift to C/C.
--   C) Multi-Refresh Test — a Return refreshed TWICE (A/A -> B/B -> C/C)
--      before approval ends up on Route C/C exclusively — never A/A or
--      B/B — proving the lockstep mechanism is not a one-shot special
--      case.
--   D) Trusted Direct Mutation Test, re-verified under the corrected
--      trigger: (1) a raw UPDATE that FAKES the sanctioned-refresh shape
--      (status stays 'pending', source_sale_row_version changes) but does
--      NOT actually match the Sale's real current state is rejected, even
--      for service_role; (2) a raw UPDATE attempting to change
--      collection_channel_id_snapshot on a Return that has ALREADY left
--      the pending lifecycle is rejected, even for service_role — mirrors
--      Hotfix 7.1.2's own proof, re-run here to confirm the revision did
--      not weaken it.
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('f7130000-0000-4000-8000-000000000001', 'h713t-admin@example.invalid')
on conflict do nothing;

update public.profiles set full_name = 'H713T Admin', status = 'active', store_access_scope = 'all'
where id = 'f7130000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select 'f7130000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

set role authenticated;
set local request.jwt.claims = '{"sub":"f7130000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- Setup: store/karat/category + THREE fully independent (payment method,
-- collection channel, settlement route) triples — A/B/C — each with a
-- proportional_reversal fee policy so approval always yields a nonzero
-- payment_fee_reversal_amount, needed for a meaningful route-discovery
-- proof at every stage.
-- ---------------------------------------------------------------------------
do $$
declare
  v_store uuid; v_karat_id uuid; v_category_id uuid;
  v_pm_a uuid; v_pm_b uuid; v_pm_c uuid;
  v_chan_a uuid; v_chan_b uuid; v_chan_c uuid;
  v_route_a uuid; v_route_b uuid; v_route_c uuid;
begin
  insert into public.stores (code, name_ar, status) values ('H713TS', 'فرع اختبار 7.1.3', 'active') returning id into v_store;
  insert into public.karats (code, name_ar, sort_order, status) values ('H713TK', 'عيار اختبار 7.1.3', 983, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h713tcat', 'تصنيف اختبار 7.1.3', 983, 'active') returning id into v_category_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 280.0000, 'f7130000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'h713t fixture');

  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, status)
    values ('h713t_pm_a', 'طريقة اختبار 7.1.3 - أ', 'percentage', 'proportional_reversal', 'active') returning id into v_pm_a;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, status)
    values ('h713t_pm_b', 'طريقة اختبار 7.1.3 - ب', 'percentage', 'proportional_reversal', 'active') returning id into v_pm_b;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, status)
    values ('h713t_pm_c', 'طريقة اختبار 7.1.3 - ج', 'percentage', 'proportional_reversal', 'active') returning id into v_pm_c;
  perform public.create_payment_method_fee_version(v_pm_a, 4.00, 0, public.business_today() - 30, 'h713t fee a');
  perform public.create_payment_method_fee_version(v_pm_b, 5.00, 0, public.business_today() - 30, 'h713t fee b');
  perform public.create_payment_method_fee_version(v_pm_c, 6.00, 0, public.business_today() - 30, 'h713t fee c');

  insert into public.collection_channels (key, name_ar, sort_order, status)
    values ('h713t_chan_a', 'قناة اختبار 7.1.3 - أ', 983, 'active') returning id into v_chan_a;
  insert into public.collection_channels (key, name_ar, sort_order, status)
    values ('h713t_chan_b', 'قناة اختبار 7.1.3 - ب', 984, 'active') returning id into v_chan_b;
  insert into public.collection_channels (key, name_ar, sort_order, status)
    values ('h713t_chan_c', 'قناة اختبار 7.1.3 - ج', 985, 'active') returning id into v_chan_c;

  v_route_a := public.create_settlement_route('h713t-route-a', 'مسار اختبار 7.1.3 - أ', 'payment_collection', 'H713T Route A', v_pm_a, v_chan_a);
  v_route_b := public.create_settlement_route('h713t-route-b', 'مسار اختبار 7.1.3 - ب', 'payment_collection', 'H713T Route B', v_pm_b, v_chan_b);
  v_route_c := public.create_settlement_route('h713t-route-c', 'مسار اختبار 7.1.3 - ج', 'payment_collection', 'H713T Route C', v_pm_c, v_chan_c);
  perform public.create_settlement_route_fee_version(v_route_a, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h713t route fee a');
  perform public.create_settlement_route_fee_version(v_route_b, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h713t route fee b');
  perform public.create_settlement_route_fee_version(v_route_c, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h713t route fee c');

  perform set_config('h713t.store', v_store::text, false);
  perform set_config('h713t.karat_id', v_karat_id::text, false);
  perform set_config('h713t.category_id', v_category_id::text, false);
  perform set_config('h713t.pm_a', v_pm_a::text, false);
  perform set_config('h713t.pm_b', v_pm_b::text, false);
  perform set_config('h713t.pm_c', v_pm_c::text, false);
  perform set_config('h713t.chan_a', v_chan_a::text, false);
  perform set_config('h713t.chan_b', v_chan_b::text, false);
  perform set_config('h713t.chan_c', v_chan_c::text, false);
  perform set_config('h713t.route_a', v_route_a::text, false);
  perform set_config('h713t.route_b', v_route_b::text, false);
  perform set_config('h713t.route_c', v_route_c::text, false);

  raise notice 'H713T SETUP OK: store=%, routes a/b/c=%/%/%', v_store, v_route_a, v_route_b, v_route_c;
end $$;

-- ---------------------------------------------------------------------------
-- (A) Pending Refresh Scenario A-G (§9).
-- ---------------------------------------------------------------------------
do $$
declare
  v_order_row record;
  v_order jsonb;
  v_return_row record;
  v_return jsonb;
  v_row_version bigint;
begin
  -- A) Sale Version 1: Method A / Channel A.
  select * into v_order_row from public.create_sales_order(
    current_setting('h713t.store')::uuid, public.business_today(),
    current_setting('h713t.pm_a')::uuid, current_setting('h713t.chan_a')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h713t.category_id')::uuid, 'karat_id', current_setting('h713t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل اختبار 7.1.3 — أ', null, null
  );
  perform set_config('h713t.orderA', v_order_row.id::text, false);
  v_order := public.get_sales_order(v_order_row.id);
  if v_order ->> 'row_version' <> '1' then
    raise exception 'FAIL: fixture assumption — expected a fresh Sale to start at row_version=1, got %', v_order ->> 'row_version';
  end if;

  -- B) Create Pending Return.
  select * into v_return_row from public.create_sales_return(
    v_order_row.id, current_setting('h713t.store')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', (v_order -> 'items' -> 0 ->> 'id')::uuid, 'condition', 'good_resellable', 'item_return_reason', 'اختبار 7.1.3 — أ')),
    (v_order ->> 'row_version')::bigint, 'collected', (v_order ->> 'subtotal')::numeric
  );
  perform set_config('h713t.returnA', v_return_row.id::text, false);

  v_return := public.get_sales_return(v_return_row.id);
  if v_return ->> 'payment_method_id' <> current_setting('h713t.pm_a')
     or (v_return ->> 'source_sale_row_version')::bigint <> 1 then
    raise exception 'FAIL: B — expected payment_method_id=A/source_sale_row_version=1 immediately at creation, got pm=%, ssrv=%', v_return ->> 'payment_method_id', v_return ->> 'source_sale_row_version';
  end if;
  raise notice 'PASS: B — Return created against Sale V1 (Method A), payment_method_id/source_sale_row_version snapshots correct';

  -- C) Update Sale via update_sales_order(): Version 2, Method B / Channel B.
  v_row_version := (v_order ->> 'row_version')::bigint;
  -- NOTE: 'id' is included so update_sales_order() updates the EXISTING
  -- sales_order_item in place rather than replacing it with a new row —
  -- otherwise the Return's sales_order_item_id reference would point at a
  -- removed item and the later sanctioned refresh (step E) would correctly
  -- reject with "تمت إزالة بند... " (established idiom, see
  -- sales_integrity_hotfix_3_2_1.test.sql / sales_returns_core.test.sql).
  perform public.update_sales_order(
    v_order_row.id, current_setting('h713t.pm_b')::uuid, current_setting('h713t.chan_b')::uuid,
    jsonb_build_array(jsonb_build_object('id', (v_order -> 'items' -> 0 ->> 'id')::uuid, 'category_id', current_setting('h713t.category_id')::uuid, 'karat_id', current_setting('h713t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل اختبار 7.1.3 — أ (بعد التعديل الأول)', null, null, null, v_row_version
  );
  v_order := public.get_sales_order(v_order_row.id);
  if v_order ->> 'payment_method_id' <> current_setting('h713t.pm_b') or v_order ->> 'collection_channel_id' <> current_setting('h713t.chan_b') then
    raise exception 'FAIL: C — expected the Sale edit to B/B WHILE the Return is pending to be permitted, got pm=%, chan=%', v_order ->> 'payment_method_id', v_order ->> 'collection_channel_id';
  end if;
  raise notice 'PASS: C — Sale edited to Version 2 (Method B/Channel B) while the Return is still pending';

  -- D) Confirm the Return needs a refresh under the CURRENT contract:
  -- approve_sales_return() rejects it outright (0109's source_sale_row_
  -- version guard, confirmed live in settlements_hotfix_7_1_2.test.sql
  -- section C) until the sanctioned refresh below runs.
  begin
    perform public.approve_sales_return(v_return_row.id, (public.get_sales_return(v_return_row.id) ->> 'row_version')::bigint);
    raise exception 'FAIL: D — expected approve_sales_return() to be REJECTED before a refresh (source_sale_row_version=1 <> Sale''s current row_version=2), but it succeeded';
  exception
    when others then
      if sqlerrm like 'FAIL:%' then raise; end if;
      raise notice 'PASS: D — approve_sales_return() correctly rejects the un-refreshed Return (%), confirming it genuinely needs a sanctioned refresh before it can proceed', sqlerrm;
  end;

  -- E) refresh_pending_sales_return_from_sale() — the ONLY sanctioned path.
  v_return := public.get_sales_return(v_return_row.id);
  perform public.refresh_pending_sales_return_from_sale(v_return_row.id, (v_return ->> 'row_version')::bigint);

  v_return := public.get_sales_return(v_return_row.id);
  if v_return ->> 'payment_method_id' <> current_setting('h713t.pm_b')
     or (v_return ->> 'source_sale_row_version')::bigint <> 2
     or (v_return ->> 'requires_sale_refresh')::boolean <> false then
    raise exception 'FAIL: E — expected payment_method_id=B/source_sale_row_version=2/requires_sale_refresh=false after refresh, got pm=%, ssrv=%, rsr=%', v_return ->> 'payment_method_id', v_return ->> 'source_sale_row_version', v_return ->> 'requires_sale_refresh';
  end if;
  raise notice 'PASS: E (§1/§9 CRITICAL) — refresh_pending_sales_return_from_sale() re-synced the Return to Sale V2 (Method B); payment_method_id and source_sale_row_version now correctly B/2';

  -- F) Approve — must now succeed.
  perform public.approve_sales_return(v_return_row.id, (v_return ->> 'row_version')::bigint);
  v_return := public.get_sales_return(v_return_row.id);
  if v_return ->> 'status' <> 'approved' then
    raise exception 'FAIL: F — expected status=approved after the refreshed Return is approved, got %', v_return ->> 'status';
  end if;
  if (v_return ->> 'payment_fee_reversal_amount')::numeric <= 0 then
    raise exception 'FAIL: fixture assumption broken — need a NONZERO payment_fee_reversal_amount, got %', v_return ->> 'payment_fee_reversal_amount';
  end if;
  raise notice 'PASS: F — approved successfully after the sanctioned refresh; payment_fee_reversal_amount=%', v_return ->> 'payment_fee_reversal_amount';
end $$;

-- G) Settlement Discovery: Route B/Channel B shows the source; Route
-- A/Channel A does not — service_role read for collection_channel_id_
-- snapshot verification (not exposed by any read RPC, same convention as
-- settlements_hotfix_7_1_2.test.sql), then back to authenticated for
-- Discovery itself.
reset role;
reset request.jwt.claims;
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_row record;
begin
  select payment_method_id, collection_channel_id_snapshot into v_row
  from public.sales_returns where id = current_setting('h713t.returnA')::uuid;
  if v_row.payment_method_id is distinct from current_setting('h713t.pm_b')::uuid
     or v_row.collection_channel_id_snapshot is distinct from current_setting('h713t.chan_b')::uuid then
    raise exception 'FAIL: G (CRITICAL) — expected BOTH basis snapshot columns to read B/Channel B together after the sanctioned refresh (lockstep), got pm=%, chan=%', v_row.payment_method_id, v_row.collection_channel_id_snapshot;
  end if;
  raise notice 'PASS: G (§1/§9 CRITICAL) — payment_method_id AND collection_channel_id_snapshot moved TOGETHER to B/Channel B via the sanctioned refresh — no impossible A/B or B/A mismatch';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f7130000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_c record;
begin
  select count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = current_setting('h713t.returnA')::uuid) as on_b
  into v_c
  from public.list_unsettled_settlement_sources(current_setting('h713t.route_b')::uuid, public.business_today() - 5, public.business_today() + 1);
  if v_c.on_b <> 1 then
    raise exception 'FAIL: G — return_fee_reversal must appear on Route B (the Return''s refreshed basis route), got count=%', v_c.on_b;
  end if;

  select count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = current_setting('h713t.returnA')::uuid) as on_a
  into v_c
  from public.list_unsettled_settlement_sources(current_setting('h713t.route_a')::uuid, public.business_today() - 5, public.business_today() + 1);
  if v_c.on_a <> 0 then
    raise exception 'FAIL: G (CRITICAL) — return_fee_reversal must NOT appear on Route A (the Return''s ORIGINAL, pre-refresh basis — abandoned by the sanctioned refresh), got count=%', v_c.on_a;
  end if;

  raise notice 'PASS: G (§9) — Settlement Discovery resolves the refreshed Return exclusively to Route B — never Route A, the abandoned pre-refresh basis';
end $$;

-- ---------------------------------------------------------------------------
-- (B) Post-Approval Historical Stability (§10) — continues from (A): the
-- Return (now on basis B/B) is reversed, then the Sale is edited AGAIN to
-- Method C/Channel C (permitted post-reversal, 0084). Both fee-reversal
-- events must stay pinned to B/B, the basis at approval/reversal time —
-- never drift to C/C, exactly like Hotfix 7.1.2's original A-G proof, now
-- confirmed AFTER a sanctioned refresh occurred earlier in this Return's
-- life (proving the freeze-once-pending-ends guarantee still holds even
-- when the basis itself moved once before freezing).
-- ---------------------------------------------------------------------------
do $$
declare
  v_return jsonb;
  v_order jsonb;
  v_row_version bigint;
begin
  v_return := public.get_sales_return(current_setting('h713t.returnA')::uuid);
  perform public.reverse_sales_return(current_setting('h713t.returnA')::uuid, (v_return ->> 'row_version')::bigint, 'اختبار 7.1.3 — عكس بعد التحديث المُعاد مزامنته', null);
  v_return := public.get_sales_return(current_setting('h713t.returnA')::uuid);
  if v_return ->> 'status' <> 'reversed' then
    raise exception 'FAIL: B1 — expected status=reversed, got %', v_return ->> 'status';
  end if;

  v_order := public.get_sales_order(current_setting('h713t.orderA')::uuid);
  v_row_version := (v_order ->> 'row_version')::bigint;
  perform public.update_sales_order(
    current_setting('h713t.orderA')::uuid, current_setting('h713t.pm_c')::uuid, current_setting('h713t.chan_c')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h713t.category_id')::uuid, 'karat_id', current_setting('h713t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل اختبار 7.1.3 — أ (بعد العكس، تعديل ثانٍ إلى ج)', null, null, null, v_row_version
  );
  v_order := public.get_sales_order(current_setting('h713t.orderA')::uuid);
  if v_order ->> 'payment_method_id' <> current_setting('h713t.pm_c') or v_order ->> 'collection_channel_id' <> current_setting('h713t.chan_c') then
    raise exception 'FAIL: B2 — expected the post-reversal Sale edit to C/C to be permitted, got pm=%, chan=%', v_order ->> 'payment_method_id', v_order ->> 'collection_channel_id';
  end if;
  raise notice 'PASS: B1/B2 — Return reversed, then the Sale edited AGAIN to Method C/Channel C post-reversal (permitted)';
end $$;

do $$
declare v_b record; v_c record;
begin
  select
    count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = current_setting('h713t.returnA')::uuid) as fee_rev,
    count(*) filter (where source_kind = 'return_fee_reversal_reversal' and source_event_id = current_setting('h713t.returnA')::uuid) as fee_rev_rev
  into v_b
  from public.list_unsettled_settlement_sources(current_setting('h713t.route_b')::uuid, public.business_today() - 5, public.business_today() + 1);
  if v_b.fee_rev <> 1 or v_b.fee_rev_rev <> 1 then
    raise exception 'FAIL: B3 (CRITICAL) — Route B (the basis at approval/reversal time) must show BOTH fee events, got return_fee_reversal=%, return_fee_reversal_reversal=%', v_b.fee_rev, v_b.fee_rev_rev;
  end if;

  select count(*) filter (where source_kind in ('return_fee_reversal', 'return_fee_reversal_reversal') and source_event_id = current_setting('h713t.returnA')::uuid) as on_c
  into v_c
  from public.list_unsettled_settlement_sources(current_setting('h713t.route_c')::uuid, public.business_today() - 5, public.business_today() + 1);
  if v_c.on_c <> 0 then
    raise exception 'FAIL: B3 (CRITICAL) — Route C (the Sale''s NEW live route, only reachable post-reversal) must show NEITHER fee event, got count=%', v_c.on_c;
  end if;

  raise notice 'PASS: B3 (§10 CRITICAL) — despite the Sale being edited to C/C AFTER the Return was reversed, both historical fee events remain pinned to Route B (the basis at approval/reversal time) — never drifted to C/C';
end $$;

-- ---------------------------------------------------------------------------
-- (C) Multi-Refresh Test (§13) — a Return refreshed TWICE before approval:
-- A/A -> (refresh) B/B -> (refresh) C/C -> Approve. Final route must be
-- C/C exclusively.
-- ---------------------------------------------------------------------------
do $$
declare
  v_order_row record;
  v_order jsonb;
  v_return_row record;
  v_return jsonb;
  v_row_version bigint;
begin
  select * into v_order_row from public.create_sales_order(
    current_setting('h713t.store')::uuid, public.business_today(),
    current_setting('h713t.pm_a')::uuid, current_setting('h713t.chan_a')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h713t.category_id')::uuid, 'karat_id', current_setting('h713t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 800.00)),
    'عميل اختبار 7.1.3 — تعدد تحديث', null, null
  );
  perform set_config('h713t.orderM', v_order_row.id::text, false);
  v_order := public.get_sales_order(v_order_row.id);

  select * into v_return_row from public.create_sales_return(
    v_order_row.id, current_setting('h713t.store')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', (v_order -> 'items' -> 0 ->> 'id')::uuid, 'condition', 'good_resellable', 'item_return_reason', 'اختبار 7.1.3 — تعدد تحديث')),
    (v_order ->> 'row_version')::bigint, 'collected', (v_order ->> 'subtotal')::numeric
  );
  perform set_config('h713t.returnM', v_return_row.id::text, false);

  -- V1 = A/A (already true at creation). -> V2 = B/B.
  v_row_version := (v_order ->> 'row_version')::bigint;
  perform public.update_sales_order(
    v_order_row.id, current_setting('h713t.pm_b')::uuid, current_setting('h713t.chan_b')::uuid,
    jsonb_build_array(jsonb_build_object('id', (v_order -> 'items' -> 0 ->> 'id')::uuid, 'category_id', current_setting('h713t.category_id')::uuid, 'karat_id', current_setting('h713t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 800.00)),
    'عميل اختبار 7.1.3 — تعدد تحديث (V2)', null, null, null, v_row_version
  );
  v_return := public.get_sales_return(v_return_row.id);
  perform public.refresh_pending_sales_return_from_sale(v_return_row.id, (v_return ->> 'row_version')::bigint);

  v_return := public.get_sales_return(v_return_row.id);
  if v_return ->> 'payment_method_id' <> current_setting('h713t.pm_b') or (v_return ->> 'source_sale_row_version')::bigint <> 2 then
    raise exception 'FAIL: C (first refresh) — expected B/2 after the first refresh, got pm=%, ssrv=%', v_return ->> 'payment_method_id', v_return ->> 'source_sale_row_version';
  end if;

  -- V2 = B/B -> V3 = C/C.
  v_order := public.get_sales_order(v_order_row.id);
  v_row_version := (v_order ->> 'row_version')::bigint;
  perform public.update_sales_order(
    v_order_row.id, current_setting('h713t.pm_c')::uuid, current_setting('h713t.chan_c')::uuid,
    jsonb_build_array(jsonb_build_object('id', (v_order -> 'items' -> 0 ->> 'id')::uuid, 'category_id', current_setting('h713t.category_id')::uuid, 'karat_id', current_setting('h713t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 800.00)),
    'عميل اختبار 7.1.3 — تعدد تحديث (V3)', null, null, null, v_row_version
  );
  v_return := public.get_sales_return(v_return_row.id);
  perform public.refresh_pending_sales_return_from_sale(v_return_row.id, (v_return ->> 'row_version')::bigint);

  v_return := public.get_sales_return(v_return_row.id);
  if v_return ->> 'payment_method_id' <> current_setting('h713t.pm_c') or (v_return ->> 'source_sale_row_version')::bigint <> 3 then
    raise exception 'FAIL: C (second refresh) — expected C/3 after the SECOND refresh, got pm=%, ssrv=%', v_return ->> 'payment_method_id', v_return ->> 'source_sale_row_version';
  end if;
  raise notice 'PASS: C (§13) — Return refreshed TWICE (A/A -> B/B -> C/C), correctly landing on C/3 after the second refresh';

  perform public.approve_sales_return(v_return_row.id, (v_return ->> 'row_version')::bigint);
  v_return := public.get_sales_return(v_return_row.id);
  if v_return ->> 'status' <> 'approved' then
    raise exception 'FAIL: C (approve) — expected status=approved, got %', v_return ->> 'status';
  end if;
end $$;

reset role;
reset request.jwt.claims;
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_row record;
begin
  select payment_method_id, collection_channel_id_snapshot into v_row
  from public.sales_returns where id = current_setting('h713t.returnM')::uuid;
  if v_row.payment_method_id is distinct from current_setting('h713t.pm_c')::uuid
     or v_row.collection_channel_id_snapshot is distinct from current_setting('h713t.chan_c')::uuid then
    raise exception 'FAIL: C (snapshot) — expected the final basis to be C/Channel C after two refreshes, got pm=%, chan=%', v_row.payment_method_id, v_row.collection_channel_id_snapshot;
  end if;
  raise notice 'PASS: C (§13, snapshot) — after two refreshes, both basis columns correctly read C/Channel C together';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f7130000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_c record; v_b record; v_a record;
begin
  select count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = current_setting('h713t.returnM')::uuid) as n
  into v_c from public.list_unsettled_settlement_sources(current_setting('h713t.route_c')::uuid, public.business_today() - 5, public.business_today() + 1);
  select count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = current_setting('h713t.returnM')::uuid) as n
  into v_b from public.list_unsettled_settlement_sources(current_setting('h713t.route_b')::uuid, public.business_today() - 5, public.business_today() + 1);
  select count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = current_setting('h713t.returnM')::uuid) as n
  into v_a from public.list_unsettled_settlement_sources(current_setting('h713t.route_a')::uuid, public.business_today() - 5, public.business_today() + 1);

  if v_c.n <> 1 or v_b.n <> 0 or v_a.n <> 0 then
    raise exception 'FAIL: C (discovery, CRITICAL) — expected the twice-refreshed Return''s fee reversal to appear on Route C ONLY, got onA=%, onB=%, onC=%', v_a.n, v_b.n, v_c.n;
  end if;
  raise notice 'PASS: C (§13, discovery CRITICAL) — the twice-refreshed Return''s settlement source resolves EXCLUSIVELY to Route C — never Route A (the original basis) nor Route B (the intermediate, superseded basis)';
end $$;

-- ---------------------------------------------------------------------------
-- (D) Trusted Direct Mutation Test, re-verified under the corrected trigger
-- (§5/§10 of the Hotfix 7.1.3 spec).
-- ---------------------------------------------------------------------------
do $$
declare
  v_order_row record;
  v_order jsonb;
  v_return_row record;
begin
  select * into v_order_row from public.create_sales_order(
    current_setting('h713t.store')::uuid, public.business_today(),
    current_setting('h713t.pm_a')::uuid, current_setting('h713t.chan_a')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h713t.category_id')::uuid, 'karat_id', current_setting('h713t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 500.00)),
    'عميل اختبار 7.1.3 — تعديل مباشر', null, null
  );
  v_order := public.get_sales_order(v_order_row.id);
  select * into v_return_row from public.create_sales_return(
    v_order_row.id, current_setting('h713t.store')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', (v_order -> 'items' -> 0 ->> 'id')::uuid, 'condition', 'good_resellable', 'item_return_reason', 'اختبار 7.1.3 — تعديل مباشر')),
    (v_order ->> 'row_version')::bigint, 'collected', (v_order ->> 'subtotal')::numeric
  );
  perform set_config('h713t.returnD', v_return_row.id::text, false);
end $$;

-- D1) FAKE sanctioned-refresh shape (status stays 'pending', source_sale_
-- row_version changes) that does NOT actually match the Sale's real
-- current state — must be rejected, even for service_role.
reset role;
reset request.jwt.claims;
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_bug boolean := false;
begin
  begin
    update public.sales_returns
    set source_sale_row_version = 999
    where id = current_setting('h713t.returnD')::uuid and status = 'pending';
    v_bug := true;
  exception when others then
    raise notice 'PASS: D1 (§5/§10 CRITICAL) — a raw UPDATE faking the sanctioned-refresh shape (status stays pending, source_sale_row_version changes) but NOT matching the Sale''s real current row_version was rejected even for service_role — %', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: D1 — a FAKE, incoherent pending-refresh transition was accepted (source_sale_row_version=999 does not match any real Sale state) — the guard trigger does not actually validate against the live Sale row'; end if;
end $$;

-- D2) collection_channel_id_snapshot cannot be mutated directly once the
-- Return has left the pending lifecycle — approve it first, then attempt
-- the mutation.
set role authenticated;
set local request.jwt.claims = '{"sub":"f7130000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_return jsonb;
begin
  v_return := public.get_sales_return(current_setting('h713t.returnD')::uuid);
  perform public.approve_sales_return(current_setting('h713t.returnD')::uuid, (v_return ->> 'row_version')::bigint);
end $$;

reset role;
reset request.jwt.claims;
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_bug boolean := false;
begin
  begin
    update public.sales_returns
    set collection_channel_id_snapshot = current_setting('h713t.chan_c')::uuid
    where id = current_setting('h713t.returnD')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'PASS: D2 (§5/§10) — collection_channel_id_snapshot rejected a direct mutation on a Return that has already left the pending lifecycle (approved), even for service_role — %', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: D2 — collection_channel_id_snapshot was mutated directly on an APPROVED Return via service_role — post-pending-lifecycle immutability is not actually enforced'; end if;
end $$;

-- Sanity check the other direction: an untouched write to a genuinely
-- mutable column is NOT blocked by this trigger.
do $$
begin
  update public.sales_returns set updated_by = updated_by where id = current_setting('h713t.returnD')::uuid;
  raise notice 'PASS: D3 — an unrelated column update (updated_by, same value) is NOT rejected by the guard trigger — its scope remains precisely collection_channel_id_snapshot';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f7130000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
begin
  raise notice '=== ALL settlements_hotfix_7_1_3.test.sql ASSERTIONS PASSED (§5/§9/§10/§13 live regression coverage) ===';
end $$;

rollback;

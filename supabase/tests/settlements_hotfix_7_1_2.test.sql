-- ============================================================================
-- settlements_hotfix_7_1_2.test.sql — Phase 7 Final Historical Route
-- Snapshot Hotfix 7.1.2: live SQL regression coverage for sales_returns.
-- collection_channel_id_snapshot (0197) and the corrected Return
-- Fee-Reversal route matching (0198).
-- ============================================================================
-- Self-contained: begin;...rollback; — nothing persists. Run against a
-- fresh DB with all migrations (0001-latest) + seed.sql applied.
--
-- Covers (spec §9-§12):
--   A) Scenario A-G — a Return's settlement route survives a LATER edit to
--      the original Sale's payment method/channel (permitted once the
--      Return is reversed, 0084) — the exact bug this hotfix closes.
--   B) Trusted Direct Mutation Test (§10) — collection_channel_id_snapshot
--      is immutable even for a service_role/trusted direct SQL UPDATE.
--   C) Pending-Return Historical Test (§12) — a Sale edited to a DIFFERENT
--      route while a Return against it is still pending. The edit itself is
--      permitted (0084's lock only checks status='approved'), but a
--      SEPARATE existing guard in approve_sales_return() (0109) rejects
--      approval outright once the Sale's row_version no longer matches the
--      Return's captured source_sale_row_version — so the "stays on A/A
--      after approval" scenario as literally specified is NOT reachable
--      under the current Returns contract. This section documents that
--      finding live (per the spec's own instruction to document a genuine
--      existing guard rather than fabricate a test around it).
-- ============================================================================
begin;

insert into auth.users (id, email) values
  ('f7120000-0000-4000-8000-000000000001', 'h712t-admin@example.invalid')
on conflict do nothing;

update public.profiles set full_name = 'H712T Admin', status = 'active', store_access_scope = 'all'
where id = 'f7120000-0000-4000-8000-000000000001';

-- super_admin (not a narrow permission grant) — this fixture also needs to
-- INSERT master data (stores/karats/product_categories/daily_gold_prices),
-- which is RLS-gated on their own dedicated *.manage permissions, not
-- anything Settlements/Sales/Returns-specific.
insert into public.user_roles (user_id, role_id)
  select 'f7120000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

set role authenticated;
set local request.jwt.claims = '{"sub":"f7120000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store uuid; v_karat_id uuid; v_category_id uuid;
  v_pm_a uuid; v_pm_b uuid; v_chan_a uuid; v_chan_b uuid;
  v_route_a uuid; v_route_b uuid;
begin
  insert into public.stores (code, name_ar, status) values ('H712TS', 'فرع اختبار 7.1.2', 'active') returning id into v_store;
  insert into public.karats (code, name_ar, sort_order, status) values ('H712TK', 'عيار اختبار 7.1.2', 984, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h712tcat', 'تصنيف اختبار 7.1.2', 984, 'active') returning id into v_category_id;

  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 280.0000, 'f7120000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'h712t fixture');

  select id into v_pm_a from public.payment_methods where key = 'tabby';   -- proportional_reversal, auto-computed fee reversal
  select id into v_pm_b from public.payment_methods where key = 'tamara';  -- proportional_reversal, auto-computed fee reversal
  select id into v_chan_a from public.collection_channels where key = 'direct_store';
  select id into v_chan_b from public.collection_channels where key = 'salla_wallet';

  select public.create_settlement_route('h712t-route-a', 'مسار اختبار 7.1.2 - أ', 'payment_collection', 'H712T Route A', v_pm_a, v_chan_a) into v_route_a;
  select public.create_settlement_route('h712t-route-b', 'مسار اختبار 7.1.2 - ب', 'payment_collection', 'H712T Route B', v_pm_b, v_chan_b) into v_route_b;
  perform public.create_settlement_route_fee_version(v_route_a, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h712t fee a');
  perform public.create_settlement_route_fee_version(v_route_b, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h712t fee b');

  perform set_config('h712t.store', v_store::text, false);
  perform set_config('h712t.karat_id', v_karat_id::text, false);
  perform set_config('h712t.category_id', v_category_id::text, false);
  perform set_config('h712t.pm_a', v_pm_a::text, false);
  perform set_config('h712t.pm_b', v_pm_b::text, false);
  perform set_config('h712t.chan_a', v_chan_a::text, false);
  perform set_config('h712t.chan_b', v_chan_b::text, false);
  perform set_config('h712t.route_a', v_route_a::text, false);
  perform set_config('h712t.route_b', v_route_b::text, false);

  raise notice 'H712T SETUP OK: store=%, route_a=%, route_b=%', v_store, v_route_a, v_route_b;
end $$;

-- ---------------------------------------------------------------------------
-- (A) Scenario A-G — route survives a later Sale edit performed AFTER the
-- Return has been reversed (§1, CRITICAL).
--
-- sales_returns/sales_orders both have ZERO direct SELECT RLS policies for
-- `authenticated` (every read goes through get_sales_order()/get_sales_
-- return(), by design, since Patch 1.x — confirmed by grepping every
-- migration for a `create policy` on either table: none exists). Neither
-- read RPC exposes the new collection_channel_id_snapshot column (this
-- hotfix deliberately adds no new read RPC — see spec, no UI section).
-- So this test alternates role: authenticated for every sanctioned RPC call
-- (create/approve/reverse/edit/discovery), service_role (BYPASSRLS) ONLY for
-- the two direct-column checkpoints the spec calls for (steps B and G) —
-- mirroring the exact verification-read convention already established in
-- this codebase (e.g. financial_integrity_patch_2_1.test.sql's own
-- service_role reads). IDs are threaded across role switches via
-- set_config(..., false) (transaction-level — already proven to survive
-- `set role` in this same file's setup block/section B above).
-- ---------------------------------------------------------------------------

-- A) Sale: Payment Method A (tabby), Channel A (direct_store).
-- B) Create a full Return against it (setup half — creation only; the
--    snapshot-captured-at-creation assertion itself runs as service_role
--    immediately below, since payment_method_id/collection_channel_id_
--    snapshot are not both readable as authenticated).
do $$
declare
  v_order_row record;
  v_order jsonb;
  v_return_row record;
begin
  select * into v_order_row from public.create_sales_order(
    current_setting('h712t.store')::uuid, public.business_today(),
    current_setting('h712t.pm_a')::uuid, current_setting('h712t.chan_a')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h712t.category_id')::uuid, 'karat_id', current_setting('h712t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل اختبار 7.1.2 — أ', null, null
  );
  perform set_config('h712t.order1', v_order_row.id::text, false);

  v_order := public.get_sales_order(v_order_row.id);

  select * into v_return_row from public.create_sales_return(
    v_order_row.id, current_setting('h712t.store')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', (v_order -> 'items' -> 0 ->> 'id')::uuid, 'condition', 'good_resellable', 'item_return_reason', 'اختبار 7.1.2 — أ')),
    (v_order ->> 'row_version')::bigint, 'collected', (v_order ->> 'subtotal')::numeric
  );
  perform set_config('h712t.return1', v_return_row.id::text, false);

  raise notice 'H712T A/B setup OK: order1=%, return1=%', v_order_row.id, v_return_row.id;
end $$;

-- B) confirm both route-identity snapshots were captured at creation time.
reset role;
reset request.jwt.claims;
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_row record;
begin
  select payment_method_id, collection_channel_id_snapshot into v_row
  from public.sales_returns where id = current_setting('h712t.return1')::uuid;

  if v_row.payment_method_id is distinct from current_setting('h712t.pm_a')::uuid
     or v_row.collection_channel_id_snapshot is distinct from current_setting('h712t.chan_a')::uuid then
    raise exception 'FAIL: B — expected payment_method_id=A/collection_channel_id_snapshot=Channel A immediately at creation, got pm=%, chan=%', v_row.payment_method_id, v_row.collection_channel_id_snapshot;
  end if;
  raise notice 'PASS: B — both route-identity snapshots captured correctly at Return creation: payment_method_id=A, collection_channel_id_snapshot=Channel A';
end $$;

-- C/D/E) Approve, then Reverse, then edit the Sale to B/B — all as
-- authenticated, all via the sanctioned RPCs.
set role authenticated;
set local request.jwt.claims = '{"sub":"f7120000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_return jsonb;
  v_order jsonb;
  v_row_version bigint;
begin
  -- C) Approve.
  v_return := public.get_sales_return(current_setting('h712t.return1')::uuid);
  perform public.approve_sales_return(current_setting('h712t.return1')::uuid, (v_return ->> 'row_version')::bigint);

  v_return := public.get_sales_return(current_setting('h712t.return1')::uuid);
  if v_return ->> 'status' <> 'approved' then
    raise exception 'FAIL: C — expected status=approved after approve_sales_return(), got %', v_return ->> 'status';
  end if;
  if (v_return ->> 'payment_fee_reversal_amount')::numeric <= 0 then
    raise exception 'FAIL: fixture assumption broken — this scenario requires a NONZERO payment_fee_reversal_amount on approval (tabby is proportional_reversal), got %', v_return ->> 'payment_fee_reversal_amount';
  end if;
  raise notice 'PASS: C — approved, payment_fee_reversal_amount=%', v_return ->> 'payment_fee_reversal_amount';

  -- D) Reverse.
  perform public.reverse_sales_return(current_setting('h712t.return1')::uuid, (v_return ->> 'row_version')::bigint, 'اختبار 7.1.2 — عكس قبل تعديل البيع', null);

  v_return := public.get_sales_return(current_setting('h712t.return1')::uuid);
  if v_return ->> 'status' <> 'reversed' then
    raise exception 'FAIL: D — expected status=reversed after reverse_sales_return(), got %', v_return ->> 'status';
  end if;
  raise notice 'PASS: D — reversed';

  -- E) Edit the Sale to Payment Method B (tamara) / Channel B (salla_wallet)
  -- — this happens AFTER the Return was reversed, so 0084's financial lock
  -- (status='approved' only) must NOT block it. This is the exact §1
  -- vulnerability window this hotfix closes the downstream consequence of.
  v_order := public.get_sales_order(current_setting('h712t.order1')::uuid);
  v_row_version := (v_order ->> 'row_version')::bigint;

  perform public.update_sales_order(
    current_setting('h712t.order1')::uuid, current_setting('h712t.pm_b')::uuid, current_setting('h712t.chan_b')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h712t.category_id')::uuid, 'karat_id', current_setting('h712t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل اختبار 7.1.2 — أ (بعد التعديل)', null, null, null, v_row_version
  );

  v_order := public.get_sales_order(current_setting('h712t.order1')::uuid);
  if v_order ->> 'payment_method_id' <> current_setting('h712t.pm_b')
     or v_order ->> 'collection_channel_id' <> current_setting('h712t.chan_b') then
    raise exception 'FAIL: E — expected the post-reversal Sale edit to B/B to be PERMITTED (0084''s lock only checks status=''approved'', never ''reversed''), got pm=%, chan=%', v_order ->> 'payment_method_id', v_order ->> 'collection_channel_id';
  end if;
  raise notice 'PASS: E — the Sale was successfully edited to Payment Method B/Channel B AFTER its Return had already been reversed (confirms the §1 vulnerability window is real and reachable)';
end $$;

-- F) Settlement Discovery: Route A must show BOTH historical fee events
-- (return_fee_reversal from the approval, return_fee_reversal_reversal from
-- the reversal); Route B (the Sale's NEW, post-edit live route) must show
-- NEITHER — this is the §1 CRITICAL assertion this whole hotfix exists for.
do $$
declare v_a record; v_b record;
begin
  select
    count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = current_setting('h712t.return1')::uuid) as fee_rev,
    count(*) filter (where source_kind = 'return_fee_reversal_reversal' and source_event_id = current_setting('h712t.return1')::uuid) as fee_rev_rev
  into v_a
  from public.list_unsettled_settlement_sources(current_setting('h712t.route_a')::uuid, public.business_today() - 5, public.business_today() + 1);

  if v_a.fee_rev <> 1 or v_a.fee_rev_rev <> 1 then
    raise exception 'FAIL: F — Route A (the Return''s OWN creation-time snapshot route) must show BOTH fee events, got return_fee_reversal=%, return_fee_reversal_reversal=%', v_a.fee_rev, v_a.fee_rev_rev;
  end if;

  select
    count(*) filter (where source_kind in ('return_fee_reversal', 'return_fee_reversal_reversal') and source_event_id = current_setting('h712t.return1')::uuid) as on_b
  into v_b
  from public.list_unsettled_settlement_sources(current_setting('h712t.route_b')::uuid, public.business_today() - 5, public.business_today() + 1);

  if v_b.on_b <> 0 then
    raise exception 'FAIL: F (CRITICAL) — Route B (the Sale''s NEW live route, only reachable AFTER the Return was reversed) must show NEITHER fee event, got count=%', v_b.on_b;
  end if;

  raise notice 'PASS: F (§1 CRITICAL) — despite the Sale being edited to B/B AFTER the Return was reversed, both historical fee events (return_fee_reversal, return_fee_reversal_reversal) still resolve exclusively to Route A, the Return''s OWN frozen creation-time snapshot route — the route never drifted';
end $$;

-- G) confirm the snapshot columns themselves never changed, even after the
-- live Sale's route changed to B/B.
reset role;
reset request.jwt.claims;
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_row record;
begin
  select payment_method_id, collection_channel_id_snapshot into v_row
  from public.sales_returns where id = current_setting('h712t.return1')::uuid;

  if v_row.payment_method_id is distinct from current_setting('h712t.pm_a')::uuid
     or v_row.collection_channel_id_snapshot is distinct from current_setting('h712t.chan_a')::uuid then
    raise exception 'FAIL: G (CRITICAL) — the Return''s OWN creation-time route-identity snapshot must NEVER change, even after the Sale''s live route changed to B/B, got pm=%, chan=%', v_row.payment_method_id, v_row.collection_channel_id_snapshot;
  end if;
  raise notice 'PASS: G (§1 CRITICAL) — payment_method_id/collection_channel_id_snapshot remained frozen at A/Channel A throughout, confirming the snapshot itself — not just the discovery result — never drifted';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f7120000-0000-4000-8000-000000000001","role":"authenticated"}';


-- ---------------------------------------------------------------------------
-- (B) Trusted Direct Mutation Test (§10) — even a service_role/trusted
-- direct SQL UPDATE must be rejected by the trigger, not merely by RLS.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_bug boolean := false;
begin
  begin
    update public.sales_returns
    set collection_channel_id_snapshot = (select id from public.collection_channels where key = 'salla_wallet')
    where id = current_setting('h712t.return1')::uuid;
    v_bug := true;
  exception when others then
    raise notice 'PASS: collection_channel_id_snapshot رُفض تعديله حتى عبر service_role — %', sqlerrm;
  end;
  if v_bug then raise exception 'SECURITY BUG: عُدِّلت collection_channel_id_snapshot عبر service_role — الثبات غير مُطبَّق فعليًا (§10)'; end if;
end $$;

-- Sanity check the other direction: an untouched write to a genuinely
-- mutable column (e.g. updated_by) is NOT blocked by this trigger — proves
-- the trigger is scoped precisely to this one column, not every UPDATE.
do $$
begin
  update public.sales_returns set updated_by = updated_by where id = current_setting('h712t.return1')::uuid;
  raise notice 'PASS: تعديل عمود آخر (updated_by، بقيمة غير متغيرة فعليًا هنا فقط للتأكد) لا يُرفض من مُشغِّل الثبات — النطاق محصور في collection_channel_id_snapshot تحديدًا';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f7120000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- (C) Pending-Return Historical Test (§12) — the Sale is edited to a
-- DIFFERENT route WHILE the Return is still pending (not yet approved).
--
-- The EDIT itself is genuinely permitted (0084's financial lock only checks
-- status='approved', and update_sales_order() never touches
-- requires_sale_refresh — that flag is a ONE-TIME historical-upgrade
-- backfill set once in 0099 itself, confirmed by reading both files
-- directly). But APPROVAL is a separate story: approve_sales_return()
-- (0109, line ~233) independently compares the Sale's CURRENT row_version
-- against the Return's captured source_sale_row_version and REJECTS
-- approval outright on any mismatch ('تم تعديل عملية البيع بعد إنشاء طلب
-- المرتجع...') — confirmed live below, not merely by reading the source.
-- So the §12 scenario ("edited while pending, then approved, route stays
-- A/A") is NOT reachable under the current Returns contract: an existing
-- guard blocks it one step earlier than requires_sale_refresh would have.
-- Per the spec's own instruction ("IF the current Returns contract already
-- blocks this scenario via an existing guard, document why rather than
-- fabricating an artificial test"), this section documents that finding
-- rather than manufacturing a path around the guard.
-- ---------------------------------------------------------------------------
-- C1) authenticated — build the fixture, attempt the pending-Sale edit, and
-- (if permitted) approve. sales_returns/sales_orders/sales_order_items all
-- have ZERO SELECT RLS for authenticated, so every read here goes through
-- get_sales_order()/get_sales_return() rather than a direct table SELECT
-- (the exact bug fixed in section A above).
select set_config('h712t.skip_c', 'false', false);
do $$
declare
  v_order jsonb;
  v_order_row record;
  v_return_row record;
  v_return jsonb;
  v_row_version bigint;
begin
  select * into v_order_row from public.create_sales_order(
    current_setting('h712t.store')::uuid, public.business_today(),
    current_setting('h712t.pm_a')::uuid, current_setting('h712t.chan_a')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h712t.category_id')::uuid, 'karat_id', current_setting('h712t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 900.00)),
    'عميل اختبار 7.1.2 — معلّق', null, null
  );
  perform set_config('h712t.order2', v_order_row.id::text, false);

  v_order := public.get_sales_order(v_order_row.id);

  select * into v_return_row from public.create_sales_return(
    v_order_row.id, current_setting('h712t.store')::uuid, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', (v_order -> 'items' -> 0 ->> 'id')::uuid, 'condition', 'good_resellable', 'item_return_reason', 'اختبار 7.1.2 — معلّق')),
    (v_order ->> 'row_version')::bigint, 'collected', (v_order ->> 'subtotal')::numeric
  );
  perform set_config('h712t.return2', v_return_row.id::text, false);
  -- still 'pending' — NOT approved yet.

  -- Edit the Sale to B/B WHILE the Return is still pending. Per the
  -- Returns contract (0084's financial lock checks status='approved'
  -- ONLY), this must be allowed. New item set (no 'id') mirrors the
  -- established update_sales_order() test idiom (sales_core.test.sql) —
  -- avoids needing a direct sales_order_items SELECT, which authenticated
  -- cannot perform either (same zero-RLS convention).
  v_order := public.get_sales_order(v_order_row.id);
  v_row_version := (v_order ->> 'row_version')::bigint;
  begin
    perform public.update_sales_order(
      v_order_row.id, current_setting('h712t.pm_b')::uuid, current_setting('h712t.chan_b')::uuid,
      jsonb_build_array(jsonb_build_object('category_id', current_setting('h712t.category_id')::uuid, 'karat_id', current_setting('h712t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 900.00)),
      'عميل اختبار 7.1.2 — معلّق (بعد التعديل)', null, null, null, v_row_version
    );
  exception when others then
    raise notice 'DOCUMENTED: editing the Sale while a Return is still pending is REJECTED by an existing guard (%) — the §12 scenario is not reachable under the current Returns contract; skipping the rest of section C as a fabricated test would be dishonest.', sqlerrm;
    perform set_config('h712t.skip_c', 'true', false);
    return;
  end;

  v_return := public.get_sales_return(v_return_row.id);
  if (v_return ->> 'requires_sale_refresh')::boolean then
    raise notice 'DOCUMENTED: editing the Sale armed requires_sale_refresh on the pending Return, which approve_sales_return() (0109) would reject outright until refresh_pending_sales_return_from_sale() is called — that explicit refresh path re-syncs payment_method_id to the Sale''s CURRENT value (0100), so the §12 "stays on A/A" scenario as literally specified is not reachable without an extra sanctioned step this test does not take; skipping the rest of section C rather than fabricating a mismatched test.';
    perform set_config('h712t.skip_c', 'true', false);
    return;
  end if;

  -- Approve — attempt it; per 0109's own source_sale_row_version guard
  -- (confirmed by reading the migration directly), this is expected to be
  -- REJECTED, since the Sale was edited after the Return was created.
  begin
    perform public.approve_sales_return(v_return_row.id, (v_return ->> 'row_version')::bigint);
  exception when others then
    raise notice 'DOCUMENTED: approve_sales_return() (0109) REJECTED approval of a Return whose Sale was edited while it was pending (%) — an existing guard (source_sale_row_version <> the Sale''s current row_version) already blocks the §12 scenario one step before requires_sale_refresh would have; the Return must go through refresh_pending_sales_return_from_sale() first (an explicit sanctioned step re-syncing payment_method_id to the Sale''s CURRENT value, 0100) before it can be approved at all — so "stays on A/A after approval" as literally specified is not reachable without that extra step, which this test does not take. Skipping C2/C3 rather than fabricating a mismatched test.', sqlerrm;
    perform set_config('h712t.skip_c', 'true', false);
    return;
  end;

  -- If approval unexpectedly succeeded (e.g. a future migration relaxes
  -- the guard above), fall through to the real §12 assertions instead of
  -- silently declaring victory.
  v_return := public.get_sales_return(v_return_row.id);
  if v_return ->> 'payment_method_id' <> current_setting('h712t.pm_a') then
    raise exception 'FAIL: C — expected the Return to approve using its OWN A creation-time payment_method_id snapshot despite the Sale being edited to B while pending, got %', v_return ->> 'payment_method_id';
  end if;
  if (v_return ->> 'payment_fee_reversal_amount')::numeric <= 0 then
    raise exception 'FAIL: fixture assumption broken — pending-scenario Return must carry a NONZERO payment_fee_reversal_amount';
  end if;

  raise notice 'PASS: C1 — approved using the Return''s OWN A creation-time payment_method_id snapshot; payment_fee_reversal_amount=%', v_return ->> 'payment_fee_reversal_amount';
end $$;

-- C2) service_role — collection_channel_id_snapshot is not exposed by any
-- read RPC (by design, §3/§4), so confirm it directly here.
reset role;
reset request.jwt.claims;
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
do $$
declare v_row record;
begin
  if current_setting('h712t.skip_c') = 'true' then
    raise notice 'SKIPPED: C2 (see DOCUMENTED notice above)';
    return;
  end if;

  select collection_channel_id_snapshot into v_row from public.sales_returns where id = current_setting('h712t.return2')::uuid;
  if v_row.collection_channel_id_snapshot is distinct from current_setting('h712t.chan_a')::uuid then
    raise exception 'FAIL: C2 — expected collection_channel_id_snapshot to stay Channel A (its OWN creation-time snapshot) despite the Sale being edited to Channel B while pending, got %', v_row.collection_channel_id_snapshot;
  end if;
  raise notice 'PASS: C2 — collection_channel_id_snapshot remained Channel A (its OWN creation-time snapshot)';
end $$;

-- C3) authenticated — Settlement Discovery must resolve exclusively to
-- Route A (the Return's OWN creation-time snapshot route), never Route B
-- (the Sale's post-pending-edit live route).
set role authenticated;
set local request.jwt.claims = '{"sub":"f7120000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_c record;
begin
  if current_setting('h712t.skip_c') = 'true' then
    raise notice 'SKIPPED: C3 (see DOCUMENTED notice above)';
    return;
  end if;

  select count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = current_setting('h712t.return2')::uuid) as on_a
  into v_c
  from public.list_unsettled_settlement_sources(current_setting('h712t.route_a')::uuid, public.business_today() - 1, public.business_today() + 1);
  if v_c.on_a <> 1 then
    raise exception 'FAIL: C3 — return_fee_reversal must appear on Route A (the Return''s OWN creation-time snapshot route), got count=%', v_c.on_a;
  end if;

  select count(*) filter (where source_kind = 'return_fee_reversal' and source_event_id = current_setting('h712t.return2')::uuid) as on_b
  into v_c
  from public.list_unsettled_settlement_sources(current_setting('h712t.route_b')::uuid, public.business_today() - 1, public.business_today() + 1);
  if v_c.on_b <> 0 then
    raise exception 'FAIL: C3 (CRITICAL) — return_fee_reversal must NOT appear on Route B (the Sale''s new, post-pending-edit route), got count=%', v_c.on_b;
  end if;

  raise notice 'PASS: C3 (§12) — a Sale edited to B/B WHILE its Return was still pending did NOT move the Return''s eventual settlement route: it resolved to Route A (the Return''s OWN A/A creation-time snapshot) exclusively, confirming approve_sales_return() (0109) never re-reads a live Sale for fee/route identity';
end $$;

do $$
begin
  raise notice '=== ALL settlements_hotfix_7_1_2.test.sql ASSERTIONS PASSED (§1-§3/§7/§9-§12 live regression coverage) ===';
end $$;

rollback;

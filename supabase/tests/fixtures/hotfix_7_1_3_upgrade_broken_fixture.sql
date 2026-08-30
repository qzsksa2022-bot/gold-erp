-- ============================================================================
-- Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3 — DELIBERATELY
-- BROKEN pre-upgrade fixture (§14, explicit-FAIL path proof).
--
-- Runs against a database that has migrations 0001-0196 + supabase/seed.sql
-- applied (still BEFORE 0197/0198 exist). Builds a refreshed-pending Return
-- exactly like hotfix_7_1_3_upgrade_pre_fixture.sql's Scenario 1 (Sale V1
-- A/A -> Return -> Sale V2 B/B -> refresh -> left PENDING, basis_version=2),
-- THEN deliberately corrupts the audit trail so the corrected 0197 backfill
-- CANNOT reconstruct this Return's basis:
--
--   1. Deletes the audit_logs 'sale.update' row whose new_values.row_version
--      = 2 for this Sale — the ONE row the backfill needs to match this
--      Return's source_sale_row_version=2.
--   2. Edits the Sale AGAIN (to V3, Method C) so the safe fallback (§8:
--      "sales_orders.row_version = source_sale_row_version AND
--      sales_orders.payment_method_id = sales_returns.payment_method_id")
--      also cannot apply — the Sale's CURRENT row_version (3) no longer
--      matches the Return's recorded basis_version (2).
--
-- With no audit row proving basis_version=2 and the current Sale no longer
-- at that basis either, 0197's backfill integrity check (§6/§7/§8) MUST
-- refuse to guess and abort the ENTIRE migration transaction with an
-- explicit exception naming this Return — never silently falling back to
-- the old ("first update after created_at") timestamp heuristic or any
-- other guess.
--
-- Because a real FAIL here aborts the whole migration transaction, this
-- fixture is run in ITS OWN dedicated database by
-- scripts/run_upgrade_test_hotfix_7_1_3_broken_fixture.sh, never mixed with
-- the "happy path" upgrade fixtures.
--
-- NOTE: deliberately NOT wrapped in begin/rollback (data must be COMMITTED)
-- and psql runs each top-level statement in its own implicit transaction, so
-- plain SET (session-scoped) is used, never SET LOCAL.
-- ============================================================================

create table if not exists public.h713ub_scratch (label text primary key, value text);

insert into auth.users (id, email) values
  ('b7130000-0000-4000-8000-000000000001', 'test-h713ub-admin@example.invalid')
  on conflict do nothing;

update public.profiles set full_name = 'H713UB Broken-Fixture Admin', status = 'active', store_access_scope = 'all'
  where id = 'b7130000-0000-4000-8000-000000000001';

insert into public.user_roles (user_id, role_id)
  select 'b7130000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

set role authenticated;
set request.jwt.claims = '{"sub":"b7130000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store uuid; v_karat_id uuid; v_category_id uuid;
  v_pm_a uuid; v_pm_b uuid; v_pm_c uuid; v_chan_a uuid; v_chan_b uuid; v_chan_c uuid;
  v_order record; v_item_id uuid; v_subtotal numeric; v_rv bigint;
  v_return record;
  v_return_after jsonb;
begin
  insert into public.stores (code, name_ar, status) values ('H713UBS', 'فرع كسر ترقية 7.1.3', 'active') returning id into v_store;
  insert into public.karats (code, name_ar, sort_order, status) values ('H713UBK', 'عيار كسر ترقية 7.1.3', 989, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h713ubcat', 'تصنيف كسر ترقية 7.1.3', 989, 'active') returning id into v_category_id;
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 280.0000, 'b7130000-0000-4000-8000-000000000001');
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today(), 'h713ub fixture');

  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, status)
    values ('h713ub_pm_a', 'طريقة كسر ترقية 7.1.3 - أ', 'percentage', 'proportional_reversal', 'active') returning id into v_pm_a;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, status)
    values ('h713ub_pm_b', 'طريقة كسر ترقية 7.1.3 - ب', 'percentage', 'proportional_reversal', 'active') returning id into v_pm_b;
  insert into public.payment_methods (key, name_ar, fee_model, refund_fee_policy, status)
    values ('h713ub_pm_c', 'طريقة كسر ترقية 7.1.3 - ج', 'percentage', 'proportional_reversal', 'active') returning id into v_pm_c;
  perform public.create_payment_method_fee_version(v_pm_a, 4.00, 0, public.business_today() - 30, 'h713ub fee a');
  perform public.create_payment_method_fee_version(v_pm_b, 5.00, 0, public.business_today() - 30, 'h713ub fee b');
  perform public.create_payment_method_fee_version(v_pm_c, 6.00, 0, public.business_today() - 30, 'h713ub fee c');

  insert into public.collection_channels (key, name_ar, sort_order, status)
    values ('h713ub_chan_a', 'قناة كسر ترقية 7.1.3 - أ', 990, 'active') returning id into v_chan_a;
  insert into public.collection_channels (key, name_ar, sort_order, status)
    values ('h713ub_chan_b', 'قناة كسر ترقية 7.1.3 - ب', 991, 'active') returning id into v_chan_b;
  insert into public.collection_channels (key, name_ar, sort_order, status)
    values ('h713ub_chan_c', 'قناة كسر ترقية 7.1.3 - ج', 992, 'active') returning id into v_chan_c;

  -- Sale V1 (A/A).
  select * into v_order from public.create_sales_order(
    v_store, public.business_today(), v_pm_a, v_chan_a,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل كسر ترقية 7.1.3', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  v_rv := (public.get_sales_order(v_order.id) ->> 'row_version')::bigint;
  v_item_id := (public.get_sales_order(v_order.id) -> 'items' -> 0 ->> 'id')::uuid;

  -- Pending Return (basis = V1/A).
  select * into v_return from public.create_sales_return(
    v_order.id, v_store, public.business_today(), 'defective_product',
    jsonb_build_array(jsonb_build_object('sales_order_item_id', v_item_id, 'condition', 'good_resellable', 'item_return_reason', 'اختبار كسر ترقية 7.1.3')),
    v_rv, 'collected', v_subtotal
  );

  -- Sale V1 -> V2 (A/A -> B/B) + sanctioned refresh (basis becomes V2/B).
  perform public.update_sales_order(
    v_order.id, v_pm_b, v_chan_b,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل كسر ترقية 7.1.3 (V2)', null, null, null,
    (public.get_sales_order(v_order.id) ->> 'row_version')::bigint
  );
  perform public.refresh_pending_sales_return_from_sale(v_return.id, (public.get_sales_return(v_return.id) ->> 'row_version')::bigint);

  v_return_after := public.get_sales_return(v_return.id);
  assert (v_return_after ->> 'source_sale_row_version')::bigint = 2, format('BUG fixture setup: expected source_sale_row_version=2 after the refresh, got %s', v_return_after ->> 'source_sale_row_version');
  assert v_return_after ->> 'payment_method_id' = v_pm_b::text, 'BUG fixture setup: expected payment_method_id=B after the refresh';

  -- Sale V2 -> V3 (B/B -> C/C), WITHOUT a further refresh — the Return's
  -- recorded basis (source_sale_row_version=2) now points at a version the
  -- Sale has already moved PAST, and (after the audit-row deletion below)
  -- nothing can prove what that V2 state actually was.
  perform public.update_sales_order(
    v_order.id, v_pm_c, v_chan_c,
    jsonb_build_array(jsonb_build_object('id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 1000.00)),
    'عميل كسر ترقية 7.1.3 (V3، بلا تحديث ثانٍ للمرتجع)', null, null, null,
    (public.get_sales_order(v_order.id) ->> 'row_version')::bigint
  );

  perform set_config('h713ub.order_id', v_order.id::text, false);
  perform set_config('h713ub.return_id', v_return.id::text, false);
  insert into public.h713ub_scratch values ('order_id', v_order.id::text);
  insert into public.h713ub_scratch values ('return_id', v_return.id::text);
  insert into public.h713ub_scratch values ('return_number', v_return.return_number);

  raise notice 'H713UB FIXTURE (pre-corruption) OK: order=% return=% — Return''s recorded basis is V2/B (source_sale_row_version=2), Sale has since moved to V3/C WITHOUT a further refresh', v_order.id, v_return.id;
end $$;

-- ---------------------------------------------------------------------------
-- Deliberate corruption (as postgres, bypassing RLS): delete the ONE
-- audit_logs row the corrected backfill needs (the sale.update event at
-- row_version=2 for this Sale). The safe fallback (§8) is already
-- unavailable on its own, since sales_orders.row_version is now 3 (not the
-- Return's basis_version=2) — this deletion removes the ONLY remaining path
-- to a trustworthy reconstruction, forcing the explicit-FAIL branch.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;

do $$
declare
  v_order_id uuid;
  v_deleted int;
begin
  select value::uuid into v_order_id from public.h713ub_scratch where label = 'order_id';

  delete from public.audit_logs
  where entity_type = 'sales_order'
    and entity_id = v_order_id
    and action = 'sale.update'
    and (new_values ->> 'row_version')::bigint = 2;
  get diagnostics v_deleted = row_count;

  if v_deleted <> 1 then
    raise exception 'BUG fixture corruption step: expected to delete exactly 1 audit_logs row (the sale.update event at row_version=2), deleted %', v_deleted;
  end if;

  insert into public.h713ub_scratch values ('corrupted', 'true');
  raise notice 'H713UB CORRUPTION APPLIED: deleted the audit_logs sale.update row at row_version=2 for order=% — no audit event now proves this Return''s recorded basis (source_sale_row_version=2), and the Sale''s current row_version is 3 (not 2), so the §8 safe fallback cannot apply either. 0197''s backfill for this Return MUST now abort the whole migration rather than guess.', v_order_id;
end $$;

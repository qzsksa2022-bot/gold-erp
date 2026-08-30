-- ============================================================================
-- Phase 8 Patch 8.1 §57-67 — Golden Scenario MULTI-STORE extension.
-- ============================================================================
-- The original phase8_golden_scenario_fixture.sql builds its entire
-- hand-traceable scenario on a SINGLE store -- correct for proving the
-- Sales->Returns->Shipping->Adjustments->Settlements arithmetic chain
-- (§81), but it means no existing golden-scenario test has ever proven
-- store-scoping (§8) against REAL cross-store data -- every store-filter
-- assertion elsewhere in this project either uses a synthetic
-- single-store dataset or an explicit-rejection check with no second
-- store's data actually present to leak.
--
-- This file is a pure ADDITION on top of the ORIGINAL fixture (unchanged,
-- none of it rewritten) -- \i this file AFTER phase8_golden_scenario_
-- fixture.sql, in the SAME transaction. It adds:
--   1. A SECOND store (P8-G-STORE-2).
--   2. One more Sales Order on that second store, July 2026 (same window as
--      the original P1 scenario), known subtotal=500.00 -- deliberately a
--      ROUND, easily-distinguishable number from the original store's
--      3500.00, so any accidental cross-store leakage or double-counting
--      is immediately obvious in the combined total (4000.00) vs either
--      store's own total.
--   3. A THIRD actor, scoped to ONLY the second store
--      (store_access_scope='single', default_store_id=store 2) via the
--      'supervisor' role (has reports.view + sales.view, unlike the
--      original limited actor's sales_employee role which lacks
--      reports.view entirely and so cannot call get_sales_report() at
--      all) -- proving
--      real narrowing (not just permission redaction) against genuine
--      two-store data.
-- ============================================================================

insert into auth.users (id, email) values
  ('80000000-0000-4000-8000-000000000005', 'p8-golden-store2-scoped@example.invalid')
on conflict (id) do nothing;

insert into public.stores (id, code, name_ar, status) values
  ('80100000-0000-4000-8000-000000000002', 'P8-G-STORE-2', 'متجر السيناريو الذهبي الثاني', 'active')
on conflict (id) do nothing;

-- The raw profile-activation UPDATE below only succeeds in a "trusted
-- bootstrap context" (public.is_trusted_bootstrap_context(), migration
-- 0013) -- auth.uid() must be NULL at this point. The original golden
-- fixture's own actor-bootstrap runs BEFORE it ever calls set_config(),
-- but by the time THIS extension file runs (same shared transaction,
-- \i'd right after it), request.jwt.claims is already set to the super
-- admin from the original fixture's own later RPC calls (set_config's
-- is_local=true only resets at transaction end, not between statements).
-- Clear it back to NULL here, restore it right after.
select set_config('request.jwt.claims', '', true);

update public.profiles
  set full_name = 'Phase8 Golden Store-2-Scoped Actor', status = 'active',
      store_access_scope = 'single', default_store_id = '80100000-0000-4000-8000-000000000002'
  where id = '80000000-0000-4000-8000-000000000005';

insert into public.user_roles (user_id, role_id)
  select '80000000-0000-4000-8000-000000000005', r.id from public.roles r where r.key = 'supervisor'
on conflict do nothing;

do $$
declare
  v_super uuid := '80000000-0000-4000-8000-000000000001';
  v_store2 uuid := '80100000-0000-4000-8000-000000000002';
  -- Reuse the original fixture's own karat/category/payment-method/channel
  -- master data (already committed by phase8_golden_scenario_fixture.sql,
  -- fixed ids per its own convention) -- only the STORE differs, keeping
  -- this extension minimal and focused purely on proving store-scoping,
  -- not re-testing master-data plumbing already proven by the original
  -- fixture.
  v_karat uuid := '80100000-0000-4000-8000-000000000002';
  v_category uuid := '80100000-0000-4000-8000-000000000003';
  v_pm uuid := '80100000-0000-4000-8000-000000000004';
  v_ch uuid := '80100000-0000-4000-8000-000000000005';
  v_order record; v_subtotal numeric;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_super, 'role', 'authenticated')::text, true);

  select * into v_order from public.create_sales_order(
    v_store2, '2026-07-15'::date, v_pm, v_ch,
    jsonb_build_array(jsonb_build_object('category_id', v_category, 'karat_id', v_karat, 'weight_grams', 1.2500, 'sale_price', 500.00)),
    'عميل السيناريو الذهبي — متجر ثانٍ', null, null, null
  );

  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  if v_subtotal <> 500.00 then
    raise exception 'BUG fixture setup: expected store-2 sale subtotal=500.00, got %', v_subtotal;
  end if;

  raise notice 'Golden Scenario multi-store extension: store-2 sale % (subtotal=500.00) created on store %, store-2-scoped actor % ready', v_order.order_number, v_store2, '80000000-0000-4000-8000-000000000005';
end $$;

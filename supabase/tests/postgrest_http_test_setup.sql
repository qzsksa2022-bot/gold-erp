-- ============================================================================
-- TEST-ONLY fixture for the real HTTP/PostgREST integration test
-- (scripts/run_postgrest_http_test.sh). NOT a migration, NOT applied to any
-- real project — applied only to a fully throwaway database created and
-- dropped by run_postgrest_http_test.sh, alongside supabase/tests/
-- local_harness_setup.sql, every real migration (0001-latest), and
-- supabase/seed.sql.
--
-- Financial Integrity Patch 2.2, item 2's most rigorous requirement: proof,
-- over a REAL HTTP round trip through a REAL PostgREST binary (not a
-- simulated JSON.parse), that:
--   (a) a raw NUMERIC value read via a non-"_safe" function/column arrives
--       client-side as a JSON *number* and a sufficiently high-precision
--       value is corrupted by the JS double decode — the failure mode this
--       whole patch item exists to close off for financial calculations.
--   (b) the finance-safe "_safe" RPCs (migration 0052) arrive client-side as
--       a JSON *string* and survive byte-for-byte, feeding into
--       src/lib/decimal.ts's toDecimal() with the exact original value.
--   (c) real production data (a real karat price, a real manufacturing fee,
--       a real payment method fee) round-trips correctly end-to-end through
--       the actual production "_safe" RPCs added in migration 0052, not
--       just a synthetic literal.
--
-- Two synthetic diagnostic functions are added here (NOT in any numbered
-- migration — this is deliberately test-only infrastructure, never shipped)
-- because every REAL column in this schema is numeric(12,4) or numeric(6,3)
-- — small enough that even a raw JSON-number round trip through an IEEE-754
-- double never actually loses precision for realistic values (a double
-- exactly represents any integer up to 2^53, and 12 total digits scaled by
-- 10000 sits well inside that range). That is real and reassuring for
-- TODAY's data, but it is not a structural guarantee for tomorrow's, and
-- proving the *mechanism* (not just "no real column happens to be large
-- enough yet") requires a literal wide enough to force a real double
-- rounding error — hence the synthetic functions below.
-- ============================================================================

-- 27 significant digits — comfortably beyond IEEE-754 double's ~15-17
-- guaranteed significant decimal digits, so JSON.parse-as-number is
-- guaranteed to round it, proving the raw-numeric wire format really is
-- unsafe for arbitrary-precision financial values, not just "safe so far".
create or replace function public._patch22_http_test_raw_numeric()
returns numeric
language sql
stable
as $$
  select 123456789012345678.123456789::numeric;
$$;

comment on function public._patch22_http_test_raw_numeric() is
  'TEST-ONLY (not part of any real migration): returns a synthetic 27-significant-digit NUMERIC literal, unquoted over PostgREST — used by scripts/run_postgrest_http_test.sh to prove a raw numeric-returning function loses precision over a real HTTP/JSON round trip.';

create or replace function public._patch22_http_test_safe_text()
returns text
language sql
stable
as $$
  select public._patch22_http_test_raw_numeric()::text;
$$;

comment on function public._patch22_http_test_safe_text() is
  'TEST-ONLY: the exact same synthetic value as _patch22_http_test_raw_numeric(), cast ::text — used to prove the finance-safe pattern (migration 0052) survives the identical real HTTP/JSON round trip losslessly.';

-- No REVOKE/GRANT — plain PUBLIC EXECUTE, matching every other STABLE SQL
-- read function in this project; RLS is irrelevant here (no table access).

-- ---------------------------------------------------------------------------
-- Test actor + real production sample data, so the REAL 0052 "_safe" RPCs
-- (not just the synthetic functions above) are also exercised end-to-end
-- over real HTTP, using the exact production functions Sales will one day
-- call.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000001', 'test-postgrest-http@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor', status = 'active', store_access_scope = 'all'
  where id = 'c9000000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('karats.view', 'gold_prices.view', 'manufacturing_fees.view', 'payment_methods.view')
on conflict do nothing;

insert into public.karats (id, code, purity_per_mille, name_ar, name_en, sort_order, status)
values ('c9100000-0000-4000-8000-000000000001', 'HTTP-TEST-K21', 916.000, 'عيار اختبار HTTP', 'HTTP Test Karat', 900, 'active')
on conflict (id) do nothing;

-- Seed for BOTH the raw DB-server current_date AND public.business_today()
-- (Asia/Riyadh, UTC+3) -- these two can genuinely differ by one calendar
-- day whenever this harness happens to run inside the ~3-hour UTC window
-- where Riyadh has already rolled over to the next day but the UTC-timezone
-- Postgres server hasn't (or vice versa around UTC midnight). gold_price_
-- for_karat_on_date()/_safe() (migration 0057) default p_date to business_
-- today(), not current_date, so seeding only current_date makes this
-- fixture flaky near that boundary -- not a real product bug, just this
-- test fixture's own date assumption.
-- DISTINCT here is deliberate, not cosmetic: current_date and business_
-- today() are usually the SAME calendar day (only differing for ~3 hours
-- around UTC midnight, per the comment above), and a plain VALUES list
-- with two identical dates makes ON CONFLICT DO UPDATE fail outright
-- ("cannot affect row a second time") — a single INSERT statement may
-- never target the same conflict key twice. Pre-existing test-fixture-only
-- bug, unrelated to any numbered migration; fixed here so this fixture
-- works on every calendar day, not just near the boundary it was guarding
-- against.
insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, source_type, is_manual_override, created_by, updated_by)
select d, 'c9100000-0000-4000-8000-000000000001', 275.1234, 'manual', true,
       'c9000000-0000-4000-8000-000000000001', 'c9000000-0000-4000-8000-000000000001'
from (select distinct d from (values (current_date), (public.business_today())) as dates(d)) as distinct_dates(d)
on conflict (price_date, karat_id) do update set price_per_gram = excluded.price_per_gram;

insert into public.manufacturing_fee_versions (karat_id, fee_per_gram, effective_from, status, created_by)
select 'c9100000-0000-4000-8000-000000000001', 12.3456, current_date - 10, 'active', 'c9000000-0000-4000-8000-000000000001'
where not exists (
  select 1 from public.manufacturing_fee_versions
  where karat_id = 'c9100000-0000-4000-8000-000000000001' and effective_to is null and status = 'active'
);

insert into public.payment_methods (id, key, name_ar, fee_model, status)
values ('c9200000-0000-4000-8000-000000000001', 'http_test_pm', 'طريقة اختبار HTTP', 'percentage_plus_fixed', 'active')
on conflict (id) do nothing;

insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, status, created_by)
select 'c9200000-0000-4000-8000-000000000001', 2.750, 5.2500, current_date - 10, 'active', 'c9000000-0000-4000-8000-000000000001'
where not exists (
  select 1 from public.payment_method_fee_versions
  where payment_method_id = 'c9200000-0000-4000-8000-000000000001' and effective_to is null and status = 'active'
);

-- ---------------------------------------------------------------------------
-- Phase 3 — Sales Core additions: a store/category/collection channel (the
-- karat, gold price, manufacturing fee version, and payment method + fee
-- version above are reused as-is) plus a SECOND test actor with sales.view
-- but NOT sales.view_profit, so scripts/postgrest-http-test.mjs can prove
-- the DB-level profit-hiding behavior (spec §15/§32) over a REAL HTTP round
-- trip for BOTH Sales Read RPCs (list_sales_orders/get_sales_order) — not
-- just via a simulated local Postgres session as supabase/tests/
-- sales_core.test.sql already does. VAT uses the 15% baseline row already
-- seeded by migration 0058/seed.sql — no separate VAT fixture needed here.
-- ---------------------------------------------------------------------------
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('stores.view', 'categories.view', 'collection_channels.view', 'sales.create', 'sales.edit', 'sales.view', 'sales.view_profit', 'audit_logs.view')
on conflict do nothing;

insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000002', 'test-postgrest-http-noprofit@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (No Profit)', status = 'active', store_access_scope = 'all'
  where id = 'c9000000-0000-4000-8000-000000000002';

-- Patch 3.1 item M: this actor deliberately holds audit_logs.view but NOT
-- sales.view_profit — used to prove, over a REAL HTTP request against
-- PostgREST's auto-generated /audit_logs endpoint (not an RPC), that the
-- audit_logs_select RLS policy (migration 0072) genuinely filters out every
-- sale.* row for a caller who cannot see profit, rather than merely hiding
-- profit-bearing columns.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('sales.view', 'audit_logs.view')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Phase 4 — Returns Core additions (migrations 0082-0091): reuse every
-- fixture row above (store/category/karat/payment method/collection
-- channel) and grant the Returns permission set to both existing test
-- actors, so scripts/postgrest-http-test.mjs can prove the same
-- Decimal-Transport-Boundary + profit-hiding guarantees for the Returns
-- read RPCs (list_sales_returns/get_sales_return/get_returnable_sales_
-- order) and the return.% audit_logs RLS extension (migration 0091) over a
-- REAL HTTP round trip, not just via supabase/tests/sales_returns_core.
-- test.sql's simulated local Postgres session.
-- ---------------------------------------------------------------------------
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('returns.view', 'returns.create', 'returns.approve', 'returns.reverse', 'returns.record_refund')
on conflict do nothing;

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key = 'returns.view'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Phase 5 — Shipping Core additions (migrations 0113-0121): reuse every
-- fixture row above (store/category/karat/payment method/collection
-- channel), grant the full Shipping permission set to the profit actor, and
-- ONLY shipments.view to the no-profit actor (mirrors Section 49's own
-- "shipments.view alone" design exactly) — so scripts/postgrest-http-test.
-- mjs can prove, over a REAL HTTP round trip:
--   - the Decimal Transport Boundary guarantee for every Shipping money
--     field (customer_shipping_charge/expected_carrier_cost/actual_carrier_
--     cost/net_shipping_expected/net_shipping_actual/cod_expected_amount),
--   - the seeded real carrier-rate/customer-return-fee figures (migration
--     0114/0115 — SMSA/ARAMEX=17.00, BARQ/REDBOX=15.00 return cost;
--     Riyadh=35.00/Outside Riyadh=50.00 customer return fee) resolve
--     correctly through preview_*/create_shipment() over real HTTP,
--   - DB-level profit protection (get_shipment()/list_shipments()) for a
--     genuinely different signed JWT/actor holding only shipments.view,
--   - the fine-grained (not blanket-prefix) shipment.* audit_logs RLS
--     gating (migration 0121) — deliberately different from return.%'s
--     blanket gating: shipment.status_add stays visible to this same
--     no-profit actor while shipment.create/cost_record/etc. do not.
-- Carriers/zones/their seeded rate versions are Master Data, already
-- present via seed.sql (step 3 of run_postgrest_http_test.sh) — no
-- additional fixture rows needed for them here.
-- ---------------------------------------------------------------------------
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'shipments.view', 'shipments.create', 'shipments.update_status', 'shipments.correct_status',
    'shipments.manage_cost', 'shipments.process_closed_day', 'shipping_rates.view', 'shipping_rates.manage'
  )
on conflict do nothing;

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key = 'shipments.view'
on conflict do nothing;

-- http_test_pm defaults to refund_fee_policy='manual' (migration 0044's
-- table default) — switched to 'proportional_reversal' here so the HTTP
-- test's approve_sales_return() call needs no manual override (the manual-
-- override path itself is already exhaustively covered by supabase/tests/
-- sales_returns_core.test.sql; this HTTP test's job is the wire-format +
-- profit-hiding guarantees, mirroring Part 3's Sales scope).
update public.payment_methods
  set refund_fee_policy = 'proportional_reversal'
  where id = 'c9200000-0000-4000-8000-000000000001';

insert into public.stores (id, code, name_ar, status)
values ('c9300000-0000-4000-8000-000000000001', 'HTTPTESTST', 'متجر اختبار HTTP', 'active')
on conflict (id) do nothing;

insert into public.product_categories (id, code, name_ar, sort_order, status)
values ('c9400000-0000-4000-8000-000000000001', 'http_test_cat', 'تصنيف اختبار HTTP', 900, 'active')
on conflict (id) do nothing;

insert into public.collection_channels (id, key, name_ar, sort_order, status)
values ('c9500000-0000-4000-8000-000000000001', 'http_test_channel', 'قناة اختبار HTTP', 900, 'active')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Final Shipping Hotfix 5.1.1 (item 6/9) — date room for the monotonic-
-- chronology-vs-latest-event proof (migration 0131) over real HTTP.
--
-- Every Sale/Shipment fixture ABOVE is created dated "today" (todayIso in
-- postgrest-http-test.mjs), which pins create_shipment()'s own shipment_date
-- floor (p_shipment_date >= sales_orders.sale_date) to a single calendar
-- day — there is no room left to construct two genuinely different
-- business_date values for the SAME shipment's status/COD event streams,
-- which is exactly what proving 0131's fix requires (a later-inserted event
-- dated BEFORE an earlier one, both still >= shipment_date). Part 9 of
-- postgrest-http-test.mjs instead creates a SECOND, deliberately backdated
-- Sale (sale_date = 5 days ago) purely to get a shipment_date 5 days in the
-- past, giving room for a spread of distinct historical event dates.
--
-- That backdated Sale needs a resolvable gold price (exact-date match,
-- migration 0041/0057 — no fallback to the nearest earlier price) and a
-- VAT rate version whose effective_from covers that date (range match,
-- migration 0061 — the baseline seeded row's effective_from is business_
-- today() with no historical predecessor, seed.sql). Manufacturing fee /
-- payment method fee versions already cover 10 days of history (this same
-- file, above) and need no change.
--
-- Both additions below only ever WIDEN validity into the past — neither
-- touches "today"'s own resolution, so Parts 1-8 above are unaffected. This
-- is fixture setup for a date the test itself picks, not a test of the VAT/
-- gold-price boundary — mirrors the identical, identically-justified
-- technique already used for the same underlying gap in supabase/tests/
-- shipping_integrity_hotfix_5_1_1.test.sql.
insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, source_type, is_manual_override, created_by, updated_by)
select d, 'c9100000-0000-4000-8000-000000000001', 275.1234, 'manual', true,
       'c9000000-0000-4000-8000-000000000001', 'c9000000-0000-4000-8000-000000000001'
from (select distinct d from (values (current_date - 5), (public.business_today() - 5)) as dates(d)) as distinct_dates(d)
on conflict (price_date, karat_id) do update set price_per_gram = excluded.price_per_gram;

update public.vat_rate_versions
  set effective_from = least(effective_from, current_date - 10, public.business_today() - 10)
  where effective_to is null and status = 'active';

-- ---------------------------------------------------------------------------
-- Phase 6 — Services / Adjustments Core additions (migrations 0133-0143):
-- reuse every fixture row above (store/category/karat/payment method/
-- collection channel), grant the full Adjustments permission set to the
-- profit actor (including adjustments.manage_cost, now REQUIRED alongside
-- adjustments.approve — 0140), and ONLY adjustments.view to the no-profit
-- actor (mirrors Section 49's "shipments.view alone" design exactly) — so
-- scripts/postgrest-http-test.mjs can prove, over a REAL HTTP round trip:
--   - the Decimal Transport Boundary guarantee for every Adjustments money
--     field (customer_charge/direct_cost/payment_fee_amount/gross_
--     adjustment_profit/net_adjustment_profit),
--   - a full create -> approve -> reverse lifecycle actually persists over
--     real HTTP, using the same worked-example fee math as the SQL suite
--     (payment method c9200000-...-1 = 2.75%/5.25 fixed here, unlike
--     seed.sql's visa 2.5%/0 — this fixture computes its own expected
--     figures from ITS OWN fee version, not visa's),
--   - DB-level profit protection (get_sales_order_adjustment()/list_sales_
--     order_adjustments()) for the genuinely different no-profit actor,
--   - the fine-grained adjustment.* audit_logs RLS gating (migration 0143)
--     — this no-profit actor holds sales.view but not sales.view_profit,
--     proving adjustment.create/update/approve/reverse are all hidden while
--     adjustment.reject/closed_day_override/adjustment_type.* stay visible,
--   - §25: search_sales_orders_for_adjustment() works for an actor holding
--     ONLY adjustments.create, no sales.view at all (a THIRD actor, since
--     both existing actors already hold sales.view from Part 3 onward).
-- ---------------------------------------------------------------------------
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'adjustments.view', 'adjustments.create', 'adjustments.approve',
    'adjustments.manage_cost', 'adjustments.reverse', 'adjustments.process_closed_day', 'adjustments.manage_types'
  )
on conflict do nothing;

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key = 'adjustments.view'
on conflict do nothing;

-- Third actor: adjustments.create ONLY, no sales.view at all — proves §25
-- (search_sales_orders_for_adjustment() never depends on sales.view) over
-- REAL HTTP, not just supabase/tests/adjustments_core_phase6.test.sql's
-- simulated local Postgres session.
insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000003', 'test-postgrest-http-adjcreateonly@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (Adjustments Create-Only)', status = 'active', store_access_scope = 'all'
  where id = 'c9000000-0000-4000-8000-000000000003';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000003', id, 'grant' from public.permissions
  where key = 'adjustments.create'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Patch 6.1 (items 31-33) additions: reuse every fixture row above (store/
-- category/karat/payment method/collection channel), a SECOND store for the
-- cross-store isolation proof (items 12/13), and two more actors so
-- scripts/postgrest-http-test.mjs's Part 12 can prove the following over a
-- REAL HTTP round trip (not just supabase/tests/adjustments_core_phase6.
-- test.sql's simulated local Postgres session):
--   - a create-only actor (existing actor ...-003) cannot pass p_direct_cost
--     at all (item 1D/23);
--   - a NEW manage_cost-ONLY actor (...-004, no view/create/approve) can set
--     Pending direct_cost via the dedicated RPC (item 2) and nothing else;
--   - the EXISTING no-profit actor (...-002) additionally gains adjustments.
--     approve here (still WITHOUT sales.view_profit or adjustments.
--     manage_cost) — proves an approve-only actor can approve a cost-bearing
--     record and that the approval response never leaks Net Profit (item 5/6
--     matrix A, reusing the actor that already proves the profit-hiding
--     side rather than adding a fourth near-duplicate);
--   - a NEW store-B-scoped actor (...-005, single-store access, adjustments.
--     view + adjustments.approve) is denied get/list/reject on an Adjustment
--     whose linked Sale lives in store A, closing the cross-store leak (item
--     12/13/31) over real HTTP, not just the local-session SQL suite.
-- ---------------------------------------------------------------------------
insert into public.stores (id, code, name_ar, status)
values ('c9300000-0000-4000-8000-000000000002', 'HTTPTESTSTB', 'متجر اختبار HTTP ب', 'active')
on conflict (id) do nothing;

insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000004', 'test-postgrest-http-adjmanagecostonly@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (Adjustments Manage-Cost-Only)', status = 'active', store_access_scope = 'all'
  where id = 'c9000000-0000-4000-8000-000000000004';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000004', id, 'grant' from public.permissions
  where key = 'adjustments.manage_cost'
on conflict do nothing;

-- ...-002 (existing no-profit actor) additionally gains adjustments.approve
-- ONLY (still no adjustments.manage_cost, still no sales.view_profit) — item
-- 5/6 matrix A, over real HTTP.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key = 'adjustments.approve'
on conflict do nothing;

insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000005', 'test-postgrest-http-adjstorebonly@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (Adjustments Store-B-Only)', status = 'active',
      store_access_scope = 'single', default_store_id = 'c9300000-0000-4000-8000-000000000002'
  where id = 'c9000000-0000-4000-8000-000000000005';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000005', id, 'grant' from public.permissions
  where key in ('adjustments.view', 'adjustments.approve')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Phase 6 Final Integrity Hotfix 6.1.1 item 13 addition: scripts/postgrest-
-- http-test.mjs's Part 13 needs to rename payment_methods/collection_
-- channels over a REAL HTTP round trip. Neither table has a dedicated
-- "sanctioned" rename RPC (unlike adjustment_types' update_adjustment_
-- type()) — a direct table UPDATE via the service_role client (exactly
-- mirroring supabase/tests/adjustments_core_phase6.test.sql's own items
-- 25B/25C) IS that sanctioned flow here. Locally that test runs the UPDATE
-- with NO "sub" claim at all, so auth.uid() is null and the system-managed-
-- columns trigger (0021/0048) leaves updated_by untouched. Over real HTTP,
-- TEST_JWT_SERVICE's "sub" is the literal all-zero UUID (scripts/run_
-- postgrest_http_test.sh) — a real, non-null auth.uid() — so the SAME
-- trigger instead PINS updated_by to that UUID, which then needs a real
-- profiles row to satisfy payment_methods.updated_by/collection_channels.
-- updated_by's FK. This is exactly the "genuinely trusted context" case the
-- trigger's own contract describes (service_role/migrations/seed.sql) —
-- adding a real, harmless placeholder actor for it, rather than a schema
-- change, is the correct fix.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000000', 'test-postgrest-http-service-role-placeholder@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Service-Role Placeholder', status = 'active', store_access_scope = 'all'
  where id = '00000000-0000-0000-0000-000000000000';

-- ---------------------------------------------------------------------------
-- Phase 7 Integrity Patch 7.1 (Settlements Core, migrations 0167-0191)
-- additions: reuse every fixture row above (store/category/karat/payment
-- method/collection channel, plus the second Store B from Patch 6.1) and add
-- the full settlements.* permission set to the profit actor (...001, minus
-- settlements.manage_routes — deliberately kept OFF this actor so it doubles
-- as the "lacks manage_routes" denial case for create_settlement_route()),
-- settlements.view ONLY to the no-profit actor (...002, money-field
-- redaction proof), settlements.view/view_financials/create to the existing
-- Store-B-only Adjustments actor (...005, reused for the §5/§6 cross-store
-- privacy proof), and FOUR new narrow actors so scripts/postgrest-http-test.
-- mjs's Settlements section can prove, over real HTTP:
--   - a create-only actor (no settlements.view at all) can create a draft
--     and read it back ONLY via get_draft_settlement_batch_for_edit() (§7),
--     and settlement_create_store_lookups() works for it (§24),
--   - a settlements.manage_routes-ONLY actor (no payment_methods.view/
--     collection_channels.view/shipping_rates.view/settlements.view_
--     financials) can fully manage Settlement Routes + their fee versions
--     via the four narrow §23 lookup RPCs, while a raw SELECT against
--     settlement_route_fee_versions for this SAME actor returns zero rows
--     (that table's own RLS policy requires view_financials, which the RPC
--     deliberately does not),
--   - the §8 audit_logs cross-domain permission split: settlements.view_
--     financials grants NOTHING toward Sales/Adjustments financial audit
--     rows, and sales.view_profit grants NOTHING toward Settlements
--     financial audit rows — two actors, each holding exactly one side.
-- ---------------------------------------------------------------------------
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in (
    'settlements.view', 'settlements.view_financials', 'settlements.create', 'settlements.finalize',
    'settlements.record_bank_movement', 'settlements.reconcile', 'settlements.reconcile_variance',
    'settlements.cancel', 'settlements.override_batch_fee', 'settlements.process_closed_day'
  )
on conflict do nothing;

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key = 'settlements.view'
on conflict do nothing;

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000005', id, 'grant' from public.permissions
  where key in ('settlements.view', 'settlements.view_financials', 'settlements.create')
on conflict do nothing;

-- Actor 006: settlements.create ONLY (no settlements.view at all) — §7/§24.
insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000006', 'test-postgrest-http-settlecreateonly@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (Settlements Create-Only)', status = 'active', store_access_scope = 'all'
  where id = 'c9000000-0000-4000-8000-000000000006';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000006', id, 'grant' from public.permissions
  where key = 'settlements.create'
on conflict do nothing;

-- Actor 007: settlements.manage_routes ONLY — §2/§23.
insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000007', 'test-postgrest-http-settlemanageroutesonly@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (Settlements Manage-Routes-Only)', status = 'active', store_access_scope = 'all'
  where id = 'c9000000-0000-4000-8000-000000000007';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000007', id, 'grant' from public.permissions
  where key = 'settlements.manage_routes'
on conflict do nothing;

-- Actor 008: audit_logs.view + settlements.view_financials, deliberately NO
-- sales.view_profit — §8 (settlements.view_financials must grant nothing
-- toward Sales/Returns/Adjustments financial audit rows).
insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000008', 'test-postgrest-http-settleauditfinonly@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (Settlements Audit Financials-Only)', status = 'active', store_access_scope = 'all'
  where id = 'c9000000-0000-4000-8000-000000000008';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000008', id, 'grant' from public.permissions
  where key in ('audit_logs.view', 'settlements.view_financials')
on conflict do nothing;

-- Actor 009: audit_logs.view + sales.view_profit, deliberately NO
-- settlements.view_financials — §8 reverse direction (sales.view_profit
-- must grant nothing toward Settlements financial audit rows).
insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000009', 'test-postgrest-http-salesprofitnosettlefin@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (Sales-Profit-Only, No Settlement Financials)', status = 'active', store_access_scope = 'all'
  where id = 'c9000000-0000-4000-8000-000000000009';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000009', id, 'grant' from public.permissions
  where key in ('audit_logs.view', 'sales.view_profit')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Phase 7 — Final Integrity Hotfix 7.1.1 (migrations 0192-0196) additions:
-- three more narrow actors so scripts/postgrest-http-test.mjs's Part 15 can
-- prove, over real HTTP:
--   - Actor 010: settlements.create ONLY — a SECOND, genuinely distinct
--     identity from actor 006 (also settlements.create-only), used as the
--     non-owner rejected by update_draft_settlement_batch() (§4).
--   - Actor 011: single-store-scoped to Store A ONLY, holding every
--     lifecycle WRITE permission (create/finalize/record_bank_movement/
--     reconcile/cancel) — used to prove all four write RPCs fail closed
--     (§5) on a batch whose Adjustment line's processing store is Store B
--     (invisible to this actor).
--   - Actor 012: settlements.reconcile ONLY (no view/view_financials),
--     store_access_scope='all' (so §5's store-scope check never interferes
--     with proving §7's redaction specifically) — used to prove
--     reconcile_settlement_batch() redacts actual_bank_movement/variance to
--     NULL without settlements.view_financials.
-- Reused rather than duplicated for Part 15's remaining actors: actor 001
-- (settlements.view, full Settlements set minus manage_routes) for §4's
-- unrestricted-view-holder case and §9's override parity; actor 002
-- (clientNoProfit, settlements.view ALONE, no payment_methods.view/
-- collection_channels.view) for §12's positive filter-lookup case; actor 006
-- (clientSettleCreateOnly, settlements.create ONLY, no settlements.view) for
-- §12's negative filter-lookup case; actor 005 (clientAdjStoreBOnly) and the
-- existing stlRouteChannelledId/STORE_ID/STORE_B_ID fixtures for §15's
-- cross-store OR-filter proof (Part 14 item f/j already builds and then
-- releases the claim on the exact cross-store Adjustment Part 15 item h
-- reuses).
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000010', 'test-postgrest-http-settlecreateonly2@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (Settlements Create-Only #2)', status = 'active', store_access_scope = 'all'
  where id = 'c9000000-0000-4000-8000-000000000010';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000010', id, 'grant' from public.permissions
  where key = 'settlements.create'
on conflict do nothing;

insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000011', 'test-postgrest-http-settlestorescoped@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (Settlements Store-Scoped)', status = 'active',
      store_access_scope = 'single', default_store_id = 'c9300000-0000-4000-8000-000000000001'
  where id = 'c9000000-0000-4000-8000-000000000011';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000011', id, 'grant' from public.permissions
  where key in ('settlements.create', 'settlements.finalize', 'settlements.record_bank_movement', 'settlements.reconcile', 'settlements.cancel')
on conflict do nothing;

insert into auth.users (id, email) values
  ('c9000000-0000-4000-8000-000000000012', 'test-postgrest-http-settlereconcileonly@example.invalid')
on conflict (id) do nothing;

update public.profiles
  set full_name = 'PostgREST HTTP Test Actor (Settlements Reconcile-Only)', status = 'active', store_access_scope = 'all'
  where id = 'c9000000-0000-4000-8000-000000000012';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000012', id, 'grant' from public.permissions
  where key = 'settlements.reconcile'
on conflict do nothing;

-- Part 15 item f's cancellation-chronology fixture needs a Sale dated 2 days
-- before "today", giving room for a distinct settlement_date/reversal_
-- business_date spread (same technique/justification as the Shipping
-- Hotfix 5.1.1 block above, which widened -5 days for the SAME karat_id —
-- daily_gold_prices is looked up by EXACT date match, migration 0041/0057).
-- manufacturing_fee_versions/payment_method_fee_versions already cover 10
-- days back (this same file, above) and vat_rate_versions is already
-- widened 10 days back by the Shipping Hotfix 5.1.1 block above — neither
-- needs any further change for this one extra historical date.
insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, source_type, is_manual_override, created_by, updated_by)
select d, 'c9100000-0000-4000-8000-000000000001', 275.1234, 'manual', true,
       'c9000000-0000-4000-8000-000000000001', 'c9000000-0000-4000-8000-000000000001'
from (select distinct d from (values (current_date - 2), (public.business_today() - 2)) as dates(d)) as distinct_dates(d)
on conflict (price_date, karat_id) do update set price_per_gram = excluded.price_per_gram;

-- A disabled payment method + a disabled collection channel — Part 15 item
-- g's proof that settlement_filter_payment_method_lookups()/settlement_
-- filter_collection_channel_lookups() (0196) include disabled/historical
-- rows (never an active-only filter), mirroring settlements_hotfix_7_1_1.
-- test.sql's own h711t_disabled_pm fixture.
insert into public.payment_methods (id, key, name_ar, name_en, fee_model, status)
values ('c9200000-0000-4000-8000-000000000002', 'http_test_pm_disabled', 'طريقة اختبار HTTP معطّلة', 'HTTP Test Disabled PM', 'none', 'inactive')
on conflict (id) do nothing;

insert into public.collection_channels (id, key, name_ar, name_en, sort_order, status)
values ('c9500000-0000-4000-8000-000000000002', 'http_test_channel_disabled', 'قناة اختبار HTTP معطّلة', 'HTTP Test Disabled Channel', 901, 'inactive')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2 (Part 16) — a
-- SECOND, genuinely distinct ACTIVE payment method + collection channel
-- ("Payment Method B" / "Channel B"), with its own real fee version and
-- proportional_reversal refund policy — mirroring PAYMENT_METHOD_ID/
-- CHANNEL_ID's own setup above exactly. Needed to build a real two-route
-- (Route A: PAYMENT_METHOD_ID+CHANNEL_ID, Route B: this pair) Discovery
-- split over real HTTP, proving §1/§7's route-identity-snapshot fix the
-- same way settlements_hotfix_7_1_2.test.sql's local SQL scenario does.
-- ---------------------------------------------------------------------------
insert into public.payment_methods (id, key, name_ar, name_en, fee_model, refund_fee_policy, status)
values ('c9200000-0000-4000-8000-000000000003', 'http_test_pm_b', 'طريقة اختبار HTTP ب', 'HTTP Test PM B', 'percentage_plus_fixed', 'proportional_reversal', 'active')
on conflict (id) do nothing;

insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, status, created_by)
select 'c9200000-0000-4000-8000-000000000003', 3.500, 4.0000, current_date - 10, 'active', 'c9000000-0000-4000-8000-000000000001'
where not exists (
  select 1 from public.payment_method_fee_versions
  where payment_method_id = 'c9200000-0000-4000-8000-000000000003' and effective_to is null and status = 'active'
);

insert into public.collection_channels (id, key, name_ar, name_en, sort_order, status)
values ('c9500000-0000-4000-8000-000000000003', 'http_test_channel_b', 'قناة اختبار HTTP ب', 'HTTP Test Channel B', 902, 'active')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3 (Part 17) — a
-- THIRD, genuinely distinct ACTIVE payment method + collection channel
-- ("Payment Method C" / "Channel C"), mirroring PAYMENT_METHOD_B_ID/
-- CHANNEL_B_ID's own setup above exactly. Needed for the post-approval
-- historical-stability step (§10): after Route B is the Return's live basis,
-- the Sale is edited AGAIN to C/C and the historical Route B fee events must
-- stay pinned there, never drift to C/C.
-- ---------------------------------------------------------------------------
insert into public.payment_methods (id, key, name_ar, name_en, fee_model, refund_fee_policy, status)
values ('c9200000-0000-4000-8000-000000000004', 'http_test_pm_c', 'طريقة اختبار HTTP ج', 'HTTP Test PM C', 'percentage_plus_fixed', 'proportional_reversal', 'active')
on conflict (id) do nothing;

insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, status, created_by)
select 'c9200000-0000-4000-8000-000000000004', 4.500, 3.0000, current_date - 10, 'active', 'c9000000-0000-4000-8000-000000000001'
where not exists (
  select 1 from public.payment_method_fee_versions
  where payment_method_id = 'c9200000-0000-4000-8000-000000000004' and effective_to is null and status = 'active'
);

insert into public.collection_channels (id, key, name_ar, name_en, sort_order, status)
values ('c9500000-0000-4000-8000-000000000004', 'http_test_channel_c', 'قناة اختبار HTTP ج', 'HTTP Test Channel C', 903, 'active')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Phase 8 (Reports, Dashboard & Exports, migrations 0199-0204) additions for
-- scripts/postgrest-http-test.mjs's Part 18. reports.view / reports.
-- export_pdf / reports.export_excel / dashboard.view / dashboard.
-- view_financials are NOT new permission keys (migration 0199's own comment
-- -- they already existed pre-Phase-8), so no new permissions.* rows are
-- needed here, only new grants on three EXISTING actors:
--   - ...-001 (the main profit actor): full reports.view/export_pdf/
--     export_excel + dashboard.view/view_financials, so Part 18 can prove
--     the Decimal Transport Boundary (§40/§41) and the Report Basis
--     Indicator (§83) for a fully-privileged caller.
--   - ...-002 (the existing Sales no-profit actor, already sales.view/
--     returns.view/shipments.view/settlements.view/adjustments.view/approve
--     WITHOUT any *.view_profit/*.view_financials): reports.view +
--     dashboard.view (deliberately WITHOUT dashboard.view_financials), so
--     Part 18 can prove §79 true key absence for get_sales_report() and
--     get_dashboard_summary() over a REAL HTTP round trip.
--   - ...-005 (the existing Store-B-only actor, already adjustments.view/
--     approve + settlements.view/view_financials/create, single-store
--     scoped to Store B, WITHOUT sales.view/returns.view/shipments.view at
--     all): reports.view + dashboard.view + dashboard.view_financials, so
--     Part 18 can prove get_dashboard_summary()'s per-domain key omission is
--     independent per domain (sales/returns/shipping entirely absent while
--     adjustments/settlements are present WITH financial sub-fields, and
--     net_operating_return is absent because it needs ALL of sales.view_
--     profit/shipments.view/adjustments.view, not just dashboard.view_
--     financials), AND reuses this SAME store-scoped actor to prove the §8/
--     §9 explicit store-filter rejection (requesting Store A while scoped to
--     Store B only) for a report/dashboard RPC over real HTTP.
-- ---------------------------------------------------------------------------
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('reports.view', 'reports.export_pdf', 'reports.export_excel', 'dashboard.view', 'dashboard.view_financials')
on conflict do nothing;

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions
  where key in ('reports.view', 'dashboard.view')
on conflict do nothing;

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'c9000000-0000-4000-8000-000000000005', id, 'grant' from public.permissions
  where key in ('reports.view', 'dashboard.view', 'dashboard.view_financials')
on conflict do nothing;

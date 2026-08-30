-- ============================================================================
-- 0065: Phase 3 — Sales Integrity Patch 3.1 (1/7): reconciling cost-calculation
-- helper + advisory-lock helper functions
-- ============================================================================
-- Migrations 0001-0064 are unmodified — this is the first migration of Patch
-- 3.1 (user directive: "كل الإصلاحات الجديدة تبدأ بعد 0064"). Purely additive:
-- new functions only, nothing existing is altered by this file. Every later
-- Patch 3.1 migration (0066-0071) builds on the functions defined here.
--
-- ---------------------------------------------------------------------------
-- Part A — compute_sales_item_costs(): the single shared reconciling
-- cost-calculation helper (spec item 8 + item 10).
--
-- Problem being fixed: create_sales_order() (0061), update_sales_order()
-- (0063), and preview_sales_order() (0062) each independently rounded
-- total_cost and gross_profit from the SAME raw (unrounded) intermediate
-- values, rather than from a shared chain of already-rounded components —
-- e.g. weight=0.0100, gold=300, manufacturing=10, VAT=15%, sale_price=100.00:
-- raw total_cost = 0.0100*300 + 0.0100*10 = 3.10, + 15% VAT = 3.565 ->
-- round(3.565,2) = 3.57 (Postgres round() is round-half-away-from-zero, not
-- banker's rounding — verified empirically against a live database during
-- this patch's design phase). gross_profit computed independently from the
-- SAME raw total_cost: 100 - 3.565 = 96.435 -> round(96.435,2) = 96.44.
-- Displayed: 3.57 + 96.44 = 100.01 -- one cent more than the 100.00 sale
-- price. This is a real accounting mismatch, not a display rounding
-- artifact, because total_cost and gross_profit are both independently
-- *stored* numeric(14,2) columns.
--
-- Fix: round each of the two true base components (gold, manufacturing)
-- independently to 2dp FIRST (each is itself a real stored output column),
-- then derive every downstream figure via EXACT arithmetic on already-2dp
-- values — never re-rounding a value that is already the exact sum/
-- difference of already-rounded numbers:
--   gold_component_cost       = round(gold_price_per_gram * weight_grams, 2)
--   manufacturing_component_cost = round(manufacturing_fee_per_gram * weight_grams, 2)
--   base_cost   = gold_component_cost + manufacturing_component_cost   (EXACT — sum of two 2dp numbers is always exactly representable to 2dp, no rounding needed)
--   vat_cost    = round(base_cost * vat_rate_percent / 100, 2)          (base_cost is now exact, so this is the only remaining rounding step for the cost side)
--   total_cost  = base_cost + vat_cost                                  (EXACT — same reasoning as base_cost)
--   gross_profit = sale_price - total_cost                              (EXACT — sale_price is already 2dp, total_cost is now exact)
-- This guarantees, by construction, for EVERY input (not just the worked
-- example): gold_component_cost + manufacturing_component_cost = base_cost,
-- base_cost + vat_cost = total_cost, and critically
-- total_cost + gross_profit = sale_price — the exact invariant spec item 8
-- mandates. Re-verified against the spec's own worked example (weight=0.01,
-- gold=300, mfg=10, vat=15%, sale=100 -> gold_component=3.00,
-- mfg_component=0.10, base_cost=3.10, vat_cost=round(3.10*0.15,2)=round(0.465,2)
-- =0.47 [round-half-away-from-zero], total_cost=3.57, gross_profit=100-3.57=
-- 96.43, and 3.57+96.43=100.00 exactly) and re-verified as fully backward-
-- compatible with every previously-verified Phase 3 worked example in
-- sales_core.test.sql (no existing assertion's numeric result changes,
-- because this rounding policy only differs from the old one at the exact
-- boundary the old policy got wrong).
--
-- IMMUTABLE (not just STABLE): pure function of its five scalar inputs, no
-- table access, no session state, no side effects — same inputs always
-- produce the same outputs, which is also exactly what "Preview = Saved"
-- (spec item 10) requires: create_sales_order()/update_sales_order()/
-- preview_sales_order() all call this SAME function with the SAME resolved
-- inputs and are therefore guaranteed byte-for-byte identical results, not
-- merely "written to match" by convention. No has_permission/table access
-- inside — not sensitive (matches the plain-arithmetic pattern of e.g.
-- business_today(), which also carries no REVOKE/GRANT and is left at the
-- Postgres default PUBLIC EXECUTE).
-- ---------------------------------------------------------------------------
create or replace function public.compute_sales_item_costs(
  p_gold_price_per_gram numeric,
  p_manufacturing_fee_per_gram numeric,
  p_vat_rate_percent numeric,
  p_weight_grams numeric,
  p_sale_price numeric
)
returns table (
  gold_component_cost numeric,
  manufacturing_component_cost numeric,
  base_cost numeric,
  vat_cost numeric,
  total_cost numeric,
  gross_profit numeric
)
language plpgsql
immutable
as $$
declare
  v_gold_component numeric;
  v_mfg_component numeric;
  v_base_cost numeric;
  v_vat_cost numeric;
  v_total_cost numeric;
begin
  v_gold_component := round(p_gold_price_per_gram * p_weight_grams, 2);
  v_mfg_component := round(p_manufacturing_fee_per_gram * p_weight_grams, 2);
  -- EXACT — sum of two already-2dp numerics, never itself re-rounded.
  v_base_cost := v_gold_component + v_mfg_component;
  v_vat_cost := round(v_base_cost * p_vat_rate_percent / 100, 2);
  -- EXACT — sum of two already-2dp numerics.
  v_total_cost := v_base_cost + v_vat_cost;

  gold_component_cost := v_gold_component;
  manufacturing_component_cost := v_mfg_component;
  base_cost := v_base_cost;
  vat_cost := v_vat_cost;
  total_cost := v_total_cost;
  -- EXACT — p_sale_price is itself already a 2dp numeric(14,2) at every
  -- call site; total_cost is exact per above, so this subtraction needs no
  -- rounding and, by construction, total_cost + gross_profit = p_sale_price
  -- always holds to the cent.
  gross_profit := p_sale_price - v_total_cost;
  return next;
end;
$$;

comment on function public.compute_sales_item_costs(numeric, numeric, numeric, numeric, numeric) is
  'Patch 3.1 item 8/10 — the single shared reconciling cost-calculation chain used identically by create_sales_order()/update_sales_order()/preview_sales_order() (0068/0069/0070). Rounds gold_component_cost and manufacturing_component_cost to 2dp first, then derives base_cost/vat_cost/total_cost/gross_profit via EXACT arithmetic on already-rounded values — guarantees by construction that gold_component_cost + manufacturing_component_cost = base_cost, base_cost + vat_cost = total_cost, and total_cost + gross_profit = sale_price, for every input, not just common cases. IMMUTABLE, no table access — not sensitive, left at default PUBLIC EXECUTE like business_today().';

-- ---------------------------------------------------------------------------
-- Part B — advisory-lock helpers (spec items 5 and 7).
--
-- Two independent lock "namespaces", each using the two-int32 overloads
-- (pg_advisory_xact_lock(key1, key2) / pg_advisory_xact_lock_shared(key1,
-- key2)) rather than the single-bigint overloads — deliberately, so the two
-- kinds of lock can NEVER collide with each other by hash coincidence: every
-- daily-close lock uses key1 = 1002, every financial-master lock uses key1 =
-- 1001, and Postgres advisory locks are compared as the pair (key1, key2)
-- together, not their combined hash. (A collision between two DIFFERENT
-- (store_id, business_date) pairs hashing to the same key2 within the same
-- key1=1002 namespace remains theoretically possible via hashtext()'s 32-bit
-- range, but is harmless even if it happens — the worst case is a rare,
-- spurious extra wait between two unrelated store/day combinations, never a
-- correctness bug, since advisory locks are used here purely for pacing, not
-- for uniqueness.)
--
-- All four are transaction-scoped (_xact_ variants) — automatically released
-- at COMMIT or ROLLBACK, never leaked by a crashed session, never requiring
-- an explicit unlock call. All four are VOLATILE (the default — never mark a
-- function with real side effects STABLE/IMMUTABLE).
--
-- REVOKE FROM PUBLIC + GRANT TO authenticated (not left at PUBLIC default,
-- unlike compute_sales_item_costs above): these are called directly by
-- SECURITY INVOKER functions that `authenticated` itself calls directly
-- (save_daily_gold_price et al., 0066 — SECURITY INVOKER, so a nested call
-- to a PUBLIC-revoked-but-not-authenticated-granted helper would fail for a
-- real client), so an explicit GRANT TO authenticated is required (the
-- generate_sales_order_number() pattern of "no grant at all, only reachable
-- through a SECURITY DEFINER owner" does NOT work here for that reason). A
-- direct client call to one of these purely acquires-then-immediately-
-- releases-at-transaction-end a lock and returns void — it reads and writes
-- no data, so this direct reachability is not a data-exposure concern, only
-- a bounded pacing one (a misbehaving client could hold a lock for the
-- duration of its own single PostgREST request/transaction at most).
-- ---------------------------------------------------------------------------
create or replace function public.acquire_financial_master_lock_shared()
returns void
language sql
as $$
  select pg_advisory_xact_lock_shared(1001, 0);
$$;

comment on function public.acquire_financial_master_lock_shared() is
  'Patch 3.1 item 7 — SHARED transaction-scoped advisory lock over the single global "financial master data" key (1001, 0). Acquired by create_sales_order()/update_sales_order()/preview_sales_order() before resolving ANY gold price/manufacturing fee/VAT rate snapshot, so that many Sales can resolve snapshots concurrently with each other but never while a financial-master WRITE (save_daily_gold_price et al., which acquire the EXCLUSIVE counterpart) is in flight — closing the "torn snapshot within one order" gap. Released automatically at transaction end.';

create or replace function public.acquire_financial_master_lock_exclusive()
returns void
language sql
as $$
  select pg_advisory_xact_lock(1001, 0);
$$;

comment on function public.acquire_financial_master_lock_exclusive() is
  'Patch 3.1 item 7 — EXCLUSIVE transaction-scoped advisory lock over the single global "financial master data" key (1001, 0). Acquired by every financial-master WRITER (save_daily_gold_price, save_daily_gold_prices_bulk, create_manufacturing_fee_version, create_payment_method_fee_version, create_vat_rate_version — 0066) immediately after their has_permission() check, so a price/fee/VAT write can never commit in the middle of a concurrent Sale''s multi-step snapshot resolution (which holds the SHARED counterpart for its whole resolution window) — the whole Order will always see either fully-old or fully-new financial master data, never a mix. Released automatically at transaction end.';

create or replace function public.acquire_daily_close_lock_shared(p_store_id uuid, p_business_date date)
returns void
language sql
as $$
  select pg_advisory_xact_lock_shared(1002, hashtext(p_store_id::text || ':' || p_business_date::text));
$$;

comment on function public.acquire_daily_close_lock_shared(uuid, date) is
  'Patch 3.1 item 5 — SHARED transaction-scoped advisory lock keyed on (1002, hashtext(store_id||date)). Acquired by create_sales_order()/update_sales_order() (0068/0069) before checking/relying on daily_closings for a given (store_id, sale_date), so many Sales for the SAME day can proceed concurrently with each other but never while close_sales_day() (0071, EXCLUSIVE counterpart) is closing that exact day — closes the "Sale slips in after the day was already closed" race. Released automatically at transaction end.';

create or replace function public.acquire_daily_close_lock_exclusive(p_store_id uuid, p_business_date date)
returns void
language sql
as $$
  select pg_advisory_xact_lock(1002, hashtext(p_store_id::text || ':' || p_business_date::text));
$$;

comment on function public.acquire_daily_close_lock_exclusive(uuid, date) is
  'Patch 3.1 item 5 — EXCLUSIVE transaction-scoped advisory lock keyed on (1002, hashtext(store_id||date)). Acquired by close_sales_day() (0071) — waits for every in-flight create_sales_order()/update_sales_order() holding the SHARED counterpart for this exact (store_id, business_date) to commit or roll back first, then closes the day; any Sale attempted afterward correctly observes the day as closed. Does NOT serialize Sales against each other (different Sales acquire the SHARED lock, which does not block other SHARED holders) — only against an actual Close of that same day. Released automatically at transaction end.';

revoke execute on function public.acquire_financial_master_lock_shared() from public;
grant execute on function public.acquire_financial_master_lock_shared() to authenticated;
revoke execute on function public.acquire_financial_master_lock_exclusive() from public;
grant execute on function public.acquire_financial_master_lock_exclusive() to authenticated;
revoke execute on function public.acquire_daily_close_lock_shared(uuid, date) from public;
grant execute on function public.acquire_daily_close_lock_shared(uuid, date) to authenticated;
revoke execute on function public.acquire_daily_close_lock_exclusive(uuid, date) from public;
grant execute on function public.acquire_daily_close_lock_exclusive(uuid, date) to authenticated;

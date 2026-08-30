-- ============================================================================
-- 0074: Phase 3 — Final Sales Integrity Patch 3.2 (2/8): full-precision
-- rounding engine, DB-level input precision validation, item-level
-- calculation_version
-- ============================================================================
-- Migrations 0001-0072 are unmodified. This migration does NOT modify 0065
-- either — compute_sales_item_costs() is reproduced here with
-- CREATE OR REPLACE (same name, same parameter list, same RETURNS TABLE
-- shape, so every existing call site in 0068/0069/0070 keeps working
-- unchanged) but with a corrected body, as its own new migration, per the
-- user's explicit instruction that new fixes start at 0073+ rather than
-- editing files in place.
--
-- ---------------------------------------------------------------------------
-- Part A — why 0065's rounding policy must change (spec item 3).
--
-- 0065 rounds the two BASE COMPONENTS (gold, manufacturing) to 2dp FIRST,
-- then derives base_cost/vat_cost/total_cost/gross_profit by exact
-- arithmetic on those already-rounded components. That construction
-- guarantees reconciliation (component sums always add up to the cent) but
-- it rounds intermediate financial values BEFORE the VAT step, which can
-- silently shift the true total away from what the full-precision formula
-- would produce. Concrete regression the user requires this migration to
-- fix (Gold=300.1234, Manufacturing=10.1234, Weight=0.0250, VAT=15%):
--   0065's approach: gold_component=round(300.1234*0.0250,2)=round(7.503085,2)=7.50,
--     mfg_component=round(10.1234*0.0250,2)=round(0.253085,2)=0.25,
--     base_cost=7.75, vat_cost=round(7.75*0.15,2)=round(1.1625,2)=1.16,
--     total_cost=8.91  <-- WRONG: one cent short of the true total.
--   Full-precision official formula: raw_base=(300.1234+10.1234)*0.0250=
--     7.75617, raw_total=7.75617*1.15=8.9195955, total_cost=round(8.9195955,2)
--     =8.92  <-- the value the spec mandates.
--
-- Fix: keep every intermediate value in full-precision NUMERIC all the way
-- through the formula chain, and round ONLY at the two financial OUTPUT
-- boundaries (base_cost, total_cost) — never round a component and then
-- feed that rounded component into a further calculation. The per-component
-- breakdown needed for display/audit (gold_component_cost,
-- manufacturing_component_cost, vat_cost) is then derived by ALLOCATION
-- against the already-rounded totals, not by independently rounding each
-- component up front:
--   raw_gold  = gold_price_per_gram * weight_grams
--   raw_mfg   = manufacturing_fee_per_gram * weight_grams
--   raw_base  = raw_gold + raw_mfg
--   raw_total = raw_base * (1 + vat_rate_percent/100)
--   base_cost  = round(raw_base, 2)                        -- output boundary #1
--   total_cost = round(raw_total, 2)                        -- output boundary #2
--   gross_profit = sale_price - total_cost                  -- EXACT: both operands already 2dp
--   gold_component_cost = round(raw_gold, 2)                 -- allocation, not a second raw value
--   manufacturing_component_cost = base_cost - gold_component_cost   -- EXACT, makes the two sum to base_cost by construction
--   vat_cost = total_cost - base_cost                        -- EXACT, makes base_cost+vat_cost=total_cost by construction
-- This keeps ALL FOUR invariants the spec requires — gold_component_cost +
-- manufacturing_component_cost = base_cost; base_cost + vat_cost =
-- total_cost; total_cost + gross_profit = sale_price — while computing
-- total_cost itself from the true full-precision formula, never from a sum
-- of pre-rounded components.
--
-- Verified against BOTH mandatory examples:
--  1) User's new regression (Gold=300.1234, Manufacturing=10.1234,
--     Weight=0.0250, VAT=15%): raw_gold=7.503085, raw_mfg=0.253085,
--     raw_base=7.75617, raw_total=8.9195955 -> base_cost=7.76,
--     total_cost=8.92 (matches spec exactly) -> gold_component_cost=7.50,
--     manufacturing_component_cost=7.76-7.50=0.26, vat_cost=8.92-7.76=1.16.
--     Reconciliation: 7.50+0.26=7.76=base_cost [ok]; 7.76+1.16=8.92=total_cost [ok].
--  2) Original Patch 3.1 worked example, which must NOT regress
--     (Gold=300, Manufacturing=10, Weight=0.0100, VAT=15%, Sale=100):
--     raw_gold=3.00, raw_mfg=0.10, raw_base=3.10, raw_total=3.565 ->
--     base_cost=3.10, total_cost=round(3.565,2)=3.57 (Postgres rounds
--     half-away-from-zero, confirmed empirically) -> gold_component_cost=3.00,
--     manufacturing_component_cost=3.10-3.00=0.10, vat_cost=3.57-3.10=0.47,
--     gross_profit=100-3.57=96.43. IDENTICAL to the numbers
--     sales_integrity_patch_3_1.test.sql sections L/L2 already assert
--     (3.57/96.43), because this specific example's inputs are already
--     2dp-clean at the component level, so no existing test expectation
--     needs to change for it — satisfying "لا تغيّر test expectation فقط
--     حتى يصبح Green" for this pre-existing case; the NEW example above is
--     the one that actually could not pass under the old policy and now
--     does under the new one.
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
  v_raw_gold numeric;
  v_raw_mfg numeric;
  v_raw_base numeric;
  v_raw_total numeric;
  v_base_cost numeric;
  v_total_cost numeric;
  v_gold_component numeric;
  v_mfg_component numeric;
  v_vat_cost numeric;
begin
  -- Full-precision intermediate values — NEVER rounded before this point.
  v_raw_gold := p_gold_price_per_gram * p_weight_grams;
  v_raw_mfg := p_manufacturing_fee_per_gram * p_weight_grams;
  v_raw_base := v_raw_gold + v_raw_mfg;
  v_raw_total := v_raw_base * (1 + p_vat_rate_percent / 100);

  -- The only two rounding points in the entire calculation: the real
  -- financial OUTPUT boundaries.
  v_base_cost := round(v_raw_base, 2);
  v_total_cost := round(v_raw_total, 2);

  -- Component breakdown via allocation against the already-rounded totals
  -- (not via independently rounding a second raw value) so the breakdown
  -- reconciles to the cent by construction, without ever feeding a rounded
  -- component back into the total_cost calculation itself.
  v_gold_component := round(v_raw_gold, 2);
  v_mfg_component := v_base_cost - v_gold_component;
  v_vat_cost := v_total_cost - v_base_cost;

  gold_component_cost := v_gold_component;
  manufacturing_component_cost := v_mfg_component;
  base_cost := v_base_cost;
  vat_cost := v_vat_cost;
  total_cost := v_total_cost;
  -- EXACT — p_sale_price is already 2dp at every call site, total_cost is
  -- already rounded above, so total_cost + gross_profit = p_sale_price
  -- always holds to the cent.
  gross_profit := p_sale_price - v_total_cost;
  return next;
end;
$$;

comment on function public.compute_sales_item_costs(numeric, numeric, numeric, numeric, numeric) is
  'Patch 3.2 item 3 (supersedes the 0065 body, same signature/shape) — full-precision reconciling cost-calculation chain. Every intermediate value (raw_gold, raw_mfg, raw_base, raw_total) stays unrounded NUMERIC through the whole formula; base_cost and total_cost are rounded ONLY at the true output boundary directly from the full-precision raw_base/raw_total (never from a sum of pre-rounded components); the component breakdown (gold_component_cost, manufacturing_component_cost, vat_cost) is then derived by allocation against the rounded totals so gold_component_cost + manufacturing_component_cost = base_cost, base_cost + vat_cost = total_cost, and total_cost + gross_profit = sale_price all hold by construction for every input. Still IMMUTABLE, no table access, PUBLIC EXECUTE (unchanged from 0065) — used identically by create_sales_order()/update_sales_order()/preview_sales_order()/preview_update_sales_order().';

-- ---------------------------------------------------------------------------
-- Part B — DB-level input precision/scale/bounds validation (spec item 4).
--
-- Problem: JSON item inputs are cast to ::numeric and fed straight into
-- compute_sales_item_costs() / stored directly, before ever being forced to
-- the final columns' actual scale (weight_grams numeric(10,4), sale_price
-- numeric(14,2) — confirmed against 0059's column definitions). A crafted
-- RPC call can send e.g. weight_grams=1.00005 or sale_price=100.005: the
-- CALCULATION would use the full crafted value while the STORED row is
-- silently rounded by Postgres's implicit numeric(10,4)/numeric(14,2) cast
-- on INSERT/UPDATE to a *different* value than what was calculated with —
-- and because compute_sales_item_costs() is called with the raw (not yet
-- column-cast) value, two items each sent as sale_price=100.005 could each
-- calculate against 100.005 while each STORING as 100.01, silently
-- breaking subtotal = SUM(stored sale_price) if the order-level total were
-- ever built from the raw payload instead of the stored rows.
--
-- Fix: reject over-precision and out-of-bounds input OUTRIGHT (never
-- silently round it) before it reaches compute_sales_item_costs() or any
-- INSERT/UPDATE — the DB is the sole source of truth for what is
-- acceptable, Zod/UI validation is a UX mirror only, never the authority.
-- scale(numeric) is a built-in Postgres function retursning the number of
-- digits after the decimal point of the actual value passed (not the
-- column) — exactly what is needed to catch e.g. 1.00005 (scale 5) before
-- it is ever compared against or stored into a numeric(10,4) column.
--
-- Bounds are derived directly from each column's declared precision/scale
-- (0059): weight_grams numeric(10,4) => 10 total digits, 4 fractional =>
-- integer part is at most 10-4=6 digits => the value itself must be
-- strictly less than 10^6 (1,000,000); sale_price numeric(14,2) => 14 total
-- digits, 2 fractional => integer part at most 12 digits => value must be
-- strictly less than 10^12. (Both columns already CHECK weight_grams > 0 /
-- sale_price >= 0 at the table level — this function additionally enforces
-- the upper bound and the scale, ahead of calculation, with a clear Arabic
-- message rather than a raw Postgres "numeric field overflow" error.)
--
-- IMMUTABLE: pure validation of its two scalar inputs, no table access, no
-- side effects — safe to call from create_sales_order(), update_sales_order(),
-- preview_sales_order(), and preview_update_sales_order() alike, and to run
-- BEFORE any calculation, exactly as the spec requires ("قبل أي حساب").
-- Left at default PUBLIC EXECUTE, matching compute_sales_item_costs() and
-- business_today() — pure arithmetic validation, not sensitive.
-- ---------------------------------------------------------------------------
create or replace function public.validate_sales_item_precision(
  p_weight_grams numeric,
  p_sale_price numeric
)
returns void
language plpgsql
immutable
as $$
begin
  if p_weight_grams is null or p_sale_price is null then
    raise exception 'الوزن وسعر البيع مطلوبان' using errcode = 'P0001';
  end if;

  if scale(p_weight_grams) > 4 then
    raise exception 'الوزن يجب ألا يتجاوز 4 منازل عشرية' using errcode = 'P0001';
  end if;

  if scale(p_sale_price) > 2 then
    raise exception 'سعر البيع يجب ألا يتجاوز منزلتين عشريتين' using errcode = 'P0001';
  end if;

  -- Upper bounds matching each column's declared precision (10,4) / (14,2)
  -- respectively — the table-level CHECK constraints already cover the
  -- lower bound (weight_grams > 0 / sale_price >= 0), so only the upper
  -- bound needs enforcing here, ahead of calculation.
  if p_weight_grams >= 1000000 then
    raise exception 'الوزن خارج النطاق المسموح به' using errcode = 'P0001';
  end if;

  if p_sale_price >= 1000000000000 then
    raise exception 'سعر البيع خارج النطاق المسموح به' using errcode = 'P0001';
  end if;
end;
$$;

comment on function public.validate_sales_item_precision(numeric, numeric) is
  'Patch 3.2 item 4 — rejects (never silently rounds) any sales item input whose weight_grams exceeds 4 decimal places or 6 integer digits, or whose sale_price exceeds 2 decimal places or 12 integer digits, matching sales_order_items.weight_grams numeric(10,4) / sale_price numeric(14,2) exactly (0059). Must be called BEFORE compute_sales_item_costs() and before any INSERT/UPDATE, from create_sales_order(), update_sales_order(), preview_sales_order(), and preview_update_sales_order() alike, so calculation and storage can never observe two different values for the same input. IMMUTABLE, no table access, PUBLIC EXECUTE.';

-- ---------------------------------------------------------------------------
-- Part C — item-level calculation_version (spec item 7, column only; the
-- stamping logic lives in the 0075/0076 create/update rewrites).
--
-- sales_orders.calculation_version already exists (0059) but has stayed at
-- its default 1 for every order, even after Patch 3.1 fundamentally changed
-- the calculation engine — meaning old and new Sales are currently
-- indistinguishable by version number, which will break Returns/Reports'
-- ability to interpret historical calculations precisely once that phase
-- starts. This migration only adds the missing ITEM-level column; existing
-- rows default to 1 (Legacy Version 1, matching the pre-Patch-3.2 engine
-- that produced them) and are NOT retroactively recomputed just to change
-- their version number stamp (the spec explicitly forbids this). The
-- Patch 3.2 engine (this migration''s compute_sales_item_costs() +
-- validate_sales_item_precision()) is Version 2; 0075/0076 stamp every
-- newly-created item and every item whose financials are actually
-- recalculated as version 2, while an edited order''s untouched items keep
-- whatever version they already had — an order can legitimately contain a
-- mix (e.g. item A legacy v1, item B recalculated v2) after an edit, and
-- this is intentional, documented behavior, not a bug.
-- ---------------------------------------------------------------------------
alter table public.sales_order_items
  add column if not exists calculation_version integer not null default 1;

comment on column public.sales_order_items.calculation_version is
  'Patch 3.2 item 7 — per-item cost-engine version stamp. 1 = legacy (pre-Patch-3.2 component-early-rounding engine, or any item never recalculated since). 2 = Patch 3.2 full-precision engine (compute_sales_item_costs() as of 0074), stamped on every newly-created item and every item whose financial inputs are actually recalculated on update. An untouched item keeps its existing version across an edit — a single order can legitimately mix versions across its items. This is distinct from the order-level sales_orders.calculation_version (0059), which reflects the order/payment-aggregate engine version, not any single item''s cost engine.';

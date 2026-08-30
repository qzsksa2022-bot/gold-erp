-- ============================================================================
-- 0052: Financial Integrity Patch 2.2 (2/4) — finance-safe read boundary
-- ============================================================================
-- Spec item 2. Postgres's own NUMERIC->JSON cast never loses precision
-- (jsonb preserves the original numeric text internally) -- the precision
-- risk is entirely at the JSON-DECODE step on the client: PostgREST
-- serializes a `numeric` column as an UNQUOTED JSON number token by
-- default, and the moment ANY JSON client decodes that token (a browser's
-- `JSON.parse`, `fetch().json()`, `supabase-js`'s `.select()`/`.rpc()`), it
-- becomes an IEEE-754 double -- which cannot exactly represent every value
-- a NUMERIC column can hold. A prior version of this patch's own commentary
-- (0047-era) incorrectly claimed `supabase gen types typescript` maps
-- `numeric` to TypeScript `string` -- it does not; the real, current
-- postgres-meta/Supabase typegen maps `numeric` to `number`, precisely
-- because PostgREST really does return it as a JSON number by default. A
-- hand-written `string` type in src/types/database.ts changes nothing about
-- the actual runtime value PostgREST sends -- see scripts/check-numeric-
-- column-types.ts's rewritten header comment (this patch) for the corrected
-- explanation, and DELIVERY_REPORT.md's Patch 2.2 appendix for how this was
-- verified against a REAL PostgREST server over real HTTP.
--
-- The only way to make a financial value survive the JSON boundary losslessly
-- is to never let PostgREST encode it as a JSON number in the first place --
-- cast it to `text` INSIDE Postgres, before it is ever serialized. A `numeric`
-- column cast `::text` is serialized as a QUOTED JSON string (Postgres's own
-- `to_json(text)` behavior), which JSON.parse decodes losslessly (it is
-- already a string -- no IEEE-754 conversion ever happens), and
-- src/lib/decimal.ts's toDecimal() accepts a string directly.
--
-- This migration adds "_safe" text-returning siblings to the four read
-- functions Sales/future code needs for financial values -- it does NOT
-- remove or change the existing numeric-returning functions (0041/0042/0045
-- are unmodified; those keep returning `numeric` for any internal SQL-to-SQL
-- caller that needs to do arithmetic in Postgres itself). Any FUTURE
-- application code (Sales, Returns, Settlements, ...) that reads a financial
-- value which will flow into a JavaScript Decimal computation MUST call the
-- "_safe" variant below, never the numeric-returning original, and must
-- never call Number() on the result -- feed the string straight into
-- toDecimal()/src/lib/decimal.ts.
-- ---------------------------------------------------------------------------
create or replace function public.gold_price_for_karat_on_date_safe(p_karat_id uuid, p_date date default current_date)
returns text
language sql
stable
as $$
  select public.gold_price_for_karat_on_date(p_karat_id, p_date)::text;
$$;

comment on function public.gold_price_for_karat_on_date_safe(uuid, date) is
  'Finance-safe sibling of gold_price_for_karat_on_date() (0041): identical resolution logic, but returns the price cast ::text so PostgREST serializes it as a quoted JSON string instead of an unquoted JSON number -- lossless across the JSON boundary regardless of precision. Any future JS/TS caller that will feed this value into a financial calculation (src/lib/decimal.ts) MUST call this function, not the numeric-returning original, and MUST NOT call Number() on the result. SECURITY INVOKER; RLS (gold_prices.view) governs access exactly like the original.';

create or replace function public.manufacturing_fee_for_karat_on_date_safe(p_karat_id uuid, p_date date default current_date)
returns text
language sql
stable
as $$
  select public.manufacturing_fee_for_karat_on_date(p_karat_id, p_date)::text;
$$;

comment on function public.manufacturing_fee_for_karat_on_date_safe(uuid, date) is
  'Finance-safe sibling of manufacturing_fee_for_karat_on_date() (0042) -- see gold_price_for_karat_on_date_safe() comment above for the full rationale, identical pattern.';

create or replace function public.payment_fee_for_method_on_date_safe(p_payment_method_id uuid, p_date date default current_date)
returns table (fee_version_id uuid, percentage_fee text, fixed_fee text)
language sql
stable
as $$
  select v.fee_version_id, v.percentage_fee::text, v.fixed_fee::text
  from public.payment_fee_for_method_on_date(p_payment_method_id, p_date) v;
$$;

comment on function public.payment_fee_for_method_on_date_safe(uuid, date) is
  'Finance-safe sibling of payment_fee_for_method_on_date() (0045) -- both percentage_fee and fixed_fee are cast ::text so PostgREST serializes both as quoted JSON strings. See gold_price_for_karat_on_date_safe() comment above for the full rationale.';

-- No REVOKE/GRANT needed beyond default PUBLIC EXECUTE -- these are plain
-- SECURITY INVOKER read functions, exactly like the three they wrap; access
-- is governed by RLS on the underlying tables (via the wrapped functions),
-- not by function-level EXECUTE privilege, matching the existing pattern for
-- gold_price_for_karat_on_date()/manufacturing_fee_for_karat_on_date()/
-- payment_fee_for_method_on_date() themselves.

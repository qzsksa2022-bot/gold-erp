-- ============================================================================
-- 0057: Final Date Consistency Hotfix 2.2.2 — Business Date for the
-- finance-safe RPCs and gold-price read functions' "today" default
-- ============================================================================
-- Migrations 0001-0056 are unmodified -- every change here starts at 0057.
-- Does NOT touch Decimal safe transport, return types, the ::text boundary,
-- RLS, Versioning, or anything 0055/0056 already did -- this migration
-- changes exactly one thing, in exactly six function signatures: the
-- DEFAULT VALUE of a `p_date` parameter, from Postgres' own `current_date`
-- to `public.business_today()` (0056). No TypeScript API signature changes
-- (the parameter shape -- name, type, optionality -- is identical; only the
-- server-side default a caller gets by omitting p_date changes), no
-- behavior change whatsoever for any caller that already passes p_date
-- explicitly.
--
-- ---------------------------------------------------------------------------
-- The gap, precisely: 0056 gave create_manufacturing_fee_version()/create_
-- payment_method_fee_version()/cancel_manufacturing_fee_version()/cancel_
-- payment_method_fee_version()/manufacturing_fee_for_karat_on_date()/
-- payment_fee_for_method_on_date() a Riyadh-correct "today" via public.
-- business_today() -- but the THREE finance-safe "_safe" RPCs added in
-- 0052 (the exact RPCs Sales/future code is required to use for any
-- financial value, per Patch 2.2's own mandate) were never touched by 0056,
-- and still carry `p_date date default current_date`. Each "_safe" function
-- is a thin SQL wrapper that calls its underlying function with an
-- EXPLICIT p_date argument:
--
--   select public.manufacturing_fee_for_karat_on_date(p_karat_id, p_date)::text;
--
-- When a caller omits p_date, Postgres resolves the "_safe" wrapper's OWN
-- default (current_date) BEFORE ever entering the wrapper body, and that
-- already-resolved value is what gets passed explicitly into the
-- underlying function -- the underlying function's own `business_today()`
-- default (0056) is a parameter default too, and an explicitly-passed
-- argument always overrides a callee's default, no matter what that
-- default is. In other words: 0056's fix silently never takes effect for
-- any "_safe" call that omits p_date, precisely the call shape Sales is
-- required to use. This is real, not theoretical: during the ~3-hour
-- window each day (21:00-23:59 UTC) where Asia/Riyadh has already entered
-- the next calendar day while this project's Postgres server (UTC
-- timezone) has not, `gold_price_for_karat_on_date_safe(p_karat_id)` called
-- with no p_date would resolve "today" to the WRONG (still-previous)
-- calendar day -- exactly the class of bug 0056 set out to close, reopened
-- through a sibling function 0056 never touched.
--
-- gold_price_for_karat_on_date()/gold_prices_missing_for_date() (0041) have
-- the identical `default current_date` gap in their own right -- they were
-- out of scope for 0056 (which was scoped to Manufacturing/Payment Fee
-- versioning only, by explicit prior instruction), but this hotfix's own
-- explicit scope now names them directly: any function whose default means
-- "today" must mean Asia/Riyadh's today, full stop, before Phase 2 is
-- considered final.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- gold_price_for_karat_on_date() / gold_prices_missing_for_date() (0041):
-- only the default parameter value changes -- resolution logic is
-- byte-for-byte identical to 0041's version. A caller passing an explicit
-- p_date is entirely unaffected either way.
-- ---------------------------------------------------------------------------
create or replace function public.gold_price_for_karat_on_date(p_karat_id uuid, p_date date default public.business_today())
returns numeric
language plpgsql
stable
as $$
declare
  v_price numeric;
begin
  select price_per_gram into v_price
  from public.daily_gold_prices
  where karat_id = p_karat_id and price_date = p_date;

  if v_price is null then
    raise exception 'لا يوجد سعر ذهب مسجَّل لهذا العيار بتاريخ %', p_date using errcode = 'P0001';
  end if;

  return v_price;
end;
$$;

comment on function public.gold_price_for_karat_on_date(uuid, date) is
  'Gold price per gram for a karat on an exact date. Raises P0001 (not NULL/0) if no price was recorded for that exact date — callers must not silently treat a missing price as free/zero. SECURITY INVOKER; RLS (gold_prices.view) governs access as usual. As of 0057: default p_date is public.business_today() (Asia/Riyadh calendar date, 0056), not Postgres'' current_date (the database server''s own timezone) — see migration 0057 header comment.';

create or replace function public.gold_prices_missing_for_date(p_date date default public.business_today())
returns setof public.karats
language sql
stable
as $$
  select k.* from public.karats k
  where k.status = 'active'
    and not exists (
      select 1 from public.daily_gold_prices p
      where p.karat_id = k.id and p.price_date = p_date
    )
  order by k.sort_order, k.code;
$$;

comment on function public.gold_prices_missing_for_date(date) is
  'Active karats with no daily_gold_prices row for the given date (defaults to public.business_today(), Asia/Riyadh — as of 0057, not current_date). Discoverability hook only — no notification is sent by this function; a future scheduler/dashboard widget consumes it.';

-- ---------------------------------------------------------------------------
-- The three finance-safe "_safe" RPCs (0052): only the default parameter
-- value changes. Every other line -- including the underlying function call
-- and the ::text cast that makes these the finance-safe boundary in the
-- first place -- is byte-for-byte identical to 0052's version. Return types
-- (`text`) and the Decimal-safe transport property are completely
-- unaffected; this migration changes what "today" resolves to when a
-- caller omits p_date, nothing else.
-- ---------------------------------------------------------------------------
create or replace function public.gold_price_for_karat_on_date_safe(p_karat_id uuid, p_date date default public.business_today())
returns text
language sql
stable
as $$
  select public.gold_price_for_karat_on_date(p_karat_id, p_date)::text;
$$;

comment on function public.gold_price_for_karat_on_date_safe(uuid, date) is
  'Finance-safe sibling of gold_price_for_karat_on_date() (0041): identical resolution logic, but returns the price cast ::text so PostgREST serializes it as a quoted JSON string instead of an unquoted JSON number -- lossless across the JSON boundary regardless of precision. Any future JS/TS caller that will feed this value into a financial calculation (src/lib/decimal.ts) MUST call this function, not the numeric-returning original, and MUST NOT call Number() on the result. SECURITY INVOKER; RLS (gold_prices.view) governs access exactly like the original. As of 0057: default p_date is public.business_today() (Asia/Riyadh, 0056), not current_date -- see migration 0057 header comment for why this matters specifically for a caller that omits p_date.';

create or replace function public.manufacturing_fee_for_karat_on_date_safe(p_karat_id uuid, p_date date default public.business_today())
returns text
language sql
stable
as $$
  select public.manufacturing_fee_for_karat_on_date(p_karat_id, p_date)::text;
$$;

comment on function public.manufacturing_fee_for_karat_on_date_safe(uuid, date) is
  'Finance-safe sibling of manufacturing_fee_for_karat_on_date() (0042/0056) -- see gold_price_for_karat_on_date_safe() comment above for the full rationale, identical pattern. As of 0057: default p_date is public.business_today(), not current_date.';

create or replace function public.payment_fee_for_method_on_date_safe(p_payment_method_id uuid, p_date date default public.business_today())
returns table (fee_version_id uuid, percentage_fee text, fixed_fee text)
language sql
stable
as $$
  select v.fee_version_id, v.percentage_fee::text, v.fixed_fee::text
  from public.payment_fee_for_method_on_date(p_payment_method_id, p_date) v;
$$;

comment on function public.payment_fee_for_method_on_date_safe(uuid, date) is
  'Finance-safe sibling of payment_fee_for_method_on_date() (0045/0056) -- both percentage_fee and fixed_fee are cast ::text so PostgREST serializes both as quoted JSON strings. See gold_price_for_karat_on_date_safe() comment above for the full rationale. As of 0057: default p_date is public.business_today(), not current_date.';

-- No REVOKE/GRANT changes for any of the six functions above -- unchanged
-- from 0041/0052 (plain PUBLIC EXECUTE, SECURITY INVOKER; access governed
-- by RLS on the underlying tables via the wrapped functions, exactly as
-- before this migration).

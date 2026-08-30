-- ============================================================================
-- 0073: Phase 3 — Final Sales Integrity Patch 3.2 (1/8): close the direct-
-- write bypass of the financial-master exclusive lock on daily_gold_prices
-- ============================================================================
-- Migrations 0001-0072 are unmodified (per spec: "لا تعدل migrations من
-- 0001 إلى 0072" / "كل الإصلاحات الجديدة تبدأ من 0073 وما بعده").
--
-- Problem (Patch 3.2 spec item 1): 0066 added
-- acquire_financial_master_lock_exclusive() INSIDE save_daily_gold_price()
-- and save_daily_gold_prices_bulk() — but 0041's RLS policies
-- (daily_gold_prices_insert / daily_gold_prices_update) still allow any
-- holder of gold_prices.edit to INSERT/UPDATE public.daily_gold_prices
-- DIRECTLY via PostgREST, completely bypassing both RPCs and therefore
-- never acquiring the exclusive lock. A multi-item Sale that has taken the
-- SHARED financial-master lock (via acquire_financial_master_lock_shared(),
-- 0068/0069) to guarantee every item in the order resolves its gold-price
-- snapshot against ONE consistent moment in time can have that guarantee
-- silently broken by a concurrent direct write that never waits for
-- anything.
--
-- Fix: move the lock acquisition to the TABLE itself via a BEFORE STATEMENT
-- trigger, so it fires for every write path without exception —
-- authenticated PostgREST direct writes, the existing RPCs, service_role,
-- and any future trusted integration that writes this table — none of them
-- can be a route around it, because none of them can insert/update a row
-- without the table's own trigger firing first. This is deliberately NOT a
-- modification of 0066: save_daily_gold_price()/save_daily_gold_prices_bulk()
-- keep their own explicit acquire_financial_master_lock_exclusive() call
-- exactly as 0066 left it, and the new trigger below acquires the SAME lock
-- a second time in the same code path when those RPCs run. This is safe and
-- intentional: pg_advisory_xact_lock() is RE-ENTRANT within one session/
-- transaction — a session already holding the exclusive lock can acquire it
-- again without blocking on itself and without any deadlock risk, and the
-- lock is released once, automatically, at the end of the transaction. RLS
-- policies are bypassed by BYPASSRLS/service_role, but triggers are NEVER
-- bypassed by BYPASSRLS — only policy evaluation is — so this closes the
-- bypass for every present and future writer, including service_role.
--
-- BEFORE STATEMENT (not BEFORE ROW) is deliberate: it fires exactly once
-- per statement regardless of how many rows that statement touches (a
-- single-row UPDATE, a multi-row INSERT via save_daily_gold_prices_bulk(),
-- or a raw multi-row PostgREST bulk INSERT all acquire the lock exactly
-- once), it needs no access to NEW/OLD (there is nothing row-specific about
-- "is anyone else in the middle of building Sale snapshots right now"), and
-- it runs before any row of the statement is written, so the exclusive hold
-- is in place for the statement's entire effect.
--
-- No REVOKE/GRANT changes are required: trigger functions cannot be invoked
-- directly by any client, only fired by the table's own INSERT/UPDATE.
-- ----------------------------------------------------------------------------

create or replace function public.enforce_daily_gold_prices_financial_lock()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- Acquire (or re-acquire, harmlessly, if already held by this same
  -- transaction via save_daily_gold_price()/save_daily_gold_prices_bulk())
  -- the exclusive financial-master lock before this statement is allowed to
  -- proceed. Any concurrent Sale currently holding the SHARED lock while it
  -- resolves multi-item price snapshots will block this statement until
  -- that Sale's transaction commits or rolls back — and any writer here
  -- will likewise block a Sale from acquiring the shared lock until this
  -- statement's transaction finishes, so the two can never interleave.
  perform public.acquire_financial_master_lock_exclusive();

  -- BEFORE STATEMENT triggers must return null; the return value is
  -- ignored for statement-level triggers, but a non-null return value on a
  -- row-level trigger would replace the row, so returning null is the
  -- correct/only valid contract here regardless.
  return null;
end;
$$;

drop trigger if exists daily_gold_prices_financial_lock_trigger on public.daily_gold_prices;

create trigger daily_gold_prices_financial_lock_trigger
  before insert or update on public.daily_gold_prices
  for each statement
  execute function public.enforce_daily_gold_prices_financial_lock();

comment on function public.enforce_daily_gold_prices_financial_lock() is
  'Patch 3.2 item 1: acquires the exclusive financial-master advisory lock before ANY insert/update statement on daily_gold_prices, regardless of write path (direct PostgREST, RPC, service_role), closing the lock-bypass that a direct table write around save_daily_gold_price()/save_daily_gold_prices_bulk() previously allowed.';

-- ============================================================================
-- 0123: Shipping Integrity Patch 5.1 (2/10): table-level exclusive rate lock
-- covering EVERY write path, not just the RPCs
-- ============================================================================
-- Migrations 0001-0122 are unmodified. Patch 5.1 item 4: acquire_shipping_
-- rates_lock_exclusive() (0113) was only ever called explicitly INSIDE
-- create_shipping_carrier_rate_version()/cancel_shipping_carrier_rate_
-- version()/create_customer_return_shipping_fee_version()/cancel_customer_
-- return_shipping_fee_version() (0114/0115/0122) — a hypothetical trusted
-- service_role/direct-SQL write that skipped those RPCs entirely would never
-- acquire it. Fixed with the EXACT same BEFORE STATEMENT trigger pattern
-- Sales Integrity Patch 3.2 (0073) already established for daily_gold_prices
-- (enforce_daily_gold_prices_financial_lock()) — see that migration for the
-- full rationale (re-entrant advisory lock, BEFORE STATEMENT not BEFORE ROW,
-- triggers are never bypassed by BYPASSRLS even though RLS policies are).
--
-- Hotfix 3.2.1 (0081) lesson explicitly called out by this patch's own spec
-- (item 4): a SECURITY INVOKER trigger runs under the CALLING role's own
-- privileges, so BOTH `authenticated` (already granted, 0113) AND
-- `service_role` must independently hold EXECUTE on acquire_shipping_rates_
-- lock_exclusive() or that role's writes are hard-blocked with "permission
-- denied for function acquire_shipping_rates_lock_exclusive" instead of
-- correctly waiting on/holding the lock. `anon` remains ungranted — anon
-- has no legitimate path to write these tables at all.
-- ---------------------------------------------------------------------------
grant execute on function public.acquire_shipping_rates_lock_exclusive() to service_role;

comment on function public.acquire_shipping_rates_lock_exclusive() is
  'Phase 5 — EXCLUSIVE transaction-scoped advisory lock keyed on (1005, 0). Acquired by create/cancel_shipping_carrier_rate_version() and create/cancel_customer_return_shipping_fee_version() (0114/0115/0122) immediately after the permission check, AND (as of Patch 5.1, 0123) by a BEFORE STATEMENT trigger on both versioning tables covering every write path unconditionally. pg_advisory_xact_lock() is re-entrant within one transaction, so a call already holding the lock via the RPC acquires it again harmlessly when the trigger also fires in the same statement. EXECUTE granted to `authenticated` (0113) AND `service_role` (0123, Hotfix-3.2.1-style fix) — `anon` remains ungranted. Released automatically at transaction end.';

create or replace function public.enforce_shipping_rates_table_lock()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- Acquire (or re-acquire, harmlessly) the exclusive shipping-rates
  -- advisory lock before this statement is allowed to proceed — closes the
  -- lock-bypass a direct write around the create/cancel_*_version() RPCs
  -- would otherwise have. Any concurrent create_shipment()/preview_*()
  -- holding the SHARED counterpart while it resolves a rate snapshot will
  -- block this statement until that transaction commits/rolls back, and any
  -- writer here will likewise block a shipment from acquiring the shared
  -- lock until this statement's transaction finishes — the two can never
  -- interleave, and a shipment always sees either fully-old or fully-new
  -- rate configuration, never a torn mix.
  perform public.acquire_shipping_rates_lock_exclusive();

  -- BEFORE STATEMENT triggers must return null; the return value is
  -- ignored for statement-level triggers.
  return null;
end;
$$;

comment on function public.enforce_shipping_rates_table_lock() is
  'Patch 5.1 item 4 — acquires the exclusive shipping-rates advisory lock before ANY insert/update statement on shipping_carrier_rate_versions/customer_return_shipping_fee_versions, regardless of write path (direct PostgREST — now impossible after 0122''s RLS lockdown, but this trigger is unconditional and does not rely on that — RPC, service_role, or any future trusted integration). SECURITY INVOKER (default) so it runs under the calling role''s own privileges; that role must independently hold EXECUTE on acquire_shipping_rates_lock_exclusive() (granted to authenticated + service_role).';

drop trigger if exists shipping_carrier_rate_versions_table_lock_trigger on public.shipping_carrier_rate_versions;

create trigger shipping_carrier_rate_versions_table_lock_trigger
  before insert or update on public.shipping_carrier_rate_versions
  for each statement
  execute function public.enforce_shipping_rates_table_lock();

drop trigger if exists customer_return_shipping_fee_versions_table_lock_trigger on public.customer_return_shipping_fee_versions;

create trigger customer_return_shipping_fee_versions_table_lock_trigger
  before insert or update on public.customer_return_shipping_fee_versions
  for each statement
  execute function public.enforce_shipping_rates_table_lock();

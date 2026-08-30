-- ============================================================================
-- 0051: Financial Integrity Patch 2.2 (1/4) — gold price source integrity
-- ============================================================================
-- Foundation (0001-0039), Phase 2 (0040-0046), and Financial Integrity Patch
-- 2.1 (0047-0050) are all closed and NOT modified here — every change in
-- this patch starts at 0051. This patch closes three specific, narrow gaps
-- a follow-up review found in the actual shipped code (not a new general
-- security review), and does NOT open Sales/Returns/Shipments/Settlements.
--
-- Gap closed here (spec item 1): 0050's save_daily_gold_prices_bulk() (and
-- 0041's save_daily_gold_price()) always hardcode source_type='manual',
-- is_manual_override=true when writing THROUGH those RPCs -- but
-- daily_gold_prices (0041) still has its ORIGINAL direct RLS INSERT/UPDATE
-- policies for any `authenticated` actor holding gold_prices.edit,
-- unchanged since 0041 (0047's write-lockdown only ever touched the two
-- Versioning tables, not this one -- see 0047's own header comment). That
-- means an ordinary authenticated user could always bypass both RPCs
-- entirely with a direct PostgREST INSERT/UPDATE and set
-- source_type='external_api', source_name/source_reference to anything, and
-- is_manual_override=false -- fabricating a price as if it came from a
-- trusted automated feed that does not exist yet in this project.
--
-- Design choice (documented, not just implemented): a BEFORE INSERT OR
-- UPDATE trigger that pins source_type/source_name/source_reference/
-- is_manual_override to safe manual defaults for any write NOT made from a
-- trusted bootstrap context (public.is_trusted_bootstrap_context(), 0013 --
-- true for service_role or a direct-SQL/auth.uid()-is-null connection),
-- rather than closing the direct RLS write path entirely (the approach
-- 0047 took for the two Versioning tables). Reasons this table gets the
-- trigger approach instead:
--   1. Unlike a fee VERSION (whose value can never legitimately change once
--      it exists), a daily price row is legitimately correctable in place
--      by a human all day -- 0041's own save_daily_gold_price() already
--      does exactly that via ON CONFLICT DO UPDATE. Closing the RLS path
--      entirely would not change that legitimate flow (it already goes
--      through the RPC), so it buys nothing extra there.
--   2. A future TRUSTED external price-feed integration (spec: "أبقِ
--      external_api محجوزًا لمسار Trusted Integration مستقبلي") is expected
--      to write with the service_role key from a server-side job, not from
--      a signed-in browser session -- exactly what
--      is_trusted_bootstrap_context() already distinguishes. A blanket RLS
--      lockdown (RPC-only, like 0047) would force that future integration
--      to ALSO go through a new SECURITY DEFINER RPC just to reach the
--      table, when the real distinction that matters is "was this write
--      made by a real signed-in end user or by a trusted server context",
--      which the trigger checks directly and precisely.
--   3. This still fully closes the actual exploit: whether the write comes
--      through save_daily_gold_price()/save_daily_gold_prices_bulk() or a
--      raw direct INSERT/UPDATE, an ordinary `authenticated` actor can
--      NEVER end up with source_type='external_api' or a fabricated
--      source_name/source_reference/is_manual_override=false in the
--      database -- the trigger fires unconditionally on every write path
--      for every non-trusted actor, RPC or not.
--
-- source_name/source_reference are pinned to NULL (not merely left alone)
-- for a non-trusted write: per 0041's own table comment, those two columns
-- exist specifically to "record where an automated price came from" -- a
-- manual entry has no legitimate value to put there, so allowing an
-- authenticated user to set them at all would just be a narrower version of
-- the same fabrication risk ("تلفيق بيانات المصدر").
--
-- Reading history and making authorized manual corrections are both
-- completely unaffected -- this trigger only ever touches the four
-- source-attribution columns, never price_per_gram/price_date/karat_id/
-- notes, and SELECT is untouched (still gated by gold_prices.view, 0041).
create or replace function public.enforce_daily_gold_price_source_integrity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_trusted_bootstrap_context() then
    new.source_type := 'manual';
    new.is_manual_override := true;
    new.source_name := null;
    new.source_reference := null;
  end if;
  return new;
end;
$$;

comment on function public.enforce_daily_gold_price_source_integrity() is
  'Pins source_type=manual, is_manual_override=true, source_name/source_reference=NULL on every daily_gold_prices INSERT/UPDATE made by an ordinary authenticated actor (any writer that is NOT a trusted bootstrap context, public.is_trusted_bootstrap_context() from 0013) -- regardless of whether the write goes through save_daily_gold_price()/save_daily_gold_prices_bulk() or a raw direct PostgREST INSERT/UPDATE. A trusted context (service_role -- the intended shape of a future external price-feed integration job -- or a direct-SQL/migration/seed context) may still set source_type=external_api and the source_name/source_reference fields explicitly; external_api is reserved for that future trusted path and is never reachable by a signed-in end user. See migration 0051 header comment for the full design rationale (trigger-based, not an RLS lockdown like 0047 used for the Versioning tables).';

revoke execute on function public.enforce_daily_gold_price_source_integrity() from public;

create trigger daily_gold_prices_enforce_source_integrity
  before insert or update on public.daily_gold_prices
  for each row
  execute function public.enforce_daily_gold_price_source_integrity();

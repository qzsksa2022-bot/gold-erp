-- ============================================================================
-- 0164: Phase 6 Final Audit & Invariant Hotfix 6.1.2 (2/4): adjustment_types
-- updated_by genuine anti-forgery hardening
-- ============================================================================
-- Migrations 0001-0163 are unmodified (Hotfix 6.1.2 freeze rule).
--
-- Hotfix 6.1.2 item 3 (BLOCKER) — 0162's
-- adjustment_types_enforce_updated_columns() trigger currently does:
--   new.updated_at := now();
--   if auth.uid() is not null then new.updated_by := auth.uid(); end if;
-- When auth.uid() IS NULL (a trusted/direct-SQL/service_role/maintenance
-- context — no authenticated user-auth actor present), NEW.updated_by is
-- left exactly as whatever value the UPDATE statement itself supplied. That
-- means a trusted/service_role direct write can still forge updated_by to
-- an arbitrary UUID (e.g. attributing a Master Data rename to some other
-- user who never touched it). This violates the explicit, standing
-- requirement that updated_by must never be forgeable, even via a trusted/
-- service_role direct UPDATE.
--
-- Corrected contract (CREATE OR REPLACE — same function name, so the
-- existing "before update ... for each row" trigger created by 0162
-- automatically picks up this new body; no trigger DROP/CREATE needed):
--
--   (A) auth.uid() is not null AND it identifies a real, existing
--       public.profiles row (an authenticated session backed by a genuine
--       Actor Profile) -> updated_by := auth.uid(). Sanctioned RPCs invoked
--       under an authenticated session keep recording the real acting user
--       exactly as before.
--
--   (B) auth.uid() is null, OR it does not identify a valid Actor Profile
--       (service_role/maintenance/direct-SQL context, or any other
--       situation with no genuine user-auth actor) -> updated_by is pinned
--       to OLD.updated_by. Whatever value NEW.updated_by carries in from the
--       UPDATE statement is discarded unconditionally — a trusted context
--       can still edit Master Data (name_ar/name_en/description/sort_order/
--       etc.), but it can never move attribution of that edit onto a
--       different user by its own initiative. This is a meaningfully
--       stricter contract than 0162's original "leave supplied value alone
--       when auth.uid() is null" behavior.
--
-- updated_at is always stamped now() in both branches, unchanged from 0162.
--
-- No test-only workaround of any kind is used to make a forged updated_by
-- appear to succeed — this fix corrects the real trigger logic itself; see
-- tests/adjustments-hotfix-6-1-2-updated-by-anti-forgery.test.sql for the
-- genuine trusted-direct-write forgery-rejection proof.
-- ---------------------------------------------------------------------------
create or replace function public.adjustment_types_enforce_updated_columns()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  new.updated_at := now();

  if v_actor is not null and exists (select 1 from public.profiles where id = v_actor) then
    new.updated_by := v_actor;
  else
    new.updated_by := old.updated_by;
  end if;

  return new;
end;
$$;

comment on function public.adjustment_types_enforce_updated_columns() is
  'Hotfix 6.1.2 item 3 — hardened against updated_by forgery. auth.uid() identifying a real public.profiles row => pinned to that real acting user (sanctioned RPCs under an authenticated session keep recording the true actor). Otherwise (auth.uid() null, or not a valid Actor Profile -- service_role/maintenance/direct-SQL) => updated_by is forced back to OLD.updated_by regardless of what the UPDATE statement supplied, so a trusted/service_role direct write can still edit Master Data but can never fabricate attribution to an arbitrary user. Supersedes 0162''s looser body (which left a statement-supplied value alone whenever auth.uid() was null) via CREATE OR REPLACE; the trigger created by 0162 is unchanged and automatically uses this new body.';

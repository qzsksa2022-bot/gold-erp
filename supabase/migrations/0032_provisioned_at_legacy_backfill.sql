-- ============================================================================
-- 0032: Backfill provisioned_at for accounts that predate migration 0029
-- ============================================================================
-- Foundation Hardening 1.4, item 1. Ships as a NEW migration after 0031;
-- 0001-0031 stay byte-for-byte untouched.
--
-- 0029 added profiles.provisioned_at (null by default) and a hard invariant:
-- nothing may reach status = 'active' with provisioned_at still null. That is
-- exactly correct for every row created AFTER 0029 -- but it never considered
-- rows that were already 'active' (or already 'suspended' after once being
-- active) on a database this migration applies to. Those rows were
-- legitimately provisioned by whatever mechanism existed before 0029, and
-- their provisioned_at is simply null because the column did not exist yet
-- -- not because they were ever a genuinely incomplete/cancelled invite.
-- Left alone, 0029's invariant becomes a landmine for every pre-existing
-- account: the FIRST time any one of them is ever suspended and an admin
-- tries to reactivate it, the DB rejects the reactivation forever, with no
-- path back (the column can only ever be set by finalize_new_user_profile()
-- or a trusted bootstrap context, and finalize only matches pending_setup
-- rows). An active legacy profile must never be left with provisioned_at
-- IS NULL going forward.
--
-- Two cases, deliberately handled differently:

-- ---------------------------------------------------------------------------
-- Case A: currently ACTIVE legacy rows. Unambiguous -- status = 'active' is
-- only reachable, by construction (is_active_user()/the login gate both
-- require it, and every activation path before AND after 0029 is
-- permission-gated), by an account that completed onboarding. Backfill using
-- created_at as the best available stand-in for "when this account was
-- provisioned" -- the exact original finalize timestamp is not recoverable
-- from a database that predates the column, and does not need to be:
-- provisioned_at's only job from here on is "is it null or not", never a
-- precise instant.
-- ---------------------------------------------------------------------------
update public.profiles
set provisioned_at = created_at
where status = 'active' and provisioned_at is null;

-- ---------------------------------------------------------------------------
-- Case B: currently SUSPENDED legacy rows. Two genuinely different histories
-- are indistinguishable from status/created_at alone:
--   (i)  a real, once-active account an admin later disabled deliberately --
--        WAS legitimately provisioned, and should be backfilled exactly like
--        case A so it can be reactivated normally going forward.
--   (ii) a cancelled invite that was moved straight from pending_setup to
--        suspended without ever passing through 'active' -- the exact bug
--        Foundation Hardening 1.4 item 5 (0036) closes going forward. NEVER
--        completed onboarding, and must stay permanently non-reactivatable
--        -- which is precisely what 0029's invariant, and Foundation
--        Hardening 1.3 item 8's UserStatusToggle UI (no reactivate button
--        for suspended + provisioned_at IS NULL), already correctly do for
--        it. Backfilling this case would legitimize a stranded, incomplete
--        account as if it were a real one.
--
-- audit_logs (0016's profiles_audit_trigger onward) is the one reliable
-- historical signal that tells these apart: case (i) has at least one logged
-- UPDATE where new_values->>'status' = 'active' somewhere in its history
-- (audit_table_changes() logs entity_type='user', action='user.update' for
-- every profiles UPDATE, with new_values = to_jsonb(new) -- see 0016); case
-- (ii) never does, because a cancelled invite goes pending_setup -> suspended
-- directly. Backfill case (i) using the EARLIEST such logged event's
-- timestamp -- the actual historical moment it first became active, a
-- strictly better proxy than created_at (which only reflects account
-- creation, not activation).
-- ---------------------------------------------------------------------------
update public.profiles p
set provisioned_at = earliest.first_active_at
from (
  select al.entity_id as profile_id, min(al.created_at) as first_active_at
  from public.audit_logs al
  where al.entity_type = 'user'
    and al.action = 'user.update'
    and al.new_values ->> 'status' = 'active'
  group by al.entity_id
) earliest
where p.id = earliest.profile_id
  and p.status = 'suspended'
  and p.provisioned_at is null;

-- A suspended legacy row that (a) has no audit_logs evidence of ever having
-- been active, AND (b) genuinely WAS a real completed account before audit
-- logging existed (i.e. predates 0016 entirely) is a data-quality question
-- this migration deliberately does NOT try to resolve automatically -- doing
-- so would mean guessing, and guessing wrong legitimizes exactly the
-- stranded-account failure mode this whole item exists to close. Such a row
-- (if any operator knows of one on their specific database) is a one-off,
-- manually-verified `update public.profiles set provisioned_at = now() where
-- id = '<known-legitimate-id>'` run directly by someone with database
-- access -- not something a forward migration running against every
-- database this project is ever installed on can safely infer on its own.
-- Every OTHER suspended legacy row is, from here on, correctly and
-- deliberately indistinguishable from a cancelled invite.

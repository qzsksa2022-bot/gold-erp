-- ============================================================================
-- 0029: Close the provisioning bypass permanently (provisioned_at)
-- ============================================================================
-- Foundation Hardening 1.3, item 4. Ships as a NEW migration after 0028.
--
-- 0019 introduced 'pending_setup' specifically so finalize_new_user_profile()
-- could tell "a brand-new account still being onboarded" apart from "a real
-- account someone disabled on purpose", and 0019's enforce_pending_setup_
-- transition() requires users.create for the pending_setup -> active
-- transition specifically. That closes the DIRECT path, but a second
-- independent review found the underlying invariant is still only encoded
-- in the mutable `status` enum, which means it can be routed around:
--
--   pending_setup --(users.disable)--> suspended --(users.disable)--> active
--
-- enforce_pending_setup_transition() does not fire for either of those two
-- hops: the first matches neither of its conditions (old is pending_setup,
-- new is suspended -- not the pending_setup->active condition, and not the
-- ->pending_setup condition either), and the second doesn't either (old is
-- suspended, not pending_setup). Meanwhile 0014/0018's column-authorization
-- trigger lets a users.disable holder change `status` to ANY value,
-- including 'active', with no awareness that this particular account was
-- never actually provisioned. So an actor holding users.disable (or
-- users.edit) but deliberately NOT users.create could stand up a fully
-- 'active' account -- bypassing users.create entirely -- by routing through
-- 'suspended' as a layover. The bug is architectural: "has this account ever
-- been legitimately provisioned" cannot be reconstructed from `status` alone
-- once it has passed through more than one transition.
--
-- Fix: a permanent, independent marker, decoupled from `status` entirely.
--  * provisioned_at timestamptz null -- starts null on every new profile.
--  * Set ONLY by finalize_new_user_profile(), exactly once, together with
--    the pending_setup -> active transition it already performs.
--  * Immutable via any other path (mirrors 0021's email-immutability
--    pattern) -- a client can never forge it directly.
--  * A NEW, independent invariant trigger blocks ANY transition INTO
--    status = 'active' (not just from pending_setup -- from ANY prior
--    status) unless the row already carries (or this very UPDATE is
--    setting) a non-null provisioned_at. This is what actually closes the
--    bypass: routing through 'suspended' no longer helps, because
--    provisioned_at stays null the whole time and the final ->active hop is
--    blocked regardless of which permission the actor holds.
--
-- finalize_new_user_profile() needs to set both status='active' AND
-- provisioned_at=now() in the same trusted, users.create-gated UPDATE, but
-- it runs as the calling admin's own session (auth.uid() is NOT null, so
-- is_trusted_bootstrap_context() is false here) -- it is not a "trusted
-- context" in the service-role/direct-SQL sense, just an independently
-- permission-gated RPC. A transaction-local GUC flag, set only inside this
-- function around its own single UPDATE statement and always reset before
-- returning, signals "this specific write is finalize's own, already-gated
-- write" to the immutability trigger below. See the flag's own comment for
-- why this is safe even inside the test suite's single long-lived
-- transaction.

alter table public.profiles add column provisioned_at timestamptz null;

comment on column public.profiles.provisioned_at is
  '0029: set exactly once, only by finalize_new_user_profile(), the moment a pending_setup account is legitimately completed by a users.create holder. Never cleared, never forgeable by any other path (see enforce_provisioned_at_immutable). A null value means "this account was never provisioned" -- enforce_activation_requires_provisioning uses that fact to block status from ever reaching ''active'' by any roundabout sequence of transitions that skips finalize_new_user_profile().';

-- ---------------------------------------------------------------------------
-- Immutability: provisioned_at can only change from inside
-- finalize_new_user_profile()'s own flagged UPDATE (or a trusted bootstrap
-- context -- direct SQL/service-role, e.g. a manual data fix).
-- ---------------------------------------------------------------------------
create or replace function public.enforce_provisioned_at_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if new.provisioned_at is distinct from old.provisioned_at then
    if coalesce(current_setting('app.finalize_provisioning', true), 'off') <> 'on' then
      raise exception 'لا يمكن تعديل provisioned_at مباشرة -- يتم ضبطه فقط بواسطة إتمام تزويد المستخدم (finalize_new_user_profile)'
        using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

comment on function public.enforce_provisioned_at_immutable() is
  '0029: provisioned_at cannot change via any client UPDATE except from inside finalize_new_user_profile()''s own transaction-local app.finalize_provisioning flag, or a trusted bootstrap context. Mirrors 0021''s enforce_profile_email_immutable pattern.';

revoke execute on function public.enforce_provisioned_at_immutable() from public;

create trigger profiles_enforce_provisioned_at_immutable
  before update on public.profiles
  for each row
  execute function public.enforce_provisioned_at_immutable();

-- ---------------------------------------------------------------------------
-- The actual invariant: nothing may reach status = 'active' without a
-- non-null provisioned_at, regardless of which prior status it came from or
-- which permission authorized the status change itself (that permission
-- check is 0014/0018/0030's job -- this trigger is a separate, independent
-- layer that does not care WHO made the change, only WHETHER this account
-- was ever legitimately provisioned in the first place).
-- ---------------------------------------------------------------------------
create or replace function public.enforce_activation_requires_provisioning()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'active' and new.provisioned_at is null then
    if public.is_trusted_bootstrap_context()
      or coalesce(current_setting('app.finalize_provisioning', true), 'off') = 'on'
    then
      -- Trusted bootstrap (service-role scripts such as
      -- scripts/create-super-admin.ts, direct SQL, seed.sql) is a SECOND
      -- legitimate way an account can become 'active' without ever going
      -- through finalize_new_user_profile() -- it activates a profile
      -- directly, has no reason to also know about provisioned_at, and is
      -- exactly as trustworthy as finalize's own users.create-gated write.
      -- Stamp it here instead of requiring the caller to already have set
      -- it: this is what makes such an account correctly count as
      -- "provisioned" for every LATER, ordinary users.disable-driven
      -- suspend/reactivate cycle an authenticated admin performs on it --
      -- without this, the very first production Super Admin (created by
      -- create-super-admin.ts, never through finalize_new_user_profile())
      -- could never be reactivated after being suspended even once.
      new.provisioned_at := now();
    else
      raise exception 'لا يمكن تفعيل حساب لم يكتمل تزويده عبر إنشاء المستخدم (users.create) -- provisioned_at غير مضبوط'
        using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

comment on function public.enforce_activation_requires_provisioning() is
  '0029: closes the pending_setup -> suspended -> active bypass -- ANY write that would leave status=''active'' with provisioned_at still null is only allowed from a trusted bootstrap context or finalize_new_user_profile()''s own flagged write (both of which get provisioned_at auto-stamped right here if not already set) -- everyone else is rejected. A never-provisioned account can never reach active via any sequence of users.disable-authorized status flips, but a trusted-context activation (which never calls finalize_new_user_profile()) is retroactively recognized as provisioned the moment it happens, so it is not permanently unable to be reactivated later.';

revoke execute on function public.enforce_activation_requires_provisioning() from public;

create trigger profiles_enforce_activation_requires_provisioning
  before update on public.profiles
  for each row
  execute function public.enforce_activation_requires_provisioning();

-- ---------------------------------------------------------------------------
-- finalize_new_user_profile(): CREATE OR REPLACE to also stamp
-- provisioned_at = now() in its one trusted UPDATE, using the transaction-
-- local flag described above so BOTH new invariant triggers (immutability
-- and activation-requires-provisioning) recognize this specific write as
-- legitimate without weakening either trigger for any other caller.
--
-- The flag is set to 'on' immediately before the UPDATE and explicitly reset
-- to 'off' immediately after -- using FOUND is captured into a local
-- variable first, since calling set_config() again would itself overwrite
-- FOUND. If the UPDATE statement itself raises (e.g. a future, unrelated
-- trigger rejects it), the exception propagates out of this function before
-- the reset line ever runs -- but `set_config(..., true)` is transaction-
-- LOCAL (equivalent to SET LOCAL), so Postgres automatically reverts it the
-- moment the enclosing subtransaction/savepoint rolls back, which is exactly
-- what happens to whatever caught that exception (a client-side error
-- response for a real request; a `do $$ ... exception when others` block's
-- implicit savepoint in the SQL test suite). The flag can never leak into
-- a later, unrelated statement either way.
-- ---------------------------------------------------------------------------
create or replace function public.finalize_new_user_profile(
  p_user_id uuid,
  p_full_name text,
  p_default_store_id uuid,
  p_store_access_scope text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_updated boolean;
begin
  if not public.has_permission('users.create') then
    raise exception 'لا تملك صلاحية إنشاء مستخدمين' using errcode = '42501';
  end if;

  perform set_config('app.finalize_provisioning', 'on', true);

  update public.profiles
  set full_name = p_full_name,
      status = 'active',
      default_store_id = p_default_store_id,
      store_access_scope = p_store_access_scope,
      provisioned_at = now(),
      created_by = auth.uid(),
      updated_by = auth.uid()
  where id = p_user_id
    and status = 'pending_setup'
    and provisioned_at is null;

  v_updated := found;

  perform set_config('app.finalize_provisioning', 'off', true);

  if not v_updated then
    raise exception 'تعذّر إكمال إنشاء الملف الشخصي -- المستخدم غير موجود أو ليس بانتظار الإكمال (قد يكون مُفعّلاً بالفعل أو معطّلاً)'
      using errcode = 'P0002';
  end if;
end;
$$;

comment on function public.finalize_new_user_profile(uuid, text, uuid, text) is
  '0029: now also stamps provisioned_at = now() (once, permanently) alongside activating a pending_setup row, using a transaction-local flag so the new immutability/activation-invariant triggers recognize this as the one legitimate provisioning write. Still matches status = ''pending_setup'' AND provisioned_at is null only -- cannot be used to "re-finalize" any row a second time. Called from the REGULAR session client so auth.uid() is the acting admin and the profiles audit trigger attributes the resulting event correctly.';

-- (grants unchanged by CREATE OR REPLACE -- still revoked from public,
-- granted to authenticated, as set in 0016.)

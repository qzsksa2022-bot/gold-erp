-- ============================================================================
-- 0021: Lock system-managed columns at the database level
-- ============================================================================
-- Foundation Hardening 1.2, item 5.
--
-- Gaps closed:
--  1. profiles.email had no protection at all against a direct UPDATE.
--     users.edit already lets an actor change every other profile column;
--     nothing stopped it from also rewriting email, which would silently
--     desync from the real source of truth (auth.users.email) since no
--     Supabase Auth email-change flow exists yet.
--  2. created_at/created_by are meant to be immutable history and
--     updated_at/updated_by are meant to always reflect the real actor --
--     0001's set_updated_at() and 0014's set_updated_by() already make
--     updated_at/updated_by unforgeable on UPDATE, but nothing stopped a
--     raw INSERT (via REST, bypassing the app's Server Actions, which
--     already pass session.userId correctly) from setting created_by to an
--     arbitrary uuid, or created_at to an arbitrary timestamp, on stores or
--     roles (the two admin tables `authenticated` can INSERT into at all;
--     profiles has no INSERT policy for authenticated, so it was never
--     reachable there). And nothing stopped an UPDATE from silently
--     rewriting created_at/created_by after the fact on any of the three.

-- ---------------------------------------------------------------------------
-- 1) profiles.email is immutable via any client-reachable path. Blocks
--    EVERY actor, including a Super Admin acting through the app -- there is
--    no dedicated Auth-synced email-change flow yet, so there is no
--    legitimate direct path at all; only a trusted bootstrap context
--    (handle_new_auth_user()'s INSERT, or direct SQL) may set it.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_profile_email_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if new.email is distinct from old.email then
    raise exception 'لا يمكن تغيير البريد الإلكتروني مباشرة عبر تعديل الملف الشخصي -- يتطلب ذلك مسارًا مخصصًا يزامن Supabase Auth (غير متاح بعد)'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.enforce_profile_email_immutable() is
  'profiles.email cannot change via any client UPDATE, even for an actor holding users.edit -- there is no email-change flow that keeps Supabase Auth in sync yet. Only a trusted bootstrap context (the on_auth_user_created INSERT, or direct SQL) may set it.';

revoke execute on function public.enforce_profile_email_immutable() from public;

create trigger profiles_enforce_email_immutable
  before update on public.profiles
  for each row
  execute function public.enforce_profile_email_immutable();

-- ---------------------------------------------------------------------------
-- 2) System-managed audit columns, forced to server truth regardless of
--    what a client sends. Applied to profiles/stores/roles (the three admin
--    tables with all four columns). Silently pins the value back to the
--    correct one instead of raising -- the same philosophy 0014's
--    set_updated_by() already established (a form that innocently echoes
--    back an unchanged created_at/created_by should not hard-error; an
--    attempt to actually change them should just never take effect).
--    Layered ADDITIONALLY beside 0001's set_updated_at() and 0014's
--    set_updated_by() (left exactly as they were) rather than replacing
--    them: this is defense in depth specifically against created_at/
--    created_by forgery on INSERT, which neither of those covers, plus a
--    second guarantee on updated_at/updated_by in case either of those is
--    ever bypassed.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_system_managed_columns()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if TG_OP = 'INSERT' then
    new.created_at := now();
    new.updated_at := now();
    if auth.uid() is not null then
      new.created_by := auth.uid();
      new.updated_by := auth.uid();
    end if;
    return new;
  elsif TG_OP = 'UPDATE' then
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    if auth.uid() is not null then
      new.updated_by := auth.uid();
    end if;
    return new;
  end if;
  return new;
end;
$$;

comment on function public.enforce_system_managed_columns() is
  'Forces created_at/created_by/updated_at/updated_by to server truth on every INSERT/UPDATE, regardless of client-supplied values -- created_at/created_by are pinned immutable after creation; updated_at/updated_by always reflect now()/auth.uid(). Trusted contexts (auth.uid() is null: service_role, direct SQL, migrations, seed.sql) keep whatever they explicitly supplied for created_by/updated_by, since those are legitimate system-attributed writes, not client forgery.';

revoke execute on function public.enforce_system_managed_columns() from public;

create trigger profiles_enforce_system_columns
  before insert or update on public.profiles
  for each row
  execute function public.enforce_system_managed_columns();

create trigger stores_enforce_system_columns
  before insert or update on public.stores
  for each row
  execute function public.enforce_system_managed_columns();

create trigger roles_enforce_system_columns
  before insert or update on public.roles
  for each row
  execute function public.enforce_system_managed_columns();

-- ---------------------------------------------------------------------------
-- 3) Same principle, narrower columns (created_at/created_by only -- no
--    updated_at/updated_by on these junction tables), applied to the other
--    admin-managed tables where created_by drives audit attribution:
--    user_roles, user_permission_overrides, user_store_access. A separate
--    function because referencing NEW.updated_at on a table without that
--    column would fail at runtime.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_created_by_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if TG_OP = 'INSERT' then
    new.created_at := now();
    if auth.uid() is not null then
      new.created_by := auth.uid();
    end if;
    return new;
  elsif TG_OP = 'UPDATE' then
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    return new;
  end if;
  return new;
end;
$$;

comment on function public.enforce_created_by_immutable() is
  'Same principle as enforce_system_managed_columns(), for tables with only created_at/created_by (no updated_* columns): user_roles, user_permission_overrides, user_store_access.';

revoke execute on function public.enforce_created_by_immutable() from public;

create trigger user_roles_enforce_created_by
  before insert or update on public.user_roles
  for each row
  execute function public.enforce_created_by_immutable();

create trigger user_permission_overrides_enforce_created_by
  before insert or update on public.user_permission_overrides
  for each row
  execute function public.enforce_created_by_immutable();

create trigger user_store_access_enforce_created_by
  before insert or update on public.user_store_access
  for each row
  execute function public.enforce_created_by_immutable();

-- ============================================================================
-- 0013: Privilege-escalation hardening at the DATABASE layer
-- ============================================================================
-- 0009 already stopped one specific escalation path (granting the
-- super_admin ROLE). This migration closes the broader family of
-- self-escalation and unauthorized-grant paths an independent security
-- review identified across the three tables that actually change what a
-- user can do: user_roles, user_permission_overrides, role_permissions.
--
-- Three distinct rules, each enforced as a trigger (RLS's WITH CHECK cannot
-- express "compare against what the ACTOR themselves currently holds" or
-- "this is the actor's own row" as cleanly as a trigger with full OLD/NEW
-- and function access):
--
--  (a) A non-super-admin can never modify (insert/delete/update) their OWN
--      user_roles or user_permission_overrides rows -- regardless of which
--      admin permission they otherwise hold. Deleting your own 'revoke'
--      override, for example, would silently hand back a permission to
--      yourself -- self-modification is blocked entirely rather than
--      trying to allow "safe" subsets of it.
--  (b) A non-super-admin can never GRANT a permission (via role_permissions
--      or a user_permission_overrides 'grant' row) that they do not
--      currently hold themselves. You cannot hand out what you don't have.
--  (c) The three most sensitive permission keys (users.manage_permissions,
--      settings.manage, backups.manage) can only ever be granted -- to a
--      role, to an individual override, or indirectly by assigning a role
--      that already carries one of them to someone else -- by a Super
--      Admin, full stop, even if the actor otherwise holds that exact
--      permission themselves (holding users.manage_permissions does not by
--      itself let you re-grant users.manage_permissions to someone else).
--
-- Trusted-context exemption: every trigger below (and 0009's pre-existing
-- one, re-defined at the bottom of this file) exempts a "trusted bootstrap
-- context" — see is_trusted_bootstrap_context() immediately below for what
-- that means and why auth.role() = 'service_role' alone was not enough.

create or replace function public.is_trusted_bootstrap_context()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  -- True for two distinct trusted contexts:
  --  1. auth.role() = 'service_role': a PostgREST/Supabase request made
  --     with the service-role key (src/lib/supabase/admin.ts — never
  --     shipped to the browser).
  --  2. auth.uid() is null: there is no 'sub' claim in request.jwt.claims
  --     at all, which is what a direct SQL connection looks like — the
  --     Supabase SQL Editor, `psql`, a migration runner, or supabase/
  --     seed.sql. A genuine `authenticated`-role PostgREST request always
  --     carries a 'sub' claim, so this cannot be spoofed by an ordinary
  --     signed-in user; and `anon` can never reach these triggers in the
  --     first place (the INSERT/UPDATE/DELETE RLS policies on
  --     user_roles / user_permission_overrides / role_permissions are all
  --     scoped `to authenticated` only, see 0010).
  select auth.role() = 'service_role' or auth.uid() is null;
$$;

comment on function public.is_trusted_bootstrap_context() is
  'True for the service-role PostgREST path and for direct SQL connections (SQL Editor, psql, migrations, seed.sql) that carry no JWT at all. Used to exempt trusted, non-PostgREST-authenticated-user contexts from the privilege-escalation triggers below and in 0009.';

revoke execute on function public.is_trusted_bootstrap_context() from public;

-- ---------------------------------------------------------------------------
-- Re-fix 0009's original escalation guard with the same, more complete
-- exemption (CREATE OR REPLACE from this NEW migration -- 0009 itself is
-- left untouched, per the "never edit an already-shipped migration" rule).
-- Behavior is otherwise identical to 0009.
-- ---------------------------------------------------------------------------
create or replace function public.prevent_super_admin_privilege_escalation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role_key text;
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  select key into v_role_key from public.roles where id = new.role_id;

  if v_role_key = 'super_admin' and not public.is_super_admin(auth.uid()) then
    raise exception 'فقط مستخدم Super Admin يمكنه منح دور Super Admin لمستخدم آخر'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- (a) Self-modification guard: user_roles
-- ---------------------------------------------------------------------------
create or replace function public.prevent_self_role_modification()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_target_user uuid := coalesce(new.user_id, old.user_id);
begin
  if public.is_trusted_bootstrap_context() then
    return coalesce(new, old);
  end if;

  if v_target_user = auth.uid() and not public.is_super_admin(auth.uid()) then
    raise exception 'لا يمكنك تعديل أدوارك الخاصة بحسابك أنت' using errcode = 'P0001';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger user_roles_prevent_self_modification
  before insert or delete on public.user_roles
  for each row
  execute function public.prevent_self_role_modification();

-- ---------------------------------------------------------------------------
-- (c, role path) A role that carries a sensitive permission can only be
-- ASSIGNED to someone by a Super Admin -- otherwise role_permissions being
-- locked down (below) would still be trivially bypassed by just assigning
-- an already-sensitive role via user_roles instead of touching
-- role_permissions directly.
-- ---------------------------------------------------------------------------
create or replace function public.prevent_sensitive_role_assignment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_has_sensitive boolean;
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if public.is_super_admin(auth.uid()) then
    return new;
  end if;

  select exists (
    select 1
    from public.role_permissions rp
    join public.permissions p on p.id = rp.permission_id
    where rp.role_id = new.role_id
      and p.key in ('users.manage_permissions', 'settings.manage', 'backups.manage')
  ) into v_has_sensitive;

  if v_has_sensitive then
    raise exception 'لا يمكن إسناد دور يتضمن صلاحيات حساسة إلا بواسطة Super Admin'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

create trigger user_roles_prevent_sensitive_assignment
  before insert on public.user_roles
  for each row
  execute function public.prevent_sensitive_role_assignment();

-- ---------------------------------------------------------------------------
-- (a) Self-modification guard: user_permission_overrides
-- ---------------------------------------------------------------------------
create or replace function public.prevent_self_permission_override_modification()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_target_user uuid := coalesce(new.user_id, old.user_id);
begin
  if public.is_trusted_bootstrap_context() then
    return coalesce(new, old);
  end if;

  if v_target_user = auth.uid() and not public.is_super_admin(auth.uid()) then
    raise exception 'لا يمكنك تعديل استثناءات الصلاحيات الخاصة بحسابك أنت' using errcode = 'P0001';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger user_permission_overrides_prevent_self_mod
  before insert or update or delete on public.user_permission_overrides
  for each row
  execute function public.prevent_self_permission_override_modification();

-- ---------------------------------------------------------------------------
-- (b + c) Cannot grant a permission you don't hold; sensitive keys require
-- Super Admin regardless. Applies to 'grant' rows only -- narrowing your own
-- or someone else's access ('revoke') never escalates anything, so it stays
-- unrestricted by this particular rule (still subject to the self-mod guard
-- above and to normal RLS/users.manage_permissions gating).
-- ---------------------------------------------------------------------------
create or replace function public.prevent_permission_override_grant_escalation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_perm_key text;
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if public.is_super_admin(auth.uid()) then
    return new;
  end if;

  if new.effect = 'grant' then
    select key into v_perm_key from public.permissions where id = new.permission_id;

    if v_perm_key in ('users.manage_permissions', 'settings.manage', 'backups.manage') then
      raise exception 'هذه صلاحية حساسة، لا يمكن منحها إلا بواسطة Super Admin' using errcode = 'P0001';
    end if;

    if not public.has_permission(v_perm_key) then
      raise exception 'لا يمكنك منح صلاحية لا تملكها أنت نفسك' using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

create trigger user_permission_overrides_prevent_grant_escalation
  before insert or update on public.user_permission_overrides
  for each row
  execute function public.prevent_permission_override_grant_escalation();

-- ---------------------------------------------------------------------------
-- (b + c) Same two rules for role_permissions (assigning a permission to a
-- ROLE rather than to one user directly). supabase/seed.sql populates this
-- table directly as a trusted direct-SQL script, which is exactly the
-- is_trusted_bootstrap_context() "auth.uid() is null" path.
-- ---------------------------------------------------------------------------
create or replace function public.prevent_role_permission_grant_escalation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_perm_key text;
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if public.is_super_admin(auth.uid()) then
    return new;
  end if;

  select key into v_perm_key from public.permissions where id = new.permission_id;

  if v_perm_key in ('users.manage_permissions', 'settings.manage', 'backups.manage') then
    raise exception 'هذه صلاحية حساسة، لا يمكن إسنادها لأي دور إلا بواسطة Super Admin'
      using errcode = 'P0001';
  end if;

  if not public.has_permission(v_perm_key) then
    raise exception 'لا يمكنك منح صلاحية لا تملكها أنت نفسك لأي دور' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

create trigger role_permissions_prevent_grant_escalation
  before insert on public.role_permissions
  for each row
  execute function public.prevent_role_permission_grant_escalation();

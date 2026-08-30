-- ============================================================================
-- 0027: Protect sensitive permissions symmetrically -- grant AND revoke
-- ============================================================================
-- Foundation Hardening 1.3, item 5. Ships as a NEW migration after 0026.
--
-- 0013 already restricts GRANTING one of the three most sensitive permission
-- keys (users.manage_permissions, settings.manage, backups.manage) -- via a
-- role_permissions INSERT, a user_permission_overrides 'grant' row, or
-- assigning a role that already carries one of them -- to Super Admin only.
-- That protection was asymmetric: nothing stopped a non-Super-Admin who
-- merely holds users.manage_permissions from doing the mirror-image action
-- and REVOKING a sensitive permission from someone else (or from a role),
-- which is just as much a change to who holds ultimate control over the
-- permission system as granting it would be -- an Admin could, for example,
-- strip users.manage_permissions from every other Admin (including ones who
-- would otherwise be able to stop them), consolidating control without ever
-- needing Super Admin. Three concrete gaps, found by a second independent
-- review of the actually-shipped 1.2 code:
--
--  1. role_permissions DELETE (removing a sensitive permission from a role)
--     was completely unrestricted -- 0013's trigger only fires BEFORE INSERT.
--  2. user_permission_overrides: an INSERT/UPDATE with effect='revoke' for a
--     sensitive key was unrestricted -- 0013's grant-escalation trigger only
--     inspects rows where new.effect = 'grant'.
--  3. user_permission_overrides DELETE (clearing an existing override) was
--     completely unrestricted by 0013 -- deleting a 'revoke' override for a
--     sensitive key silently RESTORES whatever role-derived grant it was
--     suppressing, which is exactly the kind of indirect grant this needs to
--     catch; deleting a 'grant' override removes a grant, which needs the
--     same protection for symmetry (Super Admin should decide both
--     directions of change to a sensitive key, not just increases).
--  4. user_roles DELETE (removing a role from a user) was unrestricted even
--     when that role carries a sensitive permission -- 0013's sensitive-role
--     trigger only fires BEFORE INSERT, mirroring gap 1's role_permissions
--     asymmetry one level up.
--
-- Fix: three new triggers, each requiring Super Admin whenever the
-- resulting change touches one of the three sensitive keys, in EITHER
-- direction. These are pure additions beside 0013's existing triggers (both
-- must pass; neither loosens the other), so 0013's file is untouched.

-- ---------------------------------------------------------------------------
-- 1) role_permissions: removing a sensitive permission from a role also
--    requires Super Admin (symmetric with 0013's INSERT-side restriction).
-- ---------------------------------------------------------------------------
create or replace function public.prevent_sensitive_role_permission_revocation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_perm_key text;
begin
  if public.is_trusted_bootstrap_context() then
    return old;
  end if;

  if public.is_super_admin(auth.uid()) then
    return old;
  end if;

  select key into v_perm_key from public.permissions where id = old.permission_id;

  if v_perm_key in ('users.manage_permissions', 'settings.manage', 'backups.manage') then
    raise exception 'هذه صلاحية حساسة، لا يمكن سحبها من أي دور إلا بواسطة Super Admin'
      using errcode = 'P0001';
  end if;

  return old;
end;
$$;

comment on function public.prevent_sensitive_role_permission_revocation() is
  '0027: symmetric counterpart to 0013''s prevent_role_permission_grant_escalation -- removing (not just granting) a sensitive permission key from a role requires Super Admin.';

revoke execute on function public.prevent_sensitive_role_permission_revocation() from public;

create trigger role_permissions_prevent_sensitive_revocation
  before delete on public.role_permissions
  for each row
  execute function public.prevent_sensitive_role_permission_revocation();

-- ---------------------------------------------------------------------------
-- 2 + 3) user_permission_overrides: ANY insert/update/delete touching a
--    sensitive permission key (grant OR revoke effect, or clearing an
--    existing row of either effect) requires Super Admin. Deliberately
--    checks BOTH old and new permission_id (a plain UPDATE never changes
--    permission_id in practice -- it's part of the primary key -- but this
--    stays correct even if that ever changes) and does not care about
--    `effect` at all, unlike 0013's narrower grant-only trigger: symmetry is
--    the whole point here.
-- ---------------------------------------------------------------------------
create or replace function public.protect_sensitive_permission_override()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_perm_key text;
begin
  if public.is_trusted_bootstrap_context() then
    return coalesce(new, old);
  end if;

  if public.is_super_admin(auth.uid()) then
    return coalesce(new, old);
  end if;

  select key into v_perm_key
    from public.permissions
    where id = coalesce(new.permission_id, old.permission_id);

  if v_perm_key in ('users.manage_permissions', 'settings.manage', 'backups.manage') then
    raise exception 'هذه صلاحية حساسة، أي تغيير عليها (منح أو سحب أو إزالة استثناء) يتطلب Super Admin'
      using errcode = 'P0001';
  end if;

  return coalesce(new, old);
end;
$$;

comment on function public.protect_sensitive_permission_override() is
  '0027: any INSERT/UPDATE/DELETE on user_permission_overrides for one of the three sensitive permission keys requires Super Admin, regardless of effect (grant/revoke) or operation -- closes the revoke-side and delete/clear-side gaps 0013''s grant-only, insert/update-only trigger left open. Runs independently of and in addition to 0013''s prevent_permission_override_grant_escalation and prevent_self_permission_override_modification.';

revoke execute on function public.protect_sensitive_permission_override() from public;

create trigger user_permission_overrides_protect_sensitive
  before insert or update or delete on public.user_permission_overrides
  for each row
  execute function public.protect_sensitive_permission_override();

-- ---------------------------------------------------------------------------
-- 4) user_roles: removing a role that carries a sensitive permission also
--    requires Super Admin (symmetric with 0013's sensitive-role-ASSIGNMENT
--    restriction, which only covered INSERT).
-- ---------------------------------------------------------------------------
create or replace function public.prevent_sensitive_role_removal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_has_sensitive boolean;
begin
  if public.is_trusted_bootstrap_context() then
    return old;
  end if;

  if public.is_super_admin(auth.uid()) then
    return old;
  end if;

  select exists (
    select 1
    from public.role_permissions rp
    join public.permissions p on p.id = rp.permission_id
    where rp.role_id = old.role_id
      and p.key in ('users.manage_permissions', 'settings.manage', 'backups.manage')
  ) into v_has_sensitive;

  if v_has_sensitive then
    raise exception 'لا يمكن إزالة دور يتضمن صلاحيات حساسة من مستخدم إلا بواسطة Super Admin'
      using errcode = 'P0001';
  end if;

  return old;
end;
$$;

comment on function public.prevent_sensitive_role_removal() is
  '0027: symmetric counterpart to 0013''s prevent_sensitive_role_assignment -- removing (not just assigning) a role that carries a sensitive permission from a user requires Super Admin, since it is an indirect way of revoking that sensitive permission from them.';

revoke execute on function public.prevent_sensitive_role_removal() from public;

create trigger user_roles_prevent_sensitive_removal
  before delete on public.user_roles
  for each row
  execute function public.prevent_sensitive_role_removal();

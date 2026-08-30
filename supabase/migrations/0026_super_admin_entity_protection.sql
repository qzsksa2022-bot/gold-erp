-- ============================================================================
-- 0026: Complete Super Admin protection as a full entity
-- ============================================================================
-- Foundation Hardening 1.3, item 6. Ships as a NEW migration after 0025.
--
-- 0020 protects a Super Admin target from: (a) having the super_admin ROLE
-- itself removed by anyone but another Super Admin (user_roles DELETE), and
-- (b) any UPDATE to their profiles row (status, name, store scope) by anyone
-- but another Super Admin. That leaves three gaps a second independent
-- review found, all reachable by a plain (non-Super-Admin) Admin holding
-- users.manage_permissions/users.manage_store_access as long as the target
-- already holds super_admin:
--
--  1. Assigning an ADDITIONAL role to a Super Admin target (user_roles
--     INSERT) -- 0020 only blocks removing the super_admin role, not adding
--     any other role to an already-Super-Admin user.
--  2. Granting/revoking/clearing a permission override for a Super Admin
--     target (user_permission_overrides INSERT/UPDATE/DELETE) -- untouched
--     by 0020, which only covers user_roles and profiles.
--  3. Granting/revoking store access for a Super Admin target
--     (user_store_access INSERT/DELETE) -- also untouched by 0020.
--
-- A Super Admin's effective access should not be alterable piecemeal by a
-- lesser admin through any of these side doors just because the direct
-- "remove super_admin role" / "edit profile" paths are already closed.
--
-- Fix: one shared trigger function, keyed off whichever column identifies
-- the target user on each table (all three use `user_id` identically),
-- attached to all three tables. Symmetric with 0020's principle: touching
-- ANY row of a Super Admin's authorization footprint requires the actor to
-- be a Super Admin too, full stop, independent of how many Super Admins
-- remain (0009's last-Super-Admin guard is a separate, additional layer).

create or replace function public.protect_super_admin_entity()
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

  if public.is_super_admin(auth.uid()) then
    return coalesce(new, old);
  end if;

  if exists (
    select 1
    from public.user_roles ur
    join public.roles r on r.id = ur.role_id
    where ur.user_id = v_target_user and r.key = 'super_admin'
  ) then
    raise exception 'تعديل أدوار أو صلاحيات أو وصول متاجر مستخدم Super Admin يتطلب أن يكون الفاعل نفسه Super Admin'
      using errcode = 'P0001';
  end if;

  return coalesce(new, old);
end;
$$;

comment on function public.protect_super_admin_entity() is
  '0026: a non-Super-Admin can never INSERT/UPDATE/DELETE a user_roles, user_permission_overrides, or user_store_access row whose target user currently holds the super_admin role -- extends 0020''s role-removal-only and profiles-only protection to the Super Admin''s full authorization footprint. A brand-new super_admin assignment (the target does not YET hold it) is unaffected here -- that path is independently gated by 0009''s prevent_super_admin_privilege_escalation.';

revoke execute on function public.protect_super_admin_entity() from public;

create trigger user_roles_protect_super_admin_entity
  before insert or update or delete on public.user_roles
  for each row
  execute function public.protect_super_admin_entity();

create trigger user_permission_overrides_protect_super_admin_entity
  before insert or update or delete on public.user_permission_overrides
  for each row
  execute function public.protect_super_admin_entity();

create trigger user_store_access_protect_super_admin_entity
  before insert or delete on public.user_store_access
  for each row
  execute function public.protect_super_admin_entity();

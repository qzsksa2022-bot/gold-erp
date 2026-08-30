-- ============================================================================
-- 0020: Protect Super Admin accounts as protected entities
-- ============================================================================
-- Foundation Hardening 1.2, item 3.
--
-- Gaps closed: 0009's protect_last_super_admin() only stops the system from
-- reaching ZERO active Super Admins, and 0013's self-modification triggers
-- only stop a Super Admin from being touched BY THEMSELVES in a
-- non-Super-Admin capacity. Neither stops a DIFFERENT non-Super-Admin
-- (e.g. an Admin holding users.manage_permissions/users.edit/users.disable)
-- from acting on a Super Admin's account as long as at least one OTHER
-- active Super Admin still exists:
--  * removing the super_admin role from any OTHER user via user_roles
--    DELETE (0013's self-block only covers the ACTOR's own row);
--  * suspending/reactivating a Super Admin's profiles.status;
--  * editing a Super Admin's profile data or store scope.
-- These are all reachable today by a plain Admin (users.manage_permissions
-- + users.edit + users.disable, none of them Super Admin) whenever 2+
-- Super Admins exist, since the "last one" guard simply does not apply.
--
-- Fix: a blanket rule -- touching a Super Admin's user_roles row or
-- profiles row requires the ACTOR to be a Super Admin too, full stop,
-- independent of how many Super Admins remain. 0009's last-Super-Admin
-- protection stays exactly as-is (still the only thing stopping a Super
-- Admin from disabling the very last other Super Admin); this migration
-- adds a layer beside it, not a replacement.

-- ---------------------------------------------------------------------------
-- user_roles: a non-Super-Admin can never DELETE a super_admin role
-- assignment for ANY user (not just their own -- 0013's
-- prevent_self_role_modification already covers the actor's own row).
-- INSERT of a super_admin role is already Super-Admin-gated by 0009's
-- prevent_super_admin_privilege_escalation; nothing further needed there.
-- ---------------------------------------------------------------------------
create or replace function public.protect_super_admin_role_removal()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role_key text;
begin
  if public.is_trusted_bootstrap_context() then
    return old;
  end if;

  select key into v_role_key from public.roles where id = old.role_id;

  if v_role_key = 'super_admin' and not public.is_super_admin(auth.uid()) then
    raise exception 'فقط Super Admin يمكنه إزالة دور Super Admin من أي مستخدم'
      using errcode = 'P0001';
  end if;

  return old;
end;
$$;

comment on function public.protect_super_admin_role_removal() is
  'A non-Super-Admin can never remove the super_admin role from ANY user, not just their own -- closes the gap where a different Admin (not the target) could strip a colleague''s Super Admin role as long as one other Super Admin still existed. Complements, does not replace, 0013''s self-modification block and 0009''s last-active-Super-Admin guard.';

revoke execute on function public.protect_super_admin_role_removal() from public;

create trigger user_roles_protect_super_admin_removal
  before delete on public.user_roles
  for each row
  execute function public.protect_super_admin_role_removal();

-- ---------------------------------------------------------------------------
-- profiles: ANY update to a row that currently holds the super_admin role
-- requires the actor to be a Super Admin too -- status changes (suspend/
-- reactivate), profile data, store scope, all of it. Runs independently of
-- and in addition to 0014's edit/disable column lock and 0018's store-scope
-- lock: even an actor who would otherwise pass those (e.g. holds
-- users.edit) is stopped here specifically because the TARGET is a
-- Super Admin, regardless of which column changed.
-- ---------------------------------------------------------------------------
create or replace function public.protect_super_admin_profile()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if public.is_super_admin(auth.uid()) then
    return new;
  end if;

  if exists (
    select 1
    from public.user_roles ur
    join public.roles r on r.id = ur.role_id
    where ur.user_id = old.id and r.key = 'super_admin'
  ) then
    raise exception 'تعديل بيانات أو حالة أو نطاق وصول مستخدم Super Admin يتطلب أن يكون الفاعل نفسه Super Admin'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.protect_super_admin_profile() is
  'Any UPDATE targeting a profiles row that holds the super_admin role requires the actor to be a Super Admin too -- status, profile data, and store-scope columns alike. A different Admin (not Super Admin) can no longer suspend, reactivate, or edit a Super Admin''s account just because 2+ Super Admins exist (the last-one-only guard in 0009 stays as a separate, additional layer for Super-Admin-on-Super-Admin actions).';

revoke execute on function public.protect_super_admin_profile() from public;

create trigger profiles_protect_super_admin
  before update on public.profiles
  for each row
  execute function public.protect_super_admin_profile();

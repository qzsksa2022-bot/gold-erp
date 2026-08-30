-- ============================================================================
-- 0025: Close store-scope delegation completely (not just INSERT)
-- ============================================================================
-- Foundation Hardening 1.3, item 1. Ships as a NEW migration after 0024;
-- 0001-0024 stay byte-for-byte untouched.
--
-- 0018 already closed most of the store-scope delegation gap: a non-Super-
-- Admin cannot grant (INSERT into user_store_access) a store outside their
-- own operable range, cannot set store_access_scope='all' for anyone, and
-- cannot touch their own store scope/access at all. Two gaps remained, found
-- by a second independent review of the actually-shipped 1.2 code:
--
--  1. enforce_store_access_delegation() (0018) only restricts the INSERT
--     branch. A non-Super-Admin holding users.manage_store_access, scoped to
--     stores A+B, could DELETE any OTHER user's user_store_access row for
--     store C -- a store the actor themselves cannot operate -- with nothing
--     stopping them. Revoking access to a store you don't manage is just as
--     much an out-of-scope action as granting it.
--  2. enforce_store_scope_authorization() (0018) requires
--     users.manage_store_access and restricts scope='all' to Super Admin,
--     but never checked default_store_id itself: an actor scoped to A+B
--     could set a Target's default_store_id to C (e.g. while switching them
--     to store_access_scope='single'), even though C is outside the actor's
--     own operable range.
--
-- Fix: extend both functions (CREATE OR REPLACE; 0018's file is untouched).
-- Super Admin remains exempt from both, exactly as before.

-- ---------------------------------------------------------------------------
-- enforce_store_scope_authorization(): add a default_store_id operable-range
-- check, independent of and in addition to the existing self-escalation and
-- scope='all' rules. Applies whenever default_store_id actually changes,
-- regardless of what store_access_scope ends up being (a 'single'-scope
-- target's default_store_id IS their entire access; for 'multiple'/'all' it
-- is used only as a UI default, but the same rule applies uniformly -- an
-- actor should never be able to point ANY user's default store at a branch
-- the actor cannot themselves operate).
-- ---------------------------------------------------------------------------
create or replace function public.enforce_store_scope_authorization()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if new.store_access_scope is distinct from old.store_access_scope
    or new.default_store_id is distinct from old.default_store_id
  then
    if new.id = auth.uid() and not public.is_super_admin(auth.uid()) then
      raise exception 'لا يمكنك تعديل نطاق وصولك للمتاجر (Store Scope) الخاص بحسابك أنت'
        using errcode = 'P0001';
    end if;

    if not public.has_permission('users.manage_store_access') then
      raise exception 'يتطلب تعديل نطاق وصول المتاجر صلاحية users.manage_store_access'
        using errcode = 'P0001';
    end if;

    if new.store_access_scope = 'all' and not public.is_super_admin(auth.uid()) then
      raise exception 'فقط Super Admin يمكنه ضبط نطاق وصول لكل المتاجر (all) لمستخدم'
        using errcode = 'P0001';
    end if;

    -- 0025: the default store itself must be within the ACTOR's own
    -- operable range, unless the actor is Super Admin -- mirrors the same
    -- "cannot delegate wider than your own access" principle 0018 already
    -- applies to user_store_access grants, applied here to default_store_id.
    if new.default_store_id is distinct from old.default_store_id
      and new.default_store_id is not null
      and not public.is_super_admin(auth.uid())
    then
      if not exists (
        select 1 from public.user_operable_store_ids(auth.uid()) sid where sid = new.default_store_id
      ) then
        raise exception 'لا يمكنك تعيين متجر افتراضي لمستخدم آخر لا تملك أنت نفسك صلاحية العمل عليه'
          using errcode = 'P0001';
      end if;
    end if;
  end if;

  return new;
end;
$$;

comment on function public.enforce_store_scope_authorization() is
  'Store-scope columns (store_access_scope, default_store_id) require users.manage_store_access. Blocks self-escalation, restricts scope=all to Super Admin, and (0025) restricts default_store_id itself to the actor''s own operable range -- unless the actor is Super Admin. Independent of and additional to 0014/0018/0030''s column-authorization triggers.';

-- ---------------------------------------------------------------------------
-- enforce_store_access_delegation(): extend the operable-range delegation
-- limit to the DELETE branch too, not just INSERT. Revoking someone else's
-- access to a store you cannot yourself operate is just as out-of-scope as
-- granting it -- an actor scoped to A+B must not be able to touch ANY
-- user_store_access row for store C, whether adding or removing it.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_store_access_delegation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_target_user uuid := coalesce(new.user_id, old.user_id);
  v_store_id uuid := coalesce(new.store_id, old.store_id);
begin
  if public.is_trusted_bootstrap_context() then
    return coalesce(new, old);
  end if;

  if v_target_user = auth.uid() and not public.is_super_admin(auth.uid()) then
    raise exception 'لا يمكنك تعديل وصولك الخاص للمتاجر (user_store_access) بنفسك'
      using errcode = 'P0001';
  end if;

  if not public.is_super_admin(auth.uid()) then
    if not exists (
      select 1 from public.user_operable_store_ids(auth.uid()) sid where sid = v_store_id
    ) then
      if TG_OP = 'INSERT' then
        raise exception 'لا يمكنك منح وصول لمتجر لا تملك أنت نفسك صلاحية العمل عليه'
          using errcode = 'P0001';
      else
        raise exception 'لا يمكنك إلغاء وصول لمتجر لا تملك أنت نفسك صلاحية العمل عليه'
          using errcode = 'P0001';
      end if;
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

comment on function public.enforce_store_access_delegation() is
  '0025: extends 0018''s INSERT-only operable-range delegation limit to DELETE too -- a non-Super-Admin can neither grant nor revoke access to a store outside their own operable set, for any OTHER user (their own row is blocked entirely, see the self-block check above). Applies regardless of which RLS policy (users.manage_permissions or users.manage_store_access) let the INSERT/DELETE through.';

-- (trigger user_store_access_enforce_delegation from 0018 already fires
-- `before insert or delete` -- CREATE OR REPLACE FUNCTION is enough, no
-- need to recreate the trigger itself.)

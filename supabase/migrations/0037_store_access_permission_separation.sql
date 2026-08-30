-- ============================================================================
-- 0037: Fully separate users.manage_store_access from users.manage_permissions
-- ============================================================================
-- Patch 1.4.1, item 1. Ships as a NEW migration after 0036.
--
-- 0018 (Foundation Hardening 1.2) introduced users.manage_store_access as a
-- dedicated permission for Store Scope / Store Access management, and added
-- its own additive RLS policies for it (profiles_update_store_access,
-- user_store_access_insert_scoped, user_store_access_delete_scoped). It did
-- NOT, however, remove 0010's ORIGINAL policies -- and Postgres OR-combines
-- multiple permissive policies for the same command on the same table, so
-- both paths have remained independently sufficient ever since:
--
--  * profiles.store_access_scope / default_store_id: 0010's own
--    `profiles_update` policy only covers users.edit/users.disable, and
--    0018's `profiles_update_store_access` only covers
--    users.manage_store_access -- users.manage_permissions was never a path
--    to these two columns at the RLS layer, and 0030's column-authorization
--    trigger rewrite confirms this (its three independent groups are
--    users.edit/users.disable/users.manage_store_access -- no
--    users.manage_permissions branch exists there at all). This half was
--    already correctly separated; this migration adds an explicit SQL test
--    proving it (see supabase/tests/rls_and_permissions.test.sql, section
--    30) rather than changing anything for it.
--  * user_store_access (INSERT/DELETE): 0010's `user_store_access_insert`/
--    `user_store_access_delete` policies authorize ANY holder of
--    users.manage_permissions -- a broad "manage roles/permissions/role
--    assignments/individual overrides" permission never intended to also
--    grant store-access management. This IS a real, currently-exploitable
--    gap: a users.manage_permissions holder (without
--    users.manage_store_access) can still grant/revoke a target's
--    user_store_access rows directly, or via the replace_user_store_access()
--    RPC (which issues ordinary INSERT/DELETE statements subject to these
--    same RLS policies). enforce_store_access_delegation()'s own comment
--    (0018) even documented the overlap explicitly at the time: "Applies
--    regardless of which RLS policy (users.manage_permissions or
--    users.manage_store_access) let the INSERT/DELETE through" -- describing
--    it as expected, not as a bug, back then. It is a bug now: Store Access
--    management is meant to be its own, narrower security boundary,
--    independent of who can reassign roles/permissions.
--
-- Fix, in the same defense-in-depth shape this project has used throughout
-- (RLS is not trusted alone; a Trigger enforces the same rule independently
-- of which RLS policy let a row through):
--  1. Drop 0010's two original user_store_access INSERT/DELETE policies.
--     0018's `_scoped` policies already cover the legitimate path
--     (users.manage_store_access); dropping the two above leaves exactly
--     that path standing at the RLS layer.
--  2. enforce_store_access_delegation() (0018) now ALSO requires
--     users.manage_store_access explicitly, independent of which RLS policy
--     let the row through -- so even a future RLS change that accidentally
--     reopens a users.manage_permissions (or any other) path still cannot
--     bypass this trigger. This mirrors 0033/0034's own pattern of adding a
--     trigger-level check that does not rely solely on RLS row-visibility.
--
-- users.manage_permissions itself is UNCHANGED (still governs roles,
-- role_permissions, user_roles, user_permission_overrides exactly as
-- before) -- only its accidental reach into user_store_access is removed.

-- ---------------------------------------------------------------------------
-- 1) Drop the two original, over-broad policies. (0010's file itself is
--    untouched -- this is a DROP issued from a new migration, the
--    established pattern from 0035 for narrowing an old policy.)
-- ---------------------------------------------------------------------------
drop policy if exists user_store_access_insert on public.user_store_access;
drop policy if exists user_store_access_delete on public.user_store_access;

-- ---------------------------------------------------------------------------
-- 2) enforce_store_access_delegation(): CREATE OR REPLACE, layered onto the
--    CURRENT (0025) version of this function -- NOT the original 0018
--    version. 0025 already extended 0018's INSERT-only operable-range check
--    to the DELETE branch too (a non-Super-Admin can neither grant nor
--    revoke access to a store outside their own operable set); this
--    revision must preserve that DELETE-branch check unchanged and only add
--    the new users.manage_store_access requirement as the FIRST check,
--    independent of RLS, ahead of everything 0025 already had.
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

  -- 0037: explicit permission requirement, independent of whichever RLS
  -- policy let the row through. Super Admin passes automatically --
  -- has_permission() short-circuits true for Super Admin (0008) regardless
  -- of role_permissions rows, and super_admin holds this permission by
  -- default (0018's seed) in any case.
  if not public.has_permission('users.manage_store_access') then
    raise exception 'يتطلب تعديل وصول المتاجر (user_store_access) صلاحية users.manage_store_access على وجه التحديد -- users.manage_permissions لم تعد كافية لذلك'
      using errcode = 'P0001';
  end if;

  if v_target_user = auth.uid() and not public.is_super_admin(auth.uid()) then
    raise exception 'لا يمكنك تعديل وصولك الخاص للمتاجر (user_store_access) بنفسك'
      using errcode = 'P0001';
  end if;

  -- 0025's DELETE-branch delegation-range check, preserved unchanged here:
  -- applies to BOTH INSERT and DELETE, not just INSERT (the original 0018
  -- version -- which this replacement must NOT regress to -- only checked
  -- INSERT).
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
  '0037: now requires users.manage_store_access explicitly (first check, independent of RLS) in addition to 0025''s self-block and INSERT+DELETE delegation-range checks (preserved unchanged) -- users.manage_permissions is no longer a sufficient permission for user_store_access writes, at the trigger level as well as the RLS level (0037 also drops the two original 0010 policies that granted this table to users.manage_permissions holders). Applies to every write path, including replace_user_store_access(), which is SECURITY INVOKER and issues ordinary INSERT/DELETE statements subject to this same trigger.';

revoke execute on function public.enforce_store_access_delegation() from public;

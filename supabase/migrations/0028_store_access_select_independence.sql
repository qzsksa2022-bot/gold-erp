-- ============================================================================
-- 0028: Complete users.manage_store_access independence (SELECT path)
-- ============================================================================
-- Foundation Hardening 1.3, item 2a. Ships as a NEW migration after 0027.
--
-- 0018 gave users.manage_store_access its own INSERT/DELETE policies on
-- user_store_access (user_store_access_insert_scoped /
-- user_store_access_delete_scoped) and its own UPDATE policy on profiles
-- (profiles_update_store_access), so an actor holding ONLY this permission
-- (plus whatever they need to see the target user, e.g. users.view) can
-- write store-scope changes. But 0010's original user_store_access_select
-- policy only covers `user_id = auth.uid() or users.view or stores.view` --
-- it was never extended for users.manage_store_access. That is a real,
-- reachable gap: replace_user_store_access() (0018) is SECURITY INVOKER and
-- computes its add/remove diff with a plain
--   select store_id from public.user_store_access where user_id = p_user_id
-- which is subject to RLS exactly like any other client SELECT -- an actor
-- who holds ONLY users.manage_store_access (not users.view or stores.view)
-- gets an empty read back for someone else's CURRENT grants, so the diff
-- against p_store_ids is computed against the wrong baseline (every
-- existing grant looks like it needs to be re-added, nothing looks removable
-- unless explicitly re-omitted) -- store-scope management is silently
-- broken for a user whose role bundle was deliberately built narrowly around
-- this one permission, exactly the scenario item 2 exists to guarantee works.
--
-- Fix: one additive permissive policy. Postgres OR-combines multiple
-- permissive policies for the same command on the same table, so this adds
-- an alternate SELECT path without touching 0010's original policy at all.

create policy user_store_access_select_scoped on public.user_store_access
  for select to authenticated
  using (public.has_permission('users.manage_store_access'));

comment on policy user_store_access_select_scoped on public.user_store_access is
  '0028: lets a users.manage_store_access-only holder (without users.view/stores.view) read user_store_access rows for any user -- required for replace_user_store_access() (0018, SECURITY INVOKER) to correctly diff an existing grant set against the desired one under RLS. Additive alongside 0010''s original user_store_access_select policy.';

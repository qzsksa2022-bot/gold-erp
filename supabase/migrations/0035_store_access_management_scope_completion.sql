-- ============================================================================
-- 0035: Complete the users.manage_store_access UI/DB flow
-- ============================================================================
-- Foundation Hardening 1.4, item 4. Ships as a NEW migration after 0034.
--
-- Foundation Hardening 1.3 item 2 gave users.manage_store_access its own
-- write paths (0018) and its own SELECT path (0028), so a limited-scope
-- store-access manager can write and read what the app already asks for --
-- but the app itself never grew a "which stores can THIS actor manage"
-- concept. Both src/features/users/components/user-store-scope-form.tsx
-- (default_store_id) and user-store-access-editor.tsx (the 'multiple'-scope
-- checklist) were fed `allStores` from listActiveStoresForSelect(), which
-- queries `stores` directly and is gated by RLS's stores_select policy --
-- `stores.view` only. An actor who holds ONLY users.manage_store_access (not
-- stores.view, exactly the narrow role bundle item 2 exists to make work)
-- gets an EMPTY store list back and cannot use either control at all, even
-- though the database has fully supported their writes since 0018. Three
-- more gaps found alongside that one:
--
--  1. Even a stores.view holder sees the FULL store catalog, not just the
--     stores they can actually operate/delegate -- an actor scoped to
--     stores A+B could see (and attempt to select) store C in the UI, only
--     to be rejected at the DB layer (0018/0025's delegation-limit
--     triggers) -- confusing, and leaks the existence/names of stores
--     outside the actor's own scope for no reason.
--  2. setUserStoreAccessAction (src/features/users/actions.ts) sends the
--     client's FULL edited selection to replace_user_store_access() (0018)
--     as the new desired set. If a target already holds a store (say C)
--     that is outside the actor's own operable range, the actor's UI (once
--     fixed to only show A/B) can never include C in that list -- so
--     replace_user_store_access()'s plain diff would try to REMOVE C
--     (present in "existing", absent from the submitted list), which then
--     hits enforce_store_access_delegation's operable-range check and fails
--     the ENTIRE atomic replace, even though the actor never intended to
--     touch C at all and was only trying to edit A/B.
--  3. 0028's SELECT policy grants a users.manage_store_access holder
--     visibility of user_store_access rows for EVERY store, system-wide --
--     wider than that actor's own operable range actually needs. A
--     genuinely limited-scope manager (A+B) has no legitimate reason to see
--     who has access to store C.

-- ---------------------------------------------------------------------------
-- 1) Dedicated data source: stores THIS actor may manage. Self-scoped
--    (auth.uid()), independent of stores.view entirely -- gated only by
--    holding users.manage_store_access, and returning only the actor's own
--    operable stores (or every active store, for a Super Admin, who is
--    exempt from every delegation-limit check elsewhere too). This is what
--    both the Store Scope form and the Store Access checklist should be
--    fed from, instead of the unfiltered, stores.view-gated store catalog.
-- ---------------------------------------------------------------------------
create or replace function public.manageable_stores_for_actor()
returns table(id uuid, code text, name_ar text, name_en text, status text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select s.id, s.code, s.name_ar, s.name_en, s.status
  from public.stores s
  where s.status = 'active'
    and public.has_permission('users.manage_store_access')
    and (
      public.is_super_admin(auth.uid())
      or s.id in (select * from public.my_operable_store_ids())
    )
  order by s.name_ar;
$$;

comment on function public.manageable_stores_for_actor() is
  '0035: stores the CURRENT user may manage store-access grants for -- gated by users.manage_store_access (empty otherwise), scoped to the actor''s own operable stores unless they are Super Admin (all active stores). Does not depend on stores.view at all. Feeds both the Store Scope (default_store_id) and Store Access (user_store_access checklist) admin UI so a limited-scope manager never sees a store outside their own range.';

revoke execute on function public.manageable_stores_for_actor() from public;
grant execute on function public.manageable_stores_for_actor() to authenticated;

-- ---------------------------------------------------------------------------
-- 2) replace_user_store_access(): CREATE OR REPLACE (0018) so a removal
--    candidate outside the ACTOR's own operable range is left untouched,
--    rather than attempted (and the whole atomic replace failing because of
--    it). This is explicit and unconditional -- correct regardless of
--    whatever else the actor's SELECT can additionally see (e.g. if they
--    also separately hold users.view/stores.view, which independently
--    widens what 0010's original, still-active user_store_access_select
--    policy lets them read) -- not merely incidental to RLS visibility.
--    Additions are NOT similarly filtered here: an attempt to ADD a store
--    outside the actor's operable range is still caught (and still rolls
--    back the whole call) by enforce_store_access_delegation's existing
--    INSERT-side check -- that is a real error to surface, not a
--    should-silently-ignore case, since manageable_stores_for_actor() above
--    means a well-behaved client should never even offer such a store as a
--    candidate to add in the first place.
-- ---------------------------------------------------------------------------
create or replace function public.replace_user_store_access(p_user_id uuid, p_store_ids uuid[])
returns void
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_to_add uuid[];
  v_to_remove uuid[];
  -- am_i_super_admin() (not is_super_admin(uuid) directly) -- this function
  -- is SECURITY INVOKER, and is_super_admin(uuid) is service_role-only
  -- (0015); am_i_super_admin() is the authenticated-callable self-scoped
  -- wrapper around it.
  v_is_super boolean := public.am_i_super_admin();
begin
  select coalesce(array_agg(sid), '{}') into v_to_add
  from (
    select distinct sid from unnest(coalesce(p_store_ids, '{}'::uuid[])) as sid
    except
    select store_id from public.user_store_access where user_id = p_user_id
  ) t;

  select coalesce(array_agg(store_id), '{}') into v_to_remove
  from (
    select store_id from public.user_store_access where user_id = p_user_id
    except
    select distinct sid from unnest(coalesce(p_store_ids, '{}'::uuid[])) as sid
  ) t
  where v_is_super or store_id in (select * from public.my_operable_store_ids());

  if array_length(v_to_remove, 1) > 0 then
    delete from public.user_store_access
      where user_id = p_user_id and store_id = any(v_to_remove);
  end if;

  if array_length(v_to_add, 1) > 0 then
    insert into public.user_store_access (user_id, store_id, created_by)
    select p_user_id, sid, auth.uid()
    from unnest(v_to_add) as sid;
  end if;
end;
$$;

comment on function public.replace_user_store_access(uuid, uuid[]) is
  '0035: same atomic all-or-nothing replace as 0018, but a removal candidate outside the ACTOR''s own operable range (unless the actor is Super Admin) is now explicitly left untouched instead of attempted -- an actor scoped to A+B editing a target who also holds C (outside the actor''s range) can freely add/remove A/B without C being dropped or the whole call failing because of it. SECURITY INVOKER, unchanged: still runs as the calling user under RLS and every user_store_access trigger.';

-- (grants unchanged by CREATE OR REPLACE -- still revoked from public,
-- granted to authenticated, as set in 0018.)

-- ---------------------------------------------------------------------------
-- 3) Narrow 0028's SELECT policy: a users.manage_store_access holder should
--    only see user_store_access rows for stores within their OWN operable
--    range (or every row, for a Super Admin) -- not system-wide. Additive
--    permissive policies OR-combine, so 0010's original policy (user_id =
--    auth.uid() OR users.view OR stores.view) is untouched and still applies
--    independently -- an actor who ALSO separately holds users.view/
--    stores.view keeps that wider visibility through that policy, exactly
--    as documented in 0028; this migration only narrows the ADDITIONAL path
--    0028 itself introduced. Cannot ALTER a policy's USING clause in place
--    -- Postgres requires DROP + CREATE; 0028's file itself is untouched.
-- ---------------------------------------------------------------------------
drop policy if exists user_store_access_select_scoped on public.user_store_access;

create policy user_store_access_select_scoped on public.user_store_access
  for select to authenticated
  using (
    public.has_permission('users.manage_store_access')
    and (
      -- am_i_super_admin(), not is_super_admin(uuid) directly -- an RLS
      -- policy's USING clause runs as the querying role (authenticated),
      -- not as a SECURITY DEFINER function body, and is_super_admin(uuid)
      -- is service_role-only (0015).
      public.am_i_super_admin()
      or store_id in (select * from public.my_operable_store_ids())
    )
  );

comment on policy user_store_access_select_scoped on public.user_store_access is
  '0035: narrows 0028''s users.manage_store_access SELECT path to the actor''s own operable stores (or every store, for Super Admin) -- a limited-scope manager no longer sees grants for stores outside their own range through this policy. Additive alongside 0010''s original, unrestricted-by-store user_store_access_select policy (user_id = auth.uid() OR users.view OR stores.view), which is unaffected.';

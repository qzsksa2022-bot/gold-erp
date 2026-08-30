-- ============================================================================
-- 0031: Inactive-session hardening for store-scope resolution
-- ============================================================================
-- Foundation Hardening 1.3, item 7 (database half -- see src/lib/supabase/
-- middleware.ts for the redirect-loop fix, the app-layer half of this item).
--
-- get_user_permissions()/has_permission() (0008) already fail closed for an
-- inactive account: get_user_permissions() filters its whole result through
-- is_active_user(p_user_id), and has_permission() checks is_active_user()
-- before anything else. A second independent review found the store-ID
-- resolvers introduced in 0017 -- user_operable_store_ids(uuid) and
-- user_visible_store_ids(uuid) -- never adopted that same pattern: they
-- resolve purely from store_access_scope/default_store_id/user_store_access
-- with NO check of profiles.status at all. A suspended user's JWT session
-- can, in principle, still exist (a session is only actually torn down when
-- the client next hits the middleware/guard and gets redirected -- see the
-- app-layer fix) -- for that brief window, or if a caller ever queries
-- my_operable_store_ids()/my_visible_store_ids() directly without going
-- through the permission-gated app layer, these functions would still
-- return the suspended user's full store list as if the account were fully
-- active. Since these are exactly the "what can I act on / see" self-scoped
-- security helpers Sales/Reports will build row-level authorization on top
-- of, they need to fail closed the same way has_permission() already does.
--
-- Fix: CREATE OR REPLACE both uuid-taking resolvers to return an empty set
-- immediately for a non-active target user. The self-scoped wrappers
-- (my_operable_store_ids/my_visible_store_ids/my_accessible_store_ids, all
-- from 0015/0017) get this "for free" since they are thin pass-throughs to
-- these two functions -- no separate fix needed there, and no risk of the
-- wrapper and the underlying resolver ever disagreeing.

create or replace function public.user_operable_store_ids(p_user_id uuid)
returns setof uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_scope text;
  v_default_store_id uuid;
begin
  -- 0031: fail closed for any non-active account, mirroring
  -- get_user_permissions()'s is_active_user() gate -- a suspended or
  -- still-pending_setup user can operate zero stores, full stop, regardless
  -- of whatever store_access_scope/default_store_id/user_store_access rows
  -- still say.
  if not public.is_active_user(p_user_id) then
    return;
  end if;

  select store_access_scope, default_store_id
    into v_scope, v_default_store_id
    from public.profiles
    where id = p_user_id;

  if v_scope is null then
    return;
  end if;

  if v_scope = 'all' then
    return query select id from public.stores where status = 'active';

  elsif v_scope = 'multiple' then
    return query
      select usa.store_id
      from public.user_store_access usa
      join public.stores s on s.id = usa.store_id
      where usa.user_id = p_user_id and s.status = 'active';

  elsif v_scope = 'single' then
    if v_default_store_id is not null then
      return query
        select s.id from public.stores s
        where s.id = v_default_store_id and s.status = 'active';
    end if;
  end if;

  return;
end;
$$;

comment on function public.user_operable_store_ids(uuid) is
  'Stores this user may target for NEW business data (sales, future modules): active stores only, resolved per store_access_scope. Returns EMPTY for any non-active account (0031), independent of whatever store_access_scope/user_store_access still says -- mirrors has_permission()''s fail-closed behavior. Use for anything that creates/updates a row. See user_visible_store_ids() for read-only historical access.';

create or replace function public.user_visible_store_ids(p_user_id uuid)
returns setof uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_scope text;
  v_default_store_id uuid;
begin
  -- 0031: same fail-closed rule as user_operable_store_ids() above. Even
  -- read-only historical visibility must not be granted through a session
  -- belonging to an account that is not currently active -- an admin who
  -- wants to review a suspended employee's past sales does so through their
  -- OWN (active, permissioned) session, not through the suspended user's.
  if not public.is_active_user(p_user_id) then
    return;
  end if;

  select store_access_scope, default_store_id
    into v_scope, v_default_store_id
    from public.profiles
    where id = p_user_id;

  if v_scope is null then
    return;
  end if;

  if v_scope = 'all' then
    return query select id from public.stores;

  elsif v_scope = 'multiple' then
    return query select store_id from public.user_store_access where user_id = p_user_id;

  elsif v_scope = 'single' then
    if v_default_store_id is not null then
      return query select v_default_store_id;
    end if;
  end if;

  return;
end;
$$;

comment on function public.user_visible_store_ids(uuid) is
  'Stores this user may VIEW historical data/reports for: every store their scope was ever granted, active or disabled. Returns EMPTY for any non-active account (0031). Never use this to authorize a NEW write -- see user_operable_store_ids() for that.';

-- (user_accessible_store_ids(uuid) is a plain alias defined via `select *
-- from user_operable_store_ids(...)` (0017) -- it inherits this fix
-- automatically, no redefinition needed. my_operable_store_ids() /
-- my_visible_store_ids() / my_accessible_store_ids() (0015/0017) are thin
-- `select * from ...(auth.uid())` wrappers -- same automatic inheritance.)

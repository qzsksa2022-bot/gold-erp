-- ============================================================================
-- 0017: Separate historical visibility from operational store access
-- ============================================================================
-- Foundation Hardening 1.2, item 4. Ships as a NEW migration -- 0001-0016
-- stay byte-for-byte untouched, per the standing rule that already-applied
-- migrations are immutable and fixes are always forward CREATE OR REPLACE /
-- ALTER statements.
--
-- Problem: user_accessible_store_ids() (0008, rewritten in 0012) has one
-- meaning doing two jobs. Today it is the ONLY store-scope resolver, and
-- 0012's fix already scopes the 'all' branch to ACTIVE stores only -- but
-- the 'multiple'/'single' branches never filtered by store status at all,
-- so a store that gets disabled AFTER a grant/assignment was made still
-- shows up as "accessible" for a multiple/single-scoped user, incorrectly
-- implying they can still act on it. Conflating "can this user operate a
-- NEW transaction against this store" with "can this user see this store's
-- PAST data/reports" under one function is exactly the ambiguity that
-- caused that gap, and would keep causing subtler ones once Sales/Reports
-- are built on top of it: disabling a store must stop new operations
-- without erasing history.
--
-- Fix: two functions with one job each.
--  * user_operable_store_ids(uuid)  -- ACTIVE stores only, for anything that
--    creates/updates NEW business data (Sales, future modules). This is
--    what user_accessible_store_ids() should always have meant, so it
--    becomes a thin alias for this (CREATE OR REPLACE, identical signature,
--    so nothing that already calls it by name breaks) instead of adding a
--    third, redundantly-named function.
--  * user_visible_store_ids(uuid)   -- every store the user's scope was
--    EVER granted for, active or disabled, for read-only historical/report
--    access. A disabled store's past transactions must stay visible to
--    whoever could see them before -- disabling a branch is not the same
--    as erasing it from history.
-- Self-scoped wrappers (my_operable_store_ids / my_visible_store_ids /
-- the existing my_accessible_store_ids, now aliasing my_operable_store_ids)
-- follow the same authenticated-callable, auth.uid()-hardcoded pattern
-- 0015 established for their uuid-taking, service_role-only counterparts.

-- ---------------------------------------------------------------------------
-- user_operable_store_ids(uuid): what user_accessible_store_ids() should
-- always have meant. Same three-branch shape as 0012, but 'multiple' and
-- 'single' now also require status = 'active', closing the gap described
-- above.
-- ---------------------------------------------------------------------------
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
  'Stores this user may target for NEW business data (sales, future modules): active stores only, resolved per store_access_scope. Use for anything that creates/updates a row. See user_visible_store_ids() for read-only historical access, which does not filter by status.';

revoke execute on function public.user_operable_store_ids(uuid) from public;
grant execute on function public.user_operable_store_ids(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- user_accessible_store_ids(uuid): kept as the stable, already-referenced
-- name (DELIVERY_REPORT.md, any future module code) but now formally an
-- alias for user_operable_store_ids() -- no longer a function with its own
-- separate (and, before 0017, subtly incomplete) implementation. This is
-- the "better design, same principle" alternative to introducing a
-- confusing third near-duplicate: the name that already meant "what can
-- this user act on" keeps meaning exactly that, unambiguously.
-- ---------------------------------------------------------------------------
create or replace function public.user_accessible_store_ids(p_user_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select * from public.user_operable_store_ids(p_user_id);
$$;

comment on function public.user_accessible_store_ids(uuid) is
  'Alias for user_operable_store_ids(uuid) as of 0017 -- kept for name stability. "Accessible" always meant "operable" (can act on); see user_visible_store_ids() for the separate historical-visibility concept this migration introduces.';

-- (grants already set by 0015 -- revoke from public, revoke from
-- authenticated, grant to service_role -- unaffected by CREATE OR REPLACE.)

-- ---------------------------------------------------------------------------
-- user_visible_store_ids(uuid): historical/reporting visibility. Every
-- store this scope was ever granted, regardless of current status. A
-- disabled store must not vanish from someone's past reports just because
-- it can no longer be selected for new operations.
-- ---------------------------------------------------------------------------
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
  select store_access_scope, default_store_id
    into v_scope, v_default_store_id
    from public.profiles
    where id = p_user_id;

  if v_scope is null then
    return;
  end if;

  if v_scope = 'all' then
    -- HQ-wide scope: every store ever, active or disabled -- full history.
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
  'Stores this user may VIEW historical data/reports for: every store their scope was ever granted, active or disabled. Never use this to authorize a NEW write -- see user_operable_store_ids() for that.';

revoke execute on function public.user_visible_store_ids(uuid) from public;
grant execute on function public.user_visible_store_ids(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Self-scoped wrappers, authenticated-callable, hardcoded to auth.uid() --
-- same shape as 0015's get_my_permissions/am_i_super_admin/
-- my_accessible_store_ids.
-- ---------------------------------------------------------------------------
create or replace function public.my_operable_store_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select * from public.user_operable_store_ids(auth.uid());
$$;

comment on function public.my_operable_store_ids() is
  'Self-scoped: active stores the current user may target for NEW business data. See my_visible_store_ids() for historical/report access.';

revoke execute on function public.my_operable_store_ids() from public;
grant execute on function public.my_operable_store_ids() to authenticated;

create or replace function public.my_accessible_store_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select * from public.my_operable_store_ids();
$$;

comment on function public.my_accessible_store_ids() is
  'Alias for my_operable_store_ids() as of 0017 -- kept for name stability.';

-- (grants already set by 0015; unaffected by CREATE OR REPLACE.)

create or replace function public.my_visible_store_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select * from public.user_visible_store_ids(auth.uid());
$$;

comment on function public.my_visible_store_ids() is
  'Self-scoped: every store (active or disabled) the current user may view historical data/reports for.';

revoke execute on function public.my_visible_store_ids() from public;
grant execute on function public.my_visible_store_ids() to authenticated;

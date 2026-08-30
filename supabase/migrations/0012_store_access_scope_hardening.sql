-- ============================================================================
-- 0012: Fix user_accessible_store_ids() + enforce store-scope consistency
-- ============================================================================
-- Follow-up security/correctness pass after an independent review of the
-- foundation. Ships as a NEW migration (not an edit of 0005/0008/0010)
-- because this schema may already be applied to a real Supabase project by
-- the time this review lands — migrations already run must stay immutable;
-- fixes are always forward migrations that ALTER/CREATE OR REPLACE.
--
-- Bug being fixed: the original user_accessible_store_ids() (0008) computed
-- BOTH branches with a single correlated subquery reused across an UNION,
-- which meant a 'single'-scope user fell through to reading
-- user_store_access (always empty for a 'single' user in normal operation)
-- instead of profiles.default_store_id — i.e. 'single' users resolved to
-- ZERO accessible stores instead of exactly one. Rewritten explicitly below,
-- one branch per scope, so each scope's data source is unambiguous and unit
-- tested (see supabase/tests/rls_and_permissions.test.sql).

create or replace function public.user_accessible_store_ids(p_user_id uuid)
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

  -- Unknown user id: empty set, fail closed.
  if v_scope is null then
    return;
  end if;

  if v_scope = 'all' then
    -- "All permitted stores" = every ACTIVE store. A disabled store is not
    -- an operable target for future store-scoped business data (Sales,
    -- Reports, ...) even for an 'all'-scope user.
    return query select id from public.stores where status = 'active';

  elsif v_scope = 'multiple' then
    -- Exactly the explicit grants in user_store_access -- no implicit
    -- fallback to anything else.
    return query select store_id from public.user_store_access where user_id = p_user_id;

  elsif v_scope = 'single' then
    -- Exactly the one default_store_id -- NEVER user_store_access. This is
    -- the branch that was broken before this migration.
    if v_default_store_id is not null then
      return query select v_default_store_id;
    end if;
    -- 'single' with a null default_store_id: empty set, fail closed. The
    -- CHECK constraint added below prevents this state from being written
    -- going forward, but the function stays defensive for any pre-existing
    -- row on a database this migration is applied to.
  end if;

  return;
end;
$$;

comment on function public.user_accessible_store_ids(uuid) is
  'Set of store ids visible to a user given their store_access_scope: all -> every active store, multiple -> user_store_access grants only, single -> default_store_id only (never user_store_access). Fixed in 0012 -- see migration comment for the bug this replaced.';

-- ---------------------------------------------------------------------------
-- Store-scope consistency (spec review item 7)
-- ---------------------------------------------------------------------------

-- 'single' must always have a default store to be scoped to -- but only
-- once the account is actually ACTIVE. 0011's safety-net trigger (and the
-- normal create-user flow, before finalize_new_user_profile completes it)
-- deliberately creates a brand-new profile as status='suspended' with the
-- table's own default store_access_scope='single' and no default_store_id
-- yet -- there is no store to assign until an admin picks one. A suspended
-- account cannot do anything regardless (is_active_user() gates every
-- permission check), so this constraint only needs to hold once status
-- flips to 'active'. Added as NOT VALID + separate VALIDATE so applying
-- this to a database that may already have rows never blocks the DDL
-- itself on a table lock timeout; the VALIDATE step below still runs
-- synchronously in this same migration (transactional DDL), so any
-- pre-existing violation surfaces immediately and by name, which is more
-- actionable than a bare failed ALTER TABLE.
alter table public.profiles
  add constraint profiles_single_scope_requires_default_store
  check (status <> 'active' or store_access_scope <> 'single' or default_store_id is not null)
  not valid;

alter table public.profiles
  validate constraint profiles_single_scope_requires_default_store;

-- A store referenced as someone's default (or granted via user_store_access)
-- must exist (already guaranteed by the FK) AND be active -- a disabled
-- store should never become newly assignable as anyone's access target,
-- even though existing historical references to it are left alone (we do
-- NOT retroactively strip access when a store is disabled; that is a
-- separate, deliberate business decision documented in DELIVERY_REPORT.md).
create or replace function public.enforce_default_store_is_active()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.default_store_id is not null then
    if not exists (
      select 1 from public.stores
      where id = new.default_store_id and status = 'active'
    ) then
      raise exception 'المتجر الافتراضي المحدد غير موجود أو غير نشط' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

create trigger profiles_enforce_default_store_active
  before insert or update of default_store_id on public.profiles
  for each row
  execute function public.enforce_default_store_is_active();

create or replace function public.enforce_store_access_grant_is_active()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1 from public.stores
    where id = new.store_id and status = 'active'
  ) then
    raise exception 'لا يمكن منح وصول لمتجر غير نشط' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger user_store_access_enforce_active
  before insert on public.user_store_access
  for each row
  execute function public.enforce_store_access_grant_is_active();

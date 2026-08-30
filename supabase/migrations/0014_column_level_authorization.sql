-- ============================================================================
-- 0014: Column-level authorization for status-only permissions
-- ============================================================================
-- 0010's profiles_update / stores_update RLS policies authorize an UPDATE if
-- the actor holds EITHER the full-edit permission OR the disable-only
-- permission -- but a plain RLS policy operates on the whole row, so an
-- actor who holds ONLY users.disable / stores.disable could still change
-- full_name, email, store scope, or a store's code/name through a direct
-- PostgREST call, not just through the app's UI (which only exposes a
-- status toggle for that permission). RLS alone cannot express "this
-- specific column may change, these others may not" -- comparing OLD vs NEW
-- per-column needs a trigger, since an UPDATE policy's USING clause sees the
-- OLD row and WITH CHECK sees the NEW row, never both at once.
--
-- This closes that gap at the database layer: it fires for every UPDATE
-- regardless of client (Next.js server action, Supabase Studio, a raw
-- PostgREST call with a stolen/leaked disable-only user's JWT), independent
-- of whatever the application layer does or forgets to do.

-- ---------------------------------------------------------------------------
-- profiles: users.edit -> any column; users.disable -> status only.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_profile_update_column_authorization()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  -- Full edit rights: no column restriction.
  if public.has_permission('users.edit') then
    return new;
  end if;

  -- Disable-only rights: every column except status (and the
  -- system-maintained updated_at/updated_by, see set_updated_by() below)
  -- must be byte-for-byte unchanged.
  if public.has_permission('users.disable') then
    if new.full_name is distinct from old.full_name
      or new.email is distinct from old.email
      or new.default_store_id is distinct from old.default_store_id
      or new.store_access_scope is distinct from old.store_access_scope
      or new.created_by is distinct from old.created_by
      or new.created_at is distinct from old.created_at
    then
      raise exception 'صلاحية تعطيل/تفعيل المستخدم تسمح فقط بتغيير حالة الحساب (status)، وليس بقية البيانات'
        using errcode = 'P0001';
    end if;
    return new;
  end if;

  -- Neither permission: RLS's USING/WITH CHECK should already have rejected
  -- this before the trigger ever runs, but fail closed regardless in case a
  -- future policy change ever loosens that without updating this trigger.
  raise exception 'لا تملك صلاحية تعديل بيانات المستخدمين' using errcode = 'P0001';
end;
$$;

create trigger profiles_enforce_column_authorization
  before update on public.profiles
  for each row
  execute function public.enforce_profile_update_column_authorization();

-- ---------------------------------------------------------------------------
-- stores: stores.edit -> any column; stores.disable -> status only.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_store_update_column_authorization()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if public.has_permission('stores.edit') then
    return new;
  end if;

  if public.has_permission('stores.disable') then
    if new.code is distinct from old.code
      or new.name_ar is distinct from old.name_ar
      or new.name_en is distinct from old.name_en
      or new.logo_url is distinct from old.logo_url
      or new.description is distinct from old.description
      or new.created_by is distinct from old.created_by
      or new.created_at is distinct from old.created_at
    then
      raise exception 'صلاحية تعطيل/تفعيل المتجر تسمح فقط بتغيير حالة المتجر (status)، وليس بقية بياناته'
        using errcode = 'P0001';
    end if;
    return new;
  end if;

  raise exception 'لا تملك صلاحية تعديل بيانات المتاجر' using errcode = 'P0001';
end;
$$;

create trigger stores_enforce_column_authorization
  before update on public.stores
  for each row
  execute function public.enforce_store_update_column_authorization();

-- ---------------------------------------------------------------------------
-- updated_by should reflect the actual acting user rather than depend on
-- every server action remembering to pass it explicitly (it did not,
-- consistently, before this migration). This runs BEFORE the two triggers
-- above only in the sense that trigger firing order is irrelevant here: the
-- column-authorization checks above intentionally exclude updated_by /
-- updated_at from their "must stay unchanged" comparisons specifically so
-- this trigger is free to stamp them on every update, including
-- disable-only ones.
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_by()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is not null then
    new.updated_by = auth.uid();
  end if;
  return new;
end;
$$;

create trigger profiles_set_updated_by
  before update on public.profiles
  for each row
  execute function public.set_updated_by();

create trigger stores_set_updated_by
  before update on public.stores
  for each row
  execute function public.set_updated_by();

create trigger roles_set_updated_by
  before update on public.roles
  for each row
  execute function public.set_updated_by();

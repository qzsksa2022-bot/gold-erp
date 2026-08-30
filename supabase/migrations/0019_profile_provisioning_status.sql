-- ============================================================================
-- 0019: Separate "provisioning in progress" from "disabled" (pending_setup)
-- ============================================================================
-- Foundation Hardening 1.2, item 2.
--
-- Problem: 'suspended' was doing two unrelated jobs. 0011's safety-net
-- trigger (and, before finalize_new_user_profile completes it, the normal
-- create-user flow) creates a brand-new profile as status='suspended'
-- purely because Provisioning is not finished yet (no full_name/store scope
-- set). But 'suspended' is ALSO the status a real, previously-active account
-- gets moved to when an admin deliberately disables it. Because
-- finalize_new_user_profile() (0016) matched on status='suspended', it
-- could not tell "a brand-new account still being onboarded" apart from "a
-- real account someone disabled on purpose" -- its WHERE clause would
-- happily match either, meaning a users.create holder could technically
-- re-"finalize" (reactivate, and overwrite full_name/store scope on) a
-- genuinely disabled account, not just complete a new one.
--
-- Fix: a third, distinct status. 'pending_setup' means "provisioning not
-- finished yet" and is ONLY ever set by a trusted bootstrap context (the
-- auth-user-created trigger, or direct SQL); 'suspended' is now reserved
-- exclusively for accounts an admin deliberately disabled, and
-- finalize_new_user_profile() only ever matches 'pending_setup' rows.

-- ---------------------------------------------------------------------------
-- Widen the status CHECK constraint. Cannot ALTER a CHECK in place --
-- Postgres requires DROP + ADD; done here as one DDL sequence in a new
-- migration rather than touching 0002's file. profiles_status_check is the
-- auto-generated name for 0002's inline CHECK (confirmed against the actual
-- schema before writing this migration).
-- ---------------------------------------------------------------------------
alter table public.profiles drop constraint profiles_status_check;
alter table public.profiles
  add constraint profiles_status_check
  check (status in ('active', 'suspended', 'pending_setup'));

comment on column public.profiles.status is
  'active: normal working account. suspended: deliberately disabled by an admin -- never anything else. pending_setup: auth.users row exists but profile provisioning (full_name/store scope) is not finished -- set only by handle_new_auth_user() (trusted context) and cleared only by finalize_new_user_profile() (0019). A pending_setup row cannot sign in (is_active_user()/login gate both require status = ''active'').';

-- ---------------------------------------------------------------------------
-- handle_new_auth_user() (0011): new profiles start pending_setup, not
-- suspended. CREATE OR REPLACE from this new migration; 0011's file is
-- untouched.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name, email, status)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    new.email,
    'pending_setup'
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- finalize_new_user_profile() (0016): only ever completes a still-
-- pending_setup row. A 'suspended' row -- a real account an admin
-- deliberately disabled -- can never match this WHERE clause any more, so a
-- users.create holder cannot use this RPC to reactivate one (see
-- supabase/tests/rls_and_permissions.test.sql for the explicit test).
-- Reactivating a genuinely suspended account remains exactly what it always
-- was: a status update via users.disable (setUserStatusAction), unrelated
-- to this function.
-- ---------------------------------------------------------------------------
create or replace function public.finalize_new_user_profile(
  p_user_id uuid,
  p_full_name text,
  p_default_store_id uuid,
  p_store_access_scope text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.has_permission('users.create') then
    raise exception 'لا تملك صلاحية إنشاء مستخدمين' using errcode = '42501';
  end if;

  update public.profiles
  set full_name = p_full_name,
      status = 'active',
      default_store_id = p_default_store_id,
      store_access_scope = p_store_access_scope,
      created_by = auth.uid(),
      updated_by = auth.uid()
  where id = p_user_id
    and status = 'pending_setup';

  if not found then
    raise exception 'تعذّر إكمال إنشاء الملف الشخصي -- المستخدم غير موجود أو ليس بانتظار الإكمال (قد يكون مُفعّلاً بالفعل أو معطّلاً)'
      using errcode = 'P0002';
  end if;
end;
$$;

comment on function public.finalize_new_user_profile(uuid, text, uuid, text) is
  'Activates a freshly-created, still-pending_setup profile row on behalf of the current users.create-holding admin. Matches status = ''pending_setup'' ONLY (0019) -- never ''suspended'', so this cannot be used to reactivate a deliberately disabled account. Called from the REGULAR session client (not admin/service-role) so auth.uid() is the acting admin and the profiles audit trigger attributes the resulting event correctly.';

-- (grants unchanged by CREATE OR REPLACE -- still revoked from public,
-- granted to authenticated, as set in 0016.)

-- ---------------------------------------------------------------------------
-- Transitioning INTO 'active' FROM 'pending_setup' is a provisioning-
-- completion action, not a generic status edit -- require users.create for
-- it specifically, regardless of which permission (users.edit,
-- users.disable, or even the broader users.manage_store_access from 0018)
-- otherwise let the UPDATE reach this row. finalize_new_user_profile()
-- itself already checks has_permission('users.create') before its own
-- UPDATE, so this is redundant-but-harmless on that path (an actor who
-- passed finalize's own check trivially passes this too) and closes the
-- gap where a users.edit holder could otherwise activate a pending_setup
-- row directly via a raw UPDATE, skipping finalize_new_user_profile()'s
-- permission gate entirely.
--
-- Moving INTO 'pending_setup' is never legitimate from client context --
-- only handle_new_auth_user() (trusted, an INSERT not an UPDATE) creates
-- pending_setup rows.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_pending_setup_transition()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if old.status = 'pending_setup' and new.status = 'active' and not public.has_permission('users.create') then
    raise exception 'إتمام تفعيل حساب مستخدم جديد يتطلب صلاحية users.create'
      using errcode = 'P0001';
  end if;

  if new.status = 'pending_setup' and old.status is distinct from 'pending_setup' then
    raise exception 'لا يمكن نقل حساب إلى حالة انتظار الإعداد (pending_setup) إلا عند إنشائه'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.enforce_pending_setup_transition() is
  'pending_setup -> active requires users.create specifically (closes the gap where users.edit alone could activate a not-yet-onboarded profile directly, bypassing finalize_new_user_profile()''s own permission gate). Nothing may move a row INTO pending_setup via UPDATE -- only the trusted handle_new_auth_user() INSERT sets it.';

revoke execute on function public.enforce_pending_setup_transition() from public;

create trigger profiles_enforce_pending_setup_transition
  before update on public.profiles
  for each row
  execute function public.enforce_pending_setup_transition();

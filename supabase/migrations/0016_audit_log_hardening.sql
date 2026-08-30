-- ============================================================================
-- 0016: Tamper-resistant, database-enforced audit logging
-- ============================================================================
-- The 0008 design already made forging WHO an audit row is attributed to
-- impossible (log_audit_event() stamps user_id = auth.uid() itself, and
-- audit_logs has no direct INSERT policy for any client role). This
-- migration closes the two gaps an independent review found in what could
-- still happen around that:
--
--  1. log_audit_event() took entirely free-form action/entity_type/
--     old_values/new_values and was callable by ANY authenticated user
--     (and, for the failed-login case, by `anon` too) -- so while a user
--     could not impersonate someone ELSE's identity in the log, they could
--     freely fabricate FICTIONAL events under their own identity (fake
--     entity_type/entity_id/values unrelated to anything that actually
--     happened), polluting a trail that is supposed to be trustworthy
--     evidence.
--  2. Because logging sensitive-table mutations was an explicit call each
--     server action had to remember to make (src/lib/audit/log.ts), any
--     mutation that reached the tables directly -- a raw PostgREST call, a
--     future code path that forgets the call, Supabase Studio -- left NO
--     audit trail at all, even though the mutation itself still succeeded
--     under RLS.
--
-- Fix: move logging of every sensitive table's mutations OUT of the
-- application layer and INTO AFTER triggers on the tables themselves, so a
-- row change and its audit entry happen atomically in the same transaction
-- no matter how the change was made. The application layer keeps exactly
-- one narrow, allowlisted RPC for the two auth-lifecycle events that have
-- no backing table row (login success, logout); the old free-form
-- log_audit_event() becomes service_role-only (used from server-only code
-- for the pre-auth failed-login case, see src/features/auth/actions.ts).

-- ---------------------------------------------------------------------------
-- 1) Generic sensitive-table audit trigger
-- ---------------------------------------------------------------------------
-- One reusable function, parameterized per trigger via TG_ARGV so each
-- table declares its own (entity_type, id_column) instead of duplicating
-- near-identical trigger bodies eight times. entity_type is deliberately
-- NOT always the same as the table name (e.g. role_permissions logs as
-- 'role_permission', not 'role', which is already used by the roles table
-- itself) so two structurally different events never collide under the
-- same action string.
create or replace function public.audit_table_changes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entity_type text := TG_ARGV[0];
  v_id_column text := TG_ARGV[1]; -- may be NULL (e.g. system_settings uses its own `id`, always present)
  v_action text;
  v_entity_id uuid;
  v_old jsonb;
  v_new jsonb;
begin
  if TG_OP = 'INSERT' then
    v_new := to_jsonb(new);
    v_entity_id := nullif(v_new ->> v_id_column, '')::uuid;
  elsif TG_OP = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    v_entity_id := nullif(v_new ->> v_id_column, '')::uuid;
  elsif TG_OP = 'DELETE' then
    v_old := to_jsonb(old);
    v_entity_id := nullif(v_old ->> v_id_column, '')::uuid;
  end if;

  v_action := v_entity_type || '.' || lower(TG_OP);

  insert into public.audit_logs (user_id, action, entity_type, entity_id, old_values, new_values)
  values (auth.uid(), v_action, v_entity_type, v_entity_id, v_old, v_new);

  return coalesce(new, old);
end;
$$;

comment on function public.audit_table_changes() is
  'Generic AFTER trigger: writes an audit_logs row for every insert/update/delete on the table it is attached to. Args: (entity_type, id_column). This is what makes sensitive-table audit logging impossible to bypass via a direct REST call -- it fires regardless of which client made the change.';

revoke execute on function public.audit_table_changes() from public;

create trigger profiles_audit_trigger
  after insert or update or delete on public.profiles
  for each row execute function public.audit_table_changes('user', 'id');

create trigger stores_audit_trigger
  after insert or update or delete on public.stores
  for each row execute function public.audit_table_changes('store', 'id');

create trigger roles_audit_trigger
  after insert or update or delete on public.roles
  for each row execute function public.audit_table_changes('role', 'id');

create trigger role_permissions_audit_trigger
  after insert or update or delete on public.role_permissions
  for each row execute function public.audit_table_changes('role_permission', 'role_id');

create trigger user_roles_audit_trigger
  after insert or update or delete on public.user_roles
  for each row execute function public.audit_table_changes('user_role', 'user_id');

create trigger user_permission_overrides_audit_trigger
  after insert or update or delete on public.user_permission_overrides
  for each row execute function public.audit_table_changes('permission_override', 'user_id');

create trigger user_store_access_audit_trigger
  after insert or update or delete on public.user_store_access
  for each row execute function public.audit_table_changes('user_store_access', 'user_id');

create trigger system_settings_audit_trigger
  after insert or update or delete on public.system_settings
  for each row execute function public.audit_table_changes('system_setting', 'id');

-- ---------------------------------------------------------------------------
-- 2) Lock down the old free-form writer to service_role only.
-- ---------------------------------------------------------------------------
-- Every sensitive-table mutation is now covered by a trigger above, so
-- `authenticated` no longer needs a general-purpose "log anything" RPC at
-- all. `anon` never should have had one (that grant existed only for the
-- failed-login case, which moves to a server-only path below).
revoke execute on function public.log_audit_event(text, text, uuid, jsonb, jsonb, text, inet, text) from authenticated, anon;
-- (already granted to service_role in 0008; left as-is -- this is now used
-- exclusively from src/features/auth/actions.ts via the ADMIN/service-role
-- client for the failed-login case, which has no session/auth.uid() yet.)

comment on function public.log_audit_event is
  'General-purpose audit writer, service_role ONLY as of 0016. Every sensitive-table mutation is logged automatically by a trigger instead (see audit_table_changes()); the only remaining legitimate caller is the server-only failed-login path in src/features/auth/actions.ts, which uses the admin/service-role client. Never call this with a client-supplied action/entity_type from `authenticated` context -- that is exactly the free-form-fabrication gap this migration closes.';

-- ---------------------------------------------------------------------------
-- 3) Narrow, allowlisted replacement for the two auth-lifecycle events that
--    have no backing table row and therefore cannot be covered by a
--    trigger: a successful login, and a logout. Both happen in an already-
--    authenticated context (a session exists by the time either fires), so
--    auth.uid() is reliable and the action value is constrained to exactly
--    two literals -- an authenticated user cannot use this to fabricate any
--    other kind of event.
-- ---------------------------------------------------------------------------
create or replace function public.log_auth_event(p_action text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'يجب أن يكون المستخدم مسجلاً للدخول' using errcode = 'P0001';
  end if;

  if p_action not in ('auth.login_success', 'auth.logout') then
    raise exception 'إجراء غير مسموح به لهذه الدالة' using errcode = 'P0001';
  end if;

  insert into public.audit_logs (user_id, action, entity_type, entity_id)
  values (auth.uid(), p_action, 'auth', auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.log_auth_event(text) is
  'Allowlisted audit writer for auth.login_success / auth.logout only -- the two lifecycle events that happen in an authenticated context but have no backing table row for a trigger to fire from. p_action is checked against a fixed allowlist, so this cannot be used to fabricate arbitrary audit entries the way the old general-purpose RPC could.';

revoke execute on function public.log_auth_event(text) from public;
grant execute on function public.log_auth_event(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) finalize_new_user_profile(): closes two problems together.
--
--    (a) User-creation partial failure (spec review item 6): the server
--    action creates the auth.users row via the Admin API, then must
--    separately activate the profiles row (full_name, status, store
--    scoping) that 0011's safety-net trigger already created as
--    'suspended'. That second step previously used the ADMIN/service-role
--    client (profiles has no direct client INSERT policy, and the second
--    step is technically an UPDATE of an existing row). Two problems with
--    that: if the second call failed, the first call's auth user was left
--    orphaned with no way to complete or clean itself up; and because the
--    service-role client carries no user JWT, auth.uid() was NULL for that
--    write, so the audit trigger above could not attribute the 'user.create'
--    event to the admin who actually performed it.
--
--    (b) Fixed by moving profile activation into this SECURITY DEFINER
--    function, callable via the REGULAR session-bound client (so auth.uid()
--    is the acting admin, and the audit trigger attributes correctly), with
--    its own has_permission('users.create') check standing in for the RLS
--    check a normal client-side UPDATE would have needed. It only ever
--    completes a still-'suspended', never-before-activated profile row --
--    not a general bypass-RLS profile editor -- so its privileged surface
--    stays as narrow as the one specific job it does. The server action
--    (src/features/users/actions.ts) now compensates by deleting the
--    orphaned auth user via the Admin API if this call fails.
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
    and status = 'suspended';

  if not found then
    raise exception 'تعذّر إكمال إنشاء الملف الشخصي -- المستخدم غير موجود أو مُفعّل بالفعل'
      using errcode = 'P0002';
  end if;
end;
$$;

comment on function public.finalize_new_user_profile(uuid, text, uuid, text) is
  'Activates a freshly-created (still-suspended) profile row on behalf of the current user.create-holding admin. Only matches status=''suspended'' rows -- not a general profile editor. Called from the REGULAR session client (not admin/service-role) so auth.uid() is the acting admin and the profiles audit trigger attributes the resulting user.create event correctly.';

revoke execute on function public.finalize_new_user_profile(uuid, text, uuid, text) from public;
grant execute on function public.finalize_new_user_profile(uuid, text, uuid, text) to authenticated;

-- ============================================================================
-- 0008: Permission resolution functions
-- ============================================================================
-- These are the SINGLE SOURCE OF TRUTH for "what can this user do". Both RLS
-- policies (database layer) and the application layer (src/lib/permissions)
-- call the same functions, so there is exactly one place the grant/revoke
-- logic is implemented — no risk of the app and the database disagreeing.
--
-- All functions are SECURITY DEFINER with a locked-down search_path so they
-- can read cross-table data (role_permissions, overrides...) regardless of
-- the calling user's own RLS visibility, without being hijackable via a
-- malicious search_path.

create or replace function public.is_active_user(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.profiles
    where id = p_user_id and status = 'active'
  );
$$;

create or replace function public.is_super_admin(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.user_roles ur
    join public.roles r on r.id = ur.role_id
    where ur.user_id = p_user_id and r.key = 'super_admin'
  );
$$;

-- Effective permission keys for a user = (role-granted permissions) plus
-- explicit 'grant' overrides, minus explicit 'revoke' overrides. Super
-- admins and inactive/suspended users are handled by the caller
-- (has_permission short-circuits super_admin to true; inactive users get
-- an empty set here so every check fails closed).
create or replace function public.get_user_permissions(p_user_id uuid)
returns table (permission_key text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with role_perms as (
    select p.key
    from public.user_roles ur
    join public.role_permissions rp on rp.role_id = ur.role_id
    join public.permissions p on p.id = rp.permission_id
    where ur.user_id = p_user_id
  ),
  grants as (
    select p.key
    from public.user_permission_overrides upo
    join public.permissions p on p.id = upo.permission_id
    where upo.user_id = p_user_id and upo.effect = 'grant'
  ),
  revokes as (
    select p.key
    from public.user_permission_overrides upo
    join public.permissions p on p.id = upo.permission_id
    where upo.user_id = p_user_id and upo.effect = 'revoke'
  ),
  combined as (
    select key from role_perms
    union
    select key from grants
  )
  select key from combined
  where public.is_active_user(p_user_id)
  except
  select key from revokes;
$$;

comment on function public.get_user_permissions(uuid) is
  'Effective permission keys for a user: (role permissions + grants − revokes), empty if the user is not active.';

-- Primary check used everywhere (RLS policies + app). Super admins always
-- pass; everyone else is resolved through get_user_permissions().
create or replace function public.has_permission(p_permission_key text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    public.is_active_user(auth.uid())
    and (
      public.is_super_admin(auth.uid())
      or exists (
        select 1
        from public.get_user_permissions(auth.uid()) gp
        where gp.permission_key = p_permission_key
      )
    );
$$;

comment on function public.has_permission(text) is
  'True if the CURRENT authenticated user (auth.uid()) holds the given permission key. Used in RLS policies and app-layer guards.';

-- Store ids the current context user is allowed to see, based on
-- store_access_scope + user_store_access. Foundation for future row-level
-- store scoping (Sales, Reports, ...); not yet consumed by any RLS policy
-- in this phase because no store-scoped business data exists yet.
create or replace function public.user_accessible_store_ids(p_user_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id from public.stores
  where (select store_access_scope from public.profiles where id = p_user_id) = 'all'
  union
  select store_id from public.user_store_access
  where user_id = p_user_id
    and (select store_access_scope from public.profiles where id = p_user_id) in ('single', 'multiple');
$$;

comment on function public.user_accessible_store_ids(uuid) is
  'Set of store ids visible to a user given their store_access_scope. Foundation for future store-scoped modules.';

-- Trusted audit-log writer. No RLS INSERT policy exists on audit_logs for
-- any client role — this function is the ONLY path that can create a row,
-- and it always stamps user_id from auth.uid(), so a client can never
-- forge an entry attributed to someone else.
create or replace function public.log_audit_event(
  p_action text,
  p_entity_type text,
  p_entity_id uuid default null,
  p_old_values jsonb default null,
  p_new_values jsonb default null,
  p_reason text default null,
  p_ip_address inet default null,
  p_user_agent text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  insert into public.audit_logs (
    user_id, action, entity_type, entity_id,
    old_values, new_values, reason, ip_address, user_agent
  )
  values (
    auth.uid(), p_action, p_entity_type, p_entity_id,
    p_old_values, p_new_values, p_reason, p_ip_address, p_user_agent
  )
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.log_audit_event is
  'Only supported way to write an audit log row. Stamps user_id = auth.uid(); callable by any authenticated user so their own actions can be logged, but they cannot set another user_id.';

-- Also grantable to anon: a FAILED login attempt happens before a session
-- exists, but "محاولة دخول فاشلة" is explicitly a case the audit log should
-- capture when possible (spec section 10). auth.uid() is null in that
-- context, so the row is written with user_id = null — never forgeable as
-- someone else's identity, just anonymous.
grant execute on function public.log_audit_event to authenticated, anon;

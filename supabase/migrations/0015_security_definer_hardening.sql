-- ============================================================================
-- 0015: SECURITY DEFINER hardening
-- ============================================================================
-- Postgres grants EXECUTE on a newly created function to PUBLIC by default
-- unless explicitly revoked. Every SECURITY DEFINER function added in 0008,
-- 0009, 0011, 0012, 0013, and 0014 was created without an explicit REVOKE,
-- so PUBLIC (which includes `anon`) has had EXECUTE on all of them this
-- whole time -- confirmed against pg_proc.proacl during this review. This
-- migration closes that for every SECURITY DEFINER function that exists so
-- far, and fixes a real information-disclosure gap: four of them accept an
-- arbitrary `p_user_id uuid` and were grantable to `authenticated`, which
-- meant any signed-in user could call e.g.
--   select * from get_user_permissions('<someone-elses-uuid>')
-- directly via PostgREST RPC and read another user's exact permission set,
-- super-admin status, or accessible store list.
--
-- search_path note: every function below already sets
-- `search_path = public, pg_temp` at creation (0008/0009/0011/0012/0013/
-- 0014) or does so here for the two new wrappers -- this is the standard
-- Postgres-safe pattern for SECURITY DEFINER (an unqualified, mutable
-- search_path is the classic SECURITY DEFINER hijack vector: a caller could
-- otherwise create a same-named object earlier in their own search_path and
-- have the definer-privileged function execute it instead of the intended
-- one). Nothing further was needed there; this migration is exclusively
-- about EXECUTE grants.

-- ---------------------------------------------------------------------------
-- Revoke the PUBLIC default on every SECURITY DEFINER function so far.
-- ---------------------------------------------------------------------------
revoke execute on function public.is_active_user(uuid) from public;
revoke execute on function public.is_super_admin(uuid) from public;
revoke execute on function public.get_user_permissions(uuid) from public;
revoke execute on function public.has_permission(text) from public;
revoke execute on function public.user_accessible_store_ids(uuid) from public;
revoke execute on function public.log_audit_event(text, text, uuid, jsonb, jsonb, text, inet, text) from public;
revoke execute on function public.protect_last_super_admin() from public;
revoke execute on function public.prevent_super_admin_privilege_escalation() from public;
revoke execute on function public.protect_system_role_identity() from public;
revoke execute on function public.handle_new_auth_user() from public;
revoke execute on function public.enforce_default_store_is_active() from public;
revoke execute on function public.enforce_store_access_grant_is_active() from public;
revoke execute on function public.prevent_self_role_modification() from public;
revoke execute on function public.prevent_sensitive_role_assignment() from public;
revoke execute on function public.prevent_self_permission_override_modification() from public;
revoke execute on function public.prevent_permission_override_grant_escalation() from public;
revoke execute on function public.prevent_role_permission_grant_escalation() from public;
revoke execute on function public.enforce_profile_update_column_authorization() from public;
revoke execute on function public.enforce_store_update_column_authorization() from public;
revoke execute on function public.set_updated_by() from public;

-- Trigger-only functions (return type `trigger`) are invoked solely by the
-- trigger mechanism, never callable directly via SQL/RPC/PostgREST -- no
-- role needs a re-grant on any of them, not even service_role.

-- ---------------------------------------------------------------------------
-- has_permission(text) takes no user id -- it always resolves against
-- auth.uid() internally -- so it is safe to expose broadly and stays
-- available to `authenticated` (used throughout RLS policies and the app).
-- ---------------------------------------------------------------------------
grant execute on function public.has_permission(text) to authenticated;

-- ---------------------------------------------------------------------------
-- The arbitrary-uuid "check any user" functions become service_role-only.
-- Nothing in the app calls them with anyone else's id (confirmed against
-- src/lib/permissions/session.ts, updated alongside this migration to use
-- the self-scoped wrappers below instead).
--
-- The REVOKE ... FROM PUBLIC above does NOT remove 0010's separate,
-- explicit `grant ... to authenticated` on these same four functions --
-- REVOKE FROM PUBLIC only removes the default/PUBLIC grant, an explicit
-- per-role grant is independent and must be revoked in its own right. This
-- is exactly the gap that would otherwise leave the arbitrary-uuid
-- information disclosure this migration exists to close still wide open.
-- ---------------------------------------------------------------------------
revoke execute on function public.is_active_user(uuid) from authenticated;
revoke execute on function public.is_super_admin(uuid) from authenticated;
revoke execute on function public.get_user_permissions(uuid) from authenticated;
revoke execute on function public.user_accessible_store_ids(uuid) from authenticated;

grant execute on function public.is_active_user(uuid) to service_role;
grant execute on function public.is_super_admin(uuid) to service_role;
grant execute on function public.get_user_permissions(uuid) to service_role;
grant execute on function public.user_accessible_store_ids(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Self-scoped wrappers: what `authenticated` actually calls going forward.
-- Each ignores any caller-supplied id entirely and hardcodes auth.uid(), so
-- there is no parameter to smuggle another user's id through.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_permissions()
returns table (permission_key text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select permission_key from public.get_user_permissions(auth.uid());
$$;

comment on function public.get_my_permissions() is
  'Self-scoped wrapper: always resolves against auth.uid(), the calling user. Use this from the app instead of get_user_permissions(uuid), which is now service_role-only.';

revoke execute on function public.get_my_permissions() from public;
grant execute on function public.get_my_permissions() to authenticated;

create or replace function public.am_i_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_super_admin(auth.uid());
$$;

comment on function public.am_i_super_admin() is
  'Self-scoped wrapper: always resolves against auth.uid(). Use this from the app instead of is_super_admin(uuid), which is now service_role-only.';

revoke execute on function public.am_i_super_admin() from public;
grant execute on function public.am_i_super_admin() to authenticated;

create or replace function public.my_accessible_store_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select * from public.user_accessible_store_ids(auth.uid());
$$;

comment on function public.my_accessible_store_ids() is
  'Self-scoped wrapper: always resolves against auth.uid(). Foundation for future store-scoped modules (Sales, Reports, ...) to call from the app without ever passing another user''s id.';

revoke execute on function public.my_accessible_store_ids() from public;
grant execute on function public.my_accessible_store_ids() to authenticated;

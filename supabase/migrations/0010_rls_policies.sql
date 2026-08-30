-- ============================================================================
-- 0010: Row Level Security policies
-- ============================================================================
-- Security model recap:
--  * Every table touched by the app has RLS enabled (see earlier migrations).
--  * Authorization decisions are made by has_permission()/is_super_admin()
--    (0008) — never by inspecting a role name string in a policy.
--  * The Next.js app additionally hides UI it knows the user cannot use, but
--    that is a UX nicety only: these policies are what actually protects the
--    data if someone bypasses the UI (devtools, direct REST/PostgREST calls
--    with the user's JWT, etc).
--  * Server actions that need to act with elevated privilege (creating an
--    auth user via the Admin API, cross-tenant bootstrap) use the SERVICE
--    ROLE key from trusted server-only code — never shipped to the browser
--    (see src/lib/supabase/admin.ts). RLS still applies to every other
--    query, which runs with the signed-in user's own JWT.

grant execute on function public.is_active_user(uuid) to authenticated;
grant execute on function public.is_super_admin(uuid) to authenticated;
grant execute on function public.get_user_permissions(uuid) to authenticated;
grant execute on function public.has_permission(text) to authenticated;
grant execute on function public.user_accessible_store_ids(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create policy profiles_select on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.has_permission('users.view'));

create policy profiles_update on public.profiles
  for update to authenticated
  using (public.has_permission('users.edit') or public.has_permission('users.disable'))
  with check (public.has_permission('users.edit') or public.has_permission('users.disable'));

-- No INSERT/DELETE policy for `authenticated`: user creation happens only
-- through the trusted server action using the service-role client, and hard
-- delete of a profile is never allowed by the app.

-- ---------------------------------------------------------------------------
-- permissions (read-only catalog)
-- ---------------------------------------------------------------------------
create policy permissions_select on public.permissions
  for select to authenticated
  using (public.has_permission('users.view') or public.has_permission('users.manage_permissions'));

-- ---------------------------------------------------------------------------
-- roles
-- ---------------------------------------------------------------------------
create policy roles_select on public.roles
  for select to authenticated
  using (public.has_permission('users.view') or public.has_permission('users.manage_permissions'));

create policy roles_insert on public.roles
  for insert to authenticated
  with check (public.has_permission('users.manage_permissions'));

create policy roles_update on public.roles
  for update to authenticated
  using (public.has_permission('users.manage_permissions'))
  with check (public.has_permission('users.manage_permissions'));

create policy roles_delete on public.roles
  for delete to authenticated
  using (public.has_permission('users.manage_permissions') and not is_system);

-- ---------------------------------------------------------------------------
-- role_permissions
-- ---------------------------------------------------------------------------
create policy role_permissions_select on public.role_permissions
  for select to authenticated
  using (public.has_permission('users.view') or public.has_permission('users.manage_permissions'));

create policy role_permissions_insert on public.role_permissions
  for insert to authenticated
  with check (public.has_permission('users.manage_permissions'));

create policy role_permissions_delete on public.role_permissions
  for delete to authenticated
  using (public.has_permission('users.manage_permissions'));

-- ---------------------------------------------------------------------------
-- user_roles
-- ---------------------------------------------------------------------------
create policy user_roles_select on public.user_roles
  for select to authenticated
  using (user_id = auth.uid() or public.has_permission('users.view'));

create policy user_roles_insert on public.user_roles
  for insert to authenticated
  with check (public.has_permission('users.manage_permissions'));

create policy user_roles_delete on public.user_roles
  for delete to authenticated
  using (public.has_permission('users.manage_permissions'));

-- ---------------------------------------------------------------------------
-- user_permission_overrides
-- ---------------------------------------------------------------------------
create policy user_permission_overrides_select on public.user_permission_overrides
  for select to authenticated
  using (user_id = auth.uid() or public.has_permission('users.view'));

create policy user_permission_overrides_insert on public.user_permission_overrides
  for insert to authenticated
  with check (public.has_permission('users.manage_permissions'));

create policy user_permission_overrides_update on public.user_permission_overrides
  for update to authenticated
  using (public.has_permission('users.manage_permissions'))
  with check (public.has_permission('users.manage_permissions'));

create policy user_permission_overrides_delete on public.user_permission_overrides
  for delete to authenticated
  using (public.has_permission('users.manage_permissions'));

-- ---------------------------------------------------------------------------
-- stores
-- ---------------------------------------------------------------------------
create policy stores_select on public.stores
  for select to authenticated
  using (public.has_permission('stores.view'));

create policy stores_insert on public.stores
  for insert to authenticated
  with check (public.has_permission('stores.create'));

create policy stores_update on public.stores
  for update to authenticated
  using (public.has_permission('stores.edit') or public.has_permission('stores.disable'))
  with check (public.has_permission('stores.edit') or public.has_permission('stores.disable'));

-- No DELETE policy: stores are never hard-deleted from the app (disable via
-- UPDATE status='disabled' instead), matching the "no delete for stores
-- with historical data" requirement — history isn't tracked yet so we just
-- disallow deletion entirely and revisit if a true "undo mistaken create"
-- case is needed later.

-- ---------------------------------------------------------------------------
-- user_store_access
-- ---------------------------------------------------------------------------
create policy user_store_access_select on public.user_store_access
  for select to authenticated
  using (
    user_id = auth.uid()
    or public.has_permission('users.view')
    or public.has_permission('stores.view')
  );

create policy user_store_access_insert on public.user_store_access
  for insert to authenticated
  with check (public.has_permission('users.manage_permissions'));

create policy user_store_access_delete on public.user_store_access
  for delete to authenticated
  using (public.has_permission('users.manage_permissions'));

-- ---------------------------------------------------------------------------
-- audit_logs (read-only to clients; writes only via log_audit_event())
-- ---------------------------------------------------------------------------
create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (public.has_permission('audit_logs.view'));

-- Intentionally no INSERT/UPDATE/DELETE policy for `authenticated` — see
-- 0008's log_audit_event() and the table comment.

-- ---------------------------------------------------------------------------
-- system_settings
-- ---------------------------------------------------------------------------
-- 'general' and 'appearance' are readable even before login (branding on the
-- login screen: system name, logo, accent color). 'security' and anything
-- else requires settings.manage. Writes always require settings.manage.
create policy system_settings_select_public on public.system_settings
  for select to anon, authenticated
  using (category in ('general', 'appearance'));

create policy system_settings_select_privileged on public.system_settings
  for select to authenticated
  using (public.has_permission('settings.manage'));

create policy system_settings_insert on public.system_settings
  for insert to authenticated
  with check (public.has_permission('settings.manage'));

create policy system_settings_update on public.system_settings
  for update to authenticated
  using (public.has_permission('settings.manage'))
  with check (public.has_permission('settings.manage'));

create policy system_settings_delete on public.system_settings
  for delete to authenticated
  using (public.has_permission('settings.manage'));

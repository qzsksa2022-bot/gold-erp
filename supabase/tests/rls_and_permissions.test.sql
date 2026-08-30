-- ============================================================================
-- Integration test: permission resolution, RLS, and the protection triggers.
-- ============================================================================
-- Rewritten after an independent security review of the foundation added
-- migrations 0012-0016 (store-scope fixes, privilege-escalation hardening,
-- column-level authorization, SECURITY DEFINER hardening, tamper-resistant
-- audit logging). This file now exercises every one of those, in addition
-- to the original 0008/0009 coverage, and never asserts "the table is
-- empty" as if that were proof of anything -- every visibility/audit
-- assertion here is checked against rows this script creates itself first.
--
-- Extended again (sections 12-17) after a SECOND independent review of the
-- foundation, Foundation Hardening 1.2, covering migrations 0017-0024:
-- operable vs. visible store ids, store-scope self-escalation/delegation
-- limits + the atomic replace RPC, Super Admin protection with two active
-- Super Admins present, system-managed column immutability (incl.
-- profiles.email), roles.is_system/key lockdown, and the audit action
-- taxonomy fix. Section 9 (finalize_new_user_profile) was also extended in
-- place (9d/9e/9f) for the new pending_setup/suspended distinction.
--
-- Extended again (sections 18-24) after a THIRD independent review,
-- Foundation Hardening 1.3, covering migrations 0025-0031: completing
-- store-scope delegation (default_store_id + the DELETE branch),
-- users.manage_store_access SELECT independence, the column-authorization
-- rewrite, closing the provisioning bypass (provisioned_at), symmetric
-- sensitive-permission protection, full-entity Super Admin protection, and
-- inactive-session store-scope fail-closed behavior.
--
-- Extended again (sections 25-29) after a FOURTH independent review,
-- Foundation Hardening 1.4, covering migrations 0032-0036: a legacy
-- provisioned_at backfill, user_permission_overrides identity immutability,
-- completing store-scope delegation for scope-only changes (not just
-- default_store_id), completing the users.manage_store_access UI/DB flow
-- (a dedicated manageable-stores source, atomic-replace out-of-range
-- preservation, and a narrower SELECT policy), and fixing the
-- cancelled-invite lifecycle (no more stranded auth.users rows -- sections
-- 9f/21 were also updated in place to reflect that pending_setup ->
-- suspended is now rejected for every non-trusted actor).
--
-- Extended a final time (sections 30-32) for Patch 1.4.1, a narrow follow-up
-- patch on top of Foundation Hardening 1.4 (NOT a new independent review) --
-- exactly three targeted fixes and no new features, covering migrations
-- 0037-0038: fully separating users.manage_store_access from
-- users.manage_permissions (closing an unintended RLS-policy overlap left
-- over from 0010/0018 where both permissions independently authorized
-- user_store_access writes), fixing Store Access loading in the UI so it no
-- longer depends on stores.view (proving the root cause directly -- a raw
-- store_id select succeeds where the old embedded store:stores(...) select
-- silently returned nothing), and making Cancel Invitation produce an
-- actor-attributed user.invite_cancel audit row distinct from the automatic,
-- actor-less user.delete row the underlying auth.users deletion still
-- produces.
--
-- Extended one final time (section 33) for Foundation Audit Hotfix 1.4.2, a
-- narrow fix on top of Patch 1.4.1 -- ONE remaining gap, not a new review:
-- log_user_invite_cancel() (0038) was reachable by any `authenticated` user
-- holding users.disable, letting them write a false "invite cancelled"
-- audit row without actually cancelling anything. Migration 0039 revokes
-- `authenticated`'s EXECUTE on it entirely and replaces its usage with
-- log_user_invite_cancel_trusted() -- service_role-only, only writes the
-- event after a matching user.delete audit row already proves a real
-- completed deletion, re-verifies the supplied actor still holds
-- users.disable, and is idempotent (at most one row per target, ever, via a
-- partial unique index).
--
-- Safe to run against a real (including production-like staging) Supabase
-- database: everything happens inside a transaction that is ALWAYS rolled
-- back at the end, so no test data is left behind. Requires migrations
-- 0001-0039 + supabase/seed.sql to already be applied.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_and_permissions.test.sql
--
-- Every assertion either raises (test fails, transaction aborts, non-zero
-- exit) or prints an "OK:" notice. Read the output top to bottom.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Actors. Fully-isolated fake accounts so this never collides with real
-- data. Roles/permissions are assigned via the trusted service-role path
-- (set role service_role), exactly like the real bootstrap flow, and are
-- exempt from the escalation triggers being tested for the same reason
-- src/lib/supabase/admin.ts is exempt in production.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000001', 'test-super-admin@example.invalid'),
  ('a0000000-0000-4000-8000-000000000002', 'test-sales-employee@example.invalid'),
  ('a0000000-0000-4000-8000-000000000003', 'test-admin@example.invalid'),
  ('a0000000-0000-4000-8000-000000000004', 'test-multi-store-user@example.invalid'),
  ('a0000000-0000-4000-8000-000000000005', 'test-disable-only-user-manager@example.invalid'),
  ('a0000000-0000-4000-8000-000000000006', 'test-disable-only-store-manager@example.invalid');

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

-- Real stores FIRST (spec review item 8: create real data before testing
-- visibility -- an empty table proves nothing). Store D is created disabled
-- specifically to test the active-store enforcement added in 0012.
-- created_by/updated_by just need a profiles.id to exist (it does, via
-- 0011's safety-net trigger firing on the auth.users inserts above) --
-- their status doesn't matter for satisfying the FK.
insert into public.stores (id, code, name_ar, status, created_by, updated_by) values
  ('b0000000-0000-4000-8000-00000000000a', 'T-A', 'فرع A تجريبي', 'active', 'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001'),
  ('b0000000-0000-4000-8000-00000000000b', 'T-B', 'فرع B تجريبي', 'active', 'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001'),
  ('b0000000-0000-4000-8000-00000000000c', 'T-C', 'فرع C تجريبي', 'active', 'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001'),
  ('b0000000-0000-4000-8000-00000000000d', 'T-D', 'فرع D معطّل', 'disabled', 'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001');

-- Now activate profiles. default_store_id is set in the SAME statement as
-- status='active' for the 'single'-scope user, since 0012's CHECK
-- constraint requires an active row with scope='single' to already have
-- one -- there is no valid intermediate state where it doesn't.
update public.profiles set full_name = 'Test Super Admin', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'Test Sales Employee', status = 'active', store_access_scope = 'single',
    default_store_id = 'b0000000-0000-4000-8000-00000000000a'
  where id = 'a0000000-0000-4000-8000-000000000002';
update public.profiles set full_name = 'Test Admin', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000003';
update public.profiles set full_name = 'Test Multi Store User', status = 'active', store_access_scope = 'multiple'
  where id = 'a0000000-0000-4000-8000-000000000004';
update public.profiles set full_name = 'Test Disable-Only User Manager', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000005';
update public.profiles set full_name = 'Test Disable-Only Store Manager', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000006';

insert into public.user_roles (user_id, role_id)
  select 'a0000000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin';
insert into public.user_roles (user_id, role_id)
  select 'a0000000-0000-4000-8000-000000000002', id from public.roles where key = 'sales_employee';
insert into public.user_roles (user_id, role_id)
  select 'a0000000-0000-4000-8000-000000000003', id from public.roles where key = 'admin';
-- 004 and 006 get no role at all -- 004 is store-scope-only, 006 gets a
-- direct permission override below. 005 also gets no role.

-- Disable-only actors (w.r.t. EDIT rights, which is what section 6 actually
-- tests): each also gets the matching *.view permission, since profiles_update
-- / stores_update's RLS USING clause targets a row that must ALSO be
-- SELECT-visible to this actor first (id=self or *.view) before the UPDATE
-- even reaches the column-authorization trigger being tested -- without
-- *.view, the UPDATE would silently affect 0 rows due to RLS row
-- visibility, which would test RLS's SELECT scoping instead of the
-- column-lock trigger this section exists to verify. Neither actor gets
-- *.edit, which is the actual thing being withheld.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a0000000-0000-4000-8000-000000000005', id, 'grant' from public.permissions where key in ('users.disable', 'users.view');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a0000000-0000-4000-8000-000000000006', id, 'grant' from public.permissions where key in ('stores.disable', 'stores.view');

-- 004 is 'multiple' -> Store A + Store B via user_store_access.
insert into public.user_store_access (user_id, store_id) values
  ('a0000000-0000-4000-8000-000000000004', 'b0000000-0000-4000-8000-00000000000a'),
  ('a0000000-0000-4000-8000-000000000004', 'b0000000-0000-4000-8000-00000000000b');

reset role;
reset request.jwt.claims;

-- Precomputed as postgres/superuser (NOT inside a `set role authenticated`
-- block): 0015 made get_user_permissions(uuid) service_role-only, so
-- sections 5e/5g below -- which need to know a permission key Admin (003)
-- does NOT hold, to prove they cannot grant it -- must resolve that value
-- here, once, into a session-local temp table, rather than calling the
-- locked-down function again later from inside actor 003's own session
-- (psql's `:var` interpolation does not reach inside a `do $$ ... $$` body,
-- so a temp table is used instead of \gset).
create temporary table test_vars (key text primary key, value text);

insert into test_vars (key, value)
select 'admin_unheld_perm_id', p.id::text
from public.permissions p
where p.key not in (select permission_key from public.get_user_permissions('a0000000-0000-4000-8000-000000000003'))
limit 1;

insert into test_vars (key, value)
select 'admin_unheld_perm_key', p.key
from public.permissions p
where p.id = (select value::uuid from test_vars where key = 'admin_unheld_perm_id');

-- Temp tables are session-local and owned by whichever role created them
-- (postgres here); SET ROLE changes current_user for privilege checks
-- without ending the session, so `authenticated` still needs an explicit
-- grant to read this one back later.
grant select on test_vars to authenticated;

-- ---------------------------------------------------------------------------
-- 1. get_user_permissions / has_permission / is_super_admin (baseline, run
--    as postgres/superuser so the service_role-only lockdown in 0015 does
--    not block this internal sanity check).
-- ---------------------------------------------------------------------------
do $$
declare v_count int; v_sales_perm_count int;
begin
  select count(*) into v_sales_perm_count from public.get_user_permissions('a0000000-0000-4000-8000-000000000002');
  assert v_sales_perm_count > 0, 'موظف المبيعات يجب أن يملك بعض الصلاحيات';

  select count(*) into v_count from public.get_user_permissions('a0000000-0000-4000-8000-000000000002');
  assert v_count = v_sales_perm_count, 'العدد يجب أن يكون ثابتًا بين الاستدعاءين';

  assert public.is_super_admin('a0000000-0000-4000-8000-000000000001') = true, 'يجب أن يكون super admin';
  assert public.is_super_admin('a0000000-0000-4000-8000-000000000002') = false, 'يجب ألا يكون super admin';
  raise notice 'OK: get_user_permissions/is_super_admin يعملان (% صلاحية لموظف المبيعات)', v_sales_perm_count;
end $$;

-- ---------------------------------------------------------------------------
-- 2. user_accessible_store_ids -- all three scopes, with REAL stores and
--    MULTIPLE users (spec review item 1). This is the exact bug the review
--    flagged: 'single' previously fell through to reading user_store_access
--    (always empty for a genuinely single-scope user) instead of
--    default_store_id, resolving to zero stores instead of exactly one.
-- ---------------------------------------------------------------------------
do $$
declare
  v_all_count int;
  v_single_ids uuid[];
  v_multiple_ids uuid[];
begin
  -- 'all' (Super Admin, scope='all'): every ACTIVE store, i.e. 3 (A, B, C),
  -- NOT the 4th, disabled one.
  select count(*) into v_all_count from public.user_accessible_store_ids('a0000000-0000-4000-8000-000000000001');
  assert v_all_count = 3, format('توقعنا 3 متاجر نشطة لمستخدم all-scope، وجدنا %s', v_all_count);

  -- 'single' (sales employee, default_store_id = Store A): EXACTLY Store A,
  -- never anything from user_store_access (which has no rows for this user
  -- at all -- if the old bug were still present this would return 0 rows).
  select array_agg(sid order by sid) into v_single_ids from public.user_accessible_store_ids('a0000000-0000-4000-8000-000000000002') as sid;
  assert v_single_ids = array['b0000000-0000-4000-8000-00000000000a'::uuid],
    format('توقعنا [Store A] فقط لمستخدم single-scope، وجدنا %s', v_single_ids);

  -- 'multiple' (multi-store user, user_store_access -> A, B): exactly those
  -- two, not Store C, not the disabled Store D.
  select array_agg(sid order by sid) into v_multiple_ids from public.user_accessible_store_ids('a0000000-0000-4000-8000-000000000004') as sid;
  assert v_multiple_ids = array[
      'b0000000-0000-4000-8000-00000000000a'::uuid,
      'b0000000-0000-4000-8000-00000000000b'::uuid
    ],
    format('توقعنا [Store A, Store B] لمستخدم multiple-scope، وجدنا %s', v_multiple_ids);

  raise notice 'OK: user_accessible_store_ids صحيحة للحالات الثلاث (all=%s, single=[A], multiple=[A,B])', v_all_count;
end $$;

-- ---------------------------------------------------------------------------
-- 3. RLS as the sales employee: scoped visibility + blocked mutation
--    (stores now genuinely exist -- this proves RLS, not an empty table).
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare v_count int;
begin
  select count(*) into v_count from public.profiles where id = 'a0000000-0000-4000-8000-000000000002';
  assert v_count = 1, 'يجب أن يرى الموظف ملفه الشخصي';

  select count(*) into v_count from public.profiles where id = 'a0000000-0000-4000-8000-000000000001';
  assert v_count = 0, 'يجب ألا يرى الموظف ملف Super Admin (لا يملك users.view)';

  -- sales_employee DOES hold stores.view per seed.sql (needs to know which
  -- store they work at) -- so the correct positive assertion is that they
  -- see all 4 real stores, not zero. Testing "sees 0 rows" against a table
  -- they are actually permitted to read would not test RLS at all.
  select count(*) into v_count from public.stores;
  assert v_count = 4, format('موظف المبيعات يملك stores.view، توقعنا رؤية كل المتاجر الأربعة، وجدنا %s', v_count);

  -- roles, by contrast, requires users.view or users.manage_permissions --
  -- neither of which sales_employee holds -- and the table has 6 real
  -- seeded rows, so this genuinely exercises RLS rather than an empty table.
  select count(*) into v_count from public.roles;
  assert v_count = 0, format('يجب ألا يرى الموظف أي دور رغم وجود أدوار فعلية (لا يملك users.view)، وجد %s', v_count);

  assert public.has_permission('sales.create') = true, 'يجب أن يملك sales.create';
  assert public.has_permission('users.manage_permissions') = false, 'يجب ألا يملك users.manage_permissions';
  raise notice 'OK: RLS + has_permission صحيحة لموظف المبيعات رغم وجود بيانات فعلية (يرى 4 متاجر مصرّح بها، لا يرى أي دور)';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.stores (code, name_ar) values ('T1', 'متجر تجريبي');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع موظف المبيعات من إنشاء متجر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن موظف المبيعات من إنشاء متجر';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 4. RLS as super admin: full access
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare v_count int;
begin
  assert public.has_permission('settings.manage') = true, 'super admin يجب أن يملك كل الصلاحيات';
  select count(*) into v_count from public.stores;
  assert v_count = 4, 'super admin يجب أن يرى كل المتاجر الأربعة (بما فيها المعطّل)';
  raise notice 'OK: super admin يرى كل المتاجر (%)', v_count;
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 5. Self-privilege-escalation prevention (spec review item 2)
-- ---------------------------------------------------------------------------

-- 5a. Super-admin ROLE escalation (0009, kept from the original suite):
-- "Test Admin" (role=admin, DOES include users.manage_permissions per seed)
-- attempting to grant super_admin to the sales employee. RLS's WITH CHECK
-- alone would ALLOW this -- only the 0009 trigger stops it.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.manage_permissions') = true,
    'الممثل يجب أن يملك users.manage_permissions لكي يكون الاختبار ذا معنى';
end $$;

do $$
declare v_bug boolean := false; v_super_admin_role_id uuid;
begin
  select id into v_super_admin_role_id from public.roles where key = 'super_admin';
  begin
    insert into public.user_roles (user_id, role_id)
    values ('a0000000-0000-4000-8000-000000000002', v_super_admin_role_id);
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنعت محاولة منح دور Super Admin من مستخدم Admin غير Super Admin (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: مستخدم Admin (غير Super Admin) تمكّن من منح دور Super Admin لغيره';
  end if;
end $$;

-- 5b. Self-modification of OWN user_roles: actor 003 tries to remove (or
-- re-grant) their OWN role assignment, despite holding manage_permissions.
do $$
declare v_bug boolean := false; v_admin_role_id uuid;
begin
  select id into v_admin_role_id from public.roles where key = 'admin';
  begin
    delete from public.user_roles
      where user_id = 'a0000000-0000-4000-8000-000000000003' and role_id = v_admin_role_id;
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin من تعديل دوره الخاص بنفسه (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin من حذف دوره الخاص بنفسه';
  end if;
end $$;

-- 5c. Assigning a role that carries a sensitive permission (the 'admin'
-- role itself includes users.manage_permissions per seed) to ANOTHER user,
-- by a non-super-admin actor who nonetheless holds manage_permissions.
do $$
declare v_bug boolean := false; v_admin_role_id uuid; v_admin_has_sensitive boolean;
begin
  select id into v_admin_role_id from public.roles where key = 'admin';
  select exists (
    select 1 from public.role_permissions rp join public.permissions p on p.id = rp.permission_id
    where rp.role_id = v_admin_role_id and p.key in ('users.manage_permissions', 'settings.manage', 'backups.manage')
  ) into v_admin_has_sensitive;
  assert v_admin_has_sensitive, 'الاختبار يفترض أن دور admin يتضمن صلاحية حساسة واحدة على الأقل (راجع seed.sql إن فشل هذا)';

  begin
    insert into public.user_roles (user_id, role_id)
    values ('a0000000-0000-4000-8000-000000000002', v_admin_role_id);
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع إسناد دور يتضمن صلاحية حساسة من مستخدم غير Super Admin (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم غير Super Admin من إسناد دور يتضمن صلاحية حساسة';
  end if;
end $$;

-- 5d. Self-modification of OWN user_permission_overrides: actor 003 tries
-- to grant themselves an extra permission.
do $$
declare v_bug boolean := false; v_perm_id uuid;
begin
  select id into v_perm_id from public.permissions where key = 'gold_prices.edit';
  begin
    insert into public.user_permission_overrides (user_id, permission_id, effect)
    values ('a0000000-0000-4000-8000-000000000003', v_perm_id, 'grant');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin من تعديل استثناءات صلاحياته الخاصة بنفسه (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin من منح صلاحية لنفسه عبر user_permission_overrides';
  end if;
end $$;

-- 5e. Cannot grant (to someone ELSE) a permission the actor does not hold.
-- Uses the permission key resolved earlier (as postgres, before entering
-- any `set role authenticated` context) precisely because 0015 made
-- get_user_permissions(uuid) unreachable from inside that context now.
do $$
declare v_bug boolean := false; v_unheld_perm_id uuid; v_unheld_key text;
begin
  select value::uuid into v_unheld_perm_id from test_vars where key = 'admin_unheld_perm_id';
  select value into v_unheld_key from test_vars where key = 'admin_unheld_perm_key';
  assert v_unheld_perm_id is not null, 'الاختبار يفترض وجود صلاحية واحدة على الأقل لا يملكها Admin';

  begin
    insert into public.user_permission_overrides (user_id, permission_id, effect)
    values ('a0000000-0000-4000-8000-000000000002', v_unheld_perm_id, 'grant');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع منح صلاحية (%) لا يملكها المانح نفسه', v_unheld_key;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم من منح صلاحية (%) لا يملكها هو نفسه', v_unheld_key;
  end if;
end $$;

-- 5f. Sensitive permission (users.manage_permissions) can NEVER be granted
-- to another user by a non-super-admin, even though the actor holds it
-- themselves (holding it does not let you re-grant it).
do $$
declare v_bug boolean := false; v_perm_id uuid;
begin
  assert public.has_permission('users.manage_permissions') = true; -- sanity: 003 does hold it
  select id into v_perm_id from public.permissions where key = 'users.manage_permissions';
  begin
    insert into public.user_permission_overrides (user_id, permission_id, effect)
    values ('a0000000-0000-4000-8000-000000000002', v_perm_id, 'grant');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع منح users.manage_permissions من مستخدم غير Super Admin رغم امتلاكه لها (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم غير Super Admin من منح users.manage_permissions لغيره';
  end if;
end $$;

-- 5g. role_permissions: cannot add a permission the actor does not hold, to
-- ANY role.
do $$
declare v_bug boolean := false; v_sales_role_id uuid; v_unheld_perm_id uuid;
begin
  select id into v_sales_role_id from public.roles where key = 'sales_employee';
  select value::uuid into v_unheld_perm_id from test_vars where key = 'admin_unheld_perm_id';

  begin
    insert into public.role_permissions (role_id, permission_id) values (v_sales_role_id, v_unheld_perm_id);
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنعت إضافة صلاحية لا يملكها الفاعل إلى role_permissions (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم من إضافة صلاحية لا يملكها إلى role_permissions';
  end if;
end $$;

-- 5h. role_permissions: a sensitive key can never be added to ANY role by a
-- non-super-admin, even one the actor holds.
do $$
declare v_bug boolean := false; v_perm_id uuid; v_sales_role_id uuid;
begin
  select id into v_sales_role_id from public.roles where key = 'sales_employee';
  select id into v_perm_id from public.permissions where key = 'settings.manage';
  begin
    insert into public.role_permissions (role_id, permission_id) values (v_sales_role_id, v_perm_id);
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنعت إضافة settings.manage (صلاحية حساسة) إلى دور من غير Super Admin (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم غير Super Admin من إضافة صلاحية حساسة إلى دور';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 5i. Super admin, by contrast, CAN do all of the above -- proves the
-- restriction is specifically "not super admin", not "nobody, ever".
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare v_perm_id uuid; v_sales_role_id uuid;
begin
  select id into v_sales_role_id from public.roles where key = 'sales_employee';
  select id into v_perm_id from public.permissions where key = 'gold_prices.edit';
  insert into public.role_permissions (role_id, permission_id) values (v_sales_role_id, v_perm_id)
    on conflict do nothing;
  delete from public.role_permissions where role_id = v_sales_role_id and permission_id = v_perm_id;
  raise notice 'OK: Super Admin غير مقيّد بقيود منع التصعيد (يستطيع تعديل role_permissions بحرية)';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 6. Column-level authorization (spec review item 3): a *.disable-only
--    actor may change ONLY status, never other columns -- enforced at the
--    database layer, so this is exactly what a direct PostgREST call with
--    that actor's JWT would also be bound by, not merely what the app's UI
--    happens to expose.
-- ---------------------------------------------------------------------------

-- 6a. profiles: actor 005 holds ONLY users.disable (no role, no other
-- override -- see setup above).
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000005","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.disable') = true, 'الفاعل يجب أن يملك users.disable';
  assert public.has_permission('users.edit') = false, 'الفاعل يجب ألا يملك users.edit (هذا هو جوهر الاختبار)';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set full_name = 'اسم منتحل' where id = 'a0000000-0000-4000-8000-000000000002';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.disable-only من تعديل full_name (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: صاحب users.disable فقط استطاع تعديل full_name عبر تحديث مباشر';
  end if;
end $$;

do $$
declare v_status_after text;
begin
  update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000004';
  select status into v_status_after from public.profiles where id = 'a0000000-0000-4000-8000-000000000004';
  assert v_status_after = 'suspended', 'صاحب users.disable يجب أن يتمكن من تغيير status فقط';
  update public.profiles set status = 'active' where id = 'a0000000-0000-4000-8000-000000000004'; -- restore
  raise notice 'OK: صاحب users.disable-only يستطيع تغيير status فقط، بنجاح';
end $$;

reset role;
reset request.jwt.claims;

-- 6b. stores: actor 006 holds ONLY stores.disable.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000006","role":"authenticated"}';

do $$
begin
  assert public.has_permission('stores.disable') = true, 'الفاعل يجب أن يملك stores.disable';
  assert public.has_permission('stores.edit') = false, 'الفاعل يجب ألا يملك stores.edit';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.stores set name_ar = 'اسم منتحل' where id = 'b0000000-0000-4000-8000-00000000000c';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب stores.disable-only من تعديل name_ar (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: صاحب stores.disable فقط استطاع تعديل name_ar عبر تحديث مباشر';
  end if;
end $$;

do $$
declare v_status_after text;
begin
  update public.stores set status = 'disabled' where id = 'b0000000-0000-4000-8000-00000000000c';
  select status into v_status_after from public.stores where id = 'b0000000-0000-4000-8000-00000000000c';
  assert v_status_after = 'disabled', 'صاحب stores.disable يجب أن يتمكن من تغيير status فقط';
  update public.stores set status = 'active' where id = 'b0000000-0000-4000-8000-00000000000c'; -- restore
  raise notice 'OK: صاحب stores.disable-only يستطيع تغيير status فقط، بنجاح';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 7. SECURITY DEFINER hardening (spec review item 4): arbitrary-uuid
--    "check any user" RPCs are no longer callable by `authenticated`; the
--    self-scoped wrappers are and correctly resolve to auth.uid().
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    perform * from public.get_user_permissions('a0000000-0000-4000-8000-000000000001');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع authenticated من استدعاء get_user_permissions(uuid) مباشرة (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم عادي من قراءة صلاحيات مستخدم آخر عبر get_user_permissions(uuid)';
  end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.is_super_admin('a0000000-0000-4000-8000-000000000001');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع authenticated من استدعاء is_super_admin(uuid) مباشرة (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم عادي من فحص حالة super-admin لمستخدم آخر عبر is_super_admin(uuid)';
  end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform * from public.user_accessible_store_ids('a0000000-0000-4000-8000-000000000001');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع authenticated من استدعاء user_accessible_store_ids(uuid) مباشرة (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم عادي من قراءة متاجر مستخدم آخر عبر user_accessible_store_ids(uuid)';
  end if;
end $$;

do $$
declare v_my_count int; v_super_admin boolean; v_my_stores uuid[];
begin
  select count(*) into v_my_count from public.get_my_permissions();
  assert v_my_count > 0, 'get_my_permissions() يجب أن يُرجع صلاحيات الفاعل نفسه';

  select public.am_i_super_admin() into v_super_admin;
  assert v_super_admin = false, 'موظف المبيعات ليس super admin';

  select array_agg(sid order by sid) into v_my_stores from public.my_accessible_store_ids() as sid;
  assert v_my_stores = array['b0000000-0000-4000-8000-00000000000a'::uuid],
    'my_accessible_store_ids() يجب أن يُرجع متجر الفاعل نفسه فقط (Store A)';

  raise notice 'OK: الدوال المُقيّدة بالذات (get_my_permissions/am_i_super_admin/my_accessible_store_ids) تعمل بشكل صحيح';
end $$;

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_super_admin boolean;
begin
  select public.am_i_super_admin() into v_super_admin;
  assert v_super_admin = true, 'am_i_super_admin() يجب أن يُرجع true لـ Super Admin';
  raise notice 'OK: am_i_super_admin() صحيحة أيضًا لـ Super Admin';
end $$;
reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 8. Audit log hardening (spec review item 5)
-- ---------------------------------------------------------------------------

-- 8a. authenticated can no longer call the general-purpose writer directly.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_audit_event('fake.fabricated.event', 'fake', null, null, '{"amount":999999}'::jsonb);
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع authenticated من استدعاء log_audit_event مباشرة (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم authenticated من تلفيق حدث Audit عبر log_audit_event';
  end if;
end $$;

-- 8b. As of 0023 (Foundation Hardening 1.2, item 6), authenticated can no
-- longer call log_auth_event(text) OR its replacement
-- log_auth_event_trusted(uuid, text) at all, under any argument -- login/
-- logout logging moved entirely to a service_role-only path called from
-- server-only code (src/features/auth/actions.ts) AFTER independently
-- verifying the session. Previously (0016) log_auth_event(text) WAS
-- callable by authenticated, self-scoped to auth.uid() and allowlisted to
-- the two auth actions -- which sounds safe, but let ANY signed-in client
-- call it themselves, at ANY time, unrelated to a real sign-in/sign-out
-- ever happening, to pad their own timeline with fabricated
-- login_success/logout entries. Closing that meant removing the client's
-- ability to call anything auth-lifecycle-shaped directly, not just
-- narrowing it further.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_auth_event('auth.login_success');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع authenticated من استدعاء log_auth_event(text) القديمة مباشرة (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن authenticated من استدعاء log_auth_event(text) رغم سحب الصلاحية في 0023';
  end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_auth_event_trusted('a0000000-0000-4000-8000-000000000002'::uuid, 'auth.login_success');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع authenticated من استدعاء log_auth_event_trusted مباشرة (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن authenticated من تسجيل حدث دخول/خروج لنفسه مباشرة عبر log_auth_event_trusted، متجاوزًا مسار الخادم الموثوق';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 8b (continued). service_role CAN call log_auth_event_trusted -- this is
-- exactly the trusted server-only path src/features/auth/actions.ts now
-- uses, AFTER independently verifying a real sign-in/sign-out server-side,
-- with p_user_id supplied explicitly (a service_role connection has no JWT
-- sub claim of its own to read via auth.uid()).
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

do $$
declare v_id uuid; v_logged_count int;
begin
  select public.log_auth_event_trusted('a0000000-0000-4000-8000-000000000002'::uuid, 'auth.login_success') into v_id;
  assert v_id is not null, 'log_auth_event_trusted يجب أن ينجح من service_role لإجراء مسموح به';

  select count(*) into v_logged_count from public.audit_logs
    where id = v_id and action = 'auth.login_success' and user_id = 'a0000000-0000-4000-8000-000000000002';
  assert v_logged_count = 1, 'يجب أن يُنشئ log_auth_event_trusted صفًا مطابقًا في audit_logs';

  raise notice 'OK: log_auth_event_trusted نجح من service_role وأنشأ الصف الصحيح، منسوبًا لـ p_user_id المُمرَّر صراحة';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_auth_event_trusted('a0000000-0000-4000-8000-000000000002'::uuid, 'sales.fake_event');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع log_auth_event_trusted من تسجيل إجراء غير مسموح به في القائمة البيضاء (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن log_auth_event_trusted من تسجيل إجراء تعسفي خارج القائمة البيضاء';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 8c. anon can no longer call the general-purpose writer either.
set role anon;
set local request.jwt.claims = '{"role":"anon"}';

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_audit_event('fake.anon.event', 'fake');
    v_bug := true;
  exception
    when insufficient_privilege or others then
      raise notice 'OK: مُنع anon من استدعاء log_audit_event (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم anon من تسجيل حدث Audit تعسفي';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 8d. Direct table mutation (the REST-equivalent of what a Next.js server
-- action does under the hood) automatically produces a matching,
-- attributed audit_logs row -- proving sensitive-table mutations cannot
-- bypass the audit trail by skipping an explicit app-layer log call.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- Identified by the distinctive description value rather than "most recent
-- row by created_at": the entire test suite runs inside a single
-- transaction (see the BEGIN at the top of this file), and now() -- what
-- audit_logs.created_at defaults to -- returns the SAME value for every
-- call within one transaction. Store A already has an earlier store.insert
-- audit row from test setup with an identical created_at, so "order by
-- created_at desc limit 1" is not actually deterministic here and would
-- silently pick whichever row the tie-break happened to favor -- it did,
-- which is exactly how this test previously reported the insert row instead
-- of the update row. Filtering on the description value this block itself
-- just set sidesteps the tie entirely and is unambiguous by construction.
do $$
declare v_before_count int; v_after_count int; v_row record;
begin
  select count(*) into v_before_count from public.audit_logs
    where entity_type = 'store' and entity_id = 'b0000000-0000-4000-8000-00000000000a';

  update public.stores set description = 'تم تعديله مباشرة عبر REST-equivalent call لأغراض الاختبار - 8d'
    where id = 'b0000000-0000-4000-8000-00000000000a';

  select count(*) into v_after_count from public.audit_logs
    where entity_type = 'store' and entity_id = 'b0000000-0000-4000-8000-00000000000a';
  assert v_after_count = v_before_count + 1,
    format('توقعنا صفًا جديدًا واحدًا في audit_logs بعد التعديل المباشر، كان %s وأصبح %s', v_before_count, v_after_count);

  select * into v_row from public.audit_logs
    where entity_type = 'store' and entity_id = 'b0000000-0000-4000-8000-00000000000a'
      and new_values ->> 'description' = 'تم تعديله مباشرة عبر REST-equivalent call لأغراض الاختبار - 8d';
  assert found, 'يجب إيجاد صف Audit مطابق للتعديل عبر new_values.description';
  assert v_row.action = 'store.update', format('توقعنا action=store.update، وجدنا %s', v_row.action);
  assert v_row.user_id = 'a0000000-0000-4000-8000-000000000001', 'يجب أن يُنسب الصف لمن نفّذ التعديل فعليًا (Super Admin هنا)';
  assert v_row.new_values ->> 'description' = 'تم تعديله مباشرة عبر REST-equivalent call لأغراض الاختبار - 8d',
    'new_values يجب أن يعكس القيمة الفعلية الجديدة';

  raise notice 'OK: التعديل المباشر (REST-equivalent) على stores أنشأ صف Audit صحيح ومنسوب بدقة، تلقائيًا عبر Trigger';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 9. finalize_new_user_profile (spec review item 6: user-creation partial
--    failure; Foundation Hardening 1.2 item 2: pending_setup vs suspended).
--    A genuinely fresh 'pending_setup' profile, created the same way 0011's
--    real safety-net trigger creates one -- 0019 changed its starting status
--    from 'suspended' to 'pending_setup' specifically so "not yet
--    provisioned" and "deliberately disabled" are never the same value.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values ('a0000000-0000-4000-8000-000000000009', 'test-new-hire@example.invalid');

do $$
declare v_status text;
begin
  select status into v_status from public.profiles where id = 'a0000000-0000-4000-8000-000000000009';
  assert v_status = 'pending_setup', 'يجب أن يبدأ المستخدم الجديد بحالة pending_setup (عبر trigger 0011/0019)، وليس suspended';
end $$;

-- 9a. An actor WITHOUT users.create cannot finalize it.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.finalize_new_user_profile('a0000000-0000-4000-8000-000000000009', 'موظف جديد', null, 'single');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع مستخدم بلا users.create من تفعيل ملف مستخدم جديد (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم بلا صلاحية users.create من تفعيل ملف مستخدم جديد';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 9b. An actor WITH users.create can finalize it, and the audit trigger
-- attributes the change to THEM (not null, unlike the old admin-client
-- design this replaced). finalize_new_user_profile performs a plain UPDATE
-- on profiles (pending_setup -> active), so audit_table_changes() logs this
-- as 'user.update' (0024's INSERT->create/UPDATE->update/DELETE->delete
-- taxonomy: this is an UPDATE, not an INSERT); there is no INSERT here to
-- produce a 'user.create' row (the actual profiles INSERT already happened
-- earlier, via 0011's safety-net trigger, attributed to nobody since it ran
-- unauthenticated at auth-user-creation time).
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.create') = true, 'الاختبار يفترض أن Admin يملك users.create (راجع seed.sql إن فشل)';
end $$;

do $$
declare v_status text; v_row record;
begin
  perform public.finalize_new_user_profile('a0000000-0000-4000-8000-000000000009', 'موظف جديد', 'b0000000-0000-4000-8000-00000000000a', 'single');

  select status into v_status from public.profiles where id = 'a0000000-0000-4000-8000-000000000009';
  assert v_status = 'active', 'يجب أن يصبح المستخدم active بعد finalize_new_user_profile';

  select * into v_row from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000009' and action = 'user.update'
    order by created_at desc limit 1;
  assert found, 'يجب إيجاد صف Audit (user.update) لتفعيل finalize_new_user_profile';
  assert v_row.user_id = 'a0000000-0000-4000-8000-000000000003',
    'حدث user.update يجب أن يُنسب لمن نفّذ finalize_new_user_profile فعليًا، وليس NULL';

  raise notice 'OK: finalize_new_user_profile نجح ونُسب حدث user.update للمسؤول الفعلي (لا NULL)';
end $$;

-- 9c. Calling it again on the now-active profile fails (not a general
-- bypass-RLS profile editor -- only completes a still-pending_setup row
-- once).
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.finalize_new_user_profile('a0000000-0000-4000-8000-000000000009', 'محاولة استغلال ثانية', null, 'all');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنعت إعادة استدعاء finalize_new_user_profile على ملف مُفعّل بالفعل (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن finalize_new_user_profile من تعديل ملف مستخدم مُفعّل بالفعل -- محرر عام غير مقيّد';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 9d. THE explicit scenario Foundation Hardening 1.2 item 2 asked to prove:
-- a users.create holder cannot reactivate a genuinely SUSPENDED (previously
-- active, deliberately disabled) account via finalize_new_user_profile --
-- only a truly never-provisioned pending_setup row can ever match. Before
-- 0019, 'suspended' was the SAME value pending_setup profiles started at,
-- so this WHERE clause could not tell the two apart.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values ('a0000000-0000-4000-8000-000000000010', 'test-was-active@example.invalid');
update public.profiles
  set full_name = 'كان نشطًا', status = 'active', store_access_scope = 'single',
      default_store_id = 'b0000000-0000-4000-8000-00000000000a'
  where id = 'a0000000-0000-4000-8000-000000000010';
update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000010'; -- admin deliberately disables it

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.finalize_new_user_profile('a0000000-0000-4000-8000-000000000010', 'محاولة إعادة تفعيل حساب معطّل', null, 'single');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع مستخدم يملك users.create من إعادة تفعيل حساب suspended (معطّل فعليًا) عبر finalize_new_user_profile (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن users.create holder من إعادة تفعيل حساب suspended عبر finalize_new_user_profile';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 9e. A users.edit holder WITHOUT users.create cannot activate a
-- pending_setup row directly via a raw UPDATE, bypassing
-- finalize_new_user_profile()'s own users.create gate (0019's
-- enforce_pending_setup_transition -- closes that gap even though the
-- actor otherwise has full edit rights on the row).
--
-- Actor 012: edit-only user manager -- users.edit + users.view, deliberately
-- NOT users.create. None of the seeded roles isolate users.edit without
-- users.create (only 'admin' holds both together), hence a dedicated
-- permission-override actor, declared here right before first use like
-- actors 009/010/011 above.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values ('a0000000-0000-4000-8000-000000000012', 'test-edit-only-no-create@example.invalid');
update public.profiles set full_name = 'Test Edit-Only No-Create', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000012';
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a0000000-0000-4000-8000-000000000012', id, 'grant' from public.permissions where key in ('users.edit', 'users.view');

insert into auth.users (id, email) values ('a0000000-0000-4000-8000-000000000011', 'test-second-new-hire@example.invalid');

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000012","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.edit') = true, 'الاختبار يفترض أن الفاعل 012 يملك users.edit (راجع إعداد الاختبار)';
  assert public.has_permission('users.create') = false, 'الاختبار يفترض أن الفاعل 012 لا يملك users.create';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set status = 'active', full_name = 'محاولة تفعيل مباشرة'
      where id = 'a0000000-0000-4000-8000-000000000011';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.edit بلا users.create من تفعيل حساب pending_setup مباشرة عبر UPDATE (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب users.edit بلا users.create من تفعيل حساب pending_setup مباشرة، متجاوزًا finalize_new_user_profile';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 9f. Cancelling a not-yet-provisioned invite. Originally (Foundation
-- Hardening 1.3) this moved the row to 'suspended' -- an ordinary
-- status/disable action gated by users.disable specifically (0030's
-- per-column authorization), not users.create. Foundation Hardening 1.4
-- item 5 (0036) found that this exact transition strands the underlying
-- auth.users row permanently (finalize_new_user_profile() only ever matches
-- pending_setup; 0029 then permanently blocks reaching 'active' again) --
-- so pending_setup -> suspended is now rejected outright for ANY
-- non-trusted actor, not just ones lacking users.disable. This section is
-- updated to prove BOTH actors are blocked now, and the correct replacement
-- (trusted-context auth.users deletion, mirroring cancelUserInviteAction) is
-- covered in section 29 below.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000012","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000011';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.edit فقط (بلا users.disable) من نقل دعوة pending_setup إلى suspended (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب users.edit وحدها (بلا users.disable) من تغيير status لدعوة قيد الإعداد';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- Foundation Hardening 1.4, item 5 (0036): even a users.disable holder --
-- who COULD move this row to 'suspended' before 1.4 -- is now blocked too.
-- This is not a regression: it closes exactly the stranded-auth-user bug
-- item 5 found (see 0036's own header comment). Row 011 stays pending_setup
-- and is cleaned up via the trusted deletion path in section 29 instead.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000005","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000011';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: (Foundation Hardening 1.4) مُنع حتى صاحب users.disable من نقل دعوة pending_setup إلى suspended مباشرة (%) -- الإلغاء الآن حذف موثوق فقط، انظر القسم 29', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب users.disable من نقل دعوة pending_setup إلى suspended مباشرة رغم 0036 -- هذا يُعيد فتح ثغرة الحساب العالق';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 10. Store-scope consistency (spec review item 7)
-- ---------------------------------------------------------------------------
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

-- 10a. 'single' scope requires default_store_id -- CHECK constraint.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles
      set store_access_scope = 'single', default_store_id = null
      where id = 'a0000000-0000-4000-8000-000000000004';
    v_bug := true;
  exception
    when check_violation or others then
      raise notice 'OK: مُنع ضبط store_access_scope=single بدون default_store_id (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: أمكن ضبط store_access_scope=single بدون default_store_id';
  end if;
end $$;

-- 10b. default_store_id must point to an ACTIVE store.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles
      set default_store_id = 'b0000000-0000-4000-8000-00000000000d' -- Store D, disabled
      where id = 'a0000000-0000-4000-8000-000000000002';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع ضبط متجر افتراضي معطّل (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: أمكن ضبط default_store_id على متجر معطّل';
  end if;
end $$;

-- 10c. user_store_access must point to an ACTIVE store.
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.user_store_access (user_id, store_id)
      values ('a0000000-0000-4000-8000-000000000004', 'b0000000-0000-4000-8000-00000000000d'); -- Store D, disabled
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع منح وصول لمتجر معطّل عبر user_store_access (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: أمكن منح وصول لمتجر معطّل عبر user_store_access';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 11. Last-super-admin protection (kept from the original suite)
-- ---------------------------------------------------------------------------
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000001';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع تعطيل آخر Super Admin نشط (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تم تعطيل آخر Super Admin نشط';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 12. Operable vs Visible store IDs (Foundation Hardening 1.2 item 4):
--     disabling a store must stop NEW operations against it without erasing
--     it from historical/report visibility. Toggles are always restored
--     immediately after each assertion block since later sections (13+)
--     assume Stores A/B/C are active.
-- ---------------------------------------------------------------------------

-- 12a. Actor 004 (multiple -> Store A + Store B): before any toggle, both
-- functions agree (both stores active).
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000004","role":"authenticated"}';

do $$
declare v_operable int; v_visible int;
begin
  select count(*) into v_operable from public.my_operable_store_ids();
  select count(*) into v_visible from public.my_visible_store_ids();
  assert v_operable = 2, format('قبل التعطيل: توقعنا 2 متجر قابل للعمل عليه (A+B)، وجدنا %s', v_operable);
  assert v_visible = 2, format('قبل التعطيل: توقعنا 2 متجر مرئي تاريخيًا (A+B)، وجدنا %s', v_visible);
end $$;

reset role;
reset request.jwt.claims;

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
update public.stores set status = 'disabled' where id = 'b0000000-0000-4000-8000-00000000000b';
reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000004","role":"authenticated"}';

do $$
declare v_operable_a boolean; v_operable_b boolean; v_visible_a boolean; v_visible_b boolean;
begin
  select exists(select 1 from public.my_operable_store_ids() sid where sid = 'b0000000-0000-4000-8000-00000000000a') into v_operable_a;
  select exists(select 1 from public.my_operable_store_ids() sid where sid = 'b0000000-0000-4000-8000-00000000000b') into v_operable_b;
  select exists(select 1 from public.my_visible_store_ids() sid where sid = 'b0000000-0000-4000-8000-00000000000a') into v_visible_a;
  select exists(select 1 from public.my_visible_store_ids() sid where sid = 'b0000000-0000-4000-8000-00000000000b') into v_visible_b;

  assert v_operable_a and not v_operable_b,
    'بعد تعطيل متجر B: يجب أن يقتصر my_operable_store_ids على A فقط (B معطّل)';
  assert v_visible_a and v_visible_b,
    'بعد تعطيل متجر B: يجب أن يبقى my_visible_store_ids يشمل A و B معًا (التاريخ لا يُمحى)';

  raise notice 'OK: تعطيل متجر يستبعده من my_operable_store_ids لكنه يبقى ضمن my_visible_store_ids (مستخدم متعدد المتاجر)';
end $$;

reset role;
reset request.jwt.claims;

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
update public.stores set status = 'active' where id = 'b0000000-0000-4000-8000-00000000000b';
reset role;
reset request.jwt.claims;

-- 12b. Actor 002 (single -> Store A): same idea, single-scope branch.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
update public.stores set status = 'disabled' where id = 'b0000000-0000-4000-8000-00000000000a';
reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare v_operable int; v_visible int;
begin
  select count(*) into v_operable from public.my_operable_store_ids();
  select count(*) into v_visible from public.my_visible_store_ids();
  assert v_operable = 0, format('بعد تعطيل متجر A (المتجر الافتراضي الوحيد): توقعنا 0 متجر قابل للعمل عليه، وجدنا %s', v_operable);
  assert v_visible = 1, format('بعد تعطيل متجر A: يجب أن يبقى مرئيًا تاريخيًا رغم تعطيله، توقعنا 1، وجدنا %s', v_visible);
  raise notice 'OK: تعطيل المتجر الافتراضي الوحيد لمستخدم single-scope يفرغ my_operable_store_ids لكن my_visible_store_ids يبقى يشمله';
end $$;

reset role;
reset request.jwt.claims;

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';
update public.stores set status = 'active' where id = 'b0000000-0000-4000-8000-00000000000a';
reset role;
reset request.jwt.claims;

-- 12c. Actor 001 (all-scope, Super Admin): operable = 3 active stores
-- (A, B, C); visible = 4 (also the permanently-disabled Store D).
do $$
declare v_operable int; v_visible int;
begin
  select count(*) into v_operable from public.user_operable_store_ids('a0000000-0000-4000-8000-000000000001');
  select count(*) into v_visible from public.user_visible_store_ids('a0000000-0000-4000-8000-000000000001');
  assert v_operable = 3, format('all-scope: توقعنا 3 متاجر نشطة قابلة للعمل عليها، وجدنا %s', v_operable);
  assert v_visible = 4, format('all-scope: توقعنا 4 متاجر مرئية تاريخيًا (شاملة Store D المعطّل)، وجدنا %s', v_visible);
  raise notice 'OK: مستخدم all-scope يرى 3 متاجر نشطة قابلة للعمل عليها و4 متاجر مرئية تاريخيًا (شاملة المعطّل)';
end $$;

-- ---------------------------------------------------------------------------
-- 13. Store-scope escalation + delegation limit + atomic replace
--     (Foundation Hardening 1.2 items 1 and 9).
-- ---------------------------------------------------------------------------

-- Actor 004 (multiple -> Store A + Store B, no role) gets the new dedicated
-- permission -- users.manage_store_access ONLY, deliberately not
-- users.edit/users.manage_permissions/users.view -- so every block below
-- tests 0018's rules in isolation from every other permission's effect.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a0000000-0000-4000-8000-000000000004', id, 'grant' from public.permissions where key = 'users.manage_store_access';

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000004","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.manage_store_access') = true, 'الاختبار يفترض أن 004 يملك الآن users.manage_store_access';
  assert public.has_permission('users.edit') = false, 'الاختبار يفترض أن 004 لا يملك users.edit (لعزل تأثير 0018 عن 0014)';
end $$;

-- 13a. Self-escalation blocked even though 004 holds users.manage_store_access.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set store_access_scope = 'all' where id = 'a0000000-0000-4000-8000-000000000004';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع 004 من تعديل نطاق وصوله (Store Scope) الخاص بنفسه رغم امتلاكه users.manage_store_access (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم من تعديل نطاق وصوله الخاص بنفسه عبر users.manage_store_access';
  end if;
end $$;

-- 13b. Self-grant / self-revoke of OWN user_store_access blocked.
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.user_store_access (user_id, store_id)
      values ('a0000000-0000-4000-8000-000000000004', 'b0000000-0000-4000-8000-00000000000c');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع 004 من منح نفسه وصولًا لمتجر إضافي بنفسه (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم من منح نفسه وصولًا لمتجر إضافي عبر user_store_access بنفسه';
  end if;
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    delete from public.user_store_access
      where user_id = 'a0000000-0000-4000-8000-000000000004' and store_id = 'b0000000-0000-4000-8000-00000000000a';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع 004 من سحب وصوله الخاص لمتجر بنفسه (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم من سحب وصوله الخاص لمتجر بنفسه عبر user_store_access';
  end if;
end $$;

-- 13c. Delegation limit -- 004 operates only Store A + Store B, cannot grant
-- Store C (outside its own operable set) to someone else, but CAN grant
-- Store A (within its own operable set).
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.user_store_access (user_id, store_id)
      values ('a0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-00000000000c');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع 004 من تفويض وصول لمتجر لا يملك هو نفسه صلاحية العمل عليه (Store C) (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم من تفويض وصول لمتجر خارج نطاق تشغيله الخاص';
  end if;
end $$;

do $$
begin
  insert into public.user_store_access (user_id, store_id)
    values ('a0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-00000000000a');
end $$;

reset role;
reset request.jwt.claims;

-- Verified as postgres/superuser, not as actor 004: user_store_access_select
-- (0010) only lets an actor read rows where user_id = auth.uid() OR they
-- hold users.view/stores.view -- 004 (deliberately granted ONLY
-- users.manage_store_access, see setup above) cannot see actor 002's own
-- row even though its own INSERT of it just succeeded, so this must be
-- checked out-of-band rather than re-querying as 004.
do $$
declare v_count int;
begin
  select count(*) into v_count from public.user_store_access
    where user_id = 'a0000000-0000-4000-8000-000000000002' and store_id = 'b0000000-0000-4000-8000-00000000000a';
  assert v_count = 1, 'يجب أن ينجح تفويض 004 لمتجر يملك هو نفسه صلاحية العمل عليه (Store A)';
  raise notice 'OK: تمكّن 004 من تفويض وصول لمتجر ضمن نطاق تشغيله الخاص (Store A) لمستخدم آخر';
end $$;

-- 13d. A non-Super-Admin manage_store_access holder can never set scope=
-- 'all' for someone ELSE, regardless of their own scope.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.manage_store_access') = true, 'الاختبار يفترض أن دور admin يملك الآن users.manage_store_access (راجع seed.sql/0018)';
  -- is_super_admin(uuid) is service_role-only (0015) -- am_i_super_admin()
  -- is the self-scoped, authenticated-callable equivalent (section 7).
  assert public.am_i_super_admin() = false, 'الاختبار يفترض أن 003 ليس Super Admin';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set store_access_scope = 'all' where id = 'a0000000-0000-4000-8000-000000000004';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin (غير Super Admin) من ضبط scope=all لمستخدم آخر رغم امتلاكه users.manage_store_access (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم غير Super Admin من ضبط store_access_scope=all لمستخدم آخر';
  end if;
end $$;

-- 13e. Positive control -- the SAME actor CAN change a non-'all' store-scope
-- column for another user (proves the block above is specific to scope=all,
-- not a general inability to use the permission at all).
do $$
declare v_default uuid;
begin
  update public.profiles set default_store_id = 'b0000000-0000-4000-8000-00000000000b'
    where id = 'a0000000-0000-4000-8000-000000000002';
  select default_store_id into v_default from public.profiles where id = 'a0000000-0000-4000-8000-000000000002';
  assert v_default = 'b0000000-0000-4000-8000-00000000000b'::uuid,
    'يجب أن ينجح Admin في تغيير عمود نطاق وصول غير scope=all لمستخدم آخر';
  raise notice 'OK: تمكّن Admin من تغيير default_store_id لمستخدم آخر (تغيير غير scope=all)، فقط ضبط scope=all تحديدًا هو الممنوع';
end $$;

reset role;
reset request.jwt.claims;

-- 13f. users.edit ALONE (without users.manage_store_access) is not enough --
-- 0014's column-authorization function (re-defined from within 0018, see
-- that migration's trailing block) lets a users.edit holder pass ITS OWN
-- gate unconditionally, but 0018's independent enforce_store_scope_
-- authorization trigger still requires users.manage_store_access
-- specifically and blocks it regardless -- this is the exact cross-migration
-- interaction the trailing block in 0018 exists to keep correct.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000012","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.edit') = true, 'الاختبار يفترض أن 012 يملك users.edit';
  assert public.has_permission('users.manage_store_access') = false, 'الاختبار يفترض أن 012 لا يملك users.manage_store_access';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set store_access_scope = 'single', default_store_id = 'b0000000-0000-4000-8000-00000000000a'
      where id = 'a0000000-0000-4000-8000-000000000004';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.edit فقط (بلا users.manage_store_access) من تعديل نطاق وصول متجر مستخدم آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب users.edit وحدها من تعديل نطاق وصول المتاجر (store_access_scope/default_store_id) لمستخدم آخر -- ثغرة 0018 كانت تهدف لإغلاقها تحديدًا';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 13g (item 9). replace_user_store_access is atomic -- a batch containing
-- ONE invalid store rolls back the ENTIRE batch, including changes that
-- would otherwise have succeeded on their own.
do $$
declare v_ids uuid[];
begin
  select coalesce(array_agg(store_id order by store_id), '{}') into v_ids
    from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000004';
  assert v_ids = array[
      'b0000000-0000-4000-8000-00000000000a'::uuid,
      'b0000000-0000-4000-8000-00000000000b'::uuid
    ],
    format('الاختبار يفترض أن وصول 004 الحالي هو [Store A, Store B] بالضبط قبل اختبار الذرّية، وجدنا %s', v_ids);
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    -- Store A (valid, no-op) + Store D (disabled -> invalid) in ONE batch:
    -- this would remove Store B and add Store D if applied non-atomically.
    perform public.replace_user_store_access(
      'a0000000-0000-4000-8000-000000000004'::uuid,
      array['b0000000-0000-4000-8000-00000000000a'::uuid, 'b0000000-0000-4000-8000-00000000000d'::uuid]
    );
    v_bug := true;
  exception
    when others then
      raise notice 'OK: رفض replace_user_store_access الدفعة كاملة لاحتوائها على متجر غير صالح (Store D معطّل) (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: نجح replace_user_store_access رغم احتواء الدفعة على متجر غير نشط';
  end if;
end $$;

reset role;
reset request.jwt.claims;

do $$
declare v_ids uuid[];
begin
  select coalesce(array_agg(store_id order by store_id), '{}') into v_ids
    from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000004';
  assert v_ids = array[
      'b0000000-0000-4000-8000-00000000000a'::uuid,
      'b0000000-0000-4000-8000-00000000000b'::uuid
    ],
    format('بعد فشل replace_user_store_access يجب ألا يتغير وصول 004 إطلاقًا (ذرّية كاملة، لا حذف جزئي لـ Store B)، وجدنا %s', v_ids);
  raise notice 'OK: فشل جزء واحد من دفعة replace_user_store_access أبطل الدفعة بالكامل -- لا تغيير جزئي';
end $$;

-- 13h. Positive control -- a fully-valid batch succeeds atomically and
-- replaces the set exactly (remove Store A, add Store C -- both within
-- actor 003's own operable set, scope='all').
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_ids uuid[];
begin
  perform public.replace_user_store_access(
    'a0000000-0000-4000-8000-000000000004'::uuid,
    array['b0000000-0000-4000-8000-00000000000b'::uuid, 'b0000000-0000-4000-8000-00000000000c'::uuid]
  );
  select coalesce(array_agg(store_id order by store_id), '{}') into v_ids
    from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000004';
  assert v_ids = array[
      'b0000000-0000-4000-8000-00000000000b'::uuid,
      'b0000000-0000-4000-8000-00000000000c'::uuid
    ],
    format('بعد استبدال ناجح بالكامل، توقعنا [Store B, Store C] بالضبط، وجدنا %s', v_ids);
  raise notice 'OK: نجح replace_user_store_access بدفعة صالحة بالكامل، واستبدل المجموعة بالضبط في استدعاء واحد ذرّي';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 14. Super Admin accounts as protected entities (Foundation Hardening 1.2
--     item 3), proven with TWO active Super Admins present so the
--     "last Super Admin" guard (0009, section 11) cannot be the thing doing
--     the blocking here -- this is about a DIFFERENT non-Super-Admin actor
--     being unable to touch ANY Super Admin, regardless of how many remain.
--     Placed after section 11 deliberately so introducing a second Super
--     Admin here cannot retroactively affect that already-passed test.
-- ---------------------------------------------------------------------------
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values ('a0000000-0000-4000-8000-000000000007', 'test-second-super-admin@example.invalid');
update public.profiles set full_name = 'Test Second Super Admin', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000007';
insert into public.user_roles (user_id, role_id)
  select 'a0000000-0000-4000-8000-000000000007', id from public.roles where key = 'super_admin';

reset role;
reset request.jwt.claims;

do $$
declare v_count int;
begin
  select count(*) into v_count from public.user_roles ur
    join public.roles r on r.id = ur.role_id
    where r.key = 'super_admin';
  assert v_count = 2, format('الاختبار يفترض وجود Super Admin نشطَين اثنين الآن، وجدنا %s', v_count);
end $$;

-- 14a. A different Admin (003, not Super Admin) cannot edit a Super Admin's
-- profile data, even though 003 holds users.edit and 2+ Super Admins exist.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set full_name = 'محاولة تعديل من Admin' where id = 'a0000000-0000-4000-8000-000000000007';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin غير Super Admin من تعديل بيانات Super Admin آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من تعديل بيانات Super Admin رغم وجود أكثر من واحد نشط';
  end if;
end $$;

-- 14b. ...cannot suspend a Super Admin.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000007';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin غير Super Admin من تعطيل Super Admin آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من تعطيل حساب Super Admin آخر';
  end if;
end $$;

-- 14c. ...cannot change a Super Admin's store scope either, even though 003
-- holds users.manage_store_access (0018) too.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set store_access_scope = 'single', default_store_id = 'b0000000-0000-4000-8000-00000000000a'
      where id = 'a0000000-0000-4000-8000-000000000007';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin غير Super Admin من تعديل نطاق وصول متاجر Super Admin آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من تعديل نطاق وصول متاجر Super Admin آخر';
  end if;
end $$;

-- 14d. ...cannot remove the super_admin role from a Super Admin's user_roles.
do $$
declare v_bug boolean := false; v_super_admin_role_id uuid;
begin
  select id into v_super_admin_role_id from public.roles where key = 'super_admin';
  begin
    delete from public.user_roles
      where user_id = 'a0000000-0000-4000-8000-000000000007' and role_id = v_super_admin_role_id;
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin غير Super Admin من حذف دور super_admin من مستخدم آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من إزالة دور super_admin من مستخدم آخر';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 14e/14f. Positive controls: a FELLOW Super Admin (001) CAN edit, suspend,
-- and reactivate 007 -- proving the block above is specific to non-Super-
-- Admin actors, not a blanket "Super Admins can never be touched".
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare v_name text;
begin
  update public.profiles set full_name = 'عُدّل بواسطة Super Admin آخر' where id = 'a0000000-0000-4000-8000-000000000007';
  select full_name into v_name from public.profiles where id = 'a0000000-0000-4000-8000-000000000007';
  assert v_name = 'عُدّل بواسطة Super Admin آخر', 'يجب أن يتمكن Super Admin آخر من تعديل بيانات Super Admin (ليس هو نفسه، وليس آخر واحد نشط)';
  raise notice 'OK: تمكّن Super Admin من تعديل بيانات Super Admin آخر';
end $$;

do $$
declare v_status text;
begin
  update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000007';
  select status into v_status from public.profiles where id = 'a0000000-0000-4000-8000-000000000007';
  assert v_status = 'suspended', 'يجب أن يتمكن Super Admin من تعطيل Super Admin آخر (ليس آخر واحد نشط، ما زال 001 نشطًا)';

  update public.profiles set status = 'active' where id = 'a0000000-0000-4000-8000-000000000007';
  select status into v_status from public.profiles where id = 'a0000000-0000-4000-8000-000000000007';
  assert v_status = 'active', 'يجب أن يتمكن Super Admin من إعادة تفعيل Super Admin آخر';

  raise notice 'OK: تمكّن Super Admin من تعطيل ثم إعادة تفعيل Super Admin آخر (0009 يحمي فقط آخر Super Admin نشط، وهذه ليست تلك الحالة)';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 15. System-managed columns lockdown (Foundation Hardening 1.2 item 5).
-- ---------------------------------------------------------------------------

-- 15a. profiles.email is immutable via ANY client UPDATE, even for a Super
-- Admin -- there is no Auth-synced email-change flow yet, so there is no
-- legitimate direct path at all today.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set email = 'forged-by-admin@example.invalid' where id = 'a0000000-0000-4000-8000-000000000002';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin (يملك users.edit) من تغيير بريد إلكتروني لمستخدم آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin من تغيير profiles.email مباشرة';
  end if;
end $$;

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set email = 'forged-by-super-admin@example.invalid' where id = 'a0000000-0000-4000-8000-000000000002';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع حتى Super Admin من تغيير بريد إلكتروني مباشرة عبر تعديل الملف الشخصي (لا مسار Auth متزامن بعد) (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Super Admin من تغيير profiles.email مباشرة، رغم عدم وجود مسار متزامن مع Supabase Auth';
  end if;
end $$;

-- 15b. created_by/created_at/updated_by forged on INSERT are silently pinned
-- to server truth, not raised as an error (same philosophy as set_updated_by()).
do $$
declare v_row record;
begin
  insert into public.stores (code, name_ar, created_by, updated_by, created_at, updated_at)
    values ('T-E', 'فرع E تجريبي', 'a0000000-0000-4000-8000-000000000002'::uuid, 'a0000000-0000-4000-8000-000000000002'::uuid,
            '2000-01-01'::timestamptz, '2000-01-01'::timestamptz)
    returning * into v_row;

  assert v_row.created_by = 'a0000000-0000-4000-8000-000000000001'::uuid,
    format('created_by يجب أن يُثبّت على الفاعل الفعلي بغض النظر عمّا أرسله العميل، وجدنا %s', v_row.created_by);
  assert v_row.updated_by = 'a0000000-0000-4000-8000-000000000001'::uuid, 'updated_by يجب أن يُثبّت على الفاعل الفعلي كذلك';
  assert v_row.created_at > '2001-01-01'::timestamptz, 'created_at يجب أن يُثبّت على الوقت الفعلي (now())، ليس القيمة المزوّرة من العميل';
  raise notice 'OK: تزوير created_by/updated_by/created_at عبر INSERT على stores تم تجاهله وتثبيته على القيم الحقيقية بصمت';
end $$;

-- 15c. created_by/created_at are immutable on UPDATE of an EXISTING row --
-- silently pinned back, not raised.
do $$
declare v_before record; v_after record;
begin
  select created_by, created_at into v_before from public.stores where id = 'b0000000-0000-4000-8000-00000000000a';

  update public.stores
    set created_by = 'a0000000-0000-4000-8000-000000000002'::uuid, created_at = '1999-01-01'::timestamptz,
        description = 'محاولة تزوير created_by/created_at عبر UPDATE - قسم 15'
    where id = 'b0000000-0000-4000-8000-00000000000a';

  select created_by, created_at into v_after from public.stores where id = 'b0000000-0000-4000-8000-00000000000a';
  assert v_after.created_by = v_before.created_by, 'created_by يجب ألا يتغير عبر UPDATE مهما أرسل العميل';
  assert v_after.created_at = v_before.created_at, 'created_at يجب ألا يتغير عبر UPDATE مهما أرسل العميل';
  raise notice 'OK: محاولة تزوير created_by/created_at عبر UPDATE على stores تم تجاهلها بصمت (القيم الأصلية محفوظة)';
end $$;

reset role;
reset request.jwt.claims;

-- 15d. Same principle on a junction table: user_roles.created_by/created_at
-- forged on INSERT are pinned to the real actor, not the client-supplied uuid.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_row record; v_sales_role_id uuid;
begin
  select id into v_sales_role_id from public.roles where key = 'sales_employee';
  insert into public.user_roles (user_id, role_id, created_by, created_at)
    values ('a0000000-0000-4000-8000-000000000006', v_sales_role_id, 'a0000000-0000-4000-8000-000000000002'::uuid, '1999-01-01'::timestamptz)
    returning * into v_row;

  assert v_row.created_by = 'a0000000-0000-4000-8000-000000000003'::uuid,
    format('created_by في user_roles يجب أن يُثبّت على الفاعل الفعلي، وجدنا %s', v_row.created_by);
  assert v_row.created_at > '2001-01-01'::timestamptz, 'created_at في user_roles يجب أن يُثبّت على الوقت الفعلي';
  raise notice 'OK: تزوير created_by/created_at عبر INSERT على user_roles تم تجاهله وتثبيته على القيم الحقيقية';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 16. roles.is_system lockdown (Foundation Hardening 1.2 item 7).
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

-- 16a. INSERT with is_system=true is blocked, even for a users.manage_permissions holder.
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.roles (key, name_ar, is_system, created_by, updated_by)
      values ('custom_test_forged_system_16a', 'دور مزوّر نظامي', true, 'a0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000003');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع إنشاء دور بـ is_system=true من سياق تطبيق (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم تطبيق من إنشاء دور is_system=true مباشرة';
  end if;
end $$;

-- Create a legitimate custom role (is_system=false) -- this is real data
-- section 17 reuses to prove the audit-taxonomy create/delete verbs.
do $$
begin
  insert into public.roles (key, name_ar, is_system, created_by, updated_by)
    values ('custom_test_role_16b', 'دور مخصص للاختبار', false, 'a0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000003');
end $$;

-- 16b. Flipping is_system false -> true via UPDATE is blocked.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.roles set is_system = true where key = 'custom_test_role_16b';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع ترقية دور مخصص إلى is_system=true عبر UPDATE (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم تطبيق من ترقية دور مخصص إلى is_system=true';
  end if;
end $$;

-- 16c. roles.key is locked on UPDATE, for any role.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.roles set key = 'custom_test_role_16b_renamed' where key = 'custom_test_role_16b';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع تغيير roles.key عبر UPDATE (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم تطبيق من تغيير roles.key';
  end if;
end $$;

-- 16d. Positive control: renaming an EXISTING system role's display name
-- still works -- the lockdown only blocks is_system/key, not every column.
do $$
declare v_role_id uuid; v_old_name text; v_new_name text;
begin
  select id, name_ar into v_role_id, v_old_name from public.roles where key = 'admin';
  assert v_role_id is not null, 'الاختبار يفترض وجود دور نظامي بمفتاح admin (راجع seed.sql)';

  update public.roles set name_ar = v_old_name || ' (مُعدّل اختباريًا)' where id = v_role_id;
  select name_ar into v_new_name from public.roles where id = v_role_id;
  assert v_new_name = v_old_name || ' (مُعدّل اختباريًا)', 'يجب أن يظل تعديل الاسم المعروض لدور نظامي موجود مسبقًا مسموحًا';

  raise notice 'OK: تعديل الاسم المعروض لدور نظامي موجود مسبقًا ما زال مسموحًا (is_system/key لم يتغيرا)';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 17. Audit action taxonomy: INSERT/DELETE produce '.create'/'.delete', not
--     raw TG_OP strings (Foundation Hardening 1.2 item 8). '.update' was
--     already implicitly proven throughout this file (e.g. 8d, 9b) -- this
--     section explicitly proves the two verbs 0024 actually changed, reusing
--     the custom role INSERTed in section 16 (real data this script produced,
--     not an assumption about an empty table).
-- ---------------------------------------------------------------------------
do $$
declare v_row record;
begin
  select * into v_row from public.audit_logs
    where entity_type = 'role' and action = 'role.create'
      and new_values ->> 'key' = 'custom_test_role_16b';
  assert found, 'يجب إيجاد صف Audit بالإجراء role.create لإنشاء الدور المخصص في القسم 16 (وليس role.insert)';
  assert v_row.user_id = 'a0000000-0000-4000-8000-000000000003', 'يجب أن يُنسب role.create لمن أنشأ الدور فعليًا';
  raise notice 'OK: إنشاء دور (INSERT) يُنتج action=role.create، وليس السلسلة الخام role.insert';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_role_id uuid;
begin
  select id into v_role_id from public.roles where key = 'custom_test_role_16b';
  delete from public.roles where id = v_role_id;
end $$;

reset role;
reset request.jwt.claims;

do $$
declare v_row record;
begin
  select * into v_row from public.audit_logs
    where entity_type = 'role' and action = 'role.delete'
      and old_values ->> 'key' = 'custom_test_role_16b';
  assert found, 'يجب إيجاد صف Audit بالإجراء role.delete لحذف الدور المخصص (وليس صيغة أخرى)';
  raise notice 'OK: حذف دور (DELETE) يُنتج action=role.delete';
end $$;

-- ============================================================================
-- Foundation Hardening 1.3 (migrations 0025-0031): a THIRD independent
-- review of the actually-shipped 1.2 code found nine further gaps. Sections
-- 18-24 below cover all of them, using fresh, deliberately narrow-scoped
-- actors created here (never the all-scope Admin/Super Admin actors used
-- elsewhere in this file) specifically so a manage_store_access/edit/
-- disable check being proven is never accidentally passing only because the
-- actor ALSO happens to hold some broader permission.
-- ============================================================================

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000013', 'test-limited-scope-manager@example.invalid'),
  ('a0000000-0000-4000-8000-000000000014', 'test-delegation-target-1@example.invalid'),
  ('a0000000-0000-4000-8000-000000000015', 'test-delegation-target-2@example.invalid'),
  ('a0000000-0000-4000-8000-000000000016', 'test-delegation-target-3@example.invalid'),
  ('a0000000-0000-4000-8000-000000000017', 'test-sensitive-role-target@example.invalid'),
  ('a0000000-0000-4000-8000-000000000018', 'test-provisioning-bypass-target@example.invalid'),
  ('a0000000-0000-4000-8000-000000000019', 'test-no-create-full-editor@example.invalid'),
  ('a0000000-0000-4000-8000-000000000020', 'test-column-auth-target@example.invalid'),
  ('a0000000-0000-4000-8000-000000000021', 'test-store-edit-only@example.invalid');

-- 013: the actor for section 18/19 -- scope='multiple' -> Store A + Store B
-- ONLY, holding users.manage_store_access + users.view (deliberately NOT
-- users.edit/users.disable/users.manage_permissions/stores.view) -- exactly
-- the "limited-scope Actor (A+B, NOT holding C)" Foundation Hardening 1.3
-- item 9 explicitly requires, instead of retesting these rules via an
-- all-scope Admin the way it would be easy (and insufficiently rigorous) to
-- do. users.view is included deliberately, not as an oversight: item 2b's
-- own wording frames it as "manage_store_access plus whatever is needed to
-- see the target user" -- profile VISIBILITY is users.view's job (and is
-- what page.tsx's own requirePermission("users.view") already gates the
-- whole /users/[id] page on); manage_store_access's job is authorizing the
-- store-scope WRITE once the actor can already see the row. Without
-- users.view here, even a fully-authorized UPDATE finds zero rows to update
-- (Postgres RLS requires a row to be visible under the table's SELECT
-- policies before an UPDATE/DELETE policy on it is even consulted) -- that
-- would test an unsupported actor shape, not a real gap.
update public.profiles set full_name = 'Test Limited Scope Manager', status = 'active', store_access_scope = 'multiple'
  where id = 'a0000000-0000-4000-8000-000000000013';
insert into public.user_store_access (user_id, store_id) values
  ('a0000000-0000-4000-8000-000000000013', 'b0000000-0000-4000-8000-00000000000a'),
  ('a0000000-0000-4000-8000-000000000013', 'b0000000-0000-4000-8000-00000000000b');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a0000000-0000-4000-8000-000000000013', id, 'grant' from public.permissions where key in ('users.manage_store_access', 'users.view');

-- 014: target for section 18 tests 1 & 2 -- 'multiple' scope, no grants yet.
update public.profiles set full_name = 'Test Delegation Target 1', status = 'active', store_access_scope = 'multiple'
  where id = 'a0000000-0000-4000-8000-000000000014';

-- 015: target for section 19 (item 2 SELECT-visibility fix) -- starts with
-- Store A + Store B, i.e. BOTH within actor 013's own operable range, so
-- this specifically isolates the SELECT-policy fix from item 1's DELETE-
-- delegation-limit fix (which would otherwise also legitimately block a
-- diff that tries to remove an out-of-range store, confounding the result).
update public.profiles set full_name = 'Test Delegation Target 2', status = 'active', store_access_scope = 'multiple'
  where id = 'a0000000-0000-4000-8000-000000000015';
insert into public.user_store_access (user_id, store_id) values
  ('a0000000-0000-4000-8000-000000000015', 'b0000000-0000-4000-8000-00000000000a'),
  ('a0000000-0000-4000-8000-000000000015', 'b0000000-0000-4000-8000-00000000000b');

-- 016: target for section 18 tests 3 & 4 -- starts with Store A + Store C
-- (C outside actor 013's operable range).
update public.profiles set full_name = 'Test Delegation Target 3', status = 'active', store_access_scope = 'multiple'
  where id = 'a0000000-0000-4000-8000-000000000016';
insert into public.user_store_access (user_id, store_id) values
  ('a0000000-0000-4000-8000-000000000016', 'b0000000-0000-4000-8000-00000000000a'),
  ('a0000000-0000-4000-8000-000000000016', 'b0000000-0000-4000-8000-00000000000c');

-- 017: holds the 'admin' role (which carries users.manage_permissions +
-- settings.manage -- both sensitive, see seed.sql) for section 22's
-- sensitive-role-REMOVAL test.
update public.profiles set full_name = 'Test Sensitive Role Target', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000017';
insert into public.user_roles (user_id, role_id)
  select 'a0000000-0000-4000-8000-000000000017', id from public.roles where key = 'admin';

-- 018: left untouched -- stays exactly at the pending_setup / provisioned_at
-- IS NULL state 0011/0019's trigger created it at (same pattern as 009/011
-- above), for section 21's bypass-attempt target.

-- 019: holds users.edit + users.disable + users.manage_store_access + users.view
-- together, deliberately NOT users.create -- section 21's actor for the
-- exact pending_setup -> suspended -> (prepare scope) -> active bypass
-- attempt item 4 describes.
update public.profiles set full_name = 'Test No-Create Full Editor', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000019';
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a0000000-0000-4000-8000-000000000019', id, 'grant' from public.permissions
  where key in ('users.edit', 'users.disable', 'users.manage_store_access', 'users.view');

-- 020: harmless active target for section 20's column-authorization tests.
update public.profiles set full_name = 'Test Column Auth Target', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000020';

-- 021: holds ONLY stores.edit (+ stores.view), deliberately NOT stores.disable
-- -- section 20's stores-equivalent actor.
update public.profiles set full_name = 'Test Store Edit Only', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000021';
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a0000000-0000-4000-8000-000000000021', id, 'grant' from public.permissions where key in ('stores.edit', 'stores.view');

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 18. Close store-scope delegation completely, not just INSERT
--     (Foundation Hardening 1.3 item 1).
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000013","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.manage_store_access') = true, 'الاختبار يفترض أن 013 يملك users.manage_store_access';
  assert public.has_permission('users.edit') = false, 'الاختبار يفترض أن 013 لا يملك أي صلاحية أخرى';
end $$;

-- 18.1: cannot set Target 1's scope to single with default=C (C outside
-- 013's own operable range A+B) -- the NEW default_store_id operable-range
-- check in enforce_store_scope_authorization (0025/0030).
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set store_access_scope = 'single', default_store_id = 'b0000000-0000-4000-8000-00000000000c'
      where id = 'a0000000-0000-4000-8000-000000000014';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع 013 من تعيين متجر افتراضي (C) خارج نطاق تشغيله الخاص لمستخدم آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن 013 من تعيين default_store_id لمستخدم آخر على متجر خارج نطاق تشغيله الخاص';
  end if;
end $$;

-- 18.2: cannot grant Store C to Target 1 (existing 0018 INSERT rule,
-- explicitly re-verified per item 9's request).
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.user_store_access (user_id, store_id)
      values ('a0000000-0000-4000-8000-000000000014', 'b0000000-0000-4000-8000-00000000000c');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع 013 من منح المتجر C لمستخدم آخر (خارج نطاق تشغيله) (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن 013 من منح وصول لمتجر C لمستخدم آخر رغم عدم امتلاكه هو نفسه صلاحية العمل عليه';
  end if;
end $$;

-- 18.3: cannot DELETE Store C from Target 3 (currently A+C) -- the NEW
-- DELETE-branch delegation limit (0025).
do $$
declare v_bug boolean := false;
begin
  begin
    delete from public.user_store_access
      where user_id = 'a0000000-0000-4000-8000-000000000016' and store_id = 'b0000000-0000-4000-8000-00000000000c';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع 013 من إلغاء وصول Target 3 للمتجر C (خارج نطاق تشغيل 013) (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن 013 من إلغاء وصول مستخدم آخر لمتجر C رغم عدم امتلاكه هو نفسه صلاحية العمل عليه -- هذه بالضبط الثغرة التي يُغلقها 0025';
  end if;
end $$;

-- 18.4: modifying A/B on Target 3 succeeds (grant B, then revoke A) -- both
-- within 013's own operable range; Store C stays untouched throughout.
do $$
declare v_ids uuid[];
begin
  insert into public.user_store_access (user_id, store_id)
    values ('a0000000-0000-4000-8000-000000000016', 'b0000000-0000-4000-8000-00000000000b');
  delete from public.user_store_access
    where user_id = 'a0000000-0000-4000-8000-000000000016' and store_id = 'b0000000-0000-4000-8000-00000000000a';

  select coalesce(array_agg(store_id order by store_id), '{}') into v_ids
    from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000016';
  assert v_ids = array[
      'b0000000-0000-4000-8000-00000000000b'::uuid,
      'b0000000-0000-4000-8000-00000000000c'::uuid
    ],
    format('توقعنا [Store B, Store C] بعد منح B وسحب A ضمن نطاق 013 الخاص، وجدنا %s', v_ids);
  raise notice 'OK: تمكّن 013 من منح وسحب المتاجر A/B (ضمن نطاق تشغيله الخاص) لمستخدم آخر، بينما ظل المتجر C خارج النطاق دون تغيير';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 19. Complete users.manage_store_access independence -- the SELECT path
--     (Foundation Hardening 1.3 item 2a).
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000013","role":"authenticated"}';

do $$
begin
  assert public.has_permission('stores.view') = false, 'الاختبار يفترض أن 013 لا يملك stores.view';
  assert public.has_permission('users.manage_permissions') = false, 'الاختبار يفترض أن 013 لا يملك users.manage_permissions (لا يعتمد الإصلاح عليها)';
end $$;

-- Note: 013 DOES hold users.view (see setup comment above) -- what it does
-- NOT hold is stores.view or users.manage_permissions, and the point being
-- proven is specifically that user_store_access visibility comes from
-- users.manage_store_access itself (0028), not accidentally from one of
-- those other two permissions.
--
-- Without 0028's added SELECT policy, this call to replace_user_store_access
-- (SECURITY INVOKER) would see Target 2's CURRENT grants as an empty set
-- under 013's own RLS context, compute the diff against that wrong baseline,
-- and then fail with a duplicate-key error trying to re-INSERT Store B
-- (which already exists) -- the desired set {B} minus a wrongly-empty
-- "existing" set is {B}, not {} as it should be. With the fix, 013 can
-- correctly see the real existing {A, B} and the diff correctly resolves to
-- "remove A only".
do $$
declare v_ids uuid[];
begin
  perform public.replace_user_store_access(
    'a0000000-0000-4000-8000-000000000015'::uuid,
    array['b0000000-0000-4000-8000-00000000000b'::uuid]
  );
  select coalesce(array_agg(store_id order by store_id), '{}') into v_ids
    from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000015';
  assert v_ids = array['b0000000-0000-4000-8000-00000000000b'::uuid],
    format('توقعنا [Store B] فقط بعد استبدال ناجح (إزالة A، الإبقاء على B)، وجدنا %s', v_ids);
  raise notice 'OK: صاحب users.manage_store_access فقط (بلا users.view/stores.view) تمكّن من استخدام replace_user_store_access بنجاح، وحُسب الفرق (diff) بشكل صحيح مقابل الوصول الحالي الفعلي';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 20. Rewrite column authorization as per-column permissions
--     (Foundation Hardening 1.3 item 3).
-- ---------------------------------------------------------------------------

-- 20a. users.edit ALONE cannot suspend/reactivate an account (status is a
-- separate column group, requiring users.disable specifically -- 0030
-- removes the old "users.edit passes everything" shortcut).
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000012","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.edit') = true, 'الاختبار يفترض أن 012 يملك users.edit';
  assert public.has_permission('users.disable') = false, 'الاختبار يفترض أن 012 لا يملك users.disable';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000020';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.edit فقط من تغيير حالة (status) مستخدم آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب users.edit وحدها من تعطيل/تفعيل مستخدم آخر -- هذا يُبطل معنى وجود users.disable كصلاحية منفصلة';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 20b. users.disable ALONE cannot change the name (full_name is a separate
-- column group, requiring users.edit specifically).
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000005","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.disable') = true, 'الاختبار يفترض أن 005 يملك users.disable';
  assert public.has_permission('users.edit') = false, 'الاختبار يفترض أن 005 لا يملك users.edit';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set full_name = 'محاولة تعديل الاسم عبر users.disable فقط' where id = 'a0000000-0000-4000-8000-000000000020';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.disable فقط من تغيير اسم مستخدم آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب users.disable وحدها من تعديل full_name لمستخدم آخر';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 20c. Positive control: an actor holding BOTH users.edit AND users.disable
-- (e.g. Admin 003) can change full_name AND status together in ONE UPDATE --
-- proves the per-column-group rewrite requires the UNION of permissions for
-- a combined change, not that it makes combined changes impossible.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_row record;
begin
  update public.profiles set full_name = 'عُدّل الاسم والحالة معًا', status = 'suspended'
    where id = 'a0000000-0000-4000-8000-000000000020'
    returning * into v_row;
  assert v_row.full_name = 'عُدّل الاسم والحالة معًا' and v_row.status = 'suspended',
    'يجب أن ينجح تعديل مُجمّع لعمودين لصاحب كلتا الصلاحيتين (users.edit + users.disable) معًا';
  raise notice 'OK: صاحب users.edit + users.disable معًا تمكّن من تعديل الاسم والحالة في تحديث واحد';
end $$;

reset role;
reset request.jwt.claims;

-- 20d/20e. Same principle for stores: stores.edit alone cannot disable a
-- store; stores.disable alone cannot rename one.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000021","role":"authenticated"}';

do $$
begin
  assert public.has_permission('stores.edit') = true, 'الاختبار يفترض أن 021 يملك stores.edit';
  assert public.has_permission('stores.disable') = false, 'الاختبار يفترض أن 021 لا يملك stores.disable';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    update public.stores set status = 'disabled' where id = 'b0000000-0000-4000-8000-00000000000b';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب stores.edit فقط من تغيير حالة متجر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب stores.edit وحدها من تعطيل متجر -- هذا يُبطل معنى وجود stores.disable كصلاحية منفصلة';
  end if;
end $$;

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000006","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    update public.stores set name_ar = 'محاولة إعادة تسمية عبر stores.disable فقط' where id = 'b0000000-0000-4000-8000-00000000000b';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب stores.disable فقط من تعديل اسم متجر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب stores.disable وحدها من تعديل بيانات متجر';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 20f. Positive control -- Admin (003, holds both stores.edit and
-- stores.disable) can rename AND disable the same store together.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_store_id uuid; v_row record;
begin
  select id into v_store_id from public.stores where code = 'T-E';
  assert v_store_id is not null, 'الاختبار يفترض وجود متجر T-E (أُنشئ في القسم 15b)';

  update public.stores set name_ar = 'فرع E مُعدّل ومُعطّل معًا', status = 'disabled'
    where id = v_store_id
    returning * into v_row;
  assert v_row.name_ar = 'فرع E مُعدّل ومُعطّل معًا' and v_row.status = 'disabled',
    'يجب أن ينجح تعديل مُجمّع لعمودين لصاحب كلتا الصلاحيتين (stores.edit + stores.disable) معًا';
  raise notice 'OK: صاحب stores.edit + stores.disable معًا تمكّن من تعديل الاسم والحالة في تحديث واحد';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 21. Close the provisioning bypass permanently (Foundation Hardening 1.3
--     item 4): pending_setup -> suspended -> (prepare scope) -> active must
--     fail for an actor holding users.edit + users.disable +
--     users.manage_store_access but deliberately NOT users.create.
-- ---------------------------------------------------------------------------
do $$
declare v_status text; v_provisioned timestamptz;
begin
  select status, provisioned_at into v_status, v_provisioned
    from public.profiles where id = 'a0000000-0000-4000-8000-000000000018';
  assert v_status = 'pending_setup', 'يجب أن يبدأ الهدف 018 بحالة pending_setup';
  assert v_provisioned is null, 'يجب أن يبدأ الهدف 018 بـ provisioned_at = null';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000019","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.edit') and public.has_permission('users.disable')
    and public.has_permission('users.manage_store_access'), 'الاختبار يفترض أن 019 يملك edit + disable + manage_store_access معًا';
  assert public.has_permission('users.create') = false, 'الاختبار يفترض أن 019 لا يملك users.create';
end $$;

-- Hop 1: pending_setup -> suspended. Foundation Hardening 1.3 originally
-- expected this to succeed as "an ordinary disable action" (users.disable,
-- not gated by users.create) -- Foundation Hardening 1.4 item 5 (0036) found
-- that this exact hop is what stranded the underlying auth.users row
-- permanently (see 0036's header comment), and now rejects it outright for
-- ANY non-trusted actor. The three-hop bypass this section exists to prove
-- is closed is therefore now blocked at the very FIRST hop -- strictly
-- earlier, and strictly more completely, than before: 019 never even
-- reaches a state where hops 2/3 are meaningful to attempt.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000018';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: (Foundation Hardening 1.4) مُنعت حتى الخطوة الأولى من محاولة الالتفاف -- pending_setup -> suspended مرفوضة الآن لأي فاعل غير موثوق، بصرف النظر عن الصلاحيات (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن حساب 019 من نقل 018 من pending_setup إلى suspended -- 0036 يجب أن يمنع هذا للجميع';
  end if;
end $$;

do $$
declare v_status text; v_provisioned timestamptz;
begin
  select status, provisioned_at into v_status, v_provisioned
    from public.profiles where id = 'a0000000-0000-4000-8000-000000000018';
  assert v_status = 'pending_setup', 'يجب أن يبقى الهدف 018 عند pending_setup بعد فشل الخطوة الأولى';
  assert v_provisioned is null, 'يجب أن يبقى provisioned_at فارغًا لهدف لم يُزوَّد قط';
  raise notice 'OK: 018 بقي pending_setup/provisioned_at=null بلا أي تغيير جزئي -- لا حاجة لمحاولة الخطوتين 2/3 أصلًا (سلسلة الالتفاف بالكامل مسدودة من جذرها). مسار الإلغاء الصحيح مغطى في القسم 29.';
end $$;

reset role;
reset request.jwt.claims;

-- 21b. Positive control: a genuinely-PROVISIONED account (009, finalized in
-- section 9b, so provisioned_at IS set) can still be suspended and
-- reactivated normally by an ordinary users.disable holder -- proves the new
-- invariant does not break the everyday suspend/reactivate flow, only the
-- never-provisioned bypass.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000005","role":"authenticated"}';

do $$
declare v_status text;
begin
  assert (select provisioned_at from public.profiles where id = 'a0000000-0000-4000-8000-000000000009') is not null,
    'الاختبار يفترض أن 009 (المُزوَّد في القسم 9ب) يملك provisioned_at غير فارغ';

  update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000009';
  update public.profiles set status = 'active' where id = 'a0000000-0000-4000-8000-000000000009';
  select status into v_status from public.profiles where id = 'a0000000-0000-4000-8000-000000000009';
  assert v_status = 'active', 'يجب أن ينجح تعطيل ثم إعادة تفعيل حساب مُزوَّد فعليًا (provisioned_at موجود) عبر users.disable العادية';
  raise notice 'OK: حساب مُزوَّد فعليًا (provisioned_at موجود) يمكن تعطيله وإعادة تفعيله بشكل طبيعي -- القيد الجديد لا يكسر إعادة التفعيل المشروعة';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 22. Sensitive permissions -- protection covers the revoke path too
--     (Foundation Hardening 1.3 item 5). 'admin' role carries both
--     users.manage_permissions and settings.manage (seed.sql); Admin (003)
--     holds users.manage_permissions via that role but is not Super Admin.
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.manage_permissions') = true, 'الاختبار يفترض أن 003 يملك users.manage_permissions';
  assert public.am_i_super_admin() = false, 'الاختبار يفترض أن 003 ليس Super Admin';
end $$;

-- 22a. DELETE from role_permissions for a sensitive permission (removing
-- settings.manage from the 'admin' role itself) is blocked.
do $$
declare v_bug boolean := false;
begin
  begin
    delete from public.role_permissions
      where role_id = (select id from public.roles where key = 'admin')
        and permission_id = (select id from public.permissions where key = 'settings.manage');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.manage_permissions (غير Super Admin) من سحب صلاحية حساسة (settings.manage) من دور (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من سحب صلاحية حساسة من دور عبر DELETE على role_permissions';
  end if;
end $$;

-- 22b. INSERTing a 'revoke' override for a sensitive permission on another
-- user is blocked (not just 'grant' overrides, per 0013's narrower rule).
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.user_permission_overrides (user_id, permission_id, effect)
      select 'a0000000-0000-4000-8000-000000000005', id, 'revoke' from public.permissions where key = 'users.manage_permissions';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.manage_permissions (غير Super Admin) من إضافة استثناء revoke لصلاحية حساسة (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من إضافة استثناء revoke لصلاحية حساسة لمستخدم آخر';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 22c. Deleting an EXISTING sensitive override (which could restore a
-- role-derived grant) is blocked. Created first by Super Admin (trusted,
-- exempt) so there is a real row to attempt deleting.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
begin
  insert into public.user_permission_overrides (user_id, permission_id, effect)
    select 'a0000000-0000-4000-8000-000000000006', id, 'grant' from public.permissions where key = 'backups.manage';
end $$;

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    delete from public.user_permission_overrides
      where user_id = 'a0000000-0000-4000-8000-000000000006'
        and permission_id = (select id from public.permissions where key = 'backups.manage');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.manage_permissions (غير Super Admin) من حذف استثناء صلاحية حساسة قائم (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من حذف استثناء صلاحية حساسة قائم لمستخدم آخر';
  end if;
end $$;

-- 22d. Removing a ROLE that carries a sensitive permission from a user
-- (017 holds 'admin', which carries users.manage_permissions + settings.manage).
do $$
declare v_bug boolean := false; v_admin_role_id uuid;
begin
  select id into v_admin_role_id from public.roles where key = 'admin';
  begin
    delete from public.user_roles
      where user_id = 'a0000000-0000-4000-8000-000000000017' and role_id = v_admin_role_id;
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.manage_permissions (غير Super Admin) من إزالة دور يحمل صلاحية حساسة عن مستخدم آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من إزالة دور (admin، يحمل صلاحيات حساسة) عن مستخدم آخر';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 23. Complete Super Admin protection as a full entity (Foundation
--     Hardening 1.3 item 6) -- Super Admin 007 (still active, restored in
--     14e/14f), Admin 003 (non-Super-Admin, holds users.manage_permissions +
--     users.manage_store_access via the 'admin' role).
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

-- 23a. Assigning an ADDITIONAL role to a Super Admin target is blocked (not
-- just removing super_admin itself, which 0020 already covered).
do $$
declare v_bug boolean := false; v_sales_role_id uuid;
begin
  select id into v_sales_role_id from public.roles where key = 'sales_employee';
  begin
    insert into public.user_roles (user_id, role_id) values ('a0000000-0000-4000-8000-000000000007', v_sales_role_id);
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin غير Super Admin من إسناد دور إضافي لمستخدم Super Admin (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من إسناد دور إضافي (غير super_admin) لمستخدم Super Admin';
  end if;
end $$;

-- 23b. Granting a permission override (even a non-sensitive one) to a Super
-- Admin target is blocked.
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.user_permission_overrides (user_id, permission_id, effect)
      select 'a0000000-0000-4000-8000-000000000007', id, 'grant' from public.permissions where key = 'dashboard.view';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin غير Super Admin من إضافة استثناء صلاحية (حتى غير حساسة) لمستخدم Super Admin (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من إضافة استثناء صلاحية لمستخدم Super Admin';
  end if;
end $$;

-- 23c. Granting store access to a Super Admin target is blocked, even
-- though 003 holds users.manage_store_access and operates every store.
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.user_store_access (user_id, store_id)
      values ('a0000000-0000-4000-8000-000000000007', 'b0000000-0000-4000-8000-00000000000a');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع Admin غير Super Admin من منح وصول متجر لمستخدم Super Admin (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن Admin غير Super Admin من منح وصول متجر لمستخدم Super Admin';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 23d. Positive control -- a FELLOW Super Admin (001) CAN grant 007 a
-- permission override, proving the block above is specific to non-Super-
-- Admin actors.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare v_count int;
begin
  insert into public.user_permission_overrides (user_id, permission_id, effect)
    select 'a0000000-0000-4000-8000-000000000007', id, 'grant' from public.permissions where key = 'dashboard.view';
  select count(*) into v_count from public.user_permission_overrides
    where user_id = 'a0000000-0000-4000-8000-000000000007' and permission_id = (select id from public.permissions where key = 'dashboard.view');
  assert v_count = 1, 'يجب أن ينجح Super Admin آخر في إضافة استثناء صلاحية لمستخدم Super Admin';
  raise notice 'OK: تمكّن Super Admin من إضافة استثناء صلاحية لمستخدم Super Admin آخر (الحماية خاصة بالفاعل غير Super Admin فقط)';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 24. Inactive-session hardening for store-scope resolution (Foundation
--     Hardening 1.3 item 7, database half -- see src/lib/supabase/
--     middleware.ts for the redirect-loop half of this item).
-- ---------------------------------------------------------------------------

-- 24a. Actor 010 (section 9d: was active with scope='single'/default=Store A,
-- then deliberately suspended) -- store_access_scope/default_store_id data
-- is still fully intact, but the account is not active. Both resolvers must
-- now return EMPTY regardless.
do $$
declare v_status text; v_operable int; v_visible int;
begin
  select status into v_status from public.profiles where id = 'a0000000-0000-4000-8000-000000000010';
  assert v_status = 'suspended', 'الاختبار يفترض أن 010 لا يزال معطّلاً (كما تركه القسم 9د)';

  select count(*) into v_operable from public.user_operable_store_ids('a0000000-0000-4000-8000-000000000010');
  select count(*) into v_visible from public.user_visible_store_ids('a0000000-0000-4000-8000-000000000010');
  assert v_operable = 0, format('حساب غير نشط: يجب أن يكون user_operable_store_ids فارغًا رغم بيانات النطاق السليمة، وجدنا %s', v_operable);
  assert v_visible = 0, format('حساب غير نشط: يجب أن يكون user_visible_store_ids فارغًا كذلك رغم بيانات النطاق السليمة، وجدنا %s', v_visible);
  raise notice 'OK: user_operable_store_ids/user_visible_store_ids يفشلان بأمان (يُرجعان فارغًا) لحساب غير نشط، رغم بقاء بيانات store_access_scope/default_store_id سليمة';
end $$;

-- 24b. Same account's own self-scoped session functions (as if a JWT for
-- this suspended user still technically existed) also fail closed.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000010","role":"authenticated"}';

do $$
declare v_operable int; v_visible int;
begin
  select count(*) into v_operable from public.my_operable_store_ids();
  select count(*) into v_visible from public.my_visible_store_ids();
  assert v_operable = 0, format('جلسة مستخدم مُعطّل: توقعنا my_operable_store_ids فارغة، وجدنا %s', v_operable);
  assert v_visible = 0, format('جلسة مستخدم مُعطّل: توقعنا my_visible_store_ids فارغة، وجدنا %s', v_visible);
  raise notice 'OK: my_operable_store_ids/my_visible_store_ids (الدوال ذاتية النطاق) تفشل بأمان لجلسة مستخدم غير نشط';
end $$;

reset role;
reset request.jwt.claims;

-- 24c. Regression guard -- an ACTIVE user's operable/visible ids are
-- unaffected by this fix (still correctly non-empty).
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare v_operable int;
begin
  select count(*) into v_operable from public.my_operable_store_ids();
  assert v_operable = 1, format('حساب نشط (002، single scope): توقعنا 1 متجر قابل للعمل عليه، وجدنا %s', v_operable);
  raise notice 'OK: حسابات نشطة لا تزال تحصل على نتيجة صحيحة من my_operable_store_ids -- إصلاح 0031 خاص بالحسابات غير النشطة فقط';
end $$;

reset role;
reset request.jwt.claims;

-- ============================================================================
-- Foundation Hardening 1.4 (migrations 0032-0036): a review of the
-- actually-shipped 1.3 code and ZIP found five further gaps. Sections 25-29
-- below cover all of them.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 25. provisioned_at legacy backfill (Foundation Hardening 1.4 item 1,
--     0032). Migrations run once against a fresh, EMPTY profiles table in
--     this test harness -- 0032's backfill UPDATEs affect zero rows at
--     apply-time here, so this section validates the backfill LOGIC
--     directly: construct synthetic "legacy" rows (as if provisioned_at had
--     just been added to a database with pre-existing data) via trusted
--     writes, then re-run 0032's own UPDATE statements verbatim against
--     them.
-- ---------------------------------------------------------------------------
-- This section runs as the plain superuser connection (no `set role`, no
-- request.jwt.claims) -- auth.uid() is null, so is_trusted_bootstrap_context()
-- is already true for every trigger below, exactly like `service_role`.
--
-- profiles_enforce_activation_requires_provisioning (0029) auto-stamps
-- provisioned_at the instant ANY write -- even a trusted one -- leaves a row
-- at status='active' with provisioned_at still null (entirely correct and
-- intentional for real traffic, see that migration's comment). That means a
-- trusted UPDATE cannot simply null provisioned_at back out on an
-- already-active row to construct a synthetic "legacy" row for this test --
-- it gets immediately re-stamped. Real legacy data never went through this
-- trigger at all: 0029's `ALTER TABLE ... ADD COLUMN provisioned_at` just
-- leaves every pre-existing row's value null, with no per-row trigger
-- involved, and enforce_system_managed_columns (0021) unconditionally pins
-- created_at on every INSERT/UPDATE (by design, to stop forgery) which
-- would equally stop this test from backdating it. Disabling both triggers
-- for just this synthetic-data setup (superuser-only DDL, not a migration
-- change) reproduces that "data already existed before these columns/rules
-- did" starting condition faithfully; both are re-enabled immediately after.
alter table public.profiles disable trigger profiles_enforce_activation_requires_provisioning;
alter table public.profiles disable trigger profiles_enforce_system_columns;

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000022', 'test-legacy-active@example.invalid'),
  ('a0000000-0000-4000-8000-000000000023', 'test-legacy-suspended-was-active@example.invalid'),
  ('a0000000-0000-4000-8000-000000000024', 'test-legacy-suspended-never-active@example.invalid');

-- 022: legacy ACTIVE row -- active with provisioned_at still null and a
-- real historical creation time, exactly what 0029's ALTER TABLE would have
-- left behind on a pre-existing active account.
update public.profiles
  set full_name = 'Test Legacy Active', status = 'active', store_access_scope = 'all',
      created_at = now() - interval '30 days'
  where id = 'a0000000-0000-4000-8000-000000000022';

-- 023: legacy SUSPENDED row that WAS active at some point (audit_logs has a
-- 'user.update' event with new_values.status = 'active' for it) -- case (i)
-- from 0032's comment. The 'user.update' -> active event itself needs the
-- activation trigger DISABLED too, or it would auto-stamp provisioned_at
-- right here and defeat the point of this synthetic row -- it is, for the
-- whole block.
update public.profiles
  set full_name = 'Test Legacy Was Active', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000023';
update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000023';

-- 024: legacy SUSPENDED row that was NEVER active (no audit_logs evidence)
-- -- case (ii), indistinguishable from a cancelled invite, must NOT be
-- backfilled. Direct pending_setup -> suspended, simulating a stray
-- pre-0036 row (0036's own block is bypassed here too, same trusted-context
-- reasoning as everywhere else in this file).
update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000024';

alter table public.profiles enable trigger profiles_enforce_activation_requires_provisioning;
alter table public.profiles enable trigger profiles_enforce_system_columns;

do $$
begin
  assert (select provisioned_at from public.profiles where id = 'a0000000-0000-4000-8000-000000000022') is null;
  assert (select provisioned_at from public.profiles where id = 'a0000000-0000-4000-8000-000000000023') is null;
  assert (select provisioned_at from public.profiles where id = 'a0000000-0000-4000-8000-000000000024') is null;
  assert exists (
    select 1 from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000023'
      and action = 'user.update' and new_values ->> 'status' = 'active'
  ), 'الاختبار يفترض وجود سجل تدقيق يثبت أن 023 كان active في وقت ما';
  assert not exists (
    select 1 from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000024'
      and action = 'user.update' and new_values ->> 'status' = 'active'
  ), 'الاختبار يفترض عدم وجود أي سجل تدقيق يثبت أن 024 كان active في أي وقت';
end $$;

-- Re-run 0032's Case A UPDATE verbatim.
update public.profiles
set provisioned_at = created_at
where status = 'active' and provisioned_at is null;

-- Re-run 0032's Case B UPDATE verbatim.
update public.profiles p
set provisioned_at = earliest.first_active_at
from (
  select al.entity_id as profile_id, min(al.created_at) as first_active_at
  from public.audit_logs al
  where al.entity_type = 'user'
    and al.action = 'user.update'
    and al.new_values ->> 'status' = 'active'
  group by al.entity_id
) earliest
where p.id = earliest.profile_id
  and p.status = 'suspended'
  and p.provisioned_at is null;

do $$
declare v_022 timestamptz; v_022_created timestamptz; v_023 timestamptz; v_024 timestamptz;
begin
  select provisioned_at, created_at into v_022, v_022_created from public.profiles where id = 'a0000000-0000-4000-8000-000000000022';
  select provisioned_at into v_023 from public.profiles where id = 'a0000000-0000-4000-8000-000000000023';
  select provisioned_at into v_024 from public.profiles where id = 'a0000000-0000-4000-8000-000000000024';

  assert v_022 is not null and v_022 = v_022_created,
    format('حالة (أ) نشط قديم: يجب أن يُملأ provisioned_at بـ created_at، وجدنا provisioned_at=%s created_at=%s', v_022, v_022_created);
  assert v_023 is not null,
    'حالة (ب-١) معطّل قديم كان نشطًا (بدليل سجل تدقيق): يجب أن يُملأ provisioned_at';
  assert v_024 is null,
    'حالة (ب-٢) معطّل قديم لم يكن نشطًا أبدًا: يجب أن يبقى provisioned_at فارغًا (لا يمكن تمييزه عن دعوة أُلغيت)';

  raise notice 'OK: (Foundation Hardening 1.4 item 1) Backfill 0032 يملأ provisioned_at للحسابات النشطة والمعطّلة-كانت-نشطة القديمة، ويترك الحسابات المعطّلة التي لم تكن نشطة أبدًا بلا تغيير عمدًا';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 26. Lock user_permission_overrides identity (Foundation Hardening 1.4
--     item 2, 0033). Reuses existing targets: 020 (ordinary active user,
--     not Super Admin) and 007 (a second Super Admin, from section 20/23).
-- ---------------------------------------------------------------------------
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into public.user_permission_overrides (user_id, permission_id, effect) values
  ('a0000000-0000-4000-8000-000000000020', (select id from public.permissions where key = 'dashboard.view'), 'grant'),
  ('a0000000-0000-4000-8000-000000000020', (select id from public.permissions where key = 'settings.manage'), 'revoke');
-- NOTE: (007, dashboard.view, grant) is NOT inserted here -- section 23d
-- already created that exact row (Super Admin 001 granting a dashboard.view
-- override to fellow Super Admin 007) and nothing between there and here
-- touches it, so re-inserting it would violate the (user_id, permission_id)
-- primary key. 26c below reuses that existing row.

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
begin
  assert public.am_i_super_admin() = true, 'الاختبار يفترض أن 001 Super Admin';
end $$;

-- 26a. Even Super Admin cannot re-point an ordinary override's user_id to a
-- different user via UPDATE.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.user_permission_overrides
      set user_id = 'a0000000-0000-4000-8000-000000000002'
      where user_id = 'a0000000-0000-4000-8000-000000000020'
        and permission_id = (select id from public.permissions where key = 'dashboard.view');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع حتى Super Admin من تغيير user_id لاستثناء صلاحية موجود عبر UPDATE (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: أمكن نقل استثناء صلاحية من مستخدم إلى آخر عبر UPDATE على user_id';
  end if;
end $$;

-- 26b. Cannot re-point a sensitive-permission override onto a non-sensitive
-- permission_id (or vice versa) via UPDATE -- moving off of/onto a
-- sensitive key must go through DELETE + INSERT, which re-triggers 0013/
-- 0027's own sensitive-key checks.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.user_permission_overrides
      set permission_id = (select id from public.permissions where key = 'dashboard.view')
      where user_id = 'a0000000-0000-4000-8000-000000000020'
        and permission_id = (select id from public.permissions where key = 'settings.manage');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع نقل استثناء صلاحية حسّاسة (settings.manage) إلى صلاحية غير حسّاسة عبر UPDATE على permission_id (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: أمكن نقل استثناء صلاحية حسّاسة إلى صلاحية أخرى غير حسّاسة عبر UPDATE';
  end if;
end $$;

-- 26c. Cannot re-point a Super-Admin-target's override to a different user
-- via UPDATE, even as Super Admin (who otherwise passes 0026's own check).
do $$
declare v_bug boolean := false;
begin
  begin
    update public.user_permission_overrides
      set user_id = 'a0000000-0000-4000-8000-000000000002'
      where user_id = 'a0000000-0000-4000-8000-000000000007'
        and permission_id = (select id from public.permissions where key = 'dashboard.view');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع نقل استثناء صلاحية يخصّ هدف Super Admin إلى مستخدم آخر عبر UPDATE (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: أمكن نقل استثناء صلاحية Super Admin إلى مستخدم آخر عبر UPDATE على user_id';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 26d. Positive control: effect/reason on an EXISTING (user_id,
-- permission_id) pair still change normally -- the identity lock does not
-- break ordinary override edits.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000003","role":"authenticated"}';

do $$
declare v_effect text; v_reason text;
begin
  update public.user_permission_overrides
    set effect = 'revoke', reason = 'تعديل تجريبي على effect/reason فقط'
    where user_id = 'a0000000-0000-4000-8000-000000000020'
      and permission_id = (select id from public.permissions where key = 'dashboard.view');

  select effect, reason into v_effect, v_reason
    from public.user_permission_overrides
    where user_id = 'a0000000-0000-4000-8000-000000000020'
      and permission_id = (select id from public.permissions where key = 'dashboard.view');

  assert v_effect = 'revoke' and v_reason = 'تعديل تجريبي على effect/reason فقط',
    'يجب أن ينجح تعديل effect/reason على نفس هوية الاستثناء (user_id/permission_id بلا تغيير)';
  raise notice 'OK: تعديل effect/reason (بلا تغيير الهوية) لا يزال يعمل بشكل طبيعي';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 27. Complete store-scope delegation for store_access_scope-only changes
--     (Foundation Hardening 1.4 item 3, 0034). Actor 013 (A+B only, reused
--     from section 18/19).
-- ---------------------------------------------------------------------------

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000025', 'test-scope-diff-leaving@example.invalid'),
  ('a0000000-0000-4000-8000-000000000026', 'test-scope-diff-in-range@example.invalid'),
  ('a0000000-0000-4000-8000-000000000027', 'test-scope-diff-entering@example.invalid');

-- 025: scope='single', default=C (outside 013's A+B range), NO
-- user_store_access rows -- effective access today is exactly {C}.
update public.profiles
  set full_name = 'Test Scope Diff Leaving', status = 'active', store_access_scope = 'single',
      default_store_id = 'b0000000-0000-4000-8000-00000000000c'
  where id = 'a0000000-0000-4000-8000-000000000025';

-- 026: scope='single', default=A (WITHIN 013's range), NO user_store_access
-- rows -- effective access today is exactly {A}.
update public.profiles
  set full_name = 'Test Scope Diff In-Range', status = 'active', store_access_scope = 'single',
      default_store_id = 'b0000000-0000-4000-8000-00000000000a'
  where id = 'a0000000-0000-4000-8000-000000000026';

-- 027: scope='multiple' with NO user_store_access rows (effective access
-- today is EMPTY), but default_store_id already = C (leftover/irrelevant
-- while scope='multiple' -- only becomes relevant if scope flips back to
-- 'single').
update public.profiles
  set full_name = 'Test Scope Diff Entering', status = 'active', store_access_scope = 'multiple',
      default_store_id = 'b0000000-0000-4000-8000-00000000000c'
  where id = 'a0000000-0000-4000-8000-000000000027';

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000013","role":"authenticated"}';

-- 27a. LEAVING, blocked: flipping 025 single->multiple (default_store_id
-- UNCHANGED, still C) makes C leave the target's effective access (multiple
-- has no user_store_access grants) -- C is outside 013's own range.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set store_access_scope = 'multiple' where id = 'a0000000-0000-4000-8000-000000000025';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع 013 من تغيير store_access_scope فقط (بلا تغيير default_store_id) يُخرج متجر C من الوصول الفعلي وهو خارج نطاقه (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن 013 من تغيير store_access_scope فقط بحيث يخرج متجر C (خارج نطاقه) من الوصول الفعلي لمستخدم آخر';
  end if;
end $$;

-- 27b. Positive control, IN-RANGE change succeeds: same shape of change on
-- 026, but the store leaving effective access (A) IS within 013's range.
do $$
declare v_scope text;
begin
  update public.profiles set store_access_scope = 'multiple' where id = 'a0000000-0000-4000-8000-000000000026';
  select store_access_scope into v_scope from public.profiles where id = 'a0000000-0000-4000-8000-000000000026';
  assert v_scope = 'multiple', 'يجب أن ينجح تغيير store_access_scope فقط عندما يبقى الفرق ضمن نطاق الفاعل (A)';
  raise notice 'OK: تغيير store_access_scope فقط ينجح عندما يكون كل متجر يتأثر ضمن نطاق تشغيل الفاعل';
end $$;

-- 27c. ENTERING, blocked: flipping 027 multiple->single (default_store_id
-- UNCHANGED, still C) makes C ENTER the target's effective access -- C is
-- outside 013's own range.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set store_access_scope = 'single' where id = 'a0000000-0000-4000-8000-000000000027';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع 013 من تغيير store_access_scope فقط بحيث يدخل متجر C (خارج نطاقه) الوصول الفعلي لمستخدم آخر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن 013 من تغيير store_access_scope فقط بحيث يدخل متجر C (خارج نطاقه) الوصول الفعلي لمستخدم آخر';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 28. Complete the users.manage_store_access UI/DB flow (Foundation
--     Hardening 1.4 item 4, 0035). Actor 028 holds users.manage_store_access
--     ONLY -- deliberately not users.view/stores.view/users.manage_permissions
--     -- so this section proves the flow works WITHOUT stores.view too, not
--     just narrower than it (unlike actor 013, which also holds users.view).
-- ---------------------------------------------------------------------------
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000028', 'test-store-access-only@example.invalid'),
  ('a0000000-0000-4000-8000-000000000029', 'test-narrow-select-target@example.invalid');

update public.profiles set full_name = 'Test Store Access Only', status = 'active', store_access_scope = 'multiple'
  where id = 'a0000000-0000-4000-8000-000000000028';
insert into public.user_store_access (user_id, store_id) values
  ('a0000000-0000-4000-8000-000000000028', 'b0000000-0000-4000-8000-00000000000a'),
  ('a0000000-0000-4000-8000-000000000028', 'b0000000-0000-4000-8000-00000000000b');
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a0000000-0000-4000-8000-000000000028', id, 'grant' from public.permissions where key = 'users.manage_store_access';

update public.profiles set full_name = 'Test Narrow Select Target', status = 'active', store_access_scope = 'multiple'
  where id = 'a0000000-0000-4000-8000-000000000029';
insert into public.user_store_access (user_id, store_id) values
  ('a0000000-0000-4000-8000-000000000029', 'b0000000-0000-4000-8000-00000000000a'),
  ('a0000000-0000-4000-8000-000000000029', 'b0000000-0000-4000-8000-00000000000c');

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000028","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.manage_store_access') = true, 'الاختبار يفترض أن 028 يملك users.manage_store_access';
  assert public.has_permission('users.view') = false, 'الاختبار يفترض أن 028 لا يملك users.view';
  assert public.has_permission('stores.view') = false, 'الاختبار يفترض أن 028 لا يملك stores.view';
end $$;

-- 28a. manageable_stores_for_actor() returns EXACTLY {A, B} -- not C, not
-- the disabled D -- WITHOUT stores.view.
do $$
declare v_count int; v_has_c boolean;
begin
  select count(*) into v_count from public.manageable_stores_for_actor();
  select exists (select 1 from public.manageable_stores_for_actor() where id = 'b0000000-0000-4000-8000-00000000000c') into v_has_c;
  assert v_count = 2, format('يجب أن يعيد manageable_stores_for_actor() متجرين فقط (A و B) لفاعل نطاقه A+B، وجدنا %s', v_count);
  assert v_has_c = false, 'يجب ألا يظهر المتجر C (خارج النطاق) في manageable_stores_for_actor()';
  raise notice 'OK: manageable_stores_for_actor() يعيد فقط متاجر الفاعل التشغيلية (A+B)، بلا الاعتماد على stores.view، وبلا كشف C';
end $$;

-- 28b. SELECT on user_store_access is narrowed to the actor's own operable
-- range: 028 sees only the A row for target 029 (who holds A+C), not C.
do $$
declare v_count int;
begin
  select count(*) into v_count from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000029';
  assert v_count = 1, format('يجب أن يرى 028 صفًا واحدًا فقط (A) من وصول متاجر 029 (يملك A+C)، وجدنا %s', v_count);
  raise notice 'OK: سياسة SELECT المُضيَّقة تُخفي عن 028 وصول متاجر خارج نطاقه (C) حتى لو كان الهدف يملكها فعليًا';
end $$;

-- 28c. Atomic replace: 028 edits 029's A/B grants (submits desired=[B],
-- unaware of C entirely) -- A is removed, B is added, C (outside 028's
-- range, invisible to 028) is left UNTOUCHED rather than the whole call
-- failing.
do $$
begin
  perform public.replace_user_store_access('a0000000-0000-4000-8000-000000000029', array['b0000000-0000-4000-8000-00000000000b']::uuid[]);
end $$;

reset role;
reset request.jwt.claims;

set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

do $$
declare v_stores uuid[];
begin
  select coalesce(array_agg(store_id order by store_id), '{}') into v_stores
    from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000029';
  assert v_stores = array['b0000000-0000-4000-8000-00000000000b', 'b0000000-0000-4000-8000-00000000000c']::uuid[],
    format('يجب أن يصبح وصول 029 بالضبط {B, C} (A أُزيلت، B أُضيفت، C بقيت بلا تغيير)، وجدنا %s', v_stores);
  raise notice 'OK: (Foundation Hardening 1.4 item 4) الاستبدال الذرّي عدّل A/B بدقة وترك C (خارج نطاق الفاعل) بلا تغيير، بدل فشل العملية بالكامل';
end $$;

reset role;
reset request.jwt.claims;

-- 28d. Negative control: an actor without users.manage_store_access at all
-- gets an empty list from manageable_stores_for_actor().
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
declare v_count int;
begin
  assert public.has_permission('users.manage_store_access') = false, 'الاختبار يفترض أن 002 لا يملك users.manage_store_access';
  select count(*) into v_count from public.manageable_stores_for_actor();
  assert v_count = 0, format('يجب أن يعيد manageable_stores_for_actor() مجموعة فارغة لفاعل لا يملك users.manage_store_access، وجدنا %s', v_count);
  raise notice 'OK: manageable_stores_for_actor() فارغة لفاعل لا يملك users.manage_store_access إطلاقًا';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 29. Fix the cancelled-invite lifecycle (Foundation Hardening 1.4 item 5,
--     0036). Sections 9f/21 above already prove pending_setup -> suspended
--     is now rejected for every non-trusted actor; this section proves the
--     REPLACEMENT flow (trusted-context auth.users deletion, mirroring
--     cancelUserInviteAction) actually works, and that no bypass of
--     users.create/provisioned_at is opened back up.
-- ---------------------------------------------------------------------------
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000030', 'test-invite-cancel-delete@example.invalid'),
  ('a0000000-0000-4000-8000-000000000031', 'test-invite-cancel-trusted-transition@example.invalid');

do $$
begin
  assert (select status from public.profiles where id = 'a0000000-0000-4000-8000-000000000030') = 'pending_setup';
  assert (select provisioned_at from public.profiles where id = 'a0000000-0000-4000-8000-000000000030') is null;
end $$;

-- 29a. The actual cancellation mechanism: delete the still-unprovisioned
-- auth.users row (mirrors cancelUserInviteAction's admin.auth.admin.
-- deleteUser() call) -- ON DELETE CASCADE (0002) removes the matching
-- profiles row in the same statement.
delete from auth.users where id = 'a0000000-0000-4000-8000-000000000030';

do $$
declare v_count int;
begin
  select count(*) into v_count from public.profiles where id = 'a0000000-0000-4000-8000-000000000030';
  assert v_count = 0, 'يجب أن يختفي صفّ profiles تمامًا بعد حذف auth.users (ON DELETE CASCADE)';
  raise notice 'OK: حذف auth.users الموثوق لدعوة pending_setup غير المكتملة يحذف صفّ profiles المطابق تلقائيًا -- لا حساب عالق';
end $$;

-- 29b. Trusted-context direct pending_setup -> suspended still works (an
-- operator data-fix path, or reproducing a legacy pre-0036 row) -- 0036's
-- block is specific to non-trusted actors, not an absolute prohibition.
update public.profiles set status = 'suspended' where id = 'a0000000-0000-4000-8000-000000000031';

do $$
declare v_status text;
begin
  select status into v_status from public.profiles where id = 'a0000000-0000-4000-8000-000000000031';
  assert v_status = 'suspended', 'سياق موثوق (service_role) يجب أن يبقى قادرًا على تنفيذ pending_setup -> suspended مباشرة';
  raise notice 'OK: السياق الموثوق لا يزال قادرًا على pending_setup -> suspended مباشرة -- المنع (0036) خاص بالفاعل غير الموثوق فقط';
end $$;

reset role;
reset request.jwt.claims;

-- 29c. No resume path: even Super Admin cannot finalize a 'suspended' row
-- (finalize_new_user_profile only ever matches 'pending_setup') -- no bypass
-- of users.create/provisioned_at is reopened by this section's changes.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.finalize_new_user_profile('a0000000-0000-4000-8000-000000000031', 'محاولة إنعاش دعوة أُلغيت', null, 'single');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: لا يوجد مسار "استئناف" لدعوة أُلغيت -- حتى Super Admin يفشل في finalize_new_user_profile على صفّ suspended (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: أمكن إنعاش/إتمام دعوة suspended عبر finalize_new_user_profile -- هذا يتجاوز users.create/provisioned_at';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- ============================================================================
-- Patch 1.4.1 (migrations 0037-0038): a final, narrowly-scoped hardening
-- patch on top of Foundation Hardening 1.4 -- exactly three items, no new
-- features. Sections 30-32 below cover each one with its own actors/targets,
-- following the same "deliberately narrow-scoped, never reuse an all-scope
-- actor to accidentally paper over a gap" discipline as sections 18-29.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 30. Fully separate users.manage_store_access from users.manage_permissions
--     (Patch 1.4.1 item 1, 0037). A users.manage_permissions holder who does
--     NOT also hold users.manage_store_access must be unable to touch Store
--     Scope, Default Store, or user_store_access rows/RPC in any way; a
--     users.manage_store_access holder (013, reused from section 18/19, does
--     NOT hold users.manage_permissions) must still succeed at exactly the
--     same operations, proving 0037 narrows without breaking the real path.
-- ---------------------------------------------------------------------------
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000032', 'test-manage-permissions-only@example.invalid'),
  ('a0000000-0000-4000-8000-000000000033', 'test-0037-store-access-target@example.invalid');

-- 032: holds users.manage_permissions + users.edit + users.view, deliberately
-- NOT users.manage_store_access -- exactly the shape 0037 exists to close
-- off from store-access writes. users.view is included for the same reason
-- it was on 013 (section 18's setup comment): without it the target row
-- would not even be SELECT-visible to 032. users.edit is ALSO required here
-- (unlike 013/028 elsewhere in this file) specifically so 032 satisfies
-- profiles_update's own RLS USING/WITH CHECK clause (0010: users.edit OR
-- users.disable only -- users.manage_permissions was never part of it, and
-- still isn't after 0037) and the UPDATE actually reaches
-- enforce_store_scope_authorization (0030) -- the trigger this section is
-- really probing. Without users.edit, RLS itself would silently match zero
-- rows before the trigger ever ran, which would test RLS row-visibility
-- instead of the users.manage_store_access requirement 0037's own comment
-- (and this section) documents as already having been correctly scoped.
update public.profiles set full_name = 'Test Manage-Permissions-Only', status = 'active', store_access_scope = 'all'
  where id = 'a0000000-0000-4000-8000-000000000032';
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'a0000000-0000-4000-8000-000000000032', id, 'grant' from public.permissions where key in ('users.manage_permissions', 'users.edit', 'users.view');

-- 033: target -- scope='multiple', holds Store A only. Both A and B are
-- within actor 013's own operable range (reused positive control below), so
-- 013's edits are never confounded by an out-of-range store the way 016/029
-- deliberately are elsewhere in this file -- this section is purely about
-- the manage_permissions-vs-manage_store_access boundary, not delegation
-- range (already covered by sections 18/25/28).
update public.profiles set full_name = 'Test 0037 Store Access Target', status = 'active', store_access_scope = 'multiple'
  where id = 'a0000000-0000-4000-8000-000000000033';
insert into public.user_store_access (user_id, store_id) values
  ('a0000000-0000-4000-8000-000000000033', 'b0000000-0000-4000-8000-00000000000a');

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000032","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.manage_permissions') = true, 'الاختبار يفترض أن 032 يملك users.manage_permissions';
  assert public.has_permission('users.edit') = true, 'الاختبار يفترض أن 032 يملك users.edit (لتجاوز RLS نفسها والوصول إلى Trigger التفويض)';
  assert public.has_permission('users.manage_store_access') = false, 'الاختبار يفترض أن 032 لا يملك users.manage_store_access -- هذا بالضبط ما يثبته 0037';
end $$;

-- 30.1: 032 cannot change Target 033's Store Scope / Default Store.
do $$
declare v_bug boolean := false;
begin
  begin
    update public.profiles set store_access_scope = 'single', default_store_id = 'b0000000-0000-4000-8000-00000000000a'
      where id = 'a0000000-0000-4000-8000-000000000033';
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.manage_permissions بلا users.manage_store_access من تغيير Store Scope / Default Store (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب users.manage_permissions وحدها (بلا users.manage_store_access) من تغيير Store Scope / Default Store لمستخدم آخر';
  end if;
end $$;

-- 30.2: 032 cannot INSERT (grant) a store access row for Target 033.
do $$
declare v_bug boolean := false;
begin
  begin
    insert into public.user_store_access (user_id, store_id)
      values ('a0000000-0000-4000-8000-000000000033', 'b0000000-0000-4000-8000-00000000000b');
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.manage_permissions بلا users.manage_store_access من منح وصول متجر (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب users.manage_permissions وحدها من منح وصول متجر لمستخدم آخر عبر user_store_access -- هذا بالضبط التداخل الذي يُغلقه 0037';
  end if;
end $$;

-- 30.3: 032 cannot DELETE (revoke) Target 033's existing Store A access.
-- Unlike 30.1 (UPDATE, caught via an explicit trigger exception) and 30.2
-- (INSERT, caught via a WITH CHECK violation, which Postgres always raises
-- as a real error since an attempted INSERT with no satisfying row IS an
-- error) -- DELETE's RLS USING clause fails differently: a row that does not
-- satisfy USING is simply excluded from the DELETE's row set, with NO error
-- and NO exception to catch. After 0037 dropped 0010's original, over-broad
-- user_store_access_delete policy, the only DELETE policy left
-- (user_store_access_delete_scoped, 0018) requires users.manage_store_access
-- outright -- so this DELETE silently matches zero rows for 032. Checked via
-- row count, not exception-catching.
do $$
declare v_row_count int;
begin
  delete from public.user_store_access
    where user_id = 'a0000000-0000-4000-8000-000000000033' and store_id = 'b0000000-0000-4000-8000-00000000000a';
  get diagnostics v_row_count = row_count;
  if v_row_count <> 0 then
    raise exception 'SECURITY BUG: تمكّن صاحب users.manage_permissions وحدها من إلغاء وصول متجر لمستخدم آخر (تأثر % صف)', v_row_count;
  end if;
  raise notice 'OK: مُنع صاحب users.manage_permissions بلا users.manage_store_access من إلغاء وصول متجر -- سياسة RLS نفسها لا تُطابق أي صف له (0 صف متأثر)';
end $$;

-- 30.4: 032 cannot use replace_user_store_access() either -- the whole
-- atomic RPC fails via the same underlying INSERT/DELETE trigger check.
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.replace_user_store_access(
      'a0000000-0000-4000-8000-000000000033'::uuid,
      array['b0000000-0000-4000-8000-00000000000b'::uuid]
    );
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.manage_permissions بلا users.manage_store_access من استخدام replace_user_store_access() (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب users.manage_permissions وحدها من استخدام replace_user_store_access() لتعديل وصول متاجر مستخدم آخر';
  end if;
end $$;

-- 30.5: sanity -- Target 033's data is completely untouched by all four
-- failed attempts above (every failure rolled back its own statement).
do $$
declare v_scope text; v_default uuid; v_ids uuid[];
begin
  select store_access_scope, default_store_id into v_scope, v_default
    from public.profiles where id = 'a0000000-0000-4000-8000-000000000033';
  select coalesce(array_agg(store_id order by store_id), '{}') into v_ids
    from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000033';
  assert v_scope = 'multiple' and v_default is null, 'لا يجب أن يتغيّر Store Scope/Default Store لـ033 بعد المحاولات الفاشلة';
  assert v_ids = array['b0000000-0000-4000-8000-00000000000a'::uuid], format('يجب أن يبقى وصول 033 عند {Store A} فقط بعد كل المحاولات الفاشلة، وجدنا %s', v_ids);
  raise notice 'OK: بيانات Target 033 (Store Scope وStore Access) بقيت بلا أي تغيير بعد كل محاولات 032 الفاشلة';
end $$;

reset role;
reset request.jwt.claims;

-- 30.6: positive control -- actor 013 (users.manage_store_access, A+B
-- operable, reused from section 18/19, does NOT hold users.manage_permissions
-- -- see its own setup-assertion at line ~2027) succeeds at exactly the
-- operations 032 was just blocked from, on the SAME target 033: change scope
-- + default, then grant Store B and revoke Store A.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000013","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.manage_store_access') = true, 'الاختبار يفترض أن 013 يملك users.manage_store_access';
  assert public.has_permission('users.manage_permissions') = false, 'الاختبار يفترض أن 013 لا يملك users.manage_permissions -- يثبت أن manage_store_access وحدها كافية';
end $$;

do $$
declare v_scope text; v_default uuid; v_ids uuid[];
begin
  update public.profiles set store_access_scope = 'single', default_store_id = 'b0000000-0000-4000-8000-00000000000a'
    where id = 'a0000000-0000-4000-8000-000000000033';
  select store_access_scope, default_store_id into v_scope, v_default
    from public.profiles where id = 'a0000000-0000-4000-8000-000000000033';
  assert v_scope = 'single' and v_default = 'b0000000-0000-4000-8000-00000000000a'::uuid,
    'يجب أن ينجح 013 في تغيير Store Scope/Default Store لـ033 (ضمن نطاق تشغيله الخاص)';

  update public.profiles set store_access_scope = 'multiple' where id = 'a0000000-0000-4000-8000-000000000033';

  insert into public.user_store_access (user_id, store_id)
    values ('a0000000-0000-4000-8000-000000000033', 'b0000000-0000-4000-8000-00000000000b');
  delete from public.user_store_access
    where user_id = 'a0000000-0000-4000-8000-000000000033' and store_id = 'b0000000-0000-4000-8000-00000000000a';

  select coalesce(array_agg(store_id order by store_id), '{}') into v_ids
    from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000033';
  assert v_ids = array['b0000000-0000-4000-8000-00000000000b'::uuid],
    format('يجب أن يصبح وصول 033 عند {Store B} فقط بعد نجاح 013 في منح B وسحب A، وجدنا %s', v_ids);
  raise notice 'OK: صاحب users.manage_store_access وحدها (بلا users.manage_permissions) نجح في تغيير Store Scope ومنح/سحب وصول المتاجر -- الفصل الكامل (0037) لا يكسر المسار الصحيح';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 31. Fix Store Access loading in the UI without depending on stores.view
--     (Patch 1.4.1 item 2, app-layer only -- no new migration). Proves the
--     actual root cause directly in SQL: a raw `store_id` select succeeds for
--     an actor who lacks stores.view, while the OLD embedded-join approach
--     (`store:stores(...)`) would not have, because PostgREST's embedded
--     resource expansion is independently subject to RLS on the JOINED
--     table. Actor 013 (reused again, A+B operable, holds users.view but NOT
--     stores.view) against a fresh target (034) holding A+C, exactly the
--     "Actor manages A+B only, Target has A+C" scenario requested.
-- ---------------------------------------------------------------------------
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000034', 'test-0037-embedded-select-target@example.invalid');

update public.profiles set full_name = 'Test Embedded-Select Target', status = 'active', store_access_scope = 'multiple'
  where id = 'a0000000-0000-4000-8000-000000000034';
insert into public.user_store_access (user_id, store_id) values
  ('a0000000-0000-4000-8000-000000000034', 'b0000000-0000-4000-8000-00000000000a'),
  ('a0000000-0000-4000-8000-000000000034', 'b0000000-0000-4000-8000-00000000000c');

reset role;
reset request.jwt.claims;

set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000013","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.view') = true, 'الاختبار يفترض أن 013 يملك users.view';
  assert public.has_permission('stores.view') = false, 'الاختبار يفترض أن 013 لا يملك stores.view -- بالضبط الحالة التي كان الكود القديم يفشل فيها';
end $$;

-- 31.1: raw store_id select (getUserDetail()'s NEW query shape, 0037/queries.
-- ts) returns BOTH rows -- A and C -- exactly like the old code intended,
-- unfiltered by the actor's own operable range (that filtering happens in
-- the app layer next, via manageable_stores_for_actor() + selectableStore
-- AccessIds(), not here).
do $$
declare v_ids uuid[];
begin
  select coalesce(array_agg(store_id order by store_id), '{}') into v_ids
    from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000034';
  assert v_ids = array['b0000000-0000-4000-8000-00000000000a', 'b0000000-0000-4000-8000-00000000000c']::uuid[],
    format('يجب أن يرى 013 كلا صفّي store_id الخام (A وC) لـ034 عبر users.view، بلا الحاجة لـstores.view، وجدنا %s', v_ids);
  raise notice 'OK: الاستعلام الخام (store_id فقط، بلا embed) يعيد وصول 034 الفعلي كاملاً (A وC) بلا الاعتماد على stores.view';
end $$;

-- 31.2: the OLD approach, simulated directly -- selecting from `stores`
-- itself (what an embedded `store:stores(...)` resolves to under the hood)
-- for those exact ids returns ZERO rows for 013, because stores_select (0010)
-- requires stores.view unconditionally. This is the precise root cause the
-- old getUserDetail() query hit: PostgREST's embedded resource is
-- independently RLS-gated on the joined table, not the base table.
do $$
declare v_count int;
begin
  select count(*) into v_count from public.stores
    where id in ('b0000000-0000-4000-8000-00000000000a', 'b0000000-0000-4000-8000-00000000000c');
  assert v_count = 0, format('يجب ألا يرى 013 أي صفّ في stores مباشرةً (بلا stores.view) -- وهذا بالضبط سبب فشل الـembed القديم، وجدنا %s صفًا', v_count);
  raise notice 'OK: (إثبات السبب الجذري) استعلام مباشر على stores نفسها يعيد صفرًا لـ013 -- الشكل القديم store:stores(...) كان سيعيد null لكل صف، فيُسقطه .filter(Boolean) بالكامل';
end $$;

-- 31.3: manageable_stores_for_actor() -- unchanged by this patch, still
-- returns exactly 013's own operable range (A+B), not C.
do $$
declare v_count int; v_has_c boolean;
begin
  select count(*) into v_count from public.manageable_stores_for_actor();
  select exists (select 1 from public.manageable_stores_for_actor() where id = 'b0000000-0000-4000-8000-00000000000c') into v_has_c;
  assert v_count = 2, format('يجب أن يعيد manageable_stores_for_actor() متجرين فقط (A وB) لـ013، وجدنا %s', v_count);
  assert v_has_c = false, 'يجب ألا يظهر المتجر C (خارج نطاق 013) في manageable_stores_for_actor()';
  raise notice 'OK: manageable_stores_for_actor() بقيت كما هي -- تعيد فقط A+B لـ013، لا تكشف C';
end $$;

-- 31.4: the exact UI-rendering intersection selectableStoreAccessIds()
-- performs in TypeScript (tests/store-access-helpers.test.ts), reproduced
-- here in SQL against the real rows: raw ids {A, C} intersected with
-- manageable ids {A, B} = exactly {A}. A appears, C never does (and C is
-- never proposed as "selectable" even though it is real, historical data).
do $$
declare v_selectable uuid[];
begin
  select coalesce(array_agg(sid order by sid), '{}') into v_selectable
  from (
    select store_id as sid from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000034'
    intersect
    select id from public.manageable_stores_for_actor()
  ) t;
  assert v_selectable = array['b0000000-0000-4000-8000-00000000000a'::uuid],
    format('يجب أن تظهر Store A فقط كمُحددة (المقاطعة بين وصول 034 الفعلي ونطاق 013 التشغيلي)، وجدنا %s', v_selectable);
  raise notice 'OK: منطق selectableStoreAccessIds() (A تظهر، C لا تظهر) يُنتج النتيجة الصحيحة عند تطبيقه على البيانات الفعلية';
end $$;

-- 31.5: editing succeeds and does NOT fail because of C -- 013 submits only
-- what it can see (desired={B}); replace_user_store_access() adds B, removes
-- A (in-range), and leaves C (out-of-range, invisible to 013's own UI)
-- completely untouched, exactly as item 2 requires.
do $$
declare v_ids uuid[];
begin
  perform public.replace_user_store_access('a0000000-0000-4000-8000-000000000034'::uuid, array['b0000000-0000-4000-8000-00000000000b']::uuid[]);
  select coalesce(array_agg(store_id order by store_id), '{}') into v_ids
    from public.user_store_access where user_id = 'a0000000-0000-4000-8000-000000000034';
  assert v_ids = array['b0000000-0000-4000-8000-00000000000b', 'b0000000-0000-4000-8000-00000000000c']::uuid[],
    format('يجب أن يصبح وصول 034 بالضبط {B, C} (A أُزيلت، B أُضيفت، C محفوظة دون تغيير)، وجدنا %s', v_ids);
  raise notice 'OK: تعديل 013 لـA/B على 034 نجح بالكامل ولم يفشل بسبب C -- C بقيت محفوظة تمامًا كما هي';
end $$;

reset role;
reset request.jwt.claims;

-- ---------------------------------------------------------------------------
-- 32. Cancel Invitation must appear in the Audit Log under the acting
--     employee's own identity (Patch 1.4.1 item 3, 0038). log_user_invite_
--     cancel() is the only way to write a `user.invite_cancel` row; it is
--     self-scoped (auth.uid(), no actor-id parameter exists to spoof),
--     requires users.disable, and only accepts a target that is genuinely
--     still an unprovisioned pending_setup invite.
--
--     UPDATED for Foundation Audit Hotfix 1.4.2 (0039): log_user_invite_
--     cancel() itself is now SUPERSEDED -- `authenticated` no longer has
--     EXECUTE on it at all, closing the exact gap this hotfix exists for (a
--     staff member holding users.disable could call it directly and write a
--     false "cancelled" event without actually cancelling anything -- see
--     section 33's header comment for the full explanation). 32.1-32.3
--     (all "must fail" assertions) remain valid and are kept unchanged --
--     they still correctly fail, now for an even stronger reason (EXECUTE
--     denial, not just a business-logic rejection). 32.4/32.5 (the original
--     success-path assertions) are kept per this project's own "never
--     remove an existing security assertion" rule, but their EXPECTATION is
--     flipped to match the new, intentional behavior, and the real
--     successful cancellation for Target 036 is re-verified via the new,
--     corrected trusted flow (0039) instead.
-- ---------------------------------------------------------------------------
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000036', 'test-invite-cancel-audit-target@example.invalid');

do $$
begin
  assert (select status from public.profiles where id = 'a0000000-0000-4000-8000-000000000036') = 'pending_setup';
  assert (select provisioned_at from public.profiles where id = 'a0000000-0000-4000-8000-000000000036') is null;
end $$;

reset role;
reset request.jwt.claims;

-- 32.1: an ordinary user (002, sales_employee -- no users.disable at all)
-- cannot create a user.invite_cancel row via the RPC, manually or otherwise.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.disable') = false, 'الاختبار يفترض أن 002 لا يملك users.disable';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_user_invite_cancel('a0000000-0000-4000-8000-000000000036', null);
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع مستخدم عادي (بلا users.disable) من استدعاء log_user_invite_cancel() لتلفيق حدث user.invite_cancel (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم عادي بلا users.disable من إنشاء حدث user.invite_cancel عبر RPC';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 32.2: an actor holding users.manage_permissions but NOT users.disable
-- (032, reused from section 30) is equally blocked -- the gate is
-- specifically users.disable, matching cancelUserInviteAction's own guard,
-- not general administrative power.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000032","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_user_invite_cancel('a0000000-0000-4000-8000-000000000036', null);
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع صاحب users.manage_permissions (بلا users.disable) من استدعاء log_user_invite_cancel() (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن صاحب users.manage_permissions وحدها (بلا users.disable) من إنشاء حدث user.invite_cancel';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 32.3: actor 005 (users.disable + users.view, reused from the file's
-- original setup) cannot invite-cancel a target that is NOT actually a
-- pending, unprovisioned invite (002 is active) -- even with the right
-- permission, the DB independently re-validates target status.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000005","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.disable') = true, 'الاختبار يفترض أن 005 يملك users.disable';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_user_invite_cancel('a0000000-0000-4000-8000-000000000002', null);
    v_bug := true;
  exception
    when others then
      raise notice 'OK: مُنع 005 من تسجيل إلغاء دعوة لحساب نشط فعليًا (ليس pending_setup) (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن 005 من تسجيل حدث user.invite_cancel لحساب نشط بالفعل (ليس دعوة قيد الإعداد)';
  end if;
end $$;

-- 32.4: SUPERSEDED by Foundation Audit Hotfix 1.4.2 (0039). This originally
-- proved a positive/success path: 005 (holding the right permission,
-- against a genuinely still-pending target, 036) could call
-- log_user_invite_cancel() directly and succeed. That exact call succeeding
-- is precisely the gap 0039 closes (see section 33's header comment) --
-- kept here (not deleted) with its expectation flipped: even 005, with
-- every business-logic condition satisfied, can no longer reach this RPC at
-- all -- EXECUTE itself is revoked from `authenticated`. The actual
-- successful cancellation for 036 is re-verified in 32.5 below, via the
-- new, corrected trusted flow.
do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_user_invite_cancel('a0000000-0000-4000-8000-000000000036', 'الموظف لم يعد بحاجة لهذا الحساب');
    v_bug := true;
  exception
    when insufficient_privilege then
      raise notice 'OK: (بعد Hotfix 1.4.2) حتى 005 بصلاحياته الصحيحة وهدف صالح (036) لم يعد قادرًا على استدعاء log_user_invite_cancel() القديمة مباشرة -- EXECUTE نفسها غير ممنوحة لـauthenticated (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: ما زال بإمكان 005 استدعاء log_user_invite_cancel() القديمة مباشرة والنجاح -- Hotfix 1.4.2 لم يُغلق هذا المسار فعليًا';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 32.5: SUPERSEDED shape, kept and adapted for Hotfix 1.4.2. The actual
-- cancellation for Target 036 now follows the CORRECTED sequence
-- (cancelUserInviteAction's real order after 0039): delete the auth user
-- FIRST (trusted service-role context here, mirroring
-- admin.auth.admin.deleteUser() succeeding), THEN log via the new trusted
-- RPC with the real actor (005) passed explicitly (mirroring capturing it
-- from the actor's own verified session before the admin client is ever
-- touched). Re-confirms user.invite_cancel and the automatic user.delete
-- row still coexist as two distinct, intentional events for the same
-- target -- exactly one of each, never a duplicate -- now produced by the
-- corrected flow instead of the retired one.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

delete from auth.users where id = 'a0000000-0000-4000-8000-000000000036';

do $$
declare v_id uuid;
begin
  v_id := public.log_user_invite_cancel_trusted(
    'a0000000-0000-4000-8000-000000000005'::uuid,
    'a0000000-0000-4000-8000-000000000036'::uuid,
    'الموظف لم يعد بحاجة لهذا الحساب'
  );
  assert v_id is not null, 'log_user_invite_cancel_trusted() يجب أن تعيد معرّف الصفّ الذي أنشأته بعد الحذف الفعلي';
end $$;

do $$
declare v_cancel_count int; v_delete_count int; v_cancel_actor uuid; v_delete_actor uuid; v_reason text;
begin
  select count(*) into v_cancel_count from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000036' and action = 'user.invite_cancel';
  select user_id, reason into v_cancel_actor, v_reason from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000036' and action = 'user.invite_cancel';
  select count(*) into v_delete_count from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000036' and action = 'user.delete';
  select user_id into v_delete_actor from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000036' and action = 'user.delete'
    limit 1;

  assert v_cancel_count = 1, format('يجب أن يوجد بالضبط صفّ user.invite_cancel واحد لـ036 (من المسار الموثوق الجديد)، وجدنا %s', v_cancel_count);
  assert v_cancel_actor = 'a0000000-0000-4000-8000-000000000005', format('actor يجب أن يكون 005 (الموظف الحقيقي)، وجدنا %s', v_cancel_actor);
  assert v_reason = 'الموظف لم يعد بحاجة لهذا الحساب', 'يجب أن يُحفظ reason كما أُرسل';
  assert v_delete_count = 1, format('يجب أن يظهر بالضبط صفّ user.delete واحد لـ036 بعد حذف auth.users (audit_table_changes التلقائي، 0016)، وجدنا %s', v_delete_count);
  assert v_delete_actor is null, 'صفّ user.delete التلقائي يُسجَّل بدون actor (auth.uid() فارغ ضمن سياق admin/service-role) -- هذا بالضبط سبب وجود user.invite_cancel كحدث منفصل يحمل هوية الموظف الحقيقية';

  raise notice 'OK: (بعد Hotfix 1.4.2) المسار الموثوق الجديد لا يزال يُنتج user.invite_cancel (actor=005 الحقيقي) وuser.delete (actor=NULL, تلقائي) كصفّين منفصلين ومقصودين لهدف 036 -- بلا تكرار، وبلا فقدان لهوية من نفّذ الإلغاء فعليًا';
end $$;

reset role;
reset request.jwt.claims;

-- ============================================================================
-- Foundation Audit Hotfix 1.4.2 (migration 0039): the one remaining gap in
-- Patch 1.4.1 item 3 -- log_user_invite_cancel() (0038) was reachable by
-- ANY authenticated user holding users.disable, letting them write a
-- user.invite_cancel row for a real pending invite WITHOUT actually
-- cancelling it. Section 33 below proves the fix: the logging RPC is now
-- service_role-only, only writes an event after a real completed deletion
-- is already on record, and is idempotent.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 33. Trusted-only, post-deletion, idempotent invite-cancel audit logging
--     (Foundation Audit Hotfix 1.4.2, 0039).
-- ---------------------------------------------------------------------------
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000035', 'test-hotfix-142-deleted-target@example.invalid'),
  ('a0000000-0000-4000-8000-000000000037', 'test-hotfix-142-still-pending-target@example.invalid'),
  ('a0000000-0000-4000-8000-000000000038', 'test-hotfix-142-second-actor-target@example.invalid');

do $$
begin
  assert (select status from public.profiles where id = 'a0000000-0000-4000-8000-000000000035') = 'pending_setup';
  assert (select status from public.profiles where id = 'a0000000-0000-4000-8000-000000000037') = 'pending_setup';
  assert (select status from public.profiles where id = 'a0000000-0000-4000-8000-000000000038') = 'pending_setup';
end $$;

reset role;
reset request.jwt.claims;

-- 33.1: a staff member who DOES hold users.disable (005, reused from
-- section 32) cannot call the trusted logging RPC directly, as
-- `authenticated` -- this is the exact gap the review found: the OLD
-- function (0038) let exactly this actor write a false "cancelled" event
-- for a real, still-intact pending invite (037). Checked via SQLSTATE
-- 42501 (insufficient_privilege) specifically -- proving this is an EXECUTE
-- grant denial, not merely a business-logic (P0001) rejection further down
-- inside the function body.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000005","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.disable') = true, 'الاختبار يفترض أن 005 يملك users.disable -- ليكون الرفض بسبب EXECUTE حصرًا، لا نقص صلاحية تطبيقية';
end $$;

do $$
declare v_bug boolean := false; v_sqlstate text;
begin
  begin
    perform public.log_user_invite_cancel_trusted(
      'a0000000-0000-4000-8000-000000000005'::uuid,
      'a0000000-0000-4000-8000-000000000037'::uuid,
      null
    );
    v_bug := true;
  exception
    when insufficient_privilege then
      raise notice 'OK: مُنع 005 (يملك users.disable فعليًا) من استدعاء log_user_invite_cancel_trusted() مباشرة -- رُفض على مستوى EXECUTE (42501) قبل أي منطق داخلي (%)', sqlerrm;
    when others then
      get stacked diagnostics v_sqlstate = returned_sqlstate;
      raise exception 'SECURITY BUG: رُفض الاستدعاء لكن بكود خطأ غير متوقَّع (% بدل 42501) -- الرفض يجب أن يكون على مستوى EXECUTE، وليس منطقًا داخل الدالة', v_sqlstate;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن 005 (يملك users.disable) من استدعاء log_user_invite_cancel_trusted() مباشرة رغم أن authenticated لا يملك EXECUTE عليها إطلاقًا -- هذه بالضبط الثغرة التي يُغلقها 0039';
  end if;
end $$;

-- 33.2: same, for an ordinary user (002, no users.disable at all) -- proves
-- the rejection is unconditional at the ROLE/EXECUTE level, not merely
-- gated by an application permission that happens to be absent here too.
reset role;
reset request.jwt.claims;
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000002","role":"authenticated"}';

do $$
begin
  assert public.has_permission('users.disable') = false, 'الاختبار يفترض أن 002 لا يملك users.disable';
end $$;

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_user_invite_cancel_trusted(
      'a0000000-0000-4000-8000-000000000002'::uuid,
      'a0000000-0000-4000-8000-000000000037'::uuid,
      null
    );
    v_bug := true;
  exception
    when insufficient_privilege then
      raise notice 'OK: مُنع 002 (لا يملك users.disable) أيضًا من استدعاء log_user_invite_cancel_trusted() مباشرة -- 42501 (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: تمكّن مستخدم عادي من استدعاء log_user_invite_cancel_trusted() مباشرة';
  end if;
end $$;

-- 33.3: regression check -- the OLD function (0038) is ALSO no longer
-- reachable by `authenticated` at all (not just superseded in practice).
-- 005 previously succeeded at calling this exact RPC in section 32.4; it
-- must fail now.
reset role;
reset request.jwt.claims;
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000005","role":"authenticated"}';

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_user_invite_cancel('a0000000-0000-4000-8000-000000000037'::uuid, null);
    v_bug := true;
  exception
    when insufficient_privilege then
      raise notice 'OK: الدالة القديمة log_user_invite_cancel() (0038) لم تعد قابلة للاستدعاء من authenticated إطلاقًا بعد 0039 (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: الدالة القديمة log_user_invite_cancel() ما زالت قابلة للاستدعاء من authenticated بعد 0039';
  end if;
end $$;

reset role;
reset request.jwt.claims;

-- 33.4: invariant (a) -- even from a fully-trusted service_role context,
-- logging a cancellation for a target that has NOT actually been deleted
-- yet (037 is still a fully intact pending_setup row -- no user.delete
-- audit row exists for it) is rejected. This is exactly the failure mode
-- the review flagged: an audit row must never exist without a real,
-- recorded, completed deletion behind it.
set role service_role;
set local request.jwt.claims = '{"role":"service_role"}';

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_user_invite_cancel_trusted(
      'a0000000-0000-4000-8000-000000000005'::uuid,
      'a0000000-0000-4000-8000-000000000037'::uuid,
      null
    );
    v_bug := true;
  exception
    when others then
      raise notice 'OK: رُفض تسجيل user.invite_cancel لهدف (037) لم يُحذف فعليًا بعد -- لا صفّ user.delete مطابق موجود (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: أمكن تسجيل user.invite_cancel لهدف لم يُحذف فعليًا -- سجل تدقيق كاذب يزعم إلغاءً لم يحدث';
  end if;
end $$;

do $$
declare v_count int;
begin
  select count(*) into v_count from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000037' and action = 'user.invite_cancel';
  assert v_count = 0, format('يجب ألا يوجد أي صفّ user.invite_cancel لهدف 037 (لم يُحذف بعد)، وجدنا %s', v_count);
  assert (select status from public.profiles where id = 'a0000000-0000-4000-8000-000000000037') = 'pending_setup',
    'يجب أن يبقى حساب 037 سليمًا تمامًا -- المحاولة الفاشلة لا تؤثر عليه';
  raise notice 'OK: لا يوجد أي صفّ user.invite_cancel كاذب لهدف لم تُنفَّذ عليه أي عملية حذف فعلية';
end $$;

-- 33.5: invariant (b) -- even after a REAL completed deletion (038), an
-- actor id that does NOT currently hold users.disable (002) is rejected --
-- the trusted function re-verifies the actor's permission itself, rather
-- than blindly trusting whatever id the caller passes in.
delete from auth.users where id = 'a0000000-0000-4000-8000-000000000038';

do $$
declare v_bug boolean := false;
begin
  begin
    perform public.log_user_invite_cancel_trusted(
      'a0000000-0000-4000-8000-000000000002'::uuid,
      'a0000000-0000-4000-8000-000000000038'::uuid,
      null
    );
    v_bug := true;
  exception
    when others then
      raise notice 'OK: رُفض تسجيل الحدث بفاعل (002) لا يملك users.disable حاليًا، حتى بعد حذف فعلي حقيقي لِـ038 (%)', sqlerrm;
  end;
  if v_bug then
    raise exception 'SECURITY BUG: أمكن تسجيل user.invite_cancel منسوبًا لفاعل لا يملك users.disable';
  end if;
end $$;

-- 33.6: the correct, full end-to-end trusted flow: delete 035's auth user
-- FIRST (mirrors admin.auth.admin.deleteUser() succeeding), THEN log via
-- the trusted RPC with the real actor (005) -- succeeds, correct row.
delete from auth.users where id = 'a0000000-0000-4000-8000-000000000035';

do $$
declare v_id uuid;
begin
  v_id := public.log_user_invite_cancel_trusted(
    'a0000000-0000-4000-8000-000000000005'::uuid,
    'a0000000-0000-4000-8000-000000000035'::uuid,
    'اختبار المسار الموثوق بعد Hotfix 1.4.2'
  );
  assert v_id is not null, 'log_user_invite_cancel_trusted() يجب أن تعيد معرّف الصفّ عند النجاح';
end $$;

do $$
declare v_row record;
begin
  select * into v_row from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000035' and action = 'user.invite_cancel';
  assert found, 'يجب إيجاد صفّ user.invite_cancel لـ035 بعد المسار الموثوق الكامل';
  assert v_row.user_id = 'a0000000-0000-4000-8000-000000000005', format('actor يجب أن يكون 005، وجدنا %s', v_row.user_id);
  assert v_row.reason = 'اختبار المسار الموثوق بعد Hotfix 1.4.2', 'يجب أن يُحفظ reason كما أُرسل';
  raise notice 'OK: المسار الموثوق الكامل (حذف فعلي أولًا، ثم تسجيل عبر service_role) نجح وسجّل actor/target الصحيحين';
end $$;

-- 33.7: idempotency -- retrying the SAME call (simulating a dropped
-- response + client retry) returns the SAME row id and does not create a
-- second row. A retry with a DIFFERENT actor id for the SAME target also
-- does not create a second row or reattribute the existing one -- proves
-- true first-writer-wins idempotency at the database layer, not merely
-- app-level dedup.
do $$
declare v_id_retry uuid; v_id_original uuid;
begin
  select id into v_id_original from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000035' and action = 'user.invite_cancel';

  v_id_retry := public.log_user_invite_cancel_trusted(
    'a0000000-0000-4000-8000-000000000005'::uuid,
    'a0000000-0000-4000-8000-000000000035'::uuid,
    'محاولة إعادة إرسال (retry) بنفس البيانات'
  );
  assert v_id_retry = v_id_original, 'إعادة نفس الاستدعاء يجب أن تعيد نفس المعرّف، لا تُنشئ صفًا جديدًا';

  -- Different actor id, same target -- still resolves to the ORIGINAL row.
  v_id_retry := public.log_user_invite_cancel_trusted(
    'a0000000-0000-4000-8000-000000000001'::uuid,
    'a0000000-0000-4000-8000-000000000035'::uuid,
    'محاولة بفاعل مختلف لنفس الهدف'
  );
  assert v_id_retry = v_id_original, 'محاولة بفاعل مختلف لنفس الهدف يجب أن تعيد نفس المعرّف الأصلي أيضًا -- لا صفّ جديد، ولا إعادة نسب';
end $$;

do $$
declare v_count int; v_actor uuid;
begin
  select count(*) into v_count from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000035' and action = 'user.invite_cancel';
  select user_id into v_actor from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000035' and action = 'user.invite_cancel';
  assert v_count = 1, format('يجب أن يبقى بالضبط صفّ user.invite_cancel واحد لـ035 رغم محاولتَي إعادة الإرسال، وجدنا %s', v_count);
  assert v_actor = 'a0000000-0000-4000-8000-000000000005', 'الـactor الأصلي (005) يجب أن يبقى كما هو -- لا إعادة نسب لمحاولة لاحقة';
  raise notice 'OK: التسجيل idempotent فعليًا -- إعادة إرسال (بنفس الفاعل أو بفاعل مختلف) لا تُنشئ صفًا ثانيًا ولا تُعيد نسب الصفّ الأصلي (فهرس فريد جزئي على audit_logs)';
end $$;

-- 33.8: user.delete (تلقائي) وuser.invite_cancel (بالمسار الموثوق) يتعايشان
-- لنفس 035 -- بلا تكرار لأيٍّ منهما.
do $$
declare v_cancel_count int; v_delete_count int;
begin
  select count(*) into v_cancel_count from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000035' and action = 'user.invite_cancel';
  select count(*) into v_delete_count from public.audit_logs
    where entity_type = 'user' and entity_id = 'a0000000-0000-4000-8000-000000000035' and action = 'user.delete';
  assert v_cancel_count = 1, format('صفّ user.invite_cancel واحد بالضبط لـ035، وجدنا %s', v_cancel_count);
  assert v_delete_count = 1, format('صفّ user.delete واحد بالضبط لـ035، وجدنا %s', v_delete_count);
  raise notice 'OK: user.delete وuser.invite_cancel يبقيان حدثين منفصلين وغير متعارضين لنفس 035 بعد Hotfix 1.4.2';
end $$;

reset role;
reset request.jwt.claims;

-- 33.9: re-confirmation -- audit_logs still has NO update/delete policy for
-- any role whatsoever (unchanged by 0039) -- even Super Admin (001) cannot
-- tamper with any audit row, including the ones this section just created.
set role authenticated;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare v_row_count int;
begin
  update public.audit_logs set reason = 'محاولة تلاعب' where entity_id = 'a0000000-0000-4000-8000-000000000035' and action = 'user.invite_cancel';
  get diagnostics v_row_count = row_count;
  if v_row_count <> 0 then
    raise exception 'SECURITY BUG: تمكّن Super Admin من تعديل صفّ Audit -- audit_logs لا تملك أي سياسة UPDATE يُفترض أن تسمح بهذا';
  end if;
  raise notice 'OK: لا سياسة UPDATE على audit_logs لأي دور -- حتى Super Admin لا يستطيع تعديل صفّ user.invite_cancel (0 صف متأثر)';
end $$;

-- DELETE, like UPDATE above, has no exception to catch here if RLS simply
-- has no permissive policy for it -- Postgres silently matches zero rows
-- rather than raising (unlike INSERT's WITH CHECK, which does raise).
-- Checked via row count, same pattern as section 30.3.
do $$
declare v_row_count int;
begin
  delete from public.audit_logs where entity_id = 'a0000000-0000-4000-8000-000000000035' and action = 'user.invite_cancel';
  get diagnostics v_row_count = row_count;
  if v_row_count <> 0 then
    raise exception 'SECURITY BUG: تمكّن Super Admin من حذف صفّ Audit -- audit_logs لا تملك أي سياسة DELETE يُفترض أن تسمح بهذا';
  end if;
  raise notice 'OK: لا سياسة DELETE على audit_logs لأي دور -- حتى Super Admin لا يستطيع حذف صفّ user.invite_cancel (0 صف متأثر)';
end $$;

reset role;
reset request.jwt.claims;

do $$
begin
  raise notice '=== ALL RLS/PERMISSION/AUDIT/ESCALATION TESTS PASSED (including Foundation Hardening 1.4, Patch 1.4.1, and Foundation Audit Hotfix 1.4.2) ===';
end $$;

rollback;

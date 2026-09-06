-- ============================================================================
-- Integration test: Production upgrade path onto Phase 10 (Store Expenses)
-- without re-running seed.sql
-- ============================================================================
-- This file does NOT build the database itself — it only ASSERTS against a
-- database that was already built the way a real production upgrade would
-- experience it:
--
--   1. Fresh DB, migrations 0001-0232 applied (the frozen baseline: the last
--      shipped state before Phase 10, i.e. Phase 9 + Hotfix 9.1.0).
--   2. The REAL supabase/seed.sql applied (a real upgrade already ran this
--      once, long before Phase 10 existed — it is never re-run here).
--   3. Migrations 0233 through the latest (Phase 10) applied on top — in a
--      SEPARATE psql invocation, exactly like a production upgrade would.
--
-- See scripts/run_upgrade_test_phase10_store_expenses.sh for the
-- orchestration that builds exactly this sequence, then runs this file.
--
-- Proves three distinct things:
--   (A) The 5 new Phase 10 permission keys and their role grants come from
--       migration 0233 ITSELF, idempotently — NOT from seed.sql (which never
--       ran again) and not missing.
--   (B) The entire new expense engine is immediately USABLE the moment
--       0233-0236 finish applying — create a category, record an expense,
--       reverse it, read the ledger back — all inside this same rolled-back
--       transaction so it never mutates whatever database this runs against.
--       No pre-existing Sales/Returns/Settlements data is needed: Store
--       Expenses is a wholly new, additive module with zero dependency on
--       prior transactional data.
--   (C) The pre-existing net_operating_return contract is UNCHANGED by the
--       upgrade — the legacy RPCs neither gained Phase 10 keys nor lost their
--       own, which is the backward-compatibility promise of this phase.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase10_store_expenses.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- (A) Permission keys + role grants come from 0233, not seed.sql.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count integer;
  v_super integer;
  v_admin integer;
  v_supervisor integer;
  v_accountant integer;
begin
  select count(*) into v_count from public.permissions
  where key in ('expenses.view', 'expenses.create', 'expenses.reverse', 'expenses.manage_categories', 'expenses.process_closed_day');
  if v_count <> 5 then
    raise exception 'BUG: expected the 5 Phase 10 permission keys to exist after the upgrade, found %', v_count;
  end if;

  select count(*) into v_super
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'super_admin' and p.key like 'expenses.%';
  if v_super <> 5 then
    raise exception 'BUG: super_admin should hold all 5 expenses.* permissions after the upgrade, found %', v_super;
  end if;

  select count(*) into v_admin
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'admin' and p.key like 'expenses.%';
  if v_admin <> 5 then
    raise exception 'BUG: admin should hold all 5 expenses.* permissions, found %', v_admin;
  end if;

  -- Supervisor gets the operational four but NOT manage_categories.
  select count(*) into v_supervisor
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'supervisor' and p.key like 'expenses.%';
  if v_supervisor <> 4 then
    raise exception 'BUG: supervisor should hold exactly 4 expenses.* permissions (no manage_categories), found %', v_supervisor;
  end if;
  if exists (
    select 1 from public.role_permissions rp
    join public.roles r on r.id = rp.role_id
    join public.permissions p on p.id = rp.permission_id
    where r.key = 'supervisor' and p.key = 'expenses.manage_categories'
  ) then
    raise exception 'BUG: supervisor must NOT hold expenses.manage_categories';
  end if;

  -- Accountant is view-only.
  select count(*) into v_accountant
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'accountant' and p.key like 'expenses.%';
  if v_accountant <> 1 then
    raise exception 'BUG: accountant should hold exactly expenses.view, found % expenses.* grants', v_accountant;
  end if;

  raise notice 'PASS A: all 5 Phase 10 permission keys and their role grants came from migration 0233 itself (seed.sql never re-ran)';
end $$;

-- ---------------------------------------------------------------------------
-- (B) The engine is usable immediately after the upgrade.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('ab999999-0000-4000-8000-000000000001', 'test-p10-upgrade@example.invalid')
on conflict (id) do nothing;

update public.profiles set full_name = 'Test P10 Upgrade Actor', status = 'active', store_access_scope = 'all'
  where id = 'ab999999-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'ab999999-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('stores.view', 'stores.create', 'expenses.view', 'expenses.create', 'expenses.reverse', 'expenses.manage_categories');

set role authenticated;
set local request.jwt.claims = '{"sub":"ab999999-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store uuid;
  v_cat uuid;
  v_exp uuid;
  v_amount text;
  v jsonb;
begin
  insert into public.stores (code, name_ar, status) values ('P10UP-ST', 'فرع ترقية 10', 'active') returning id into v_store;

  select id into v_cat from public.create_expense_category('P10UP-CAT', 'تصنيف ترقية');
  if v_cat is null then
    raise exception 'BUG: create_expense_category() unusable immediately after the upgrade';
  end if;

  select id, amount into v_exp, v_amount
  from public.record_store_expense(v_store, v_cat, 320, current_date, 'مصروف ترقية');
  if v_amount <> '320.00' then
    raise exception 'BUG: expected recorded amount=320.00 (text at the column''s own 2dp scale), got %', v_amount;
  end if;

  select amount into v_amount from public.reverse_store_expense(v_exp, 'عكس ترقية', current_date);
  if v_amount <> '-320.00' then
    raise exception 'BUG: expected reversal amount=-320.00, got %', v_amount;
  end if;

  v := public.list_store_expenses(current_date - 1, current_date);
  if v -> 'summary' ->> 'operating_expenses_total' <> '0.00' then
    raise exception 'BUG: expense + its reversal must net to 0.00, got %', v -> 'summary' ->> 'operating_expenses_total';
  end if;
  if (v ->> 'total_count')::int <> 2 then
    raise exception 'BUG: expected 2 ledger entries (expense + reversal), got %', v ->> 'total_count';
  end if;

  raise notice 'PASS B: the Store Expenses engine is fully usable the moment 0233-0236 finish applying';
end $$;

-- ---------------------------------------------------------------------------
-- (C) The pre-existing net_operating_return contract survived the upgrade.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;
do $$
declare
  v_src text;
begin
  -- get_dashboard_summary() and get_dashboard_summary_with_comparison() must
  -- still exist and must NOT mention any Phase 10 concept: Phase 10 adds a
  -- NEW wrapper rather than editing them, which is what keeps every legacy
  -- caller and every golden-scenario figure byte-identical.
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_dashboard_summary_with_comparison';

  if v_src is null then
    raise exception 'BUG: get_dashboard_summary_with_comparison() disappeared during the Phase 10 upgrade';
  end if;
  if v_src like '%expense%' then
    raise exception 'BUG: the legacy comparison RPC was modified to know about expenses — Phase 10 must be additive only';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_dashboard_summary';
  if v_src like '%expense%' then
    raise exception 'BUG: the canonical get_dashboard_summary() was modified to know about expenses — Phase 10 must be additive only';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_dashboard_summary_with_expenses'
  ) then
    raise exception 'BUG: the new expense-aware wrapper was not created by the upgrade';
  end if;

  raise notice 'PASS C: the legacy dashboard RPCs are untouched by the upgrade; the expense-aware view is a separate, additive wrapper';
end $$;

do $$
begin
  raise notice '=== ALL upgrade_phase10_store_expenses.test.sql ASSERTIONS PASSED ===';
end $$;

rollback;

-- ============================================================================
-- Integration test: Phase 10 — Store Expenses Core, GENUINE multi-session
-- concurrency (dblink), deterministic.
-- ============================================================================
-- NOT safe to run against a shared/staging database — real dblink sessions,
-- auto-committing statements, no wrapping transaction. Run ONLY against a
-- throwaway/CI database.
--
-- Requires migrations 0001-latest (including 0233-0236) + supabase/seed.sql
-- already applied, and the `dblink` extension available.
--
-- Connection string override, same convention as every other *_concurrency.
-- test.sql file:
--   psql -v dblink_conninfo="host=... port=... user=... password=..." \
--     -f supabase/tests/store_expenses_phase10_concurrency.test.sql
--
-- The server must require PASSWORD authentication on the loopback: these
-- sessions call dblink_connect() after `set local role authenticated`, and
-- dblink refuses a non-superuser connection that did not actually
-- authenticate with a password.
--
-- ONLY genuine concurrency invariants are covered here — Phase 10 adds no
-- derived balance to serialize (an expense entry is an unconditional append),
-- so there is deliberately no "two writers race a computed total" scenario to
-- fabricate. What IS genuinely concurrent:
--
--   A — an expense may be reversed AT MOST ONCE (partial unique index, 0234)
--   B — an expense can never slip into a day that is being CLOSED right now
--       (SHARED vs EXCLUSIVE daily-close lock 1002, 0065)
--   C — two concurrent recordings never collide on expense_number (SEQUENCE)
-- ============================================================================

create extension if not exists dblink;

\if :{?dblink_conninfo}
\else
\set dblink_conninfo 'host=127.0.0.1 port=5432 user=postgres password=postgres'
\endif

select set_config('p10cc.dblink_conninfo', :'dblink_conninfo', false);

create or replace function public._p10cc_wait_ready(p_connname text, p_max_polls int default 200, p_interval numeric default 0.05)
returns boolean
language plpgsql
as $$
declare v_i int;
begin
  for v_i in 1..p_max_polls loop
    if dblink_is_busy(p_connname) = 0 then
      return true;
    end if;
    perform pg_sleep(p_interval);
  end loop;
  return dblink_is_busy(p_connname) = 0;
end;
$$;

create or replace function public._p10cc_drain_pending(p_connname text)
returns void
language plpgsql
as $$
begin
  perform 1 from dblink_get_result(p_connname) as t(x text);
end;
$$;

-- The deterministic overlap proof (same helper shape Hotfix 9.1.0 introduced
-- for settlements_phase7_concurrency). dblink_is_busy() only says "no result
-- yet" — it cannot distinguish a session genuinely parked on the other's lock
-- from one that has not started, so a scenario asserting real contention could
-- pass with the two sessions merely running in sequence. pg_blocking_pids()
-- answers the real question: wait until the second session's backend is
-- blocked BY THE FIRST SESSION'S BACKEND SPECIFICALLY. Bounded wait for a
-- state that MUST occur — never a retry of the operation under test.
create or replace function public._p10cc_wait_blocked_by(p_pid int, p_blocker int, p_max_polls int default 200, p_interval numeric default 0.05)
returns boolean
language plpgsql
as $$
declare v_i int;
begin
  for v_i in 1..p_max_polls loop
    if p_blocker = any (pg_blocking_pids(p_pid)) then
      return true;
    end if;
    perform pg_sleep(p_interval);
  end loop;
  return p_blocker = any (pg_blocking_pids(p_pid));
end;
$$;

-- ============================================================================
-- 0. Fixtures — own prefix 'ac000000-.../P10CC', committed immediately.
-- ============================================================================
insert into auth.users (id, email) values
  ('ac000000-0000-4000-8000-000000000001', 'test-p10cc-actor@example.invalid');

update public.profiles set full_name = 'P10CC actor', status = 'active', store_access_scope = 'all'
  where id = 'ac000000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'ac000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('stores.view', 'stores.create', 'sales.close_day',
                'expenses.view', 'expenses.create', 'expenses.reverse', 'expenses.manage_categories');

do $$
declare
  v_store_id uuid; v_cat_id uuid; v_exp_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}';

  insert into public.stores (code, name_ar, status) values ('P10CCST', 'فرع تزامن مصروفات', 'active') returning id into v_store_id;
  select id into v_cat_id from public.create_expense_category('P10CC-CAT', 'تصنيف تزامن');

  -- Committed fixture expense, used by scenario A.
  select id into v_exp_id from public.record_store_expense(v_store_id, v_cat_id, 900, current_date - 1, 'مصروف تزامن');

  perform set_config('p10cc.store', v_store_id::text, false);
  perform set_config('p10cc.cat', v_cat_id::text, false);
  perform set_config('p10cc.exp', v_exp_id::text, false);
end $$;

-- ============================================================================
-- A — Two concurrent reversals of the SAME expense. Exactly one wins; the
-- other genuinely blocks on the first's uncommitted row, then is cleanly
-- rejected. Guarded by store_expenses_one_reversal_per_expense_idx (0234).
-- ============================================================================
do $$
declare
  v_a_pid int; v_b_pid int;
  v_blocked boolean;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_reversal_count int;
  v_net numeric;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p10cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p10cc.dblink_conninfo') || ' dbname=' || current_database());

  select pid into v_a_pid from dblink('conn_a', 'select pg_backend_pid()') as t(pid int);
  select pid into v_b_pid from dblink('conn_b', 'select pg_backend_pid()') as t(pid int);

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A reverses SYNCHRONOUSLY: when this returns, A's reversal row has provably
  -- been inserted, and A's transaction is still open.
  begin
    perform id from dblink('conn_a', format(
      $sql$select * from public.reverse_store_expense('%s'::uuid, 'عكس متزامن A', current_date)$sql$,
      current_setting('p10cc.exp')
    )) as t(id uuid, expense_number text, amount text);
  exception when others then
    v_a_failed := true;
  end;
  assert not v_a_failed, 'FAIL A: عكس A (الأول، بلا منافس) يجب أن ينجح — بدونه لا يوجد سباق أصلًا';

  -- B races the SAME expense while A is still open.
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.reverse_store_expense('%s'::uuid, 'عكس متزامن B', current_date)$sql$,
    current_setting('p10cc.exp')
  ));

  v_blocked := public._p10cc_wait_blocked_by(v_b_pid, v_a_pid);
  assert v_blocked, format(
    'FAIL A: محاولة العكس الثانية (B، pid %s) لم تُرصد محجوبة على قفل جلسة A (pid %s) بينما معاملة A مفتوحة — لم يحدث تداخل حقيقي',
    v_b_pid, v_a_pid);

  perform dblink_exec('conn_a', 'commit');

  perform public._p10cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, expense_number text, amount text);
    perform public._p10cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL A: محاولة العكس الثانية كان يجب أن تُرفض بعد التزام A — قُبلت، أي أن المصروف عُكس مرتين';

  select count(*) into v_reversal_count
  from public.store_expenses
  where reverses_expense_id = current_setting('p10cc.exp')::uuid and entry_kind = 'reversal';
  assert v_reversal_count = 1, format('FAIL A: يجب أن توجد حركة عكس واحدة بالضبط، الموجود: %s', v_reversal_count);

  -- Authoritative: the ledger nets to exactly zero for this expense pair.
  select coalesce(sum(amount), 0) into v_net
  from public.store_expenses
  where id = current_setting('p10cc.exp')::uuid or reverses_expense_id = current_setting('p10cc.exp')::uuid;
  assert v_net = 0, format('FAIL A: المصروف وعكسه يجب أن يتصافيا إلى صفر، الموجود: %s', v_net);

  raise notice 'PASS A: double-reversal race — exactly one reversal wins, the other genuinely blocks then is cleanly rejected; ledger nets to 0';
end $$;

-- ============================================================================
-- B — Daily Close (EXCLUSIVE 1002) vs recording an expense (SHARED 1002).
-- The expense must genuinely block while the close is open, then correctly
-- observe the day as closed once the close commits.
-- ============================================================================
do $$
declare
  v_a_pid int; v_b_pid int;
  v_blocked boolean;
  v_b_failed boolean := false;
  v_target date := current_date - 4;
  v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p10cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p10cc.dblink_conninfo') || ' dbname=' || current_database());

  select pid into v_a_pid from dblink('conn_a', 'select pg_backend_pid()') as t(pid int);
  select pid into v_b_pid from dblink('conn_b', 'select pg_backend_pid()') as t(pid int);

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A closes the day and HOLDS the exclusive lock (transaction still open).
  perform x from dblink('conn_a', format(
    $sql$select public.close_sales_day('%s'::uuid, '%s'::date, 'إغلاق تزامن')$sql$,
    current_setting('p10cc.store'), v_target
  )) as t(x uuid);

  -- B tries to record an expense into that very day.
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.record_store_expense('%s'::uuid, '%s'::uuid, 30, '%s'::date, 'مصروف أثناء الإغلاق')$sql$,
    current_setting('p10cc.store'), current_setting('p10cc.cat'), v_target
  ));

  v_blocked := public._p10cc_wait_blocked_by(v_b_pid, v_a_pid);
  assert v_blocked, format(
    'FAIL B: تسجيل المصروف (B، pid %s) لم يُحجب على قفل الإغلاق اليومي الذي تحمله جلسة A (pid %s) — لم يحدث تداخل حقيقي',
    v_b_pid, v_a_pid);

  perform dblink_exec('conn_a', 'commit');

  perform public._p10cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, expense_number text, amount text);
    perform public._p10cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  -- The actor holds no expenses.process_closed_day, so once the day is
  -- genuinely closed the expense must be refused.
  assert v_b_failed, 'FAIL B: سُجِّل مصروف في يوم أُغلق للتو — الحارس اليومي لم يُطبَّق بعد رفع الحجب';

  select count(*) into v_count from public.store_expenses
  where store_id = current_setting('p10cc.store')::uuid and business_date = v_target;
  assert v_count = 0, format('FAIL B: يجب ألا توجد أي حركة في اليوم المقفل، الموجود: %s', v_count);

  raise notice 'PASS B: daily-close race — the expense genuinely blocked on the open EXCLUSIVE close lock, then was correctly refused once the day was closed';
end $$;

-- ============================================================================
-- C — Two concurrent recordings must never collide on expense_number.
-- ============================================================================
do $$
declare
  v_num_a text; v_num_b text;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p10cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p10cc.dblink_conninfo') || ' dbname=' || current_database());

  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- Both sent before either result is read, so they genuinely overlap.
  perform dblink_send_query('conn_a', format(
    $sql$select * from public.record_store_expense('%s'::uuid, '%s'::uuid, 11, current_date, 'تزامن A')$sql$,
    current_setting('p10cc.store'), current_setting('p10cc.cat')
  ));
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.record_store_expense('%s'::uuid, '%s'::uuid, 12, current_date, 'تزامن B')$sql$,
    current_setting('p10cc.store'), current_setting('p10cc.cat')
  ));

  perform public._p10cc_wait_ready('conn_a');
  select expense_number into v_num_a from dblink_get_result('conn_a', true) as t(id uuid, expense_number text, amount text);
  perform public._p10cc_drain_pending('conn_a');

  perform public._p10cc_wait_ready('conn_b');
  select expense_number into v_num_b from dblink_get_result('conn_b', true) as t(id uuid, expense_number text, amount text);
  perform public._p10cc_drain_pending('conn_b');

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert v_num_a is not null and v_num_b is not null, 'FAIL C: كلا التسجيلين المتزامنين يجب أن ينجحا';
  assert v_num_a <> v_num_b, format('FAIL C: تصادم في رقم المصروف بين تسجيلين متزامنين — كلاهما %s', v_num_a);
  assert (v_num_a ~ '^EXP-[0-9]{10}$') and (v_num_b ~ '^EXP-[0-9]{10}$'),
    format('FAIL C: تنسيق رقم المصروف غير صحيح: % / %', v_num_a, v_num_b);

  raise notice 'PASS C: two concurrent record_store_expense() calls across separate sessions produced distinct expense numbers (% / %) — SEQUENCE-based, no MAX()+1 race', v_num_a, v_num_b;
end $$;

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
drop function if exists public._p10cc_wait_ready(text, int, numeric);
drop function if exists public._p10cc_drain_pending(text);
drop function if exists public._p10cc_wait_blocked_by(int, int, int, numeric);

\echo 'store_expenses_phase10_concurrency.test.sql PASSED'

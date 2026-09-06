-- ============================================================================
-- Integration test: Phase 11 — Purchases & Suppliers Core, GENUINE
-- multi-session concurrency (dblink), deterministic.
-- ============================================================================
-- NOT safe to run against a shared/staging database — real dblink sessions,
-- auto-committing statements, no wrapping transaction. Run ONLY against a
-- throwaway/CI database.
--
-- Requires migrations 0001-latest (including 0237-0240) + supabase/seed.sql
-- already applied, and the `dblink` extension available.
--
-- Connection string override, same convention as every other *_concurrency.
-- test.sql file:
--   psql -v dblink_conninfo="host=... port=... user=... password=..." \
--     -f supabase/tests/purchases_phase11_concurrency.test.sql
--
-- The server must require PASSWORD authentication on the loopback: these
-- sessions call dblink_connect() after `set local role authenticated`, and
-- dblink refuses a non-superuser connection that did not actually
-- authenticate with a password.
--
-- Every scenario below is a REAL contention proof: the second session is sent
-- while the first session's transaction is still open, and the test asserts —
-- via pg_blocking_pids() — that the second backend is blocked BY THE FIRST
-- BACKEND SPECIFICALLY before the first commits. A scenario that merely ran
-- the two operations in sequence would fail that assertion. No scenario is
-- "proved" by pg_sleep alone.
--
--   A — the same supplier invoice number can never be posted twice
--   B — inventory posting genuinely serializes on PHASE 9's 1008 lock, and no
--       quantity is posted twice or partially
--   C — an invoice can be reversed AT MOST ONCE
--   D — two payments racing the SAME remaining balance can never jointly
--       exceed it
--   E — a payment and an invoice reversal can never interleave
--   F — nothing slips into a day that is being CLOSED right now
-- ============================================================================

create extension if not exists dblink;

\if :{?dblink_conninfo}
\else
\set dblink_conninfo 'host=127.0.0.1 port=5432 user=postgres password=postgres'
\endif

select set_config('p11cc.dblink_conninfo', :'dblink_conninfo', false);

create or replace function public._p11cc_wait_ready(p_connname text, p_max_polls int default 200, p_interval numeric default 0.05)
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

create or replace function public._p11cc_drain_pending(p_connname text)
returns void
language plpgsql
as $$
begin
  perform 1 from dblink_get_result(p_connname) as t(x text);
end;
$$;

-- The deterministic overlap proof (Hotfix 9.1.0's helper shape).
-- dblink_is_busy() only says "no result yet" — it cannot distinguish a session
-- genuinely parked on the other's lock from one that has not started, so a
-- scenario asserting real contention could pass with the two sessions merely
-- running in sequence. pg_blocking_pids() answers the real question: wait
-- until the second session's backend is blocked BY THE FIRST SESSION'S BACKEND
-- SPECIFICALLY. Bounded wait for a state that MUST occur — never a retry of
-- the operation under test.
create or replace function public._p11cc_wait_blocked_by(p_pid int, p_blocker int, p_max_polls int default 200, p_interval numeric default 0.05)
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
-- 0. Fixtures — own prefix 'bb000000-.../P11CC', committed immediately.
-- ============================================================================
insert into auth.users (id, email) values
  ('bb000000-0000-4000-8000-000000000001', 'test-p11cc-actor@example.invalid');

update public.profiles set full_name = 'P11CC actor', status = 'active', store_access_scope = 'all'
  where id = 'bb000000-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'bb000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('stores.view', 'stores.create', 'sales.close_day',
                'categories.view', 'categories.manage', 'karats.view', 'karats.manage',
                'inventory.view', 'inventory.receive',
                'purchases.view', 'purchases.create', 'purchases.reverse',
                'purchases.record_payment', 'purchases.reverse_payment', 'purchases.manage_suppliers');

do $$
declare
  v_store uuid; v_cat uuid; v_karat uuid; v_item uuid; v_item2 uuid; v_sup uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}';

  insert into public.stores (code, name_ar, status) values ('P11CCST', 'فرع تزامن مشتريات', 'active') returning id into v_store;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p11cccat', 'تصنيف تزامن مشتريات', 982, 'active') returning id into v_cat;
  insert into public.karats (code, name_ar, sort_order, status) values ('P11CCK', 'عيار تزامن مشتريات', 982, 'active') returning id into v_karat;

  select id into v_item from public.create_inventory_item('P11CC-SKU', 'صنف تزامن مشتريات', v_cat, v_karat, 'gram', null);
  -- A SECOND item, so scenario G can exercise a multi-line invoice holding
  -- more than one 1008 lock at once.
  select id into v_item2 from public.create_inventory_item('P11CC-SKU2', 'صنف تزامن مشتريات 2', v_cat, v_karat, 'gram', null);
  select id into v_sup from public.create_supplier('P11CC-SUP', 'مورّد التزامن', 'Concurrency Supplier', '300000000000003');

  perform set_config('p11cc.store', v_store::text, false);
  perform set_config('p11cc.item', v_item::text, false);
  perform set_config('p11cc.item2', v_item2::text, false);
  perform set_config('p11cc.supplier', v_sup::text, false);
end $$;

-- A single-line invoice body, reused throughout: 4 units @ 100 net + 15% VAT.
select set_config('p11cc.lines', format(
  '[{"inventory_item_id":"%s","quantity":4,"unit_net_cost":100,"tax_treatment":"standard","tax_rate_percent":15,"net_amount":400,"vat_amount":60,"gross_amount":460}]',
  current_setting('p11cc.item')
), false);

-- The invoices raced in C, D and E must be COMMITTED before those scenarios
-- run: the dblink sessions are separate backends and cannot see a row still
-- uncommitted in this session's transaction. Each top-level statement in psql
-- is its own transaction, so posting them in a standalone DO block — rather
-- than at the top of each scenario — is what makes them visible.
do $$
declare v_id uuid;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select id into v_id from public.post_purchase_invoice(
    current_setting('p11cc.supplier')::uuid, current_setting('p11cc.store')::uuid,
    current_setting('p11cc.lines')::jsonb, 400, 60, 460, current_date, 'REV-RACE');
  perform set_config('p11cc.inv_c', v_id::text, false);

  select id into v_id from public.post_purchase_invoice(
    current_setting('p11cc.supplier')::uuid, current_setting('p11cc.store')::uuid,
    current_setting('p11cc.lines')::jsonb, 400, 60, 460, current_date, 'PAY-RACE');
  perform set_config('p11cc.inv_d', v_id::text, false);

  select id into v_id from public.post_purchase_invoice(
    current_setting('p11cc.supplier')::uuid, current_setting('p11cc.store')::uuid,
    current_setting('p11cc.lines')::jsonb, 400, 60, 460, current_date, 'PAY-VS-REV');
  perform set_config('p11cc.inv_e', v_id::text, false);

  -- Scenario H pays into a day that is closed mid-flight, so this invoice must
  -- be dated on or before that day: a payment may not precede its invoice.
  select id into v_id from public.post_purchase_invoice(
    current_setting('p11cc.supplier')::uuid, current_setting('p11cc.store')::uuid,
    current_setting('p11cc.lines')::jsonb, 400, 60, 460, current_date - 7, 'CLOSE-VS-PAY');
  perform set_config('p11cc.inv_h', v_id::text, false);
end $$;

-- ============================================================================
-- A — The SAME supplier invoice number posted concurrently, twice. Exactly one
-- survives; the loser genuinely blocks on the winner's uncommitted index entry
-- (purchase_invoices_supplier_invoice_number_idx, 0238), then is rejected.
-- ============================================================================
do $$
declare
  v_a_pid int; v_b_pid int;
  v_blocked boolean;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());

  select pid into v_a_pid from dblink('conn_a', 'select pg_backend_pid()') as t(pid int);
  select pid into v_b_pid from dblink('conn_b', 'select pg_backend_pid()') as t(pid int);

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A posts SYNCHRONOUSLY and holds its transaction open.
  begin
    perform id from dblink('conn_a', format(
      $sql$select * from public.post_purchase_invoice('%s'::uuid, '%s'::uuid, '%s'::jsonb, 400, 60, 460, current_date, 'DUP-001')$sql$,
      current_setting('p11cc.supplier'), current_setting('p11cc.store'), current_setting('p11cc.lines')
    )) as t(id uuid, purchase_number text, gross_total text);
  exception when others then
    v_a_failed := true;
  end;
  assert not v_a_failed, 'FAIL A: ترحيل A (الأول، بلا منافس) يجب أن ينجح — بدونه لا يوجد سباق أصلًا';

  -- B posts the SAME supplier invoice number while A is still open.
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.post_purchase_invoice('%s'::uuid, '%s'::uuid, '%s'::jsonb, 400, 60, 460, current_date, 'DUP-001')$sql$,
    current_setting('p11cc.supplier'), current_setting('p11cc.store'), current_setting('p11cc.lines')
  ));

  v_blocked := public._p11cc_wait_blocked_by(v_b_pid, v_a_pid);
  assert v_blocked, format(
    'FAIL A: الترحيل الثاني (B، pid %s) لم يُرصد محجوبًا على فهرس جلسة A (pid %s) بينما معاملة A مفتوحة — لم يحدث تداخل حقيقي',
    v_b_pid, v_a_pid);

  perform dblink_exec('conn_a', 'commit');

  perform public._p11cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, purchase_number text, gross_total text);
    perform public._p11cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL A: قُبل رقم فاتورة مورّد مكرر بعد التزام A — نفس المستند رُحِّل مرتين';

  select count(*) into v_count from public.purchase_invoices
  where supplier_id = current_setting('p11cc.supplier')::uuid and supplier_invoice_number = 'DUP-001';
  assert v_count = 1, format('FAIL A: يجب أن توجد فاتورة واحدة بالضبط بالرقم DUP-001، الموجود: %s', v_count);

  raise notice 'PASS A: duplicate supplier invoice number — the second poster genuinely blocked on the first, then was cleanly rejected';
end $$;

-- ============================================================================
-- B — Inventory posting serializes on PHASE 9's OWN 1008 item/store lock.
-- Two invoices for the SAME item and store overlap. The second must be seen
-- blocked by the first, both must succeed once the first commits, and the
-- resulting balance must be the EXACT sum — never doubled, never partial.
-- ============================================================================
do $$
declare
  v_a_pid int; v_b_pid int;
  v_blocked boolean;
  v_before numeric; v_after numeric;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_moves int; v_lines int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}';

  select coalesce(sum(quantity_delta), 0) into v_before
  from public.inventory_stock_movements
  where item_id = current_setting('p11cc.item')::uuid and store_id = current_setting('p11cc.store')::uuid;

  perform dblink_connect('conn_a', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());

  select pid into v_a_pid from dblink('conn_a', 'select pg_backend_pid()') as t(pid int);
  select pid into v_b_pid from dblink('conn_b', 'select pg_backend_pid()') as t(pid int);

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  begin
    perform id from dblink('conn_a', format(
      $sql$select * from public.post_purchase_invoice('%s'::uuid, '%s'::uuid, '%s'::jsonb, 400, 60, 460, current_date, 'LOCK-A')$sql$,
      current_setting('p11cc.supplier'), current_setting('p11cc.store'), current_setting('p11cc.lines')
    )) as t(id uuid, purchase_number text, gross_total text);
  exception when others then
    v_a_failed := true;
  end;
  assert not v_a_failed, 'FAIL B: ترحيل A يجب أن ينجح';

  perform dblink_send_query('conn_b', format(
    $sql$select * from public.post_purchase_invoice('%s'::uuid, '%s'::uuid, '%s'::jsonb, 400, 60, 460, current_date, 'LOCK-B')$sql$,
    current_setting('p11cc.supplier'), current_setting('p11cc.store'), current_setting('p11cc.lines')
  ));

  -- The two invoices share no row and no unique key — the ONLY thing that can
  -- block B here is the 1008 advisory lock that Phase 9's
  -- record_inventory_stock_movement() takes on (item, store). This assertion
  -- is therefore a direct proof that purchases post through that engine and
  -- inherit its serialization, rather than writing movements themselves.
  v_blocked := public._p11cc_wait_blocked_by(v_b_pid, v_a_pid);
  assert v_blocked, format(
    'FAIL B: الترحيل الثاني (B، pid %s) لم يُحجب على قفل المخزون 1008 الذي تحمله جلسة A (pid %s) — الشراء لا يمر عبر محرك المرحلة 9',
    v_b_pid, v_a_pid);

  perform dblink_exec('conn_a', 'commit');

  perform public._p11cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, purchase_number text, gross_total text);
    perform public._p11cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert not v_b_failed, 'FAIL B: الترحيل الثاني كان يجب أن ينجح بعد رفع الحجب — الفاتورتان مستقلتان';

  select coalesce(sum(quantity_delta), 0) into v_after
  from public.inventory_stock_movements
  where item_id = current_setting('p11cc.item')::uuid and store_id = current_setting('p11cc.store')::uuid;

  assert v_after = v_before + 8, format(
    'FAIL B: الرصيد يجب أن يزيد 8 بالضبط (4+4)، قبل=%s بعد=%s — ترحيل مزدوج أو جزئي للمخزون', v_before, v_after);

  -- Every line posted exactly one movement, and no movement is shared.
  select count(*), count(distinct l.inventory_movement_id) into v_lines, v_moves
  from public.purchase_invoice_lines l
  join public.purchase_invoices pi on pi.id = l.purchase_invoice_id
  where pi.supplier_invoice_number in ('LOCK-A', 'LOCK-B');
  assert v_lines = 2 and v_moves = 2, format(
    'FAIL B: يجب أن يقابل كل بند حركة مخزون فريدة — بنود=%s حركات مميزة=%s', v_lines, v_moves);

  raise notice 'PASS B: inventory posting genuinely blocked on Phase 9''s 1008 item/store lock; balance moved by exactly 8, one unique movement per line';
end $$;

-- ============================================================================
-- C — Two concurrent reversals of the SAME invoice. Exactly one wins.
-- Guarded by purchase_invoices_one_reversal_idx (0238) and the FOR UPDATE row
-- lock in reverse_purchase_invoice (0239).
-- ============================================================================
do $$
declare
  v_a_pid int; v_b_pid int;
  v_blocked boolean;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_inv uuid; v_count int; v_net numeric;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}';

  v_inv := current_setting('p11cc.inv_c')::uuid;

  perform dblink_connect('conn_a', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());

  select pid into v_a_pid from dblink('conn_a', 'select pg_backend_pid()') as t(pid int);
  select pid into v_b_pid from dblink('conn_b', 'select pg_backend_pid()') as t(pid int);

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  begin
    perform id from dblink('conn_a', format(
      $sql$select * from public.reverse_purchase_invoice('%s'::uuid, 'عكس متزامن A', current_date)$sql$,
      v_inv
    )) as t(id uuid, purchase_number text, gross_total text);
  exception when others then
    v_a_failed := true;
  end;
  assert not v_a_failed, 'FAIL C: عكس A (الأول، بلا منافس) يجب أن ينجح';

  perform dblink_send_query('conn_b', format(
    $sql$select * from public.reverse_purchase_invoice('%s'::uuid, 'عكس متزامن B', current_date)$sql$,
    v_inv
  ));

  v_blocked := public._p11cc_wait_blocked_by(v_b_pid, v_a_pid);
  assert v_blocked, format(
    'FAIL C: محاولة العكس الثانية (B، pid %s) لم تُرصد محجوبة على قفل صف جلسة A (pid %s) — لم يحدث تداخل حقيقي',
    v_b_pid, v_a_pid);

  perform dblink_exec('conn_a', 'commit');

  perform public._p11cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, purchase_number text, gross_total text);
    perform public._p11cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL C: عُكست الفاتورة مرتين';

  select count(*) into v_count from public.purchase_invoices
  where reverses_invoice_id = v_inv and entry_kind = 'reversal';
  assert v_count = 1, format('FAIL C: يجب أن يوجد مستند عكس واحد بالضبط، الموجود: %s', v_count);

  -- Authoritative: the document pair nets to zero, in money AND in stock.
  select coalesce(sum(gross_total), 0) into v_net from public.purchase_invoices
  where id = v_inv or reverses_invoice_id = v_inv;
  assert v_net = 0, format('FAIL C: الفاتورة وعكسها يجب أن يتصافيا إلى صفر، الموجود: %s', v_net);

  select coalesce(sum(m.quantity_delta), 0) into v_net
  from public.purchase_invoice_lines l
  join public.inventory_stock_movements m on m.id = l.inventory_movement_id
  where l.purchase_invoice_id = v_inv
     or l.purchase_invoice_id in (select r.id from public.purchase_invoices r where r.reverses_invoice_id = v_inv);
  assert v_net = 0, format('FAIL C: حركات المخزون للفاتورة وعكسها يجب أن تتصافى إلى صفر، الموجود: %s', v_net);

  raise notice 'PASS C: double invoice reversal — exactly one won; money and stock both net to 0';
end $$;

-- ============================================================================
-- D — Two payments racing the SAME remaining balance. Together they would
-- exceed it; the FOR UPDATE row lock on the invoice (0239) must force them to
-- serialize so the second observes the first's payment and is refused.
-- ============================================================================
do $$
declare
  v_a_pid int; v_b_pid int;
  v_blocked boolean;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_inv uuid; v_paid numeric; v_gross numeric;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}';

  v_inv := current_setting('p11cc.inv_d')::uuid;

  perform dblink_connect('conn_a', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());

  select pid into v_a_pid from dblink('conn_a', 'select pg_backend_pid()') as t(pid int);
  select pid into v_b_pid from dblink('conn_b', 'select pg_backend_pid()') as t(pid int);

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- Each payment is 300; the invoice is only 460, so at most one can stand.
  begin
    perform id from dblink('conn_a', format(
      $sql$select * from public.record_supplier_payment('%s'::uuid, 300, 'cash')$sql$, v_inv
    )) as t(id uuid, payment_number text, amount text, outstanding_after text);
  exception when others then
    v_a_failed := true;
  end;
  assert not v_a_failed, 'FAIL D: دفعة A (الأولى، بلا منافس) يجب أن تنجح';

  perform dblink_send_query('conn_b', format(
    $sql$select * from public.record_supplier_payment('%s'::uuid, 300, 'cash')$sql$, v_inv
  ));

  v_blocked := public._p11cc_wait_blocked_by(v_b_pid, v_a_pid);
  assert v_blocked, format(
    'FAIL D: الدفعة الثانية (B، pid %s) لم تُرصد محجوبة على قفل صف الفاتورة الذي تحمله جلسة A (pid %s) — الدفعتان لم تتسلسلا فعليًا',
    v_b_pid, v_a_pid);

  perform dblink_exec('conn_a', 'commit');

  perform public._p11cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, payment_number text, amount text, outstanding_after text);
    perform public._p11cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL D: قُبلت الدفعة الثانية — مجموع المدفوعات تجاوز إجمالي الفاتورة';

  select coalesce(sum(amount), 0) into v_paid from public.supplier_payments where purchase_invoice_id = v_inv;
  select gross_total into v_gross from public.purchase_invoices where id = v_inv;
  assert v_paid = 300, format('FAIL D: المدفوع يجب أن يكون 300 بالضبط، الموجود: %s', v_paid);
  assert v_paid <= v_gross, format('FAIL D: المدفوع (%s) تجاوز إجمالي الفاتورة (%s)', v_paid, v_gross);

  raise notice 'PASS D: two payments racing the same remaining balance — the second genuinely blocked, then was refused; total paid never exceeded the invoice';
end $$;

-- ============================================================================
-- E — A payment and an INVOICE REVERSAL racing the same invoice. They must
-- never interleave: whichever commits first, the loser is refused.
-- Here A pays, B tries to reverse — B must block on A's row lock and then be
-- refused because an unreversed payment now exists.
-- ============================================================================
do $$
declare
  v_a_pid int; v_b_pid int;
  v_blocked boolean;
  v_a_failed boolean := false; v_b_failed boolean := false;
  v_inv uuid; v_rev int; v_paid numeric;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}';

  v_inv := current_setting('p11cc.inv_e')::uuid;

  perform dblink_connect('conn_a', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());

  select pid into v_a_pid from dblink('conn_a', 'select pg_backend_pid()') as t(pid int);
  select pid into v_b_pid from dblink('conn_b', 'select pg_backend_pid()') as t(pid int);

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  begin
    perform id from dblink('conn_a', format(
      $sql$select * from public.record_supplier_payment('%s'::uuid, 100, 'cash')$sql$, v_inv
    )) as t(id uuid, payment_number text, amount text, outstanding_after text);
  exception when others then
    v_a_failed := true;
  end;
  assert not v_a_failed, 'FAIL E: الدفعة A يجب أن تنجح';

  perform dblink_send_query('conn_b', format(
    $sql$select * from public.reverse_purchase_invoice('%s'::uuid, 'عكس أثناء الدفع', current_date)$sql$, v_inv
  ));

  v_blocked := public._p11cc_wait_blocked_by(v_b_pid, v_a_pid);
  assert v_blocked, format(
    'FAIL E: العكس (B، pid %s) لم يُرصد محجوبًا على قفل صف الفاتورة الذي تحمله جلسة الدفع A (pid %s) — لولا ذلك لأمكن عكس فاتورة ودفعها في آن واحد',
    v_b_pid, v_a_pid);

  perform dblink_exec('conn_a', 'commit');

  perform public._p11cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, purchase_number text, gross_total text);
    perform public._p11cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL E: عُكست فاتورة رغم وجود دفعة غير معكوسة التُزم بها للتو';

  select count(*) into v_rev from public.purchase_invoices where reverses_invoice_id = v_inv;
  assert v_rev = 0, format('FAIL E: يجب ألا يوجد أي مستند عكس، الموجود: %s', v_rev);

  select coalesce(sum(amount), 0) into v_paid from public.supplier_payments where purchase_invoice_id = v_inv;
  assert v_paid = 100, format('FAIL E: الدفعة الملتزم بها يجب أن تبقى 100، الموجود: %s', v_paid);

  raise notice 'PASS E: payment vs invoice reversal — the reversal genuinely blocked on the payment''s row lock, then was refused; neither operation was lost';
end $$;

-- ============================================================================
-- F — Daily Close (EXCLUSIVE 1002) vs posting a purchase (SHARED 1002).
-- The purchase must genuinely block while the close is open, then correctly
-- observe the day as closed once the close commits.
-- ============================================================================
do $$
declare
  v_a_pid int; v_b_pid int;
  v_blocked boolean;
  v_b_failed boolean := false;
  v_target date := current_date - 5;
  v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}';

  perform dblink_connect('conn_a', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());

  select pid into v_a_pid from dblink('conn_a', 'select pg_backend_pid()') as t(pid int);
  select pid into v_b_pid from dblink('conn_b', 'select pg_backend_pid()') as t(pid int);

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A closes the day and HOLDS the exclusive lock.
  perform x from dblink('conn_a', format(
    $sql$select public.close_sales_day('%s'::uuid, '%s'::date, 'إغلاق تزامن مشتريات')$sql$,
    current_setting('p11cc.store'), v_target
  )) as t(x uuid);

  perform dblink_send_query('conn_b', format(
    $sql$select * from public.post_purchase_invoice('%s'::uuid, '%s'::uuid, '%s'::jsonb, 400, 60, 460, '%s'::date, 'CLOSED-RACE')$sql$,
    current_setting('p11cc.supplier'), current_setting('p11cc.store'), current_setting('p11cc.lines'), v_target
  ));

  v_blocked := public._p11cc_wait_blocked_by(v_b_pid, v_a_pid);
  assert v_blocked, format(
    'FAIL F: ترحيل الشراء (B، pid %s) لم يُحجب على قفل الإغلاق اليومي الذي تحمله جلسة A (pid %s) — لم يحدث تداخل حقيقي',
    v_b_pid, v_a_pid);

  perform dblink_exec('conn_a', 'commit');

  perform public._p11cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, purchase_number text, gross_total text);
    perform public._p11cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  -- The actor holds no purchases.process_closed_day, so once the day is
  -- genuinely closed the purchase must be refused.
  assert v_b_failed, 'FAIL F: رُحِّلت فاتورة شراء في يوم أُغلق للتو — الحارس اليومي لم يُطبَّق بعد رفع الحجب';

  select count(*) into v_count from public.purchase_invoices
  where store_id = current_setting('p11cc.store')::uuid and business_date = v_target;
  assert v_count = 0, format('FAIL F: يجب ألا توجد أي فاتورة في اليوم المقفل، الموجود: %s', v_count);

  -- And crucially: no stock leaked in either. A partially-applied purchase —
  -- movements written but the invoice rolled back — is the exact failure this
  -- phase must never allow.
  select count(*) into v_count from public.inventory_stock_movements
  where store_id = current_setting('p11cc.store')::uuid and business_date = v_target;
  assert v_count = 0, format('FAIL F: تسربت %s حركة مخزون من فاتورة مرفوضة — الترحيل ليس ذريًا', v_count);

  raise notice 'PASS F: daily-close race — the purchase genuinely blocked on the open EXCLUSIVE close lock, was refused, and left neither an invoice nor a stock movement behind';
end $$;

-- ============================================================================
-- G — LOCK ORDERING. A multi-line invoice takes one 1008 lock PER LINE, so it
-- is the first thing in this codebase to hold several at once. If they were
-- acquired in client-supplied line order, two operators posting invoices that
-- share items in opposite orders would form a lock cycle and PostgreSQL would
-- abort one with 'deadlock detected' — a spurious failure of a valid purchase.
--
-- 0239 acquires them in canonical item-id order instead. This scenario proves
-- that directly: session A holds ONLY the lock that sorts FIRST, then B posts
-- an invoice whose lines are listed in the OPPOSITE order. Under canonical
-- ordering B must block on that first lock while holding NOTHING, so nothing
-- can ever wait on B. Under client ordering B would grab the second item's
-- lock before blocking — and that held lock is exactly the missing edge of a
-- deadlock cycle.
--
-- The assertion is on `pg_locks` directly rather than on a raced outcome, so
-- it is deterministic and it fails the moment the ordering loop is removed.
-- ============================================================================
do $$
declare
  v_a_pid int; v_b_pid int;
  v_blocked boolean; v_holds_other boolean;
  v_b_failed boolean := false;
  v_lo uuid; v_hi uuid; v_lines text;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}';

  v_lo := least(current_setting('p11cc.item')::uuid, current_setting('p11cc.item2')::uuid);
  v_hi := greatest(current_setting('p11cc.item')::uuid, current_setting('p11cc.item2')::uuid);

  -- Lines listed HIGH first — the reverse of the canonical order.
  v_lines := format(
    '[{"inventory_item_id":"%s","quantity":1,"unit_net_cost":100,"tax_treatment":"standard","tax_rate_percent":15,"net_amount":100,"vat_amount":15,"gross_amount":115},'
    '{"inventory_item_id":"%s","quantity":1,"unit_net_cost":100,"tax_treatment":"standard","tax_rate_percent":15,"net_amount":100,"vat_amount":15,"gross_amount":115}]',
    v_hi, v_lo);

  perform dblink_connect('conn_a', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());

  select pid into v_a_pid from dblink('conn_a', 'select pg_backend_pid()') as t(pid int);
  select pid into v_b_pid from dblink('conn_b', 'select pg_backend_pid()') as t(pid int);

  -- A holds ONLY the canonically-first item's lock, standing in for another
  -- purchase transaction that reached that item first.
  perform dblink_exec('conn_a', 'begin');
  perform x from dblink('conn_a', format(
    $sql$select pg_advisory_xact_lock(1008, hashtext('%s' || ':' || '%s'))$sql$,
    v_lo, current_setting('p11cc.store'))) as t(x text);

  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.post_purchase_invoice('%s'::uuid, '%s'::uuid, '%s'::jsonb, 200, 30, 230, current_date, 'LOCKORDER-B')$sql$,
    current_setting('p11cc.supplier'), current_setting('p11cc.store'), v_lines));

  v_blocked := public._p11cc_wait_blocked_by(v_b_pid, v_a_pid);
  assert v_blocked, format(
    'FAIL G: الترحيل (B، pid %s) لم يُرصد محجوبًا على قفل الصنف الأول الذي تحمله جلسة A (pid %s) — لم يحدث تداخل حقيقي',
    v_b_pid, v_a_pid);

  -- THE assertion: while blocked, B must hold NO other 1008 lock.
  select exists (
    select 1 from pg_locks l
    where l.locktype = 'advisory' and l.pid = v_b_pid and l.granted
      and l.classid = 1008
      and l.objid = hashtext(v_hi::text || ':' || current_setting('p11cc.store'))::bigint::int
  ) into v_holds_other;

  assert not v_holds_other, format(
    'FAIL G: الترحيل المحجوب يحمل بالفعل قفل الصنف الآخر (1008/%s) — الأقفال تُؤخذ بترتيب بنود العميل لا بترتيب قانوني، وهذه بالضبط الحافة الناقصة لدورة جمود بين فاتورتين متعددتَي البنود',
    v_hi);

  perform dblink_exec('conn_a', 'commit');

  perform public._p11cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, purchase_number text, gross_total text);
    perform public._p11cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert not v_b_failed, 'FAIL G: الترحيل كان يجب أن ينجح بعد تحرير القفل';

  raise notice 'PASS G: multi-line 1008 locks are acquired in canonical item order — a blocked posting holds no other item lock, so no cycle between two multi-line invoices is constructible';
end $$;

-- ============================================================================
-- H — Daily Close (EXCLUSIVE 1002) vs RECORDING A PAYMENT (SHARED 1002).
-- Scenario F proved the guard for invoice posting. The guard has four call
-- sites, and the payment path is the one that differs structurally: it takes a
-- ROW lock on the invoice BEFORE asking for the daily-close lock. That order
-- has to be proved, not assumed — it is also what makes a payment and a close
-- unable to interleave.
-- ============================================================================
do $$
declare
  v_a_pid int; v_b_pid int;
  v_blocked boolean;
  v_b_failed boolean := false;
  v_target date := current_date - 6;
  v_inv uuid;
  v_count int;
begin
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}';

  v_inv := current_setting('p11cc.inv_h')::uuid;

  perform dblink_connect('conn_a', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());
  perform dblink_connect('conn_b', current_setting('p11cc.dblink_conninfo') || ' dbname=' || current_database());

  select pid into v_a_pid from dblink('conn_a', 'select pg_backend_pid()') as t(pid int);
  select pid into v_b_pid from dblink('conn_b', 'select pg_backend_pid()') as t(pid int);

  perform dblink_exec('conn_a', 'begin');
  perform dblink_exec('conn_a', 'set role authenticated');
  perform dblink_exec('conn_a', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);
  perform dblink_exec('conn_b', 'set role authenticated');
  perform dblink_exec('conn_b', $sql$set request.jwt.claims = '{"sub":"bb000000-0000-4000-8000-000000000001","role":"authenticated"}'$sql$);

  -- A closes the day and HOLDS the exclusive lock.
  perform x from dblink('conn_a', format(
    $sql$select public.close_sales_day('%s'::uuid, '%s'::date, 'إغلاق تزامن دفعة')$sql$,
    current_setting('p11cc.store'), v_target
  )) as t(x uuid);

  -- B pays into that very day.
  perform dblink_send_query('conn_b', format(
    $sql$select * from public.record_supplier_payment('%s'::uuid, 50, 'cash', '%s'::date)$sql$, v_inv, v_target));

  v_blocked := public._p11cc_wait_blocked_by(v_b_pid, v_a_pid);
  assert v_blocked, format(
    'FAIL H: تسجيل الدفعة (B، pid %s) لم يُحجب على قفل الإغلاق اليومي الذي تحمله جلسة A (pid %s) — لم يحدث تداخل حقيقي',
    v_b_pid, v_a_pid);

  perform dblink_exec('conn_a', 'commit');

  perform public._p11cc_wait_ready('conn_b');
  begin
    perform id from dblink_get_result('conn_b', true) as t(id uuid, payment_number text, amount text, outstanding_after text);
    perform public._p11cc_drain_pending('conn_b');
  exception when others then
    v_b_failed := true;
  end;

  perform dblink_disconnect('conn_a');
  perform dblink_disconnect('conn_b');

  assert v_b_failed, 'FAIL H: سُجِّلت دفعة في يوم أُغلق للتو — الحارس اليومي لم يُطبَّق على مسار الدفع بعد رفع الحجب';

  select count(*) into v_count from public.supplier_payments
  where purchase_invoice_id = v_inv and business_date = v_target;
  assert v_count = 0, format('FAIL H: يجب ألا توجد أي دفعة في اليوم المقفل، الموجود: %s', v_count);

  raise notice 'PASS H: daily-close race on the PAYMENT path — the payment genuinely blocked on the open EXCLUSIVE close lock, then was correctly refused';
end $$;

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
drop function if exists public._p11cc_wait_ready(text, int, numeric);
drop function if exists public._p11cc_drain_pending(text);
drop function if exists public._p11cc_wait_blocked_by(int, int, int, numeric);

\echo 'purchases_phase11_concurrency.test.sql PASSED'

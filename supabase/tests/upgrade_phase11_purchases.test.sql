-- ============================================================================
-- Integration test: Production upgrade path onto Phase 11 (Purchases &
-- Suppliers Core) without re-running seed.sql
-- ============================================================================
-- This file does NOT build the database itself — it only ASSERTS against a
-- database that was already built the way a real production upgrade would
-- experience it:
--
--   1. Fresh DB, migrations 0001-0236 applied (the frozen baseline: the last
--      shipped state before Phase 11, i.e. Phase 10 + Hotfix 10.1.0).
--   2. The REAL supabase/seed.sql applied (a real upgrade already ran this
--      once, long before Phase 11 existed — it is never re-run here).
--   3. Migrations 0237 through the latest (Phase 11) applied on top — in a
--      SEPARATE psql invocation, exactly like a production upgrade would.
--
-- See scripts/run_upgrade_test_phase11_purchases.sh for the orchestration that
-- builds exactly this sequence, then runs this file.
--
-- Proves five distinct things:
--   (A) The 7 new Phase 11 permission keys and their role grants come from
--       migration 0237 ITSELF, idempotently — NOT from seed.sql (which never
--       ran again) and not missing.
--   (B) The whole purchasing engine is immediately USABLE the moment
--       0237-0240 finish applying — supplier, invoice, inventory receipt,
--       partial payment, payment reversal, invoice reversal, reports — all
--       inside this same rolled-back transaction.
--   (C) DECISION 5, structurally: the upgrade did not add a single column,
--       constraint or foreign key to the Phase 10 expense schema, and no
--       purchase can reach the operating-expense ledger.
--   (D) DECISION 3: net_operating_return and the Phase 10 expense-aware
--       dashboard wrapper are byte-for-byte unaware of purchases.
--   (E) DECISION 2: Phase 9's inventory engine was NOT edited — Phase 11
--       calls record_inventory_stock_movement(), it does not reimplement or
--       fork it.
--
-- Run it with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase11_purchases.test.sql
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- (A) Permission keys + role grants come from 0237, not seed.sql.
-- ---------------------------------------------------------------------------
do $$
declare
  v_count integer; v_super integer; v_admin integer; v_supervisor integer; v_accountant integer;
begin
  select count(*) into v_count from public.permissions
  where key in ('purchases.view', 'purchases.create', 'purchases.reverse', 'purchases.record_payment',
                'purchases.reverse_payment', 'purchases.manage_suppliers', 'purchases.process_closed_day');
  if v_count <> 7 then
    raise exception 'BUG: expected the 7 Phase 11 permission keys to exist after the upgrade, found %', v_count;
  end if;

  select count(*) into v_super
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'super_admin' and p.key like 'purchases.%';
  if v_super <> 7 then
    raise exception 'BUG: super_admin should hold all 7 purchases.* permissions after the upgrade, found %', v_super;
  end if;

  select count(*) into v_admin
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'admin' and p.key like 'purchases.%';
  if v_admin <> 7 then
    raise exception 'BUG: admin should hold all 7 purchases.* permissions, found %', v_admin;
  end if;

  -- Supervisor gets the operational six but NOT the supplier catalogue.
  select count(*) into v_supervisor
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'supervisor' and p.key like 'purchases.%';
  if v_supervisor <> 6 then
    raise exception 'BUG: supervisor should hold exactly 6 purchases.* permissions (no manage_suppliers), found %', v_supervisor;
  end if;
  if exists (
    select 1 from public.role_permissions rp
    join public.roles r on r.id = rp.role_id
    join public.permissions p on p.id = rp.permission_id
    where r.key = 'supervisor' and p.key = 'purchases.manage_suppliers'
  ) then
    raise exception 'BUG: supervisor must NOT hold purchases.manage_suppliers';
  end if;

  -- Accountant is view-only.
  select count(*) into v_accountant
  from public.role_permissions rp
  join public.roles r on r.id = rp.role_id
  join public.permissions p on p.id = rp.permission_id
  where r.key = 'accountant' and p.key like 'purchases.%';
  if v_accountant <> 1 then
    raise exception 'BUG: accountant should hold exactly purchases.view, found % purchases.* grants', v_accountant;
  end if;

  raise notice 'PASS A: all 7 Phase 11 permission keys and their role grants came from migration 0237 itself (seed.sql never re-ran)';
end $$;

-- ---------------------------------------------------------------------------
-- (B) The engine is usable immediately after the upgrade.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('bb999999-0000-4000-8000-000000000001', 'test-p11-upgrade@example.invalid')
on conflict (id) do nothing;

update public.profiles set full_name = 'Test P11 Upgrade Actor', status = 'active', store_access_scope = 'all'
  where id = 'bb999999-0000-4000-8000-000000000001';

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'bb999999-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('stores.view', 'stores.create', 'categories.view', 'categories.manage',
                'karats.view', 'karats.manage', 'inventory.view', 'inventory.receive',
                'purchases.view', 'purchases.create', 'purchases.reverse',
                'purchases.record_payment', 'purchases.reverse_payment', 'purchases.manage_suppliers');

set role authenticated;
set local request.jwt.claims = '{"sub":"bb999999-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store uuid; v_cat uuid; v_karat uuid; v_item uuid; v_sup uuid;
  v_inv uuid; v_pay uuid; v_gross text; v_amount text; v_out text;
  v_lines jsonb; v jsonb; v_qty numeric;
begin
  insert into public.stores (code, name_ar, status) values ('P11UP-ST', 'فرع ترقية 11', 'active') returning id into v_store;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p11upcat', 'تصنيف ترقية 11', 991, 'active') returning id into v_cat;
  insert into public.karats (code, name_ar, sort_order, status) values ('P11UPK', 'عيار ترقية 11', 991, 'active') returning id into v_karat;
  select id into v_item from public.create_inventory_item('P11UP-SKU', 'صنف ترقية 11', v_cat, v_karat, 'gram', null);

  select id into v_sup from public.create_supplier('P11UP-SUP', 'مورّد الترقية', 'Upgrade Supplier', '300000000000003');
  if v_sup is null then
    raise exception 'BUG: create_supplier() unusable immediately after the upgrade';
  end if;

  v_lines := jsonb_build_array(jsonb_build_object(
    'inventory_item_id', v_item, 'quantity', 6, 'unit_net_cost', 200,
    'tax_treatment', 'standard', 'tax_rate_percent', 15,
    'net_amount', 1200, 'vat_amount', 180, 'gross_amount', 1380));

  select id, gross_total into v_inv, v_gross
  from public.post_purchase_invoice(v_sup, v_store, v_lines, 1200, 180, 1380, current_date, 'UP-INV-1', current_date);
  if v_gross <> '1380.00' then
    raise exception 'BUG: expected gross_total=1380.00 (text at the column''s own 2dp scale), got %', v_gross;
  end if;

  -- Decision 2: posting the invoice ALSO received the stock, atomically.
  select coalesce(sum(quantity_delta), 0) into v_qty
  from public.inventory_stock_movements where item_id = v_item and store_id = v_store;
  if v_qty <> 6 then
    raise exception 'BUG: posting the invoice must receive 6 units into inventory, found %', v_qty;
  end if;

  -- Partial payment, then its reversal, then the invoice reversal.
  select id, amount, outstanding_after into v_pay, v_amount, v_out
  from public.record_supplier_payment(v_inv, 380, 'bank_transfer', current_date, 'UP-TRX');
  if v_amount <> '380.00' or v_out <> '1000.00' then
    raise exception 'BUG: expected payment 380.00 leaving 1000.00 outstanding, got %/%', v_amount, v_out;
  end if;

  select amount into v_amount from public.reverse_supplier_payment(v_pay, 'عكس دفعة الترقية', current_date);
  if v_amount <> '-380.00' then
    raise exception 'BUG: expected payment reversal amount=-380.00, got %', v_amount;
  end if;

  select gross_total into v_gross from public.reverse_purchase_invoice(v_inv, 'عكس فاتورة الترقية', current_date);
  if v_gross <> '-1380.00' then
    raise exception 'BUG: expected invoice reversal gross_total=-1380.00, got %', v_gross;
  end if;

  -- The compensating movement returned the stock, exactly.
  select coalesce(sum(quantity_delta), 0) into v_qty
  from public.inventory_stock_movements where item_id = v_item and store_id = v_store;
  if v_qty <> 0 then
    raise exception 'BUG: invoice and its reversal must net to 0 units of stock, found %', v_qty;
  end if;

  -- Reads work, and the reversed pair carries no liability.
  v := public.list_purchase_invoices(current_date - 1, current_date);
  if (v ->> 'total_count')::int <> 2 then
    raise exception 'BUG: expected 2 ledger entries (invoice + reversal), got %', v ->> 'total_count';
  end if;

  v := public.get_supplier_outstanding_summary();
  if v -> 'summary' ->> 'outstanding_total' <> '0.00' then
    raise exception 'BUG: a fully reversed invoice must leave 0.00 outstanding, got %', v -> 'summary' ->> 'outstanding_total';
  end if;

  raise notice 'PASS B: the Purchases engine (supplier, invoice, inventory receipt, payment, both reversals, reports) is fully usable the moment 0237-0240 finish applying';
end $$;

-- ---------------------------------------------------------------------------
-- (C) DECISION 5 — the Phase 10 expense schema was not touched, and no
--     purchase can reach it.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;
do $$
declare v_bad text; v_src text; v_count int;
begin
  -- Not one new column on the expense ledger.
  select string_agg(column_name, ', ') into v_bad
  from information_schema.columns
  where table_schema = 'public' and table_name = 'store_expenses'
    and (column_name like '%purchase%' or column_name like '%supplier%');
  if v_bad is not null then
    raise exception 'BUG (Decision 5): the upgrade added purchase/supplier column(s) to store_expenses: %', v_bad;
  end if;

  -- No foreign key in either direction between the two ledgers.
  select count(*) into v_count
  from information_schema.table_constraints tc
  join information_schema.constraint_column_usage ccu on ccu.constraint_name = tc.constraint_name
   and ccu.table_schema = tc.table_schema
  where tc.table_schema = 'public' and tc.constraint_type = 'FOREIGN KEY'
    and (
      (tc.table_name = 'store_expenses' and ccu.table_name in ('purchase_invoices', 'purchase_invoice_lines', 'supplier_payments', 'suppliers'))
      or (tc.table_name in ('purchase_invoices', 'purchase_invoice_lines', 'supplier_payments', 'suppliers') and ccu.table_name = 'store_expenses')
    );
  if v_count <> 0 then
    raise exception 'BUG (Decision 5): the upgrade created % foreign key(s) coupling purchases to the expense ledger', v_count;
  end if;

  -- The purchase write paths must not so much as mention store_expenses.
  for v_src in
    select pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('post_purchase_invoice', 'reverse_purchase_invoice',
                        'record_supplier_payment', 'reverse_supplier_payment')
  loop
    if v_src like '%store_expenses%' or v_src like '%record_store_expense%' then
      raise exception 'BUG (Decision 5): a purchase write path references the operating-expense ledger';
    end if;
  end loop;

  -- And symmetrically, expense reporting must not have learned about purchases.
  for v_src in
    select pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('record_store_expense', 'reverse_store_expense', 'list_store_expenses',
                        'get_store_expenses_report', 'get_dashboard_summary_with_expenses')
  loop
    if v_src like '%purchase%' or v_src like '%supplier%' then
      raise exception 'BUG (Decision 5): an expense RPC was modified to know about purchases — the two ledgers must stay disjoint';
    end if;
  end loop;

  raise notice 'PASS C: the Phase 10 expense schema gained no purchase column, constraint or foreign key, and neither ledger''s RPCs reference the other';
end $$;

-- ---------------------------------------------------------------------------
-- (D) DECISION 3 — net_operating_return and the legacy dashboards are
--     unaware of purchases.
-- ---------------------------------------------------------------------------
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_dashboard_summary_with_comparison';
  if v_src is null then
    raise exception 'BUG: get_dashboard_summary_with_comparison() disappeared during the Phase 11 upgrade';
  end if;
  if v_src like '%purchase%' then
    raise exception 'BUG (Decision 3): the legacy comparison RPC was modified to know about purchases — Phase 11 must be additive only';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_dashboard_summary';
  if v_src like '%purchase%' then
    raise exception 'BUG (Decision 3): the canonical get_dashboard_summary() was modified to know about purchases';
  end if;

  -- The Phase 10 wrapper that DOES compute net_operating_return must remain
  -- purchase-free: acquisition cost is documentary only.
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_dashboard_summary_with_expenses';
  if v_src is null then
    raise exception 'BUG: the Phase 10 expense-aware wrapper disappeared during the Phase 11 upgrade';
  end if;
  if v_src like '%purchase%' then
    raise exception 'BUG (Decision 3): net_operating_return''s wrapper now depends on purchases — acquisition cost must stay documentary';
  end if;

  raise notice 'PASS D: net_operating_return and every legacy dashboard RPC survived the upgrade with no knowledge of purchases';
end $$;

-- ---------------------------------------------------------------------------
-- (E) DECISION 2 — Phase 9's inventory engine was called, not forked.
-- ---------------------------------------------------------------------------
do $$
declare v_src text; v_count int;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'record_inventory_stock_movement';
  if v_src is null then
    raise exception 'BUG: Phase 9''s record_inventory_stock_movement() disappeared during the upgrade';
  end if;
  if v_src like '%purchase_invoice%' then
    raise exception 'BUG (Decision 2): Phase 9''s inventory engine was edited to know about purchases — Phase 11 must call it unchanged';
  end if;

  -- There is exactly ONE inventory posting engine; Phase 11 introduced no
  -- parallel writer of inventory_stock_movements.
  select count(*) into v_count
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('post_purchase_invoice', 'reverse_purchase_invoice')
    and pg_get_functiondef(p.oid) like '%insert into public.inventory_stock_movements%';
  if v_count <> 0 then
    raise exception 'BUG (Decision 2): % purchase RPC(s) write inventory_stock_movements directly instead of going through Phase 9''s engine', v_count;
  end if;

  select count(*) into v_count
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('post_purchase_invoice', 'reverse_purchase_invoice')
    and pg_get_functiondef(p.oid) like '%record_inventory_stock_movement%';
  if v_count <> 2 then
    raise exception 'BUG (Decision 2): expected both purchase posting paths to call record_inventory_stock_movement(), found %', v_count;
  end if;

  raise notice 'PASS E: both purchase posting paths go through Phase 9''s unmodified inventory engine; neither writes inventory_stock_movements itself';
end $$;

do $$
begin
  raise notice '=== ALL upgrade_phase11_purchases.test.sql ASSERTIONS PASSED ===';
end $$;

rollback;

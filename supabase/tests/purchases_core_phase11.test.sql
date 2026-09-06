-- ============================================================================
-- Integration test: Phase 11 — Purchases & Suppliers Core (0237-0240)
-- ============================================================================
-- Single-transaction, rolled-back-at-the-end regression test, mirroring
-- store_expenses_phase10.test.sql / inventory_core_phase9.test.sql exactly.
--
-- Prefix 'ba000000-...' is not used by any other test file's fixtures.
--   01 = full purchasing actor (+ stores.create, audit_logs.view,
--        sales.close_day, inventory.view for the stock assertions)
--   02 = purchases.view ONLY
--   03 = purchases.create ONLY
--   04 = purchases.record_payment ONLY
--   05 = full purchasing, but store_access_scope='single' -> Store B only
--   06 = full purchasing PLUS purchases.process_closed_day
--
-- Requires migrations 0001-latest + supabase/seed.sql already applied.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Setup
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('ba000000-0000-4000-8000-000000000001', 'test-p11-full@example.invalid'),
  ('ba000000-0000-4000-8000-000000000002', 'test-p11-viewonly@example.invalid'),
  ('ba000000-0000-4000-8000-000000000003', 'test-p11-createonly@example.invalid'),
  ('ba000000-0000-4000-8000-000000000004', 'test-p11-payonly@example.invalid'),
  ('ba000000-0000-4000-8000-000000000005', 'test-p11-storebonly@example.invalid'),
  ('ba000000-0000-4000-8000-000000000006', 'test-p11-closedday@example.invalid');

update public.profiles set full_name = 'P11 Full', status = 'active', store_access_scope = 'all' where id = 'ba000000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'P11 View Only', status = 'active', store_access_scope = 'all' where id = 'ba000000-0000-4000-8000-000000000002';
update public.profiles set full_name = 'P11 Create Only', status = 'active', store_access_scope = 'all' where id = 'ba000000-0000-4000-8000-000000000003';
update public.profiles set full_name = 'P11 Pay Only', status = 'active', store_access_scope = 'all' where id = 'ba000000-0000-4000-8000-000000000004';
update public.profiles set full_name = 'P11 Store-B Only', status = 'active', store_access_scope = 'all' where id = 'ba000000-0000-4000-8000-000000000005';
update public.profiles set full_name = 'P11 Closed Day', status = 'active', store_access_scope = 'all' where id = 'ba000000-0000-4000-8000-000000000006';

-- stores.create is required by 0010's stores_insert policy; audit_logs.view by
-- the audit section; sales.close_day by the daily-close section; inventory.view
-- so the stock assertions can read inventory_stock_movements at all;
-- categories/karats manage so the fixture can create the item catalogue.
insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'ba000000-0000-4000-8000-000000000001', id, 'grant' from public.permissions
  where key in ('stores.view', 'stores.create', 'audit_logs.view', 'sales.close_day',
                'categories.view', 'categories.manage', 'karats.view', 'karats.manage',
                'inventory.view', 'inventory.receive',
                'purchases.view', 'purchases.create', 'purchases.reverse',
                'purchases.record_payment', 'purchases.reverse_payment', 'purchases.manage_suppliers');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'ba000000-0000-4000-8000-000000000002', id, 'grant' from public.permissions where key in ('purchases.view');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'ba000000-0000-4000-8000-000000000003', id, 'grant' from public.permissions where key in ('purchases.create');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'ba000000-0000-4000-8000-000000000004', id, 'grant' from public.permissions where key in ('purchases.record_payment');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'ba000000-0000-4000-8000-000000000005', id, 'grant' from public.permissions
  where key in ('purchases.view', 'purchases.create', 'purchases.reverse', 'purchases.record_payment');

insert into public.user_permission_overrides (user_id, permission_id, effect)
  select 'ba000000-0000-4000-8000-000000000006', id, 'grant' from public.permissions
  where key in ('purchases.view', 'purchases.create', 'purchases.reverse', 'purchases.record_payment',
                'purchases.reverse_payment', 'purchases.process_closed_day', 'sales.close_day');

set role authenticated;
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_a uuid; v_store_b uuid; v_cat uuid; v_karat uuid; v_item uuid; v_item2 uuid; v_sup uuid;
begin
  insert into public.stores (code, name_ar, status) values ('P11-STA', 'فرع مشتريات أ', 'active') returning id into v_store_a;
  insert into public.stores (code, name_ar, status) values ('P11-STB', 'فرع مشتريات ب', 'active') returning id into v_store_b;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('p11cat', 'تصنيف مشتريات', 981, 'active') returning id into v_cat;
  insert into public.karats (code, name_ar, sort_order, status) values ('P11K', 'عيار مشتريات', 981, 'active') returning id into v_karat;

  select id into v_item from public.create_inventory_item('P11-SKU-1', 'صنف مشتريات 1', v_cat, v_karat, 'gram', null);
  select id into v_item2 from public.create_inventory_item('P11-SKU-2', 'صنف مشتريات 2', v_cat, v_karat, 'gram', null);
  select id into v_sup from public.create_supplier('P11-SUP', 'مورّد الذهب الرئيسي', 'Main Gold Supplier', '300000000000003');

  perform set_config('p11.store_a', v_store_a::text, false);
  perform set_config('p11.store_b', v_store_b::text, false);
  perform set_config('p11.item', v_item::text, false);
  perform set_config('p11.item2', v_item2::text, false);
  perform set_config('p11.supplier', v_sup::text, false);
end;
$$;

-- Store-scoping actor 005 must NOT happen as `authenticated`: 0010's
-- profiles_update policy requires users.edit, which this purchasing-only actor
-- lacks, and an RLS-blocked UPDATE silently matches ZERO rows rather than
-- raising — leaving 005 at scope 'all' and making every cross-store assertion
-- below pass vacuously.
reset role;
reset request.jwt.claims;
update public.profiles
   set store_access_scope = 'single', default_store_id = current_setting('p11.store_b')::uuid
 where id = 'ba000000-0000-4000-8000-000000000005';

do $$
declare v_scope text; v_default uuid;
begin
  select store_access_scope, default_store_id into v_scope, v_default
  from public.profiles where id = 'ba000000-0000-4000-8000-000000000005';
  if v_scope <> 'single' or v_default is distinct from current_setting('p11.store_b')::uuid then
    raise exception 'TEST FAILED: fixture did not store-scope actor 005 to Store B (scope=%, default=%)', v_scope, v_default;
  end if;
end;
$$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- 1. Suppliers — permission boundary, duplicate code, lifecycle.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
begin
  begin
    perform public.create_supplier('P11-X', 'مورّد غير مصرح');
    raise exception 'TEST FAILED: view-only actor created a supplier';
  exception when others then
    if sqlerrm not like '%صلاحية%' then raise; end if;
  end;
end;
$$;

set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
begin
  begin
    perform public.create_supplier('p11-sup', 'مورّد مكرر');
    raise exception 'TEST FAILED: a duplicate (case-insensitive) supplier code was accepted';
  exception when others then
    if sqlerrm not like '%مستخدم بالفعل%' then raise; end if;
  end;

  -- A disabled supplier cannot be invoiced against.
  perform public.set_supplier_status(current_setting('p11.supplier')::uuid, 'disabled');
  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      jsonb_build_array(jsonb_build_object(
        'inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 100,
        'tax_treatment', 'standard', 'tax_rate_percent', 15,
        'net_amount', 100, 'vat_amount', 15, 'gross_amount', 115)),
      100, 15, 115, current_date);
    raise exception 'TEST FAILED: an invoice was posted against a DISABLED supplier';
  exception when others then
    if sqlerrm not like '%غير نشط%' then raise; end if;
  end;
  perform public.set_supplier_status(current_setting('p11.supplier')::uuid, 'active');
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Posting an invoice — validation, totals, and ATOMIC inventory posting.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
begin
  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      jsonb_build_array(jsonb_build_object(
        'inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 100,
        'tax_treatment', 'standard', 'tax_rate_percent', 15,
        'net_amount', 100, 'vat_amount', 15, 'gross_amount', 115)),
      100, 15, 115, current_date);
    raise exception 'TEST FAILED: view-only actor posted a purchase invoice';
  exception when others then
    if sqlerrm not like '%صلاحية%' then raise; end if;
  end;
end;
$$;

set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_lines jsonb;
begin
  v_lines := jsonb_build_array(jsonb_build_object(
    'inventory_item_id', current_setting('p11.item'), 'quantity', 10, 'unit_net_cost', 100,
    'tax_treatment', 'standard', 'tax_rate_percent', 15,
    'net_amount', 1000, 'vat_amount', 150, 'gross_amount', 1150));

  -- Line arithmetic must hold exactly.
  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      jsonb_build_array(jsonb_build_object(
        'inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 100,
        'tax_treatment', 'standard', 'tax_rate_percent', 15,
        'net_amount', 100, 'vat_amount', 15, 'gross_amount', 999)),
      100, 15, 999, current_date);
    raise exception 'TEST FAILED: a line whose gross <> net + vat was accepted';
  exception when others then
    if sqlerrm not like '%لا يساوي الصافي%' then raise; end if;
  end;

  -- Header must equal the sum of its lines, exactly.
  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid, v_lines,
      1000, 150, 1151, current_date);
    raise exception 'TEST FAILED: an invoice whose header totals disagree with its lines was accepted';
  exception when others then
    -- Must be the RPC's own sentence, NOT a raw constraint name: the RPC has
    -- to catch this before it writes anything.
    if sqlerrm not like '%لا تطابق مجموع البنود%' then raise; end if;
  end;

  -- A non-standard treatment may not carry VAT.
  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      jsonb_build_array(jsonb_build_object(
        'inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 100,
        'tax_treatment', 'exempt', 'tax_rate_percent', 15,
        'net_amount', 100, 'vat_amount', 15, 'gross_amount', 115)),
      100, 15, 115, current_date);
    raise exception 'TEST FAILED: an exempt line carrying VAT was accepted';
  exception when others then
    if sqlerrm not like '%ولا يجوز أن يحمل ضريبة%' then raise; end if;
  end;

  -- Future-dated posting rejected.
  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid, v_lines,
      1000, 150, 1150, public.business_today() + 1);
    raise exception 'TEST FAILED: a future-dated invoice was accepted';
  exception when others then
    if sqlerrm not like '%مستقبلي%' then raise; end if;
  end;
end;
$$;

-- Cross-store rejection.
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
begin
  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      jsonb_build_array(jsonb_build_object(
        'inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 100,
        'tax_treatment', 'standard', 'tax_rate_percent', 15,
        'net_amount', 100, 'vat_amount', 15, 'gross_amount', 115)),
      100, 15, 115, current_date);
    raise exception 'TEST FAILED: Store-B-only actor posted an invoice at Store A';
  exception when others then
    if sqlerrm not like '%الفرع%' then raise; end if;
  end;
end;
$$;

-- The real posting: two lines, mixed tax treatments.
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_id uuid; v_num text; v_gross text;
begin
  select id, purchase_number, gross_total into v_id, v_num, v_gross
  from public.post_purchase_invoice(
    current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
    jsonb_build_array(
      jsonb_build_object('inventory_item_id', current_setting('p11.item'), 'quantity', 10, 'unit_net_cost', 100,
        'tax_treatment', 'standard', 'tax_rate_percent', 15, 'net_amount', 1000, 'vat_amount', 150, 'gross_amount', 1150),
      jsonb_build_object('inventory_item_id', current_setting('p11.item2'), 'quantity', 5, 'unit_net_cost', 40,
        'tax_treatment', 'zero_rated', 'tax_rate_percent', 0, 'net_amount', 200, 'vat_amount', 0, 'gross_amount', 200)
    ),
    1200, 150, 1350, current_date - 3, 'SUP-INV-001', current_date - 3, 'شحنة سبتمبر');

  if v_gross <> '1350.00' then
    raise exception 'TEST FAILED: expected gross_total=1350.00 (text at the column scale), got %', v_gross;
  end if;
  if v_num !~ '^PUR-[0-9]{10}$' then
    raise exception 'TEST FAILED: purchase number format is wrong: %', v_num;
  end if;
  perform set_config('p11.inv1', v_id::text, false);
end;
$$;

-- The SAME supplier cannot issue the SAME invoice number twice...
do $$
begin
  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      jsonb_build_array(jsonb_build_object('inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 100,
        'tax_treatment', 'standard', 'tax_rate_percent', 15, 'net_amount', 100, 'vat_amount', 15, 'gross_amount', 115)),
      100, 15, 115, current_date, 'SUP-INV-001');
    raise exception 'TEST FAILED: a duplicate supplier invoice number was accepted for the SAME supplier';
  exception when others then
    if sqlerrm not like '%supplier_invoice_number%' then raise; end if;
  end;
end;
$$;

-- ...but a DIFFERENT supplier may legitimately use the same number.
do $$
declare v_sup2 uuid;
begin
  select id into v_sup2 from public.create_supplier('P11-SUP2', 'مورّد ثانٍ');
  perform set_config('p11.supplier2', v_sup2::text, false);

  perform public.post_purchase_invoice(
    v_sup2, current_setting('p11.store_a')::uuid,
    jsonb_build_array(jsonb_build_object('inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 50,
      'tax_treatment', 'out_of_scope', 'tax_rate_percent', 0, 'net_amount', 50, 'vat_amount', 0, 'gross_amount', 50)),
    50, 0, 50, current_date - 2, 'SUP-INV-001');
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Inventory posting — exactly one movement per line, correct quantities.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;
do $$
declare
  v_lines int; v_moves int; v_balance numeric; v_mismatch text;
begin
  select count(*) into v_lines from public.purchase_invoice_lines where purchase_invoice_id = current_setting('p11.inv1')::uuid;
  if v_lines <> 2 then
    raise exception 'TEST FAILED: expected 2 invoice lines, got %', v_lines;
  end if;

  -- Every line links to a distinct, existing movement (the UNIQUE constraint
  -- makes duplicate or shared posting impossible; this proves it happened).
  select count(distinct l.inventory_movement_id) into v_moves
  from public.purchase_invoice_lines l where l.purchase_invoice_id = current_setting('p11.inv1')::uuid;
  if v_moves <> 2 then
    raise exception 'TEST FAILED: expected 2 distinct inventory movements, got %', v_moves;
  end if;

  if exists (
    select 1 from public.purchase_invoice_lines l
    left join public.inventory_stock_movements m on m.id = l.inventory_movement_id
    where l.purchase_invoice_id = current_setting('p11.inv1')::uuid and m.id is null
  ) then
    raise exception 'TEST FAILED: a line references a non-existent inventory movement';
  end if;

  -- ---------------------------------------------------------------------
  -- PER-LINE CORRESPONDENCE. The UNIQUE link proves a line has exactly one
  -- movement; it says NOTHING about that movement being the RIGHT one. A
  -- line could point at a movement for another item, another store, another
  -- quantity or the wrong direction and every constraint would still hold.
  -- So compare the four fields directly, line by line, for EVERY line of
  -- EVERY purchase document in the database — not just this invoice.
  --
  -- quantity_delta is compared to the line's own SIGNED quantity, which makes
  -- this one assertion cover both directions: an invoice line is positive and
  -- posts a 'receive', a reversal line is negative and posts an 'adjust'.
  -- ---------------------------------------------------------------------
  select string_agg(format('line %s: item %s/%s store %s/%s qty %s/%s kind %s',
           l.id, l.inventory_item_id, m.item_id, l.store_id, m.store_id, l.quantity, m.quantity_delta, m.movement_kind), '; ')
    into v_mismatch
  from public.purchase_invoice_lines l
  join public.inventory_stock_movements m on m.id = l.inventory_movement_id
  where m.item_id is distinct from l.inventory_item_id
     or m.store_id is distinct from l.store_id
     or m.quantity_delta is distinct from l.quantity
     or (l.quantity > 0 and m.movement_kind <> 'receive')
     or (l.quantity < 0 and m.movement_kind <> 'adjust');
  if v_mismatch is not null then
    raise exception 'TEST FAILED: line/movement mismatch — %', v_mismatch;
  end if;

  -- The scan above is only meaningful if it actually looked at rows.
  select count(*) into v_lines from public.purchase_invoice_lines l
  join public.inventory_stock_movements m on m.id = l.inventory_movement_id;
  if v_lines < 3 then
    raise exception 'TEST FAILED: the correspondence scan examined only % joined line(s) — too few to be meaningful', v_lines;
  end if;

  -- Stock actually moved, in the right direction and amount.
  select coalesce(sum(quantity_delta), 0) into v_balance
  from public.inventory_stock_movements
  where item_id = current_setting('p11.item')::uuid and store_id = current_setting('p11.store_a')::uuid;
  if v_balance <> 11 then -- 10 from inv1 + 1 from the second supplier's invoice
    raise exception 'TEST FAILED: expected item-1 balance 11 after posting, got %', v_balance;
  end if;
end;
$$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- 3b. ATOMICITY — a line that fails AFTER an earlier line already posted must
--     leave nothing at all behind.
-- ---------------------------------------------------------------------------
-- This is the case the UNIQUE constraint cannot speak to. Line 1 genuinely
-- succeeds: its inventory movement is written and its row inserted. Then line
-- 2 fails on item lookup (a pass-2 failure — pass 1 validates arithmetic, so
-- an unknown item survives it). If posting were not atomic, the database would
-- be left holding an invoice header, one orphan line, and — worst of all — a
-- REAL stock increase for goods that were never recorded as purchased.
--
-- The plpgsql BEGIN/EXCEPTION block below is a subtransaction, which models
-- exactly what PostgREST gives a single RPC call: one statement, one
-- transaction, all-or-nothing.
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_docs_before int; v_lines_before int; v_moves_before int; v_bal_before numeric;
  v_docs_after int; v_lines_after int; v_moves_after int; v_bal_after numeric;
  v_raised boolean := false;
begin
  select count(*) into v_docs_before from public.purchase_invoices;
  select count(*) into v_lines_before from public.purchase_invoice_lines;
  select count(*) into v_moves_before from public.inventory_stock_movements;
  select coalesce(sum(quantity_delta), 0) into v_bal_before
  from public.inventory_stock_movements
  where item_id = current_setting('p11.item')::uuid and store_id = current_setting('p11.store_a')::uuid;

  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      jsonb_build_array(
        -- Line 1 is entirely valid and WILL post its movement first.
        jsonb_build_object('inventory_item_id', current_setting('p11.item'), 'quantity', 7, 'unit_net_cost', 100,
          'tax_treatment', 'standard', 'tax_rate_percent', 15, 'net_amount', 700, 'vat_amount', 105, 'gross_amount', 805),
        -- Line 2 references an item that does not exist — a pass-2 failure,
        -- raised only after line 1 has already been written.
        jsonb_build_object('inventory_item_id', '00000000-0000-4000-8000-0000000000ff', 'quantity', 3, 'unit_net_cost', 100,
          'tax_treatment', 'standard', 'tax_rate_percent', 15, 'net_amount', 300, 'vat_amount', 45, 'gross_amount', 345)
      ),
      1000, 150, 1150, current_date, 'ATOMIC-1');
    raise exception 'TEST FAILED: an invoice with an unknown item on line 2 was accepted';
  exception when others then
    if sqlerrm like 'TEST FAILED%' then raise; end if;
    if sqlerrm not like '%الصنف غير موجود%' then raise; end if;
    v_raised := true;
  end;

  if not v_raised then
    raise exception 'TEST FAILED: the failing line did not raise at all — the atomicity check never got to run';
  end if;

  select count(*) into v_docs_after from public.purchase_invoices;
  select count(*) into v_lines_after from public.purchase_invoice_lines;
  select count(*) into v_moves_after from public.inventory_stock_movements;
  select coalesce(sum(quantity_delta), 0) into v_bal_after
  from public.inventory_stock_movements
  where item_id = current_setting('p11.item')::uuid and store_id = current_setting('p11.store_a')::uuid;

  if v_docs_after <> v_docs_before then
    raise exception 'TEST FAILED (atomicity): a partial invoice header survived — % documents before, % after', v_docs_before, v_docs_after;
  end if;
  if v_lines_after <> v_lines_before then
    raise exception 'TEST FAILED (atomicity): % orphan invoice line(s) survived the failed posting', v_lines_after - v_lines_before;
  end if;
  if v_moves_after <> v_moves_before then
    raise exception 'TEST FAILED (atomicity): % inventory movement(s) leaked from a failed posting — stock rose for goods never recorded as purchased', v_moves_after - v_moves_before;
  end if;
  if v_bal_after <> v_bal_before then
    raise exception 'TEST FAILED (atomicity): the item balance moved from % to % despite the posting failing', v_bal_before, v_bal_after;
  end if;

  -- And nothing is recoverable by document number either.
  if exists (select 1 from public.purchase_invoices where supplier_invoice_number = 'ATOMIC-1') then
    raise exception 'TEST FAILED (atomicity): the failed invoice is still addressable by its supplier invoice number';
  end if;
end;
$$;

-- The counts above prove the END STATE is clean. They do NOT by themselves
-- prove a partial write was ever ATTEMPTED — if the RPC happened to validate
-- every item before posting anything, the assertions would pass without the
-- interesting path ever executing, and the test would be a false positive.
--
-- So assert the structure that makes the attempt real: line N's item lookup
-- and line N's inventory posting live in the SAME loop iteration, which means
-- line 1's movement is genuinely written before line 2 is ever looked at.
reset role;
reset request.jwt.claims;
do $$
declare
  v_src text; v_pass2 text;
  v_check int; v_post int; v_endloop int;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'post_purchase_invoice';

  v_pass2 := substr(v_src, position('PASS 2' in v_src));
  if v_pass2 = '' then
    raise exception 'TEST FAILED: could not locate the posting pass in post_purchase_invoice — this structural check is not actually inspecting anything';
  end if;

  v_check   := position('الصنف غير موجود' in v_pass2);
  v_post    := position('record_inventory_stock_movement' in v_pass2);
  v_endloop := position('end loop' in v_pass2);

  if v_check = 0 or v_post = 0 or v_endloop = 0 then
    raise exception 'TEST FAILED: the posting pass no longer contains the per-line item check (%), the engine call (%) or a loop (%)', v_check, v_post, v_endloop;
  end if;
  if v_check > v_endloop or v_post > v_endloop then
    raise exception 'TEST FAILED: the item check and the inventory posting are no longer in the SAME per-line loop — the atomicity test above would stop exercising a genuine partial write';
  end if;
end;
$$;
set role authenticated;
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- The same must hold when the failing line names a DISABLED item, which is a
-- different pass-2 rejection path.
--
-- The item is flipped inactive as superuser rather than through
-- update_inventory_item(): this actor holds no item-management permission, and
-- an RLS-blocked UPDATE matches zero rows SILENTLY instead of raising — which
-- would leave the item active and make the whole check pass for the wrong
-- reason. The subject under test is the purchase RPC, not the item RPC.
reset role;
reset request.jwt.claims;
update public.inventory_items set active = false where sku = 'P11-SKU-2';
do $$
begin
  if not exists (select 1 from public.inventory_items where sku = 'P11-SKU-2' and not active) then
    raise exception 'TEST FAILED: fixture did not disable P11-SKU-2 — the disabled-item check would be vacuous';
  end if;
end $$;
set role authenticated;
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_moves_before int; v_moves_after int; v_disabled uuid;
begin
  select id into v_disabled from public.inventory_items where sku = 'P11-SKU-2';

  select count(*) into v_moves_before from public.inventory_stock_movements;
  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      jsonb_build_array(
        jsonb_build_object('inventory_item_id', current_setting('p11.item'), 'quantity', 2, 'unit_net_cost', 100,
          'tax_treatment', 'standard', 'tax_rate_percent', 15, 'net_amount', 200, 'vat_amount', 30, 'gross_amount', 230),
        jsonb_build_object('inventory_item_id', v_disabled, 'quantity', 2, 'unit_net_cost', 100,
          'tax_treatment', 'standard', 'tax_rate_percent', 15, 'net_amount', 200, 'vat_amount', 30, 'gross_amount', 230)
      ),
      400, 60, 460, current_date, 'ATOMIC-2');
    raise exception 'TEST FAILED: an invoice naming a DISABLED item was accepted';
  exception when others then
    if sqlerrm like 'TEST FAILED%' then raise; end if;
    if sqlerrm not like '%غير نشط%' then raise; end if;
  end;

  select count(*) into v_moves_after from public.inventory_stock_movements;
  if v_moves_after <> v_moves_before then
    raise exception 'TEST FAILED (atomicity): % movement(s) leaked when line 2 named a disabled item', v_moves_after - v_moves_before;
  end if;
end;
$$;

reset role;
reset request.jwt.claims;
update public.inventory_items set active = true where sku = 'P11-SKU-2';
set role authenticated;
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 4. Payments — partial, overpayment refused, derived outstanding.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
begin
  begin
    perform public.record_supplier_payment(current_setting('p11.inv1')::uuid, 100, 'cash');
    raise exception 'TEST FAILED: create-only actor recorded a supplier payment';
  exception when others then
    if sqlerrm not like '%صلاحية%' then raise; end if;
  end;
end;
$$;

set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_amt text; v_out text; v_id uuid;
begin
  -- Overpayment refused up front.
  begin
    perform public.record_supplier_payment(current_setting('p11.inv1')::uuid, 2000, 'cash');
    raise exception 'TEST FAILED: a payment exceeding the invoice total was accepted';
  exception when others then
    if sqlerrm not like '%يتجاوز المتبقي%' then raise; end if;
  end;

  -- Partial payment.
  select id, amount, outstanding_after into v_id, v_amt, v_out
  from public.record_supplier_payment(current_setting('p11.inv1')::uuid, 350, 'bank_transfer', current_date - 1, 'TRX-9');
  if v_amt <> '350.00' or v_out <> '1000.00' then
    raise exception 'TEST FAILED: expected amount=350.00 / outstanding=1000.00, got %/%', v_amt, v_out;
  end if;
  perform set_config('p11.pay1', v_id::text, false);

  -- A second payment may not exceed what is LEFT.
  begin
    perform public.record_supplier_payment(current_setting('p11.inv1')::uuid, 1000.01, 'cash');
    raise exception 'TEST FAILED: a payment exceeding the REMAINING balance was accepted';
  exception when others then
    if sqlerrm not like '%يتجاوز المتبقي%' then raise; end if;
  end;

  -- Reversing the payment restores the liability exactly.
  select outstanding_after into v_out from public.reverse_supplier_payment(v_id, 'حوالة مرتجعة', current_date);
  if v_out <> '1350.00' then
    raise exception 'TEST FAILED: reversing the payment should restore outstanding to 1350.00, got %', v_out;
  end if;

  -- Double reversal refused.
  begin
    perform public.reverse_supplier_payment(v_id, 'مرة أخرى');
    raise exception 'TEST FAILED: a payment was reversed TWICE';
  exception when others then
    if sqlerrm not like '%مسبقًا%' then raise; end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Invoice reversal — blocked while an unreversed payment exists.
-- ---------------------------------------------------------------------------
do $$
declare v_pay uuid; v_num text; v_gross text; v_bal numeric;
begin
  -- Pay, then try to reverse the invoice: must be refused.
  select id into v_pay from public.record_supplier_payment(current_setting('p11.inv1')::uuid, 50, 'cash');
  begin
    perform public.reverse_purchase_invoice(current_setting('p11.inv1')::uuid, 'محاولة عكس');
    raise exception 'TEST FAILED: an invoice with an unreversed payment was reversed';
  exception when others then
    if sqlerrm not like '%دفعة غير معكوسة%' then raise; end if;
  end;

  -- Reverse the payment first, then the invoice succeeds.
  perform public.reverse_supplier_payment(v_pay, 'إلغاء الدفعة قبل عكس الفاتورة');

  select purchase_number, gross_total into v_num, v_gross
  from public.reverse_purchase_invoice(current_setting('p11.inv1')::uuid, 'بضاعة مرتجعة للمورّد', current_date);
  if v_gross <> '-1350.00' then
    raise exception 'TEST FAILED: expected reversal gross_total=-1350.00, got %', v_gross;
  end if;

  -- Double reversal refused.
  begin
    perform public.reverse_purchase_invoice(current_setting('p11.inv1')::uuid, 'مرة أخرى');
    raise exception 'TEST FAILED: an invoice was reversed TWICE';
  exception when others then
    if sqlerrm not like '%مسبقًا%' then raise; end if;
  end;

  -- Paying a reversed invoice is refused.
  begin
    perform public.record_supplier_payment(current_setting('p11.inv1')::uuid, 10, 'cash');
    raise exception 'TEST FAILED: a payment was accepted against a REVERSED invoice';
  exception when others then
    if sqlerrm not like '%معكوسة%' then raise; end if;
  end;
end;
$$;

-- Compensating inventory movements landed on the REVERSAL's own date.
reset role;
reset request.jwt.claims;
do $$
declare v_bal numeric; v_rev_moves int;
begin
  select coalesce(sum(quantity_delta), 0) into v_bal
  from public.inventory_stock_movements
  where item_id = current_setting('p11.item')::uuid and store_id = current_setting('p11.store_a')::uuid;
  -- 11 posted, 10 reversed -> 1 remains (the second supplier's invoice).
  if v_bal <> 1 then
    raise exception 'TEST FAILED: expected item-1 balance 1 after the reversal, got %', v_bal;
  end if;

  select count(*) into v_rev_moves
  from public.inventory_stock_movements m
  where m.item_id = current_setting('p11.item')::uuid
    and m.movement_kind = 'adjust' and m.quantity_delta < 0
    and m.business_date = current_date;
  if v_rev_moves <> 1 then
    raise exception 'TEST FAILED: expected exactly 1 compensating movement dated today, got %', v_rev_moves;
  end if;
end;
$$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- 6. Append-only — UPDATE/DELETE impossible even for a role bypassing RLS.
-- ---------------------------------------------------------------------------
reset role;
reset request.jwt.claims;
do $$
begin
  begin
    update public.purchase_invoices set gross_total = 1 where id = current_setting('p11.inv1')::uuid;
    raise exception 'TEST FAILED: a posted invoice row was UPDATED';
  exception when others then
    if sqlerrm not like '%إضافية فقط%' then raise; end if;
  end;
  begin
    delete from public.purchase_invoices where id = current_setting('p11.inv1')::uuid;
    raise exception 'TEST FAILED: a posted invoice row was DELETED';
  exception when others then
    if sqlerrm not like '%إضافية فقط%' then raise; end if;
  end;
  begin
    update public.supplier_payments set amount = 1 where id = current_setting('p11.pay1')::uuid;
    raise exception 'TEST FAILED: a posted payment row was UPDATED';
  exception when others then
    if sqlerrm not like '%إضافية فقط%' then raise; end if;
  end;
  begin
    delete from public.purchase_invoice_lines where purchase_invoice_id = current_setting('p11.inv1')::uuid;
    raise exception 'TEST FAILED: an invoice line was DELETED';
  exception when others then
    if sqlerrm not like '%إضافية فقط%' then raise; end if;
  end;

  -- The RPC validates arithmetic and tax treatment, but the TABLE must be the
  -- backstop: a future code path that bypasses the RPC still cannot write an
  -- internally inconsistent document. Proven here by direct superuser INSERT,
  -- which no RPC guard is in front of.
  begin
    insert into public.purchase_invoices (purchase_number, supplier_id, store_id, business_date,
      entry_kind, supplier_name_snapshot, net_total, vat_total, gross_total, created_by)
    values ('PUR-9999999999', current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      current_date, 'invoice', 'س', 100, 15, 999, 'ba000000-0000-4000-8000-000000000001');
    raise exception 'TEST FAILED: the header CHECK did not stop gross <> net + vat on a direct insert';
  exception when others then
    if sqlerrm not like '%totals_consistent%' then raise; end if;
  end;

  begin
    insert into public.purchase_invoice_lines (purchase_invoice_id, store_id, inventory_item_id,
      item_sku_snapshot, item_name_snapshot, quantity, unit_net_cost, tax_treatment,
      tax_rate_percent, net_amount, vat_amount, gross_amount, inventory_movement_id)
    select current_setting('p11.inv1')::uuid, current_setting('p11.store_a')::uuid,
      current_setting('p11.item')::uuid, 'X', 'X', 1, 1, 'exempt', 15, 100, 15, 115, gen_random_uuid();
    raise exception 'TEST FAILED: the line CHECK did not stop an exempt line carrying VAT on a direct insert';
  exception when others then
    -- CHECK constraints are evaluated before FK triggers, so this must be the
    -- CHECK and nothing else — accepting a foreign-key error here would make
    -- the assertion pass for the wrong reason.
    if sqlerrm not like '%non_standard_no_vat%' then raise; end if;
  end;
end;
$$;
set role authenticated;

-- ---------------------------------------------------------------------------
-- 7. Daily close (§12).
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
begin
  perform public.close_sales_day(current_setting('p11.store_a')::uuid, current_date - 6, 'إغلاق اختبار Phase 11');

  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      jsonb_build_array(jsonb_build_object('inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 10,
        'tax_treatment', 'standard', 'tax_rate_percent', 15, 'net_amount', 10, 'vat_amount', 1.5, 'gross_amount', 11.5)),
      10, 1.5, 11.5, current_date - 6, 'SUP-CLOSED-1');
    raise exception 'TEST FAILED: an invoice was posted into a CLOSED day without purchases.process_closed_day';
  exception when others then
    if sqlerrm not like '%يوم مقفل%' then raise; end if;
  end;
end;
$$;

set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$
declare v_id uuid;
begin
  -- The permission alone is not enough: a reason is mandatory.
  begin
    perform public.post_purchase_invoice(
      current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
      jsonb_build_array(jsonb_build_object('inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 10,
        'tax_treatment', 'standard', 'tax_rate_percent', 15, 'net_amount', 10, 'vat_amount', 1.5, 'gross_amount', 11.5)),
      10, 1.5, 11.5, current_date - 6, 'SUP-CLOSED-1');
    raise exception 'TEST FAILED: a closed-day invoice was accepted without a reason';
  exception when others then
    if sqlerrm not like '%سبب%' then raise; end if;
  end;

  select id into v_id from public.post_purchase_invoice(
    current_setting('p11.supplier')::uuid, current_setting('p11.store_a')::uuid,
    jsonb_build_array(jsonb_build_object('inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 10,
      'tax_treatment', 'standard', 'tax_rate_percent', 15, 'net_amount', 10, 'vat_amount', 1.5, 'gross_amount', 11.5)),
    10, 1.5, 11.5, current_date - 6, 'SUP-CLOSED-1', null, null, 'تسوية متأخرة معتمدة');
  if v_id is null then
    raise exception 'TEST FAILED: a permitted closed-day invoice with a reason was not posted';
  end if;
  perform set_config('p11.closed_inv', v_id::text, false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7b. The daily-close guard has FOUR call sites, not one. Posting is covered
--     above; the payment, invoice-reversal and payment-reversal paths each
--     call the guard separately, so each is proved separately here. A guard
--     that is wired into one path and quietly missing from another is exactly
--     the kind of gap that only shows up as a mutated closed period.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_pay uuid;
begin
  -- (i) PAYMENT into a closed day, by an actor WITHOUT process_closed_day.
  begin
    perform public.record_supplier_payment(current_setting('p11.closed_inv')::uuid, 1, 'cash', current_date - 6);
    raise exception 'TEST FAILED: a payment was recorded into a CLOSED day without purchases.process_closed_day';
  exception when others then
    if sqlerrm like 'TEST FAILED%' then raise; end if;
    if sqlerrm not like '%يوم مقفل%' then raise; end if;
  end;

  -- (ii) INVOICE REVERSAL dated into a closed day. §85: the guard must be
  -- applied to the REVERSAL's own date, not the original invoice's.
  begin
    perform public.reverse_purchase_invoice(current_setting('p11.closed_inv')::uuid, 'عكس في يوم مقفل', current_date - 6);
    raise exception 'TEST FAILED: an invoice was reversed INTO a closed day without purchases.process_closed_day';
  exception when others then
    if sqlerrm like 'TEST FAILED%' then raise; end if;
    if sqlerrm not like '%يوم مقفل%' then raise; end if;
  end;
end;
$$;

-- The privileged actor may do both, with a reason — and (iii) the payment
-- reversal path is guarded on its own date too.
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$
declare v_pay uuid; v_out text;
begin
  -- A payment on the closed day, permitted and reasoned.
  select id into v_pay from public.record_supplier_payment(
    current_setting('p11.closed_inv')::uuid, 5, 'cash', current_date - 6, null, null, 'دفعة متأخرة معتمدة');
  if v_pay is null then
    raise exception 'TEST FAILED: a permitted closed-day payment with a reason was not recorded';
  end if;

  -- Reversing THAT payment into the same closed day: still guarded, and the
  -- reason is still mandatory even for the privileged actor.
  begin
    perform public.reverse_supplier_payment(v_pay, 'عكس دفعة', current_date - 6);
    raise exception 'TEST FAILED: a closed-day payment reversal was accepted without a reason';
  exception when others then
    if sqlerrm like 'TEST FAILED%' then raise; end if;
    if sqlerrm not like '%سبب%' then raise; end if;
  end;

  select outstanding_after into v_out from public.reverse_supplier_payment(
    v_pay, 'عكس دفعة', current_date - 6, 'عكس متأخر معتمد');
  if v_out <> '11.50' then
    raise exception 'TEST FAILED: reversing the closed-day payment should restore outstanding to 11.50, got %', v_out;
  end if;
end;
$$;

-- And the invoice-reversal path, permitted + reasoned, on the closed day.
do $$
declare v_gross text;
begin
  select gross_total into v_gross from public.reverse_purchase_invoice(
    current_setting('p11.closed_inv')::uuid, 'عكس في يوم مقفل', current_date - 6, 'عكس متأخر معتمد');
  if v_gross <> '-11.50' then
    raise exception 'TEST FAILED: expected the closed-day reversal gross_total=-11.50, got %', v_gross;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Reads — derived status, store scope, statement, liabilities.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v jsonb; v_row jsonb;
begin
  v := public.list_purchase_invoices(current_date - 30, current_date);

  -- The reversed invoice is classified from ledger facts, not a column.
  select r into v_row from jsonb_array_elements(v -> 'rows') r where r ->> 'id' = current_setting('p11.inv1');
  if v_row ->> 'payment_status' <> 'reversed' then
    raise exception 'TEST FAILED: expected inv1 payment_status=reversed, got %', v_row ->> 'payment_status';
  end if;
  if v_row ->> 'gross_total' <> '1350.00' then
    raise exception 'TEST FAILED: expected inv1 gross_total=1350.00 as text, got %', v_row ->> 'gross_total';
  end if;

  -- An out-of-scope explicit store filter is REJECTED (§8).
  begin
    perform public.list_purchase_invoices(current_date - 30, current_date, array['ffffffff-ffff-4fff-8fff-ffffffffffff'::uuid]);
    raise exception 'TEST FAILED: an out-of-scope store filter was accepted';
  exception when others then
    if sqlerrm not like '%نطاق صلاحيتك%' then raise; end if;
  end;

  -- Detail view carries lines and payments.
  v := public.get_purchase_invoice(current_setting('p11.inv1')::uuid);
  if jsonb_array_length(v -> 'lines') <> 2 then
    raise exception 'TEST FAILED: expected 2 lines in the detail view, got %', jsonb_array_length(v -> 'lines');
  end if;
  if jsonb_array_length(v -> 'payments') <> 4 then -- 350 + its reversal, 50 + its reversal
    raise exception 'TEST FAILED: expected 4 payment entries in the detail view, got %', jsonb_array_length(v -> 'payments');
  end if;
  if v ->> 'outstanding' <> '0.00' then
    raise exception 'TEST FAILED: a fully reversed invoice pair should leave outstanding 0.00 on payments, got %', v ->> 'outstanding';
  end if;

  -- Supplier statement.
  v := public.get_supplier_statement(current_setting('p11.supplier')::uuid, current_date - 30, current_date);
  if v -> 'summary' ->> 'paid_total' <> '0.00' then
    raise exception 'TEST FAILED: statement paid_total should net to 0.00 after both reversals, got %', v -> 'summary' ->> 'paid_total';
  end if;

  -- Outstanding liabilities exclude reversed invoices entirely. Only the
  -- second supplier's 50.00 remains: inv1 and the closed-day invoice have both
  -- been reversed by now, and a reversed invoice owes nothing.
  v := public.get_supplier_outstanding_summary();
  if v -> 'summary' ->> 'outstanding_total' <> '50.00' then
    raise exception 'TEST FAILED: expected outstanding_total=50.00, got %', v -> 'summary' ->> 'outstanding_total';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8b. AS-OF-DATE SEMANTICS — a later-dated correction must never rewrite an
--     already-reported historical balance.
-- ---------------------------------------------------------------------------
-- This is the property that makes a purchase ledger auditable at all. Because
-- every document and payment is immutable, signed and business-dated, and a
-- correction is a NEW row carrying its OWN date (§85), a statement issued for
-- September must read the same tomorrow as it did on 1 October — no matter
-- what reversals happen in between.
do $$
declare
  v_sup uuid; v_inv uuid; v_pay uuid; v jsonb;
  v_close_before text; v_open_before text; v_cur_before text;
  v_close_after text; v_cur_after text;
  v_d0 date := current_date - 20;   -- inside the reported period
  v_from date := current_date - 25;
  v_to date := current_date - 15;
begin
  -- A dedicated supplier, so this section's arithmetic is not entangled with
  -- anything above.
  select id into v_sup from public.create_supplier('P11-ASOF', 'مورّد كشف الحساب');

  select id into v_inv from public.post_purchase_invoice(
    v_sup, current_setting('p11.store_a')::uuid,
    jsonb_build_array(jsonb_build_object('inventory_item_id', current_setting('p11.item'), 'quantity', 1, 'unit_net_cost', 1000,
      'tax_treatment', 'standard', 'tax_rate_percent', 15, 'net_amount', 1000, 'vat_amount', 150, 'gross_amount', 1150)),
    1000, 150, 1150, v_d0, 'ASOF-1');

  select id into v_pay from public.record_supplier_payment(v_inv, 400, 'cash', v_d0 + 1);

  v := public.get_supplier_statement(v_sup, v_from, v_to);
  v_open_before := v -> 'summary' ->> 'opening_balance';
  v_close_before := v -> 'summary' ->> 'closing_balance';
  v_cur_before := v -> 'summary' ->> 'current_balance';

  if v_open_before <> '0.00' then
    raise exception 'TEST FAILED: expected opening_balance 0.00 before any activity, got %', v_open_before;
  end if;
  if v_close_before <> '750.00' then -- 1150 invoiced − 400 paid, both inside the period
    raise exception 'TEST FAILED: expected closing_balance 750.00 as of the period end, got %', v_close_before;
  end if;
  if v_cur_before <> '750.00' then
    raise exception 'TEST FAILED: with no later activity, current_balance must equal closing_balance, got %', v_cur_before;
  end if;

  -- Now correct BOTH the payment and the invoice, dated TODAY — long after the
  -- reported period closed.
  perform public.reverse_supplier_payment(v_pay, 'تصحيح لاحق', current_date);
  perform public.reverse_purchase_invoice(v_inv, 'تصحيح لاحق', current_date);

  v := public.get_supplier_statement(v_sup, v_from, v_to);
  v_close_after := v -> 'summary' ->> 'closing_balance';
  v_cur_after := v -> 'summary' ->> 'current_balance';

  -- THE assertion: the historical figures are untouched.
  if v_close_after <> v_close_before then
    raise exception 'TEST FAILED (as-of-date): a reversal dated today changed the closing balance of a period that ended % — was %, now %', v_to, v_close_before, v_close_after;
  end if;
  if v -> 'summary' ->> 'opening_balance' <> v_open_before then
    raise exception 'TEST FAILED (as-of-date): a later reversal changed the opening balance';
  end if;
  if v -> 'summary' ->> 'invoiced_total' <> '1150.00' or v -> 'summary' ->> 'paid_total' <> '400.00' then
    raise exception 'TEST FAILED (as-of-date): a later reversal changed the period movement (invoiced %, paid %)',
      v -> 'summary' ->> 'invoiced_total', v -> 'summary' ->> 'paid_total';
  end if;
  if jsonb_array_length(v -> 'entries') <> 2 then
    raise exception 'TEST FAILED (as-of-date): the period should still contain exactly its own 2 entries, got %', jsonb_array_length(v -> 'entries');
  end if;

  -- ...while the CURRENT balance did move, and the two are reported as
  -- separate numbers so a reader is never left guessing which one they have.
  if v_cur_after <> '0.00' then
    raise exception 'TEST FAILED: after reversing both documents the current balance must be 0.00, got %', v_cur_after;
  end if;
  if v_cur_after = v_close_after then
    raise exception 'TEST FAILED: current_balance and closing_balance are indistinguishable — the as-of-date distinction is not actually being made';
  end if;

  -- A statement whose window ENDS today does see the corrections.
  v := public.get_supplier_statement(v_sup, v_from, current_date);
  if v -> 'summary' ->> 'closing_balance' <> '0.00' then
    raise exception 'TEST FAILED: a window ending today should close at 0.00, got %', v -> 'summary' ->> 'closing_balance';
  end if;
end;
$$;

-- Store-B-only actor sees nothing from Store A.
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
declare v jsonb;
begin
  v := public.list_purchase_invoices(current_date - 30, current_date);
  if (v ->> 'total_count')::int <> 0 then
    raise exception 'TEST FAILED: Store-B-only actor saw % Store-A purchase rows', v ->> 'total_count';
  end if;

  -- The DETAIL view must scope too. A list that filters correctly while the
  -- by-id read hands over the whole document would be a complete bypass:
  -- an id is guessable in a way a list result is not.
  begin
    perform public.get_purchase_invoice(current_setting('p11.inv1')::uuid);
    raise exception 'TEST FAILED: Store-B-only actor read a Store-A invoice by id';
  exception when others then
    if sqlerrm not like '%غير موجودة أو غير متاحة لك%' then raise; end if;
  end;

  -- Likewise the statement: a supplier is global, but its movements are not.
  v := public.get_supplier_statement(current_setting('p11.supplier')::uuid, current_date - 30, current_date);
  if jsonb_array_length(v -> 'entries') <> 0 then
    raise exception 'TEST FAILED: Store-B-only actor saw % Store-A entries in a supplier statement', jsonb_array_length(v -> 'entries');
  end if;
  if v -> 'summary' ->> 'invoiced_total' <> '0.00' then
    raise exception 'TEST FAILED: Store-B-only actor saw a non-zero invoiced total (%) for Store-A activity', v -> 'summary' ->> 'invoiced_total';
  end if;

  -- And the liabilities report.
  v := public.get_supplier_outstanding_summary();
  if v -> 'summary' ->> 'outstanding_total' <> '0.00' then
    raise exception 'TEST FAILED: Store-B-only actor saw % outstanding from another store', v -> 'summary' ->> 'outstanding_total';
  end if;
end;
$$;

-- No purchases.view -> no read at all.
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
begin
  begin
    perform public.list_purchase_invoices(current_date - 30, current_date);
    raise exception 'TEST FAILED: an actor without purchases.view read the purchase ledger';
  exception when others then
    if sqlerrm not like '%صلاحية%' then raise; end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Accounting boundary — purchases NEVER touch Phase 10 expenses.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"ba000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_expenses int;
begin
  select count(*) into v_expenses from public.store_expenses;
  if v_expenses <> 0 then
    raise exception 'TEST FAILED (CRITICAL accounting boundary): posting purchases created % store_expenses row(s) — an asset purchase must never become an operating expense', v_expenses;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Audit — one event per mutation.
-- ---------------------------------------------------------------------------
do $$
declare v_docs int; v_audit int; v_pays int; v_pay_audit int;
begin
  select count(*) into v_docs from public.purchase_invoices;
  select count(*) into v_audit from public.audit_logs
  where action in ('purchase.post', 'purchase.reverse') and entity_type = 'purchase_invoice';
  if v_audit <> v_docs then
    raise exception 'TEST FAILED: expected one audit row per purchase document (% docs), got %', v_docs, v_audit;
  end if;

  select count(*) into v_pays from public.supplier_payments;
  select count(*) into v_pay_audit from public.audit_logs
  where action in ('supplier_payment.record', 'supplier_payment.reverse') and entity_type = 'supplier_payment';
  if v_pay_audit <> v_pays then
    raise exception 'TEST FAILED: expected one audit row per payment entry (% entries), got %', v_pays, v_pay_audit;
  end if;

  if not exists (select 1 from public.audit_logs where action = 'supplier.create' and entity_type = 'supplier') then
    raise exception 'TEST FAILED: supplier creation was not audited';
  end if;
end;
$$;

do $$
begin
  raise notice '=== ALL purchases_core_phase11.test.sql ASSERTIONS PASSED ===';
end $$;

rollback;

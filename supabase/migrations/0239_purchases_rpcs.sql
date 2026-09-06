-- ============================================================================
-- 0239: Phase 11 — Purchases & Suppliers Core (3/4): SECURITY DEFINER RPCs
-- ============================================================================
-- Migrations 0001-0238 are unmodified.
--
-- Every mutation/read below is a SECURITY DEFINER RPC with search_path pinned
-- to public, pg_temp — the base tables carry zero direct-write RLS policy
-- (0238), so this is the only path that works at all. Money is always returned
-- ::text, read back from the STORED row, never echoed from a caller parameter.
--
-- INVENTORY IS POSTED THROUGH PHASE 9'S OWN ENGINE, NOT REIMPLEMENTED
-- ---------------------------------------------------------------------------
-- post_purchase_invoice() calls record_inventory_stock_movement() (0229) once
-- per line. That function already: checks the caller's permission (it takes
-- the permission key as a PARAMETER, which is why Phase 11 needs no change to
-- 0229 at all), validates operable-store scope, takes the 1008 advisory lock
-- for the (item, store) pair, refuses to drive a balance negative, and writes
-- its own audit event. Phase 11 duplicates none of that.
--
-- Because the whole posting runs inside ONE RPC — hence one transaction —
-- invoice header, lines and every inventory movement either all commit or all
-- roll back. There is no window in which stock moved but the document did not.
-- ---------------------------------------------------------------------------
begin;

-- ---------------------------------------------------------------------------
-- Suppliers.
-- ---------------------------------------------------------------------------
create or replace function public.create_supplier(
  p_code text,
  p_name_ar text,
  p_name_en text default null,
  p_vat_number text default null,
  p_contact_person text default null,
  p_phone text default null,
  p_email text default null,
  p_notes text default null
)
returns table (id uuid, code text, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
begin
  if v_actor is null or not public.has_permission('purchases.manage_suppliers') then
    raise exception 'ليست لديك صلاحية إدارة الموردين' using errcode = 'P0001';
  end if;

  if p_code is null or btrim(p_code) = '' then
    raise exception 'رمز المورّد مطلوب' using errcode = 'P0001';
  end if;
  if p_name_ar is null or btrim(p_name_ar) = '' then
    raise exception 'اسم المورّد مطلوب' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.suppliers s where lower(s.code) = lower(btrim(p_code))) then
    raise exception 'رمز المورّد مستخدم بالفعل' using errcode = 'P0001';
  end if;

  insert into public.suppliers (code, name_ar, name_en, vat_number, contact_person, phone, email, notes, created_by, updated_by)
  values (
    btrim(p_code), btrim(p_name_ar),
    nullif(btrim(coalesce(p_name_en, '')), ''), nullif(btrim(coalesce(p_vat_number, '')), ''),
    nullif(btrim(coalesce(p_contact_person, '')), ''), nullif(btrim(coalesce(p_phone, '')), ''),
    nullif(btrim(coalesce(p_email, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''),
    v_actor, v_actor
  )
  returning suppliers.id into v_id;

  perform public.log_audit_event('supplier.create', 'supplier', v_id, null,
    jsonb_build_object('code', btrim(p_code), 'name_ar', btrim(p_name_ar), 'vat_number', p_vat_number));

  return query select s.id, s.code, s.row_version from public.suppliers s where s.id = v_id;
end;
$$;

revoke execute on function public.create_supplier(text, text, text, text, text, text, text, text) from public;
grant execute on function public.create_supplier(text, text, text, text, text, text, text, text) to authenticated;

create or replace function public.update_supplier(
  p_id uuid,
  p_expected_version bigint,
  p_name_ar text,
  p_name_en text default null,
  p_vat_number text default null,
  p_contact_person text default null,
  p_phone text default null,
  p_email text default null,
  p_notes text default null
)
returns table (id uuid, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old public.suppliers%rowtype;
begin
  if v_actor is null or not public.has_permission('purchases.manage_suppliers') then
    raise exception 'ليست لديك صلاحية إدارة الموردين' using errcode = 'P0001';
  end if;
  if p_name_ar is null or btrim(p_name_ar) = '' then
    raise exception 'اسم المورّد مطلوب' using errcode = 'P0001';
  end if;

  -- Table-aliased so `id`/`row_version` resolve to the COLUMNS rather than
  -- colliding with this function's own RETURNS TABLE out-parameters (the
  -- run-time-only failure 0232 had to fix).
  select * into v_old from public.suppliers s where s.id = p_id for update;
  if not found then
    raise exception 'المورّد غير موجود' using errcode = 'P0001';
  end if;

  -- A NULL expected version is rejected explicitly: `row_version <> NULL` is
  -- NULL, never TRUE, so it would silently bypass optimistic concurrency.
  if p_expected_version is null then
    raise exception 'رقم إصدار المورّد (row_version) مطلوب للتعديل' using errcode = 'P0001';
  end if;
  if v_old.row_version is distinct from p_expected_version then
    raise exception 'تم تعديل هذا المورّد من قِبل مستخدم آخر، الرجاء إعادة التحميل والمحاولة مرة أخرى' using errcode = 'P0001';
  end if;

  update public.suppliers su
  set name_ar = btrim(p_name_ar),
      name_en = nullif(btrim(coalesce(p_name_en, '')), ''),
      vat_number = nullif(btrim(coalesce(p_vat_number, '')), ''),
      contact_person = nullif(btrim(coalesce(p_contact_person, '')), ''),
      phone = nullif(btrim(coalesce(p_phone, '')), ''),
      email = nullif(btrim(coalesce(p_email, '')), ''),
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      row_version = su.row_version + 1,
      updated_by = v_actor,
      updated_at = now()
  where su.id = p_id;

  perform public.log_audit_event('supplier.update', 'supplier', p_id,
    jsonb_build_object('name_ar', v_old.name_ar, 'vat_number', v_old.vat_number),
    jsonb_build_object('name_ar', btrim(p_name_ar), 'vat_number', p_vat_number));

  return query select p_id, s.row_version from public.suppliers s where s.id = p_id;
end;
$$;

revoke execute on function public.update_supplier(uuid, bigint, text, text, text, text, text, text, text) from public;
grant execute on function public.update_supplier(uuid, bigint, text, text, text, text, text, text, text) to authenticated;

create or replace function public.set_supplier_status(p_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old text;
begin
  if v_actor is null or not public.has_permission('purchases.manage_suppliers') then
    raise exception 'ليست لديك صلاحية إدارة الموردين' using errcode = 'P0001';
  end if;
  if p_status is null or p_status not in ('active', 'disabled') then
    raise exception 'حالة المورّد غير صالحة' using errcode = 'P0001';
  end if;

  select s.status into v_old from public.suppliers s where s.id = p_id for update;
  if v_old is null then
    raise exception 'المورّد غير موجود' using errcode = 'P0001';
  end if;

  update public.suppliers su
  set status = p_status, row_version = su.row_version + 1, updated_by = v_actor, updated_at = now()
  where su.id = p_id;

  perform public.log_audit_event(
    case when p_status = 'disabled' then 'supplier.disable' else 'supplier.enable' end,
    'supplier', p_id, jsonb_build_object('status', v_old), jsonb_build_object('status', p_status));
end;
$$;

revoke execute on function public.set_supplier_status(uuid, text) from public;
grant execute on function public.set_supplier_status(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- _purchase_daily_close_guard() — internal. The §12 Daily Close contract,
-- identical in shape to _store_expense_daily_close_guard() (0235) and
-- record_settlement_bank_movement()'s own (0188).
-- ---------------------------------------------------------------------------
create or replace function public._purchase_daily_close_guard(
  p_store_id uuid,
  p_business_date date,
  p_closed_day_reason text,
  p_what text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.acquire_daily_close_lock_shared(p_store_id, p_business_date);

  if exists (select 1 from public.daily_closings dc where dc.store_id = p_store_id and dc.business_date = p_business_date) then
    if not public.has_permission('purchases.process_closed_day') then
      raise exception 'تاريخ % (%) يقع في يوم مقفل لهذا الفرع — يتطلب صلاحية خاصة (purchases.process_closed_day)', p_what, p_business_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتنفيذ % في يوم مقفل', p_what using errcode = 'P0001';
    end if;
  end if;
end;
$$;

revoke execute on function public._purchase_daily_close_guard(uuid, date, text, text) from public;

-- ---------------------------------------------------------------------------
-- purchase_invoice_outstanding() — THE derived liability. Never a column.
-- ---------------------------------------------------------------------------
create or replace function public.purchase_invoice_outstanding(p_invoice_id uuid)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(
    (
      select pi.gross_total
      from public.purchase_invoices pi
      where pi.id = p_invoice_id
        and pi.entry_kind = 'invoice'
        -- A REVERSED invoice owes nothing. The reversal document carries the
        -- exact negative of the original, so the pair nets to zero; reporting
        -- the original's gross as still-outstanding would overstate the
        -- liability. reverse_purchase_invoice() refuses to run while any
        -- unreversed payment is still attached, so this can never mask money
        -- that actually changed hands.
        and not exists (
          select 1 from public.purchase_invoices r
          where r.reverses_invoice_id = pi.id and r.entry_kind = 'reversal'
        )
    ),
    0
  )
  - coalesce(
    (
      select sum(sp.amount)
      from public.supplier_payments sp
      join public.purchase_invoices pi on pi.id = sp.purchase_invoice_id
      where sp.purchase_invoice_id = p_invoice_id
        and not exists (
          select 1 from public.purchase_invoices r
          where r.reverses_invoice_id = pi.id and r.entry_kind = 'reversal'
        )
    ),
    0
  );
$$;

comment on function public.purchase_invoice_outstanding(uuid) is
  'Phase 11 (internal) — the amount still owed on an invoice: gross_total minus the SIGNED sum of its payments (so a reversed payment automatically restores the liability), and exactly 0 once the invoice itself has been reversed. Computed live from immutable ledger rows; there is deliberately no cached balance column anywhere. Performs no permission check: callers resolve authorisation first.';

revoke execute on function public.purchase_invoice_outstanding(uuid) from public;

-- ---------------------------------------------------------------------------
-- post_purchase_invoice() — the one act that also moves stock.
-- ---------------------------------------------------------------------------
-- p_lines is a jsonb array of objects:
--   { inventory_item_id, quantity, unit_net_cost, tax_treatment,
--     tax_rate_percent, net_amount, vat_amount, gross_amount }
-- Every monetary value is taken EXACTLY as supplied (the supplier's document
-- is the source of truth) and validated for internal consistency; nothing is
-- recomputed or rounded on the caller's behalf.
create or replace function public.post_purchase_invoice(
  p_supplier_id uuid,
  p_store_id uuid,
  p_lines jsonb,
  p_net_total numeric,
  p_vat_total numeric,
  p_gross_total numeric,
  p_business_date date default public.business_today(),
  p_supplier_invoice_number text default null,
  p_supplier_invoice_date date default null,
  p_notes text default null,
  p_closed_day_reason text default null
)
returns table (id uuid, purchase_number text, gross_total text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_supplier public.suppliers%rowtype;
  v_invoice_id uuid;
  v_number text;
  v_line jsonb;
  v_item public.inventory_items%rowtype;
  v_item_id uuid;
  v_movement_id uuid;
  v_sum_net numeric(14, 2) := 0;
  v_sum_vat numeric(14, 2) := 0;
  v_sum_gross numeric(14, 2) := 0;
  v_qty numeric(12, 3);
  v_net numeric(14, 2);
  v_vat numeric(14, 2);
  v_gross numeric(14, 2);
  v_treatment text;
  v_rate numeric(6, 3);
  v_unit numeric(12, 4);
  v_stored_gross numeric(14, 2);
  v_count int := 0;
begin
  if v_actor is null or not public.has_permission('purchases.create') then
    raise exception 'ليست لديك صلاحية ترحيل فاتورة شراء' using errcode = 'P0001';
  end if;

  if p_business_date is null then
    raise exception 'تاريخ الفاتورة مطلوب' using errcode = 'P0001';
  end if;
  if p_business_date > public.business_today() then
    raise exception 'لا يمكن ترحيل فاتورة بتاريخ مستقبلي' using errcode = 'P0001';
  end if;

  -- Write scope is OPERABLE, matching every other write path.
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'ليس لديك صلاحية الوصول لهذا الفرع' using errcode = 'P0001';
  end if;

  select * into v_supplier from public.suppliers s where s.id = p_supplier_id;
  if v_supplier.id is null then
    raise exception 'المورّد غير موجود' using errcode = 'P0001';
  end if;
  if v_supplier.status <> 'active' then
    raise exception 'المورّد غير نشط' using errcode = 'P0001';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'يجب أن تحتوي الفاتورة على بند واحد على الأقل' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_net_total, 'إجمالي الصافي');
  perform public.validate_money_scale(p_vat_total, 'إجمالي الضريبة');
  perform public.validate_money_scale(p_gross_total, 'الإجمالي');

  if p_gross_total is null or p_gross_total <= 0 then
    raise exception 'إجمالي الفاتورة يجب أن يكون رقمًا موجبًا' using errcode = 'P0001';
  end if;

  -- ---------------------------------------------------------------------
  -- PASS 1 — validate every line and accumulate its sums BEFORE anything is
  -- written. Validation order matters for the operator: if the header were
  -- inserted first, a line arithmetic error would surface as a raw
  -- `purchase_invoices_totals_consistent` constraint name instead of a
  -- sentence naming the offending line. Nothing is written until the whole
  -- document is known to be internally consistent.
  -- ---------------------------------------------------------------------
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_count := v_count + 1;

    v_qty := (v_line ->> 'quantity')::numeric;
    v_treatment := v_line ->> 'tax_treatment';
    v_rate := coalesce((v_line ->> 'tax_rate_percent')::numeric, 0);
    v_net := (v_line ->> 'net_amount')::numeric;
    v_vat := coalesce((v_line ->> 'vat_amount')::numeric, 0);
    v_gross := (v_line ->> 'gross_amount')::numeric;

    if v_qty is null or v_qty <= 0 then
      raise exception 'كمية البند % يجب أن تكون رقمًا موجبًا', v_count using errcode = 'P0001';
    end if;
    if v_treatment is null or v_treatment not in ('standard', 'zero_rated', 'exempt', 'out_of_scope') then
      raise exception 'المعالجة الضريبية للبند % غير صالحة', v_count using errcode = 'P0001';
    end if;

    perform public.validate_money_scale(v_net, format('صافي البند %s', v_count));
    perform public.validate_money_scale(v_vat, format('ضريبة البند %s', v_count));
    perform public.validate_money_scale(v_gross, format('إجمالي البند %s', v_count));

    -- Exact, never "close enough": the supplier's own arithmetic must hold.
    if v_gross <> v_net + v_vat then
      raise exception 'إجمالي البند % لا يساوي الصافي + الضريبة (%, %, %)', v_count, v_net, v_vat, v_gross using errcode = 'P0001';
    end if;

    -- A zero-rated / exempt / out-of-scope line cannot carry VAT. Phase 11
    -- does not DECIDE the treatment — it refuses a document that contradicts
    -- the treatment the supplier itself declared.
    if v_treatment <> 'standard' and (v_vat <> 0 or v_rate <> 0) then
      raise exception 'البند % معالجته الضريبية % ولا يجوز أن يحمل ضريبة أو نسبة', v_count, v_treatment using errcode = 'P0001';
    end if;

    v_sum_net := v_sum_net + v_net;
    v_sum_vat := v_sum_vat + v_vat;
    v_sum_gross := v_sum_gross + v_gross;
  end loop;

  -- The header must equal its own lines, exactly.
  if v_sum_net <> p_net_total or v_sum_vat <> p_vat_total or v_sum_gross <> p_gross_total then
    raise exception 'إجماليات الفاتورة لا تطابق مجموع البنود (الصافي %/%، الضريبة %/%، الإجمالي %/%)',
      v_sum_net, p_net_total, v_sum_vat, p_vat_total, v_sum_gross, p_gross_total using errcode = 'P0001';
  end if;

  perform public._purchase_daily_close_guard(p_store_id, p_business_date, p_closed_day_reason, 'ترحيل الفاتورة');

  v_number := public.generate_purchase_number();

  insert into public.purchase_invoices (
    purchase_number, supplier_id, store_id, business_date, entry_kind,
    supplier_invoice_number, supplier_invoice_date,
    supplier_name_snapshot, supplier_vat_number_snapshot,
    net_total, vat_total, gross_total, notes, closed_day_reason, created_by
  )
  values (
    v_number, p_supplier_id, p_store_id, p_business_date, 'invoice',
    nullif(btrim(coalesce(p_supplier_invoice_number, '')), ''), p_supplier_invoice_date,
    v_supplier.name_ar, v_supplier.vat_number,
    p_net_total, p_vat_total, p_gross_total,
    nullif(btrim(coalesce(p_notes, '')), ''), nullif(btrim(coalesce(p_closed_day_reason, '')), ''), v_actor
  )
  returning purchase_invoices.id, purchase_invoices.gross_total into v_invoice_id, v_stored_gross;

  -- ---------------------------------------------------------------------
  -- DETERMINISTIC LOCK ORDERING — acquire every distinct (item, store) 1008
  -- lock up front, in canonical item-id order, before posting any movement.
  -- ---------------------------------------------------------------------
  -- Phase 11 is the FIRST caller to take more than one 1008 lock in a single
  -- transaction (Phase 9's engine is called once per user action; a purchase
  -- invoice calls it once per line). Without this loop the locks are acquired
  -- in whatever order the client happened to list the lines, so two operators
  -- posting invoices that share items in opposite orders form a genuine lock
  -- cycle: A holds item Y and waits for X while B holds X and waits for Y.
  -- PostgreSQL breaks that cycle by aborting one transaction with
  -- 'deadlock detected' — a spurious failure of a perfectly valid purchase.
  --
  -- Acquiring in a canonical order that every caller shares makes the cycle
  -- unconstructible: a transaction can only ever wait on a lock that sorts
  -- after every lock it already holds. Advisory locks are re-entrant within a
  -- transaction, so record_inventory_stock_movement()'s own acquisition below
  -- is then a no-op — Phase 9's engine is still the only thing that writes a
  -- movement, and it is not modified in any way.
  --
  -- reverse_purchase_invoice() uses the identical ordering, so a posting and a
  -- reversal cannot deadlock against each other either.
  for v_item_id in
    select distinct (l ->> 'inventory_item_id')::uuid
    from jsonb_array_elements(p_lines) l
    order by 1
  loop
    perform public.acquire_inventory_item_store_lock(v_item_id, p_store_id);
  end loop;

  -- ---------------------------------------------------------------------
  -- PASS 2 — the document is proven consistent; now write the lines and move
  -- the stock. Amounts are re-read from the same jsonb, so what is stored is
  -- exactly what was validated above.
  -- ---------------------------------------------------------------------
  v_count := 0;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_count := v_count + 1;

    select * into v_item from public.inventory_items i where i.id = (v_line ->> 'inventory_item_id')::uuid;
    if v_item.id is null then
      raise exception 'الصنف غير موجود في البند %', v_count using errcode = 'P0001';
    end if;
    if not v_item.active then
      raise exception 'الصنف غير نشط في البند % (%)', v_count, v_item.sku using errcode = 'P0001';
    end if;

    v_qty := (v_line ->> 'quantity')::numeric;
    v_unit := (v_line ->> 'unit_net_cost')::numeric;
    v_treatment := v_line ->> 'tax_treatment';
    v_rate := coalesce((v_line ->> 'tax_rate_percent')::numeric, 0);
    v_net := (v_line ->> 'net_amount')::numeric;
    v_vat := coalesce((v_line ->> 'vat_amount')::numeric, 0);
    v_gross := (v_line ->> 'gross_amount')::numeric;

    -- Stock is posted through PHASE 9's engine (0229), which takes the 1008
    -- lock, validates the operable store again, refuses a negative balance and
    -- writes its own inventory audit event. The permission key is passed as a
    -- parameter — that is exactly why 0229 accepts one — so a purchasing actor
    -- needs purchases.create, not an inventory permission.
    select m.id into v_movement_id
    from public.record_inventory_stock_movement(
      'purchases.create', v_item.id, p_store_id, 'receive', v_qty, p_business_date,
      null, v_number
    ) m;

    insert into public.purchase_invoice_lines (
      purchase_invoice_id, store_id, inventory_item_id, item_sku_snapshot, item_name_snapshot,
      quantity, unit_net_cost, tax_treatment, tax_rate_percent,
      net_amount, vat_amount, gross_amount, inventory_movement_id
    )
    values (
      v_invoice_id, p_store_id, v_item.id, v_item.sku, v_item.name_ar,
      v_qty, v_unit, v_treatment, v_rate,
      v_net, v_vat, v_gross, v_movement_id
    );
  end loop;

  perform public.log_audit_event(
    'purchase.post', 'purchase_invoice', v_invoice_id, null,
    jsonb_build_object(
      'purchase_number', v_number, 'supplier_id', p_supplier_id, 'store_id', p_store_id,
      'business_date', p_business_date, 'gross_total', v_stored_gross::text,
      'supplier_invoice_number', p_supplier_invoice_number, 'lines', v_count
    )
  );

  return query select v_invoice_id, v_number, v_stored_gross::text;
end;
$$;

revoke execute on function public.post_purchase_invoice(uuid, uuid, jsonb, numeric, numeric, numeric, date, text, date, text, text) from public;
grant execute on function public.post_purchase_invoice(uuid, uuid, jsonb, numeric, numeric, numeric, date, text, date, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- reverse_purchase_invoice() — the ONLY correction path.
-- ---------------------------------------------------------------------------
create or replace function public.reverse_purchase_invoice(
  p_invoice_id uuid,
  p_reason text,
  p_reversal_business_date date default public.business_today(),
  p_closed_day_reason text default null
)
returns table (id uuid, purchase_number text, gross_total text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_original public.purchase_invoices%rowtype;
  v_reversal_id uuid;
  v_number text;
  v_line public.purchase_invoice_lines%rowtype;
  v_item_id uuid;
  v_movement_id uuid;
  v_stored_gross numeric(14, 2);
  v_unreversed int;
begin
  if v_actor is null or not public.has_permission('purchases.reverse') then
    raise exception 'ليست لديك صلاحية عكس فاتورة شراء' using errcode = 'P0001';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'سبب العكس مطلوب' using errcode = 'P0001';
  end if;
  if p_reversal_business_date is null then
    raise exception 'تاريخ العكس مطلوب' using errcode = 'P0001';
  end if;
  if p_reversal_business_date > public.business_today() then
    raise exception 'لا يمكن عكس فاتورة بتاريخ مستقبلي' using errcode = 'P0001';
  end if;

  -- Row-locks the invoice for the rest of this transaction: this is what
  -- serializes a reversal against a concurrent payment (which locks the same
  -- row) and against a second concurrent reversal.
  select * into v_original from public.purchase_invoices pi where pi.id = p_invoice_id for update;
  if v_original.id is null then
    raise exception 'الفاتورة غير موجودة' using errcode = 'P0001';
  end if;
  if v_original.entry_kind <> 'invoice' then
    raise exception 'لا يمكن عكس مستند عكس — اعكس الفاتورة الأصلية بدلًا من ذلك' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_original.store_id) then
    raise exception 'ليس لديك صلاحية الوصول لهذا الفرع' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.purchase_invoices r where r.reverses_invoice_id = p_invoice_id and r.entry_kind = 'reversal') then
    raise exception 'تم عكس هذه الفاتورة مسبقًا' using errcode = 'P0001';
  end if;
  if p_reversal_business_date < v_original.business_date then
    raise exception 'تاريخ العكس لا يمكن أن يسبق تاريخ الفاتورة الأصلية (%)', v_original.business_date using errcode = 'P0001';
  end if;

  -- A liability that has been (even partly) settled cannot simply vanish:
  -- the payments must be reversed first, so the money trail stays explicit.
  select count(*) into v_unreversed
  from public.supplier_payments sp
  where sp.purchase_invoice_id = p_invoice_id
    and sp.entry_kind = 'payment'
    and not exists (
      select 1 from public.supplier_payments r
      where r.reverses_payment_id = sp.id and r.entry_kind = 'reversal'
    );
  if v_unreversed > 0 then
    raise exception 'لا يمكن عكس الفاتورة وبها % دفعة غير معكوسة — اعكس المدفوعات أولًا', v_unreversed using errcode = 'P0001';
  end if;

  -- §85 Event Date: the reversal is guarded against ITS OWN business date.
  perform public._purchase_daily_close_guard(v_original.store_id, p_reversal_business_date, p_closed_day_reason, 'عكس الفاتورة');

  v_number := public.generate_purchase_number();

  insert into public.purchase_invoices (
    purchase_number, supplier_id, store_id, business_date, entry_kind,
    supplier_invoice_number, supplier_invoice_date,
    supplier_name_snapshot, supplier_vat_number_snapshot,
    net_total, vat_total, gross_total, notes,
    reverses_invoice_id, reversal_reason, closed_day_reason, created_by
  )
  values (
    v_number, v_original.supplier_id, v_original.store_id, p_reversal_business_date, 'reversal',
    -- The supplier's document number is NOT carried onto the reversal: the
    -- per-supplier unique index covers real invoices only, and a reversal is
    -- our document, not a second supplier invoice.
    null, v_original.supplier_invoice_date,
    v_original.supplier_name_snapshot, v_original.supplier_vat_number_snapshot,
    -v_original.net_total, -v_original.vat_total, -v_original.gross_total, v_original.notes,
    p_invoice_id, btrim(p_reason), nullif(btrim(coalesce(p_closed_day_reason, '')), ''), v_actor
  )
  returning purchase_invoices.id, purchase_invoices.gross_total into v_reversal_id, v_stored_gross;

  -- Same canonical 1008 lock ordering as post_purchase_invoice(), so a
  -- reversal and a posting that share items can never form a lock cycle.
  for v_item_id in
    select distinct l.inventory_item_id
    from public.purchase_invoice_lines l
    where l.purchase_invoice_id = p_invoice_id
    order by 1
  loop
    perform public.acquire_inventory_item_store_lock(v_item_id, v_original.store_id);
  end loop;

  -- Exact compensating inventory movements, dated on the REVERSAL's own
  -- business date. 'adjust' (not 'receive') because the delta is negative —
  -- 0228's CHECK requires a receive to be positive — and 0229 requires a
  -- reason for an adjust, which the reversal supplies.
  for v_line in
    select * from public.purchase_invoice_lines l where l.purchase_invoice_id = p_invoice_id order by l.created_at
  loop
    select m.id into v_movement_id
    from public.record_inventory_stock_movement(
      'purchases.reverse', v_line.inventory_item_id, v_line.store_id, 'adjust', -v_line.quantity,
      p_reversal_business_date, format('عكس فاتورة شراء %s: %s', v_original.purchase_number, btrim(p_reason)), v_number
    ) m;

    insert into public.purchase_invoice_lines (
      purchase_invoice_id, store_id, inventory_item_id, item_sku_snapshot, item_name_snapshot,
      quantity, unit_net_cost, tax_treatment, tax_rate_percent,
      net_amount, vat_amount, gross_amount, inventory_movement_id
    )
    values (
      v_reversal_id, v_line.store_id, v_line.inventory_item_id, v_line.item_sku_snapshot, v_line.item_name_snapshot,
      -v_line.quantity, v_line.unit_net_cost, v_line.tax_treatment, v_line.tax_rate_percent,
      -v_line.net_amount, -v_line.vat_amount, -v_line.gross_amount, v_movement_id
    );
  end loop;

  perform public.log_audit_event(
    'purchase.reverse', 'purchase_invoice', v_reversal_id,
    jsonb_build_object('reversed_purchase_number', v_original.purchase_number, 'original_gross_total', v_original.gross_total::text, 'original_business_date', v_original.business_date),
    jsonb_build_object('purchase_number', v_number, 'gross_total', v_stored_gross::text, 'business_date', p_reversal_business_date, 'reason', btrim(p_reason))
  );

  return query select v_reversal_id, v_number, v_stored_gross::text;
end;
$$;

revoke execute on function public.reverse_purchase_invoice(uuid, text, date, text) from public;
grant execute on function public.reverse_purchase_invoice(uuid, text, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- record_supplier_payment() — partial payments, never overpaying.
-- ---------------------------------------------------------------------------
create or replace function public.record_supplier_payment(
  p_invoice_id uuid,
  p_amount numeric,
  p_payment_mode text,
  p_business_date date default public.business_today(),
  p_payment_reference text default null,
  p_notes text default null,
  p_closed_day_reason text default null
)
returns table (id uuid, payment_number text, amount text, outstanding_after text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_invoice public.purchase_invoices%rowtype;
  v_id uuid;
  v_number text;
  v_stored_amount numeric(14, 2);
  v_outstanding numeric(14, 2);
begin
  if v_actor is null or not public.has_permission('purchases.record_payment') then
    raise exception 'ليست لديك صلاحية تسجيل دفعة لمورّد' using errcode = 'P0001';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'مبلغ الدفعة يجب أن يكون رقمًا موجبًا' using errcode = 'P0001';
  end if;
  perform public.validate_money_scale(p_amount, 'مبلغ الدفعة');

  if p_payment_mode is null or p_payment_mode not in ('cash', 'bank_transfer', 'cheque', 'other') then
    raise exception 'طريقة الدفع غير صالحة' using errcode = 'P0001';
  end if;
  if p_business_date is null then
    raise exception 'تاريخ الدفعة مطلوب' using errcode = 'P0001';
  end if;
  if p_business_date > public.business_today() then
    raise exception 'لا يمكن تسجيل دفعة بتاريخ مستقبلي' using errcode = 'P0001';
  end if;

  -- THE serialization point. Locking the invoice row means two concurrent
  -- payments cannot both read the same remaining balance and both be accepted:
  -- the second waits here, then re-reads the balance the first actually left.
  select * into v_invoice from public.purchase_invoices pi where pi.id = p_invoice_id for update;
  if v_invoice.id is null then
    raise exception 'الفاتورة غير موجودة' using errcode = 'P0001';
  end if;
  if v_invoice.entry_kind <> 'invoice' then
    raise exception 'لا يمكن الدفع مقابل مستند عكس' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_invoice.store_id) then
    raise exception 'ليس لديك صلاحية الوصول لهذا الفرع' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.purchase_invoices r where r.reverses_invoice_id = p_invoice_id and r.entry_kind = 'reversal') then
    raise exception 'لا يمكن الدفع مقابل فاتورة معكوسة' using errcode = 'P0001';
  end if;
  if p_business_date < v_invoice.business_date then
    raise exception 'تاريخ الدفعة لا يمكن أن يسبق تاريخ الفاتورة (%)', v_invoice.business_date using errcode = 'P0001';
  end if;

  v_outstanding := public.purchase_invoice_outstanding(p_invoice_id);
  if p_amount > v_outstanding then
    raise exception 'مبلغ الدفعة (%) يتجاوز المتبقي على الفاتورة (%)', p_amount, v_outstanding using errcode = 'P0001';
  end if;

  perform public._purchase_daily_close_guard(v_invoice.store_id, p_business_date, p_closed_day_reason, 'تسجيل الدفعة');

  v_number := public.generate_supplier_payment_number();

  insert into public.supplier_payments (
    payment_number, purchase_invoice_id, supplier_id, store_id, business_date, entry_kind,
    amount, payment_mode, payment_reference, notes, closed_day_reason, created_by
  )
  values (
    v_number, p_invoice_id, v_invoice.supplier_id, v_invoice.store_id, p_business_date, 'payment',
    p_amount, p_payment_mode, nullif(btrim(coalesce(p_payment_reference, '')), ''),
    nullif(btrim(coalesce(p_notes, '')), ''), nullif(btrim(coalesce(p_closed_day_reason, '')), ''), v_actor
  )
  returning supplier_payments.id, supplier_payments.amount into v_id, v_stored_amount;

  perform public.log_audit_event(
    'supplier_payment.record', 'supplier_payment', v_id, null,
    jsonb_build_object('payment_number', v_number, 'purchase_invoice_id', p_invoice_id,
      'amount', v_stored_amount::text, 'payment_mode', p_payment_mode, 'business_date', p_business_date)
  );

  return query select v_id, v_number, v_stored_amount::text, public.purchase_invoice_outstanding(p_invoice_id)::text;
end;
$$;

revoke execute on function public.record_supplier_payment(uuid, numeric, text, date, text, text, text) from public;
grant execute on function public.record_supplier_payment(uuid, numeric, text, date, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- reverse_supplier_payment()
-- ---------------------------------------------------------------------------
create or replace function public.reverse_supplier_payment(
  p_payment_id uuid,
  p_reason text,
  p_reversal_business_date date default public.business_today(),
  p_closed_day_reason text default null
)
returns table (id uuid, payment_number text, amount text, outstanding_after text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_original public.supplier_payments%rowtype;
  v_id uuid;
  v_number text;
  v_stored_amount numeric(14, 2);
begin
  if v_actor is null or not public.has_permission('purchases.reverse_payment') then
    raise exception 'ليست لديك صلاحية عكس دفعة مورّد' using errcode = 'P0001';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'سبب العكس مطلوب' using errcode = 'P0001';
  end if;
  if p_reversal_business_date is null then
    raise exception 'تاريخ العكس مطلوب' using errcode = 'P0001';
  end if;
  if p_reversal_business_date > public.business_today() then
    raise exception 'لا يمكن عكس دفعة بتاريخ مستقبلي' using errcode = 'P0001';
  end if;

  select * into v_original from public.supplier_payments sp where sp.id = p_payment_id for update;
  if v_original.id is null then
    raise exception 'الدفعة غير موجودة' using errcode = 'P0001';
  end if;
  if v_original.entry_kind <> 'payment' then
    raise exception 'لا يمكن عكس حركة عكس — اعكس الدفعة الأصلية بدلًا من ذلك' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_original.store_id) then
    raise exception 'ليس لديك صلاحية الوصول لهذا الفرع' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.supplier_payments r where r.reverses_payment_id = p_payment_id and r.entry_kind = 'reversal') then
    raise exception 'تم عكس هذه الدفعة مسبقًا' using errcode = 'P0001';
  end if;
  if p_reversal_business_date < v_original.business_date then
    raise exception 'تاريخ العكس لا يمكن أن يسبق تاريخ الدفعة الأصلية (%)', v_original.business_date using errcode = 'P0001';
  end if;

  perform public._purchase_daily_close_guard(v_original.store_id, p_reversal_business_date, p_closed_day_reason, 'عكس الدفعة');

  v_number := public.generate_supplier_payment_number();

  insert into public.supplier_payments (
    payment_number, purchase_invoice_id, supplier_id, store_id, business_date, entry_kind,
    amount, payment_mode, payment_reference, notes,
    reverses_payment_id, reversal_reason, closed_day_reason, created_by
  )
  values (
    v_number, v_original.purchase_invoice_id, v_original.supplier_id, v_original.store_id, p_reversal_business_date, 'reversal',
    -v_original.amount, v_original.payment_mode, v_original.payment_reference, v_original.notes,
    p_payment_id, btrim(p_reason), nullif(btrim(coalesce(p_closed_day_reason, '')), ''), v_actor
  )
  returning supplier_payments.id, supplier_payments.amount into v_id, v_stored_amount;

  perform public.log_audit_event(
    'supplier_payment.reverse', 'supplier_payment', v_id,
    jsonb_build_object('reversed_payment_number', v_original.payment_number, 'original_amount', v_original.amount::text, 'original_business_date', v_original.business_date),
    jsonb_build_object('payment_number', v_number, 'amount', v_stored_amount::text, 'business_date', p_reversal_business_date, 'reason', btrim(p_reason))
  );

  return query select v_id, v_number, v_stored_amount::text, public.purchase_invoice_outstanding(v_original.purchase_invoice_id)::text;
end;
$$;

revoke execute on function public.reverse_supplier_payment(uuid, text, date, text) from public;
grant execute on function public.reverse_supplier_payment(uuid, text, date, text) to authenticated;

commit;

-- ============================================================================
-- 0068: Phase 3 — Sales Integrity Patch 3.1 (4/7): create_sales_order()
-- rewritten for concurrency-safe locking + the shared reconciling calc helper
-- ============================================================================
-- Migrations 0001-0067 are unmodified. CREATE OR REPLACE of create_sales_
-- order() (0061) — every validation rule, error message, and business flow
-- is byte-for-byte unchanged EXCEPT:
--   (a) two new advisory-lock acquisitions (spec items 5 and 7):
--       - acquire_daily_close_lock_shared(store_id, sale_date) (0065),
--         acquired BEFORE the daily_closings existence check, so this Sale
--         can never slip through between a concurrent close_sales_day()'s
--         own check and its commit (the exact race spec item 5 describes).
--       - acquire_financial_master_lock_shared() (0065), acquired BEFORE
--         resolving the payment fee version (the first financial-master
--         read in this function) and held for the rest of the transaction,
--         so gold price / manufacturing fee / VAT rate / payment fee can
--         never change mid-resolution for this Order (spec item 7).
--   (b) every item's cost breakdown is now computed via the single shared
--       compute_sales_item_costs() helper (0065) instead of inline
--       round()-per-column arithmetic — this changes the ROUNDING RESULT
--       only at the exact boundary spec item 8 identified as broken (e.g.
--       weight=0.0100/gold=300/mfg=10/vat=15%/sale=100.00 now yields
--       total_cost=3.57/gross_profit=96.43, reconciling exactly, instead of
--       the old 3.57/96.44 mismatch) — every other input produces the
--       identical result as before (verified against every existing
--       sales_core.test.sql worked example).
--   (c) every inserted item is explicitly stamped status = 'active' (spec
--       item 1) — the column defaults to 'active' anyway (0067), but an
--       explicit value here matches this project's existing explicit-
--       column-list convention and makes the write self-documenting.
-- ---------------------------------------------------------------------------
create or replace function public.create_sales_order(
  p_store_id uuid,
  p_sale_date date,
  p_payment_method_id uuid,
  p_collection_channel_id uuid,
  p_items jsonb,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_notes text default null,
  p_closed_day_reason text default null
)
returns table (id uuid, order_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_today date := public.business_today();
  v_order_id uuid;
  v_order_number text;
  v_payment_method record;
  v_collection_channel record;
  v_payment_fee record; -- fee_version_id, percentage_fee, fixed_fee
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_item jsonb;
  v_line_no integer := 0;
  v_category_id uuid;
  v_karat_id uuid;
  v_weight numeric;
  v_sale_price numeric;
  v_item_name text;
  v_description text;
  v_sku text;
  v_category record;
  v_karat record;
  v_gold record; -- daily_gold_price_id, price_per_gram
  v_mfg record;  -- manufacturing_fee_version_id, fee_per_gram
  v_vat record;  -- vat_rate_version_id, rate_percent
  v_costs record; -- gold_component_cost, manufacturing_component_cost, base_cost, vat_cost, total_cost, gross_profit
  v_subtotal numeric := 0;
  v_order_gross_profit numeric := 0;
  v_payment_fee_amount numeric;
  v_net_sales_profit numeric;
  v_item_id uuid;
begin
  -- 1-2) Authenticate actor + sales.create permission.
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لإنشاء عملية بيع' using errcode = 'P0001';
  end if;

  if not public.has_permission('sales.create') then
    raise exception 'ليست لديك صلاحية إنشاء عمليات بيع' using errcode = 'P0001';
  end if;

  -- 3) Actor active — redundant with has_permission()'s own is_active_user()
  -- check above, kept explicit for defense-in-depth per spec §11 step 3.
  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_store_id is null or p_sale_date is null or p_payment_method_id is null or p_collection_channel_id is null then
    raise exception 'المتجر وتاريخ البيع وطريقة الدفع وقناة التحصيل كلها مطلوبة' using errcode = 'P0001';
  end if;

  -- 4-5) Store must be within the actor's OPERABLE scope (spec §14).
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'هذا المتجر غير متاح لك لإنشاء عمليات بيع فيه، أو أنه غير نشط' using errcode = 'P0001';
  end if;

  -- 6) sale_date allowed — never in the future.
  if p_sale_date > v_today then
    raise exception 'لا يمكن تسجيل عملية بيع بتاريخ مستقبلي (%)', p_sale_date using errcode = 'P0001';
  end if;

  -- Patch 3.1 item 5 — SHARED daily-close lock BEFORE reading daily_closings
  -- for this (store, date). Blocks only against a concurrent EXCLUSIVE
  -- close_sales_day() for this exact day; does not serialize against other
  -- concurrent Sales for the same/different day (they all take the SHARED
  -- lock, which never blocks other SHARED holders). See migration 0065.
  perform public.acquire_daily_close_lock_shared(p_store_id, p_sale_date);

  select exists(
    select 1 from public.daily_closings
    where store_id = p_store_id and business_date = p_sale_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('sales.edit_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن إنشاء عملية بيع جديدة فيه إلا بصلاحية خاصة (sales.edit_closed_day)', p_sale_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لإنشاء عملية بيع في يوم مقفل (%)', p_sale_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  -- 7) Master references — payment method / collection channel must exist
  -- and be active for a NEW sale (spec §12).
  select * into v_payment_method from public.payment_methods where payment_methods.id = p_payment_method_id;
  if v_payment_method.id is null then
    raise exception 'طريقة الدفع غير موجودة' using errcode = 'P0001';
  end if;
  if v_payment_method.status <> 'active' then
    raise exception 'طريقة الدفع "%" غير نشطة — لا يمكن استخدامها في عملية بيع جديدة', v_payment_method.name_ar using errcode = 'P0001';
  end if;

  select * into v_collection_channel from public.collection_channels where collection_channels.id = p_collection_channel_id;
  if v_collection_channel.id is null then
    raise exception 'قناة التحصيل غير موجودة' using errcode = 'P0001';
  end if;
  if v_collection_channel.status <> 'active' then
    raise exception 'قناة التحصيل "%" غير نشطة — لا يمكن استخدامها في عملية بيع جديدة', v_collection_channel.name_ar using errcode = 'P0001';
  end if;

  -- Patch 3.1 item 7 — SHARED financial-master lock BEFORE the first
  -- financial-master resolution (payment fee) in this function, held for
  -- the rest of the transaction so every item's gold/manufacturing/VAT
  -- resolution below, plus this payment fee resolution, are guaranteed to
  -- see a financially-consistent snapshot for the whole Order — a
  -- concurrent price/fee/VAT write (which takes the EXCLUSIVE counterpart,
  -- 0066) can never commit in the middle of this resolution window. See
  -- migration 0065.
  perform public.acquire_financial_master_lock_shared();

  -- 8 (order-level) Resolve the payment fee version for this method/date.
  select * into v_payment_fee from public.payment_fee_for_method_on_date(p_payment_method_id, p_sale_date);

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'يجب أن تحتوي عملية البيع على بند واحد على الأقل' using errcode = 'P0001';
  end if;

  -- 11 (partial) Order number + header row FIRST (placeholder totals,
  -- corrected below once every item is resolved and computed).
  v_order_number := public.generate_sales_order_number();

  insert into public.sales_orders (
    order_number, store_id, sale_date, salesperson_id, payment_method_id, collection_channel_id,
    customer_name, customer_phone, notes,
    payment_fee_version_id, payment_fee_percentage_snapshot, payment_fee_fixed_snapshot,
    payment_fee_amount, subtotal, gross_profit, net_sales_profit, calculation_version,
    created_by, updated_by
  ) values (
    v_order_number, p_store_id, p_sale_date, v_actor, p_payment_method_id, p_collection_channel_id,
    nullif(btrim(coalesce(p_customer_name, '')), ''), nullif(btrim(coalesce(p_customer_phone, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''),
    v_payment_fee.fee_version_id, v_payment_fee.percentage_fee, v_payment_fee.fixed_fee,
    0, 0, 0, 0, 1,
    v_actor, v_actor
  )
  returning sales_orders.id into v_order_id;

  -- 8-10 (per item) Resolve every item's financial snapshots and compute
  -- its cost breakdown via the shared reconciling helper (Patch 3.1 items
  -- 8/10 — compute_sales_item_costs(), 0065).
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_line_no := v_line_no + 1;

    if v_item ->> 'category_id' is null or v_item ->> 'karat_id' is null
       or v_item ->> 'weight_grams' is null or v_item ->> 'sale_price' is null then
      raise exception 'كل بند يجب أن يحدد التصنيف والعيار والوزن وسعر البيع (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;

    v_category_id := (v_item ->> 'category_id')::uuid;
    v_karat_id := (v_item ->> 'karat_id')::uuid;
    v_weight := (v_item ->> 'weight_grams')::numeric;
    v_sale_price := (v_item ->> 'sale_price')::numeric;
    v_item_name := nullif(btrim(coalesce(v_item ->> 'item_name', '')), '');
    v_description := nullif(btrim(coalesce(v_item ->> 'description', '')), '');
    v_sku := nullif(btrim(coalesce(v_item ->> 'sku', '')), '');

    if v_weight <= 0 then
      raise exception 'الوزن يجب أن يكون أكبر من صفر (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;

    if v_sale_price < 0 then
      raise exception 'سعر البيع لا يمكن أن يكون سالبًا (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;

    -- 12) Active master data rules (spec §12) — category and karat must be
    -- active for a NEW sale.
    select * into v_category from public.product_categories where product_categories.id = v_category_id;
    if v_category.id is null then
      raise exception 'التصنيف غير موجود (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;
    if v_category.status <> 'active' then
      raise exception 'التصنيف "%" غير نشط — لا يمكن استخدامه في عملية بيع جديدة (بند رقم %)', v_category.name_ar, v_line_no using errcode = 'P0001';
    end if;

    select * into v_karat from public.karats where karats.id = v_karat_id;
    if v_karat.id is null then
      raise exception 'العيار غير موجود (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;
    if v_karat.status <> 'active' then
      raise exception 'عيار "%" غير نشط — لا يمكن استخدامه في عملية بيع جديدة (بند رقم %)', v_karat.name_ar, v_line_no using errcode = 'P0001';
    end if;

    select * into v_gold from public.gold_price_version_for_karat_on_date(v_karat_id, p_sale_date);
    select * into v_mfg from public.manufacturing_fee_version_for_karat_on_date(v_karat_id, p_sale_date);
    select * into v_vat from public.vat_rate_version_for_date(p_sale_date);

    select * into v_costs from public.compute_sales_item_costs(
      v_gold.price_per_gram, v_mfg.fee_per_gram, v_vat.rate_percent, v_weight, v_sale_price
    );

    insert into public.sales_order_items (
      sales_order_id, line_no, category_id, karat_id, item_name, description, sku,
      weight_grams, sale_price,
      category_name_ar_snapshot, karat_code_snapshot, karat_name_ar_snapshot,
      daily_gold_price_id, gold_price_per_gram_snapshot,
      manufacturing_fee_version_id, manufacturing_fee_per_gram_snapshot,
      vat_rate_version_id, vat_rate_percent_snapshot,
      gold_component_cost, manufacturing_component_cost, base_cost, vat_cost, total_cost, gross_profit,
      status,
      created_by, updated_by
    ) values (
      v_order_id, v_line_no, v_category_id, v_karat_id, v_item_name, v_description, v_sku,
      v_weight, v_sale_price,
      v_category.name_ar, v_karat.code, v_karat.name_ar,
      v_gold.daily_gold_price_id, v_gold.price_per_gram,
      v_mfg.manufacturing_fee_version_id, v_mfg.fee_per_gram,
      v_vat.vat_rate_version_id, v_vat.rate_percent,
      v_costs.gold_component_cost, v_costs.manufacturing_component_cost, v_costs.base_cost, v_costs.vat_cost, v_costs.total_cost, v_costs.gross_profit,
      'active',
      v_actor, v_actor
    )
    returning sales_order_items.id into v_item_id;

    v_subtotal := v_subtotal + v_sale_price;
    -- Order Gross Profit = SUM(active item gross_profit), using the same
    -- already-reconciled value just stored on the item row.
    v_order_gross_profit := v_order_gross_profit + v_costs.gross_profit;
  end loop;

  -- 10) Order totals. Payment Fee = (Subtotal × Percentage / 100) + Fixed.
  v_payment_fee_amount := round((v_subtotal * v_payment_fee.percentage_fee / 100) + v_payment_fee.fixed_fee, 2);
  v_net_sales_profit := round(v_order_gross_profit, 2) - v_payment_fee_amount;

  update public.sales_orders
  set subtotal = round(v_subtotal, 2),
      gross_profit = round(v_order_gross_profit, 2),
      payment_fee_amount = v_payment_fee_amount,
      net_sales_profit = v_net_sales_profit
  where sales_orders.id = v_order_id;

  -- 14) Audit (spec §21).
  perform public.log_audit_event(
    'sale.create', 'sales_order', v_order_id, null,
    jsonb_build_object('order_number', v_order_number, 'store_id', p_store_id, 'sale_date', p_sale_date, 'subtotal', round(v_subtotal, 2), 'net_sales_profit', v_net_sales_profit)
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'sale.closed_day_update', 'sales_order', v_order_id, null,
      jsonb_build_object('order_number', v_order_number, 'sale_date', p_sale_date, 'created_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := v_order_id;
  order_number := v_order_number;
  return next;
end;
$$;

comment on function public.create_sales_order(uuid, date, uuid, uuid, jsonb, text, text, text, text) is
  'The single transactional entry point for creating a Sale (spec §11) — authenticates the actor, checks sales.create + store scope + active store/master-data + closed-day gating, resolves every financial version for sale_date and computes every cost/profit figure via the shared compute_sales_item_costs() helper (0065, Patch 3.1 items 8/10), then writes the order header and every item (status=''active'') atomically. As of 0068 (Patch 3.1 items 5/7): acquires acquire_daily_close_lock_shared() before checking daily_closings and acquire_financial_master_lock_shared() before resolving any financial-master value, so this Sale can neither race a concurrent Daily Close nor observe a torn financial-master snapshot. SECURITY DEFINER — sales_orders/sales_order_items have zero direct-write RLS policies (0059).';

revoke execute on function public.create_sales_order(uuid, date, uuid, uuid, jsonb, text, text, text, text) from public;
grant execute on function public.create_sales_order(uuid, date, uuid, uuid, jsonb, text, text, text, text) to authenticated;

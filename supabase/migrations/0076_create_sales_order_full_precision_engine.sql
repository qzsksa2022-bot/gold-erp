-- ============================================================================
-- 0076: Phase 3 — Final Sales Integrity Patch 3.2 (4/8): create_sales_order()
-- wired to the full-precision engine, DB-level precision validation,
-- calculation_version=2, and a complete create audit
-- ============================================================================
-- Migrations 0001-0072 are unmodified, including 0068 itself. Same exact
-- signature as 0068 (9 parameters, all unchanged) — CREATE OR REPLACE is a
-- true replace here (no new parameter, no return-shape change), no DROP
-- FUNCTION needed. Every validation rule, error message, and business flow
-- from 0068 is preserved byte-for-byte EXCEPT:
--   (a) validate_sales_item_precision() (0074) is called for every item,
--       before any calculation, per item 4;
--   (b) compute_sales_item_costs() now resolves to the full-precision
--       Patch 3.2 body (0074) automatically, since it is the same function
--       name/signature this function already called — no call-site change
--       needed here beyond the fact that its RESULTS now differ for
--       previously-mis-rounded inputs (item 3);
--   (c) every newly-created item is stamped calculation_version = 2 (item
--       7 — "Every Sale created after Patch 3.2 is entirely v2"), and the
--       ORDER-level calculation_version (already existing since 0059) is
--       likewise stamped 2 instead of the previous default 1, since a
--       brand-new order's aggregate/payment engine is entirely the Patch
--       3.2 engine, never a mix;
--   (d) the sale.create audit now includes the final created items array
--       in new_values (previously header-only), matching what item 10
--       requires of sale.update and closing the old/new asymmetry the spec
--       called out.
-- Store scope remains user_operable_store_ids() — UNCHANGED — per item 9's
-- explicit "Create Sale → operable store فقط" (only editing an EXISTING
-- historical Sale uses the broader visible-scope policy, 0075).
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
  v_payment_fee record;
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
  v_gold record;
  v_mfg record;
  v_vat record;
  v_costs record;
  v_subtotal numeric := 0;
  v_order_gross_profit numeric := 0;
  v_payment_fee_amount numeric;
  v_net_sales_profit numeric;
  v_item_id uuid;
  v_items_for_audit jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لإنشاء عملية بيع' using errcode = 'P0001';
  end if;

  if not public.has_permission('sales.create') then
    raise exception 'ليست لديك صلاحية إنشاء عمليات بيع' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_store_id is null or p_sale_date is null or p_payment_method_id is null or p_collection_channel_id is null then
    raise exception 'المتجر وتاريخ البيع وطريقة الدفع وقناة التحصيل كلها مطلوبة' using errcode = 'P0001';
  end if;

  -- Item 9 — Create remains OPERABLE scope only, unchanged.
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'هذا المتجر غير متاح لك لإنشاء عمليات بيع فيه، أو أنه غير نشط' using errcode = 'P0001';
  end if;

  if p_sale_date > v_today then
    raise exception 'لا يمكن تسجيل عملية بيع بتاريخ مستقبلي (%)', p_sale_date using errcode = 'P0001';
  end if;

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

  perform public.acquire_financial_master_lock_shared();

  select * into v_payment_fee from public.payment_fee_for_method_on_date(p_payment_method_id, p_sale_date);

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'يجب أن تحتوي عملية البيع على بند واحد على الأقل' using errcode = 'P0001';
  end if;

  v_order_number := public.generate_sales_order_number();

  -- Item 7 — a brand-new order's calculation_version is stamped 2
  -- (entirely the Patch 3.2 engine), not the old default of 1.
  insert into public.sales_orders (
    order_number, store_id, sale_date, salesperson_id, payment_method_id, collection_channel_id,
    customer_name, customer_phone, notes,
    payment_fee_version_id, payment_fee_percentage_snapshot, payment_fee_fixed_snapshot,
    payment_fee_amount, subtotal, gross_profit, net_sales_profit, calculation_version,
    row_version,
    created_by, updated_by
  ) values (
    v_order_number, p_store_id, p_sale_date, v_actor, p_payment_method_id, p_collection_channel_id,
    nullif(btrim(coalesce(p_customer_name, '')), ''), nullif(btrim(coalesce(p_customer_phone, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''),
    v_payment_fee.fee_version_id, v_payment_fee.percentage_fee, v_payment_fee.fixed_fee,
    0, 0, 0, 0, 2,
    1,
    v_actor, v_actor
  )
  returning sales_orders.id into v_order_id;

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

    -- Item 4 — reject over-precision/out-of-bounds input BEFORE any
    -- calculation or storage, for every item of a NEW order.
    perform public.validate_sales_item_precision(v_weight, v_sale_price);

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
      calculation_version,
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
      2,
      'active',
      v_actor, v_actor
    )
    returning sales_order_items.id into v_item_id;

    v_subtotal := v_subtotal + v_sale_price;
    v_order_gross_profit := v_order_gross_profit + v_costs.gross_profit;
  end loop;

  v_payment_fee_amount := round((v_subtotal * v_payment_fee.percentage_fee / 100) + v_payment_fee.fixed_fee, 2);
  v_net_sales_profit := round(v_order_gross_profit, 2) - v_payment_fee_amount;

  update public.sales_orders
  set subtotal = round(v_subtotal, 2),
      gross_profit = round(v_order_gross_profit, 2),
      payment_fee_amount = v_payment_fee_amount,
      net_sales_profit = v_net_sales_profit
  where sales_orders.id = v_order_id;

  -- Item 10 — the create audit now captures the final created items array,
  -- matching what update's new_values captures (0075), instead of the old
  -- header-only snapshot.
  select coalesce(jsonb_agg(to_jsonb(it.*) order by it.line_no), '[]'::jsonb) into v_items_for_audit
  from public.sales_order_items it
  where it.sales_order_id = v_order_id and it.status = 'active';

  perform public.log_audit_event(
    'sale.create', 'sales_order', v_order_id, null,
    jsonb_build_object('order_number', v_order_number, 'store_id', p_store_id, 'sale_date', p_sale_date,
      'items', v_items_for_audit,
      'payment_method_id', p_payment_method_id, 'collection_channel_id', p_collection_channel_id,
      'subtotal', round(v_subtotal, 2), 'gross_profit', round(v_order_gross_profit, 2),
      'payment_fee_amount', v_payment_fee_amount, 'net_sales_profit', v_net_sales_profit,
      'calculation_version', 2, 'row_version', 1)
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
  'Patch 3.2 rewrite (items 3/4/7/10, same signature as 0068) — every item is validated via validate_sales_item_precision() (0074) before any calculation, computed via the full-precision compute_sales_item_costs() (0074), and stamped calculation_version=2; the order header itself is stamped calculation_version=2 and row_version=1 (a brand-new order is entirely the Patch 3.2 engine, never a legacy mix); the sale.create audit now captures the final created items array in new_values, matching sale.update''s new_values (0075). Store scope remains user_operable_store_ids() (item 9 — Create stays operable-only). Locking/business flow otherwise byte-for-byte identical to 0068. SECURITY DEFINER.';

revoke execute on function public.create_sales_order(uuid, date, uuid, uuid, jsonb, text, text, text, text) from public;
grant execute on function public.create_sales_order(uuid, date, uuid, uuid, jsonb, text, text, text, text) to authenticated;

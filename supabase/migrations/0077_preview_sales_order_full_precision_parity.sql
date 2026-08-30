-- ============================================================================
-- 0077: Phase 3 — Final Sales Integrity Patch 3.2 (5/8): preview_sales_order()
-- (Create-mode preview) — precision validation parity with create_sales_order()
-- ============================================================================
-- Migrations 0001-0072 are unmodified, including 0070 itself. Same exact
-- signature as 0070's preview_sales_order() (5 parameters, unchanged) — true
-- CREATE OR REPLACE, no DROP needed. This is the CREATE-mode preview and
-- continues to be used ONLY by the New Sale form; the Edit form moves to the
-- new preview_update_sales_order() (0078), which mirrors update_sales_order()'s
-- structurally different decision tree instead of this one's.
--
-- The only functional change here is adding validate_sales_item_precision()
-- (0074) before each item's calculation — item 4 requires this validation to
-- run in every place compute_sales_item_costs() is about to run, including
-- Preview, so a crafted over-precision payload is rejected at Preview time
-- with the same clear message create_sales_order() would give, rather than
-- previewing successfully and only failing later on actual Save. Every other
-- line is byte-for-byte identical to 0070 — compute_sales_item_costs() itself
-- already resolves to the Patch 3.2 full-precision body via 0074 with no
-- call-site change required, so Preview = Saved values continues to hold
-- exactly (item 5's parity requirement, for Create mode).
-- ---------------------------------------------------------------------------
create or replace function public.preview_sales_order(
  p_store_id uuid,
  p_sale_date date,
  p_payment_method_id uuid,
  p_collection_channel_id uuid,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_today date := public.business_today();
  v_can_view_profit boolean;
  v_payment_method record;
  v_collection_channel record;
  v_payment_fee record;
  v_is_closed boolean;
  v_item jsonb;
  v_line_no integer := 0;
  v_category_id uuid;
  v_karat_id uuid;
  v_weight numeric;
  v_sale_price numeric;
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
  v_items_json jsonb := '[]'::jsonb;
  v_item_json jsonb;
begin
  if v_actor is null or not (public.has_permission('sales.create') or public.has_permission('sales.edit')) then
    raise exception 'ليست لديك صلاحية معاينة عملية بيع' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  if p_store_id is null or p_sale_date is null or p_payment_method_id is null or p_collection_channel_id is null then
    raise exception 'المتجر وتاريخ البيع وطريقة الدفع وقناة التحصيل مطلوبة للمعاينة' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'هذا المتجر غير متاح لك' using errcode = 'P0001';
  end if;

  if p_sale_date > v_today then
    raise exception 'لا يمكن تسجيل عملية بيع بتاريخ مستقبلي (%)', p_sale_date using errcode = 'P0001';
  end if;

  select exists(
    select 1 from public.daily_closings
    where store_id = p_store_id and business_date = p_sale_date
  ) into v_is_closed;

  if v_is_closed and not public.has_permission('sales.edit_closed_day') then
    raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن إنشاء عملية بيع جديدة فيه إلا بصلاحية خاصة (sales.edit_closed_day)', p_sale_date using errcode = 'P0001';
  end if;

  select * into v_payment_method from public.payment_methods pm where pm.id = p_payment_method_id;
  if v_payment_method.id is null then
    raise exception 'طريقة الدفع غير موجودة' using errcode = 'P0001';
  end if;
  if v_payment_method.status <> 'active' then
    raise exception 'طريقة الدفع "%" غير نشطة', v_payment_method.name_ar using errcode = 'P0001';
  end if;

  select * into v_collection_channel from public.collection_channels cc where cc.id = p_collection_channel_id;
  if v_collection_channel.id is null then
    raise exception 'قناة التحصيل غير موجودة' using errcode = 'P0001';
  end if;
  if v_collection_channel.status <> 'active' then
    raise exception 'قناة التحصيل "%" غير نشطة', v_collection_channel.name_ar using errcode = 'P0001';
  end if;

  select * into v_payment_fee from public.payment_fee_for_method_on_date(p_payment_method_id, p_sale_date);

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'يجب إضافة بند واحد على الأقل للمعاينة' using errcode = 'P0001';
  end if;

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

    if v_weight <= 0 then
      raise exception 'الوزن يجب أن يكون أكبر من صفر (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;

    if v_sale_price < 0 then
      raise exception 'سعر البيع لا يمكن أن يكون سالبًا (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;

    -- Item 4 — same precision/bounds rejection Create itself would apply,
    -- so Preview never claims success for a payload Save would reject.
    perform public.validate_sales_item_precision(v_weight, v_sale_price);

    select * into v_category from public.product_categories pc where pc.id = v_category_id;
    if v_category.id is null then
      raise exception 'التصنيف غير موجود (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;
    if v_category.status <> 'active' then
      raise exception 'التصنيف "%" غير نشط (بند رقم %)', v_category.name_ar, v_line_no using errcode = 'P0001';
    end if;

    select * into v_karat from public.karats k where k.id = v_karat_id;
    if v_karat.id is null then
      raise exception 'العيار غير موجود (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;
    if v_karat.status <> 'active' then
      raise exception 'عيار "%" غير نشط (بند رقم %)', v_karat.name_ar, v_line_no using errcode = 'P0001';
    end if;

    select * into v_gold from public.gold_price_version_for_karat_on_date(v_karat_id, p_sale_date);
    select * into v_mfg from public.manufacturing_fee_version_for_karat_on_date(v_karat_id, p_sale_date);
    select * into v_vat from public.vat_rate_version_for_date(p_sale_date);

    select * into v_costs from public.compute_sales_item_costs(
      v_gold.price_per_gram, v_mfg.fee_per_gram, v_vat.rate_percent, v_weight, v_sale_price
    );

    v_item_json := jsonb_build_object(
      'line_no', v_line_no, 'category_id', v_category_id, 'karat_id', v_karat_id,
      'weight_grams', v_weight::text, 'sale_price', v_sale_price::text,
      'category_name_ar', v_category.name_ar, 'karat_name_ar', v_karat.name_ar
    )
    || case when v_can_view_profit then jsonb_build_object(
      'gold_price_per_gram', v_gold.price_per_gram::text,
      'manufacturing_fee_per_gram', v_mfg.fee_per_gram::text,
      'vat_rate_percent', v_vat.rate_percent::text,
      'gold_component_cost', v_costs.gold_component_cost::text,
      'manufacturing_component_cost', v_costs.manufacturing_component_cost::text,
      'base_cost', v_costs.base_cost::text,
      'vat_cost', v_costs.vat_cost::text,
      'total_cost', v_costs.total_cost::text,
      'gross_profit', v_costs.gross_profit::text
    ) else '{}'::jsonb end;

    v_items_json := v_items_json || jsonb_build_array(v_item_json);

    v_subtotal := v_subtotal + v_sale_price;
    v_order_gross_profit := v_order_gross_profit + v_costs.gross_profit;
  end loop;

  v_payment_fee_amount := round((v_subtotal * v_payment_fee.percentage_fee / 100) + v_payment_fee.fixed_fee, 2);
  v_net_sales_profit := round(v_order_gross_profit, 2) - v_payment_fee_amount;

  return jsonb_build_object('subtotal', round(v_subtotal, 2)::text, 'items', v_items_json, 'is_day_closed', v_is_closed)
  || case when v_can_view_profit then jsonb_build_object(
    'gross_profit', round(v_order_gross_profit, 2)::text,
    'payment_fee_amount', v_payment_fee_amount::text,
    'net_sales_profit', v_net_sales_profit::text
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.preview_sales_order(uuid, date, uuid, uuid, jsonb) is
  'Patch 3.2 (item 4 parity, supersedes 0070''s body, same signature) — Create-mode preview, used ONLY by the New Sale form (Edit uses preview_update_sales_order(), 0078). Adds validate_sales_item_precision() before each item''s calculation so an over-precision/out-of-bounds payload is rejected at Preview time with the same message Create would give. compute_sales_item_costs() resolves to the Patch 3.2 full-precision engine (0074) automatically. Still writes nothing, still not the source of truth.';

revoke execute on function public.preview_sales_order(uuid, date, uuid, uuid, jsonb) from public;
grant execute on function public.preview_sales_order(uuid, date, uuid, uuid, jsonb) to authenticated;

-- ============================================================================
-- 0063: Phase 3 — Sales Core (6/8): update_sales_order()
-- ============================================================================
-- Migrations 0001-0062 are unmodified.
--
-- Editable per spec §18: customer_name, customer_phone, notes, payment
-- method, collection channel, items (category/karat/weight/sale price/
-- description per line). NEVER editable through this or any function:
-- order_number, created_by, created_at, calculation_version, any snapshot
-- field directly, store_id, sale_date (Phase 3 has no order-identity-change
-- workflow — moving a historical financial record to a different
-- store/day is explicitly out of scope, §18) — this function's parameter
-- list simply has no store_id/sale_date parameter at all, so there is no
-- way to even attempt it.
--
-- Items are replaced wholesale (existing rows for this order deleted,
-- the full new set re-inserted with freshly-resolved snapshots) rather than
-- patched line-by-line — the spec does not ask for per-item edit history,
-- every financial input change requires a fresh snapshot resolution
-- anyway (§18), and the pre-edit item set is fully preserved in this
-- function's own audit_logs old_values (§21), so nothing is actually lost —
-- only the LIVE row set changes shape, exactly like the order header's own
-- totals are overwritten in place rather than versioned. sales_order_items
-- has no direct-write RLS policy at all (0059), so this DELETE+INSERT pair
-- is only ever reachable through this SECURITY DEFINER function, inside
-- one transaction with everything else here — a failure anywhere rolls
-- back the delete along with everything else, never leaving an order with
-- zero items.
create or replace function public.update_sales_order(
  p_order_id uuid,
  p_payment_method_id uuid,
  p_collection_channel_id uuid,
  p_items jsonb,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_notes text default null,
  -- Same meaning as create_sales_order()'s identical parameter (0061) —
  -- only required/checked when the order's (unchangeable) sale_date is
  -- closed for its (unchangeable) store_id and the actor holds sales.
  -- edit_closed_day.
  p_closed_day_reason text default null
)
returns table (id uuid, order_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old_order record;
  v_old_items jsonb;
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
  v_gold_component numeric;
  v_mfg_component numeric;
  v_base_cost numeric;
  v_vat_cost numeric;
  v_total_cost numeric;
  v_item_gross_profit numeric;
  v_subtotal numeric := 0;
  v_order_gross_profit numeric := 0;
  v_payment_fee_amount numeric;
  v_net_sales_profit numeric;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتعديل عملية بيع' using errcode = 'P0001';
  end if;

  if not public.has_permission('sales.edit') then
    raise exception 'ليست لديك صلاحية تعديل عمليات البيع' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  select * into v_old_order from public.sales_orders so where so.id = p_order_id;

  -- Same "not found" message whether the order genuinely does not exist or
  -- merely falls outside the actor's OPERABLE scope (editing is acting on
  -- business data, spec §14 — user_operable_store_ids, not the weaker
  -- user_visible_store_ids used for read-only historical access).
  if v_old_order.id is null or not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_old_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if p_payment_method_id is null or p_collection_channel_id is null then
    raise exception 'طريقة الدفع وقناة التحصيل كلاهما مطلوبان' using errcode = 'P0001';
  end if;

  -- Closed-day gating — uses the order's own (unchangeable) store_id/
  -- sale_date, exactly mirroring create_sales_order()'s identical check.
  select exists(
    select 1 from public.daily_closings
    where store_id = v_old_order.store_id and business_date = v_old_order.sale_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('sales.edit_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن تعديل عملية البيع إلا بصلاحية خاصة (sales.edit_closed_day)', v_old_order.sale_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتعديل عملية بيع في يوم مقفل (%)', v_old_order.sale_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
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

  -- Resolved against the order's own (unchangeable) sale_date — an edit
  -- never re-dates the sale, so this is the same date the original
  -- snapshots used, but the FEE VERSION itself may have changed since
  -- (spec §18: "عند تغيير أي مدخل مالي: أعد حساب Snapshots اللازمة").
  select * into v_payment_fee from public.payment_fee_for_method_on_date(p_payment_method_id, v_old_order.sale_date);

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'يجب أن تحتوي عملية البيع على بند واحد على الأقل' using errcode = 'P0001';
  end if;

  -- Snapshot the FULL pre-edit state (header + items) for the audit trail
  -- (§21) before anything is touched.
  select coalesce(jsonb_agg(to_jsonb(it.*) order by it.line_no), '[]'::jsonb) into v_old_items
  from public.sales_order_items it
  where it.sales_order_id = p_order_id;

  delete from public.sales_order_items where sales_order_id = p_order_id;

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

    select * into v_category from public.product_categories pc where pc.id = v_category_id;
    if v_category.id is null then
      raise exception 'التصنيف غير موجود (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;
    if v_category.status <> 'active' then
      raise exception 'التصنيف "%" غير نشط — لا يمكن استخدامه في عملية بيع (بند رقم %)', v_category.name_ar, v_line_no using errcode = 'P0001';
    end if;

    select * into v_karat from public.karats k where k.id = v_karat_id;
    if v_karat.id is null then
      raise exception 'العيار غير موجود (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;
    if v_karat.status <> 'active' then
      raise exception 'عيار "%" غير نشط — لا يمكن استخدامه في عملية بيع (بند رقم %)', v_karat.name_ar, v_line_no using errcode = 'P0001';
    end if;

    select * into v_gold from public.gold_price_version_for_karat_on_date(v_karat_id, v_old_order.sale_date);
    select * into v_mfg from public.manufacturing_fee_version_for_karat_on_date(v_karat_id, v_old_order.sale_date);
    select * into v_vat from public.vat_rate_version_for_date(v_old_order.sale_date);

    v_gold_component := v_gold.price_per_gram * v_weight;
    v_mfg_component := v_mfg.fee_per_gram * v_weight;
    v_base_cost := v_gold_component + v_mfg_component;
    v_vat_cost := v_base_cost * v_vat.rate_percent / 100;
    v_total_cost := v_base_cost + v_vat_cost;
    v_item_gross_profit := v_sale_price - v_total_cost;

    insert into public.sales_order_items (
      sales_order_id, line_no, category_id, karat_id, item_name, description, sku,
      weight_grams, sale_price,
      category_name_ar_snapshot, karat_code_snapshot, karat_name_ar_snapshot,
      daily_gold_price_id, gold_price_per_gram_snapshot,
      manufacturing_fee_version_id, manufacturing_fee_per_gram_snapshot,
      vat_rate_version_id, vat_rate_percent_snapshot,
      gold_component_cost, manufacturing_component_cost, base_cost, vat_cost, total_cost, gross_profit,
      created_by, updated_by
    ) values (
      p_order_id, v_line_no, v_category_id, v_karat_id, v_item_name, v_description, v_sku,
      v_weight, v_sale_price,
      v_category.name_ar, v_karat.code, v_karat.name_ar,
      v_gold.daily_gold_price_id, v_gold.price_per_gram,
      v_mfg.manufacturing_fee_version_id, v_mfg.fee_per_gram,
      v_vat.vat_rate_version_id, v_vat.rate_percent,
      round(v_gold_component, 2), round(v_mfg_component, 2), round(v_base_cost, 2), round(v_vat_cost, 2), round(v_total_cost, 2), round(v_item_gross_profit, 2),
      v_actor, v_actor
    );

    v_subtotal := v_subtotal + v_sale_price;
    v_order_gross_profit := v_order_gross_profit + round(v_item_gross_profit, 2);
  end loop;

  v_payment_fee_amount := round((v_subtotal * v_payment_fee.percentage_fee / 100) + v_payment_fee.fixed_fee, 2);
  v_net_sales_profit := round(v_order_gross_profit, 2) - v_payment_fee_amount;

  update public.sales_orders
  set payment_method_id = p_payment_method_id,
      collection_channel_id = p_collection_channel_id,
      customer_name = nullif(btrim(coalesce(p_customer_name, '')), ''),
      customer_phone = nullif(btrim(coalesce(p_customer_phone, '')), ''),
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      payment_fee_version_id = v_payment_fee.fee_version_id,
      payment_fee_percentage_snapshot = v_payment_fee.percentage_fee,
      payment_fee_fixed_snapshot = v_payment_fee.fixed_fee,
      payment_fee_amount = v_payment_fee_amount,
      subtotal = round(v_subtotal, 2),
      gross_profit = round(v_order_gross_profit, 2),
      net_sales_profit = v_net_sales_profit,
      updated_by = v_actor
  where sales_orders.id = p_order_id;

  -- Audit (§21) — 'sale.update' always; ALSO 'sale.closed_day_update' with
  -- the mandatory reason when the closed-day override path was used, same
  -- dual-event convention as create_sales_order() (0061).
  perform public.log_audit_event(
    'sale.update', 'sales_order', p_order_id,
    jsonb_build_object('order_number', v_old_order.order_number, 'items', v_old_items,
      'payment_method_id', v_old_order.payment_method_id, 'collection_channel_id', v_old_order.collection_channel_id,
      'customer_name', v_old_order.customer_name, 'customer_phone', v_old_order.customer_phone, 'notes', v_old_order.notes,
      'subtotal', v_old_order.subtotal, 'net_sales_profit', v_old_order.net_sales_profit),
    jsonb_build_object('order_number', v_old_order.order_number, 'payment_method_id', p_payment_method_id, 'collection_channel_id', p_collection_channel_id,
      'customer_name', p_customer_name, 'customer_phone', p_customer_phone, 'notes', p_notes,
      'subtotal', round(v_subtotal, 2), 'net_sales_profit', v_net_sales_profit)
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'sale.closed_day_update', 'sales_order', p_order_id, null,
      jsonb_build_object('order_number', v_old_order.order_number, 'sale_date', v_old_order.sale_date, 'edited_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := p_order_id;
  order_number := v_old_order.order_number;
  return next;
end;
$$;

comment on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text) is
  'The single transactional entry point for editing a Sale (spec §18) — order_number/created_by/created_at/calculation_version/store_id/sale_date are never editable (no parameter exists for them). Editable: payment method, collection channel, customer fields, items (wholesale replace with freshly-resolved snapshots against the order''s unchanged sale_date). Closed-day gating mirrors create_sales_order() (0061) exactly, including the dual sale.update + sale.closed_day_update audit events. SECURITY DEFINER — sales_orders/sales_order_items have zero direct-write RLS policies (0059).';

revoke execute on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text) from public;
grant execute on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text) to authenticated;

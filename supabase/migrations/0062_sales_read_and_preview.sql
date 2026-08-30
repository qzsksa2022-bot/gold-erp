-- ============================================================================
-- 0062: Phase 3 — Sales Core (5/8): preview_sales_order() + Read RPCs
-- (list_sales_orders / get_sales_order) with DB-level profit protection
-- ============================================================================
-- Migrations 0001-0061 are unmodified.
--
-- sales_orders/sales_order_items have ZERO direct-write RLS policies AND
-- zero direct-SELECT RLS policies (0059's access-model note) — every read
-- in this project's UI goes through one of the two SECURITY DEFINER
-- functions below. Both independently resolve has_permission(''sales.view_
-- profit'') and OMIT (set to NULL) every profit-sensitive field for a
-- caller who lacks it — cost, gross_profit, payment_fee_*, net_sales_profit
-- never leave Postgres for that caller under ANY code path (no direct
-- table SELECT is even possible to attempt, since no policy grants it —
-- spec §15/§32). Every financial value in both responses is TEXT, never a
-- raw JSON number (spec §16/§33).
create or replace function public.list_sales_orders(
  p_date_from date default null,
  p_date_to date default null,
  p_store_id uuid default null,
  p_order_number text default null,
  p_salesperson_id uuid default null,
  p_payment_method_id uuid default null,
  p_collection_channel_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid,
  order_number text,
  store_id uuid,
  sale_date date,
  salesperson_id uuid,
  payment_method_id uuid,
  collection_channel_id uuid,
  customer_name text,
  item_count integer,
  subtotal text,
  gross_profit text,
  payment_fee_amount text,
  net_sales_profit text,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_can_view_profit boolean;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if v_actor is null or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض المبيعات' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  return query
  select
    so.id,
    so.order_number,
    so.store_id,
    so.sale_date,
    so.salesperson_id,
    so.payment_method_id,
    so.collection_channel_id,
    so.customer_name,
    (select count(*)::integer from public.sales_order_items it where it.sales_order_id = so.id),
    so.subtotal::text,
    case when v_can_view_profit then so.gross_profit::text else null end,
    case when v_can_view_profit then so.payment_fee_amount::text else null end,
    case when v_can_view_profit then so.net_sales_profit::text else null end,
    so.created_at,
    count(*) over ()::bigint
  from public.sales_orders so
  where so.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and (p_date_from is null or so.sale_date >= p_date_from)
    and (p_date_to is null or so.sale_date <= p_date_to)
    and (p_store_id is null or so.store_id = p_store_id)
    and (p_order_number is null or so.order_number ilike '%' || p_order_number || '%')
    and (p_salesperson_id is null or so.salesperson_id = p_salesperson_id)
    and (p_payment_method_id is null or so.payment_method_id = p_payment_method_id)
    and (p_collection_channel_id is null or so.collection_channel_id = p_collection_channel_id)
  order by so.sale_date desc, so.created_at desc
  limit v_limit offset v_offset;
end;
$$;

comment on function public.list_sales_orders(date, date, uuid, text, uuid, uuid, uuid, integer, integer) is
  'Paginated Sales list (spec §16/§34) — store-scoped via user_visible_store_ids (historical visibility, not operable-for-new-writes). Profit columns (gross_profit/payment_fee_amount/net_sales_profit) are NULL for a caller without sales.view_profit, never the real value. total_count (a window count(*) over()) lets the caller compute total pages without a second round trip. p_limit is clamped to [1,200] server-side regardless of what the caller sends.';

revoke execute on function public.list_sales_orders(date, date, uuid, text, uuid, uuid, uuid, integer, integer) from public;
grant execute on function public.list_sales_orders(date, date, uuid, text, uuid, uuid, uuid, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_sales_order(): full detail (header + items) for one order. Returns
-- jsonb (not a fixed `returns table`) because the item array's shape itself
-- differs by permission (profit-sensitive item columns are simply absent,
-- not just null, for a non-view_profit caller) — a single jsonb document is
-- the natural fit, same as preview_sales_order() below.
-- ---------------------------------------------------------------------------
create or replace function public.get_sales_order(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_order record;
  v_can_view_profit boolean;
  v_is_closed boolean;
  v_items jsonb;
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض المبيعات' using errcode = 'P0001';
  end if;

  select * into v_order from public.sales_orders so where so.id = p_id;

  -- Same "not found" message whether the row genuinely does not exist or
  -- merely falls outside the actor's visible store scope — avoids leaking
  -- which case it is.
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  select exists(
    select 1 from public.daily_closings dc
    where dc.store_id = v_order.store_id and dc.business_date = v_order.sale_date
  ) into v_is_closed;

  select coalesce(jsonb_agg(
    (
      jsonb_build_object(
        'id', it.id, 'line_no', it.line_no, 'category_id', it.category_id, 'karat_id', it.karat_id,
        'item_name', it.item_name, 'description', it.description, 'sku', it.sku,
        'weight_grams', it.weight_grams::text, 'sale_price', it.sale_price::text,
        'category_name_ar_snapshot', it.category_name_ar_snapshot,
        'karat_code_snapshot', it.karat_code_snapshot, 'karat_name_ar_snapshot', it.karat_name_ar_snapshot
      )
      || case when v_can_view_profit then jsonb_build_object(
        'gold_price_per_gram_snapshot', it.gold_price_per_gram_snapshot::text,
        'manufacturing_fee_per_gram_snapshot', it.manufacturing_fee_per_gram_snapshot::text,
        'vat_rate_percent_snapshot', it.vat_rate_percent_snapshot::text,
        'gold_component_cost', it.gold_component_cost::text,
        'manufacturing_component_cost', it.manufacturing_component_cost::text,
        'base_cost', it.base_cost::text,
        'vat_cost', it.vat_cost::text,
        'total_cost', it.total_cost::text,
        'gross_profit', it.gross_profit::text
      ) else '{}'::jsonb end
    )
    order by it.line_no
  ), '[]'::jsonb) into v_items
  from public.sales_order_items it
  where it.sales_order_id = v_order.id;

  v_result := jsonb_build_object(
    'id', v_order.id, 'order_number', v_order.order_number, 'store_id', v_order.store_id,
    'sale_date', v_order.sale_date, 'sold_at', v_order.sold_at, 'salesperson_id', v_order.salesperson_id,
    'payment_method_id', v_order.payment_method_id, 'collection_channel_id', v_order.collection_channel_id,
    'customer_name', v_order.customer_name, 'customer_phone', v_order.customer_phone, 'notes', v_order.notes,
    'subtotal', v_order.subtotal::text,
    'is_day_closed', v_is_closed,
    'created_at', v_order.created_at, 'updated_at', v_order.updated_at,
    'items', v_items
  )
  || case when v_can_view_profit then jsonb_build_object(
    'payment_fee_percentage_snapshot', v_order.payment_fee_percentage_snapshot::text,
    'payment_fee_fixed_snapshot', v_order.payment_fee_fixed_snapshot::text,
    'payment_fee_amount', v_order.payment_fee_amount::text,
    'gross_profit', v_order.gross_profit::text,
    'net_sales_profit', v_order.net_sales_profit::text
  ) else '{}'::jsonb end;

  return v_result;
end;
$$;

comment on function public.get_sales_order(uuid) is
  'Full detail (header + items) for one Sale (spec §16/§18/§22) — store-scoped via user_visible_store_ids. Profit-sensitive keys (item cost breakdown, order gross_profit/payment_fee_amount/net_sales_profit) are entirely ABSENT from the returned jsonb for a caller without sales.view_profit, not merely null — a crafted client cannot distinguish "hidden" from "zero" (spec §15/§32). is_day_closed drives the "اليوم مغلق" badge (§22). Every financial value is TEXT.';

revoke execute on function public.get_sales_order(uuid) from public;
grant execute on function public.get_sales_order(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- preview_sales_order(): optional-but-preferred fast-UX preview (spec §17).
-- Uses the EXACT SAME resolution/calculation rules as create_sales_order()
-- (0061) but writes nothing — no order number is burned, no row is
-- inserted. NOT the source of truth: create_sales_order() always
-- recomputes independently inside its own transaction when the user
-- actually saves. Every validation error a save would hit (missing gold
-- price, inactive karat, unconfigured payment fee, ...) surfaces here too,
-- with the identical clear Arabic message, so the fast-entry UI can show it
-- before the user even attempts to save (spec §23).
-- ---------------------------------------------------------------------------
create or replace function public.preview_sales_order(
  p_store_id uuid,
  p_sale_date date,
  p_payment_method_id uuid,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_can_view_profit boolean;
  v_payment_method record;
  v_payment_fee record;
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
  v_items_json jsonb := '[]'::jsonb;
  v_item_json jsonb;
begin
  if v_actor is null or not (public.has_permission('sales.create') or public.has_permission('sales.edit')) then
    raise exception 'ليست لديك صلاحية معاينة عملية بيع' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  if p_store_id is null or p_sale_date is null or p_payment_method_id is null then
    raise exception 'المتجر وتاريخ البيع وطريقة الدفع مطلوبة للمعاينة' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'هذا المتجر غير متاح لك' using errcode = 'P0001';
  end if;

  select * into v_payment_method from public.payment_methods pm where pm.id = p_payment_method_id;
  if v_payment_method.id is null then
    raise exception 'طريقة الدفع غير موجودة' using errcode = 'P0001';
  end if;
  if v_payment_method.status <> 'active' then
    raise exception 'طريقة الدفع "%" غير نشطة', v_payment_method.name_ar using errcode = 'P0001';
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

    v_gold_component := v_gold.price_per_gram * v_weight;
    v_mfg_component := v_mfg.fee_per_gram * v_weight;
    v_base_cost := v_gold_component + v_mfg_component;
    v_vat_cost := v_base_cost * v_vat.rate_percent / 100;
    v_total_cost := v_base_cost + v_vat_cost;
    v_item_gross_profit := v_sale_price - v_total_cost;

    v_item_json := jsonb_build_object(
      'line_no', v_line_no, 'category_id', v_category_id, 'karat_id', v_karat_id,
      'weight_grams', v_weight::text, 'sale_price', v_sale_price::text,
      'category_name_ar', v_category.name_ar, 'karat_name_ar', v_karat.name_ar
    )
    || case when v_can_view_profit then jsonb_build_object(
      'gold_price_per_gram', v_gold.price_per_gram::text,
      'manufacturing_fee_per_gram', v_mfg.fee_per_gram::text,
      'vat_rate_percent', v_vat.rate_percent::text,
      'base_cost', round(v_base_cost, 2)::text,
      'vat_cost', round(v_vat_cost, 2)::text,
      'total_cost', round(v_total_cost, 2)::text,
      'gross_profit', round(v_item_gross_profit, 2)::text
    ) else '{}'::jsonb end;

    v_items_json := v_items_json || jsonb_build_array(v_item_json);

    v_subtotal := v_subtotal + v_sale_price;
    v_order_gross_profit := v_order_gross_profit + round(v_item_gross_profit, 2);
  end loop;

  v_payment_fee_amount := round((v_subtotal * v_payment_fee.percentage_fee / 100) + v_payment_fee.fixed_fee, 2);
  v_net_sales_profit := round(v_order_gross_profit, 2) - v_payment_fee_amount;

  return jsonb_build_object('subtotal', round(v_subtotal, 2)::text, 'items', v_items_json)
  || case when v_can_view_profit then jsonb_build_object(
    'gross_profit', round(v_order_gross_profit, 2)::text,
    'payment_fee_amount', v_payment_fee_amount::text,
    'net_sales_profit', v_net_sales_profit::text
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.preview_sales_order(uuid, date, uuid, jsonb) is
  'Read-only preview using the exact same resolution/calculation rules as create_sales_order() (0061) — writes nothing, burns no order number. NOT the source of truth: create_sales_order() always recomputes independently. Profit-sensitive keys are entirely absent for a caller without sales.view_profit, matching get_sales_order()/list_sales_orders(). Every financial value is TEXT.';

revoke execute on function public.preview_sales_order(uuid, date, uuid, jsonb) from public;
grant execute on function public.preview_sales_order(uuid, date, uuid, jsonb) to authenticated;

-- ============================================================================
-- 0070: Phase 3 — Sales Integrity Patch 3.1 (6/7): Read RPCs — active-items
-- filter, salesperson_name/filter without users.view, preview/create parity
-- ============================================================================
-- Migrations 0001-0069 are unmodified.
--
-- Item 1 — list_sales_orders()/get_sales_order() now filter every item read
-- and every totals-derived count to sales_order_items.status = 'active'
-- (0067) — a soft-removed item is preserved in the database (spec item 1)
-- but must never appear in a normal Read or be counted toward anything a
-- user sees.
--
-- Item 11 — both functions now also return salesperson_name, resolved
-- INSIDE this SECURITY DEFINER function from profiles.full_name for the
-- salesperson_id already attached to a Sale the caller is already permitted
-- to see (sales.view) — this is the Sale's own data, not a general grant of
-- users.view/profiles browsing, so it is safe to expose here even to a
-- caller who holds sales.view but not users.view. list_sales_salespersons()
-- (new) gives the /sales filter UI a scoped dropdown of exactly the
-- salespeople who have a Sale within the caller's visible store scope —
-- never a general profiles listing.
--
-- list_sales_orders() gains a new output column (salesperson_name) — this
-- changes its RETURNS TABLE row type, which CREATE OR REPLACE cannot do in
-- place (Postgres requires an explicit DROP first when OUT-parameter/return
-- shape changes, even with the same function name and input signature).
drop function if exists public.list_sales_orders(date, date, uuid, text, uuid, uuid, uuid, integer, integer);

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
  salesperson_name text,
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
    sp.full_name,
    so.payment_method_id,
    so.collection_channel_id,
    so.customer_name,
    (select count(*)::integer from public.sales_order_items it where it.sales_order_id = so.id and it.status = 'active'),
    so.subtotal::text,
    case when v_can_view_profit then so.gross_profit::text else null end,
    case when v_can_view_profit then so.payment_fee_amount::text else null end,
    case when v_can_view_profit then so.net_sales_profit::text else null end,
    so.created_at,
    count(*) over ()::bigint
  from public.sales_orders so
  left join public.profiles sp on sp.id = so.salesperson_id
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
  'Paginated Sales list (spec §16/§34). As of 0070 (Patch 3.1 items 1/11): item_count only counts status=''active'' items; salesperson_name is resolved from profiles inside this SECURITY DEFINER function (safe under sales.view alone — it is the Sale''s own attached data, not general profiles access) so the UI never needs users.view to show it. Profit columns remain NULL for a caller without sales.view_profit.';

revoke execute on function public.list_sales_orders(date, date, uuid, text, uuid, uuid, uuid, integer, integer) from public;
grant execute on function public.list_sales_orders(date, date, uuid, text, uuid, uuid, uuid, integer, integer) to authenticated;

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
  v_salesperson_name text;
  v_items jsonb;
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض المبيعات' using errcode = 'P0001';
  end if;

  select * into v_order from public.sales_orders so where so.id = p_id;

  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  select p.full_name into v_salesperson_name from public.profiles p where p.id = v_order.salesperson_id;

  select exists(
    select 1 from public.daily_closings dc
    where dc.store_id = v_order.store_id and dc.business_date = v_order.sale_date
  ) into v_is_closed;

  -- Item 1 — status = 'active' only; a soft-removed item never appears here.
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
  where it.sales_order_id = v_order.id and it.status = 'active';

  v_result := jsonb_build_object(
    'id', v_order.id, 'order_number', v_order.order_number, 'store_id', v_order.store_id,
    'sale_date', v_order.sale_date, 'sold_at', v_order.sold_at, 'salesperson_id', v_order.salesperson_id,
    'salesperson_name', v_salesperson_name,
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
  'Full detail for one Sale (spec §16/§18/§22). As of 0070 (Patch 3.1 items 1/11): items filtered to status=''active'' only (a soft-removed item is never returned here); salesperson_name resolved from profiles internally (safe under sales.view alone, same reasoning as list_sales_orders()). Profit-sensitive keys remain entirely ABSENT for a caller without sales.view_profit.';

revoke execute on function public.get_sales_order(uuid) from public;
grant execute on function public.get_sales_order(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- list_sales_salespersons(): scoped dropdown source for the /sales
-- salesperson filter (spec item 11) — distinct salespeople who have at
-- least one Sale within the caller's VISIBLE store scope. Deliberately NOT
-- a general profiles listing (never returns a person with zero visible
-- Sales, never exposes any profiles column beyond id/full_name) — does not
-- require and must never require users.view.
-- ---------------------------------------------------------------------------
create or replace function public.list_sales_salespersons()
returns table (id uuid, full_name text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض المبيعات' using errcode = 'P0001';
  end if;

  return query
  select distinct p.id, p.full_name
  from public.sales_orders so
  join public.profiles p on p.id = so.salesperson_id
  where so.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
  order by p.full_name;
end;
$$;

comment on function public.list_sales_salespersons() is
  'Patch 3.1 item 11 — distinct salespeople with at least one Sale within the caller''s visible store scope (user_visible_store_ids), for the /sales salesperson filter dropdown. Requires sales.view only — never users.view. Returns only id/full_name, never a general profiles listing.';

revoke execute on function public.list_sales_salespersons() from public;
grant execute on function public.list_sales_salespersons() to authenticated;

-- ---------------------------------------------------------------------------
-- preview_sales_order(): item 10 — Preview/Create parity.
--
-- Signature changes from (store_id, sale_date, payment_method_id, items) to
-- (store_id, sale_date, payment_method_id, collection_channel_id, items) —
-- matching create_sales_order()'s own positional order — so the old 4-arg
-- overload is explicitly DROPped first (CREATE OR REPLACE cannot change a
-- function's parameter list in place; it would otherwise leave BOTH the old
-- 4-arg and new 5-arg versions callable side by side).
--
-- Fixes vs 0062's version: (a) validates collection_channel_id exists/
-- active, exactly like create_sales_order(); (b) validates sale_date is not
-- in the future, exactly like create_sales_order() (0062's preview never
-- checked this at all); (c) surfaces the closed-day state instead of either
-- silently ignoring it or writing — if the day is closed and the caller
-- lacks sales.edit_closed_day, preview now fails with the SAME error Create
-- would produce (so preview never claims "ready to save" when a real save
-- would be rejected); if the caller DOES hold sales.edit_closed_day, preview
-- succeeds and reports is_day_closed=true so the UI can pre-surface the
-- "reason required" prompt; (d) uses the shared compute_sales_item_costs()
-- helper (0065) — byte-for-byte the same rounding chain create_sales_order()
-- uses, so Preview = Saved values exactly (spec item 8/10 together).
-- ---------------------------------------------------------------------------
drop function if exists public.preview_sales_order(uuid, date, uuid, jsonb);

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

  -- Parity fix (c) — same future-date rule as create_sales_order() (0068),
  -- which the pre-Patch-3.1 preview never checked at all.
  if p_sale_date > v_today then
    raise exception 'لا يمكن تسجيل عملية بيع بتاريخ مستقبلي (%)', p_sale_date using errcode = 'P0001';
  end if;

  select exists(
    select 1 from public.daily_closings
    where store_id = p_store_id and business_date = p_sale_date
  ) into v_is_closed;

  -- Parity fix (c) — if a real save would be rejected outright (closed day,
  -- no override permission), Preview must not claim otherwise.
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

  -- Parity fix (a) — collection_channel_id, validated exactly like
  -- create_sales_order().
  select * into v_collection_channel from public.collection_channels cc where cc.id = p_collection_channel_id;
  if v_collection_channel.id is null then
    raise exception 'قناة التحصيل غير موجودة' using errcode = 'P0001';
  end if;
  if v_collection_channel.status <> 'active' then
    raise exception 'قناة التحصيل "%" غير نشطة', v_collection_channel.name_ar using errcode = 'P0001';
  end if;

  -- Preview is read-only and does not write, so it deliberately does NOT
  -- acquire the financial-master/daily-close advisory locks (0065) —
  -- acquiring a lock only to release it at the end of a read-only
  -- transaction with nothing to protect would be pure overhead with no
  -- correctness benefit; create_sales_order() (0068) is always the actual
  -- source of truth and independently re-resolves everything under its own
  -- locks when the user really saves (spec item 10: "NOT the source of
  -- truth").
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

    -- Parity fix (d) — the SAME shared helper create_sales_order() uses.
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
  'Patch 3.1 item 10 — read-only preview, now with full parity against create_sales_order(): validates collection_channel_id (new required parameter) and future sale_date exactly like Create, surfaces is_day_closed instead of silently ignoring a closed day (and still rejects outright if the caller could not save anyway), and uses the shared compute_sales_item_costs() helper (0065) so Preview = Saved values exactly. Still writes nothing, still not the source of truth. Profit-sensitive keys remain entirely absent for a caller without sales.view_profit.';

revoke execute on function public.preview_sales_order(uuid, date, uuid, uuid, jsonb) from public;
grant execute on function public.preview_sales_order(uuid, date, uuid, uuid, jsonb) to authenticated;

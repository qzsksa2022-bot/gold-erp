-- ============================================================================
-- 0079: Phase 3 — Final Sales Integrity Patch 3.2 (7/8): Sales read RPCs
-- resolve their own labels (no more Master .view dependency) and expose
-- row_version / item calculation_version
-- ============================================================================
-- Migrations 0001-0072 are unmodified, including 0070 itself.
--
-- Item 8 — problem: list_sales_orders()/get_sales_order() already resolve
-- salesperson_name internally (0070), but the Sales list/detail UI still
-- reads stores/payment_methods/collection_channels DIRECTLY (client-side
-- queries against those tables) to turn the raw ids these RPCs return into
-- display names — so a user who holds sales.view but NOT stores.view/
-- payment_methods.view/collection_channels.view can see the Sale itself
-- but every one of those labels renders as "—", which breaks the Sales Read
-- contract (sales.view alone must be enough to read a Sale's own basic
-- labels). Fix: resolve store_name/payment_method_name/collection_channel_name
-- INSIDE these SECURITY DEFINER RPCs, exactly the same pattern 0070 already
-- established for salesperson_name — this is the Sale's own attached data,
-- scoped to a Sale the caller is already permitted to see, never a general
-- grant of Master Data browsing. The Sales list/detail TypeScript is
-- updated in the same delivery to stop reading those tables directly.
--
-- Item 2/7 — get_sales_order() now also returns row_version (needed by the
-- Edit form to submit p_expected_version on Save/Preview, 0075/0078) and
-- each item's calculation_version (so a mixed legacy/v2 order is visible
-- for debugging/audit, not just inferred) — neither is profit-sensitive, so
-- both are returned regardless of sales.view_profit.
--
-- Both functions gain new output columns, which CREATE OR REPLACE cannot do
-- in place (same rule 0070 already documented) — both old overloads are
-- explicitly DROPped first.
-- ---------------------------------------------------------------------------
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
  store_name text,
  sale_date date,
  salesperson_id uuid,
  salesperson_name text,
  payment_method_id uuid,
  payment_method_name text,
  collection_channel_id uuid,
  collection_channel_name text,
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
    st.name_ar,
    so.sale_date,
    so.salesperson_id,
    sp.full_name,
    so.payment_method_id,
    pm.name_ar,
    so.collection_channel_id,
    cc.name_ar,
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
  left join public.stores st on st.id = so.store_id
  left join public.payment_methods pm on pm.id = so.payment_method_id
  left join public.collection_channels cc on cc.id = so.collection_channel_id
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
  'Paginated Sales list. As of 0079 (Patch 3.2 item 8): also resolves store_name/payment_method_name/collection_channel_name internally, exactly like the existing salesperson_name resolution (0070) — a caller with sales.view alone now sees every basic label with no dependency on stores.view/payment_methods.view/collection_channels.view. item_count only counts status=''active'' items. Profit columns remain NULL for a caller without sales.view_profit.';

revoke execute on function public.list_sales_orders(date, date, uuid, text, uuid, uuid, uuid, integer, integer) from public;
grant execute on function public.list_sales_orders(date, date, uuid, text, uuid, uuid, uuid, integer, integer) to authenticated;

drop function if exists public.get_sales_order(uuid);

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
  v_store_name text;
  v_payment_method_name text;
  v_collection_channel_name text;
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
  select st.name_ar into v_store_name from public.stores st where st.id = v_order.store_id;
  select pm.name_ar into v_payment_method_name from public.payment_methods pm where pm.id = v_order.payment_method_id;
  select cc.name_ar into v_collection_channel_name from public.collection_channels cc where cc.id = v_order.collection_channel_id;

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
        'karat_code_snapshot', it.karat_code_snapshot, 'karat_name_ar_snapshot', it.karat_name_ar_snapshot,
        'calculation_version', it.calculation_version
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
    'store_name', v_store_name,
    'sale_date', v_order.sale_date, 'sold_at', v_order.sold_at, 'salesperson_id', v_order.salesperson_id,
    'salesperson_name', v_salesperson_name,
    'payment_method_id', v_order.payment_method_id, 'payment_method_name', v_payment_method_name,
    'collection_channel_id', v_order.collection_channel_id, 'collection_channel_name', v_collection_channel_name,
    'customer_name', v_order.customer_name, 'customer_phone', v_order.customer_phone, 'notes', v_order.notes,
    'subtotal', v_order.subtotal::text,
    'is_day_closed', v_is_closed,
    'row_version', v_order.row_version,
    'calculation_version', v_order.calculation_version,
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
  'Full detail for one Sale. As of 0079 (Patch 3.2 items 2/7/8, supersedes 0070''s body): resolves store_name/payment_method_name/collection_channel_name internally alongside the existing salesperson_name (same reasoning — safe under sales.view alone, scoped to a Sale the caller can already see); returns row_version (needed by the Edit form for p_expected_version) and each item''s calculation_version — neither is profit-sensitive, both returned regardless of sales.view_profit. Items still filtered to status=''active'' only. Profit-sensitive keys remain entirely absent for a caller without sales.view_profit.';

revoke execute on function public.get_sales_order(uuid) from public;
grant execute on function public.get_sales_order(uuid) to authenticated;

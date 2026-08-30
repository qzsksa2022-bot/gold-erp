-- ============================================================================
-- Phase 8 — Reports, Dashboard & Exports (0201)
-- get_sales_report(), get_items_report(), get_categories_report(),
-- get_karats_report(), get_employees_report() (§21-§25).
-- ============================================================================
-- FREEZE: migrations 0001-0200 untouched. Purely additive.
--
-- Shared contract for every report RPC in this migration (and 0202-0204):
--   - Returns ONE jsonb object: {summary: {...totals...}, rows: [...],
--     total_count: N} from a SINGLE atomic query per call (§92/§94 --
--     summary and the paginated page it belongs to always come from the
--     same MVCC snapshot; never two round trips that could disagree).
--   - Money: every amount in `summary`/`rows` is TEXT (finance-safe
--     boundary, §40). Weight: TEXT too (§41, numeric(10,4) precision must
--     survive the JSON round trip untouched).
--   - Store scope via _report_resolve_store_filter() (0199, §8).
--   - Server-side pagination/sort/filter (§45/§63) -- p_limit/p_offset,
--     capped p_limit.
--   - Profit-sensitive money columns follow the SAME redaction convention
--     as list_sales_orders/list_settlement_batches (0079/0191): present
--     in the row shape but NULL when the caller lacks sales.view_profit
--     (a permission boolean captured once, reused for every row in the
--     SAME query -- never a second permission check per row).
--   - Historical labels (§50): item-level category/karat names come from
--     sales_order_items' own *_snapshot columns (never a live join to
--     product_categories/karats for a historical row). Store/payment
--     method/collection channel/employee names have no snapshot column on
--     sales_orders itself (confirmed by schema research) -- current
--     master-data labels are joined and this is documented here as
--     descriptive-only, per §50's own fallback clause.
--   - Canonical Sales Truth (§1/§14): every cost/profit figure is read
--     directly from sales_orders/sales_order_items' own stored columns
--     (subtotal, gross_profit, payment_fee_amount, net_sales_profit,
--     base_cost, vat_cost, total_cost, gold_component_cost,
--     manufacturing_component_cost) -- never recomputed from current gold
--     price/manufacturing fee/VAT rate.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- get_sales_report() (§21): order-level detail + summary.
-- ---------------------------------------------------------------------------
create or replace function public.get_sales_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_employee_id uuid default null,
  p_category_id uuid default null,
  p_karat_id uuid default null,
  p_payment_method_id uuid default null,
  p_collection_channel_id uuid default null,
  p_search text default null,
  p_sort text default 'sale_date_desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_profit boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير المبيعات' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with matched as (
    select so.id, so.order_number, so.sale_date, so.store_id, s.name_ar as store_name,
      coalesce(emp.full_name, '—') as employee_name,
      pm.name_ar as payment_method_name, ch.name_ar as collection_channel_name,
      so.subtotal, so.gross_profit, so.payment_fee_amount, so.net_sales_profit,
      (select count(*) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as items_count,
      (select coalesce(sum(i.weight_grams), 0) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as weight_grams,
      (select coalesce(sum(i.base_cost), 0) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as base_cost,
      (select coalesce(sum(i.vat_cost), 0) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as vat_cost,
      (select coalesce(sum(i.total_cost), 0) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as total_cost
    from public.sales_orders so
    join public.stores s on s.id = so.store_id
    left join public.profiles emp on emp.id = so.salesperson_id
    left join public.payment_methods pm on pm.id = so.payment_method_id
    left join public.collection_channels ch on ch.id = so.collection_channel_id
    where so.sale_date between p_date_from and p_date_to
      and so.store_id = any (v_stores)
      and (p_employee_id is null or so.salesperson_id = p_employee_id or so.created_by = p_employee_id)
      and (p_payment_method_id is null or so.payment_method_id = p_payment_method_id)
      and (p_collection_channel_id is null or so.collection_channel_id = p_collection_channel_id)
      and (p_category_id is null or exists (select 1 from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active' and i.category_id = p_category_id))
      and (p_karat_id is null or exists (select 1 from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active' and i.karat_id = p_karat_id))
      and (p_search is null or btrim(p_search) = '' or so.order_number ilike '%' || btrim(p_search) || '%'
           or exists (select 1 from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active'
                      and (i.item_name ilike '%' || btrim(p_search) || '%' or i.sku ilike '%' || btrim(p_search) || '%')))
  ),
  summary as (
    select
      count(*) as orders_count,
      coalesce(sum(items_count), 0) as items_count,
      coalesce(sum(weight_grams), 0) as weight_grams,
      coalesce(sum(subtotal), 0) as sales_revenue,
      coalesce(sum(base_cost), 0) as base_cost,
      coalesce(sum(vat_cost), 0) as vat_cost,
      coalesce(sum(total_cost), 0) as total_cost,
      coalesce(sum(gross_profit), 0) as gross_profit,
      coalesce(sum(payment_fee_amount), 0) as payment_fees,
      coalesce(sum(net_sales_profit), 0) as net_sales_profit
    from matched
  ),
  paged as (
    select * from matched
    order by
      case when p_sort = 'sale_date_asc' then sale_date end asc,
      case when p_sort = 'subtotal_desc' then subtotal end desc,
      case when p_sort = 'subtotal_asc' then subtotal end asc,
      sale_date desc, order_number desc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select orders_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'summary', jsonb_build_object(
      'orders_count', (select orders_count from summary),
      'items_count', (select items_count from summary),
      'weight_grams', (select weight_grams::text from summary),
      'sales_revenue', (select sales_revenue::text from summary),
      'average_order_value', (case when (select orders_count from summary) = 0 then null else round((select sales_revenue from summary) / (select orders_count from summary), 2)::text end),
      'average_item_weight', (case when (select items_count from summary) = 0 then null else round((select weight_grams from summary) / (select items_count from summary), 4)::text end)
    ) || (case when v_can_profit then jsonb_build_object(
      'base_cost', (select base_cost::text from summary),
      'vat_cost', (select vat_cost::text from summary),
      'total_cost', (select total_cost::text from summary),
      'gross_profit', (select gross_profit::text from summary),
      'payment_fees', (select payment_fees::text from summary),
      'net_sales_profit', (select net_sales_profit::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'order_id', paged.id, 'order_number', paged.order_number, 'sale_date', paged.sale_date,
        'store_id', paged.store_id, 'store_name', paged.store_name, 'employee_name', paged.employee_name,
        'payment_method_name', paged.payment_method_name, 'collection_channel_name', paged.collection_channel_name,
        'items_count', paged.items_count, 'weight_grams', paged.weight_grams::text, 'sales_revenue', paged.subtotal::text
      ) || (case when v_can_profit then jsonb_build_object(
        'base_cost', paged.base_cost::text, 'vat_cost', paged.vat_cost::text, 'total_cost', paged.total_cost::text,
        'gross_profit', paged.gross_profit::text, 'payment_fee_amount', paged.payment_fee_amount::text, 'net_sales_profit', paged.net_sales_profit::text
      ) else '{}'::jsonb end) order by paged.sale_date desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_sales_report(date, date, uuid[], uuid, uuid, uuid, uuid, uuid, text, text, integer, integer) is
  'Phase 8 §21/§39/§45/§63 -- order-level Sales Report: one atomic {summary, rows, total_count} jsonb payload, server-side paginated/filtered/sorted. Profit fields (base/vat/total cost, gross profit, payment fees, net sales profit) require sales.view_profit -- absent entirely otherwise. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_sales_report(date, date, uuid[], uuid, uuid, uuid, uuid, uuid, text, text, integer, integer) from public;
grant execute on function public.get_sales_report(date, date, uuid[], uuid, uuid, uuid, uuid, uuid, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_items_report() (§22): item-identity ranking (grouped by
-- category+karat+sku/name -- there is no product/inventory master in this
-- system, so "item identity" is the natural key sold items share). Grouping
-- is done over sales_order_items rows (status='active') directly, so every
-- gram/riyal traces to the same stored item columns get_sales_report()
-- reads (§1/§14). Item-level profit is gross_profit only -- payment fees
-- are an order-level charge in this schema and cannot be allocated to a
-- single line without an arbitrary allocation rule, so net_sales_profit is
-- intentionally NOT surfaced at the item grain (documented here, §50/§83).
-- ---------------------------------------------------------------------------
create or replace function public.get_items_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_category_id uuid default null,
  p_karat_id uuid default null,
  p_search text default null,
  p_sort text default 'revenue_desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_profit boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير الأصناف' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with matched as (
    select
      i.category_id, i.karat_id,
      coalesce(nullif(btrim(i.sku), ''), lower(btrim(i.item_name))) as item_key,
      i.item_name, i.sku, i.category_name_ar_snapshot, i.karat_name_ar_snapshot, i.karat_code_snapshot,
      i.weight_grams, i.sale_price, i.base_cost, i.vat_cost, i.total_cost, i.gross_profit,
      so.sale_date
    from public.sales_order_items i
    join public.sales_orders so on so.id = i.sales_order_id
    where i.status = 'active'
      and so.sale_date between p_date_from and p_date_to
      and so.store_id = any (v_stores)
      and (p_category_id is null or i.category_id = p_category_id)
      and (p_karat_id is null or i.karat_id = p_karat_id)
      and (p_search is null or btrim(p_search) = ''
           or i.item_name ilike '%' || btrim(p_search) || '%' or i.sku ilike '%' || btrim(p_search) || '%')
  ),
  grouped as (
    select
      category_id, karat_id, item_key,
      (array_agg(item_name order by sale_date desc))[1] as item_name,
      (array_agg(sku order by sale_date desc))[1] as sku,
      (array_agg(category_name_ar_snapshot order by sale_date desc))[1] as category_label,
      (array_agg(karat_name_ar_snapshot order by sale_date desc))[1] as karat_label,
      (array_agg(karat_code_snapshot order by sale_date desc))[1] as karat_code,
      count(*) as units_sold,
      coalesce(sum(weight_grams), 0) as weight_grams,
      coalesce(sum(sale_price), 0) as revenue,
      coalesce(sum(base_cost), 0) as base_cost,
      coalesce(sum(vat_cost), 0) as vat_cost,
      coalesce(sum(total_cost), 0) as total_cost,
      coalesce(sum(gross_profit), 0) as gross_profit
    from matched
    group by category_id, karat_id, item_key
  ),
  summary as (
    select
      count(*) as items_count,
      coalesce(sum(units_sold), 0) as units_sold,
      coalesce(sum(weight_grams), 0) as weight_grams,
      coalesce(sum(revenue), 0) as revenue,
      coalesce(sum(base_cost), 0) as base_cost,
      coalesce(sum(vat_cost), 0) as vat_cost,
      coalesce(sum(total_cost), 0) as total_cost,
      coalesce(sum(gross_profit), 0) as gross_profit
    from grouped
  ),
  paged as (
    select * from grouped
    order by
      case when p_sort = 'revenue_asc' then revenue end asc,
      case when p_sort = 'weight_desc' then weight_grams end desc,
      case when p_sort = 'weight_asc' then weight_grams end asc,
      case when p_sort = 'units_desc' then units_sold end desc,
      case when p_sort = 'units_asc' then units_sold end asc,
      revenue desc, item_name asc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select items_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'summary', jsonb_build_object(
      'items_count', (select items_count from summary),
      'units_sold', (select units_sold from summary),
      'weight_grams', (select weight_grams::text from summary),
      'revenue', (select revenue::text from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'base_cost', (select base_cost::text from summary),
      'vat_cost', (select vat_cost::text from summary),
      'total_cost', (select total_cost::text from summary),
      'gross_profit', (select gross_profit::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'category_id', paged.category_id, 'category_label', paged.category_label,
        'karat_id', paged.karat_id, 'karat_label', paged.karat_label, 'karat_code', paged.karat_code,
        'item_name', paged.item_name, 'sku', paged.sku,
        'units_sold', paged.units_sold, 'weight_grams', paged.weight_grams::text, 'revenue', paged.revenue::text
      ) || (case when v_can_profit then jsonb_build_object(
        'base_cost', paged.base_cost::text, 'vat_cost', paged.vat_cost::text, 'total_cost', paged.total_cost::text,
        'gross_profit', paged.gross_profit::text
      ) else '{}'::jsonb end) order by paged.revenue desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_items_report(date, date, uuid[], uuid, uuid, text, text, integer, integer) is
  'Phase 8 §22/§39/§45/§63 -- item-identity ranking (grouped by category+karat+sku/name over sales_order_items). Item-level profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_items_report(date, date, uuid[], uuid, uuid, text, text, integer, integer) from public;
grant execute on function public.get_items_report(date, date, uuid[], uuid, uuid, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_categories_report() (§23): grouped by product_categories. Current
-- master-data label is used (categories have no per-item historical name
-- change scenario tracked beyond the item snapshot; grouping by the stable
-- category_id and labelling with the CURRENT name is documented here as
-- descriptive-only per §50's fallback clause -- the identity key (category_id)
-- is always the stable/authoritative one, only the display label can drift).
-- ---------------------------------------------------------------------------
create or replace function public.get_categories_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_karat_id uuid default null,
  p_search text default null,
  p_sort text default 'revenue_desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_profit boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير الأصناف حسب الفئة' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with matched as (
    select i.category_id, so.id as order_id, i.weight_grams, i.sale_price, i.base_cost, i.vat_cost, i.total_cost, i.gross_profit
    from public.sales_order_items i
    join public.sales_orders so on so.id = i.sales_order_id
    where i.status = 'active'
      and so.sale_date between p_date_from and p_date_to
      and so.store_id = any (v_stores)
      and (p_karat_id is null or i.karat_id = p_karat_id)
  ),
  grouped as (
    select category_id,
      count(*) as items_count,
      count(distinct order_id) as orders_count,
      coalesce(sum(weight_grams), 0) as weight_grams,
      coalesce(sum(sale_price), 0) as revenue,
      coalesce(sum(base_cost), 0) as base_cost,
      coalesce(sum(vat_cost), 0) as vat_cost,
      coalesce(sum(total_cost), 0) as total_cost,
      coalesce(sum(gross_profit), 0) as gross_profit
    from matched
    group by category_id
  ),
  labelled as (
    select g.*, c.name_ar as category_label, c.code as category_code
    from grouped g
    join public.product_categories c on c.id = g.category_id
    where p_search is null or btrim(p_search) = '' or c.name_ar ilike '%' || btrim(p_search) || '%' or c.code ilike '%' || btrim(p_search) || '%'
  ),
  summary as (
    select
      count(*) as categories_count,
      coalesce(sum(items_count), 0) as items_count,
      coalesce(sum(orders_count), 0) as orders_count,
      coalesce(sum(weight_grams), 0) as weight_grams,
      coalesce(sum(revenue), 0) as revenue,
      coalesce(sum(base_cost), 0) as base_cost,
      coalesce(sum(vat_cost), 0) as vat_cost,
      coalesce(sum(total_cost), 0) as total_cost,
      coalesce(sum(gross_profit), 0) as gross_profit
    from labelled
  ),
  paged as (
    select * from labelled
    order by
      case when p_sort = 'revenue_asc' then revenue end asc,
      case when p_sort = 'weight_desc' then weight_grams end desc,
      case when p_sort = 'weight_asc' then weight_grams end asc,
      revenue desc, category_label asc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select categories_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'summary', jsonb_build_object(
      'categories_count', (select categories_count from summary),
      'items_count', (select items_count from summary),
      'orders_count', (select orders_count from summary),
      'weight_grams', (select weight_grams::text from summary),
      'revenue', (select revenue::text from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'base_cost', (select base_cost::text from summary),
      'vat_cost', (select vat_cost::text from summary),
      'total_cost', (select total_cost::text from summary),
      'gross_profit', (select gross_profit::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'category_id', paged.category_id, 'category_label', paged.category_label, 'category_code', paged.category_code,
        'items_count', paged.items_count, 'orders_count', paged.orders_count,
        'weight_grams', paged.weight_grams::text, 'revenue', paged.revenue::text
      ) || (case when v_can_profit then jsonb_build_object(
        'base_cost', paged.base_cost::text, 'vat_cost', paged.vat_cost::text, 'total_cost', paged.total_cost::text,
        'gross_profit', paged.gross_profit::text
      ) else '{}'::jsonb end) order by paged.revenue desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_categories_report(date, date, uuid[], uuid, text, text, integer, integer) is
  'Phase 8 §23/§39/§45/§63 -- category ranking over sales_order_items grouped by category_id, current master-data label (descriptive-only, §50). Profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_categories_report(date, date, uuid[], uuid, text, text, integer, integer) from public;
grant execute on function public.get_categories_report(date, date, uuid[], uuid, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_karats_report() (§24): grouped by karats, same conventions as
-- get_categories_report() (current master-data label, descriptive-only).
-- ---------------------------------------------------------------------------
create or replace function public.get_karats_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_category_id uuid default null,
  p_search text default null,
  p_sort text default 'revenue_desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_profit boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير الأصناف حسب العيار' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with matched as (
    select i.karat_id, so.id as order_id, i.weight_grams, i.sale_price, i.base_cost, i.vat_cost, i.total_cost, i.gross_profit
    from public.sales_order_items i
    join public.sales_orders so on so.id = i.sales_order_id
    where i.status = 'active'
      and so.sale_date between p_date_from and p_date_to
      and so.store_id = any (v_stores)
      and (p_category_id is null or i.category_id = p_category_id)
  ),
  grouped as (
    select karat_id,
      count(*) as items_count,
      count(distinct order_id) as orders_count,
      coalesce(sum(weight_grams), 0) as weight_grams,
      coalesce(sum(sale_price), 0) as revenue,
      coalesce(sum(base_cost), 0) as base_cost,
      coalesce(sum(vat_cost), 0) as vat_cost,
      coalesce(sum(total_cost), 0) as total_cost,
      coalesce(sum(gross_profit), 0) as gross_profit
    from matched
    group by karat_id
  ),
  labelled as (
    select g.*, k.name_ar as karat_label, k.code as karat_code
    from grouped g
    join public.karats k on k.id = g.karat_id
    where p_search is null or btrim(p_search) = '' or k.name_ar ilike '%' || btrim(p_search) || '%' or k.code ilike '%' || btrim(p_search) || '%'
  ),
  summary as (
    select
      count(*) as karats_count,
      coalesce(sum(items_count), 0) as items_count,
      coalesce(sum(orders_count), 0) as orders_count,
      coalesce(sum(weight_grams), 0) as weight_grams,
      coalesce(sum(revenue), 0) as revenue,
      coalesce(sum(base_cost), 0) as base_cost,
      coalesce(sum(vat_cost), 0) as vat_cost,
      coalesce(sum(total_cost), 0) as total_cost,
      coalesce(sum(gross_profit), 0) as gross_profit
    from labelled
  ),
  paged as (
    select * from labelled
    order by
      case when p_sort = 'revenue_asc' then revenue end asc,
      case when p_sort = 'weight_desc' then weight_grams end desc,
      case when p_sort = 'weight_asc' then weight_grams end asc,
      revenue desc, karat_label asc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select karats_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'summary', jsonb_build_object(
      'karats_count', (select karats_count from summary),
      'items_count', (select items_count from summary),
      'orders_count', (select orders_count from summary),
      'weight_grams', (select weight_grams::text from summary),
      'revenue', (select revenue::text from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'base_cost', (select base_cost::text from summary),
      'vat_cost', (select vat_cost::text from summary),
      'total_cost', (select total_cost::text from summary),
      'gross_profit', (select gross_profit::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'karat_id', paged.karat_id, 'karat_label', paged.karat_label, 'karat_code', paged.karat_code,
        'items_count', paged.items_count, 'orders_count', paged.orders_count,
        'weight_grams', paged.weight_grams::text, 'revenue', paged.revenue::text
      ) || (case when v_can_profit then jsonb_build_object(
        'base_cost', paged.base_cost::text, 'vat_cost', paged.vat_cost::text, 'total_cost', paged.total_cost::text,
        'gross_profit', paged.gross_profit::text
      ) else '{}'::jsonb end) order by paged.revenue desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_karats_report(date, date, uuid[], uuid, text, text, integer, integer) is
  'Phase 8 §24/§39/§45/§63 -- karat ranking over sales_order_items grouped by karat_id, current master-data label (descriptive-only, §50). Profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_karats_report(date, date, uuid[], uuid, text, text, integer, integer) from public;
grant execute on function public.get_karats_report(date, date, uuid[], uuid, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_employees_report() (§25): grouped by salesperson_id (order-level --
-- sales_orders has no per-order employee-name snapshot column, so the
-- CURRENT profiles.full_name is joined and documented as descriptive-only,
-- §50). Profit fields mirror get_sales_report()'s order-level set exactly
-- (gross_profit, payment_fees, net_sales_profit) since these are genuinely
-- order-level here, unlike the item-level reports above.
-- ---------------------------------------------------------------------------
create or replace function public.get_employees_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_search text default null,
  p_sort text default 'revenue_desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_profit boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير الموظفين' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with matched as (
    select so.id, so.salesperson_id, so.subtotal, so.gross_profit, so.payment_fee_amount, so.net_sales_profit,
      (select coalesce(sum(i.weight_grams), 0) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as weight_grams,
      (select count(*) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as items_count
    from public.sales_orders so
    where so.sale_date between p_date_from and p_date_to
      and so.store_id = any (v_stores)
  ),
  grouped as (
    select salesperson_id,
      count(*) as orders_count,
      coalesce(sum(items_count), 0) as items_count,
      coalesce(sum(weight_grams), 0) as weight_grams,
      coalesce(sum(subtotal), 0) as revenue,
      coalesce(sum(gross_profit), 0) as gross_profit,
      coalesce(sum(payment_fee_amount), 0) as payment_fees,
      coalesce(sum(net_sales_profit), 0) as net_sales_profit
    from matched
    group by salesperson_id
  ),
  labelled as (
    select g.*, p.full_name as employee_name
    from grouped g
    join public.profiles p on p.id = g.salesperson_id
    where p_search is null or btrim(p_search) = '' or p.full_name ilike '%' || btrim(p_search) || '%'
  ),
  summary as (
    select
      count(*) as employees_count,
      coalesce(sum(orders_count), 0) as orders_count,
      coalesce(sum(items_count), 0) as items_count,
      coalesce(sum(weight_grams), 0) as weight_grams,
      coalesce(sum(revenue), 0) as revenue,
      coalesce(sum(gross_profit), 0) as gross_profit,
      coalesce(sum(payment_fees), 0) as payment_fees,
      coalesce(sum(net_sales_profit), 0) as net_sales_profit
    from labelled
  ),
  paged as (
    select * from labelled
    order by
      case when p_sort = 'revenue_asc' then revenue end asc,
      case when p_sort = 'orders_desc' then orders_count end desc,
      case when p_sort = 'orders_asc' then orders_count end asc,
      revenue desc, employee_name asc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select employees_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'summary', jsonb_build_object(
      'employees_count', (select employees_count from summary),
      'orders_count', (select orders_count from summary),
      'items_count', (select items_count from summary),
      'weight_grams', (select weight_grams::text from summary),
      'revenue', (select revenue::text from summary),
      'average_order_value', (case when (select orders_count from summary) = 0 then null else round((select revenue from summary) / (select orders_count from summary), 2)::text end)
    ) || (case when v_can_profit then jsonb_build_object(
      'gross_profit', (select gross_profit::text from summary),
      'payment_fees', (select payment_fees::text from summary),
      'net_sales_profit', (select net_sales_profit::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'employee_id', paged.salesperson_id, 'employee_name', paged.employee_name,
        'orders_count', paged.orders_count, 'items_count', paged.items_count,
        'weight_grams', paged.weight_grams::text, 'revenue', paged.revenue::text
      ) || (case when v_can_profit then jsonb_build_object(
        'gross_profit', paged.gross_profit::text, 'payment_fees', paged.payment_fees::text, 'net_sales_profit', paged.net_sales_profit::text
      ) else '{}'::jsonb end) order by paged.revenue desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_employees_report(date, date, uuid[], text, text, integer, integer) is
  'Phase 8 §25/§39/§45/§63 -- employee (salesperson) ranking over sales_orders grouped by salesperson_id, current profiles.full_name (descriptive-only, §50). Profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_employees_report(date, date, uuid[], text, text, integer, integer) from public;
grant execute on function public.get_employees_report(date, date, uuid[], text, text, integer, integer) to authenticated;

commit;

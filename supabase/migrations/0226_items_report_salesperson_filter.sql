-- ============================================================================
-- Phase 8 — Final Closure Hotfix 8.1.2 — §34-36:
-- get_items_report() gains a p_salesperson_id filter, bound to
-- sales_orders.salesperson_id — the same real column the Employees report
-- and Returns report already filter/attribute against, just never exposed
-- on the Items report.
-- ============================================================================
-- Migrations 0001-0225 are FROZEN. This migration only ADDS 0226+.
-- NEW parameter -- signature change, DROP FUNCTION + CREATE FUNCTION
-- required (§0; body-only CREATE OR REPLACE would not suffice).
--
-- p_salesperson_id filters `matched` (the per-sale-item source rows, before
-- the item-identity GROUP BY) against so.salesperson_id -- the SAME join
-- (`sales_order_items i join sales_orders so on so.id = i.sales_order_id`)
-- this report already performs, so no new join/table read is introduced.
-- ============================================================================
begin;

drop function if exists public.get_items_report(date, date, uuid[], uuid, uuid, text, text, integer, integer);

create function public.get_items_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_category_id uuid default null,
  p_karat_id uuid default null,
  p_search text default null,
  p_sort text default 'revenue_desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_salesperson_id uuid default null
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
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
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
      and (p_salesperson_id is null or so.salesperson_id = p_salesperson_id)
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

comment on function public.get_items_report(date, date, uuid[], uuid, uuid, text, text, integer, integer, uuid) is
  'Phase 8 §14/§39; Hotfix 8.1.1 §11-14/§60 (cap 5000); Hotfix 8.1.2 §34-36 -- Items Report, grouped by stable item identity (sku, or normalized item_name when sku is blank). p_salesperson_id (NEW) filters the underlying sales_orders.salesperson_id -- the SAME column the Employees/Returns reports already use. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_items_report(date, date, uuid[], uuid, uuid, text, text, integer, integer, uuid) from public;
grant execute on function public.get_items_report(date, date, uuid[], uuid, uuid, text, text, integer, integer, uuid) to authenticated;

commit;

-- ============================================================================
-- Patch 8.1 §50-51 / §71 — Reports/Dashboard performance: get_sales_report()
-- plan-shape fix (byte-identical signature, CREATE OR REPLACE per §0).
-- ============================================================================
-- The performance fixture (supabase/tests/tests/fixtures — see
-- phase8_performance_fixture.sql, 10,500 real sales orders across a
-- 365-day window) exposed a real cost problem in get_sales_report(): its
-- "matched" CTE ran FIVE separate correlated subqueries against
-- sales_order_items (items_count/weight_grams/base_cost/vat_cost/
-- total_cost) PLUS one more against sales_returns
-- (effective_return_net_profit_adjustment) -- for EVERY matching order row,
-- not just the paged page. Over a full-year/10,500-order report window
-- that is ~6 correlated-subquery executions x thousands of rows before the
-- summary aggregate can even be computed (the summary, by definition,
-- must touch every row in the filtered window, not just the returned
-- page) -- a real, measurable cost (single-digit seconds at fixture
-- scale), not a hypothetical one.
--
-- The fix is a pure plan-shape change: replace the six per-row correlated
-- subqueries with two GROUP BY aggregates (one over sales_order_items,
-- one over sales_returns), each scoped to the already date/store/
-- employee/payment/channel/category/karat/search-filtered order set via a
-- join back to the `base` CTE, then LEFT JOINed onto `base` once. This
-- computes the exact same per-order figures (coalesce(...,0) after the
-- LEFT JOIN reproduces the original subqueries' 0-when-no-rows behavior
-- exactly) via ONE aggregate pass over each source table instead of N
-- per-row index probes -- never a recomputation of any financial figure
-- (§1), purely how the existing formula is evaluated.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_sales_report(p_date_from date, p_date_to date, p_store_ids uuid[] DEFAULT NULL::uuid[], p_employee_id uuid DEFAULT NULL::uuid, p_category_id uuid DEFAULT NULL::uuid, p_karat_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_collection_channel_id uuid DEFAULT NULL::uuid, p_search text DEFAULT NULL::text, p_sort text DEFAULT 'sale_date_desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_can_profit boolean;
  v_stores uuid[];
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('sales.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير المبيعات' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with base as (
    select so.id, so.order_number, so.sale_date, so.store_id, s.name_ar as store_name,
      coalesce(emp.full_name, '—') as employee_name,
      pm.name_ar as payment_method_name, ch.name_ar as collection_channel_name,
      so.subtotal, so.gross_profit, so.payment_fee_amount, so.net_sales_profit
    from public.sales_orders so
    join public.stores s on s.id = so.store_id
    left join public.profiles emp on emp.id = so.salesperson_id
    left join public.payment_methods pm on pm.id = so.payment_method_id
    left join public.collection_channels ch on ch.id = so.collection_channel_id
    where so.sale_date between p_date_from and p_date_to
      and so.store_id = any (v_stores)
      -- §35: salesperson_id ONLY -- never created_by (Operator/Audit-creator
      -- is a distinct concept and must never be conflated with the
      -- Salesperson business attribution).
      and (p_employee_id is null or so.salesperson_id = p_employee_id)
      and (p_payment_method_id is null or so.payment_method_id = p_payment_method_id)
      and (p_collection_channel_id is null or so.collection_channel_id = p_collection_channel_id)
      and (p_category_id is null or exists (select 1 from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active' and i.category_id = p_category_id))
      and (p_karat_id is null or exists (select 1 from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active' and i.karat_id = p_karat_id))
      and (p_search is null or btrim(p_search) = '' or so.order_number ilike '%' || btrim(p_search) || '%'
           or exists (select 1 from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active'
                      and (i.item_name ilike '%' || btrim(p_search) || '%' or i.sku ilike '%' || btrim(p_search) || '%')))
  ),
  item_agg as (
    select i.sales_order_id,
      count(*) as items_count,
      coalesce(sum(i.weight_grams), 0) as weight_grams,
      coalesce(sum(i.base_cost), 0) as base_cost,
      coalesce(sum(i.vat_cost), 0) as vat_cost,
      coalesce(sum(i.total_cost), 0) as total_cost
    from public.sales_order_items i
    join base b on b.id = i.sales_order_id
    where i.status = 'active'
    group by i.sales_order_id
  ),
  return_agg as (
    -- §33/§34: CURRENT EFFECTIVE return impact tied to this sale (Sale
    -- Cohort basis) -- only status='approved' returns contribute; a
    -- reversed return's effect is undone as of now.
    select sr.sales_order_id,
      coalesce(sum(sr.net_sales_profit_adjustment), 0) as effective_return_net_profit_adjustment
    from public.sales_returns sr
    join base b on b.id = sr.sales_order_id
    where sr.status = 'approved'
    group by sr.sales_order_id
  ),
  matched as (
    select
      b.id, b.order_number, b.sale_date, b.store_id, b.store_name, b.employee_name,
      b.payment_method_name, b.collection_channel_name,
      b.subtotal, b.gross_profit, b.payment_fee_amount, b.net_sales_profit,
      coalesce(ia.items_count, 0) as items_count,
      coalesce(ia.weight_grams, 0) as weight_grams,
      coalesce(ia.base_cost, 0) as base_cost,
      coalesce(ia.vat_cost, 0) as vat_cost,
      coalesce(ia.total_cost, 0) as total_cost,
      coalesce(ra.effective_return_net_profit_adjustment, 0) as effective_return_net_profit_adjustment
    from base b
    left join item_agg ia on ia.sales_order_id = b.id
    left join return_agg ra on ra.sales_order_id = b.id
  ),
  extended as (
    select *, (net_sales_profit + effective_return_net_profit_adjustment) as effective_net_sales_profit
    from matched
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
      coalesce(sum(net_sales_profit), 0) as net_sales_profit,
      coalesce(sum(effective_return_net_profit_adjustment), 0) as effective_return_net_profit_adjustment,
      coalesce(sum(effective_net_sales_profit), 0) as effective_net_sales_profit
    from extended
  ),
  paged as (
    select * from extended
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
      'net_sales_profit', (select net_sales_profit::text from summary),
      'original_net_sales_profit', (select net_sales_profit::text from summary),
      'effective_return_net_profit_adjustment', (select effective_return_net_profit_adjustment::text from summary),
      'effective_net_sales_profit', (select effective_net_sales_profit::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'order_id', paged.id, 'order_number', paged.order_number, 'sale_date', paged.sale_date,
        'store_id', paged.store_id, 'store_name', paged.store_name, 'employee_name', paged.employee_name,
        'payment_method_name', paged.payment_method_name, 'collection_channel_name', paged.collection_channel_name,
        'items_count', paged.items_count, 'weight_grams', paged.weight_grams::text, 'sales_revenue', paged.subtotal::text
      ) || (case when v_can_profit then jsonb_build_object(
        'base_cost', paged.base_cost::text, 'vat_cost', paged.vat_cost::text, 'total_cost', paged.total_cost::text,
        'gross_profit', paged.gross_profit::text, 'payment_fee_amount', paged.payment_fee_amount::text, 'net_sales_profit', paged.net_sales_profit::text,
        'original_net_sales_profit', paged.net_sales_profit::text,
        'effective_return_net_profit_adjustment', paged.effective_return_net_profit_adjustment::text,
        'effective_net_sales_profit', paged.effective_net_sales_profit::text
      ) else '{}'::jsonb end) order by paged.sale_date desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$function$;

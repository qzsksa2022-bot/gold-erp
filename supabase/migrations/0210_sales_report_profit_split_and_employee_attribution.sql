-- ============================================================================
-- Phase 8 — Integrity Patch 8.1 — §33-36/§66: Sales Report original/effective
-- profit split + correct Salesperson attribution (Sales Cohort basis).
-- ============================================================================
-- Migrations 0001-0209 are FROZEN. This migration only ADDS 0210+. Both
-- functions below keep their EXACT existing signatures (no new params), so
-- this uses CREATE OR REPLACE FUNCTION directly -- no DROP needed, unlike
-- 0206/0207/0208/0209 where the signature itself changed.
--
-- §34 basis (unchanged, restated for clarity): /reports/sales and the
-- Employees report are a SALE COHORT by sale_date -- any Return adjustment
-- shown here reflects the CURRENT EFFECTIVE Return impact tied to that sale
-- (i.e. sales_returns rows joined by sales_order_id, filtered to CURRENTLY
-- status='approved' -- a status='reversed' return no longer contributes).
-- This is DELIBERATELY different from the Dashboard's Event-Period basis
-- (get_dashboard_summary()/get_returns_report()), which places a Return's
-- effect at the return/reversal's OWN date -- the two must never be
-- conflated (§34's explicit warning). Nothing here changes any Event-Period
-- RPC or rewrites a Sale's own date.
--
-- §33/§66 -- get_sales_report(): ADDS (additive, existing keys unchanged)
-- at both summary and row level, gated sales.view_profit:
--   - original_net_sales_profit: the sale's own immutable net_sales_profit
--     (same value already exposed as 'net_sales_profit' -- kept for
--     backward compatibility, never removed).
--   - effective_return_net_profit_adjustment: sum(sales_returns.
--     net_sales_profit_adjustment) over CURRENTLY status='approved' returns
--     against that sale (a reversed return contributes 0 -- its effect is
--     undone as of now).
--   - effective_net_sales_profit: original_net_sales_profit +
--     effective_return_net_profit_adjustment.
--
-- §35 -- the employee/salesperson filter (p_employee_id) is fixed to match
-- so.salesperson_id ONLY -- the previous "salesperson_id OR created_by"
-- conflated the actual Salesperson (business attribution) with whoever
-- happened to key the order in (an Operator/Audit-creator concept). A
-- future Creator/operational report, if ever needed, must be a SEPARATE
-- filter/report and must never be labelled "الموظف البائع" (the
-- salesperson) -- not attempted here (§73 No Scope Creep).
--
-- §36/§66 -- get_employees_report(): ADDS, attributed by the Salesperson's
-- OWN Sales Cohort (so.salesperson_id = the group key -- never the
-- return's approver/creator):
--   - returns_count: currently status='approved' returns against sales in
--     this salesperson's cohort.
--   - returned_value_effective: sum(approved_refund_amount) over the same
--     currently-approved returns (the CURRENT effective refund target).
--   - effective_return_net_profit_adjustment / effective_net_sales_profit:
--     identical formula to get_sales_report(), summed across the cohort.
--
-- §60: v_limit cap raised 500 -> 5000 on both functions (matches every
-- other report RPC touched this patch).
-- ============================================================================
begin;

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

  with matched as (
    select so.id, so.order_number, so.sale_date, so.store_id, s.name_ar as store_name,
      coalesce(emp.full_name, '—') as employee_name,
      pm.name_ar as payment_method_name, ch.name_ar as collection_channel_name,
      so.subtotal, so.gross_profit, so.payment_fee_amount, so.net_sales_profit,
      (select count(*) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as items_count,
      (select coalesce(sum(i.weight_grams), 0) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as weight_grams,
      (select coalesce(sum(i.base_cost), 0) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as base_cost,
      (select coalesce(sum(i.vat_cost), 0) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as vat_cost,
      (select coalesce(sum(i.total_cost), 0) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as total_cost,
      -- §33/§34: CURRENT EFFECTIVE return impact tied to this sale (Sale
      -- Cohort basis) -- only status='approved' returns contribute; a
      -- reversed return's effect is undone as of now.
      (select coalesce(sum(sr.net_sales_profit_adjustment), 0)
         from public.sales_returns sr where sr.sales_order_id = so.id and sr.status = 'approved') as effective_return_net_profit_adjustment
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
$$;

comment on function public.get_sales_report(date, date, uuid[], uuid, uuid, uuid, uuid, uuid, text, text, integer, integer) is
  'Phase 8 §21/§39/§45/§63; Patch 8.1 §33-35/§66 -- order-level Sales Report, Sale Cohort basis (by sale_date, §34). Adds original_net_sales_profit / effective_return_net_profit_adjustment (sum of CURRENTLY status=approved sales_returns.net_sales_profit_adjustment against the sale) / effective_net_sales_profit = original + adjustment, alongside the pre-existing net_sales_profit (kept, unchanged, for backward compatibility). p_employee_id filters so.salesperson_id ONLY -- never created_by (§35, no Operator/creator conflation). Profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_sales_report(date, date, uuid[], uuid, uuid, uuid, uuid, uuid, text, text, integer, integer) from public;
grant execute on function public.get_sales_report(date, date, uuid[], uuid, uuid, uuid, uuid, uuid, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_employees_report() (§36/§66): adds Returns attribution, strictly by
-- the Salesperson's own Sales Cohort (so.salesperson_id = group key) --
-- never by a return's approver/creator.
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
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
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
      (select count(*) from public.sales_order_items i where i.sales_order_id = so.id and i.status = 'active') as items_count,
      -- §36: currently-approved returns against THIS sale (Sale Cohort
      -- basis, identical formula to get_sales_report()).
      (select count(*) from public.sales_returns sr where sr.sales_order_id = so.id and sr.status = 'approved') as returns_count,
      (select coalesce(sum(sr.approved_refund_amount), 0) from public.sales_returns sr where sr.sales_order_id = so.id and sr.status = 'approved') as returned_value_effective,
      (select coalesce(sum(sr.net_sales_profit_adjustment), 0) from public.sales_returns sr where sr.sales_order_id = so.id and sr.status = 'approved') as effective_return_net_profit_adjustment
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
      coalesce(sum(net_sales_profit), 0) as net_sales_profit,
      coalesce(sum(returns_count), 0) as returns_count,
      coalesce(sum(returned_value_effective), 0) as returned_value_effective,
      coalesce(sum(effective_return_net_profit_adjustment), 0) as effective_return_net_profit_adjustment,
      coalesce(sum(net_sales_profit) + sum(effective_return_net_profit_adjustment), 0) as effective_net_sales_profit
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
      coalesce(sum(net_sales_profit), 0) as net_sales_profit,
      coalesce(sum(returns_count), 0) as returns_count,
      coalesce(sum(returned_value_effective), 0) as returned_value_effective,
      coalesce(sum(effective_return_net_profit_adjustment), 0) as effective_return_net_profit_adjustment,
      coalesce(sum(effective_net_sales_profit), 0) as effective_net_sales_profit
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
      'average_order_value', (case when (select orders_count from summary) = 0 then null else round((select revenue from summary) / (select orders_count from summary), 2)::text end),
      'returns_count', (select returns_count from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'gross_profit', (select gross_profit::text from summary),
      'payment_fees', (select payment_fees::text from summary),
      'net_sales_profit', (select net_sales_profit::text from summary),
      'returned_value_effective', (select returned_value_effective::text from summary),
      'effective_return_net_profit_adjustment', (select effective_return_net_profit_adjustment::text from summary),
      'effective_net_sales_profit', (select effective_net_sales_profit::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'employee_id', paged.salesperson_id, 'employee_name', paged.employee_name,
        'orders_count', paged.orders_count, 'items_count', paged.items_count,
        'weight_grams', paged.weight_grams::text, 'revenue', paged.revenue::text,
        'returns_count', paged.returns_count
      ) || (case when v_can_profit then jsonb_build_object(
        'gross_profit', paged.gross_profit::text, 'payment_fees', paged.payment_fees::text, 'net_sales_profit', paged.net_sales_profit::text,
        'returned_value_effective', paged.returned_value_effective::text,
        'effective_return_net_profit_adjustment', paged.effective_return_net_profit_adjustment::text,
        'effective_net_sales_profit', paged.effective_net_sales_profit::text
      ) else '{}'::jsonb end) order by paged.revenue desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_employees_report(date, date, uuid[], text, text, integer, integer) is
  'Phase 8 §25/§39/§45/§63; Patch 8.1 §36/§66 -- employee (salesperson) ranking over sales_orders grouped by salesperson_id ONLY (never created_by, §35). Adds returns_count / returned_value_effective / effective_return_net_profit_adjustment / effective_net_sales_profit, attributed strictly by the Salesperson''s own Sales Cohort (currently status=approved returns against sales in that cohort) -- never by a return''s approver/creator. Profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_employees_report(date, date, uuid[], text, text, integer, integer) from public;
grant execute on function public.get_employees_report(date, date, uuid[], text, text, integer, integer) to authenticated;

commit;

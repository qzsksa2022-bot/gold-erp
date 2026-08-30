-- ============================================================================
-- Phase 8 — Reports, Dashboard & Exports (0202)
-- get_payment_methods_report(), get_collection_channels_report(),
-- get_returns_report() (§26-§28).
-- ============================================================================
-- FREEZE: migrations 0001-0201 untouched. Purely additive.
--
-- get_payment_methods_report()/get_collection_channels_report() follow the
-- exact same order-level grouping contract as get_employees_report() (0201):
-- {summary, rows, total_count}, grouped over sales_orders, current
-- master-data label (descriptive-only, §50), profit fields gated by
-- sales.view_profit.
--
-- get_returns_report() is different in shape: it is a MOVEMENTS LEDGER
-- (§84/§85), not a current-status snapshot. Every sales_returns row can
-- contribute up to two separate movement rows to a given period:
--   - an 'approved' movement dated at its own return_date (status in
--     ('approved','reversed') -- a reversed return still HAPPENED as an
--     approval on its own date, §82 historical visibility);
--   - a 'reversed' movement dated at its own SEPARATE reversal_business_date
--     (status = 'reversed' only), carrying the NEGATED figures (the undo).
-- A period's net return effect = sum over whichever movements actually
-- fall inside it, which is exactly how get_dashboard_summary()'s
-- returns_appr_cte/returns_undo_cte compute the Net Operating Return
-- contribution (§18/§85) -- this report is the row-level detail backing
-- that same aggregate (§39 Single Reporting Engine: same dataset/formula).
-- The authoritative signed profit-adjustment column is
-- sales_returns.net_sales_profit_adjustment (0092/0099) -- NOT the legacy
-- net_profit_reversal_amount column, which carries the wrong sign for
-- historical rows (see 0200's discovery note).
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- get_payment_methods_report() (§26): grouped by payment_method_id over
-- sales_orders.
-- ---------------------------------------------------------------------------
create or replace function public.get_payment_methods_report(
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
    raise exception 'ليست لديك صلاحية عرض تقرير طرق الدفع' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with matched as (
    select so.id, so.payment_method_id, so.subtotal, so.gross_profit, so.payment_fee_amount, so.net_sales_profit
    from public.sales_orders so
    where so.sale_date between p_date_from and p_date_to
      and so.store_id = any (v_stores)
  ),
  grouped as (
    select payment_method_id,
      count(*) as orders_count,
      coalesce(sum(subtotal), 0) as revenue,
      coalesce(sum(gross_profit), 0) as gross_profit,
      coalesce(sum(payment_fee_amount), 0) as payment_fees,
      coalesce(sum(net_sales_profit), 0) as net_sales_profit
    from matched
    group by payment_method_id
  ),
  labelled as (
    select g.*, pm.name_ar as payment_method_name, pm.key as payment_method_key
    from grouped g
    join public.payment_methods pm on pm.id = g.payment_method_id
    where p_search is null or btrim(p_search) = '' or pm.name_ar ilike '%' || btrim(p_search) || '%' or pm.key ilike '%' || btrim(p_search) || '%'
  ),
  summary as (
    select
      count(*) as payment_methods_count,
      coalesce(sum(orders_count), 0) as orders_count,
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
      revenue desc, payment_method_name asc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select payment_methods_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'summary', jsonb_build_object(
      'payment_methods_count', (select payment_methods_count from summary),
      'orders_count', (select orders_count from summary),
      'revenue', (select revenue::text from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'gross_profit', (select gross_profit::text from summary),
      'payment_fees', (select payment_fees::text from summary),
      'net_sales_profit', (select net_sales_profit::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'payment_method_id', paged.payment_method_id, 'payment_method_name', paged.payment_method_name, 'payment_method_key', paged.payment_method_key,
        'orders_count', paged.orders_count, 'revenue', paged.revenue::text
      ) || (case when v_can_profit then jsonb_build_object(
        'gross_profit', paged.gross_profit::text, 'payment_fees', paged.payment_fees::text, 'net_sales_profit', paged.net_sales_profit::text
      ) else '{}'::jsonb end) order by paged.revenue desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer) is
  'Phase 8 §26/§39/§45/§63 -- payment method ranking over sales_orders grouped by payment_method_id, current master-data label (descriptive-only, §50). Profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer) from public;
grant execute on function public.get_payment_methods_report(date, date, uuid[], text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_collection_channels_report() (§27): grouped by collection_channel_id
-- over sales_orders. Same conventions as get_payment_methods_report().
-- ---------------------------------------------------------------------------
create or replace function public.get_collection_channels_report(
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
    raise exception 'ليست لديك صلاحية عرض تقرير قنوات التحصيل' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with matched as (
    select so.id, so.collection_channel_id, so.subtotal, so.gross_profit, so.payment_fee_amount, so.net_sales_profit
    from public.sales_orders so
    where so.sale_date between p_date_from and p_date_to
      and so.store_id = any (v_stores)
  ),
  grouped as (
    select collection_channel_id,
      count(*) as orders_count,
      coalesce(sum(subtotal), 0) as revenue,
      coalesce(sum(gross_profit), 0) as gross_profit,
      coalesce(sum(payment_fee_amount), 0) as payment_fees,
      coalesce(sum(net_sales_profit), 0) as net_sales_profit
    from matched
    group by collection_channel_id
  ),
  labelled as (
    select g.*, ch.name_ar as collection_channel_name, ch.key as collection_channel_key
    from grouped g
    join public.collection_channels ch on ch.id = g.collection_channel_id
    where p_search is null or btrim(p_search) = '' or ch.name_ar ilike '%' || btrim(p_search) || '%' or ch.key ilike '%' || btrim(p_search) || '%'
  ),
  summary as (
    select
      count(*) as collection_channels_count,
      coalesce(sum(orders_count), 0) as orders_count,
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
      revenue desc, collection_channel_name asc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select collection_channels_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'summary', jsonb_build_object(
      'collection_channels_count', (select collection_channels_count from summary),
      'orders_count', (select orders_count from summary),
      'revenue', (select revenue::text from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'gross_profit', (select gross_profit::text from summary),
      'payment_fees', (select payment_fees::text from summary),
      'net_sales_profit', (select net_sales_profit::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'collection_channel_id', paged.collection_channel_id, 'collection_channel_name', paged.collection_channel_name, 'collection_channel_key', paged.collection_channel_key,
        'orders_count', paged.orders_count, 'revenue', paged.revenue::text
      ) || (case when v_can_profit then jsonb_build_object(
        'gross_profit', paged.gross_profit::text, 'payment_fees', paged.payment_fees::text, 'net_sales_profit', paged.net_sales_profit::text
      ) else '{}'::jsonb end) order by paged.revenue desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_collection_channels_report(date, date, uuid[], text, text, integer, integer) is
  'Phase 8 §27/§39/§45/§63 -- collection channel ranking over sales_orders grouped by collection_channel_id, current master-data label (descriptive-only, §50). Profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_collection_channels_report(date, date, uuid[], text, text, integer, integer) from public;
grant execute on function public.get_collection_channels_report(date, date, uuid[], text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_returns_report() (§28): movements-ledger row-level Returns Report.
-- Each row is one MOVEMENT (an approval or a reversal), not one
-- sales_returns record -- a reversed return contributes two rows total
-- when both its return_date and its reversal_business_date fall in the
-- requested range, and only one (or zero) otherwise. §83 Report Basis:
-- "Movements during the Period".
-- ---------------------------------------------------------------------------
create or replace function public.get_returns_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_scenario text default null,
  p_status text default null,
  p_payment_method_id uuid default null,
  p_collection_channel_id uuid default null,
  p_search text default null,
  p_sort text default 'movement_date_desc',
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
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('returns.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير المرتجعات' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with movements as (
    -- Approval movements: return_date is the movement's own business date.
    select
      sr.id as return_id, sr.return_number, sr.return_date as movement_date, 'approved'::text as movement_type,
      sr.sales_order_id, so.order_number, sr.processed_store_id, s.name_ar as store_name,
      sr.scenario, sr.status, sr.payment_method_id, pm.name_ar as payment_method_name,
      sr.collection_channel_id_snapshot as collection_channel_id, ch.name_ar as collection_channel_name,
      sr.sales_revenue_reversal_amount as revenue_effect,
      sr.gross_profit_reversal_amount as gross_profit_effect,
      sr.payment_fee_reversal_amount as payment_fee_effect,
      sr.net_sales_profit_adjustment as net_profit_effect,
      sr.approved_refund_amount as refund_effect
    from public.sales_returns sr
    join public.sales_orders so on so.id = sr.sales_order_id
    join public.stores s on s.id = sr.processed_store_id
    left join public.payment_methods pm on pm.id = sr.payment_method_id
    left join public.collection_channels ch on ch.id = sr.collection_channel_id_snapshot
    where sr.status in ('approved', 'reversed')
      and sr.return_date between p_date_from and p_date_to
      and sr.processed_store_id = any (v_stores)
      and (p_scenario is null or sr.scenario = p_scenario)
      and (p_status is null or sr.status = p_status)
      and (p_payment_method_id is null or sr.payment_method_id = p_payment_method_id)
      and (p_collection_channel_id is null or sr.collection_channel_id_snapshot = p_collection_channel_id)
      and (p_search is null or btrim(p_search) = '' or sr.return_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')

    union all

    -- Reversal (undo) movements: reversal_business_date is a SEPARATE own
    -- business date (§85) -- the negated figures cancel the approval's
    -- financial contribution wherever the reversal itself actually lands.
    select
      sr.id as return_id, sr.return_number, sr.reversal_business_date as movement_date, 'reversed'::text as movement_type,
      sr.sales_order_id, so.order_number, sr.processed_store_id, s.name_ar as store_name,
      sr.scenario, sr.status, sr.payment_method_id, pm.name_ar as payment_method_name,
      sr.collection_channel_id_snapshot as collection_channel_id, ch.name_ar as collection_channel_name,
      -coalesce(sr.sales_revenue_reversal_amount, 0) as revenue_effect,
      -coalesce(sr.gross_profit_reversal_amount, 0) as gross_profit_effect,
      -coalesce(sr.payment_fee_reversal_amount, 0) as payment_fee_effect,
      -coalesce(sr.net_sales_profit_adjustment, 0) as net_profit_effect,
      -coalesce(sr.approved_refund_amount, 0) as refund_effect
    from public.sales_returns sr
    join public.sales_orders so on so.id = sr.sales_order_id
    join public.stores s on s.id = sr.processed_store_id
    left join public.payment_methods pm on pm.id = sr.payment_method_id
    left join public.collection_channels ch on ch.id = sr.collection_channel_id_snapshot
    where sr.status = 'reversed'
      and sr.reversal_business_date between p_date_from and p_date_to
      and sr.processed_store_id = any (v_stores)
      and (p_scenario is null or sr.scenario = p_scenario)
      and (p_status is null or sr.status = p_status)
      and (p_payment_method_id is null or sr.payment_method_id = p_payment_method_id)
      and (p_collection_channel_id is null or sr.collection_channel_id_snapshot = p_collection_channel_id)
      and (p_search is null or btrim(p_search) = '' or sr.return_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')
  ),
  summary as (
    select
      count(*) as movements_count,
      count(*) filter (where movement_type = 'approved') as approved_count,
      count(*) filter (where movement_type = 'reversed') as reversed_count,
      coalesce(sum(revenue_effect), 0) as revenue_effect,
      coalesce(sum(gross_profit_effect), 0) as gross_profit_effect,
      coalesce(sum(payment_fee_effect), 0) as payment_fee_effect,
      coalesce(sum(net_profit_effect), 0) as net_profit_effect,
      coalesce(sum(refund_effect), 0) as refund_effect
    from movements
  ),
  paged as (
    select * from movements
    order by
      case when p_sort = 'movement_date_asc' then movement_date end asc,
      movement_date desc, return_number desc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total_count', (select movements_count from summary),
    'limit', v_limit, 'offset', v_offset,
    'basis', 'movements_during_period',
    'summary', jsonb_build_object(
      'movements_count', (select movements_count from summary),
      'approved_count', (select approved_count from summary),
      'reversed_count', (select reversed_count from summary),
      'refund_effect', (select refund_effect::text from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'revenue_effect', (select revenue_effect::text from summary),
      'gross_profit_effect', (select gross_profit_effect::text from summary),
      'payment_fee_effect', (select payment_fee_effect::text from summary),
      'net_profit_effect', (select net_profit_effect::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'return_id', paged.return_id, 'return_number', paged.return_number,
        'movement_date', paged.movement_date, 'movement_type', paged.movement_type,
        'sales_order_id', paged.sales_order_id, 'order_number', paged.order_number,
        'store_id', paged.processed_store_id, 'store_name', paged.store_name,
        'scenario', paged.scenario, 'status', paged.status,
        'payment_method_name', paged.payment_method_name, 'collection_channel_name', paged.collection_channel_name,
        'refund_effect', paged.refund_effect::text
      ) || (case when v_can_profit then jsonb_build_object(
        'revenue_effect', paged.revenue_effect::text, 'gross_profit_effect', paged.gross_profit_effect::text,
        'payment_fee_effect', paged.payment_fee_effect::text, 'net_profit_effect', paged.net_profit_effect::text
      ) else '{}'::jsonb end) order by paged.movement_date desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_returns_report(date, date, uuid[], text, text, uuid, uuid, text, text, integer, integer) is
  'Phase 8 §28/§39/§45/§63/§83/§84/§85 -- returns MOVEMENTS LEDGER (row-level detail behind get_dashboard_summary()''s returns figures): each sales_returns record contributes an ''approved'' movement (dated return_date) and, if reversed, a separate ''reversed'' undo movement (dated its own reversal_business_date). Uses the authoritative net_sales_profit_adjustment column (0092/0099), never the legacy net_profit_reversal_amount. Financial-effect fields require sales.view_profit. Requires reports.view + returns.view. SECURITY DEFINER.';

revoke execute on function public.get_returns_report(date, date, uuid[], text, text, uuid, uuid, text, text, integer, integer) from public;
grant execute on function public.get_returns_report(date, date, uuid[], text, text, uuid, uuid, text, text, integer, integer) to authenticated;

commit;

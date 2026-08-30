-- ============================================================================
-- Phase 8 — Integrity Patch 8.1 — §37-38/§67: Historical category/karat
-- labels (never rewritten by a later master-data rename) + category
-- hierarchy (existing parent_id, no new Product Master).
-- ============================================================================
-- Migrations 0001-0210 are FROZEN. This migration only ADDS 0211+.
--
-- Problem (§37): sales_order_items already stores category_name_ar_snapshot
-- / karat_name_ar_snapshot / karat_code_snapshot at sale time (0059) --
-- immutable, historically accurate. But get_categories_report()/
-- get_karats_report() (0201) joined the CURRENT product_categories/karats
-- master row for the display label -- so renaming "خواتم" to "خواتم جديدة"
-- TODAY silently rewrites every historical report's label for sales made
-- BEFORE the rename, even though the grouped totals are still correct.
--
-- Fix (§37): Group identity stays the stable ID (category_id/karat_id,
-- unchanged -- historical financial totals are correct today and remain
-- so). The DISPLAY LABEL now comes from the Historical Snapshot, chosen
-- DETERMINISTICALLY when more than one snapshot label exists for the same
-- ID within the requested period (a rename mid-period): the snapshot
-- attached to the chronologically LATEST matched item (by sale_date, then
-- item created_at, then item id) wins -- documented here as the contract
-- (spec §37 explicitly permits either grouping strategy or a documented
-- deterministic choice; this is the latter, chosen because "the label as
-- of the end of the period" is the least surprising reading for a
-- date-ranged report and requires no schema change).
-- category_code has NO snapshot column in this schema (only the two name
-- snapshots + karat_code_snapshot exist, per 0059) -- current
-- product_categories.code is kept as a stable technical identifier (codes
-- are not the "current master NAME" the spec is protecting, and are not
-- normally renamed); karat_code IS snapshotted and now uses the same
-- historical-label mechanism as karat_name.
--
-- §38: adds category hierarchy metadata using the EXISTING product_categories
-- parent_id self-reference (no new Product Master, no Items/SKU change):
-- a recursive CTE resolves each category's CURRENT parent_id chain into
-- parent_category_id / parent_category_label / category_path / category_depth
-- (current-state navigational metadata -- the hierarchy STRUCTURE is not a
-- historical fact the spec asks to preserve, only the NAME LABEL is, per
-- §37's own scope) + a new p_parent_id filter (direct children only).
--
-- §67 required test (sale item snapshot Category="خواتم"/Karat="عيار 21",
-- then rename masters, historical report for the OLD period must show the
-- Snapshot never the current label) is proven in the golden-scenario test
-- expansion (§193) -- this migration ships the mechanism.
--
-- §60: v_limit cap raised 500 -> 5000 on both functions.
-- ============================================================================
begin;

-- get_categories_report() gains a new appended parameter (p_parent_id) --
-- per the established project lesson (0206/0207/0208/0209), CREATE OR
-- REPLACE with a changed parameter list creates a SECOND, ambiguous
-- overload rather than truly replacing the old one, so the OLD exact
-- 8-arg signature is dropped first.
drop function if exists public.get_categories_report(date, date, uuid[], uuid, text, text, integer, integer);

create function public.get_categories_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_karat_id uuid default null,
  p_search text default null,
  p_sort text default 'revenue_desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_parent_id uuid default null
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
    raise exception 'ليست لديك صلاحية عرض تقرير الأصناف حسب الفئة' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with recursive category_ancestry as (
    select c.id, c.parent_id, c.name_ar, 0 as depth, array[c.name_ar] as path
    from public.product_categories c
    where c.parent_id is null
    union all
    select c.id, c.parent_id, c.name_ar, ca.depth + 1, ca.path || c.name_ar
    from public.product_categories c
    join category_ancestry ca on ca.id = c.parent_id
  ),
  matched as (
    select i.category_id, i.category_name_ar_snapshot, so.id as order_id, so.sale_date, i.created_at, i.id as item_id,
      i.weight_grams, i.sale_price, i.base_cost, i.vat_cost, i.total_cost, i.gross_profit
    from public.sales_order_items i
    join public.sales_orders so on so.id = i.sales_order_id
    where i.status = 'active'
      and so.sale_date between p_date_from and p_date_to
      and so.store_id = any (v_stores)
      and (p_karat_id is null or i.karat_id = p_karat_id)
      and (p_parent_id is null or exists (select 1 from public.product_categories pc where pc.id = i.category_id and pc.parent_id = p_parent_id))
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
  -- §37: deterministic historical label -- the snapshot attached to the
  -- chronologically LATEST matched item within the period wins when a
  -- mid-period rename produced more than one snapshot label for this ID.
  label_pick as (
    select distinct on (category_id) category_id, category_name_ar_snapshot as category_label
    from matched
    order by category_id, sale_date desc, created_at desc, item_id desc
  ),
  labelled as (
    select g.*, lp.category_label, c.code as category_code,
      ca.parent_id as parent_category_id, pca.name_ar as parent_category_label,
      ca.depth as category_depth, ca.path as category_path_current
    from grouped g
    join label_pick lp on lp.category_id = g.category_id
    left join public.product_categories c on c.id = g.category_id
    left join category_ancestry ca on ca.id = g.category_id
    left join public.product_categories pca on pca.id = ca.parent_id
    where p_search is null or btrim(p_search) = '' or lp.category_label ilike '%' || btrim(p_search) || '%' or c.code ilike '%' || btrim(p_search) || '%'
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
        'parent_category_id', paged.parent_category_id, 'parent_category_label', paged.parent_category_label,
        'category_depth', paged.category_depth, 'category_path_current', to_jsonb(paged.category_path_current),
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

comment on function public.get_categories_report(date, date, uuid[], uuid, text, text, integer, integer, uuid) is
  'Phase 8 §23/§39/§45/§63; Patch 8.1 §37-38/§67 -- category ranking over sales_order_items grouped by category_id (stable identity, unchanged). Display label now comes from category_name_ar_snapshot (the item''s OWN historical snapshot, 0059) -- never the current product_categories.name_ar -- so a later master-data rename never rewrites an already-reported historical period. When a mid-period rename produced multiple snapshot labels for the same category_id, the chronologically LATEST matched item''s snapshot wins (deterministic, documented). Adds parent_category_id/parent_category_label/category_depth/category_path_current (current hierarchy navigation via product_categories.parent_id, §38 -- no new Product Master) and p_parent_id (direct-children filter). Profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_categories_report(date, date, uuid[], uuid, text, text, integer, integer, uuid) from public;
grant execute on function public.get_categories_report(date, date, uuid[], uuid, text, text, integer, integer, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- get_karats_report() (§37): same historical-snapshot fix. Karats are flat
-- (no parent_id / hierarchy in this schema) -- §38 hierarchy work does not
-- apply here.
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
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
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
    select i.karat_id, i.karat_name_ar_snapshot, i.karat_code_snapshot, so.id as order_id, so.sale_date, i.created_at, i.id as item_id,
      i.weight_grams, i.sale_price, i.base_cost, i.vat_cost, i.total_cost, i.gross_profit
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
  label_pick as (
    select distinct on (karat_id) karat_id, karat_name_ar_snapshot as karat_label, karat_code_snapshot as karat_code
    from matched
    order by karat_id, sale_date desc, created_at desc, item_id desc
  ),
  labelled as (
    select g.*, lp.karat_label, lp.karat_code
    from grouped g
    join label_pick lp on lp.karat_id = g.karat_id
    where p_search is null or btrim(p_search) = '' or lp.karat_label ilike '%' || btrim(p_search) || '%' or lp.karat_code ilike '%' || btrim(p_search) || '%'
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
  'Phase 8 §24/§39/§45/§63; Patch 8.1 §37/§67 -- karat ranking over sales_order_items grouped by karat_id (stable identity, unchanged). Display label/code now come from karat_name_ar_snapshot/karat_code_snapshot (the item''s OWN historical snapshot, 0059) -- never the current karats master row -- so a later master-data rename never rewrites an already-reported historical period. Mid-period rename tie-break identical to get_categories_report() (latest matched item''s snapshot wins). Profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_karats_report(date, date, uuid[], uuid, text, text, integer, integer) from public;
grant execute on function public.get_karats_report(date, date, uuid[], uuid, text, text, integer, integer) to authenticated;

commit;

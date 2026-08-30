-- ============================================================================
-- Phase 8 — Final Integrity Hotfix 8.1.1 — §11-14/§32-35/§60: raise
-- get_items_report()/get_adjustments_report() export row caps 500 -> 5000
-- (closing the silent-truncation blocker, §11 CRITICAL) and complete
-- get_adjustments_report()'s filter set (§32).
-- ============================================================================
-- Migrations 0001-0214 are FROZEN (never modified in place). This migration
-- only ADDS 0215+.
--
-- §11-14 CRITICAL: the export route (src/app/api/reports/export/route.ts)
-- requests up to EXPORT_MAX_ROWS=5000 rows in one call and treats
-- `envelope.total_count > 5000` as the ONLY truncation signal — but
-- get_items_report() (0201) and get_adjustments_report() (0203) still
-- internally clamp p_limit to 500 (`least(greatest(..., 1), 500)`), so a
-- report with 501-5000 matching rows silently returns only 500 of them
-- while total_count correctly reports the true (higher) count — which the
-- route DOES already catch (500 < total_count <= 5000 is NOT > 5000, so no
-- error is raised, and the file is built from only 500 rows). Every other
-- report RPC touched in Patch 8.1 already had its cap raised to 5000
-- (0206/0207/0208/0209/0210/0211/0212) for exactly this reason; these two
-- were missed. Fixed here by CREATE OR REPLACE (identical signatures, cap
-- raise is a body-only change — no DROP needed, §0).
--
-- §32 CRITICAL: get_adjustments_report()'s filter set was still limited to
-- date/store/adjustment_type/search — far short of what Adjustments'
-- Actions layer and sales_order_adjustments' own columns already support.
-- This migration DROPs + CREATEs (new appended params change the function's
-- identity, §0) to add the full required set, every one reading a REAL
-- column already present on sales_order_adjustments (confirmed via schema
-- read — payment_method_id, collection_channel_id, participates_in_settlement,
-- created_by, approved_by all already exist, 0135):
--   - p_original_sale_store_id: filters against so.store_id (the SALE's own
--     store — independent of p_store_ids' visibility scope and independent
--     of p_processing_store_id, §33 dual-store semantics — never an
--     OR-visibility merge of the two).
--   - p_processing_store_id: filters against a.processing_store_id.
--   - p_payment_method_id / p_collection_channel_id: the adjustment's OWN
--     payment_method_id/collection_channel_id (a service/adjustment can
--     carry its own payment/channel independent of the original sale).
--   - p_participates_in_settlement: a real typed boolean end-to-end (§34) —
--     matches a.participates_in_settlement exactly, including the false
--     case (a plain `is null or =` predicate handles false correctly; the
--     bug §34 warns about lives in the TS/URL layer, fixed separately in
--     url.ts/report-registry.ts/route.ts of this same delivery).
--   - p_movement_type: the ledger's own movement/effective status
--     ('approved' | 'reversed') — this report is a MOVEMENTS LEDGER (§83),
--     not a row-per-adjustment listing, so "status" here is which kind of
--     movement a row represents (mirrors Returns' analogous distinction
--     between a movement's own type and the parent record's current status).
--   - p_created_by / p_approved_by (optional): sales_order_adjustments' own
--     audit columns, applied to BOTH movement branches via the adjustment
--     row `a` (an approval movement and its reversal movement share the
--     same parent adjustment's created_by/approved_by).
--
-- §35: cap raised to 5000 here as well, and every new filter above works
-- identically through the Full Export path (the export route already
-- forwards every `extraFilterKeys` entry verbatim — no export-specific
-- code path exists to fall out of sync, §39 Single Reporting Engine).
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- get_items_report() (§11-14/§60): identical signature, cap raise only.
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
  'Phase 8 §22/§39/§45/§63; Hotfix 8.1.1 §11-14/§60 -- item-identity ranking (grouped by category+karat+sku/name over sales_order_items). Export row cap raised 500->5000 (closes the silent-truncation blocker: EXPORT_MAX_ROWS=5000 now matches this RPC''s own v_limit ceiling). Item-level profit fields require sales.view_profit. Requires reports.view + sales.view. SECURITY DEFINER.';

revoke execute on function public.get_items_report(date, date, uuid[], uuid, uuid, text, text, integer, integer) from public;
grant execute on function public.get_items_report(date, date, uuid[], uuid, uuid, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_adjustments_report() (§32-35/§60): signature changes (new filters) --
-- DROP old exact signature + CREATE, per §0.
-- ---------------------------------------------------------------------------
drop function if exists public.get_adjustments_report(date, date, uuid[], uuid, text, text, integer, integer);

create function public.get_adjustments_report(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_adjustment_type_id uuid default null,
  p_search text default null,
  p_sort text default 'movement_date_desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_original_sale_store_id uuid default null,
  p_processing_store_id uuid default null,
  p_payment_method_id uuid default null,
  p_collection_channel_id uuid default null,
  p_participates_in_settlement boolean default null,
  p_movement_type text default null,
  p_created_by uuid default null,
  p_approved_by uuid default null
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
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('adjustments.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير التسويات' using errcode = 'P0001';
  end if;
  if p_movement_type is not null and p_movement_type not in ('approved', 'reversed') then
    raise exception 'نوع حركة غير صالح' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  with movements as (
    -- Approval movements: adjustment_date is the movement's own business
    -- date. sales_order_adjustments' columns are immutable once approved.
    select
      a.id as adjustment_id, a.adjustment_number, a.adjustment_date as movement_date, 'approved'::text as movement_type,
      a.sales_order_id, so.order_number, so.store_id as original_sale_store_id, a.processing_store_id, s.name_ar as store_name,
      a.adjustment_type_id, a.adjustment_type_name_ar_snapshot as adjustment_type_label,
      a.payment_method_id, a.collection_channel_id, a.participates_in_settlement, a.created_by, a.approved_by,
      a.customer_charge as customer_charge_effect, a.direct_cost as direct_cost_effect,
      a.payment_fee_amount as payment_fee_effect, a.gross_adjustment_profit as gross_profit_effect,
      a.net_adjustment_profit as net_profit_effect
    from public.sales_order_adjustments a
    join public.sales_orders so on so.id = a.sales_order_id
    join public.stores s on s.id = a.processing_store_id
    where a.status = 'approved'
      and a.adjustment_date between p_date_from and p_date_to
      and a.processing_store_id = any (v_stores)
      and exists (select 1 from public.sales_orders so2 where so2.id = a.sales_order_id and so2.store_id = any (v_stores))
      and (p_adjustment_type_id is null or a.adjustment_type_id = p_adjustment_type_id)
      and (p_original_sale_store_id is null or so.store_id = p_original_sale_store_id)
      and (p_processing_store_id is null or a.processing_store_id = p_processing_store_id)
      and (p_payment_method_id is null or a.payment_method_id = p_payment_method_id)
      and (p_collection_channel_id is null or a.collection_channel_id = p_collection_channel_id)
      and (p_participates_in_settlement is null or a.participates_in_settlement = p_participates_in_settlement)
      and (p_created_by is null or a.created_by = p_created_by)
      and (p_approved_by is null or a.approved_by = p_approved_by)
      and (p_movement_type is null or p_movement_type = 'approved')
      and (p_search is null or btrim(p_search) = '' or a.adjustment_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')

    union all

    -- Reversal (undo) movements: reversal_business_date is a SEPARATE own
    -- business date (§85). sales_order_adjustment_reversals' own
    -- *_reversal_amount columns are already correctly signed net-effect
    -- amounts (verified by data inspection) -- used AS-IS, no negation.
    select
      a.id as adjustment_id, a.adjustment_number, r.reversal_business_date as movement_date, 'reversed'::text as movement_type,
      a.sales_order_id, so.order_number, so.store_id as original_sale_store_id, a.processing_store_id, s.name_ar as store_name,
      a.adjustment_type_id, a.adjustment_type_name_ar_snapshot as adjustment_type_label,
      a.payment_method_id, a.collection_channel_id, a.participates_in_settlement, a.created_by, a.approved_by,
      r.customer_charge_reversal_amount as customer_charge_effect, r.direct_cost_reversal_amount as direct_cost_effect,
      r.payment_fee_reversal_amount as payment_fee_effect, r.gross_profit_reversal_amount as gross_profit_effect,
      r.net_profit_reversal_amount as net_profit_effect
    from public.sales_order_adjustment_reversals r
    join public.sales_order_adjustments a on a.id = r.sales_order_adjustment_id
    join public.sales_orders so on so.id = a.sales_order_id
    join public.stores s on s.id = a.processing_store_id
    where r.reversal_business_date between p_date_from and p_date_to
      and a.processing_store_id = any (v_stores)
      and exists (select 1 from public.sales_orders so2 where so2.id = a.sales_order_id and so2.store_id = any (v_stores))
      and (p_adjustment_type_id is null or a.adjustment_type_id = p_adjustment_type_id)
      and (p_original_sale_store_id is null or so.store_id = p_original_sale_store_id)
      and (p_processing_store_id is null or a.processing_store_id = p_processing_store_id)
      and (p_payment_method_id is null or a.payment_method_id = p_payment_method_id)
      and (p_collection_channel_id is null or a.collection_channel_id = p_collection_channel_id)
      and (p_participates_in_settlement is null or a.participates_in_settlement = p_participates_in_settlement)
      and (p_created_by is null or a.created_by = p_created_by)
      and (p_approved_by is null or a.approved_by = p_approved_by)
      and (p_movement_type is null or p_movement_type = 'reversed')
      and (p_search is null or btrim(p_search) = '' or a.adjustment_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')
  ),
  summary as (
    select
      count(*) as movements_count,
      count(*) filter (where movement_type = 'approved') as approved_count,
      count(*) filter (where movement_type = 'reversed') as reversed_count,
      coalesce(sum(customer_charge_effect), 0) as customer_charge_effect,
      coalesce(sum(direct_cost_effect), 0) as direct_cost_effect,
      coalesce(sum(payment_fee_effect), 0) as payment_fee_effect,
      coalesce(sum(gross_profit_effect), 0) as gross_profit_effect,
      coalesce(sum(net_profit_effect), 0) as net_profit_effect
    from movements
  ),
  paged as (
    select * from movements
    order by
      case when p_sort = 'movement_date_asc' then movement_date end asc,
      movement_date desc, adjustment_number desc
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
      'customer_charge_effect', (select customer_charge_effect::text from summary)
    ) || (case when v_can_profit then jsonb_build_object(
      'direct_cost_effect', (select direct_cost_effect::text from summary),
      'payment_fee_effect', (select payment_fee_effect::text from summary),
      'gross_profit_effect', (select gross_profit_effect::text from summary),
      'net_profit_effect', (select net_profit_effect::text from summary)
    ) else '{}'::jsonb end),
    'rows', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'adjustment_id', paged.adjustment_id, 'adjustment_number', paged.adjustment_number,
        'movement_date', paged.movement_date, 'movement_type', paged.movement_type,
        'sales_order_id', paged.sales_order_id, 'order_number', paged.order_number,
        'original_sale_store_id', paged.original_sale_store_id,
        'store_id', paged.processing_store_id, 'store_name', paged.store_name,
        'adjustment_type_id', paged.adjustment_type_id, 'adjustment_type_label', paged.adjustment_type_label,
        'participates_in_settlement', paged.participates_in_settlement,
        'customer_charge_effect', paged.customer_charge_effect::text
      ) || (case when v_can_profit then jsonb_build_object(
        'direct_cost_effect', paged.direct_cost_effect::text, 'payment_fee_effect', paged.payment_fee_effect::text,
        'gross_profit_effect', paged.gross_profit_effect::text, 'net_profit_effect', paged.net_profit_effect::text
      ) else '{}'::jsonb end) order by paged.movement_date desc), '[]'::jsonb)
      from paged
    )
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.get_adjustments_report(date, date, uuid[], uuid, text, text, integer, integer, uuid, uuid, uuid, uuid, boolean, text, uuid, uuid) is
  'Phase 8 §32/§39/§45/§63/§83/§84/§85; Hotfix 8.1.1 §11-14/§32-35/§60 -- adjustments MOVEMENTS LEDGER. Export row cap raised 500->5000. Complete filter set: p_original_sale_store_id (so.store_id) / p_processing_store_id (a.processing_store_id) are INDEPENDENT filters, never OR-merged (§33); p_payment_method_id/p_collection_channel_id read the adjustment''s OWN columns; p_participates_in_settlement is a real end-to-end typed boolean (false included, §34); p_movement_type selects which ledger movement kind (approved|reversed); p_created_by/p_approved_by are optional audit filters. Dual cross-store visibility preserved (§8/§9). Financial-effect fields require sales.view_profit. Requires reports.view + adjustments.view. SECURITY DEFINER.';

revoke execute on function public.get_adjustments_report(date, date, uuid[], uuid, text, text, integer, integer, uuid, uuid, uuid, uuid, boolean, text, uuid, uuid) from public;
grant execute on function public.get_adjustments_report(date, date, uuid[], uuid, text, text, integer, integer, uuid, uuid, uuid, uuid, boolean, text, uuid, uuid) to authenticated;

commit;

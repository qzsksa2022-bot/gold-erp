-- ============================================================================
-- Phase 8 — Integrity Patch 8.1 — §26-29/§63: get_returns_report() dual basis.
-- ============================================================================
-- Migrations 0001-0207 are FROZEN (never modified in place). This migration
-- only ever ADDS 0208+. It rebuilds get_returns_report() (originally 0202)
-- via DROP FUNCTION IF EXISTS <old exact signature> + CREATE FUNCTION,
-- because the new p_basis/new filter params change the function's identity
-- (same lesson already applied in 0206/0207 for the same reason).
--
-- Problem (§26): the existing get_returns_report() only ever showed the
-- BUSINESS EFFECT movements ledger (sales_returns.approved_refund_amount at
-- return_date / -amount at reversal_business_date) labelled ambiguously as
-- "refund_effect" — never the ACTUAL REFUND LEDGER (sales_return_refund_events
-- + sales_return_refund_event_reversals), so a caller could not tell "what
-- SHOULD have been refunded" (the approval's computed target) from "what was
-- ACTUALLY paid out in cash."
--
-- Fix: expose two clearly separated, explicitly named bases behind a new
-- p_basis parameter (§39 Single Reporting Engine — one function, two
-- documented projections, never two independently-maintained formulas):
--
--   'business_effect' (default, preserves 0202's existing behaviour and
--   numbers byte-for-byte — only relabelled/annotated, never recomputed):
--     - Approval movement dated return_date; Reversal (undo) movement dated
--       its own reversal_business_date (§85 Event Date).
--     - refund_effect here means "Approved Refund TARGET Effect" — the
--       computed amount the approval/reversal implies, NEVER "Actual
--       Refunded Cash" (§29's explicit labelling requirement).
--     - Profit adjustment via the authoritative net_sales_profit_adjustment
--       column (already correct in 0202, preserved unchanged).
--
--   'actual_cash' (NEW): the real cash ledger —
--     - sales_return_refund_events: cash_effect = -event.amount, dated the
--       event's own refund_business_date.
--     - sales_return_refund_event_reversals: cash_effect = +original
--       event.amount (joined back to the immutable original event row —
--       amount is never duplicated on the reversal row per 0106's own
--       design comment), dated the reversal's own reversal_business_date.
--     - refund_method_id/name come from the EVENT's own refund_method_id —
--       never the original sale's payment method (§28's explicit warning).
--     - every event contributes its own -amount movement regardless of
--       whether it is later reversed; the reversal is a SEPARATE, separately
--       dated movement (identical convention to the business_effect basis
--       and to Adjustments/Settlements elsewhere in Phase 8) — so a
--       recorded-then-reversed refund event still shows its true history
--       instead of vanishing from the ledger.
--     - actual_cash rows/summary do NOT require sales.view_profit (matches
--       the pre-existing precedent in get_return_detail(), 0098: actual
--       refund/refund variance were never profit-gated — only
--       recovered_cost/fee_reversal/net_sales_profit_adjustment were).
--
-- §29 additions (both bases):
--   - refund_reconciliation_state exposed per row as a CURRENT OPERATIONAL
--     INDICATOR (not_applicable / pending / finalized_matched /
--     finalized_with_variance) — reusing the EXACT CASE expression already
--     established in get_return_detail() (0098) for consistency. This is
--     explicitly NOT a business event date and must never be treated as one.
--   - New filters: original sale date range (p_original_sale_date_from/to,
--     optional, against sales_orders.sale_date — separate from the
--     movement-date range), salesperson/employee (p_salesperson_id, against
--     sales_orders.salesperson_id — the same Salesperson identity
--     get_employees_report() uses, never created_by), refund method
--     (p_refund_method_id — applies to sr.payment_method_id under
--     business_effect, to e.refund_method_id under actual_cash), and
--     effective/current status (p_refund_reconciliation_state).
--
-- §60: v_limit cap raised 500 -> 5000 (matches 0206/0207's export-cap raise
-- for the same reason — full-export-dataset contract, no silent truncation).
--
-- §63 required test scenario (Return Target=50, Actual cash event=35, then
-- an actual-cash reversal) is proven in the golden-scenario test expansion
-- (§193 of the task list), not re-litigated here — this migration only
-- ships the mechanism.
-- ============================================================================
begin;

drop function if exists public.get_returns_report(date, date, uuid[], text, text, uuid, uuid, text, text, integer, integer);

create function public.get_returns_report(
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
  p_offset integer default 0,
  p_basis text default 'business_effect',
  p_refund_method_id uuid default null,
  p_salesperson_id uuid default null,
  p_original_sale_date_from date default null,
  p_original_sale_date_to date default null,
  p_refund_reconciliation_state text default null
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
  v_basis text := coalesce(p_basis, 'business_effect');
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 5000);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_result jsonb;
begin
  if v_actor is null or not public.has_permission('reports.view') or not public.has_permission('returns.view') then
    raise exception 'ليست لديك صلاحية عرض تقرير المرتجعات' using errcode = 'P0001';
  end if;
  if v_basis not in ('business_effect', 'actual_cash') then
    raise exception 'أساس تقرير غير صالح' using errcode = 'P0001';
  end if;
  perform public._report_validate_date_range(p_date_from, p_date_to);
  v_can_profit := public.has_permission('sales.view_profit');
  v_stores := public._report_resolve_store_filter(v_actor, p_store_ids);

  if v_basis = 'business_effect' then
    with movements as (
      -- Approval movements: return_date is the movement's own business date.
      select
        sr.id as return_id, sr.return_number, sr.return_date as movement_date, 'approved'::text as movement_type,
        sr.sales_order_id, so.order_number, so.sale_date as original_sale_date, so.salesperson_id,
        sr.processed_store_id, s.name_ar as store_name,
        sr.scenario, sr.status, sr.payment_method_id, pm.name_ar as payment_method_name,
        sr.collection_channel_id_snapshot as collection_channel_id, ch.name_ar as collection_channel_name,
        sr.sales_revenue_reversal_amount as revenue_effect,
        sr.gross_profit_reversal_amount as gross_profit_effect,
        sr.payment_fee_reversal_amount as payment_fee_effect,
        sr.net_sales_profit_adjustment as net_profit_effect,
        sr.approved_refund_amount as refund_effect,
        (case
          when sr.status not in ('approved', 'reversed') then 'not_applicable'
          when sr.refund_finalized_at is null then 'pending'
          when sr.refund_final_variance_reason is null then 'finalized_matched'
          else 'finalized_with_variance'
        end) as refund_reconciliation_state
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
        and (p_refund_method_id is null or sr.payment_method_id = p_refund_method_id)
        and (p_salesperson_id is null or so.salesperson_id = p_salesperson_id)
        and (p_original_sale_date_from is null or so.sale_date >= p_original_sale_date_from)
        and (p_original_sale_date_to is null or so.sale_date <= p_original_sale_date_to)
        and (p_search is null or btrim(p_search) = '' or sr.return_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')

      union all

      -- Reversal (undo) movements: reversal_business_date is a SEPARATE own
      -- business date (§85) -- the negated figures cancel the approval's
      -- financial contribution wherever the reversal itself actually lands.
      select
        sr.id as return_id, sr.return_number, sr.reversal_business_date as movement_date, 'reversed'::text as movement_type,
        sr.sales_order_id, so.order_number, so.sale_date as original_sale_date, so.salesperson_id,
        sr.processed_store_id, s.name_ar as store_name,
        sr.scenario, sr.status, sr.payment_method_id, pm.name_ar as payment_method_name,
        sr.collection_channel_id_snapshot as collection_channel_id, ch.name_ar as collection_channel_name,
        -coalesce(sr.sales_revenue_reversal_amount, 0) as revenue_effect,
        -coalesce(sr.gross_profit_reversal_amount, 0) as gross_profit_effect,
        -coalesce(sr.payment_fee_reversal_amount, 0) as payment_fee_effect,
        -coalesce(sr.net_sales_profit_adjustment, 0) as net_profit_effect,
        -coalesce(sr.approved_refund_amount, 0) as refund_effect,
        (case
          when sr.status not in ('approved', 'reversed') then 'not_applicable'
          when sr.refund_finalized_at is null then 'pending'
          when sr.refund_final_variance_reason is null then 'finalized_matched'
          else 'finalized_with_variance'
        end) as refund_reconciliation_state
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
        and (p_refund_method_id is null or sr.payment_method_id = p_refund_method_id)
        and (p_salesperson_id is null or so.salesperson_id = p_salesperson_id)
        and (p_original_sale_date_from is null or so.sale_date >= p_original_sale_date_from)
        and (p_original_sale_date_to is null or so.sale_date <= p_original_sale_date_to)
        and (p_search is null or btrim(p_search) = '' or sr.return_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')
    ),
    filtered as (
      select * from movements m
      where (p_refund_reconciliation_state is null or m.refund_reconciliation_state = p_refund_reconciliation_state)
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
      from filtered
    ),
    paged as (
      select * from filtered
      order by
        case when p_sort = 'movement_date_asc' then movement_date end asc,
        movement_date desc, return_number desc
      limit v_limit offset v_offset
    )
    select jsonb_build_object(
      'total_count', (select movements_count from summary),
      'limit', v_limit, 'offset', v_offset,
      'basis', 'business_effect',
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
          'original_sale_date', paged.original_sale_date,
          'store_id', paged.processed_store_id, 'store_name', paged.store_name,
          'scenario', paged.scenario, 'status', paged.status,
          'payment_method_name', paged.payment_method_name, 'collection_channel_name', paged.collection_channel_name,
          'refund_reconciliation_state', paged.refund_reconciliation_state,
          'refund_effect', paged.refund_effect::text
        ) || (case when v_can_profit then jsonb_build_object(
          'revenue_effect', paged.revenue_effect::text, 'gross_profit_effect', paged.gross_profit_effect::text,
          'payment_fee_effect', paged.payment_fee_effect::text, 'net_profit_effect', paged.net_profit_effect::text
        ) else '{}'::jsonb end) order by paged.movement_date desc), '[]'::jsonb)
        from paged
      )
    ) into v_result;
  else
    -- 'actual_cash' basis: the REAL cash ledger from the append-only refund
    -- event tables, never sales_returns.approved_refund_amount.
    with cash_movements as (
      select
        e.sales_return_id as return_id, sr.return_number, e.refund_business_date as movement_date,
        'actual_refund'::text as movement_type,
        sr.sales_order_id, so.order_number, so.sale_date as original_sale_date, so.salesperson_id,
        sr.processed_store_id, s.name_ar as store_name,
        sr.scenario, sr.status,
        e.refund_method_id, pm.name_ar as refund_method_name,
        (-e.amount) as cash_effect,
        (case
          when sr.status not in ('approved', 'reversed') then 'not_applicable'
          when sr.refund_finalized_at is null then 'pending'
          when sr.refund_final_variance_reason is null then 'finalized_matched'
          else 'finalized_with_variance'
        end) as refund_reconciliation_state
      from public.sales_return_refund_events e
      join public.sales_returns sr on sr.id = e.sales_return_id
      join public.sales_orders so on so.id = sr.sales_order_id
      join public.stores s on s.id = sr.processed_store_id
      join public.payment_methods pm on pm.id = e.refund_method_id
      where e.refund_business_date between p_date_from and p_date_to
        and sr.processed_store_id = any (v_stores)
        and (p_scenario is null or sr.scenario = p_scenario)
        and (p_status is null or sr.status = p_status)
        and (p_refund_method_id is null or e.refund_method_id = p_refund_method_id)
        and (p_salesperson_id is null or so.salesperson_id = p_salesperson_id)
        and (p_original_sale_date_from is null or so.sale_date >= p_original_sale_date_from)
        and (p_original_sale_date_to is null or so.sale_date <= p_original_sale_date_to)
        and (p_search is null or btrim(p_search) = '' or sr.return_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')

      union all

      select
        rev.sales_return_id as return_id, sr.return_number, rev.reversal_business_date as movement_date,
        'actual_refund_reversal'::text as movement_type,
        sr.sales_order_id, so.order_number, so.sale_date as original_sale_date, so.salesperson_id,
        sr.processed_store_id, s.name_ar as store_name,
        sr.scenario, sr.status,
        e.refund_method_id, pm.name_ar as refund_method_name,
        e.amount as cash_effect,
        (case
          when sr.status not in ('approved', 'reversed') then 'not_applicable'
          when sr.refund_finalized_at is null then 'pending'
          when sr.refund_final_variance_reason is null then 'finalized_matched'
          else 'finalized_with_variance'
        end) as refund_reconciliation_state
      from public.sales_return_refund_event_reversals rev
      join public.sales_return_refund_events e on e.id = rev.refund_event_id
      join public.sales_returns sr on sr.id = rev.sales_return_id
      join public.sales_orders so on so.id = sr.sales_order_id
      join public.stores s on s.id = sr.processed_store_id
      join public.payment_methods pm on pm.id = e.refund_method_id
      where rev.reversal_business_date between p_date_from and p_date_to
        and sr.processed_store_id = any (v_stores)
        and (p_scenario is null or sr.scenario = p_scenario)
        and (p_status is null or sr.status = p_status)
        and (p_refund_method_id is null or e.refund_method_id = p_refund_method_id)
        and (p_salesperson_id is null or so.salesperson_id = p_salesperson_id)
        and (p_original_sale_date_from is null or so.sale_date >= p_original_sale_date_from)
        and (p_original_sale_date_to is null or so.sale_date <= p_original_sale_date_to)
        and (p_search is null or btrim(p_search) = '' or sr.return_number ilike '%' || btrim(p_search) || '%' or so.order_number ilike '%' || btrim(p_search) || '%')
    ),
    filtered as (
      select * from cash_movements cm
      where (p_refund_reconciliation_state is null or cm.refund_reconciliation_state = p_refund_reconciliation_state)
    ),
    summary as (
      select
        count(*) as movements_count,
        count(*) filter (where movement_type = 'actual_refund') as refund_events_count,
        count(*) filter (where movement_type = 'actual_refund_reversal') as reversal_events_count,
        coalesce(sum(cash_effect), 0) as cash_effect
      from filtered
    ),
    paged as (
      select * from filtered
      order by
        case when p_sort = 'movement_date_asc' then movement_date end asc,
        movement_date desc, return_number desc
      limit v_limit offset v_offset
    )
    select jsonb_build_object(
      'total_count', (select movements_count from summary),
      'limit', v_limit, 'offset', v_offset,
      'basis', 'actual_cash',
      'summary', jsonb_build_object(
        'movements_count', (select movements_count from summary),
        'refund_events_count', (select refund_events_count from summary),
        'reversal_events_count', (select reversal_events_count from summary),
        'cash_effect', (select cash_effect::text from summary)
      ),
      'rows', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'return_id', paged.return_id, 'return_number', paged.return_number,
          'movement_date', paged.movement_date, 'movement_type', paged.movement_type,
          'sales_order_id', paged.sales_order_id, 'order_number', paged.order_number,
          'original_sale_date', paged.original_sale_date,
          'store_id', paged.processed_store_id, 'store_name', paged.store_name,
          'scenario', paged.scenario, 'status', paged.status,
          'refund_method_id', paged.refund_method_id, 'refund_method_name', paged.refund_method_name,
          'refund_reconciliation_state', paged.refund_reconciliation_state,
          'cash_effect', paged.cash_effect::text
        ) order by paged.movement_date desc), '[]'::jsonb)
        from paged
      )
    ) into v_result;
  end if;

  return v_result;
end;
$$;

comment on function public.get_returns_report(date, date, uuid[], text, text, uuid, uuid, text, text, integer, integer, text, uuid, uuid, date, date, text) is
  'Phase 8 Patch 8.1 §26-29/§39/§45/§63/§83/§84/§85 -- returns DUAL BASIS report. p_basis=''business_effect'' (default, byte-identical to 0202): sales_returns movements ledger (approved at return_date / reversed undo at reversal_business_date), refund_effect = "Approved Refund TARGET Effect" (never Actual Cash), profit fields require sales.view_profit. p_basis=''actual_cash'' (NEW): the REAL cash ledger from sales_return_refund_events (-amount at refund_business_date) + sales_return_refund_event_reversals (+original amount at reversal_business_date), refund method = the EVENT''s own refund_method_id (never the original sale''s payment method), no sales.view_profit required (matches get_return_detail() 0098 precedent). Both bases expose refund_reconciliation_state as a CURRENT operational indicator (never a business date). Requires reports.view + returns.view. SECURITY DEFINER.';

revoke execute on function public.get_returns_report(date, date, uuid[], text, text, uuid, uuid, text, text, integer, integer, text, uuid, uuid, date, date, text) from public;
grant execute on function public.get_returns_report(date, date, uuid[], text, text, uuid, uuid, text, text, integer, integer, text, uuid, uuid, date, date, text) to authenticated;

commit;

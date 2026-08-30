-- ============================================================================
-- 0111: Phase 4 — Final Hotfix 4.2.1 (6/7): get_sales_return(),
-- list_sales_returns() — append-only-derived totals, reference/refund
-- method snapshot, fee calculation version (Sections 4/6/13/17).
-- ============================================================================
-- Migrations 0001-0110 are unmodified. Same signatures/access model as 0104
-- — no visibility-scope or profit-gating shape change beyond what Sections
-- 6/13/17 explicitly ask for.
--
-- Section 4 — every `e.status = 'active'` computation switches to the
-- append-only-derived rule: an event counts as effective iff NO row in
-- sales_return_refund_event_reversals (0106/0107) references it. The
-- legacy status column is never read for computation again after this
-- migration (0106's backfill guarantees every historically-reversed event
-- already has exactly one reversal row, so the derived rule reproduces the
-- exact same totals for old data — see the 0111 upgrade-parity test).
--
-- Section 6/17 — refund_events gains reference and
-- refund_method_name_snapshot per event; the event's status/reversed_at/
-- reversal_business_date/reversal_reason are now DERIVED from a LEFT JOIN
-- against sales_return_refund_event_reversals, not read off the original
-- (now legacy-only) columns.
--
-- Section 13 — payment_fee_reversal_calculation_version is exposed
-- alongside the other profit-sensitive financial fields (it describes how
-- payment_fee_reversal_amount, itself profit-gated, was computed — v1 or
-- v2), satisfying "at least for audit/API": the value is also already
-- recorded on every approval's audit log entry (0109) regardless of who can
-- read this RPC.
create or replace function public.get_sales_return(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_return record;
  v_can_view_profit boolean;
  v_order_number text;
  v_original_store_id uuid;
  v_original_store_name text;
  v_sale_date date;
  v_order_net_sales_profit numeric;
  v_processed_store_name text;
  v_payment_method_name text;
  v_items jsonb;
  v_refund_events jsonb;
  v_reconciliation_history jsonb;
  v_actual_refunded_total numeric;
  v_refund_variance numeric;
  v_refund_reconciliation_state text;
  v_adjusted_order_profit numeric;
begin
  if v_actor is null or not public.has_permission('returns.view') then
    raise exception 'ليست لديك صلاحية عرض المرتجعات' using errcode = 'P0001';
  end if;

  select * into v_return from public.sales_returns sr where sr.id = p_id;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  select so.order_number, so.store_id, so.sale_date, so.net_sales_profit
  into v_order_number, v_original_store_id, v_sale_date, v_order_net_sales_profit
  from public.sales_orders so where so.id = v_return.sales_order_id;

  select st.name_ar into v_original_store_name from public.stores st where st.id = v_original_store_id;
  select st.name_ar into v_processed_store_name from public.stores st where st.id = v_return.processed_store_id;
  select pm.name_ar into v_payment_method_name from public.payment_methods pm where pm.id = v_return.payment_method_id;

  -- Section 6 — history preservation: an item shows if it is CURRENT
  -- membership (status='active') OR it was part of the final set at the
  -- moment of the decision (included_in_decision=true) — a Rejected or
  -- Reversed return never appears to have zero items. UNCHANGED from 0104.
  select coalesce(jsonb_agg(
    (
      jsonb_build_object(
        'id', sri.id, 'sales_order_item_id', sri.sales_order_item_id, 'line_no', sri.line_no,
        'status', sri.status, 'is_effective', sri.is_effective,
        'condition', sri.condition, 'item_return_reason', sri.item_return_reason, 'item_notes', sri.item_notes,
        'category_name_ar_snapshot', sri.category_name_ar_snapshot,
        'karat_code_snapshot', sri.karat_code_snapshot, 'karat_name_ar_snapshot', sri.karat_name_ar_snapshot,
        'weight_grams', sri.weight_grams_snapshot::text, 'sale_price', sri.sale_price_snapshot::text,
        'item_calculation_version_snapshot', sri.item_calculation_version_snapshot
      )
      || case when v_can_view_profit then jsonb_build_object(
        'gold_component_cost', sri.gold_component_cost_snapshot::text,
        'manufacturing_component_cost', sri.manufacturing_component_cost_snapshot::text,
        'base_cost', sri.base_cost_snapshot::text,
        'vat_cost', sri.vat_cost_snapshot::text,
        'total_cost', sri.total_cost_snapshot::text,
        'gross_profit', sri.gross_profit_snapshot::text
      ) else '{}'::jsonb end
    )
    order by sri.line_no
  ), '[]'::jsonb) into v_items
  from public.sales_return_items sri
  where sri.sales_return_id = v_return.id and (sri.status = 'active' or sri.included_in_decision = true);

  -- Hotfix 4.2.1 (Sections 4/6/17) — status/reversed_at/reversal_business_
  -- date/reversal_reason are now DERIVED via a LEFT JOIN against the real
  -- append-only reversal ledger (0106/0107), never read off the original
  -- event's own (legacy-only, frozen) status/reversed_* columns. reference
  -- and refund_method_name_snapshot (0106) are exposed per event.
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', e.id, 'amount', e.amount::text, 'refund_method_id', e.refund_method_id,
      'refund_method_name_snapshot', e.refund_method_name_snapshot, 'reference', e.reference,
      'refund_business_date', e.refund_business_date, 'refunded_at', e.refunded_at, 'notes', e.notes,
      'status', case when rev.id is not null then 'reversed' else 'active' end,
      'reversed_at', rev.reversed_at, 'reversal_business_date', rev.reversal_business_date, 'reversal_reason', rev.reversal_reason
    )
    order by e.refunded_at
  ), '[]'::jsonb) into v_refund_events
  from public.sales_return_refund_events e
  left join public.sales_return_refund_event_reversals rev on rev.refund_event_id = e.id
  where e.sales_return_id = v_return.id;

  -- Patch 4.2 (Section 4) — full reconciliation history (finalize/reopen
  -- transitions), oldest first. Not profit-gated, mirroring refund_events.
  -- UNCHANGED from 0104.
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', rce.id, 'event_type', rce.event_type,
      'actual_refunded_total', rce.actual_refunded_total::text,
      'approved_refund_amount', rce.approved_refund_amount::text,
      'variance', rce.variance::text, 'reason', rce.reason,
      'actor', rce.actor, 'created_at', rce.created_at
    )
    order by rce.created_at
  ), '[]'::jsonb) into v_reconciliation_history
  from public.sales_return_refund_reconciliation_events rce
  where rce.sales_return_id = v_return.id;

  -- Hotfix 4.2.1 (Section 4) — the fix: an event counts toward the actual
  -- total iff no row in sales_return_refund_event_reversals references it.
  select coalesce(sum(e.amount), 0.00) into v_actual_refunded_total
  from public.sales_return_refund_events e
  where e.sales_return_id = v_return.id
    and not exists (select 1 from public.sales_return_refund_event_reversals rev where rev.refund_event_id = e.id);

  v_refund_variance := coalesce(v_return.approved_refund_amount, 0) - v_actual_refunded_total;

  v_refund_reconciliation_state := case
    when v_return.status not in ('approved', 'reversed') then 'not_applicable'
    when v_return.refund_finalized_at is null then 'pending'
    when v_return.refund_final_variance_reason is null then 'finalized_matched'
    else 'finalized_with_variance'
  end;

  if v_can_view_profit then
    select v_order_net_sales_profit + coalesce(sum(sr2.net_sales_profit_adjustment), 0)
    into v_adjusted_order_profit
    from public.sales_returns sr2
    where sr2.sales_order_id = v_return.sales_order_id and sr2.status = 'approved';
  end if;

  return jsonb_build_object(
    'id', v_return.id, 'return_number', v_return.return_number,
    'sales_order_id', v_return.sales_order_id, 'order_number', v_order_number,
    'original_store_id', v_original_store_id, 'original_store_name', v_original_store_name, 'sale_date', v_sale_date,
    'processed_store_id', v_return.processed_store_id, 'store_name', v_processed_store_name,
    'return_date', v_return.return_date,
    'customer_name', v_return.customer_name_snapshot, 'customer_phone', v_return.customer_phone_snapshot,
    'scenario', v_return.scenario, 'scenario_notes', v_return.scenario_notes,
    'collection_state', v_return.collection_state,
    'status', v_return.status, 'row_version', v_return.row_version,
    'payment_method_id', v_return.payment_method_id, 'payment_method_name', v_payment_method_name,
    'source_sale_row_version', v_return.source_sale_row_version,
    'requires_sale_refresh', v_return.requires_sale_refresh,
    'approved_at', v_return.approved_at, 'approved_by', v_return.approved_by,
    'rejected_at', v_return.rejected_at, 'rejection_reason', v_return.rejection_reason,
    'reversed_at', v_return.reversed_at, 'reversal_reason', v_return.reversal_reason,
    'reversal_business_date', v_return.reversal_business_date,
    'returned_original_sale_amount', v_return.returned_original_sale_amount::text,
    'non_shipping_deduction_amount', v_return.non_shipping_deduction_amount::text,
    'deduction_reason', v_return.deduction_reason,
    'sales_revenue_reversal_amount', v_return.sales_revenue_reversal_amount::text,
    'approved_refund_amount', v_return.approved_refund_amount::text,
    'refund_difference_reason', v_return.refund_difference_reason,
    'actual_refunded_total', v_actual_refunded_total::text,
    'refund_variance', v_refund_variance::text,
    'refund_reconciliation_state', v_refund_reconciliation_state,
    'refund_finalized_at', v_return.refund_finalized_at, 'refund_finalized_by', v_return.refund_finalized_by,
    'refund_final_variance_reason', v_return.refund_final_variance_reason,
    'refund_fee_policy_snapshot', v_return.refund_fee_policy_snapshot,
    'created_at', v_return.created_at, 'updated_at', v_return.updated_at,
    'items', v_items,
    'refund_events', v_refund_events,
    'reconciliation_history', v_reconciliation_history
  )
  || case when v_can_view_profit then jsonb_build_object(
    'order_subtotal_snapshot', v_return.order_subtotal_snapshot::text,
    'order_payment_fee_amount_snapshot', v_return.order_payment_fee_amount_snapshot::text,
    'recovered_original_cost_amount', v_return.recovered_original_cost_amount::text,
    'payment_fee_reversal_amount', v_return.payment_fee_reversal_amount::text,
    'payment_fee_reversal_calculation_version', v_return.payment_fee_reversal_calculation_version,
    'net_sales_profit_adjustment', v_return.net_sales_profit_adjustment::text,
    'adjusted_order_net_sales_profit', v_adjusted_order_profit::text,
    'gross_profit_reversal_amount', v_return.gross_profit_reversal_amount::text,
    'net_profit_reversal_amount', v_return.net_profit_reversal_amount::text
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.get_sales_return(uuid) is
  'Patch 4.1/4.2/Hotfix 4.2.1 (Sections 1/4/6/12/13/14/17) — items visible if status=''active'' OR included_in_decision=true. Hotfix 4.2.1: actual_refunded_total and each refund event''s status/reversed_at/reversal_business_date/reversal_reason are now DERIVED from sales_return_refund_event_reversals (0106/0107), never the legacy status column; refund_events also exposes reference/refund_method_name_snapshot (0106); payment_fee_reversal_calculation_version exposed alongside payment_fee_reversal_amount (profit-gated). Profit-sensitive keys entirely absent without sales.view_profit.';

revoke execute on function public.get_sales_return(uuid) from public;
grant execute on function public.get_sales_return(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- list_sales_returns() — actual_refunded_total/refund_variance switch to the
-- append-only-derived rule (Section 4); payment_fee_reversal_calculation_
-- version added to the row shape (Section 13, profit-gated alongside
-- payment_fee_reversal_amount). Same 11-arg signature as 0104 — column list
-- changes, so the old return-type overload must be dropped first.
-- ---------------------------------------------------------------------------
drop function if exists public.list_sales_returns(date, date, uuid, uuid, text, text, text, text, uuid, integer, integer);

create or replace function public.list_sales_returns(
  p_date_from date default null,
  p_date_to date default null,
  p_processed_store_id uuid default null,
  p_original_store_id uuid default null,
  p_return_number text default null,
  p_order_number text default null,
  p_status text default null,
  p_scenario text default null,
  p_sales_order_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid,
  return_number text,
  sales_order_id uuid,
  order_number text,
  original_store_id uuid,
  original_store_name text,
  processed_store_id uuid,
  processed_store_name text,
  sale_date date,
  return_date date,
  status text,
  scenario text,
  collection_state text,
  requires_sale_refresh boolean,
  item_count integer,
  returned_original_sale_amount text,
  non_shipping_deduction_amount text,
  sales_revenue_reversal_amount text,
  approved_refund_amount text,
  actual_refunded_total text,
  refund_variance text,
  refund_reconciliation_state text,
  recovered_original_cost_amount text,
  payment_fee_reversal_amount text,
  payment_fee_reversal_calculation_version integer,
  net_sales_profit_adjustment text,
  adjusted_order_net_sales_profit text,
  gross_profit_reversal_amount text,
  net_profit_reversal_amount text,
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
  if v_actor is null or not public.has_permission('returns.view') then
    raise exception 'ليست لديك صلاحية عرض المرتجعات' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  return query
  select
    sr.id,
    sr.return_number,
    sr.sales_order_id,
    so.order_number,
    so.store_id,
    ost.name_ar,
    sr.processed_store_id,
    pst.name_ar,
    so.sale_date,
    sr.return_date,
    sr.status,
    sr.scenario,
    sr.collection_state,
    sr.requires_sale_refresh,
    (select count(*)::integer from public.sales_return_items sri where sri.sales_return_id = sr.id and (sri.status = 'active' or sri.included_in_decision = true)),
    sr.returned_original_sale_amount::text,
    sr.non_shipping_deduction_amount::text,
    sr.sales_revenue_reversal_amount::text,
    sr.approved_refund_amount::text,
    (
      select coalesce(sum(e.amount), 0.00)::text from public.sales_return_refund_events e
      where e.sales_return_id = sr.id
        and not exists (select 1 from public.sales_return_refund_event_reversals rev where rev.refund_event_id = e.id)
    ),
    (
      coalesce(sr.approved_refund_amount, 0) - (
        select coalesce(sum(e.amount), 0.00) from public.sales_return_refund_events e
        where e.sales_return_id = sr.id
          and not exists (select 1 from public.sales_return_refund_event_reversals rev where rev.refund_event_id = e.id)
      )
    )::text,
    case
      when sr.status not in ('approved', 'reversed') then 'not_applicable'
      when sr.refund_finalized_at is null then 'pending'
      when sr.refund_final_variance_reason is null then 'finalized_matched'
      else 'finalized_with_variance'
    end,
    case when v_can_view_profit then sr.recovered_original_cost_amount::text else null end,
    case when v_can_view_profit then sr.payment_fee_reversal_amount::text else null end,
    case when v_can_view_profit then sr.payment_fee_reversal_calculation_version else null end,
    case when v_can_view_profit then sr.net_sales_profit_adjustment::text else null end,
    case when v_can_view_profit then (
      so.net_sales_profit + coalesce((
        select sum(sr2.net_sales_profit_adjustment) from public.sales_returns sr2
        where sr2.sales_order_id = so.id and sr2.status = 'approved'
      ), 0)
    )::text else null end,
    case when v_can_view_profit then sr.gross_profit_reversal_amount::text else null end,
    case when v_can_view_profit then sr.net_profit_reversal_amount::text else null end,
    sr.created_at,
    count(*) over ()::bigint
  from public.sales_returns sr
  join public.sales_orders so on so.id = sr.sales_order_id
  left join public.stores pst on pst.id = sr.processed_store_id
  left join public.stores ost on ost.id = so.store_id
  where sr.processed_store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and (p_date_from is null or sr.return_date >= p_date_from)
    and (p_date_to is null or sr.return_date <= p_date_to)
    and (p_processed_store_id is null or sr.processed_store_id = p_processed_store_id)
    and (p_original_store_id is null or so.store_id = p_original_store_id)
    and (p_return_number is null or sr.return_number ilike '%' || p_return_number || '%')
    and (p_order_number is null or so.order_number ilike '%' || p_order_number || '%')
    and (p_status is null or sr.status = p_status)
    and (p_scenario is null or sr.scenario = p_scenario)
    and (p_sales_order_id is null or sr.sales_order_id = p_sales_order_id)
  order by sr.return_date desc, sr.created_at desc
  limit v_limit offset v_offset;
end;
$$;

comment on function public.list_sales_returns(date, date, uuid, uuid, text, text, text, text, uuid, integer, integer) is
  'Patch 4.1/4.2/Hotfix 4.2.1 (Sections 1/4/13/14) — actual_refunded_total/refund_variance now derived from sales_return_refund_event_reversals (0106/0107), never the legacy status column. Adds payment_fee_reversal_calculation_version (profit-gated, alongside payment_fee_reversal_amount). item_count uses status=''active'' OR included_in_decision=true (Section 6). Scoped by processed_store_id via user_visible_store_ids().';

revoke execute on function public.list_sales_returns(date, date, uuid, uuid, text, text, text, text, uuid, integer, integer) from public;
grant execute on function public.list_sales_returns(date, date, uuid, uuid, text, text, text, text, uuid, integer, integer) to authenticated;

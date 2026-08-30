-- ============================================================================
-- 0090: Phase 4 — Returns Core (9/10): list_sales_returns(),
-- get_sales_return(), get_returnable_sales_order()
-- ============================================================================
-- Migrations 0001-0089 are unmodified. Same access-model reasoning as
-- list_sales_orders()/get_sales_order() (0079): sales_returns/
-- sales_return_items have zero direct-authenticated RLS policies (0082), so
-- these three SECURITY DEFINER RPCs are the only read path, and each
-- resolves its own labels internally (store_name, order_number, ...) so
-- returns.view alone is enough — no dependency on stores.view/sales.view
-- for basic labels. Profit-sensitive columns (gross_profit_reversal_amount,
-- net_profit_reversal_amount, and every *_snapshot cost column on an item)
-- are gated on sales.view_profit, reusing that exact permission — no new
-- returns.view_profit is introduced (matches the Phase 4 spec directly).
--
-- get_returnable_sales_order() merges what were originally planned as two
-- separate RPCs (a "get order for return" lookup and a "list returnable
-- items" lookup) into one call — every item the UI needs for the New
-- Return flow (label, snapshot cost, and a `returnable` flag) is already a
-- single query away from the order lookup itself, so serving them
-- separately would only cost the client an extra round trip for no benefit.
-- ---------------------------------------------------------------------------

drop function if exists public.list_sales_returns(date, date, uuid, text, text, uuid, integer, integer);

create or replace function public.list_sales_returns(
  p_date_from date default null,
  p_date_to date default null,
  p_processed_store_id uuid default null,
  p_return_number text default null,
  p_status text default null,
  p_sales_order_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid,
  return_number text,
  sales_order_id uuid,
  order_number text,
  processed_store_id uuid,
  store_name text,
  return_date date,
  status text,
  scenario text,
  item_count integer,
  sales_revenue_reversal_amount text,
  approved_refund_amount text,
  actual_refunded_total text,
  gross_profit_reversal_amount text,
  payment_fee_reversal_amount text,
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
    sr.processed_store_id,
    st.name_ar,
    sr.return_date,
    sr.status,
    sr.scenario,
    (select count(*)::integer from public.sales_return_items sri where sri.sales_return_id = sr.id and sri.status = 'active'),
    sr.sales_revenue_reversal_amount::text,
    sr.approved_refund_amount::text,
    (select coalesce(sum(e.amount), 0.00)::text from public.sales_return_refund_events e where e.sales_return_id = sr.id and e.status = 'active'),
    case when v_can_view_profit then sr.gross_profit_reversal_amount::text else null end,
    case when v_can_view_profit then sr.payment_fee_reversal_amount::text else null end,
    case when v_can_view_profit then sr.net_profit_reversal_amount::text else null end,
    sr.created_at,
    count(*) over ()::bigint
  from public.sales_returns sr
  join public.sales_orders so on so.id = sr.sales_order_id
  left join public.stores st on st.id = sr.processed_store_id
  where sr.processed_store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and (p_date_from is null or sr.return_date >= p_date_from)
    and (p_date_to is null or sr.return_date <= p_date_to)
    and (p_processed_store_id is null or sr.processed_store_id = p_processed_store_id)
    and (p_return_number is null or sr.return_number ilike '%' || p_return_number || '%')
    and (p_status is null or sr.status = p_status)
    and (p_sales_order_id is null or sr.sales_order_id = p_sales_order_id)
  order by sr.return_date desc, sr.created_at desc
  limit v_limit offset v_offset;
end;
$$;

comment on function public.list_sales_returns(date, date, uuid, text, text, uuid, integer, integer) is
  'Paginated Returns list, scoped by processed_store_id via user_visible_store_ids() (mirrors list_sales_orders(), 0079). item_count only counts status=''active'' items. actual_refunded_total is the live sum of active refund_events (0089) — independent from approved_refund_amount, the computed target (see design notes). Profit columns NULL without sales.view_profit.';

revoke execute on function public.list_sales_returns(date, date, uuid, text, text, uuid, integer, integer) from public;
grant execute on function public.list_sales_returns(date, date, uuid, text, text, uuid, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
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
  v_store_name text;
  v_payment_method_name text;
  v_items jsonb;
  v_refund_events jsonb;
  v_actual_refunded_total numeric;
begin
  if v_actor is null or not public.has_permission('returns.view') then
    raise exception 'ليست لديك صلاحية عرض المرتجعات' using errcode = 'P0001';
  end if;

  select * into v_return from public.sales_returns sr where sr.id = p_id;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  select so.order_number into v_order_number from public.sales_orders so where so.id = v_return.sales_order_id;
  select st.name_ar into v_store_name from public.stores st where st.id = v_return.processed_store_id;
  select pm.name_ar into v_payment_method_name from public.payment_methods pm where pm.id = v_return.payment_method_id;

  select coalesce(jsonb_agg(
    (
      jsonb_build_object(
        'id', sri.id, 'sales_order_item_id', sri.sales_order_item_id, 'line_no', sri.line_no,
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
  where sri.sales_return_id = v_return.id and sri.status = 'active';

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', e.id, 'amount', e.amount::text, 'refund_method_id', e.refund_method_id,
      'refunded_at', e.refunded_at, 'notes', e.notes, 'status', e.status,
      'reversed_at', e.reversed_at, 'reversal_reason', e.reversal_reason
    )
    order by e.refunded_at
  ), '[]'::jsonb) into v_refund_events
  from public.sales_return_refund_events e
  where e.sales_return_id = v_return.id;

  select coalesce(sum(e.amount), 0.00) into v_actual_refunded_total
  from public.sales_return_refund_events e
  where e.sales_return_id = v_return.id and e.status = 'active';

  return jsonb_build_object(
    'id', v_return.id, 'return_number', v_return.return_number,
    'sales_order_id', v_return.sales_order_id, 'order_number', v_order_number,
    'processed_store_id', v_return.processed_store_id, 'store_name', v_store_name,
    'return_date', v_return.return_date,
    'customer_name', v_return.customer_name_snapshot, 'customer_phone', v_return.customer_phone_snapshot,
    'scenario', v_return.scenario, 'scenario_notes', v_return.scenario_notes,
    'status', v_return.status, 'row_version', v_return.row_version,
    'payment_method_id', v_return.payment_method_id, 'payment_method_name', v_payment_method_name,
    'approved_at', v_return.approved_at, 'approved_by', v_return.approved_by,
    'rejected_at', v_return.rejected_at, 'rejection_reason', v_return.rejection_reason,
    'reversed_at', v_return.reversed_at, 'reversal_reason', v_return.reversal_reason,
    'sales_revenue_reversal_amount', v_return.sales_revenue_reversal_amount::text,
    'approved_refund_amount', v_return.approved_refund_amount::text,
    'actual_refunded_total', v_actual_refunded_total::text,
    'refund_variance', (coalesce(v_return.approved_refund_amount, 0) - v_actual_refunded_total)::text,
    'refund_fee_policy_snapshot', v_return.refund_fee_policy_snapshot,
    'created_at', v_return.created_at, 'updated_at', v_return.updated_at,
    'items', v_items,
    'refund_events', v_refund_events
  )
  || case when v_can_view_profit then jsonb_build_object(
    'order_subtotal_snapshot', v_return.order_subtotal_snapshot::text,
    'order_payment_fee_amount_snapshot', v_return.order_payment_fee_amount_snapshot::text,
    'gross_profit_reversal_amount', v_return.gross_profit_reversal_amount::text,
    'payment_fee_reversal_amount', v_return.payment_fee_reversal_amount::text,
    'net_profit_reversal_amount', v_return.net_profit_reversal_amount::text
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.get_sales_return(uuid) is
  'Full detail for one Return, scoped via user_visible_store_ids() on processed_store_id. refund_variance = approved_refund_amount - actual_refunded_total (never auto-enforced to zero — a reconciliation figure, see design notes). Profit-sensitive keys entirely absent without sales.view_profit.';

revoke execute on function public.get_sales_return(uuid) from public;
grant execute on function public.get_sales_return(uuid) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.get_returnable_sales_order(p_sales_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_order record;
  v_can_view_profit boolean;
  v_store_name text;
  v_items jsonb;
  v_total_active integer;
  v_covered integer;
  v_order_state text;
  v_returns jsonb;
begin
  if v_actor is null or not public.has_permission('sales.view') or not public.has_permission('returns.create') then
    raise exception 'ليست لديك صلاحية بدء مرتجع لهذه العملية' using errcode = 'P0001';
  end if;

  select * into v_order from public.sales_orders so where so.id = p_sales_order_id;

  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  select st.name_ar into v_store_name from public.stores st where st.id = v_order.store_id;

  select coalesce(jsonb_agg(
    (
      jsonb_build_object(
        'id', soi.id, 'line_no', soi.line_no,
        'category_name_ar_snapshot', soi.category_name_ar_snapshot,
        'karat_code_snapshot', soi.karat_code_snapshot, 'karat_name_ar_snapshot', soi.karat_name_ar_snapshot,
        'weight_grams', soi.weight_grams::text, 'sale_price', soi.sale_price::text,
        'returnable', not exists (
          select 1 from public.sales_return_items sri
          where sri.sales_order_item_id = soi.id and sri.status = 'active'
        )
      )
      || case when v_can_view_profit then jsonb_build_object('gross_profit', soi.gross_profit::text) else '{}'::jsonb end
    )
    order by soi.line_no
  ), '[]'::jsonb) into v_items
  from public.sales_order_items soi
  where soi.sales_order_id = p_sales_order_id and soi.status = 'active';

  select count(*) into v_total_active from public.sales_order_items soi
  where soi.sales_order_id = p_sales_order_id and soi.status = 'active';

  select count(*) into v_covered from public.sales_order_items soi
  where soi.sales_order_id = p_sales_order_id and soi.status = 'active'
    and exists (
      select 1 from public.sales_return_items sri
      join public.sales_returns sr on sr.id = sri.sales_return_id
      where sri.sales_order_item_id = soi.id and sri.status = 'active' and sr.status = 'approved'
    );

  v_order_state := case
    when v_total_active = 0 then 'not_returned'
    when v_covered = 0 then 'not_returned'
    when v_covered >= v_total_active then 'full'
    else 'partial'
  end;

  select coalesce(jsonb_agg(
    jsonb_build_object('id', sr.id, 'return_number', sr.return_number, 'status', sr.status, 'created_at', sr.created_at)
    order by sr.created_at
  ), '[]'::jsonb) into v_returns
  from public.sales_returns sr
  where sr.sales_order_id = p_sales_order_id;

  return jsonb_build_object(
    'sales_order_id', v_order.id, 'order_number', v_order.order_number,
    'store_id', v_order.store_id, 'store_name', v_store_name,
    'sale_date', v_order.sale_date,
    'customer_name', v_order.customer_name, 'customer_phone', v_order.customer_phone,
    'payment_method_id', v_order.payment_method_id,
    -- order_state is DERIVED live from current item coverage — never a
    -- stored/cached column a client could send back stale or forged.
    'order_state', v_order_state,
    'items', v_items,
    'existing_returns', v_returns
  );
end;
$$;

comment on function public.get_returnable_sales_order(uuid) is
  'Everything the New Return flow needs for one order in a single call — order basics, every active item flagged `returnable` (not currently claimed by another active return), the DERIVED order_state (full/partial/not_returned, computed live from item coverage — never stored), and the order''s existing returns for context. Requires sales.view (to see the Sale) AND returns.create (this RPC exists specifically to start a new return). Profit-sensitive gross_profit per item gated on sales.view_profit.';

revoke execute on function public.get_returnable_sales_order(uuid) from public;
grant execute on function public.get_returnable_sales_order(uuid) to authenticated;

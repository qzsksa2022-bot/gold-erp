-- ============================================================================
-- 0142: Phase 6 — Services / Adjustments Core (10/11): read RPCs — get/list/
-- summary (§38/§39/§40)
-- ============================================================================
-- Migrations 0001-0141 are unmodified.
--
-- §29 — DB-level profit privacy: adjustments.view alone exposes adjustment
-- number, order number, service type, date, processing store,
-- customer_charge (customer-facing, NOT profit-gated — same precedent as
-- Shipping's customer_shipping_charge), payment method, collection
-- channel, settlement participation, status/effective_status, notes — but
-- NEVER direct_cost/payment_fee_amount/gross_adjustment_profit/net_
-- adjustment_profit without sales.view_profit, enforced HERE at the RPC
-- level (the base table has zero direct SELECT policy at all, 0135).
--
-- §39 — effective_status is SERVER-computed (pending|approved|rejected|
-- reversed) from the base status column plus reversal-ledger existence —
-- the client must never infer "reversed" itself.
-- ---------------------------------------------------------------------------

create or replace function public.get_sales_order_adjustment(p_id uuid)
returns table (
  id uuid,
  adjustment_number text,
  sales_order_id uuid,
  order_number text,
  adjustment_type_id uuid,
  adjustment_type_code text,
  adjustment_type_name_ar text,
  processing_store_id uuid,
  processing_store_name text,
  adjustment_date date,
  payment_method_id uuid,
  payment_method_name text,
  collection_channel_id uuid,
  collection_channel_name text,
  participates_in_settlement boolean,
  customer_charge text,
  direct_cost text,
  payment_fee_amount text,
  gross_adjustment_profit text,
  net_adjustment_profit text,
  status text,
  effective_status text,
  rejection_reason text,
  notes text,
  row_version bigint,
  reversal_business_date date,
  reversal_reason text,
  created_at timestamptz,
  approved_at timestamptz,
  rejected_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_can_view_profit boolean;
  v_row record;
  v_reversal record;
begin
  if v_actor is null or not public.has_permission('adjustments.view') then
    raise exception 'ليست لديك صلاحية عرض التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  select a.*, so.order_number, st.name_ar as store_name,
         t.code as live_type_code, t.name_ar as live_type_name_ar,
         pm.name_ar as live_payment_method_name, cc.name_ar as live_collection_channel_name
  into v_row
  from public.sales_order_adjustments a
  join public.sales_orders so on so.id = a.sales_order_id
  join public.stores st on st.id = a.processing_store_id
  join public.adjustment_types t on t.id = a.adjustment_type_id
  join public.payment_methods pm on pm.id = a.payment_method_id
  join public.collection_channels cc on cc.id = a.collection_channel_id
  where a.id = p_id;

  if v_row.id is null then
    raise exception 'التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_row.processing_store_id) then
    raise exception 'التعديل/الخدمة غير مرئي لك' using errcode = 'P0001';
  end if;

  select r.* into v_reversal from public.sales_order_adjustment_reversals r where r.sales_order_adjustment_id = p_id;

  v_can_view_profit := public.has_permission('sales.view_profit');

  id := v_row.id;
  adjustment_number := v_row.adjustment_number;
  sales_order_id := v_row.sales_order_id;
  order_number := v_row.order_number;
  adjustment_type_id := v_row.adjustment_type_id;
  adjustment_type_code := coalesce(v_row.adjustment_type_code_snapshot, v_row.live_type_code);
  adjustment_type_name_ar := coalesce(v_row.adjustment_type_name_ar_snapshot, v_row.live_type_name_ar);
  processing_store_id := v_row.processing_store_id;
  processing_store_name := v_row.store_name;
  adjustment_date := v_row.adjustment_date;
  payment_method_id := v_row.payment_method_id;
  payment_method_name := coalesce(v_row.payment_method_name_snapshot, v_row.live_payment_method_name);
  collection_channel_id := v_row.collection_channel_id;
  collection_channel_name := coalesce(v_row.collection_channel_name_snapshot, v_row.live_collection_channel_name);
  participates_in_settlement := v_row.participates_in_settlement;
  customer_charge := v_row.customer_charge::text;
  status := v_row.status;
  effective_status := case when v_row.status = 'approved' and v_reversal.id is not null then 'reversed' else v_row.status end;
  rejection_reason := v_row.rejection_reason;
  notes := v_row.notes;
  row_version := v_row.row_version;
  reversal_business_date := v_reversal.reversal_business_date;
  reversal_reason := v_reversal.reason;
  created_at := v_row.created_at;
  approved_at := v_row.approved_at;
  rejected_at := v_row.rejected_at;

  if v_can_view_profit then
    direct_cost := v_row.direct_cost::text;
    payment_fee_amount := v_row.payment_fee_amount::text;
    gross_adjustment_profit := v_row.gross_adjustment_profit::text;
    net_adjustment_profit := v_row.net_adjustment_profit::text;
  else
    direct_cost := null;
    payment_fee_amount := null;
    gross_adjustment_profit := null;
    net_adjustment_profit := null;
  end if;

  return next;
end;
$$;

comment on function public.get_sales_order_adjustment(uuid) is
  'Phase 6 (§38/§39/§29) — single-record read. customer_charge/status/effective_status/settlement participation visible to adjustments.view alone; direct_cost/payment_fee_amount/gross/net additionally require sales.view_profit. effective_status is server-computed (pending|approved|rejected|reversed) from the base status column plus reversal-ledger existence. SECURITY DEFINER.';

revoke execute on function public.get_sales_order_adjustment(uuid) from public;
grant execute on function public.get_sales_order_adjustment(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- list_sales_order_adjustments() — §38.
-- ---------------------------------------------------------------------------
create or replace function public.list_sales_order_adjustments(
  p_sales_order_id uuid default null,
  p_store_id uuid default null,
  p_status text default null,
  p_adjustment_type_id uuid default null,
  p_date_from date default null,
  p_date_to date default null,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid,
  adjustment_number text,
  sales_order_id uuid,
  order_number text,
  adjustment_type_name_ar text,
  processing_store_name text,
  adjustment_date date,
  payment_method_name text,
  customer_charge text,
  net_adjustment_profit text,
  status text,
  effective_status text,
  participates_in_settlement boolean,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_can_view_profit boolean;
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if v_actor is null or not public.has_permission('adjustments.view') then
    raise exception 'ليست لديك صلاحية عرض التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  return query
  select
    a.id, a.adjustment_number, a.sales_order_id, so.order_number,
    coalesce(a.adjustment_type_name_ar_snapshot, t.name_ar),
    st.name_ar,
    a.adjustment_date,
    coalesce(a.payment_method_name_snapshot, pm.name_ar),
    a.customer_charge::text,
    case when v_can_view_profit then a.net_adjustment_profit::text else null end,
    a.status,
    case when a.status = 'approved' and r.id is not null then 'reversed' else a.status end,
    a.participates_in_settlement,
    count(*) over ()
  from public.sales_order_adjustments a
  join public.sales_orders so on so.id = a.sales_order_id
  join public.stores st on st.id = a.processing_store_id
  join public.adjustment_types t on t.id = a.adjustment_type_id
  join public.payment_methods pm on pm.id = a.payment_method_id
  left join public.sales_order_adjustment_reversals r on r.sales_order_adjustment_id = a.id
  where a.processing_store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and (p_sales_order_id is null or a.sales_order_id = p_sales_order_id)
    and (p_store_id is null or a.processing_store_id = p_store_id)
    and (p_adjustment_type_id is null or a.adjustment_type_id = p_adjustment_type_id)
    and (p_date_from is null or a.adjustment_date >= p_date_from)
    and (p_date_to is null or a.adjustment_date <= p_date_to)
    and (
      p_status is null
      or case when a.status = 'approved' and r.id is not null then 'reversed' else a.status end = p_status
    )
    and (
      v_search is null
      or a.adjustment_number ilike '%' || v_search || '%'
      or so.order_number ilike '%' || v_search || '%'
    )
  order by a.adjustment_date desc, a.adjustment_number desc
  limit v_limit offset v_offset;
end;
$$;

comment on function public.list_sales_order_adjustments(uuid, uuid, text, uuid, date, date, text, integer, integer) is
  'Phase 6 (§38) — filterable list, scoped to processing stores visible to the actor. p_status accepts pending/approved/rejected/reversed — reversed is derived (approved + reversal exists), NOT a base status value. Money as TEXT; net_adjustment_profit requires sales.view_profit. Requires adjustments.view. SECURITY DEFINER.';

revoke execute on function public.list_sales_order_adjustments(uuid, uuid, text, uuid, date, date, text, integer, integer) from public;
grant execute on function public.list_sales_order_adjustments(uuid, uuid, text, uuid, date, date, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_sales_order_adjustment_summary() — §40. Original Invoice Amount +
-- Effective Approved Adjustments Charges = Total Including Adjustments.
-- Pending/Rejected/Reversed are ALL excluded from the effective total —
-- only status='approved' AND no reversal counts. Returns are NEVER
-- subtracted here, Shipping is NEVER added here (§2 — fully independent).
-- Gated on adjustments.view OR sales.view (design decision — this widget
-- is embedded on /sales/[id], §41, so a sales.view holder without
-- adjustments.view can still see it; it carries customer_charge only, the
-- same non-profit-sensitive figure adjustments.view alone would expose).
-- ---------------------------------------------------------------------------
create or replace function public.get_sales_order_adjustment_summary(p_order_id uuid)
returns table (
  original_invoice_amount text,
  approved_effective_adjustments_charge_total text,
  total_including_adjustments text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_order record;
  v_effective_total numeric;
begin
  if v_actor is null or not (public.has_permission('adjustments.view') or public.has_permission('sales.view')) then
    raise exception 'ليست لديك صلاحية عرض ملخص التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  select * into v_order from public.sales_orders where id = p_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير مرئية لك' using errcode = 'P0001';
  end if;

  select coalesce(sum(a.customer_charge), 0) into v_effective_total
  from public.sales_order_adjustments a
  where a.sales_order_id = p_order_id
    and a.status = 'approved'
    and not exists (select 1 from public.sales_order_adjustment_reversals r where r.sales_order_adjustment_id = a.id);

  original_invoice_amount := v_order.subtotal::text;
  approved_effective_adjustments_charge_total := v_effective_total::text;
  total_including_adjustments := (v_order.subtotal + v_effective_total)::text;
  return next;
end;
$$;

comment on function public.get_sales_order_adjustment_summary(uuid) is
  'Phase 6 (§2/§40) — Original Invoice Amount (sales_orders.subtotal, never touched) + Effective Approved (non-reversed) Adjustments Charges = Total Including Adjustments. Returns/Shipping are never part of this computation. Requires adjustments.view OR sales.view, plus order-store visibility. SECURITY DEFINER.';

revoke execute on function public.get_sales_order_adjustment_summary(uuid) from public;
grant execute on function public.get_sales_order_adjustment_summary(uuid) to authenticated;

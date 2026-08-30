-- ============================================================================
-- 0151: Phase 6 Integrity Patch 6.1 (8/13): get/list_sales_order_adjustment(s)
-- v2 — cross-store scope fix, original/effective profit split, has_direct_
-- cost + pending manage_cost exception, payment_reference, expanded filters
-- ============================================================================
-- Migrations 0001-0150 are unmodified. Return shapes change — both original
-- 0142 signatures are dropped explicitly first.
--
-- Patch 6.1 fixes bundled here:
--   item 12 — the ORIGINAL get/list only checked processing_store_id
--     visibility, never the linked Sale's OWN store. An actor who could see
--     Store B (processing) but NOT Store A (the order's original store)
--     could read/list an Adjustment on an Order they have no business
--     seeing. Both RPCs now require BOTH stores to be visible.
--   item 3 — a PENDING record's direct_cost is now visible to sales.
--     view_profit OR adjustments.manage_cost (never payment_fee_amount/
--     gross/net — those stay sales.view_profit-only, always). Once the
--     record leaves pending (approved/rejected/reversed), the exception no
--     longer applies — every profit figure reverts to sales.view_profit
--     alone. has_direct_cost is a NEW, always-visible-to-adjustments.view
--     operational boolean (never discloses the amount).
--   item 19 — original_* (the immutable approved snapshot) vs effective_*
--     (0.00 across the board once reversed, NULL while pending/rejected —
--     "not yet/never financially effective") are now DISTINCT fields, so a
--     reversed record can never be mistaken for still contributing its
--     original profit.
--   item 11/29 — payment_reference is now exposed (adjustments.view alone,
--     never a profit-gated figure).
--   item 21 — list_sales_order_adjustments() gains p_original_sale_store_id/
--     p_payment_method_id/p_collection_channel_id/p_participates_in_
--     settlement filters, plus original_sale_store_id/_name columns,
--     distinct from processing_store_id/_name.
-- ---------------------------------------------------------------------------
drop function if exists public.get_sales_order_adjustment(uuid);
drop function if exists public.list_sales_order_adjustments(uuid, uuid, text, uuid, date, date, text, integer, integer);

create or replace function public.get_sales_order_adjustment(p_id uuid)
returns table (
  id uuid,
  adjustment_number text,
  sales_order_id uuid,
  order_number text,
  original_sale_store_id uuid,
  original_sale_store_name text,
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
  payment_reference text,
  participates_in_settlement boolean,
  customer_charge text,
  has_direct_cost boolean,
  original_direct_cost text,
  original_payment_fee_amount text,
  original_gross_adjustment_profit text,
  original_net_adjustment_profit text,
  effective_customer_charge text,
  effective_direct_cost text,
  effective_payment_fee_amount text,
  effective_gross_adjustment_profit text,
  effective_net_adjustment_profit text,
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
  v_can_view_pending_cost boolean;
  v_row record;
  v_reversal record;
  v_is_reversed boolean;
begin
  if v_actor is null or not public.has_permission('adjustments.view') then
    raise exception 'ليست لديك صلاحية عرض التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  select a.*, so.order_number, so.store_id as sale_store_id, sost.name_ar as sale_store_name,
         st.name_ar as store_name,
         t.code as live_type_code, t.name_ar as live_type_name_ar,
         pm.name_ar as live_payment_method_name, cc.name_ar as live_collection_channel_name
  into v_row
  from public.sales_order_adjustments a
  join public.sales_orders so on so.id = a.sales_order_id
  join public.stores sost on sost.id = so.store_id
  join public.stores st on st.id = a.processing_store_id
  join public.adjustment_types t on t.id = a.adjustment_type_id
  left join public.payment_methods pm on pm.id = a.payment_method_id
  left join public.collection_channels cc on cc.id = a.collection_channel_id
  where a.id = p_id;

  if v_row.id is null then
    raise exception 'التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;

  -- item 12 — BOTH the linked Sale's own store AND the processing store
  -- must be visible.
  if not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_row.sale_store_id) then
    raise exception 'التعديل/الخدمة غير مرئي لك' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_row.processing_store_id) then
    raise exception 'التعديل/الخدمة غير مرئي لك' using errcode = 'P0001';
  end if;

  select r.* into v_reversal from public.sales_order_adjustment_reversals r where r.sales_order_adjustment_id = p_id;

  v_can_view_profit := public.has_permission('sales.view_profit');
  -- item 3 — pending direct_cost exception: manage_cost holders need to see
  -- the current value to manage it, even without sales.view_profit. Never
  -- extends to payment_fee/gross/net, and never applies once the record
  -- leaves pending.
  v_can_view_pending_cost := v_row.status = 'pending' and public.has_permission('adjustments.manage_cost');
  v_is_reversed := v_row.status = 'approved' and v_reversal.id is not null;

  id := v_row.id;
  adjustment_number := v_row.adjustment_number;
  sales_order_id := v_row.sales_order_id;
  order_number := v_row.order_number;
  original_sale_store_id := v_row.sale_store_id;
  original_sale_store_name := v_row.sale_store_name;
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
  payment_reference := v_row.payment_reference;
  participates_in_settlement := v_row.participates_in_settlement;
  customer_charge := v_row.customer_charge::text;
  has_direct_cost := v_row.direct_cost is not null;
  status := v_row.status;
  effective_status := case when v_is_reversed then 'reversed' else v_row.status end;
  rejection_reason := v_row.rejection_reason;
  notes := v_row.notes;
  row_version := v_row.row_version;
  reversal_business_date := v_reversal.reversal_business_date;
  reversal_reason := v_reversal.reason;
  created_at := v_row.created_at;
  approved_at := v_row.approved_at;
  rejected_at := v_row.rejected_at;

  if v_can_view_profit then
    original_direct_cost := v_row.direct_cost::text;
    original_payment_fee_amount := v_row.payment_fee_amount::text;
    original_gross_adjustment_profit := v_row.gross_adjustment_profit::text;
    original_net_adjustment_profit := v_row.net_adjustment_profit::text;
  elsif v_can_view_pending_cost then
    original_direct_cost := v_row.direct_cost::text;
    original_payment_fee_amount := null;
    original_gross_adjustment_profit := null;
    original_net_adjustment_profit := null;
  else
    original_direct_cost := null;
    original_payment_fee_amount := null;
    original_gross_adjustment_profit := null;
    original_net_adjustment_profit := null;
  end if;

  -- item 19 — "Current Effective" figures: reversed => 0.00 across the
  -- board; approved & not reversed => the original snapshot; pending/
  -- rejected => NULL (never financially effective, nothing to report).
  -- customer_charge is NOT profit-gated (mirrors the bare field above).
  effective_customer_charge := case
    when v_is_reversed then '0.00'
    when v_row.status = 'approved' then v_row.customer_charge::text
    else null
  end;

  if v_can_view_profit then
    effective_direct_cost := case when v_is_reversed then '0.00' when v_row.status = 'approved' then v_row.direct_cost::text else null end;
    effective_payment_fee_amount := case when v_is_reversed then '0.00' when v_row.status = 'approved' then v_row.payment_fee_amount::text else null end;
    effective_gross_adjustment_profit := case when v_is_reversed then '0.00' when v_row.status = 'approved' then v_row.gross_adjustment_profit::text else null end;
    effective_net_adjustment_profit := case when v_is_reversed then '0.00' when v_row.status = 'approved' then v_row.net_adjustment_profit::text else null end;
  else
    effective_direct_cost := null;
    effective_payment_fee_amount := null;
    effective_gross_adjustment_profit := null;
    effective_net_adjustment_profit := null;
  end if;

  return next;
end;
$$;

comment on function public.get_sales_order_adjustment(uuid) is
  'Phase 6 (§38/§39/§29) + Patch 6.1 items 3/11/12/19 — single-record read. Requires BOTH the linked Sale''s store AND the processing store to be visible (closes the cross-store leak). original_* is the immutable approved snapshot (sales.view_profit, or adjustments.manage_cost for direct_cost ONLY while pending); effective_* is the CURRENT financial effect (0.00 once reversed, NULL while pending/rejected, sales.view_profit only). has_direct_cost/payment_reference/customer_charge/participates_in_settlement stay visible to adjustments.view alone. SECURITY DEFINER.';

revoke execute on function public.get_sales_order_adjustment(uuid) from public;
grant execute on function public.get_sales_order_adjustment(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- list_sales_order_adjustments() v2 — §38, Patch 6.1 items 12/19/21.
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
  p_offset integer default 0,
  p_original_sale_store_id uuid default null,
  p_payment_method_id uuid default null,
  p_collection_channel_id uuid default null,
  p_participates_in_settlement boolean default null
)
returns table (
  id uuid,
  adjustment_number text,
  sales_order_id uuid,
  order_number text,
  original_sale_store_id uuid,
  original_sale_store_name text,
  adjustment_type_id uuid,
  adjustment_type_name_ar text,
  processing_store_id uuid,
  processing_store_name text,
  adjustment_date date,
  payment_method_id uuid,
  payment_method_name text,
  collection_channel_id uuid,
  collection_channel_name text,
  payment_reference text,
  customer_charge text,
  effective_net_adjustment_profit text,
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
    so.store_id, sost.name_ar,
    a.adjustment_type_id, coalesce(a.adjustment_type_name_ar_snapshot, t.name_ar),
    a.processing_store_id, st.name_ar,
    a.adjustment_date,
    a.payment_method_id, coalesce(a.payment_method_name_snapshot, pm.name_ar),
    a.collection_channel_id, coalesce(a.collection_channel_name_snapshot, cc.name_ar),
    a.payment_reference,
    a.customer_charge::text,
    case
      when not v_can_view_profit then null
      when a.status = 'approved' and r.id is not null then '0.00'
      when a.status = 'approved' then a.net_adjustment_profit::text
      else null
    end,
    a.status,
    case when a.status = 'approved' and r.id is not null then 'reversed' else a.status end,
    a.participates_in_settlement,
    count(*) over ()
  from public.sales_order_adjustments a
  join public.sales_orders so on so.id = a.sales_order_id
  join public.stores sost on sost.id = so.store_id
  join public.stores st on st.id = a.processing_store_id
  join public.adjustment_types t on t.id = a.adjustment_type_id
  left join public.payment_methods pm on pm.id = a.payment_method_id
  left join public.collection_channels cc on cc.id = a.collection_channel_id
  left join public.sales_order_adjustment_reversals r on r.sales_order_adjustment_id = a.id
  where a.processing_store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    -- item 12 — the linked Sale's own store must ALSO be visible.
    and so.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and (p_sales_order_id is null or a.sales_order_id = p_sales_order_id)
    and (p_store_id is null or a.processing_store_id = p_store_id)
    and (p_original_sale_store_id is null or so.store_id = p_original_sale_store_id)
    and (p_adjustment_type_id is null or a.adjustment_type_id = p_adjustment_type_id)
    and (p_payment_method_id is null or a.payment_method_id = p_payment_method_id)
    and (p_collection_channel_id is null or a.collection_channel_id = p_collection_channel_id)
    and (p_participates_in_settlement is null or a.participates_in_settlement = p_participates_in_settlement)
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

comment on function public.list_sales_order_adjustments(uuid, uuid, text, uuid, date, date, text, integer, integer, uuid, uuid, uuid, boolean) is
  'Phase 6 (§38) + Patch 6.1 items 12/19/21 — filterable list, scoped to BOTH the linked Sale''s store AND the processing store being visible to the actor (closes the cross-store leak). effective_net_adjustment_profit is 0.00 once reversed (never the stale original figure), NULL while pending/rejected/without sales.view_profit. New filters: p_original_sale_store_id/p_payment_method_id/p_collection_channel_id/p_participates_in_settlement. Requires adjustments.view. SECURITY DEFINER.';

revoke execute on function public.list_sales_order_adjustments(uuid, uuid, text, uuid, date, date, text, integer, integer, uuid, uuid, uuid, boolean) from public;
grant execute on function public.list_sales_order_adjustments(uuid, uuid, text, uuid, date, date, text, integer, integer, uuid, uuid, uuid, boolean) to authenticated;

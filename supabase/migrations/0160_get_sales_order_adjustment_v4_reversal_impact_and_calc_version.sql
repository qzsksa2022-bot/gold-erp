-- ============================================================================
-- 0160: Phase 6 Final Integrity Hotfix 6.1.1 (4/6): get_sales_order_
-- adjustment() v4 — signed reversal financial impact + calculation_version
-- ============================================================================
-- Migrations 0001-0159 are unmodified. Return shape changes — the 0151
-- signature is dropped explicitly first.
--
-- Hotfix 6.1.1 item 6 — the 5 signed reversal-impact columns 0150 added to
-- sales_order_adjustment_reversals (customer_charge_reversal_amount/
-- direct_cost_reversal_amount/payment_fee_reversal_amount/gross_profit_
-- reversal_amount/net_profit_reversal_amount) were never readable through
-- ANY authorized RPC — only a direct service_role table read could see
-- them. This migration exposes them through get_sales_order_adjustment(),
-- gated behind the SAME sales.view_profit rule as every other profit
-- figure (never a separate/looser gate) — NULL entirely (not merely a
-- redacted string) when the record has no reversal, or the caller lacks
-- sales.view_profit. Money-scale-safe TEXT, exactly like every other
-- financial field this RPC already returns.
--
-- Hotfix 6.1.1 item 7 — calculation_version (0158/0159) is also exposed
-- here as plain operational metadata (never a money figure, so no TEXT-cast
-- needed) — visible to adjustments.view alone, same tier as has_direct_cost,
-- NOT gated by sales.view_profit (it discloses nothing about amounts, only
-- which engine version computed them).
-- ---------------------------------------------------------------------------
drop function if exists public.get_sales_order_adjustment(uuid);

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
  calculation_version integer,
  original_direct_cost text,
  original_payment_fee_amount text,
  original_gross_adjustment_profit text,
  original_net_adjustment_profit text,
  effective_customer_charge text,
  effective_direct_cost text,
  effective_payment_fee_amount text,
  effective_gross_adjustment_profit text,
  effective_net_adjustment_profit text,
  reversal_customer_charge_impact text,
  reversal_direct_cost_impact text,
  reversal_payment_fee_impact text,
  reversal_gross_profit_impact text,
  reversal_net_profit_impact text,
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
  calculation_version := v_row.calculation_version;
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

  -- Hotfix 6.1.1 item 6 — signed reversal financial impact, sales.
  -- view_profit gated exactly like every other profit figure. NULL when
  -- there is no reversal at all (v_reversal.id is null), regardless of
  -- permission.
  if v_can_view_profit and v_reversal.id is not null then
    reversal_customer_charge_impact := v_reversal.customer_charge_reversal_amount::text;
    reversal_direct_cost_impact := v_reversal.direct_cost_reversal_amount::text;
    reversal_payment_fee_impact := v_reversal.payment_fee_reversal_amount::text;
    reversal_gross_profit_impact := v_reversal.gross_profit_reversal_amount::text;
    reversal_net_profit_impact := v_reversal.net_profit_reversal_amount::text;
  else
    reversal_customer_charge_impact := null;
    reversal_direct_cost_impact := null;
    reversal_payment_fee_impact := null;
    reversal_gross_profit_impact := null;
    reversal_net_profit_impact := null;
  end if;

  return next;
end;
$$;

comment on function public.get_sales_order_adjustment(uuid) is
  'Phase 6 (§38/§39/§29) + Patch 6.1 items 3/11/12/19 + Hotfix 6.1.1 items 6/7 — single-record read. original_*/effective_* as before. reversal_*_impact are the 5 signed reversal-impact figures (0150), sales.view_profit-gated, NULL when no reversal exists. calculation_version is plain operational metadata (adjustments.view alone, never profit-gated — discloses no amount). SECURITY DEFINER.';

revoke execute on function public.get_sales_order_adjustment(uuid) from public;
grant execute on function public.get_sales_order_adjustment(uuid) to authenticated;

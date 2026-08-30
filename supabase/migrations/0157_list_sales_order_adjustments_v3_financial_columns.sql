-- ============================================================================
-- 0157: Phase 6 Final Integrity Hotfix 6.1.1 (1/6): list_sales_order_
-- adjustments() v3 — effective_direct_cost/effective_payment_fee_amount/
-- effective_gross_adjustment_profit columns
-- ============================================================================
-- Migrations 0001-0156 are unmodified (0144-0156 are Patch 6.1, still under
-- review but NOT edited here — this is a new, additive Schema/Read
-- enhancement, correctly starting at 0157 per the governing freeze rule).
--
-- Hotfix 6.1.1 item 5 — the original requirement for /adjustments' list view
-- was that a sales.view_profit holder sees Direct Cost/Payment Fee/Net
-- Adjustment Profit, but list_sales_order_adjustments() (0151) only ever
-- exposed effective_net_adjustment_profit. get_sales_order_adjustment()
-- already exposes the full original_*/effective_* split (0151) — this
-- migration brings list_sales_order_adjustments() up to the same effective_*
-- coverage (money-scale-safe TEXT, never numeric), so the list page can
-- finally show the full three-column profit breakdown it was always meant
-- to. original_* fields are deliberately NOT added to the list shape (the
-- list is a "current state" view; the full historical snapshot including
-- original_* stays a detail-page concern, matching get_sales_order_
-- adjustment()'s own division of labor) — effective_net_adjustment_profit
-- alone already existed for exactly this reason.
--
-- Semantics (identical to get_sales_order_adjustment()'s effective_* rules):
--   approved, not reversed => effective_* = the approved snapshot value.
--   reversed               => effective_* = 0.00 (no longer in effect).
--   pending/rejected       => effective_* = NULL (never financially
--                              effective yet/at all).
--   Every effective_* money field is NULL outright without sales.view_profit
--   (identical gating to the pre-existing effective_net_adjustment_profit).
-- ---------------------------------------------------------------------------
drop function if exists public.list_sales_order_adjustments(uuid, uuid, text, uuid, date, date, text, integer, integer, uuid, uuid, uuid, boolean);

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
  effective_direct_cost text,
  effective_payment_fee_amount text,
  effective_gross_adjustment_profit text,
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
      when a.status = 'approved' then a.direct_cost::text
      else null
    end,
    case
      when not v_can_view_profit then null
      when a.status = 'approved' and r.id is not null then '0.00'
      when a.status = 'approved' then a.payment_fee_amount::text
      else null
    end,
    case
      when not v_can_view_profit then null
      when a.status = 'approved' and r.id is not null then '0.00'
      when a.status = 'approved' then a.gross_adjustment_profit::text
      else null
    end,
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
  'Phase 6 (§38) + Patch 6.1 items 12/19/21 + Hotfix 6.1.1 item 5 — filterable list, scoped to BOTH the linked Sale''s store AND the processing store being visible to the actor. effective_direct_cost/effective_payment_fee_amount/effective_gross_adjustment_profit/effective_net_adjustment_profit are 0.00 once reversed, the approved snapshot while approved-and-not-reversed, NULL while pending/rejected/without sales.view_profit — identical semantics to get_sales_order_adjustment()''s own effective_* fields. Requires adjustments.view. SECURITY DEFINER.';

revoke execute on function public.list_sales_order_adjustments(uuid, uuid, text, uuid, date, date, text, integer, integer, uuid, uuid, uuid, boolean) from public;
grant execute on function public.list_sales_order_adjustments(uuid, uuid, text, uuid, date, date, text, integer, integer, uuid, uuid, uuid, boolean) to authenticated;

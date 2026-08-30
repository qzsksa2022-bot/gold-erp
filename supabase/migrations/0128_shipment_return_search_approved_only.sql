-- ============================================================================
-- 0128: Shipping Integrity Patch 5.1 (7/10): search_sales_returns_for_
-- shipment() only offers 'approved' returns — parity with create_shipment()
-- ============================================================================
-- Migrations 0001-0127 are unmodified.
--
-- Item 15 (lookup parity half — the RPC half was already fixed in
-- create_shipment() itself, 0125): search_sales_returns_for_shipment()
-- (0120) still listed status IN ('approved', 'reversed') as eligible
-- results for the /shipments/new Return-search step — after 0125, a
-- 'reversed' return can never actually succeed at create_shipment() time,
-- so surfacing it in the picker was a dead-end the actor would only
-- discover after selecting it and submitting. Fixed by narrowing to
-- status = 'approved' only, so nothing this lookup surfaces can ever fail
-- at submission for status reasons — the exact guarantee its own comment
-- already promised.
-- ---------------------------------------------------------------------------
create or replace function public.search_sales_returns_for_shipment(
  p_return_number text default null,
  p_sales_order_id uuid default null,
  p_limit integer default 10
)
returns table (
  id uuid,
  return_number text,
  return_date date,
  status text,
  sales_order_id uuid,
  order_number text,
  processed_store_id uuid,
  store_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_trimmed text := nullif(btrim(coalesce(p_return_number, '')), '');
begin
  if v_actor is null or not public.has_permission('shipments.create') then
    raise exception 'ليست لديك صلاحية إنشاء شحنات' using errcode = 'P0001';
  end if;

  if v_trimmed is null and p_sales_order_id is null then
    return;
  end if;

  return query
  select sr.id, sr.return_number, sr.return_date, sr.status, sr.sales_order_id, so.order_number, sr.processed_store_id, st.name_ar
  from public.sales_returns sr
  join public.sales_orders so on so.id = sr.sales_order_id
  left join public.stores st on st.id = sr.processed_store_id
  where sr.processed_store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and sr.status = 'approved'
    and (v_trimmed is null or sr.return_number ilike '%' || v_trimmed || '%')
    and (p_sales_order_id is null or sr.sales_order_id = p_sales_order_id)
  order by sr.return_date desc, sr.return_number desc
  limit v_limit;
end;
$$;

comment on function public.search_sales_returns_for_shipment(text, uuid, integer) is
  'Phase 5 (Section 38), narrowed by Patch 5.1 item 15 (0128): only status = ''approved'' is eligible — a ''reversed'' return can no longer receive a NEW shipment (create_shipment(), 0125), so it is no longer offered here either. An EXISTING historical shipment already linked to a since-reversed return is untouched and still fully readable via get_shipment()/list_shipments() — this lookup only governs what can be picked for a NEW shipment. Gated on shipments.create ONLY, scoped by user_visible_store_ids(). SECURITY DEFINER.';

revoke execute on function public.search_sales_returns_for_shipment(text, uuid, integer) from public;
grant execute on function public.search_sales_returns_for_shipment(text, uuid, integer) to authenticated;

-- ============================================================================
-- 0112: Phase 4 — Final Hotfix 4.2.1 (7/7): search_sales_orders_for_return(),
-- get_returnable_sales_order() permission relaxation (Section 15).
-- ============================================================================
-- Migrations 0001-0111 are unmodified.
--
-- The bug: the original Permission Model always treated returns.create as
-- independent — a custom role can be granted returns.create without
-- sales.view, and should still be able to run the entire New Return flow
-- (search a Sale by order number, load its returnable items, create a
-- Pending return). But the New Return flow's order-lookup step
-- (searchSalesOrdersForReturnAction(), src/features/returns/actions.ts)
-- calls list_sales_orders() (0079), which independently requires
-- sales.view — and get_returnable_sales_order() (0098) explicitly requires
-- BOTH sales.view AND returns.create. A user with returns.create but
-- without sales.view is blocked from starting a Return at all, even though
-- returns.create was always meant to be sufficient on its own. This mirrors
-- exactly the Master-Data hidden-dependency bug Patch 4.2 Section 7 already
-- fixed for stores/payment_methods (0105) — same pattern, one layer deeper,
-- now fixed for the Sale lookup itself.
--
-- Fix, in the same narrow-RPC style as 0105: a NEW, Returns-permission-only
-- Sale lookup carrying just the columns the New Return flow's search step
-- actually renders — never the full sales_orders row list_sales_orders()
-- exposes, and never a route into the Sales module itself. Profit fields
-- (net_sales_profit and friends) are not exposed here at all — they were
-- never part of this lookup's job, and remain protected by
-- sales.view_profit wherever the Sales module itself reads them.
create or replace function public.search_sales_orders_for_return(
  p_order_number text default null,
  p_limit integer default 10
)
returns table (
  id uuid,
  order_number text,
  sale_date date,
  store_id uuid,
  store_name text,
  customer_name text,
  subtotal text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 50);
  v_trimmed text := nullif(btrim(coalesce(p_order_number, '')), '');
begin
  if v_actor is null or not public.has_permission('returns.create') then
    raise exception 'ليست لديك صلاحية إنشاء مرتجعات' using errcode = 'P0001';
  end if;

  if v_trimmed is null then
    return;
  end if;

  return query
  select so.id, so.order_number, so.sale_date, so.store_id, st.name_ar, so.customer_name, so.subtotal::text
  from public.sales_orders so
  left join public.stores st on st.id = so.store_id
  where so.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and so.order_number ilike '%' || v_trimmed || '%'
  order by so.sale_date desc, so.order_number desc
  limit v_limit;
end;
$$;

comment on function public.search_sales_orders_for_return(text, integer) is
  'Hotfix 4.2.1 (Section 15) — the Returns-only Sale-search lookup for the New Return flow''s order-number search step, replacing a hidden dependency on list_sales_orders() (0079, gated on sales.view). Gated on returns.create ONLY, scoped by user_visible_store_ids(). Returns only {id, order_number, sale_date, store_id, store_name, customer_name, subtotal} — no profit fields, no other sales_orders column, no route into the Sales module. SECURITY DEFINER.';

revoke execute on function public.search_sales_orders_for_return(text, integer) from public;
grant execute on function public.search_sales_orders_for_return(text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_returnable_sales_order() — drop the sales.view requirement (Section
-- 15). Same signature/shape as 0098 — only the permission check changes.
-- Profit fields inside the response stay gated on sales.view_profit exactly
-- as before (v_can_view_profit is unrelated to sales.view/returns.create).
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
  -- Hotfix 4.2.1 (Section 15) — the fix: returns.create alone is sufficient,
  -- exactly like every other Returns-create-flow RPC (create_sales_return(),
  -- preview_sales_return(), search_sales_orders_for_return() above). The
  -- original spec never made sales.view a Returns prerequisite; this
  -- previously-undocumented AND was never intentional.
  if v_actor is null or not public.has_permission('returns.create') then
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
          where sri.sales_order_item_id = soi.id and sri.is_effective = true
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
      where sri.sales_order_item_id = soi.id and sri.is_effective = true
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
    'sale_date', v_order.sale_date, 'row_version', v_order.row_version,
    'customer_name', v_order.customer_name, 'customer_phone', v_order.customer_phone,
    'payment_method_id', v_order.payment_method_id,
    'order_state', v_order_state,
    'items', v_items,
    'existing_returns', v_returns
  );
end;
$$;

comment on function public.get_returnable_sales_order(uuid) is
  'Patch 4.1/Hotfix 4.2.1 (Sections 4/5/15) — `returnable`/order_state derive from is_effective, not mere active membership. Returns the Sale''s row_version for p_expected_sale_version. Hotfix 4.2.1: requires returns.create ONLY (sales.view is no longer a Returns prerequisite — it never should have been). Profit-sensitive gross_profit still gated on sales.view_profit.';

revoke execute on function public.get_returnable_sales_order(uuid) from public;
grant execute on function public.get_returnable_sales_order(uuid) to authenticated;

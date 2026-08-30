-- ============================================================================
-- 0137: Phase 6 — Services / Adjustments Core (5/11): narrow store/order/
-- payment/channel lookups for the Adjustments flow
-- ============================================================================
-- Migrations 0001-0136 are unmodified.
--
-- Every lookup below is gated on the SPECIFIC permission that legitimately
-- needs it — never sales.view/stores.view/payment_methods.view/collection_
-- channels.view — mirroring 0120's shipments_*_lookups() convention
-- exactly, so a role holding only adjustments.create can complete the
-- entire creation flow (including searching for and selecting a Sales
-- Order) without any extra grant. This directly satisfies §25: search_
-- sales_orders_for_adjustment() must NOT depend on sales.view.
-- ---------------------------------------------------------------------------

create or replace function public.adjustments_operable_store_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء تعديل/خدمة' using errcode = 'P0001';
  end if;

  return query
  select st.id, st.name_ar
  from public.stores st
  where st.id in (select sid from public.user_operable_store_ids(v_actor) sid)
  order by st.name_ar;
end;
$$;

comment on function public.adjustments_operable_store_lookups() is
  'Phase 6 (§23) — operable stores only, for the "Processing Store" picker on /adjustments/new (a NEW adjustment requires an operable, non-disabled store). Gated on adjustments.create alone.';

revoke execute on function public.adjustments_operable_store_lookups() from public;
grant execute on function public.adjustments_operable_store_lookups() to authenticated;

create or replace function public.adjustments_visible_store_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('adjustments.view') then
    raise exception 'ليست لديك صلاحية عرض التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  return query
  select st.id, st.name_ar
  from public.stores st
  where st.id in (select sid from public.user_visible_store_ids(v_actor) sid)
  order by st.name_ar;
end;
$$;

comment on function public.adjustments_visible_store_lookups() is
  'Phase 6 (§24) — visible stores (INCLUDING disabled ones — historical filtering must not disappear), for the /adjustments list store filter. Gated on adjustments.view alone.';

revoke execute on function public.adjustments_visible_store_lookups() from public;
grant execute on function public.adjustments_visible_store_lookups() to authenticated;

create or replace function public.adjustments_payment_method_lookups()
returns table (id uuid, key text, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء تعديل/خدمة' using errcode = 'P0001';
  end if;

  return query
  select pm.id, pm.key, pm.name_ar
  from public.payment_methods pm
  where pm.status = 'active'
  order by pm.name_ar;
end;
$$;

comment on function public.adjustments_payment_method_lookups() is
  'Phase 6 — active payment methods for the Adjustments creation flow. Gated on adjustments.create alone (NOT payment_methods.view), independent narrow lookup mirroring shipments_carrier_lookups().';

revoke execute on function public.adjustments_payment_method_lookups() from public;
grant execute on function public.adjustments_payment_method_lookups() to authenticated;

create or replace function public.adjustments_collection_channel_lookups()
returns table (id uuid, key text, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء تعديل/خدمة' using errcode = 'P0001';
  end if;

  return query
  select cc.id, cc.key, cc.name_ar
  from public.collection_channels cc
  where cc.status = 'active'
  order by cc.name_ar;
end;
$$;

comment on function public.adjustments_collection_channel_lookups() is
  'Phase 6 — active collection channels for the Adjustments creation flow. Gated on adjustments.create alone (NOT collection_channels.view).';

revoke execute on function public.adjustments_collection_channel_lookups() from public;
grant execute on function public.adjustments_collection_channel_lookups() to authenticated;

-- ---------------------------------------------------------------------------
-- search_sales_orders_for_adjustment() — §25, the critical requirement:
-- gated on adjustments.create alone, NEVER sales.view. Returns ONLY
-- sales_order_id, order_number, sale_date, store, minimal customer display
-- info, and original invoice amount as TEXT — explicitly WITHOUT profit/
-- cost/gold snapshots. Order visibility uses user_visible_store_ids()
-- (§23 — the Original Sales Order only needs to be VISIBLE, not operable).
-- ---------------------------------------------------------------------------
create or replace function public.search_sales_orders_for_adjustment(p_search text default null, p_limit integer default 10)
returns table (
  sales_order_id uuid,
  order_number text,
  sale_date date,
  store_name text,
  customer_name text,
  customer_phone text,
  original_invoice_amount text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_search text := btrim(coalesce(p_search, ''));
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 50);
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء تعديل/خدمة' using errcode = 'P0001';
  end if;

  if v_search = '' then
    return;
  end if;

  return query
  select so.id, so.order_number, so.sale_date, st.name_ar, so.customer_name, so.customer_phone, so.subtotal::text
  from public.sales_orders so
  join public.stores st on st.id = so.store_id
  where so.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and (
      so.order_number ilike '%' || v_search || '%'
      or so.customer_name ilike '%' || v_search || '%'
      or so.customer_phone ilike '%' || v_search || '%'
    )
  order by so.sale_date desc, so.order_number desc
  limit v_limit;
end;
$$;

comment on function public.search_sales_orders_for_adjustment(text, integer) is
  'Phase 6 (§25) — narrow Sales Order search for the Adjustments creation flow, gated on adjustments.create ONLY (never sales.view), so a user holding no Sales permission at all can still find and select the order a new Service/Adjustment attaches to. Returns minimal display fields plus the original invoice amount as TEXT — explicitly NO profit/cost/gold snapshot columns. Empty search short-circuits to zero rows.';

revoke execute on function public.search_sales_orders_for_adjustment(text, integer) from public;
grant execute on function public.search_sales_orders_for_adjustment(text, integer) to authenticated;

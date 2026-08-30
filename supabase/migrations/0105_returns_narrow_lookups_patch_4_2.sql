-- ============================================================================
-- 0105: Final Returns Integrity Patch 4.2 (7/7): returns_operable_store_
-- lookups(), returns_visible_store_lookups(), returns_refund_method_lookups()
-- ============================================================================
-- Migrations 0001-0104 are unmodified.
--
-- Section 7 — the same hidden Master-Data-permission dependency Sales
-- already had one layer of (list_sales_orders()/get_sales_order(), 0079,
-- resolve store/payment-method NAMES themselves so the /sales list and
-- detail pages need zero direct table access) still existed one layer
-- deeper in Returns: getReturnsFormLookups() (src/features/returns/
-- queries.ts) issued a direct `.from("payment_methods").select(...)` and
-- `.from("stores").select(...)` for the New Return / Edit / Detail forms'
-- DROPDOWN OPTIONS — gated by payment_methods_select/stores_select's own
-- RLS policies (0010/0044), which require payment_methods.view/stores.view
-- specifically. A custom role holding only returns.view/returns.create/
-- returns.record_refund (no Master Data browse permission at all) could
-- open a Return via the Returns RPCs perfectly well, yet /returns/[id]
-- would still attempt a payment_methods.view-gated query merely to populate
-- the refund-method dropdown, and /returns/new's processing-store dropdown
-- needed stores.view the same way — neither dropdown query result grants
-- browse access to the Master Data module pages themselves, but the
-- dependency was real and undocumented.
--
-- Fix: three new, narrow, Returns-permission-gated RPCs returning ONLY
-- {id, name_ar} — never the full stores/payment_methods row, never any
-- column a Returns workflow does not need. Each is gated on the SPECIFIC
-- Returns permission that actually needs it (returns.create for the
-- processing-store picker; returns.view for the wider visible-store list
-- filter; returns.record_refund for the refund-method picker) — never on
-- stores.view/payment_methods.view. Holding one of these Returns
-- permissions still grants NOTHING toward browsing the Master Data module
-- pages themselves; these RPCs expose only the two label columns Returns
-- workflows render, both already effectively public information to anyone
-- who can already see the Return record they are attached to.
create or replace function public.returns_operable_store_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('returns.create') then
    raise exception 'ليست لديك صلاحية إنشاء مرتجعات' using errcode = 'P0001';
  end if;

  return query
  select st.id, st.name_ar
  from public.stores st
  where st.id in (select sid from public.user_operable_store_ids(v_actor) sid)
  order by st.name_ar;
end;
$$;

comment on function public.returns_operable_store_lookups() is
  'Patch 4.2 (Section 7) — the OPERABLE-scope store picker for the New Return / Edit Return processing-store field. Gated on returns.create, NEVER stores.view. Returns only {id, name_ar} — no other stores column. SECURITY DEFINER.';

revoke execute on function public.returns_operable_store_lookups() from public;
grant execute on function public.returns_operable_store_lookups() to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.returns_visible_store_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('returns.view') then
    raise exception 'ليست لديك صلاحية عرض المرتجعات' using errcode = 'P0001';
  end if;

  return query
  select st.id, st.name_ar
  from public.stores st
  where st.id in (select sid from public.user_visible_store_ids(v_actor) sid)
  order by st.name_ar;
end;
$$;

comment on function public.returns_visible_store_lookups() is
  'Patch 4.2 (Section 7) — the VISIBLE-scope store picker for the /returns list filters (original store + processing store, including a store later disabled — Section 13 already reads via user_visible_store_ids()). Gated on returns.view, NEVER stores.view. Returns only {id, name_ar}. SECURITY DEFINER.';

revoke execute on function public.returns_visible_store_lookups() from public;
grant execute on function public.returns_visible_store_lookups() to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.returns_refund_method_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('returns.record_refund') then
    raise exception 'ليست لديك صلاحية تسجيل استرداد نقدي' using errcode = 'P0001';
  end if;

  return query
  select pm.id, pm.name_ar
  from public.payment_methods pm
  where pm.status = 'active'
  order by pm.sort_order;
end;
$$;

comment on function public.returns_refund_method_lookups() is
  'Patch 4.2 (Section 7) — the refund-method picker for record_sales_return_refund(). Gated on returns.record_refund, NEVER payment_methods.view. Returns only {id, name_ar} — no fee_model/refund_fee_policy/other columns, none of which the refund-recording UI needs. SECURITY DEFINER.';

revoke execute on function public.returns_refund_method_lookups() from public;
grant execute on function public.returns_refund_method_lookups() to authenticated;

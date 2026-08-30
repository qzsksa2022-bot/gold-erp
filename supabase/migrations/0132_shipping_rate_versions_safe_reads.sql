-- ============================================================================
-- 0132: Final Shipping Hotfix 5.1.1 (2/2): Safe TEXT-returning list RPCs for
-- shipping_carrier_rate_versions.base_cost / customer_return_shipping_fee_
-- versions.fee_amount, replacing the Shipping Rate Admin UI's raw NUMERIC
-- table reads
-- ============================================================================
-- Migrations 0001-0131 are unmodified.
--
-- Item 5 — src/features/shipping-rates/queries.ts (the Shipping Rate Admin
-- UI, Patch 5.1 items 19/20) read shipping_carrier_rate_versions/customer_
-- return_shipping_fee_versions directly via `.from(...).select("*")`, which
-- hands base_cost/fee_amount to the browser as a raw, unquoted NUMERIC ->
-- JS number over PostgREST's wire format -- the exact decode point this
-- project's Decimal Transport Boundary convention (see decimal.ts, and the
-- gold_price_for_karat_on_date_safe()/manufacturing_fee_for_karat_on_date_
-- safe()/payment_fee_for_method_on_date_safe() precedent, migration 0052)
-- exists to steer money values away from, in favor of a dedicated ::text
-- cast performed INSIDE Postgres before PostgREST ever serializes it. The
-- admin overview page today only ever displays these values (never re-feeds
-- them into a computation), so this was not a live precision bug -- but per
-- explicit instruction, hardened to the same _safe pattern as every other
-- money-bearing admin read in this project rather than relying on "display-
-- only, for now" staying true forever.
--
-- Two new SECURITY DEFINER RPCs, gated on shipping_rates.view (the same
-- permission the two tables' own RLS SELECT policies already require,
-- 0113/0122) -- not a widening of access, just a text-safe read path with
-- the identical row set (every non-cancelled OR cancelled version; the UI
-- resolves current/upcoming/history client-side exactly as it does today,
-- unchanged logic, only the transport format of the money column changes).
-- ---------------------------------------------------------------------------

create or replace function public.list_shipping_carrier_rate_versions_safe()
returns table (
  id uuid,
  carrier_id uuid,
  shipping_zone_id uuid,
  direction text,
  base_cost text,
  effective_from date,
  effective_to date,
  status text,
  notes text,
  created_by uuid,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.has_permission('shipping_rates.view') then
    raise exception 'ليست لديك صلاحية عرض تسعير الشحن' using errcode = 'P0001';
  end if;

  return query
  select
    v.id, v.carrier_id, v.shipping_zone_id, v.direction, v.base_cost::text,
    v.effective_from, v.effective_to, v.status, v.notes, v.created_by, v.created_at
  from public.shipping_carrier_rate_versions v
  order by v.effective_from desc;
end;
$$;

comment on function public.list_shipping_carrier_rate_versions_safe() is
  'Hotfix 5.1.1 item 5 — text-safe replacement for a raw `.from("shipping_carrier_rate_versions").select("*")` read: base_cost arrives ::text, never a raw NUMERIC->JS number over the wire. Gated on shipping_rates.view (same permission the table''s own RLS SELECT policy already requires, 0113/0122) -- returns every version (including cancelled), same as the RLS-visible row set; the Admin UI resolves current/upcoming/history itself. SECURITY DEFINER.';

revoke execute on function public.list_shipping_carrier_rate_versions_safe() from public;
grant execute on function public.list_shipping_carrier_rate_versions_safe() to authenticated;

create or replace function public.list_customer_return_shipping_fee_versions_safe()
returns table (
  id uuid,
  shipping_zone_id uuid,
  fee_amount text,
  effective_from date,
  effective_to date,
  status text,
  notes text,
  created_by uuid,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.has_permission('shipping_rates.view') then
    raise exception 'ليست لديك صلاحية عرض تسعير الشحن' using errcode = 'P0001';
  end if;

  return query
  select
    v.id, v.shipping_zone_id, v.fee_amount::text,
    v.effective_from, v.effective_to, v.status, v.notes, v.created_by, v.created_at
  from public.customer_return_shipping_fee_versions v
  order by v.effective_from desc;
end;
$$;

comment on function public.list_customer_return_shipping_fee_versions_safe() is
  'Hotfix 5.1.1 item 5 — text-safe replacement for a raw `.from("customer_return_shipping_fee_versions").select("*")` read: fee_amount arrives ::text, never a raw NUMERIC->JS number over the wire. Gated on shipping_rates.view (same permission the table''s own RLS SELECT policy already requires, 0113/0122). SECURITY DEFINER.';

revoke execute on function public.list_customer_return_shipping_fee_versions_safe() from public;
grant execute on function public.list_customer_return_shipping_fee_versions_safe() to authenticated;

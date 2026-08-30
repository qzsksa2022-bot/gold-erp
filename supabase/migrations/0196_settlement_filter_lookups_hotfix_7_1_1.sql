-- ============================================================================
-- 0196: Phase 7 — Final Integrity Hotfix 7.1.1 (5/N): settlements.view-gated
-- filter lookups for the /settlements list page (§12).
-- ============================================================================
-- Migrations 0001-0195 are FROZEN.
--
-- §12 — src/features/settlements/queries.ts's getPaymentMethodFilterLookups
-- ForSettlements()/getCollectionChannelFilterLookupsForSettlements()/
-- getShippingCarrierFilterLookupsForSettlements() (feeding list_settlement_
-- batches()'s (0191) p_payment_method_id/p_collection_channel_id/p_shipping
-- _carrier_id filters on the /settlements list page) read public.
-- payment_methods/collection_channels/shipping_carriers directly — each
-- table's OWN SELECT RLS policy applies (payment_methods.view/collection_
-- channels.view/shipping_rates.view respectively), a hidden dependency: an
-- actor holding settlements.view (sufficient for the /settlements list page
-- itself) but none of those three unrelated Domain permissions saw EMPTY
-- filter pickers, exactly mirroring the §23 bug Patch 7.1 already fixed for
-- the route-creation form (settlement_route_payment_method_lookups() et
-- al., migration 0190) — never fixed for the list-page filters themselves.
--
-- Fix: three new narrow RPCs, gated ONLY on settlements.view, minimum
-- metadata only (id + code/key + name_ar). Unlike 0190's manage_routes
-- lookups (active-only, for picking a value on a NEW route), these
-- deliberately include DISABLED/historical rows too — a list-page filter
-- must be able to find an already-finalized batch whose route snapshot
-- references a payment method/channel/carrier that has since been
-- disabled; excluding it would make that batch permanently unfilterable by
-- that criterion even though it still exists and is still readable.
-- ============================================================================
create or replace function public.settlement_filter_payment_method_lookups()
returns table (id uuid, key text, name_ar text, status text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select pm.id, pm.key, pm.name_ar, pm.status
  from public.payment_methods pm
  where public.has_permission('settlements.view')
  order by pm.name_ar;
$$;

comment on function public.settlement_filter_payment_method_lookups() is
  'Hotfix 7.1.1 (§12) — payment-method picker for the /settlements list-page filters, gated ONLY on settlements.view (never payment_methods.view — the hidden dependency queries.ts previously had by reading public.payment_methods directly). Includes disabled/historical rows so an already-finalized batch stays filterable by them.';

revoke execute on function public.settlement_filter_payment_method_lookups() from public;
grant execute on function public.settlement_filter_payment_method_lookups() to authenticated;

create or replace function public.settlement_filter_collection_channel_lookups()
returns table (id uuid, key text, name_ar text, status text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select cc.id, cc.key, cc.name_ar, cc.status
  from public.collection_channels cc
  where public.has_permission('settlements.view')
  order by cc.sort_order, cc.name_ar;
$$;

comment on function public.settlement_filter_collection_channel_lookups() is
  'Hotfix 7.1.1 (§12) — collection-channel picker for the /settlements list-page filters, gated ONLY on settlements.view (never collection_channels.view). Includes disabled/historical rows.';

revoke execute on function public.settlement_filter_collection_channel_lookups() from public;
grant execute on function public.settlement_filter_collection_channel_lookups() to authenticated;

create or replace function public.settlement_filter_carrier_lookups()
returns table (id uuid, code text, name_ar text, status text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select sc.id, sc.code, sc.name_ar, sc.status
  from public.shipping_carriers sc
  where public.has_permission('settlements.view')
  order by sc.name_ar;
$$;

comment on function public.settlement_filter_carrier_lookups() is
  'Hotfix 7.1.1 (§12) — shipping-carrier picker for the /settlements list-page filters, gated ONLY on settlements.view (never shipping_rates.view/shipping_carriers.view). Includes disabled/historical rows.';

revoke execute on function public.settlement_filter_carrier_lookups() from public;
grant execute on function public.settlement_filter_carrier_lookups() to authenticated;

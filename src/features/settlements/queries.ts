import "server-only";

import { createClient } from "@/lib/supabase/server";
import type { SettlementBatchesListFilters } from "./schema";

/**
 * Narrow ACTIVE-only route picker for /settlements/new step 1 — thin
 * wrapper over settlement_route_lookups() (migration 0169), gated on
 * settlements.create alone (never settlements.manage_routes).
 */
export async function getSettlementRouteLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_route_lookups");
  if (error) throw error;
  return data ?? [];
}

/**
 * Store picker for the create-only draft/source-discovery workflow —
 * settlement_create_store_lookups() (Patch 7.1 §24, migration 0186), gated
 * on settlements.create ALONE (never settlements.view). Returns the same
 * actor-visible store set as getSettlementStoreFilterLookups() below, just
 * under a create-gate instead of a view-gate — use this one wherever a
 * create-only actor (no settlements.view) must be able to reach the picker,
 * i.e. everywhere in the draft-editing workspace on /settlements/[id].
 */
export async function getSettlementCreateStoreLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_create_store_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Full (active + disabled) route list for the /settlements list-page filter dropdown — settlement_route_filter_lookups() (0169), gated on settlements.view alone. */
export async function getSettlementRouteFilterLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_route_filter_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Full admin listing (active + disabled) for /master-data/settlement-routes — settlement_routes_admin_list() (0169), gated on settlements.manage_routes. */
export async function getSettlementRoutesAdminList() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_routes_admin_list");
  if (error) throw error;
  return data ?? [];
}

/** Store picker scoped to the actor's own visible stores — settlement_store_filter_lookups() (0182), used to filter unsettled-source discovery on /settlements/new by store. Gated on settlements.view. */
export async function getSettlementStoreFilterLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_store_filter_lookups");
  if (error) throw error;
  return data ?? [];
}

/**
 * Paginated Settlement Batches list — thin wrapper over
 * list_settlement_batches() (migration 0182, complete filter set +
 * original/effective semantics in Patch 7.1 §25/§26, migration 0191). This
 * RPC does NOT return a total_count column (unlike every other list_*() RPC
 * in this codebase), so pagination here uses the standard "fetch one extra
 * row" technique: we ask for pageSize + 1 rows and use the presence of that
 * extra row as hasNextPage, rather than fabricating a total. The shared
 * <Pagination> component (which requires a real total) is deliberately NOT
 * used on the /settlements list page for this reason — see
 * settlement-batches-pager.tsx.
 *
 * p_has_variance is only ever sent when non-null — the RPC itself refuses
 * it outright without settlements.view_financials (§25), so callers must
 * never pass it for an actor lacking that permission (the UI never offers
 * the control in that case either — see the filters component).
 */
export async function listSettlementBatchesPage(filters: SettlementBatchesListFilters, pageSize: number) {
  const supabase = await createClient();
  const offset = (filters.page - 1) * pageSize;

  const { data, error } = await supabase.rpc("list_settlement_batches", {
    p_status: null,
    p_settlement_route_id: filters.settlement_route_id ?? null,
    p_date_from: filters.date_from ?? null,
    p_date_to: filters.date_to ?? null,
    p_search: filters.search ?? null,
    p_route_kind: filters.route_kind ?? null,
    p_payment_method_id: filters.payment_method_id ?? null,
    p_collection_channel_id: filters.collection_channel_id ?? null,
    p_shipping_carrier_id: filters.shipping_carrier_id ?? null,
    p_effective_status: filters.effective_status ? [filters.effective_status] : null,
    p_store_id: filters.store_id ?? null,
    p_has_variance: filters.has_variance ?? null,
    p_limit: pageSize + 1,
    p_offset: offset,
  });

  if (error) throw error;

  const rows = data ?? [];
  const hasNextPage = rows.length > pageSize;
  return { rows: rows.slice(0, pageSize), hasNextPage };
}

// ---------------------------------------------------------------------------
// The route-creation dialog (/master-data/settlement-routes) needs a
// payment method / collection channel / shipping carrier picker —
// settlement_route_payment_method_lookups()/settlement_route_collection_
// channel_lookups()/settlement_route_carrier_lookups() (Patch 7.1 §23,
// migration 0190) now provide exactly that, gated ONLY on settlements.
// manage_routes — replacing the direct payment_methods/collection_channels/
// shipping_carriers table reads this file used before, which depended on
// those tables' own unrelated .view permissions (the hidden dependency §23
// names).
// ---------------------------------------------------------------------------
export async function getActivePaymentMethodsForRouteForm() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_route_payment_method_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getActiveCollectionChannelsForRouteForm() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_route_collection_channel_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getActiveShippingCarriersForRouteForm() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_route_carrier_lookups");
  if (error) throw error;
  return data ?? [];
}

// ---------------------------------------------------------------------------
// list_settlement_batches()'s p_payment_method_id/p_collection_channel_id/
// p_shipping_carrier_id filters (0191) need pickers gated on settlements.
// view (the /settlements list page's own permission) — settlement_filter_
// payment_method_lookups()/settlement_filter_collection_channel_lookups()/
// settlement_filter_carrier_lookups() (Hotfix 7.1.1 §12, migration 0196)
// now provide exactly that, replacing this file's PREVIOUS direct reads of
// payment_methods/collection_channels/shipping_carriers, which depended on
// those tables' own unrelated .view permissions (payment_methods.view/
// collection_channels.view/shipping_rates.view) — an actor holding
// settlements.view but none of those three saw an EMPTY picker, the exact
// hidden dependency §12 names (the same class of bug §23/migration 0190
// already fixed for the route-CREATION form). These three RPCs
// deliberately include disabled/historical rows too, so an already-
// finalized batch stays filterable by a since-disabled method/channel/
// carrier.
// ---------------------------------------------------------------------------
export async function getPaymentMethodFilterLookupsForSettlements() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_filter_payment_method_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getCollectionChannelFilterLookupsForSettlements() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_filter_collection_channel_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getShippingCarrierFilterLookupsForSettlements() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("settlement_filter_carrier_lookups");
  if (error) throw error;
  return data ?? [];
}

/**
 * Fee-version history for one Settlement Route — list_settlement_route_fee_
 * versions_for_management() (Patch 7.1 §23, migration 0190), gated ONLY on
 * settlements.manage_routes — replaces the direct settlement_route_fee_
 * versions table read this file used before, which depended on that
 * table's own settlements.view_financials-gated RLS policy (0170, a
 * DIFFERENT permission than the one that actually governs this page — the
 * hidden dependency §23 names). Money figures now arrive as text (the RPC
 * casts them ::text), not number.
 */
export async function listSettlementRouteFeeVersions(routeId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("list_settlement_route_fee_versions_for_management", { p_settlement_route_id: routeId });
  if (error) throw error;
  return (data ?? []).filter((v) => v.status !== "cancelled");
}

/**
 * Full Settlement Batch detail — thin wrapper over get_settlement_batch()
 * (rebuilt in Patch 7.1 §6/§26, migrations 0186/0191). Throws if not found
 * (including when the actor cannot see every store a batch's lines touch —
 * §6 whole-batch fail-closed privacy). Money figures/lines/bank-movements
 * arrive null/empty without settlements.view_financials — enforced inside
 * the RPC, never re-derived here. Requires settlements.view — for a
 * settlements.create-only actor's OWN draft, use
 * getDraftSettlementBatchForEdit() below instead.
 */
export async function getSettlementBatchDetail(id: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_settlement_batch", { p_settlement_batch_id: id });
  if (error) throw error;
  const row = data?.[0];
  if (!row) throw new Error("not found");
  return row;
}

/**
 * Narrow draft-only getter — get_draft_settlement_batch_for_edit() (Patch
 * 7.1 §7, migration 0186). Requires settlements.create ALONE (never
 * settlements.view); an actor without settlements.view may reach ONLY a
 * draft they themselves created — a draft belonging to someone else, or a
 * batch that is no longer 'draft', raises the same not-found error the
 * getter itself uses (never distinguishable, never leaking existence).
 * Returns operational fields only — a draft carries no financial snapshot
 * yet, so there is nothing to redact.
 */
export async function getDraftSettlementBatchForEdit(id: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_draft_settlement_batch_for_edit", { p_id: id });
  if (error) throw error;
  const row = data?.[0];
  if (!row) throw new Error("not found");
  return row;
}

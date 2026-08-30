import "server-only";

import { createClient } from "@/lib/supabase/server";
import type { AdjustmentsListFilters } from "./schema";

/**
 * Narrow, permission-specific lookups (migrations 0136/0137) — mirror
 * shipments_*_lookups() (0120) exactly. Each RPC returns only a minimal
 * shape and checks the SPECIFIC Adjustments permission that actually needs
 * it — never sales.view/stores.view/payment_methods.view/collection_
 * channels.view (§25/§23).
 */
export async function getAdjustmentsOperableStoreLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjustments_operable_store_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getAdjustmentsVisibleStoreLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjustments_visible_store_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Active Service/Adjustment type picker for /adjustments/new — gated on adjustments.create alone. */
export async function getAdjustmentsActiveTypeLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjustments_active_type_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Active payment method picker for /adjustments/new — gated on adjustments.create alone, never payment_methods.view. */
export async function getAdjustmentsPaymentMethodLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjustments_payment_method_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Active collection channel picker for /adjustments/new — gated on adjustments.create alone, never collection_channels.view. */
export async function getAdjustmentsCollectionChannelLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjustments_collection_channel_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Full type catalog (including disabled) for /master-data/adjustment-types — gated on adjustments.manage_types. */
export async function getAdjustmentTypesAdminList() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjustment_types_admin_list");
  if (error) throw error;
  return data ?? [];
}

/**
 * Patch 6.1 item 22 (migration 0152) — VIEW-only historical filter lookups
 * for the /adjustments list page filters, gated on adjustments.view ALONE
 * (never adjustments.create like adjustments_active_type_lookups() et al.
 * above, which are the CREATE-flow, active-only pickers). These return the
 * FULL catalog (including disabled/inactive) so a view-only actor can still
 * filter by a type/payment method/channel an existing adjustment references
 * even after it was disabled.
 */
export async function getAdjustmentsFilterTypeLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjustments_filter_type_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getAdjustmentsFilterPaymentMethodLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjustments_filter_payment_method_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getAdjustmentsFilterCollectionChannelLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjustments_filter_collection_channel_lookups");
  if (error) throw error;
  return data ?? [];
}

/**
 * Sale-search step of /adjustments/new — thin wrapper over
 * search_sales_orders_for_adjustment() (migration 0137), gated on
 * adjustments.create ONLY, never sales.view (§25).
 */
export async function searchSalesOrdersForAdjustment(search: string) {
  const trimmed = search.trim();
  if (!trimmed) return [];

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("search_sales_orders_for_adjustment", {
    p_search: trimmed,
    p_limit: 10,
  });
  if (error) throw error;
  return data ?? [];
}

/**
 * Paginated Adjustments list — thin wrapper over list_sales_order_
 * adjustments() v2 (migration 0151), v3 (migration 0157, Hotfix 6.1.1 item
 * 5). effective_direct_cost/effective_payment_fee_amount/effective_gross_
 * adjustment_profit/effective_net_adjustment_profit all arrive `null`
 * already when the caller lacks sales.view_profit, or while the record is
 * pending/rejected — enforced inside the RPC, not duplicated here. Patch
 * 6.1 item 21 adds original_sale_store_id/payment_method_id/collection_
 * channel_id/participates_in_settlement filters.
 */
export async function listAdjustmentsPage(filters: AdjustmentsListFilters, pageSize: number) {
  const supabase = await createClient();
  const offset = (filters.page - 1) * pageSize;

  const { data, error } = await supabase.rpc("list_sales_order_adjustments", {
    p_sales_order_id: filters.sales_order_id ?? null,
    p_store_id: filters.store_id ?? null,
    p_status: filters.status ?? null,
    p_adjustment_type_id: filters.adjustment_type_id ?? null,
    p_date_from: filters.date_from ?? null,
    p_date_to: filters.date_to ?? null,
    p_search: filters.search ?? null,
    p_limit: pageSize,
    p_offset: offset,
    p_original_sale_store_id: filters.original_sale_store_id ?? null,
    p_payment_method_id: filters.payment_method_id ?? null,
    p_collection_channel_id: filters.collection_channel_id ?? null,
    p_participates_in_settlement: filters.participates_in_settlement ?? null,
  });

  if (error) throw error;

  const rows = data ?? [];
  const total = rows.length > 0 ? rows[0].total_count : 0;

  return { rows, total };
}

/**
 * Full Adjustment detail — thin wrapper over get_sales_order_adjustment()
 * v2 (migration 0151), v4 (migration 0160, Hotfix 6.1.1 items 6/7). Throws
 * if not found/not visible (now requires BOTH the linked Sale's own store
 * AND the processing store to be visible, item 12). Returns the original_ /
 * effective_ prefixed field split (item 19) + has_direct_cost + payment_
 * reference + calculation_version (adjustments.view alone, NOT sales.
 * view_profit-gated) + the 5 reversal_*_impact fields (sales.view_profit-
 * gated, null when there is no reversal); profit-sensitive keys are simply
 * null (not absent) without sales.view_profit (or, for original_direct_cost
 * alone while pending, without adjustments.manage_cost either — item 3) —
 * enforced inside the RPC.
 */
export async function getAdjustmentDetail(id: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_sales_order_adjustment", { p_id: id });
  if (error) throw error;
  const row = data?.[0];
  if (!row) throw new Error("not found");
  return row;
}

/**
 * Patch 6.1 item 23 (migration 0152) — narrow Pending-edit getter, gated on
 * adjustments.create ALONE (never adjustments.view). This is what /
 * adjustments/[id]/edit (and the post-create redirect target) must use
 * instead of getAdjustmentDetail() above, so a create-only actor (no
 * adjustments.view) can land on their own just-created Pending record
 * without being denied by a hidden permission dependency. Explicitly
 * pending-only — throws for an approved/rejected record (use
 * getAdjustmentDetail() there instead, which requires adjustments.view).
 */
export async function getPendingAdjustmentForEdit(id: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_pending_sales_order_adjustment_for_edit", { p_id: id });
  if (error) throw error;
  const row = data?.[0];
  if (!row) throw new Error("not found");
  return row;
}

/**
 * Original Invoice + Effective Approved Adjustments summary for a Sales
 * Order — thin wrapper over get_sales_order_adjustment_summary() (migration
 * 0142). Used both on /adjustments/[id] (via the order) and embedded on
 * /sales/[id] (§41) — gated on adjustments.view OR sales.view.
 */
export async function getAdjustmentSummaryForOrder(orderId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_sales_order_adjustment_summary", { p_order_id: orderId });
  if (error) throw error;
  return data?.[0] ?? null;
}

/** List of adjustments for a specific Sales Order (embedded on /sales/[id]) — thin wrapper over list_sales_order_adjustments() filtered by p_sales_order_id. */
export async function listAdjustmentsForOrder(orderId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("list_sales_order_adjustments", {
    p_sales_order_id: orderId,
    p_store_id: null,
    p_status: null,
    p_adjustment_type_id: null,
    p_date_from: null,
    p_date_to: null,
    p_search: null,
    p_limit: 50,
    p_offset: 0,
  });
  if (error) throw error;
  return data ?? [];
}

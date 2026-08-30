import "server-only";

import { createClient } from "@/lib/supabase/server";
import type { ShipmentsListFilters } from "./schema";

/**
 * Narrow, permission-specific lookups (migration 0120) — mirror
 * returns_operable_store_lookups()/returns_visible_store_lookups() (0105)
 * exactly. Each RPC returns only {id, name_ar} (or the equivalent narrow
 * shape) and checks the SPECIFIC Shipping permission that actually needs
 * it — never stores.view/shipping_rates.view/sales.view.
 */
export async function getShipmentsOperableStoreLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("shipments_operable_store_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getShipmentsVisibleStoreLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("shipments_visible_store_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Active carrier picker for /shipments/new — gated on shipments.create, never shipping_rates.view. */
export async function getShipmentsCarrierLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("shipments_carrier_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Active shipping-zone picker for /shipments/new — gated on shipments.create, never shipping_rates.view. */
export async function getShipmentsZoneLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("shipments_zone_lookups");
  if (error) throw error;
  return data ?? [];
}

/**
 * Carrier picker for the /shipments LIST filter bar (Patch 5.1 item 11,
 * migration 0126) — gated on shipments.view alone, unlike
 * getShipmentsCarrierLookups() above which is shipments.create-gated for
 * the /shipments/new form. A shipments.view-only actor (no create
 * permission) must still be able to filter the list by carrier/zone.
 * Includes any disabled carrier still referenced by a visible historical
 * shipment, so an existing filter selection never silently disappears.
 */
export async function getShipmentsFilterCarrierLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("shipments_filter_carrier_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Zone picker for the /shipments LIST filter bar — see getShipmentsFilterCarrierLookups() above. Gated on shipments.view alone. */
export async function getShipmentsFilterZoneLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("shipments_filter_zone_lookups");
  if (error) throw error;
  return data ?? [];
}

/**
 * Paginated Shipments list — thin wrapper over list_shipments() (migration
 * 0119). Profit/cost columns arrive `null` already when the caller lacks
 * sales.view_profit — enforced inside the RPC, not duplicated here.
 */
export async function listShipmentsPage(filters: ShipmentsListFilters, pageSize: number) {
  const supabase = await createClient();
  const offset = (filters.page - 1) * pageSize;

  const { data, error } = await supabase.rpc("list_shipments", {
    p_date_from: filters.date_from ?? null,
    p_date_to: filters.date_to ?? null,
    p_store_id: filters.store_id ?? null,
    p_carrier_id: filters.carrier_id ?? null,
    p_shipping_zone_id: filters.shipping_zone_id ?? null,
    p_direction: filters.direction ?? null,
    p_current_status: filters.current_status ?? null,
    p_shipment_number: filters.shipment_number ?? null,
    p_tracking_number: filters.tracking_number ?? null,
    p_sales_order_id: filters.sales_order_id ?? null,
    p_sales_return_id: filters.sales_return_id ?? null,
    p_limit: pageSize,
    p_offset: offset,
    // Patch 5.1 item 12 — new trailing filters (migration 0126).
    p_order_number: filters.order_number ?? null,
    p_return_number: filters.return_number ?? null,
    p_original_sale_store_id: filters.original_sale_store_id ?? null,
    p_cod_collection_state: filters.cod_collection_state ?? null,
  });

  if (error) throw error;

  const rows = data ?? [];
  const total = rows.length > 0 ? rows[0].total_count : 0;

  return { rows, total };
}

/**
 * Full Shipment detail — thin wrapper over get_shipment() (migration 0119).
 * Throws if not found/not visible. Profit-sensitive keys are simply absent
 * (not null) in the returned object without sales.view_profit.
 */
export async function getShipmentDetail(id: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_shipment", { p_id: id });
  if (error) throw error;
  return data as Record<string, unknown>;
}

/**
 * Sale-search step of /shipments/new (outbound shipments) — thin wrapper
 * over search_sales_orders_for_shipment() (migration 0120), gated on
 * shipments.create ONLY, never sales.view.
 */
export async function searchSalesOrdersForShipment(orderNumber: string) {
  const trimmed = orderNumber.trim();
  if (!trimmed) return [];

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("search_sales_orders_for_shipment", {
    p_order_number: trimmed,
    p_limit: 10,
  });
  if (error) throw error;
  return data ?? [];
}

/**
 * Return-search step of /shipments/new (return shipments) — thin wrapper
 * over search_sales_returns_for_shipment() (migration 0120). Only
 * approved/reversed returns are eligible, matching create_shipment()'s own
 * check exactly.
 */
export async function searchSalesReturnsForShipment(params: { returnNumber?: string; salesOrderId?: string }) {
  const trimmed = params.returnNumber?.trim();
  if (!trimmed && !params.salesOrderId) return [];

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("search_sales_returns_for_shipment", {
    p_return_number: trimmed || null,
    p_sales_order_id: params.salesOrderId ?? null,
    p_limit: 10,
  });
  if (error) throw error;
  return data ?? [];
}

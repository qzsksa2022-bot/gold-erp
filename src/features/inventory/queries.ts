import "server-only";

import { createClient } from "@/lib/supabase/server";
import type { InventoryItemsListFilters, InventoryMovementsListFilters } from "./schema";

/**
 * Narrow, permission-specific lookups (migration 0229) — mirror
 * adjustments_operable_store_lookups()/adjustments_visible_store_lookups()
 * (0137) exactly. Never depend on stores.view/categories.view/karats.view —
 * only the specific Inventory permission that legitimately needs the
 * picker.
 */
export async function getInventoryOperableStoreLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("inventory_operable_store_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getInventoryVisibleStoreLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("inventory_visible_store_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Active item picker for the Receive/Adjust dialogs — gated on inventory.receive OR inventory.adjust alone, never inventory.view. */
export async function getInventoryActiveItemLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("inventory_active_item_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getInventoryCategoryLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("inventory_category_lookups");
  if (error) throw error;
  return data ?? [];
}

export async function getInventoryKaratLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("inventory_karat_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Paginated item catalog — thin wrapper over list_inventory_items() (migration 0229). */
export async function listInventoryItemsPage(filters: InventoryItemsListFilters, pageSize: number) {
  const supabase = await createClient();
  const offset = (filters.page - 1) * pageSize;

  const { data, error } = await supabase.rpc("list_inventory_items", {
    p_search: filters.search ?? null,
    p_category_id: filters.category_id ?? null,
    p_karat_id: filters.karat_id ?? null,
    p_active: filters.active ?? null,
    p_limit: pageSize,
    p_offset: offset,
  });

  if (error) throw error;

  const rows = data ?? [];
  const total = rows.length > 0 ? rows[0].total_count : 0;

  return { rows, total };
}

/** Paginated per-(item, store) stock balances — thin wrapper over list_inventory_stock_balances() (migration 0229). */
export async function listInventoryStockBalancesPage(params: { storeId?: string; itemId?: string; search?: string }, page: number, pageSize: number) {
  const supabase = await createClient();
  const offset = (page - 1) * pageSize;

  const { data, error } = await supabase.rpc("list_inventory_stock_balances", {
    p_store_id: params.storeId ?? null,
    p_item_id: params.itemId ?? null,
    p_search: params.search ?? null,
    p_limit: pageSize,
    p_offset: offset,
  });

  if (error) throw error;

  const rows = data ?? [];
  const total = rows.length > 0 ? rows[0].total_count : 0;

  return { rows, total };
}

/** Paginated movement history — thin wrapper over list_inventory_stock_movements() (migration 0229). */
export async function listInventoryStockMovementsPage(filters: InventoryMovementsListFilters, pageSize: number) {
  const supabase = await createClient();
  const offset = (filters.page - 1) * pageSize;

  const { data, error } = await supabase.rpc("list_inventory_stock_movements", {
    p_item_id: filters.item_id ?? null,
    p_store_id: filters.store_id ?? null,
    p_date_from: filters.date_from ?? null,
    p_date_to: filters.date_to ?? null,
    p_limit: pageSize,
    p_offset: offset,
  });

  if (error) throw error;

  const rows = data ?? [];
  const total = rows.length > 0 ? rows[0].total_count : 0;

  return { rows, total };
}

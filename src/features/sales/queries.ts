import "server-only";

import { createClient } from "@/lib/supabase/server";
import type { SalesListFilters } from "./schema";

/**
 * Master-data dropdowns for the fast Sales entry form (spec §22/§23) —
 * every list here is scoped by the SAME RLS/permission rules the actor
 * already has for Phase 2 Master Data (karats.view/categories.view/
 * payment_methods.view/collection_channels.view/stores.view), all of which
 * Foundation already granted to sales_employee alongside sales.create (see
 * supabase/seed.sql's Phase 2 section) — Sales does not need any new
 * master-data read permission.
 */
export async function getSalesFormLookups() {
  const supabase = await createClient();

  const [{ data: karats, error: karatsError }, { data: categories, error: categoriesError }, { data: channels, error: channelsError }, { data: paymentMethods, error: paymentMethodsError }, { data: operableStoreIds, error: storeIdsError }] =
    await Promise.all([
      supabase.rpc("active_karats"),
      supabase.rpc("active_product_categories"),
      supabase.rpc("active_collection_channels"),
      supabase.from("payment_methods").select("*").eq("status", "active").order("sort_order"),
      supabase.rpc("my_operable_store_ids"),
    ]);

  if (karatsError) throw karatsError;
  if (categoriesError) throw categoriesError;
  if (channelsError) throw channelsError;
  if (paymentMethodsError) throw paymentMethodsError;
  if (storeIdsError) throw storeIdsError;

  const ids = operableStoreIds ?? [];
  const { data: stores, error: storesError } = ids.length
    ? await supabase.from("stores").select("*").in("id", ids).order("name_ar")
    : { data: [], error: null };
  if (storesError) throw storesError;

  return {
    karats: karats ?? [],
    categories: categories ?? [],
    collectionChannels: channels ?? [],
    paymentMethods: paymentMethods ?? [],
    operableStores: stores ?? [],
  };
}

/** Every store the actor may VIEW historical Sales for (spec §14) — used for the /sales list filter, wider than operableStores above. */
export async function getVisibleStoresForSalesFilters() {
  const supabase = await createClient();
  const { data: ids, error: idsError } = await supabase.rpc("my_visible_store_ids");
  if (idsError) throw idsError;

  const list = ids ?? [];
  if (list.length === 0) return [];

  const { data: stores, error } = await supabase.from("stores").select("*").in("id", list).order("name_ar");
  if (error) throw error;
  return stores ?? [];
}

/**
 * Patch 3.1 item 12 — the Daily Close dialog must offer OPERABLE stores
 * (active stores the actor may create/edit NEW business data for), NOT the
 * wider VISIBLE scope getVisibleStoresForSalesFilters() above returns —
 * closing a day is itself a write action, and a disabled/inactive or
 * view-only store should never appear as a closeable option even though its
 * historical Sales remain visible in the /sales list filter.
 */
export async function getOperableStoresForCloseDay() {
  const supabase = await createClient();
  const { data: ids, error: idsError } = await supabase.rpc("my_operable_store_ids");
  if (idsError) throw idsError;

  const list = ids ?? [];
  if (list.length === 0) return [];

  const { data: stores, error } = await supabase.from("stores").select("*").in("id", list).order("name_ar");
  if (error) throw error;
  return stores ?? [];
}

/**
 * Patch 3.1 item 11 — scoped salesperson dropdown for the /sales filter,
 * via list_sales_salespersons() (migration 0070). Requires sales.view only;
 * deliberately never queries `profiles` directly (that would require
 * users.view, which a Sales-only actor need not hold).
 */
export async function getSalespeopleForSalesFilters() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("list_sales_salespersons");
  if (error) throw error;
  return data ?? [];
}

/**
 * Paginated Sales list (spec §16) — thin wrapper over list_sales_orders()
 * (migration 0062). Profit columns arrive `null` already when the caller
 * lacks sales.view_profit — this function does not need to (and cannot)
 * duplicate that check, it is enforced inside the RPC.
 */
export async function listSalesOrdersPage(filters: SalesListFilters, pageSize: number) {
  const supabase = await createClient();
  const offset = (filters.page - 1) * pageSize;

  const { data, error } = await supabase.rpc("list_sales_orders", {
    p_date_from: filters.date_from ?? null,
    p_date_to: filters.date_to ?? null,
    p_store_id: filters.store_id ?? null,
    p_order_number: filters.order_number ?? null,
    p_salesperson_id: filters.salesperson_id ?? null,
    p_payment_method_id: filters.payment_method_id ?? null,
    p_collection_channel_id: filters.collection_channel_id ?? null,
    p_limit: pageSize,
    p_offset: offset,
  });

  if (error) throw error;

  const rows = data ?? [];
  const total = rows.length > 0 ? rows[0].total_count : 0;

  // Patch 3.2 item 8 (migration 0079) — list_sales_orders() now resolves
  // store_name/payment_method_name/collection_channel_name itself, exactly
  // like the existing server-side salesperson_name resolution (0070), so a
  // caller with sales.view alone sees every label with no dependency on
  // stores.view/payment_methods.view/collection_channels.view. The prior
  // second-pass batched lookup against those three tables is gone; the
  // shapes below are kept identical (`{ store: { name_ar }, ... }`) so the
  // /sales list component needs no change.
  return {
    rows: rows.map((r) => ({
      ...r,
      store: r.store_name ? { name_ar: r.store_name } : null,
      paymentMethod: r.payment_method_name ? { name_ar: r.payment_method_name } : null,
      collectionChannel: r.collection_channel_name ? { name_ar: r.collection_channel_name } : null,
      salesperson: r.salesperson_name ? { full_name: r.salesperson_name } : null,
    })),
    total,
  };
}

/**
 * Full Sale detail (spec §16/§18/§22) — thin wrapper over get_sales_order()
 * (migration 0062; Patch 3.2 items 2/7/8, migration 0079). Throws if not
 * found/not visible. As of 0079 the returned object already carries
 * store_name/payment_method_name/collection_channel_name and row_version —
 * callers should read those directly instead of issuing their own
 * stores/payment_methods/collection_channels lookups.
 */
export async function getSalesOrderDetail(id: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_sales_order", { p_id: id });
  if (error) throw error;
  return data as Record<string, unknown>;
}

/**
 * Patch 3.2 item 6 (migration 0080) — Edit-mode lookup source for ONE Sale:
 * every active category/karat/payment method/collection channel, PLUS that
 * order's own currently-used value for each even if it has since gone
 * inactive (flagged is_historical). Deliberately NOT the same set
 * getSalesFormLookups() returns (that one is active-only, for the New Sale
 * form) — the Edit form must use this instead so a historical Sale's own
 * reference always renders correctly, while still never offering any OTHER
 * inactive option to switch to.
 */
export async function getSalesOrderEditLookups(orderId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("sales_order_edit_lookups", { p_order_id: orderId });
  if (error) throw error;

  const result = (data ?? {}) as {
    categories?: { id: string; name_ar: string; is_historical: boolean }[];
    karats?: { id: string; name_ar: string; code?: string; is_historical: boolean }[];
    payment_methods?: { id: string; name_ar: string; is_historical: boolean }[];
    collection_channels?: { id: string; name_ar: string; is_historical: boolean }[];
  };

  return {
    categories: result.categories ?? [],
    karats: result.karats ?? [],
    paymentMethods: result.payment_methods ?? [],
    collectionChannels: result.collection_channels ?? [],
  };
}

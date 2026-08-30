import "server-only";

import { createClient } from "@/lib/supabase/server";
import type { ReturnsListFilters } from "./schema";

/**
 * Patch 4.2 (Section 7) — narrow, Returns-permission-gated store/payment-
 * method label lookups (returns_operable_store_lookups()/returns_visible_
 * store_lookups()/returns_refund_method_lookups(), migration 0105). Replace
 * the old getReturnsFormLookups()'s direct `.from("payment_methods")`/
 * `.from("stores")` selects, which depended on payment_methods.view/
 * stores.view via RLS (0010/0044) — a real, undocumented dependency a
 * custom role holding only Returns permissions would silently trip over
 * (e.g. /returns/[id] failing to populate the refund-method dropdown for a
 * user with returns.record_refund but no payment_methods.view). Each RPC
 * returns only {id, name_ar} and checks the SPECIFIC Returns permission
 * that actually needs it — never a Master Data browse permission, and
 * holding one grants nothing toward browsing Master Data pages themselves.
 */
export async function getReturnsOperableStoreLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("returns_operable_store_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Every store the actor may VIEW historical Returns for — used for the /returns list filter. Section 7: gated on returns.view, not stores.view. */
export async function getReturnsVisibleStoreLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("returns_visible_store_lookups");
  if (error) throw error;
  return data ?? [];
}

/** Refund-method picker for record_sales_return_refund() — Section 7: gated on returns.record_refund, not payment_methods.view. */
export async function getReturnsRefundMethodLookups() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("returns_refund_method_lookups");
  if (error) throw error;
  return data ?? [];
}

/**
 * Paginated Returns list — thin wrapper over list_sales_returns()
 * (migration 0090). Profit columns arrive `null` already when the caller
 * lacks sales.view_profit — enforced inside the RPC, not duplicated here.
 */
export async function listSalesReturnsPage(filters: ReturnsListFilters, pageSize: number) {
  const supabase = await createClient();
  const offset = (filters.page - 1) * pageSize;

  const { data, error } = await supabase.rpc("list_sales_returns", {
    p_date_from: filters.date_from ?? null,
    p_date_to: filters.date_to ?? null,
    p_processed_store_id: filters.processed_store_id ?? null,
    p_original_store_id: filters.original_store_id ?? null,
    p_return_number: filters.return_number ?? null,
    p_order_number: filters.order_number ?? null,
    p_status: filters.status ?? null,
    p_scenario: filters.scenario ?? null,
    p_sales_order_id: filters.sales_order_id ?? null,
    p_limit: pageSize,
    p_offset: offset,
  });

  if (error) throw error;

  const rows = data ?? [];
  const total = rows.length > 0 ? rows[0].total_count : 0;

  return { rows, total };
}

/**
 * Full Return detail — thin wrapper over get_sales_return() (migration
 * 0090). Throws if not found/not visible. Profit-sensitive keys are simply
 * absent (not null) in the returned object without sales.view_profit — see
 * get_sales_return()'s own comment.
 */
export async function getSalesReturnDetail(id: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_sales_return", { p_id: id });
  if (error) throw error;
  return data as Record<string, unknown>;
}

/**
 * Everything the New Return flow needs for one Sale in a single call — thin
 * wrapper over get_returnable_sales_order() (migration 0090, rewritten by
 * Hotfix 4.2.1 Section 15 / migration 0112): order basics, every active
 * item flagged `returnable`, the DERIVED order_state (full/partial/
 * not_returned — never stored/cached), and existing returns for context.
 * Requires returns.create ONLY (enforced inside the RPC itself) — sales.view
 * is no longer a Returns prerequisite.
 */
export async function getReturnableSalesOrder(salesOrderId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_returnable_sales_order", { p_sales_order_id: salesOrderId });
  if (error) throw error;
  return data as Record<string, unknown>;
}

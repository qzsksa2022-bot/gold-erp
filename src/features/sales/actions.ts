"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import {
  createSalesOrderSchema,
  updateSalesOrderSchema,
  previewSalesOrderSchema,
  previewUpdateSalesOrderSchema,
  closeSalesDaySchema,
  type CreateSalesOrderInput,
  type UpdateSalesOrderInput,
  type PreviewSalesOrderInput,
  type PreviewUpdateSalesOrderInput,
  type CloseSalesDayInput,
} from "./schema";

// Every mutation below goes through a single trusted RPC (create_sales_
// order / update_sales_order / close_sales_day — supabase/migrations/
// 0061/0063/0064) — never a raw insert/update, and never more than one
// round trip, so "all or nothing" holds by construction (spec §11/§28).
// Every financial input (weight_grams/sale_price) stays a string from the
// browser through Zod through this file to the RPC call — never Number().

function itemsPayload(items: CreateSalesOrderInput["items"]) {
  return items.map((item) => ({
    // Patch 3.1 item 1/9 — stable identity: forward the existing item's id
    // when present (an edit), omit it for a new item. create_sales_order()
    // ignores this field entirely; update_sales_order() (migration 0069)
    // uses it to distinguish "keep/edit this exact row" from "insert a new
    // row", and soft-removes any existing active item whose id is absent
    // here — never a hard delete.
    ...(item.id ? { id: item.id } : {}),
    category_id: item.category_id,
    karat_id: item.karat_id,
    weight_grams: item.weight_grams,
    sale_price: item.sale_price,
    item_name: item.item_name ?? null,
    description: item.description ?? null,
    sku: item.sku ?? null,
  }));
}

export async function createSalesOrderAction(input: CreateSalesOrderInput): Promise<ActionResult<{ id: string; order_number: string }>> {
  await requirePermission("sales.create");

  const parsed = createSalesOrderSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_sales_order", {
    p_store_id: parsed.data.store_id,
    p_sale_date: parsed.data.sale_date,
    p_payment_method_id: parsed.data.payment_method_id,
    p_collection_channel_id: parsed.data.collection_channel_id,
    p_items: itemsPayload(parsed.data.items),
    p_customer_name: parsed.data.customer_name ?? null,
    p_customer_phone: parsed.data.customer_phone ?? null,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[sales] create_sales_order failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.sales);
  return actionSuccess({ id: row.id, order_number: row.order_number }, `تم إنشاء عملية البيع رقم ${row.order_number} بنجاح.`);
}

export async function updateSalesOrderAction(input: UpdateSalesOrderInput): Promise<ActionResult<{ id: string; order_number: string }>> {
  await requirePermission("sales.edit");

  const parsed = updateSalesOrderSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("update_sales_order", {
    p_order_id: parsed.data.order_id,
    p_payment_method_id: parsed.data.payment_method_id,
    p_collection_channel_id: parsed.data.collection_channel_id,
    p_items: itemsPayload(parsed.data.items),
    p_customer_name: parsed.data.customer_name ?? null,
    p_customer_phone: parsed.data.customer_phone ?? null,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
    // Patch 3.2 item 2 — optimistic concurrency: rejected with a Conflict
    // (isVersionConflictError()) if this no longer matches the row's
    // current row_version. Never silently retried by this action — the
    // Edit form must reload and let the user reconcile.
    p_expected_version: parsed.data.row_version,
  });

  if (error) {
    console.error("[sales] update_sales_order failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.sales);
  revalidatePath(`${ROUTES.sales}/${row.id}`);
  return actionSuccess({ id: row.id, order_number: row.order_number }, "تم حفظ التعديلات بنجاح.");
}

/**
 * Fast-UX preview (spec §17) — read-only, called on every meaningful form
 * change (debounced client-side). NOT the source of truth: save always
 * recomputes independently inside create_sales_order()/update_sales_order().
 */
export async function previewSalesOrderAction(input: PreviewSalesOrderInput): Promise<ActionResult<Record<string, unknown>>> {
  const parsed = previewSalesOrderSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.");
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("preview_sales_order", {
    p_store_id: parsed.data.store_id,
    p_sale_date: parsed.data.sale_date,
    p_payment_method_id: parsed.data.payment_method_id,
    p_collection_channel_id: parsed.data.collection_channel_id,
    p_items: itemsPayload(parsed.data.items),
  });

  if (error) {
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  return actionSuccess((data as Record<string, unknown>) ?? {});
}

/**
 * Patch 3.2 item 5 — Edit-mode preview, read-only, over preview_update_
 * sales_order() (migration 0078) — mirrors update_sales_order()'s own
 * decision tree (unchanged item -> preserved snapshot, changed item ->
 * recalculated) instead of treating every item as brand-new like Create's
 * preview does. Used ONLY by the Edit form.
 */
export async function previewUpdateSalesOrderAction(input: PreviewUpdateSalesOrderInput): Promise<ActionResult<Record<string, unknown>>> {
  const parsed = previewUpdateSalesOrderSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.");
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("preview_update_sales_order", {
    p_order_id: parsed.data.order_id,
    p_expected_version: parsed.data.row_version,
    p_payment_method_id: parsed.data.payment_method_id,
    p_collection_channel_id: parsed.data.collection_channel_id,
    p_items: itemsPayload(parsed.data.items),
    p_customer_name: parsed.data.customer_name ?? null,
    p_customer_phone: parsed.data.customer_phone ?? null,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  return actionSuccess((data as Record<string, unknown>) ?? {});
}

export async function closeSalesDayAction(input: CloseSalesDayInput): Promise<ActionResult<{ id: string }>> {
  await requirePermission("sales.close_day");

  const parsed = closeSalesDaySchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("close_sales_day", {
    p_store_id: parsed.data.store_id,
    p_business_date: parsed.data.business_date,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[sales] close_sales_day failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }
  if (!data) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.sales);
  return actionSuccess({ id: data }, "تم إغلاق اليوم بنجاح.");
}

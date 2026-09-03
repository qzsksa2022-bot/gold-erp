"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import {
  createInventoryItemSchema,
  updateInventoryItemSchema,
  receiveInventoryStockSchema,
  adjustInventoryStockSchema,
  type CreateInventoryItemInput,
  type UpdateInventoryItemInput,
  type ReceiveInventoryStockInput,
  type AdjustInventoryStockInput,
} from "./schema";

// Every mutation below goes through a single trusted SECURITY DEFINER RPC
// (migration 0229) — never a raw insert/update, mirroring src/features/
// adjustments/actions.ts exactly. inventory_items/inventory_stock_movements
// carry zero direct-write RLS policy (Layer-A lockdown, 0228) — a raw
// .from(...).insert/.update would be silently rejected by Postgres
// regardless of what this file does. Every quantity input stays a string
// from the browser through Zod through this file to the RPC call — never
// Number().

export async function createInventoryItemAction(input: CreateInventoryItemInput): Promise<ActionResult<{ id: string; sku: string; row_version: number }>> {
  await requirePermission("inventory.receive");

  const parsed = createInventoryItemSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_inventory_item", {
    p_sku: parsed.data.sku,
    p_name_ar: parsed.data.name_ar,
    p_category_id: parsed.data.category_id,
    p_karat_id: parsed.data.karat_id ?? null,
    p_unit: parsed.data.unit,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[inventory] create_inventory_item failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.inventory);
  return actionSuccess({ id: row.id, sku: row.sku, row_version: row.row_version }, `تمت إضافة الصنف "${row.sku}" بنجاح.`);
}

export async function updateInventoryItemAction(input: UpdateInventoryItemInput): Promise<ActionResult<{ id: string; row_version: number }>> {
  await requirePermission("inventory.adjust");

  const parsed = updateInventoryItemSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("update_inventory_item", {
    p_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_name_ar: parsed.data.name_ar,
    p_category_id: parsed.data.category_id,
    p_karat_id: parsed.data.karat_id ?? null,
    p_unit: parsed.data.unit,
    p_active: parsed.data.active,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[inventory] update_inventory_item failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.inventory);
  return actionSuccess({ id: row.id, row_version: row.row_version }, "تم حفظ التعديلات بنجاح.");
}

export async function receiveInventoryStockAction(input: ReceiveInventoryStockInput): Promise<ActionResult<{ id: string; resulting_balance: string }>> {
  await requirePermission("inventory.receive");

  const parsed = receiveInventoryStockSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("receive_inventory_stock", {
    p_item_id: parsed.data.item_id,
    p_store_id: parsed.data.store_id,
    p_quantity: parsed.data.quantity,
    p_business_date: parsed.data.business_date,
    p_reference: parsed.data.reference ?? null,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[inventory] receive_inventory_stock failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.inventory);
  revalidatePath(ROUTES.inventoryMovements);
  return actionSuccess({ id: row.id, resulting_balance: row.resulting_balance }, "تم تسجيل استلام المخزون بنجاح.");
}

export async function adjustInventoryStockAction(input: AdjustInventoryStockInput): Promise<ActionResult<{ id: string; resulting_balance: string }>> {
  await requirePermission("inventory.adjust");

  const parsed = adjustInventoryStockSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjust_inventory_stock", {
    p_item_id: parsed.data.item_id,
    p_store_id: parsed.data.store_id,
    p_quantity_delta: parsed.data.quantity_delta,
    p_reason: parsed.data.reason,
    p_business_date: parsed.data.business_date,
    p_reference: parsed.data.reference ?? null,
  });

  if (error) {
    console.error("[inventory] adjust_inventory_stock failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.inventory);
  revalidatePath(ROUTES.inventoryMovements);
  return actionSuccess({ id: row.id, resulting_balance: row.resulting_balance }, "تم تسجيل تصحيح المخزون بنجاح.");
}

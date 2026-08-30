"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import {
  createAdjustmentSchema,
  updateAdjustmentSchema,
  approveAdjustmentSchema,
  rejectAdjustmentSchema,
  reverseAdjustmentSchema,
  adjustmentTypeFormSchema,
  setAdjustmentCostSchema,
  type CreateAdjustmentInput,
  type UpdateAdjustmentInput,
  type ApproveAdjustmentInput,
  type RejectAdjustmentInput,
  type ReverseAdjustmentInput,
  type SetAdjustmentCostInput,
} from "./schema";

// Every mutation below goes through a single trusted SECURITY DEFINER RPC
// (create/update/approve/reject/reverse_sales_order_adjustment, migrations
// 0139/0140/0141; adjustment_types CRUD, migration 0136) — never a raw
// insert/update, mirroring src/features/shipping/actions.ts exactly. The
// base tables (sales_order_adjustments/sales_order_adjustment_reversals/
// adjustment_types) carry zero direct-write RLS policy (Layer-A lockdown,
// 0135) — a raw .from(...).insert/.update would be silently rejected by
// Postgres regardless of what this file does, so the RPC is not merely a
// convention here, it is the only path that works at all. Every financial
// input stays a string from the browser through Zod through this file to
// the RPC call — never Number().

export async function createAdjustmentAction(input: CreateAdjustmentInput): Promise<ActionResult<{ id: string; adjustment_number: string }>> {
  await requirePermission("adjustments.create");

  const parsed = createAdjustmentSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_sales_order_adjustment", {
    p_sales_order_id: parsed.data.sales_order_id,
    p_adjustment_type_id: parsed.data.adjustment_type_id,
    p_processing_store_id: parsed.data.processing_store_id,
    p_adjustment_date: parsed.data.adjustment_date,
    p_payment_method_id: parsed.data.payment_method_id ?? null,
    p_collection_channel_id: parsed.data.collection_channel_id ?? null,
    p_participates_in_settlement: parsed.data.participates_in_settlement,
    p_customer_charge: parsed.data.customer_charge,
    p_direct_cost: parsed.data.direct_cost ?? null,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
    p_payment_reference: parsed.data.payment_reference ?? null,
  });

  if (error) {
    console.error("[adjustments] create_sales_order_adjustment failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.adjustments);
  return actionSuccess({ id: row.id, adjustment_number: row.adjustment_number }, `تم إنشاء التعديل/الخدمة رقم ${row.adjustment_number} بنجاح.`);
}

export async function updateAdjustmentAction(input: UpdateAdjustmentInput): Promise<ActionResult<{ row_version: number }>> {
  await requirePermission("adjustments.create");

  const parsed = updateAdjustmentSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  // Patch 6.1 item 1B — update_sales_order_adjustment() v2 (0147) dropped
  // p_direct_cost entirely; direct_cost is never sent here regardless of
  // what the (now cost-field-less) edit form submits. Cost changes go
  // through setAdjustmentCostAction() below instead.
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("update_sales_order_adjustment", {
    p_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_adjustment_type_id: parsed.data.adjustment_type_id,
    p_processing_store_id: parsed.data.processing_store_id,
    p_adjustment_date: parsed.data.adjustment_date,
    p_payment_method_id: parsed.data.payment_method_id ?? null,
    p_collection_channel_id: parsed.data.collection_channel_id ?? null,
    p_participates_in_settlement: parsed.data.participates_in_settlement,
    p_customer_charge: parsed.data.customer_charge,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
    p_payment_reference: parsed.data.payment_reference ?? null,
  });

  if (error) {
    console.error("[adjustments] update_sales_order_adjustment failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.adjustments);
  revalidatePath(`${ROUTES.adjustments}/${parsed.data.id}`);
  return actionSuccess({ row_version: row.row_version }, "تم حفظ التعديلات بنجاح.");
}

/**
 * Patch 6.1 item 2 — the SINGLE sanctioned path for setting/correcting a
 * PENDING record's direct_cost, via the dedicated set_pending_sales_order_
 * adjustment_direct_cost() RPC (0145). Requires adjustments.manage_cost
 * ALONE — deliberately independent of adjustments.create/approve (item 1/5),
 * so this is gated on manage_cost here, never create/approve.
 */
export async function setAdjustmentCostAction(input: SetAdjustmentCostInput): Promise<ActionResult<{ row_version: number; direct_cost: string; has_direct_cost: boolean }>> {
  await requirePermission("adjustments.manage_cost");

  const parsed = setAdjustmentCostSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_pending_sales_order_adjustment_direct_cost", {
    p_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_direct_cost: parsed.data.direct_cost,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[adjustments] set_pending_sales_order_adjustment_direct_cost failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.adjustments);
  revalidatePath(`${ROUTES.adjustments}/${parsed.data.id}`);
  return actionSuccess({ row_version: row.row_version, direct_cost: row.direct_cost, has_direct_cost: row.has_direct_cost }, "تم حفظ التكلفة المباشرة بنجاح.");
}

export async function approveAdjustmentAction(input: ApproveAdjustmentInput): Promise<ActionResult<{ row_version: number; adjustment_number: string; net_adjustment_profit: string | null }>> {
  await requirePermission("adjustments.approve");

  const parsed = approveAdjustmentSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("approve_sales_order_adjustment", {
    p_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[adjustments] approve_sales_order_adjustment failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.adjustments);
  revalidatePath(`${ROUTES.adjustments}/${parsed.data.id}`);
  return actionSuccess(
    { row_version: row.row_version, adjustment_number: row.adjustment_number, net_adjustment_profit: row.net_adjustment_profit },
    `تم اعتماد التعديل/الخدمة رقم ${row.adjustment_number} بنجاح.`,
  );
}

export async function rejectAdjustmentAction(input: RejectAdjustmentInput): Promise<ActionResult<{ row_version: number }>> {
  await requirePermission("adjustments.approve");

  const parsed = rejectAdjustmentSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reject_sales_order_adjustment", {
    p_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_reason: parsed.data.reason,
  });

  if (error) {
    console.error("[adjustments] reject_sales_order_adjustment failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.adjustments);
  revalidatePath(`${ROUTES.adjustments}/${parsed.data.id}`);
  return actionSuccess({ row_version: row.row_version }, "تم رفض التعديل/الخدمة.");
}

export async function reverseAdjustmentAction(input: ReverseAdjustmentInput): Promise<ActionResult<{ id: string; reversal_id: string }>> {
  await requirePermission("adjustments.reverse");

  const parsed = reverseAdjustmentSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reverse_sales_order_adjustment", {
    p_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_reversal_business_date: parsed.data.reversal_business_date,
    p_reason: parsed.data.reason,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[adjustments] reverse_sales_order_adjustment failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.adjustments);
  revalidatePath(`${ROUTES.adjustments}/${parsed.data.id}`);
  return actionSuccess({ id: row.id, reversal_id: row.reversal_id }, "تم عكس التعديل/الخدمة بنجاح.");
}

/**
 * Narrow, adjustments.create-gated preview the /adjustments/new UI calls
 * before submission (migration 0138, v2 in 0155) — never requires sales.
 * view_profit for the operational fields; profit fields simply arrive null
 * without it. Patch 6.1 items 9/10 — paymentMethodId is now OPTIONAL: for a
 * zero-charge (free service) preview, the entry form never resolves a
 * payment method at all, and preview_sales_order_adjustment() v2 (0155)
 * unconditionally returns fee_found=true/payment_fee_amount=0.00 for
 * customer_charge=0 regardless of payment method.
 */
export async function previewAdjustmentAction(params: {
  paymentMethodId?: string;
  customerCharge: string;
  directCost?: string;
  adjustmentDate?: string;
}): Promise<
  ActionResult<{
    fee_found: boolean;
    customer_charge: string;
    payment_fee_percentage: string | null;
    payment_fee_fixed: string | null;
    payment_fee_amount: string | null;
    direct_cost: string | null;
    gross_adjustment_profit: string | null;
    net_adjustment_profit: string | null;
  }>
> {
  await requirePermission("adjustments.create");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("preview_sales_order_adjustment", {
    p_payment_method_id: params.paymentMethodId || null,
    p_customer_charge: params.customerCharge,
    p_direct_cost: params.directCost || null,
    p_adjustment_date: params.adjustmentDate || undefined,
  });

  if (error) {
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);
  return actionSuccess(row);
}

/** Order lookup step of /adjustments/new — thin wrapper over search_sales_orders_for_adjustment() (0137), gated on adjustments.create ALONE, never sales.view (§25). */
export async function searchSalesOrdersForAdjustmentAction(search: string): Promise<
  ActionResult<{ sales_order_id: string; order_number: string; sale_date: string; store_name: string | null; customer_name: string | null; customer_phone: string | null; original_invoice_amount: string }[]>
> {
  await requirePermission("adjustments.create");

  const trimmed = search.trim();
  if (!trimmed) return actionSuccess([]);

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("search_sales_orders_for_adjustment", {
    p_search: trimmed,
    p_limit: 10,
  });

  if (error) {
    console.error("[adjustments] search sales orders failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  return actionSuccess(data ?? []);
}

// ---------------------------------------------------------------------------
// adjustment_types CRUD (migration 0136) — every write goes through an RPC,
// never a raw table write (Layer-A lockdown, 0134).
// ---------------------------------------------------------------------------

export async function createAdjustmentTypeAction(input: unknown): Promise<ActionResult<{ id: string }>> {
  await requirePermission("adjustments.manage_types");

  const parsed = adjustmentTypeFormSchema.safeParse(input);
  if (!parsed.success || !parsed.data.code) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.success ? { code: ["الرمز مطلوب"] } : parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_adjustment_type", {
    p_code: parsed.data.code,
    p_name_ar: parsed.data.name_ar,
    p_name_en: parsed.data.name_en ?? null,
    p_description: parsed.data.description ?? null,
    p_sort_order: parsed.data.sort_order ?? 0,
  });

  if (error) {
    console.error("[adjustments] create_adjustment_type failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataAdjustmentTypes);
  return actionSuccess({ id: data as string }, "تمت إضافة نوع التعديل/الخدمة بنجاح.");
}

export async function updateAdjustmentTypeAction(typeId: string, input: unknown): Promise<ActionResult<null>> {
  await requirePermission("adjustments.manage_types");

  const parsed = adjustmentTypeFormSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("update_adjustment_type", {
    p_id: typeId,
    p_name_ar: parsed.data.name_ar,
    p_name_en: parsed.data.name_en ?? null,
    p_description: parsed.data.description ?? null,
    p_sort_order: parsed.data.sort_order ?? 0,
  });

  if (error) {
    console.error("[adjustments] update_adjustment_type failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataAdjustmentTypes);
  return actionSuccess(null, "تم حفظ التعديلات.");
}

export async function setAdjustmentTypeStatusAction(typeId: string, nextStatus: "active" | "disabled"): Promise<ActionResult<null>> {
  await requirePermission("adjustments.manage_types");

  const supabase = await createClient();
  const { error } = await supabase.rpc(nextStatus === "disabled" ? "disable_adjustment_type" : "enable_adjustment_type", { p_id: typeId });

  if (error) {
    console.error("[adjustments] adjustment type status change failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataAdjustmentTypes);
  return actionSuccess(null, nextStatus === "disabled" ? "تم تعطيل نوع التعديل/الخدمة." : "تمت إعادة تفعيل نوع التعديل/الخدمة.");
}

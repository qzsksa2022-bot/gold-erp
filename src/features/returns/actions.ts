"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import {
  createSalesReturnSchema,
  previewSalesReturnSchema,
  updatePendingSalesReturnSchema,
  refreshPendingSalesReturnSchema,
  approveSalesReturnSchema,
  rejectSalesReturnSchema,
  reverseSalesReturnSchema,
  recordSalesReturnRefundSchema,
  reverseSalesReturnRefundEventSchema,
  finalizeSalesReturnRefundSchema,
  reopenSalesReturnRefundReconciliationSchema,
  type CreateSalesReturnInput,
  type PreviewSalesReturnInput,
  type UpdatePendingSalesReturnInput,
  type RefreshPendingSalesReturnInput,
  type ApproveSalesReturnInput,
  type RejectSalesReturnInput,
  type ReverseSalesReturnInput,
  type RecordSalesReturnRefundInput,
  type ReverseSalesReturnRefundEventInput,
  type FinalizeSalesReturnRefundInput,
  type ReopenSalesReturnRefundReconciliationInput,
} from "./schema";

// Every mutation below goes through a single trusted RPC (create_sales_
// return / update_pending_sales_return / refresh_pending_sales_return_
// from_sale / approve_sales_return / reject_sales_return / reverse_sales_
// return / record_sales_return_refund / reverse_sales_return_refund_event /
// finalize_sales_return_refund — migrations 0085-0089, rewritten/added by
// Patch 4.1's 0093-0097) — never a raw insert/update, mirroring
// src/features/sales/actions.ts exactly. Every financial input stays a
// string from the browser through Zod through this file to the RPC call —
// never Number().

function itemsPayload(items: CreateSalesReturnInput["items"]) {
  return items.map((it) => ({
    sales_order_item_id: it.sales_order_item_id,
    condition: it.condition,
    item_return_reason: it.item_return_reason ?? null,
    item_notes: it.item_notes ?? null,
  }));
}

export async function createSalesReturnAction(input: CreateSalesReturnInput): Promise<ActionResult<{ id: string; return_number: string }>> {
  await requirePermission("returns.create");

  const parsed = createSalesReturnSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_sales_return", {
    p_sales_order_id: parsed.data.sales_order_id,
    p_processed_store_id: parsed.data.processed_store_id,
    p_return_date: parsed.data.return_date,
    p_scenario: parsed.data.scenario,
    p_items: itemsPayload(parsed.data.items),
    p_expected_sale_version: parsed.data.expected_sale_version,
    p_collection_state: parsed.data.collection_state,
    p_approved_refund_amount: parsed.data.approved_refund_amount,
    p_non_shipping_deduction_amount: parsed.data.non_shipping_deduction_amount,
    p_deduction_reason: parsed.data.deduction_reason ?? null,
    p_refund_difference_reason: parsed.data.refund_difference_reason ?? null,
    p_scenario_notes: parsed.data.scenario_notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[returns] create_sales_return failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.returns);
  return actionSuccess({ id: row.id, return_number: row.return_number }, `تم إنشاء المرتجع رقم ${row.return_number} بنجاح.`);
}

/**
 * Fast-UX preview — read-only, called on every meaningful item-selection or
 * business-input change (debounced client-side). NOT the source of truth:
 * the fee-reversal figure is explicitly an ESTIMATE (see preview_sales_
 * return()'s own comment) — approve_sales_return() always recomputes
 * independently at approval time (Section 16). Only requires returns.create
 * (mirrors preview_sales_order()'s permission-free-beyond-create shape).
 */
export async function previewSalesReturnAction(input: PreviewSalesReturnInput): Promise<ActionResult<Record<string, unknown>>> {
  const parsed = previewSalesReturnSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.");
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("preview_sales_return", {
    p_sales_order_id: parsed.data.sales_order_id,
    p_items: itemsPayload(parsed.data.items),
    p_scenario: parsed.data.scenario ?? null,
    p_collection_state: parsed.data.collection_state ?? null,
    p_non_shipping_deduction_amount: parsed.data.non_shipping_deduction_amount ?? "0",
    p_deduction_reason: parsed.data.deduction_reason ?? null,
    p_approved_refund_amount: parsed.data.approved_refund_amount ?? null,
    p_refund_difference_reason: parsed.data.refund_difference_reason ?? null,
    p_fee_reversal_override: parsed.data.fee_reversal_override ?? null,
  });

  if (error) {
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  return actionSuccess((data as Record<string, unknown>) ?? {});
}

export async function updatePendingSalesReturnAction(input: UpdatePendingSalesReturnInput): Promise<ActionResult<{ id: string; return_number: string }>> {
  await requirePermission("returns.create");

  const parsed = updatePendingSalesReturnSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("update_pending_sales_return", {
    p_return_id: parsed.data.return_id,
    p_scenario: parsed.data.scenario,
    p_items: itemsPayload(parsed.data.items),
    p_collection_state: parsed.data.collection_state,
    p_approved_refund_amount: parsed.data.approved_refund_amount,
    p_expected_version: parsed.data.row_version,
    p_non_shipping_deduction_amount: parsed.data.non_shipping_deduction_amount,
    p_deduction_reason: parsed.data.deduction_reason ?? null,
    p_refund_difference_reason: parsed.data.refund_difference_reason ?? null,
    p_scenario_notes: parsed.data.scenario_notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[returns] update_pending_sales_return failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.returns);
  revalidatePath(`${ROUTES.returns}/${row.id}`);
  return actionSuccess({ id: row.id, return_number: row.return_number }, "تم حفظ التعديلات بنجاح.");
}

/**
 * Patch 4.1 (Section 4) — the explicit refresh path for a Pending return
 * whose Sale changed since creation. Never called automatically; the user
 * chooses this after seeing the stale-sale rejection from approve_sales_
 * return() (isStaleSaleError() in schema.ts).
 */
export async function refreshPendingSalesReturnAction(input: RefreshPendingSalesReturnInput): Promise<ActionResult<{ id: string; return_number: string }>> {
  await requirePermission("returns.create");

  const parsed = refreshPendingSalesReturnSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("refresh_pending_sales_return_from_sale", {
    p_return_id: parsed.data.return_id,
    p_expected_version: parsed.data.row_version,
  });

  if (error) {
    console.error("[returns] refresh_pending_sales_return_from_sale failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(`${ROUTES.returns}/${row.id}`);
  return actionSuccess({ id: row.id, return_number: row.return_number }, "تم تحديث بيانات المرتجع من أحدث نسخة لعملية البيع. راجع الأرقام قبل الاعتماد.");
}

export async function approveSalesReturnAction(input: ApproveSalesReturnInput): Promise<ActionResult<{ id: string; return_number: string }>> {
  await requirePermission("returns.approve");

  const parsed = approveSalesReturnSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("approve_sales_return", {
    p_return_id: parsed.data.return_id,
    p_expected_version: parsed.data.row_version,
    p_fee_reversal_override: parsed.data.fee_reversal_override ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[returns] approve_sales_return failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.returns);
  revalidatePath(`${ROUTES.returns}/${row.id}`);
  return actionSuccess({ id: row.id, return_number: row.return_number }, `تم اعتماد المرتجع رقم ${row.return_number} بنجاح.`);
}

export async function rejectSalesReturnAction(input: RejectSalesReturnInput): Promise<ActionResult<{ id: string; return_number: string }>> {
  await requirePermission("returns.approve");

  const parsed = rejectSalesReturnSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reject_sales_return", {
    p_return_id: parsed.data.return_id,
    p_expected_version: parsed.data.row_version,
    p_rejection_reason: parsed.data.rejection_reason,
  });

  if (error) {
    console.error("[returns] reject_sales_return failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.returns);
  revalidatePath(`${ROUTES.returns}/${row.id}`);
  return actionSuccess({ id: row.id, return_number: row.return_number }, `تم رفض المرتجع رقم ${row.return_number}.`);
}

export async function reverseSalesReturnAction(input: ReverseSalesReturnInput): Promise<ActionResult<{ id: string; return_number: string }>> {
  await requirePermission("returns.reverse");

  const parsed = reverseSalesReturnSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reverse_sales_return", {
    p_return_id: parsed.data.return_id,
    p_expected_version: parsed.data.row_version,
    p_reversal_reason: parsed.data.reversal_reason,
    p_reversal_business_date: parsed.data.reversal_business_date ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[returns] reverse_sales_return failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.returns);
  revalidatePath(`${ROUTES.returns}/${row.id}`);
  return actionSuccess({ id: row.id, return_number: row.return_number }, `تم التراجع عن المرتجع رقم ${row.return_number}.`);
}

export async function recordSalesReturnRefundAction(input: RecordSalesReturnRefundInput): Promise<ActionResult<{ id: string }>> {
  await requirePermission("returns.record_refund");

  const parsed = recordSalesReturnRefundSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("record_sales_return_refund", {
    p_return_id: parsed.data.return_id,
    p_amount: parsed.data.amount,
    p_refund_method_id: parsed.data.refund_method_id,
    p_refund_business_date: parsed.data.refund_business_date ?? null,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
    p_reference: parsed.data.reference ?? null,
  });

  if (error) {
    console.error("[returns] record_sales_return_refund failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(`${ROUTES.returns}/${parsed.data.return_id}`);
  return actionSuccess({ id: row.id }, "تم تسجيل الاسترداد النقدي بنجاح.");
}

export async function reverseSalesReturnRefundEventAction(input: ReverseSalesReturnRefundEventInput): Promise<ActionResult<{ id: string }>> {
  await requirePermission("returns.record_refund");

  const parsed = reverseSalesReturnRefundEventSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reverse_sales_return_refund_event", {
    p_event_id: parsed.data.event_id,
    p_reversal_reason: parsed.data.reversal_reason,
    p_reversal_business_date: parsed.data.reversal_business_date ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[returns] reverse_sales_return_refund_event failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.returns);
  return actionSuccess({ id: row.id }, "تم التراجع عن سجل الاسترداد.");
}

/**
 * Patch 4.1 (Section 11) — declares refund reconciliation for one return
 * complete; requires a variance reason iff the actual refunded total does
 * not match approved_refund_amount at this moment.
 */
export async function finalizeSalesReturnRefundAction(input: FinalizeSalesReturnRefundInput): Promise<ActionResult<{ id: string; return_number: string; actual_refunded_total: string; refund_variance: string }>> {
  await requirePermission("returns.record_refund");

  const parsed = finalizeSalesReturnRefundSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("finalize_sales_return_refund", {
    p_return_id: parsed.data.return_id,
    p_expected_version: parsed.data.row_version,
    p_variance_reason: parsed.data.variance_reason ?? null,
  });

  if (error) {
    console.error("[returns] finalize_sales_return_refund failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(`${ROUTES.returns}/${row.id}`);
  return actionSuccess(
    { id: row.id, return_number: row.return_number, actual_refunded_total: row.actual_refunded_total, refund_variance: row.refund_variance },
    "تم إغلاق تسوية الاسترداد بنجاح.",
  );
}

/**
 * Patch 4.2 (Section 4) — the explicit, reason-required escape hatch from a
 * Finalized refund reconciliation. After this succeeds, record_sales_
 * return_refund()/reverse_sales_return_refund_event() become callable again
 * and finalize_sales_return_refund() can run once more.
 */
export async function reopenSalesReturnRefundReconciliationAction(
  input: ReopenSalesReturnRefundReconciliationInput,
): Promise<ActionResult<{ id: string; return_number: string }>> {
  await requirePermission("returns.record_refund");

  const parsed = reopenSalesReturnRefundReconciliationSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reopen_sales_return_refund_reconciliation", {
    p_return_id: parsed.data.return_id,
    p_expected_version: parsed.data.row_version,
    p_reason: parsed.data.reason,
  });

  if (error) {
    console.error("[returns] reopen_sales_return_refund_reconciliation failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(`${ROUTES.returns}/${row.id}`);
  return actionSuccess({ id: row.id, return_number: row.return_number }, "تمت إعادة فتح تسوية الاسترداد بنجاح.");
}

/**
 * Order lookup step of the New Return flow — the UI only knows an
 * order_number typed by staff, but every Returns RPC needs the order's
 * uuid. Thin, read-only wrapper over search_sales_orders_for_return()
 * (Hotfix 4.2.1, Section 15, migration 0112) — a Returns-only narrow Sale
 * lookup gated on returns.create ALONE, replacing the previous wrapper over
 * list_sales_orders() (migration 0079), which independently required
 * sales.view. That hidden dependency meant a custom role granted
 * returns.create but not sales.view could never start a Return at all,
 * even though returns.create was always meant to be sufficient by itself.
 * get_returnable_sales_order() (queries.ts) was fixed the same way
 * (migration 0112) — nothing here is a security shortcut, only a UX lookup
 * scoped to visible stores.
 */
export async function searchSalesOrdersForReturnAction(orderNumber: string): Promise<
  ActionResult<{ id: string; order_number: string; sale_date: string; store_name: string | null; customer_name: string | null; subtotal: string }[]>
> {
  await requirePermission("returns.create");

  const trimmed = orderNumber.trim();
  if (!trimmed) return actionSuccess([]);

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("search_sales_orders_for_return", {
    p_order_number: trimmed,
    p_limit: 10,
  });

  if (error) {
    console.error("[returns] search sales orders failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  return actionSuccess(
    (data ?? []).map((r) => ({
      id: r.id,
      order_number: r.order_number,
      sale_date: r.sale_date,
      store_name: r.store_name,
      customer_name: r.customer_name,
      subtotal: r.subtotal,
    })),
  );
}

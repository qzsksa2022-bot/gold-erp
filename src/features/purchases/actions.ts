"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import {
  createSupplierSchema,
  updateSupplierSchema,
  postPurchaseInvoiceSchema,
  reversePurchaseInvoiceSchema,
  recordSupplierPaymentSchema,
  reverseSupplierPaymentSchema,
  type CreateSupplierInput,
  type UpdateSupplierInput,
  type PostPurchaseInvoiceInput,
  type ReversePurchaseInvoiceInput,
  type RecordSupplierPaymentInput,
  type ReverseSupplierPaymentInput,
} from "./schema";

// Every mutation below goes through a single trusted SECURITY DEFINER RPC
// (migration 0239) — never a raw insert/update, mirroring
// src/features/expenses/actions.ts exactly. suppliers/purchase_invoices/
// purchase_invoice_lines/supplier_payments carry zero direct-write RLS policy
// (Layer-A lockdown, 0238), and the three ledgers additionally reject every
// UPDATE/DELETE at trigger level — a raw .from(...).insert/.update would be
// rejected by Postgres regardless of what this file does. Every monetary input
// stays a string from the browser through Zod through this file to the RPC
// call — never Number().
//
// ACCOUNTING BOUNDARY (Decision 5): nothing in this file writes, or can write,
// a store_expenses row. An inventory purchase is the acquisition of an asset,
// not an operating expense, and the two ledgers never meet.

export async function createSupplierAction(input: CreateSupplierInput): Promise<ActionResult<{ id: string; code: string; row_version: number }>> {
  await requirePermission("purchases.manage_suppliers");

  const parsed = createSupplierSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_supplier", {
    p_code: parsed.data.code,
    p_name_ar: parsed.data.name_ar,
    p_name_en: parsed.data.name_en ?? null,
    p_vat_number: parsed.data.vat_number ?? null,
    p_contact_person: parsed.data.contact_person ?? null,
    p_phone: parsed.data.phone ?? null,
    p_email: parsed.data.email ?? null,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[purchases] create_supplier failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.suppliers);
  return actionSuccess({ id: row.id, code: row.code, row_version: row.row_version }, `تمت إضافة المورّد "${row.code}" بنجاح.`);
}

export async function updateSupplierAction(input: UpdateSupplierInput): Promise<ActionResult<{ id: string; row_version: number }>> {
  await requirePermission("purchases.manage_suppliers");

  const parsed = updateSupplierSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("update_supplier", {
    p_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_name_ar: parsed.data.name_ar,
    p_name_en: parsed.data.name_en ?? null,
    p_vat_number: parsed.data.vat_number ?? null,
    p_contact_person: parsed.data.contact_person ?? null,
    p_phone: parsed.data.phone ?? null,
    p_email: parsed.data.email ?? null,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[purchases] update_supplier failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.suppliers);
  return actionSuccess({ id: row.id, row_version: row.row_version }, "تم تحديث بيانات المورّد بنجاح.");
}

export async function setSupplierStatusAction(supplierId: string, nextStatus: "active" | "disabled"): Promise<ActionResult<null>> {
  await requirePermission("purchases.manage_suppliers");

  const supabase = await createClient();
  const { error } = await supabase.rpc("set_supplier_status", { p_id: supplierId, p_status: nextStatus });

  if (error) {
    console.error("[purchases] set_supplier_status failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.suppliers);
  return actionSuccess(null, nextStatus === "disabled" ? "تم تعطيل المورّد." : "تم تفعيل المورّد.");
}

export async function postPurchaseInvoiceAction(input: PostPurchaseInvoiceInput): Promise<ActionResult<{ id: string; purchase_number: string; gross_total: string }>> {
  await requirePermission("purchases.create");

  const parsed = postPurchaseInvoiceSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("post_purchase_invoice", {
    p_supplier_id: parsed.data.supplier_id,
    p_store_id: parsed.data.store_id,
    // Every amount inside p_lines stays a STRING right up to here — PostgREST
    // hands each one to a numeric parameter server-side, so none is ever seen
    // by a JS float.
    p_lines: parsed.data.lines,
    p_net_total: parsed.data.net_total,
    p_vat_total: parsed.data.vat_total,
    p_gross_total: parsed.data.gross_total,
    p_business_date: parsed.data.business_date,
    p_supplier_invoice_number: parsed.data.supplier_invoice_number ?? null,
    p_supplier_invoice_date: parsed.data.supplier_invoice_date ?? null,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[purchases] post_purchase_invoice failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.purchases);
  // Posting an invoice receives its quantities into stock in the same
  // transaction (Decision 2), so the inventory screens are stale too.
  revalidatePath(ROUTES.inventory);
  return actionSuccess(
    { id: row.id, purchase_number: row.purchase_number, gross_total: row.gross_total },
    `تم ترحيل فاتورة الشراء "${row.purchase_number}" وإدخال كمياتها للمخزون.`,
  );
}

export async function reversePurchaseInvoiceAction(input: ReversePurchaseInvoiceInput): Promise<ActionResult<{ id: string; purchase_number: string; gross_total: string }>> {
  await requirePermission("purchases.reverse");

  const parsed = reversePurchaseInvoiceSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reverse_purchase_invoice", {
    p_invoice_id: parsed.data.invoice_id,
    p_reason: parsed.data.reason,
    p_reversal_business_date: parsed.data.business_date,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[purchases] reverse_purchase_invoice failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.purchases);
  revalidatePath(ROUTES.inventory);
  return actionSuccess(
    { id: row.id, purchase_number: row.purchase_number, gross_total: row.gross_total },
    `تم عكس الفاتورة بالمستند "${row.purchase_number}" وإرجاع كمياتها من المخزون.`,
  );
}

export async function recordSupplierPaymentAction(input: RecordSupplierPaymentInput): Promise<ActionResult<{ id: string; payment_number: string; amount: string; outstanding_after: string }>> {
  await requirePermission("purchases.record_payment");

  const parsed = recordSupplierPaymentSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("record_supplier_payment", {
    p_invoice_id: parsed.data.invoice_id,
    p_amount: parsed.data.amount,
    p_payment_mode: parsed.data.payment_mode,
    p_business_date: parsed.data.business_date,
    p_payment_reference: parsed.data.payment_reference ?? null,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[purchases] record_supplier_payment failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.purchases);
  return actionSuccess(
    { id: row.id, payment_number: row.payment_number, amount: row.amount, outstanding_after: row.outstanding_after },
    `تم تسجيل الدفعة "${row.payment_number}". المتبقي: ${row.outstanding_after}`,
  );
}

export async function reverseSupplierPaymentAction(input: ReverseSupplierPaymentInput): Promise<ActionResult<{ id: string; payment_number: string; amount: string; outstanding_after: string }>> {
  await requirePermission("purchases.reverse_payment");

  const parsed = reverseSupplierPaymentSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reverse_supplier_payment", {
    p_payment_id: parsed.data.payment_id,
    p_reason: parsed.data.reason,
    p_reversal_business_date: parsed.data.business_date,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[purchases] reverse_supplier_payment failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.purchases);
  return actionSuccess(
    { id: row.id, payment_number: row.payment_number, amount: row.amount, outstanding_after: row.outstanding_after },
    `تم عكس الدفعة بالحركة "${row.payment_number}". المتبقي: ${row.outstanding_after}`,
  );
}

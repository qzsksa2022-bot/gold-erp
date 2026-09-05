"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import {
  createExpenseCategorySchema,
  updateExpenseCategorySchema,
  recordStoreExpenseSchema,
  reverseStoreExpenseSchema,
  type CreateExpenseCategoryInput,
  type UpdateExpenseCategoryInput,
  type RecordStoreExpenseInput,
  type ReverseStoreExpenseInput,
} from "./schema";

// Every mutation below goes through a single trusted SECURITY DEFINER RPC
// (migration 0235) — never a raw insert/update, mirroring
// src/features/inventory/actions.ts exactly. expense_categories/store_expenses
// carry zero direct-write RLS policy (Layer-A lockdown, 0234), and
// store_expenses additionally rejects every UPDATE/DELETE at trigger level —
// a raw .from(...).insert/.update would be rejected by Postgres regardless of
// what this file does. Every monetary input stays a string from the browser
// through Zod through this file to the RPC call — never Number().

export async function createExpenseCategoryAction(input: CreateExpenseCategoryInput): Promise<ActionResult<{ id: string; code: string; row_version: number }>> {
  await requirePermission("expenses.manage_categories");

  const parsed = createExpenseCategorySchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_expense_category", {
    p_code: parsed.data.code,
    p_name_ar: parsed.data.name_ar,
    p_name_en: parsed.data.name_en ?? null,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[expenses] create_expense_category failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.expenseCategories);
  return actionSuccess({ id: row.id, code: row.code, row_version: row.row_version }, `تمت إضافة التصنيف "${row.code}" بنجاح.`);
}

export async function updateExpenseCategoryAction(input: UpdateExpenseCategoryInput): Promise<ActionResult<{ id: string; row_version: number }>> {
  await requirePermission("expenses.manage_categories");

  const parsed = updateExpenseCategorySchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("update_expense_category", {
    p_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_name_ar: parsed.data.name_ar,
    p_name_en: parsed.data.name_en ?? null,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[expenses] update_expense_category failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.expenseCategories);
  return actionSuccess({ id: row.id, row_version: row.row_version }, "تم تحديث التصنيف بنجاح.");
}

export async function setExpenseCategoryStatusAction(categoryId: string, nextStatus: "active" | "disabled"): Promise<ActionResult<null>> {
  await requirePermission("expenses.manage_categories");

  const supabase = await createClient();
  const { error } = await supabase.rpc(nextStatus === "disabled" ? "disable_expense_category" : "enable_expense_category", { p_id: categoryId });

  if (error) {
    console.error("[expenses] set expense category status failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.expenseCategories);
  return actionSuccess(null, nextStatus === "disabled" ? "تم تعطيل التصنيف." : "تم تفعيل التصنيف.");
}

export async function recordStoreExpenseAction(input: RecordStoreExpenseInput): Promise<ActionResult<{ id: string; expense_number: string; amount: string }>> {
  await requirePermission("expenses.create");

  const parsed = recordStoreExpenseSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("record_store_expense", {
    p_store_id: parsed.data.store_id,
    p_expense_category_id: parsed.data.expense_category_id,
    // The amount stays a STRING right up to here — PostgREST hands it to a
    // numeric parameter server-side, so it is never seen by a JS float.
    p_amount: parsed.data.amount,
    p_business_date: parsed.data.business_date,
    p_description: parsed.data.description ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[expenses] record_store_expense failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.expenses);
  revalidatePath(ROUTES.dashboard);
  return actionSuccess({ id: row.id, expense_number: row.expense_number, amount: row.amount }, `تم تسجيل المصروف "${row.expense_number}" بنجاح.`);
}

export async function reverseStoreExpenseAction(input: ReverseStoreExpenseInput): Promise<ActionResult<{ id: string; expense_number: string; amount: string }>> {
  await requirePermission("expenses.reverse");

  const parsed = reverseStoreExpenseSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reverse_store_expense", {
    p_expense_id: parsed.data.expense_id,
    p_reason: parsed.data.reason,
    p_reversal_business_date: parsed.data.business_date,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[expenses] reverse_store_expense failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.expenses);
  revalidatePath(ROUTES.dashboard);
  return actionSuccess({ id: row.id, expense_number: row.expense_number, amount: row.amount }, `تم عكس المصروف بالحركة "${row.expense_number}".`);
}

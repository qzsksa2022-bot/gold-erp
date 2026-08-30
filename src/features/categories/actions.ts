"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { categoryFormSchema } from "./schema";
import { ROUTES } from "@/lib/constants";

// Audit logging handled automatically by product_categories_audit_trigger
// (supabase/migrations/0043). Cycle prevention (a category can never become
// its own ancestor) is enforced by prevent_category_cycle() at the DB
// level regardless of what the UI allows the user to pick.

function parseForm(formData: FormData) {
  return categoryFormSchema.safeParse({
    parent_id: formData.get("parent_id"),
    code: formData.get("code"),
    name_ar: formData.get("name_ar"),
    name_en: formData.get("name_en"),
    sort_order: formData.get("sort_order") || undefined,
  });
}

export async function createCategoryAction(
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("categories.manage");

  const parsed = parseForm(formData);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("product_categories")
    .insert({ ...parsed.data, parent_id: parsed.data.parent_id ?? null, created_by: session.userId, updated_by: session.userId })
    .select("id")
    .single();

  if (error) {
    if (error.code === "23505") {
      return actionError("هذا الكود مستخدم بالفعل لتصنيف آخر.", { code: ["هذا الكود مستخدم"] });
    }
    console.error("[categories] create failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataCategories);
  return actionSuccess({ id: data.id }, "تمت إضافة التصنيف بنجاح.");
}

export async function updateCategoryAction(
  categoryId: string,
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("categories.manage");

  const parsed = parseForm(formData);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  if (parsed.data.parent_id === categoryId) {
    return actionError("لا يمكن أن يكون التصنيف أبًا لنفسه.");
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("product_categories")
    .update({ ...parsed.data, parent_id: parsed.data.parent_id ?? null, updated_by: session.userId })
    .eq("id", categoryId)
    .select("id")
    .single();

  if (error) {
    if (error.code === "23505") {
      return actionError("هذا الكود مستخدم بالفعل لتصنيف آخر.", { code: ["هذا الكود مستخدم"] });
    }
    console.error("[categories] update failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataCategories);
  return actionSuccess({ id: data.id }, "تم حفظ التعديلات.");
}

export async function setCategoryStatusAction(categoryId: string, nextStatus: "active" | "inactive"): Promise<ActionResult<null>> {
  const session = await requirePermission("categories.manage");

  const supabase = await createClient();
  const { error } = await supabase
    .from("product_categories")
    .update({ status: nextStatus, updated_by: session.userId })
    .eq("id", categoryId);

  if (error) {
    console.error("[categories] status change failed", error);
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(ROUTES.masterDataCategories);
  return actionSuccess(null, nextStatus === "inactive" ? "تم تعطيل التصنيف." : "تمت إعادة تفعيل التصنيف.");
}

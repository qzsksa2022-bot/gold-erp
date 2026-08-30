"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { storeFormSchema } from "./schema";
import { ROUTES } from "@/lib/constants";

// Audit logging for every mutation below is now handled automatically by
// the stores_audit_trigger (supabase/migrations/0016) — no explicit
// logAuditEvent() call here any more.

function parseForm(formData: FormData) {
  return storeFormSchema.safeParse({
    code: formData.get("code"),
    name_ar: formData.get("name_ar"),
    name_en: formData.get("name_en"),
    description: formData.get("description"),
    logo_url: formData.get("logo_url"),
  });
}

export async function createStoreAction(
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("stores.create");

  const parsed = parseForm(formData);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("stores")
    .insert({ ...parsed.data, created_by: session.userId, updated_by: session.userId })
    .select("id")
    .single();

  if (error) {
    if (error.code === "23505") {
      return actionError("كود المتجر مستخدم بالفعل، الرجاء اختيار كود آخر.", { code: ["هذا الكود مستخدم"] });
    }
    console.error("[stores] create failed", error);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  revalidatePath(ROUTES.stores);
  return actionSuccess({ id: data.id }, "تم إنشاء المتجر بنجاح.");
}

export async function updateStoreAction(
  storeId: string,
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  await requirePermission("stores.edit");

  const parsed = parseForm(formData);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();

  const { data, error } = await supabase
    .from("stores")
    .update({ ...parsed.data })
    .eq("id", storeId)
    .select("id")
    .single();

  if (error) {
    if (error.code === "23505") {
      return actionError("كود المتجر مستخدم بالفعل، الرجاء اختيار كود آخر.", { code: ["هذا الكود مستخدم"] });
    }
    console.error("[stores] update failed", error);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  revalidatePath(ROUTES.stores);
  return actionSuccess({ id: data.id }, "تم حفظ التعديلات.");
}

export async function setStoreStatusAction(storeId: string, nextStatus: "active" | "disabled"): Promise<ActionResult<null>> {
  await requirePermission("stores.disable");

  const supabase = await createClient();
  const { error } = await supabase.from("stores").update({ status: nextStatus }).eq("id", storeId);

  if (error) {
    console.error("[stores] status change failed", error);
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(ROUTES.stores);
  return actionSuccess(null, nextStatus === "disabled" ? "تم تعطيل المتجر." : "تمت إعادة تفعيل المتجر.");
}

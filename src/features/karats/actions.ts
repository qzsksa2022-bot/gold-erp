"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { karatFormSchema } from "./schema";
import { ROUTES } from "@/lib/constants";

// Audit logging for every mutation below is handled automatically by
// karats_audit_trigger (supabase/migrations/0040) — no explicit call here.

function parseForm(formData: FormData) {
  return karatFormSchema.safeParse({
    code: formData.get("code"),
    name_ar: formData.get("name_ar"),
    name_en: formData.get("name_en"),
    purity_per_mille: formData.get("purity_per_mille"),
    sort_order: formData.get("sort_order") || undefined,
  });
}

export async function createKaratAction(
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("karats.manage");

  const parsed = parseForm(formData);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("karats")
    .insert({ ...parsed.data, created_by: session.userId, updated_by: session.userId })
    .select("id")
    .single();

  if (error) {
    if (error.code === "23505") {
      return actionError("هذا الكود مستخدم بالفعل لعيار آخر.", { code: ["هذا الكود مستخدم"] });
    }
    console.error("[karats] create failed", error);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  revalidatePath(ROUTES.masterDataKarats);
  return actionSuccess({ id: data.id }, "تمت إضافة العيار بنجاح.");
}

export async function updateKaratAction(
  karatId: string,
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("karats.manage");

  const parsed = parseForm(formData);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("karats")
    .update({ ...parsed.data, updated_by: session.userId })
    .eq("id", karatId)
    .select("id")
    .single();

  if (error) {
    if (error.code === "23505") {
      return actionError("هذا الكود مستخدم بالفعل لعيار آخر.", { code: ["هذا الكود مستخدم"] });
    }
    console.error("[karats] update failed", error);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  revalidatePath(ROUTES.masterDataKarats);
  return actionSuccess({ id: data.id }, "تم حفظ التعديلات.");
}

export async function setKaratStatusAction(karatId: string, nextStatus: "active" | "inactive"): Promise<ActionResult<null>> {
  const session = await requirePermission("karats.manage");

  const supabase = await createClient();
  const { error } = await supabase.from("karats").update({ status: nextStatus, updated_by: session.userId }).eq("id", karatId);

  if (error) {
    console.error("[karats] status change failed", error);
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(ROUTES.masterDataKarats);
  return actionSuccess(null, nextStatus === "inactive" ? "تم تعطيل العيار." : "تمت إعادة تفعيل العيار.");
}

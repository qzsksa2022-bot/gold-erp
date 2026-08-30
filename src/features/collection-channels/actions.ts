"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { collectionChannelFormSchema } from "./schema";
import { ROUTES } from "@/lib/constants";

// Audit logging handled automatically by collection_channels_audit_trigger
// (supabase/migrations/0046).

function parseForm(formData: FormData) {
  return collectionChannelFormSchema.safeParse({
    key: formData.get("key"),
    name_ar: formData.get("name_ar"),
    name_en: formData.get("name_en"),
    sort_order: formData.get("sort_order") || undefined,
  });
}

export async function createCollectionChannelAction(
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("collection_channels.manage");

  const parsed = parseForm(formData);
  if (!parsed.success || !parsed.data.key) {
    return actionError(
      "تحقق من صحة البيانات المدخلة.",
      parsed.success ? { key: ["المفتاح مطلوب"] } : parsed.error.flatten().fieldErrors,
    );
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("collection_channels")
    .insert({ ...parsed.data, key: parsed.data.key, created_by: session.userId, updated_by: session.userId })
    .select("id")
    .single();

  if (error) {
    if (error.code === "23505") {
      return actionError("هذا المفتاح مستخدم بالفعل.", { key: ["هذا المفتاح مستخدم"] });
    }
    console.error("[collection-channels] create failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataCollectionChannels);
  return actionSuccess({ id: data.id }, "تمت إضافة قناة التحصيل بنجاح.");
}

export async function updateCollectionChannelAction(
  channelId: string,
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("collection_channels.manage");

  const parsed = parseForm(formData);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const { key: _key, ...updateData } = parsed.data;
  void _key;

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("collection_channels")
    .update({ ...updateData, updated_by: session.userId })
    .eq("id", channelId)
    .select("id")
    .single();

  if (error) {
    console.error("[collection-channels] update failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataCollectionChannels);
  return actionSuccess({ id: data.id }, "تم حفظ التعديلات.");
}

export async function setCollectionChannelStatusAction(
  channelId: string,
  nextStatus: "active" | "inactive",
): Promise<ActionResult<null>> {
  const session = await requirePermission("collection_channels.manage");

  const supabase = await createClient();
  const { error } = await supabase
    .from("collection_channels")
    .update({ status: nextStatus, updated_by: session.userId })
    .eq("id", channelId);

  if (error) {
    console.error("[collection-channels] status change failed", error);
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(ROUTES.masterDataCollectionChannels);
  return actionSuccess(null, nextStatus === "inactive" ? "تم تعطيل قناة التحصيل." : "تمت إعادة تفعيل قناة التحصيل.");
}

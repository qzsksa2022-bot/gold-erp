"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";

// Audit logging for every settings change below is now handled
// automatically by the system_settings_audit_trigger (supabase/migrations/
// 0016) — no explicit logAuditEvent() call here any more.
import { generalSettingsSchema, appearanceSettingsSchema, securitySettingsSchema } from "./schema";
import { ROUTES } from "@/lib/constants";

async function upsertCategory(
  category: string,
  values: Record<string, unknown>,
  updatedBy: string,
) {
  const supabase = await createClient();
  const rows = Object.entries(values).map(([key, value]) => ({ category, key, value: value as never, updated_by: updatedBy }));
  const { error } = await supabase.from("system_settings").upsert(rows, { onConflict: "category,key" });
  return error;
}

export async function updateGeneralSettingsAction(
  _prevState: ActionResult<null> | null,
  formData: FormData,
): Promise<ActionResult<null>> {
  const session = await requirePermission("settings.manage");

  const parsed = generalSettingsSchema.safeParse({
    system_name_ar: formData.get("system_name_ar"),
    system_name_en: formData.get("system_name_en"),
    currency: formData.get("currency"),
    timezone: formData.get("timezone"),
  });
  if (!parsed.success) return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);

  const error = await upsertCategory("general", parsed.data, session.userId);
  if (error) {
    console.error("[settings] general update failed", error);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  revalidatePath(ROUTES.settings);
  revalidatePath("/", "layout");
  return actionSuccess(null, "تم حفظ الإعدادات العامة.");
}

export async function updateAppearanceSettingsAction(
  _prevState: ActionResult<null> | null,
  formData: FormData,
): Promise<ActionResult<null>> {
  const session = await requirePermission("settings.manage");

  const parsed = appearanceSettingsSchema.safeParse({
    logo_url: formData.get("logo_url"),
    accent_color: formData.get("accent_color"),
    font_family: formData.get("font_family"),
  });
  if (!parsed.success) return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);

  const error = await upsertCategory("appearance", parsed.data, session.userId);
  if (error) {
    console.error("[settings] appearance update failed", error);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  revalidatePath(ROUTES.settings);
  revalidatePath("/", "layout");
  return actionSuccess(null, "تم حفظ إعدادات المظهر.");
}

export async function updateSecuritySettingsAction(
  _prevState: ActionResult<null> | null,
  formData: FormData,
): Promise<ActionResult<null>> {
  const session = await requirePermission("settings.manage");

  const parsed = securitySettingsSchema.safeParse({
    two_factor_enabled: formData.get("two_factor_enabled") === "on",
    session_timeout_minutes: formData.get("session_timeout_minutes"),
  });
  if (!parsed.success) return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);

  const error = await upsertCategory("security", parsed.data, session.userId);
  if (error) {
    console.error("[settings] security update failed", error);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  revalidatePath(ROUTES.settings);
  return actionSuccess(null, "تم حفظ إعدادات الأمان.");
}

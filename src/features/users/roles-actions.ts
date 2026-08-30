"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { roleFormSchema } from "./schema";
import { ROUTES } from "@/lib/constants";
import { countUsersForRole } from "./queries";

// Audit logging for every mutation below is now handled automatically by
// the roles_audit_trigger / role_permissions_audit_trigger (supabase/
// migrations/0016) — no explicit logAuditEvent() call here any more.

/** Generates a stable, unique-enough machine key for a custom role. Never
 * shown in the UI and never branched on in app code (only 'super_admin' is
 * special-cased) — it exists purely to satisfy the `roles.key` NOT NULL
 * UNIQUE column. */
function generateRoleKey(nameEn: string | undefined, nameAr: string) {
  const base = (nameEn || nameAr)
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9؀-ۿ]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 40);
  return `custom_${base || "role"}_${crypto.randomUUID().slice(0, 8)}`;
}

export async function createRoleAction(
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("users.manage_permissions");

  const parsed = roleFormSchema.safeParse({
    name_ar: formData.get("name_ar"),
    name_en: formData.get("name_en"),
    description_ar: formData.get("description_ar"),
  });

  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const key = generateRoleKey(parsed.data.name_en, parsed.data.name_ar);

  const { data, error } = await supabase
    .from("roles")
    .insert({ ...parsed.data, key, is_system: false, created_by: session.userId, updated_by: session.userId })
    .select("id")
    .single();

  if (error) {
    console.error("[roles] create failed", error);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  revalidatePath(ROUTES.users);
  return actionSuccess({ id: data.id }, "تم إنشاء الدور.");
}

export async function updateRoleAction(
  roleId: string,
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  await requirePermission("users.manage_permissions");

  const parsed = roleFormSchema.safeParse({
    name_ar: formData.get("name_ar"),
    name_en: formData.get("name_en"),
    description_ar: formData.get("description_ar"),
  });

  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { error } = await supabase.from("roles").update(parsed.data).eq("id", roleId);
  if (error) {
    console.error("[roles] update failed", error);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  revalidatePath(ROUTES.users);
  return actionSuccess({ id: roleId }, "تم حفظ التعديلات.");
}

export async function deleteRoleAction(roleId: string): Promise<ActionResult<null>> {
  await requirePermission("users.manage_permissions");

  const usersCount = await countUsersForRole(roleId);
  if (usersCount > 0) {
    return actionError(`لا يمكن حذف هذا الدور، هو مُسند حاليًا إلى ${usersCount} مستخدم.`);
  }

  const supabase = await createClient();
  const { error } = await supabase.from("roles").delete().eq("id", roleId);

  if (error) {
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(ROUTES.users);
  return actionSuccess(null, "تم حذف الدور.");
}

export async function toggleRolePermissionAction(roleId: string, permissionId: string, enabled: boolean): Promise<ActionResult<null>> {
  await requirePermission("users.manage_permissions");
  const supabase = await createClient();

  if (enabled) {
    const { error } = await supabase.from("role_permissions").insert({ role_id: roleId, permission_id: permissionId });
    if (error && error.code !== "23505") return actionError(dbErrorMessage(error));
  } else {
    const { error } = await supabase.from("role_permissions").delete().eq("role_id", roleId).eq("permission_id", permissionId);
    if (error) return actionError(dbErrorMessage(error));
  }

  revalidatePath(ROUTES.users);
  return actionSuccess(null, undefined);
}

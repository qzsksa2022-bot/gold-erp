"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { createUserSchema, updateUserProfileSchema, updateUserStoreScopeSchema } from "./schema";
import { ROUTES } from "@/lib/constants";

// Audit logging for every table-backed change below (profile edits, role
// assignment, permission overrides, store access, status changes) is now
// handled automatically by database triggers (supabase/migrations/0016) —
// no explicit logAuditEvent() call is needed or even possible any more from
// `authenticated` context (that RPC is service_role-only as of 0016). The
// one exception is user creation's audit attribution, which is handled by
// finalize_new_user_profile() itself running under the acting admin's own
// session (see createUserAction below) rather than by an app-layer call.

function usersPath(userId?: string) {
  return userId ? `${ROUTES.users}/${userId}` : ROUTES.users;
}

// ---------------------------------------------------------------------------
// Create / edit / status
// ---------------------------------------------------------------------------

export async function createUserAction(
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  await requirePermission("users.create");

  const parsed = createUserSchema.safeParse({
    full_name: formData.get("full_name"),
    email: formData.get("email"),
    password: formData.get("password"),
    default_store_id: formData.get("default_store_id"),
    store_access_scope: formData.get("store_access_scope") || "single",
  });

  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const { full_name, email, password, default_store_id, store_access_scope } = parsed.data;

  // Step 1: Admin API required to create the auth.users row — no way around
  // that, only the service-role client can do it. 0011's safety-net trigger
  // fires immediately after and creates a matching 'suspended' profiles row.
  const admin = createAdminClient();

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name },
  });

  if (createError || !created.user) {
    if (createError?.message?.toLowerCase().includes("already")) {
      return actionError("هذا البريد الإلكتروني مستخدم بالفعل.", { email: ["البريد الإلكتروني مستخدم بالفعل"] });
    }
    console.error("[users] createUser failed", createError);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  // Step 2: activate the profile via finalize_new_user_profile() (0016) on
  // the REGULAR session-bound client — deliberately NOT the admin client.
  // Running this as the acting admin's own session means auth.uid() is
  // correct, so the profiles audit trigger attributes the resulting
  // user.create event to the admin who actually did this, and the
  // function's own has_permission('users.create') check stands in for the
  // RLS check a normal client-side UPDATE would otherwise need.
  const supabase = await createClient();
  const { error: finalizeError } = await supabase.rpc("finalize_new_user_profile", {
    p_user_id: created.user.id,
    p_full_name: full_name,
    p_default_store_id: default_store_id ?? null,
    p_store_access_scope: store_access_scope,
  });

  if (finalizeError) {
    // Compensation: step 1 already created a real auth.users row. If we
    // cannot also activate its profile, do not leave an orphaned,
    // permanently-suspended account behind with no way to complete or
    // retry — delete the auth user so the operation fails atomically from
    // the caller's point of view (the ON DELETE CASCADE from profiles.id
    // to auth.users.id also removes the now-pointless suspended profile
    // row). The admin can simply try again after this returns an error.
    console.error("[users] finalize_new_user_profile failed, rolling back auth user", finalizeError);
    const { error: cleanupError } = await admin.auth.admin.deleteUser(created.user.id);
    if (cleanupError) {
      // Extremely unlikely (would mean the Admin API itself is failing),
      // but if cleanup ALSO fails we must not claim success — surface a
      // distinct message so this doesn't look like a routine validation
      // error and gets investigated instead of silently retried forever.
      console.error("[users] rollback of orphaned auth user also failed", cleanupError);
      return actionError("حدث خطأ غير متوقع أثناء إنشاء المستخدم. الرجاء التواصل مع الدعم الفني قبل إعادة المحاولة.");
    }
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  revalidatePath(ROUTES.users);
  return actionSuccess({ id: created.user.id }, "تم إنشاء المستخدم بنجاح. لا تنسَ إسناد دور له.");
}

// Foundation Hardening 1.3, item 2e / item 3: split into two independent
// actions, one per DB-layer column-authorization group (supabase/migrations/
// 0030) — full_name requires users.edit; store scope requires
// users.manage_store_access ONLY. Splitting the Server Action (not just the
// form) means an actor holding only one of the two permissions gets a
// working, correctly-scoped action instead of a combined UPDATE the
// database would now reject for lacking the other permission.

export async function updateUserProfileAction(
  userId: string,
  _prevState: ActionResult<null> | null,
  formData: FormData,
): Promise<ActionResult<null>> {
  await requirePermission("users.edit");

  const parsed = updateUserProfileSchema.safeParse({
    full_name: formData.get("full_name"),
  });

  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();

  // No manual "fetch before, log after" needed here any more — the
  // profiles_audit_trigger (0016) captures old_values/new_values itself,
  // atomically, in the same transaction as the UPDATE below.
  const { error } = await supabase.from("profiles").update(parsed.data).eq("id", userId);

  if (error) {
    console.error("[users] update profile failed", error);
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(usersPath(userId));
  return actionSuccess(null, "تم حفظ التعديلات.");
}

export async function updateUserStoreScopeAction(
  userId: string,
  _prevState: ActionResult<null> | null,
  formData: FormData,
): Promise<ActionResult<null>> {
  await requirePermission("users.manage_store_access");

  const parsed = updateUserStoreScopeSchema.safeParse({
    default_store_id: formData.get("default_store_id"),
    store_access_scope: formData.get("store_access_scope"),
  });

  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();

  const { error } = await supabase
    .from("profiles")
    .update({ ...parsed.data, default_store_id: parsed.data.default_store_id ?? null })
    .eq("id", userId);

  if (error) {
    console.error("[users] update store scope failed", error);
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(usersPath(userId));
  return actionSuccess(null, "تم حفظ نطاق الوصول للمتاجر.");
}

// Foundation Hardening 1.4, item 5: cancelling a pending_setup invite is no
// longer a status UPDATE (supabase/migrations/0036 rejects pending_setup ->
// suspended at the database layer outright -- it used to strand the
// underlying auth.users row with no path to ever complete or reactivate it).
// The only correct way to cancel an invite is to delete the still-
// unprovisioned auth user via the trusted service-role Admin API; ON DELETE
// CASCADE (profiles.id -> auth.users.id, 0002) removes the matching
// profiles row in the same operation.
export async function cancelUserInviteAction(userId: string): Promise<ActionResult<null>> {
  // Foundation Audit Hotfix 1.4.2: capture the REAL actor id here, from the
  // acting staff member's own verified session (requirePermission() calls
  // getCurrentSession(), which resolves the user via supabase.auth.getUser()
  // -- a server-verified JWT, not client-supplied input) -- BEFORE the admin
  // client is touched at all. This is the only trustworthy source for "who
  // is actually doing this"; the admin client used below has no auth.uid()
  // of its own to read.
  const session = await requirePermission("users.disable");
  const actorUserId = session.userId;

  const admin = createAdminClient();

  // Server-side safety check, independent of whatever the caller believes
  // the user's status is: this action must NEVER be usable to delete a
  // real, already-provisioned account -- only a still-pending_setup,
  // never-provisioned row qualifies. The admin client bypasses RLS, so this
  // explicit re-check is the only thing standing between "cancel invite"
  // and "delete any user".
  const { data: profile, error: fetchError } = await admin
    .from("profiles")
    .select("status, provisioned_at")
    .eq("id", userId)
    .maybeSingle();

  if (fetchError || !profile) {
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  if (profile.status !== "pending_setup" || profile.provisioned_at !== null) {
    return actionError("لا يمكن إلغاء الدعوة — هذا الحساب مكتمل التزويد بالفعل وليس دعوة قيد الانتظار.");
  }

  // Foundation Audit Hotfix 1.4.2: delete FIRST, log SECOND -- reversed from
  // Patch 1.4.1's original order. log_user_invite_cancel() (0038) is now
  // SUPERSEDED -- `authenticated` no longer has EXECUTE on it at all, closing
  // the gap where any staff member holding users.disable could call it
  // directly and write a false "cancelled" record without actually
  // cancelling anything. The real deletion is the source of truth; the audit
  // event now only gets written once that has actually happened.
  const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
  if (deleteError) {
    console.error("[users] cancelUserInviteAction delete failed", deleteError);
    return actionError(GENERIC_ERROR_MESSAGE_AR);
  }

  // Deletion succeeded -- the account is gone regardless of what happens
  // next. Log via the new trusted, service_role-only RPC (0039), which
  // independently re-verifies (a) the target profile no longer exists (ties
  // the event structurally to a completed deletion, not just to call
  // ordering) and (b) the supplied actor still holds users.disable. It is
  // idempotent (a partial unique index on audit_logs allows at most one
  // user.invite_cancel row per target ever), so a retry of this action after
  // a dropped response cannot double-log the same cancellation.
  const { error: auditError } = await admin.rpc("log_user_invite_cancel_trusted", {
    p_actor_user_id: actorUserId,
    p_target_user_id: userId,
    p_reason: null,
  });

  if (auditError) {
    // The deletion already succeeded and cannot be undone -- returning a
    // failure here would wrongly suggest nothing happened and could prompt
    // a retry that fails confusingly (the account is already gone). Surface
    // this loudly server-side for operators instead of misleading the
    // caller; the cancellation itself is complete either way.
    console.error("[users] log_user_invite_cancel_trusted failed after successful deletion", auditError);
  }

  revalidatePath(ROUTES.users);
  return actionSuccess(null, "تم إلغاء الدعوة وحذف الحساب غير المكتمل نهائيًا.");
}

export async function setUserStatusAction(userId: string, nextStatus: "active" | "suspended"): Promise<ActionResult<null>> {
  await requirePermission("users.disable");

  const supabase = await createClient();
  const { error } = await supabase.from("profiles").update({ status: nextStatus }).eq("id", userId);

  if (error) {
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(usersPath(userId));
  revalidatePath(ROUTES.users);
  return actionSuccess(null, nextStatus === "suspended" ? "تم تعطيل المستخدم." : "تمت إعادة تفعيل المستخدم.");
}

// ---------------------------------------------------------------------------
// Role assignment (requires users.manage_permissions; uses the REGULAR
// session-bound client — NOT the admin client — so RLS and the
// privilege-escalation / last-super-admin DB triggers apply exactly as they
// would for any other authenticated write. See supabase/migrations/0009.)
// ---------------------------------------------------------------------------

export async function assignRoleAction(userId: string, roleId: string): Promise<ActionResult<null>> {
  const session = await requirePermission("users.manage_permissions");
  const supabase = await createClient();

  const { error } = await supabase.from("user_roles").insert({ user_id: userId, role_id: roleId, created_by: session.userId });

  if (error) {
    if (error.code === "23505") return actionError("هذا الدور مُسند بالفعل لهذا المستخدم.");
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(usersPath(userId));
  return actionSuccess(null, "تم إسناد الدور.");
}

export async function removeRoleAction(userId: string, roleId: string): Promise<ActionResult<null>> {
  await requirePermission("users.manage_permissions");
  const supabase = await createClient();

  const { error } = await supabase.from("user_roles").delete().eq("user_id", userId).eq("role_id", roleId);

  if (error) {
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(usersPath(userId));
  return actionSuccess(null, "تم إلغاء إسناد الدور.");
}

// ---------------------------------------------------------------------------
// Per-user permission overrides
// ---------------------------------------------------------------------------

export async function setPermissionOverrideAction(
  userId: string,
  permissionId: string,
  effect: "grant" | "revoke" | "clear",
): Promise<ActionResult<null>> {
  const session = await requirePermission("users.manage_permissions");
  const supabase = await createClient();

  if (effect === "clear") {
    const { error } = await supabase
      .from("user_permission_overrides")
      .delete()
      .eq("user_id", userId)
      .eq("permission_id", permissionId);
    if (error) return actionError(dbErrorMessage(error));
  } else {
    const { error } = await supabase
      .from("user_permission_overrides")
      .upsert(
        { user_id: userId, permission_id: permissionId, effect, created_by: session.userId },
        { onConflict: "user_id,permission_id" },
      );
    if (error) return actionError(dbErrorMessage(error));
  }

  revalidatePath(usersPath(userId));
  return actionSuccess(null, "تم تحديث الصلاحية.");
}

// ---------------------------------------------------------------------------
// Store access
// ---------------------------------------------------------------------------

export async function setUserStoreAccessAction(userId: string, storeIds: string[]): Promise<ActionResult<null>> {
  // Patch 1.4.1, item 1: users.manage_store_access is now the ONLY
  // permission that can manage Store Access -- users.manage_permissions
  // used to also work here (RLS OR-combined 0010's original
  // user_store_access_insert/delete policies with 0018's scoped ones), but
  // that was an unintended overlap, not an intentional alternate path (see
  // supabase/migrations/0037's header comment). The database now rejects
  // users.manage_permissions-only writes to user_store_access at both the
  // RLS and trigger layers regardless of what this app-layer guard does,
  // but the guard is narrowed to match so the error surfaces immediately
  // with the right message instead of a generic database rejection.
  await requirePermission("users.manage_store_access");
  const supabase = await createClient();

  // Single atomic RPC (supabase/migrations/0018's replace_user_store_access)
  // instead of a client-computed insert-then-delete: either every grant/
  // revoke in this batch applies, or none does, and every store in
  // storeIds is still independently subject to the delegation-limit and
  // self-block triggers exactly as a direct REST call would be (the RPC is
  // SECURITY INVOKER, not a privileged bypass).
  const { error } = await supabase.rpc("replace_user_store_access", {
    p_user_id: userId,
    p_store_ids: storeIds,
  });

  if (error) {
    console.error("[users] replace_user_store_access failed", error);
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(usersPath(userId));
  return actionSuccess(null, "تم تحديث وصول المتاجر.");
}

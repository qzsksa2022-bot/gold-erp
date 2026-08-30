"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import { paymentMethodFeeVersionSchema, paymentMethodFormSchema } from "./schema";

// Audit logging is automatic (payment_methods_audit_trigger /
// payment_method_fee_versions_audit_trigger, supabase/migrations/0044-0045).
// Fee rate changes ALWAYS go through create_payment_method_fee_version() /
// cancel_payment_method_fee_version() — never a raw insert/update on
// payment_method_fee_versions — so a rate that already took effect can
// never be silently rewritten.

export async function createPaymentMethodAction(
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("payment_methods.manage");

  const parsed = paymentMethodFormSchema.safeParse({
    key: formData.get("key"),
    name_ar: formData.get("name_ar"),
    name_en: formData.get("name_en"),
    fee_model: formData.get("fee_model"),
    supports_refunds: formData.get("supports_refunds") === "on",
    refund_fee_policy: formData.get("refund_fee_policy"),
    sort_order: formData.get("sort_order") || undefined,
  });

  if (!parsed.success || !parsed.data.key) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.success ? { key: ["المفتاح مطلوب"] } : parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("payment_methods")
    .insert({ ...parsed.data, key: parsed.data.key, created_by: session.userId, updated_by: session.userId })
    .select("id")
    .single();

  if (error) {
    if (error.code === "23505") {
      return actionError("هذا المفتاح مستخدم بالفعل.", { key: ["هذا المفتاح مستخدم"] });
    }
    console.error("[payment-methods] create failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataPaymentMethods);
  return actionSuccess({ id: data.id }, "تمت إضافة طريقة الدفع بنجاح.");
}

export async function updatePaymentMethodAction(
  methodId: string,
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("payment_methods.manage");

  const parsed = paymentMethodFormSchema.safeParse({
    name_ar: formData.get("name_ar"),
    name_en: formData.get("name_en"),
    fee_model: formData.get("fee_model"),
    supports_refunds: formData.get("supports_refunds") === "on",
    refund_fee_policy: formData.get("refund_fee_policy"),
    sort_order: formData.get("sort_order") || undefined,
  });

  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const { key: _key, ...updateData } = parsed.data;
  void _key;

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("payment_methods")
    .update({ ...updateData, updated_by: session.userId })
    .eq("id", methodId)
    .select("id")
    .single();

  if (error) {
    console.error("[payment-methods] update failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataPaymentMethods);
  return actionSuccess({ id: data.id }, "تم حفظ التعديلات.");
}

export async function setPaymentMethodStatusAction(methodId: string, nextStatus: "active" | "inactive"): Promise<ActionResult<null>> {
  const session = await requirePermission("payment_methods.manage");

  const supabase = await createClient();
  const { error } = await supabase
    .from("payment_methods")
    .update({ status: nextStatus, updated_by: session.userId })
    .eq("id", methodId);

  if (error) {
    console.error("[payment-methods] status change failed", error);
    return actionError(dbErrorMessage(error));
  }

  revalidatePath(ROUTES.masterDataPaymentMethods);
  return actionSuccess(null, nextStatus === "inactive" ? "تم تعطيل طريقة الدفع." : "تمت إعادة تفعيل طريقة الدفع.");
}

export async function createPaymentMethodFeeVersionAction(
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  await requirePermission("payment_methods.manage");

  const parsed = paymentMethodFeeVersionSchema.safeParse({
    payment_method_id: formData.get("payment_method_id"),
    percentage_fee: formData.get("percentage_fee"),
    fixed_fee: formData.get("fixed_fee"),
    effective_from: formData.get("effective_from"),
    notes: formData.get("notes"),
  });

  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_payment_method_fee_version", {
    p_payment_method_id: parsed.data.payment_method_id,
    p_percentage_fee: parsed.data.percentage_fee,
    p_fixed_fee: parsed.data.fixed_fee,
    p_effective_from: parsed.data.effective_from,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[payment-methods] create fee version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataPaymentMethods);
  return actionSuccess({ id: data as string }, "تم إنشاء إصدار العمولة الجديد بنجاح.");
}

export async function cancelPaymentMethodFeeVersionAction(versionId: string): Promise<ActionResult<null>> {
  await requirePermission("payment_methods.manage");

  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_payment_method_fee_version", { p_version_id: versionId });

  if (error) {
    console.error("[payment-methods] cancel fee version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataPaymentMethods);
  return actionSuccess(null, "تم إلغاء الإصدار المستقبلي.");
}

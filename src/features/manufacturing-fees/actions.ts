"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import { manufacturingFeeVersionSchema } from "./schema";

// Every mutation below goes through the create_manufacturing_fee_version /
// cancel_manufacturing_fee_version RPCs (supabase/migrations/0042) — never
// a raw insert/update — so the "end the old version atomically, never edit
// a rate that already took effect" guarantee holds regardless of how this
// action is called. Audit logging is automatic via
// manufacturing_fee_versions_audit_trigger.

export async function createManufacturingFeeVersionAction(
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  await requirePermission("manufacturing_fees.manage");

  const parsed = manufacturingFeeVersionSchema.safeParse({
    karat_id: formData.get("karat_id"),
    fee_per_gram: formData.get("fee_per_gram"),
    effective_from: formData.get("effective_from"),
    notes: formData.get("notes"),
  });

  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_manufacturing_fee_version", {
    p_karat_id: parsed.data.karat_id,
    p_fee_per_gram: parsed.data.fee_per_gram,
    p_effective_from: parsed.data.effective_from,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[manufacturing-fees] create version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataManufacturingFees);
  return actionSuccess({ id: data as string }, "تم إنشاء إصدار المصنعية الجديد بنجاح.");
}

export async function cancelManufacturingFeeVersionAction(versionId: string): Promise<ActionResult<null>> {
  await requirePermission("manufacturing_fees.manage");

  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_manufacturing_fee_version", { p_version_id: versionId });

  if (error) {
    console.error("[manufacturing-fees] cancel version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataManufacturingFees);
  return actionSuccess(null, "تم إلغاء الإصدار المستقبلي.");
}

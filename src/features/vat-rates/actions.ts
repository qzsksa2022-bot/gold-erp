"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import { vatRateVersionSchema } from "./schema";

// Hotfix 10.1.0 — every mutation below goes through the EXISTING
// create_vat_rate_version / cancel_vat_rate_version RPCs (supabase/migrations/
// 0058, hardened in 0066 to take the exclusive financial-master lock) — never
// a raw insert/update. No VAT calculation is redefined here and no migration
// was added: this hotfix only builds the missing UI over a backend that was
// already complete.
//
// Audit logging is automatic via the vat_rate_versions audit trigger, so the
// pre-existing `vat_rate_version.create` / `vat_rate_version.update` action
// labels (src/lib/audit/action-labels.ts) start resolving real events instead
// of anticipating ones the app could never produce.

export async function createVatRateVersionAction(
  _prevState: ActionResult<{ id: string }> | null,
  formData: FormData,
): Promise<ActionResult<{ id: string }>> {
  await requirePermission("vat_rates.manage");

  const parsed = vatRateVersionSchema.safeParse({
    rate_percent: formData.get("rate_percent"),
    effective_from: formData.get("effective_from"),
    // `FormData.get()` returns null for an absent field, and the optional
    // notes schema accepts `string | undefined` — not null. The dialog always
    // renders the textarea so it is never absent there, but a Server Action
    // can be invoked with any FormData, and a null here would otherwise fail
    // validation for a field the caller simply did not supply.
    notes: formData.get("notes") ?? undefined,
  });

  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_vat_rate_version", {
    // The rate stays a STRING right up to here — PostgREST hands it to a
    // numeric parameter server-side, so it is never seen by a JS float.
    p_rate_percent: parsed.data.rate_percent,
    p_effective_from: parsed.data.effective_from,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[vat-rates] create version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataVatRates);
  return actionSuccess({ id: data as string }, "تم إنشاء إصدار ضريبة القيمة المضافة الجديد بنجاح.");
}

export async function cancelVatRateVersionAction(versionId: string): Promise<ActionResult<null>> {
  await requirePermission("vat_rates.manage");

  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_vat_rate_version", { p_version_id: versionId });

  if (error) {
    console.error("[vat-rates] cancel version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataVatRates);
  return actionSuccess(null, "تم إلغاء الإصدار المستقبلي.");
}

"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import {
  shippingCarrierFormSchema,
  shippingZoneFormSchema,
  shippingCarrierRateVersionFormSchema,
  customerReturnShippingFeeVersionFormSchema,
} from "./schema";

// Carrier/zone CRUD below is a direct Supabase table insert/update, gated
// by RLS on shipping_rates.manage (0113) — code is never sent on update
// (immutable after creation, enforced DB-side by 0124's trigger, so
// attempting it would fail loudly rather than silently). Audit logging is
// automatic via audit_shipping_master_data_changes (0124). Rate/return-fee
// VERSION writes below go through create_*/cancel_* RPCs ONLY (0114/0115/
//0122) — never a raw table write, matching item 1's RLS lockdown.

// ---------------------------------------------------------------------------
// shipping_carriers
// ---------------------------------------------------------------------------
export async function createShippingCarrierAction(input: unknown): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("shipping_rates.manage");

  const parsed = shippingCarrierFormSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("shipping_carriers")
    .insert({
      code: parsed.data.code,
      name_ar: parsed.data.name_ar,
      name_en: parsed.data.name_en ?? null,
      carrier_type: parsed.data.carrier_type,
      notes: parsed.data.notes ?? null,
      created_by: session.userId,
      updated_by: session.userId,
    })
    .select("id")
    .single();

  if (error) {
    if (error.code === "23505") {
      return actionError("هذا الكود مستخدم بالفعل لشركة شحن أخرى.", { code: ["هذا الكود مستخدم"] });
    }
    console.error("[shipping-rates] create carrier failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataShippingRates);
  return actionSuccess({ id: data.id }, "تمت إضافة شركة الشحن بنجاح.");
}

export async function updateShippingCarrierAction(carrierId: string, input: unknown): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("shipping_rates.manage");

  // code is deliberately NOT part of this schema's writable surface here —
  // shippingCarrierFormSchema still validates it (shared with create) but
  // update intentionally drops it before the table write, matching 0124's
  // immutability trigger rather than relying on the trigger alone to catch it.
  const parsed = shippingCarrierFormSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("shipping_carriers")
    .update({
      name_ar: parsed.data.name_ar,
      name_en: parsed.data.name_en ?? null,
      carrier_type: parsed.data.carrier_type,
      notes: parsed.data.notes ?? null,
      updated_by: session.userId,
    })
    .eq("id", carrierId)
    .select("id")
    .single();

  if (error) {
    console.error("[shipping-rates] update carrier failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataShippingRates);
  return actionSuccess({ id: data.id }, "تم حفظ التعديلات.");
}

export async function setShippingCarrierStatusAction(carrierId: string, nextStatus: "active" | "disabled"): Promise<ActionResult<null>> {
  const session = await requirePermission("shipping_rates.manage");

  const supabase = await createClient();
  const { error } = await supabase.from("shipping_carriers").update({ status: nextStatus, updated_by: session.userId }).eq("id", carrierId);

  if (error) {
    console.error("[shipping-rates] carrier status change failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataShippingRates);
  return actionSuccess(null, nextStatus === "disabled" ? "تم تعطيل شركة الشحن." : "تمت إعادة تفعيل شركة الشحن.");
}

// ---------------------------------------------------------------------------
// shipping_zones
// ---------------------------------------------------------------------------
export async function createShippingZoneAction(input: unknown): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("shipping_rates.manage");

  const parsed = shippingZoneFormSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("shipping_zones")
    .insert({
      code: parsed.data.code,
      name_ar: parsed.data.name_ar,
      name_en: parsed.data.name_en ?? null,
      sort_order: parsed.data.sort_order ?? 0,
      notes: parsed.data.notes ?? null,
      created_by: session.userId,
      updated_by: session.userId,
    })
    .select("id")
    .single();

  if (error) {
    if (error.code === "23505") {
      return actionError("هذا الكود مستخدم بالفعل لمنطقة أخرى.", { code: ["هذا الكود مستخدم"] });
    }
    console.error("[shipping-rates] create zone failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataShippingRates);
  return actionSuccess({ id: data.id }, "تمت إضافة المنطقة بنجاح.");
}

export async function updateShippingZoneAction(zoneId: string, input: unknown): Promise<ActionResult<{ id: string }>> {
  const session = await requirePermission("shipping_rates.manage");

  const parsed = shippingZoneFormSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("shipping_zones")
    .update({
      name_ar: parsed.data.name_ar,
      name_en: parsed.data.name_en ?? null,
      sort_order: parsed.data.sort_order ?? 0,
      notes: parsed.data.notes ?? null,
      updated_by: session.userId,
    })
    .eq("id", zoneId)
    .select("id")
    .single();

  if (error) {
    console.error("[shipping-rates] update zone failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataShippingRates);
  return actionSuccess({ id: data.id }, "تم حفظ التعديلات.");
}

export async function setShippingZoneStatusAction(zoneId: string, nextStatus: "active" | "disabled"): Promise<ActionResult<null>> {
  const session = await requirePermission("shipping_rates.manage");

  const supabase = await createClient();
  const { error } = await supabase.from("shipping_zones").update({ status: nextStatus, updated_by: session.userId }).eq("id", zoneId);

  if (error) {
    console.error("[shipping-rates] zone status change failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataShippingRates);
  return actionSuccess(null, nextStatus === "disabled" ? "تم تعطيل المنطقة." : "تمت إعادة تفعيل المنطقة.");
}

// ---------------------------------------------------------------------------
// shipping_carrier_rate_versions — RPC only (migrations 0114/0122).
// ---------------------------------------------------------------------------
export async function createShippingCarrierRateVersionAction(input: unknown): Promise<ActionResult<{ id: string }>> {
  await requirePermission("shipping_rates.manage");

  const parsed = shippingCarrierRateVersionFormSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_shipping_carrier_rate_version", {
    p_carrier_id: parsed.data.carrier_id,
    p_shipping_zone_id: parsed.data.shipping_zone_id,
    p_direction: parsed.data.direction,
    p_base_cost: parsed.data.base_cost,
    p_effective_from: parsed.data.effective_from,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[shipping-rates] create rate version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataShippingRates);
  return actionSuccess({ id: data as string }, "تم إنشاء إصدار تسعير جديد بنجاح.");
}

export async function cancelShippingCarrierRateVersionAction(versionId: string): Promise<ActionResult<null>> {
  await requirePermission("shipping_rates.manage");

  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_shipping_carrier_rate_version", { p_version_id: versionId });

  if (error) {
    console.error("[shipping-rates] cancel rate version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataShippingRates);
  return actionSuccess(null, "تم إلغاء الإصدار المستقبلي.");
}

// ---------------------------------------------------------------------------
// customer_return_shipping_fee_versions — RPC only (migrations 0115/0122).
// ---------------------------------------------------------------------------
export async function createCustomerReturnShippingFeeVersionAction(input: unknown): Promise<ActionResult<{ id: string }>> {
  await requirePermission("shipping_rates.manage");

  const parsed = customerReturnShippingFeeVersionFormSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_customer_return_shipping_fee_version", {
    p_shipping_zone_id: parsed.data.shipping_zone_id,
    p_fee_amount: parsed.data.fee_amount,
    p_effective_from: parsed.data.effective_from,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[shipping-rates] create return fee version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataShippingRates);
  return actionSuccess({ id: data as string }, "تم إنشاء إصدار رسوم إرجاع جديد بنجاح.");
}

export async function cancelCustomerReturnShippingFeeVersionAction(versionId: string): Promise<ActionResult<null>> {
  await requirePermission("shipping_rates.manage");

  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_customer_return_shipping_fee_version", { p_version_id: versionId });

  if (error) {
    console.error("[shipping-rates] cancel return fee version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataShippingRates);
  return actionSuccess(null, "تم إلغاء الإصدار المستقبلي.");
}

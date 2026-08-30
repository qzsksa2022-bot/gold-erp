"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import {
  createSettlementRouteSchema,
  updateSettlementRouteSchema,
  createSettlementRouteFeeVersionSchema,
  createDraftSettlementBatchSchema,
  updateDraftSettlementBatchSchema,
  finalizeSettlementBatchSchema,
  recordSettlementBankMovementSchema,
  reverseSettlementBankMovementSchema,
  reconcileSettlementBatchSchema,
  cancelSettlementBatchSchema,
  type CreateSettlementRouteInput,
  type UpdateSettlementRouteInput,
  type CreateSettlementRouteFeeVersionInput,
  type CreateDraftSettlementBatchInput,
  type UpdateDraftSettlementBatchInput,
  type FinalizeSettlementBatchInput,
  type RecordSettlementBankMovementInput,
  type ReverseSettlementBankMovementInput,
  type ReconcileSettlementBatchInput,
  type CancelSettlementBatchInput,
} from "./schema";

// Every mutation below goes through a single trusted SECURITY DEFINER RPC
// (settlement_routes/settlement_route_fee_versions CRUD, migrations 0169/
// 0171; settlement_batches draft/finalize/reconcile/cancel, migrations
// 0177/0178/0180/0181; settlement_bank_movement_events record/reverse,
// migration 0179) — never a raw insert/update, mirroring
// src/features/adjustments/actions.ts exactly. Every base table in this
// module carries zero direct-write RLS policy — a raw .from(...).insert/
// .update would be silently rejected by Postgres regardless of what this
// file does. Every financial input stays a string from the browser through
// Zod through this file to the RPC call — never Number().

// ---------------------------------------------------------------------------
// settlement_routes CRUD (migration 0169).
// ---------------------------------------------------------------------------

export async function createSettlementRouteAction(input: CreateSettlementRouteInput): Promise<ActionResult<{ id: string }>> {
  await requirePermission("settlements.manage_routes");

  const parsed = createSettlementRouteSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_settlement_route", {
    p_code: parsed.data.code,
    p_name_ar: parsed.data.name_ar,
    p_route_kind: parsed.data.route_kind,
    p_name_en: parsed.data.name_en ?? null,
    p_payment_method_id: parsed.data.payment_method_id ?? null,
    p_collection_channel_id: parsed.data.collection_channel_id ?? null,
    p_shipping_carrier_id: parsed.data.shipping_carrier_id ?? null,
    p_description: parsed.data.description ?? null,
  });

  if (error) {
    console.error("[settlements] create_settlement_route failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataSettlementRoutes);
  return actionSuccess({ id: data as string }, "تم إنشاء مسار التسوية بنجاح.");
}

export async function updateSettlementRouteAction(input: UpdateSettlementRouteInput): Promise<ActionResult<null>> {
  await requirePermission("settlements.manage_routes");

  const parsed = updateSettlementRouteSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("update_settlement_route", {
    p_id: parsed.data.id,
    p_name_ar: parsed.data.name_ar,
    p_name_en: parsed.data.name_en ?? null,
    p_description: parsed.data.description ?? null,
  });

  if (error) {
    console.error("[settlements] update_settlement_route failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataSettlementRoutes);
  return actionSuccess(null, "تم حفظ التعديلات.");
}

export async function setSettlementRouteStatusAction(routeId: string, nextStatus: "active" | "disabled"): Promise<ActionResult<null>> {
  await requirePermission("settlements.manage_routes");

  const supabase = await createClient();
  const { error } = await supabase.rpc(nextStatus === "disabled" ? "disable_settlement_route" : "enable_settlement_route", { p_id: routeId });

  if (error) {
    console.error("[settlements] settlement route status change failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataSettlementRoutes);
  return actionSuccess(null, nextStatus === "disabled" ? "تم تعطيل مسار التسوية." : "تمت إعادة تفعيل مسار التسوية.");
}

// ---------------------------------------------------------------------------
// settlement_route_fee_versions create/cancel (migration 0171).
// ---------------------------------------------------------------------------

export async function createSettlementRouteFeeVersionAction(input: CreateSettlementRouteFeeVersionInput): Promise<ActionResult<{ id: string }>> {
  await requirePermission("settlements.manage_routes");

  const parsed = createSettlementRouteFeeVersionSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_settlement_route_fee_version", {
    p_settlement_route_id: parsed.data.settlement_route_id,
    p_effective_from: parsed.data.effective_from,
    p_transaction_fee_strategy: parsed.data.transaction_fee_strategy,
    p_transaction_fee_model: parsed.data.transaction_fee_model ?? null,
    p_percentage_fee: parsed.data.percentage_fee ?? null,
    p_fixed_fee: parsed.data.fixed_fee ?? null,
    p_batch_fee_fixed: parsed.data.batch_fee_fixed,
    p_cod_fee_reversal_policy: parsed.data.cod_fee_reversal_policy ?? null,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[settlements] create_settlement_route_fee_version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataSettlementRoutes);
  return actionSuccess({ id: data as string }, "تم إنشاء إصدار رسوم جديد بنجاح.");
}

export async function cancelSettlementRouteFeeVersionAction(versionId: string): Promise<ActionResult<null>> {
  await requirePermission("settlements.manage_routes");

  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_settlement_route_fee_version", { p_version_id: versionId });

  if (error) {
    console.error("[settlements] cancel_settlement_route_fee_version failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.masterDataSettlementRoutes);
  return actionSuccess(null, "تم إلغاء إصدار الرسوم.");
}

// ---------------------------------------------------------------------------
// Settlement Source Discovery (migration 0176) — client-triggered reads,
// gated on settlements.create like every other step of the /settlements/new
// flow (mirrors searchSalesOrdersForAdjustmentAction/previewAdjustmentAction
// in adjustments/actions.ts exactly).
// ---------------------------------------------------------------------------

export type UnsettledSourceRow = {
  source_kind: string;
  source_event_id: string;
  source_number: string;
  source_business_date: string;
  store_display: string;
  source_label: string;
  gross_collection_impact: string;
  provider_fee_impact: string;
  expected_settlement_impact: string;
};

export async function listUnsettledSettlementSourcesAction(params: {
  settlementRouteId: string;
  sourceDateFrom: string;
  sourceDateTo: string;
  storeId?: string;
  search?: string;
}): Promise<ActionResult<UnsettledSourceRow[]>> {
  await requirePermission("settlements.create");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("list_unsettled_settlement_sources", {
    p_settlement_route_id: params.settlementRouteId,
    p_source_date_from: params.sourceDateFrom,
    p_source_date_to: params.sourceDateTo,
    p_store_id: params.storeId || null,
    p_search: params.search || null,
    p_limit: 200,
    p_offset: 0,
  });

  if (error) {
    console.error("[settlements] list_unsettled_settlement_sources failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  return actionSuccess(data ?? []);
}

export type SettlementBatchPreview = {
  lines: unknown[];
  gross_source_impact: string;
  provider_fee_impact: string;
  expected_before_batch_fee: string;
  configured_batch_fee: string;
  effective_batch_fee: string;
  batch_fee_overridden: boolean;
  expected_bank_settlement: string;
  fee_version_resolved: boolean;
  transaction_fee_strategy: string | null;
};

/**
 * Hotfix 7.1.1 §9 — preview_settlement_batch() (migration 0195) now accepts
 * the SAME batch-fee-override pair finalize_settlement_batch() always has,
 * so a pending override actually changes what Preview displays instead of
 * silently diverging from what Finalize will apply. batchFeeOverride/
 * overrideReason are both optional — omitted (or undefined) means "no
 * override", exactly mirroring finalizeSettlementBatchAction's own
 * optional-override shape below. Values stay strings end-to-end — never
 * Number() (§13).
 */
export async function previewSettlementBatchAction(params: {
  settlementRouteId: string;
  sourceDateFrom: string;
  sourceDateTo: string;
  selectedSources: { source_kind: string; source_event_id: string }[];
  settlementDate?: string;
  batchFeeOverride?: string;
  overrideReason?: string;
}): Promise<ActionResult<SettlementBatchPreview>> {
  await requirePermission("settlements.create");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("preview_settlement_batch", {
    p_settlement_route_id: params.settlementRouteId,
    p_source_date_from: params.sourceDateFrom,
    p_source_date_to: params.sourceDateTo,
    p_selected_sources: params.selectedSources,
    p_settlement_date: params.settlementDate || null,
    p_batch_fee_override: params.batchFeeOverride || null,
    p_override_reason: params.overrideReason || null,
  });

  if (error) {
    console.error("[settlements] preview_settlement_batch failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);
  return actionSuccess(row as SettlementBatchPreview);
}

// ---------------------------------------------------------------------------
// settlement_batches draft lifecycle (migration 0177).
// ---------------------------------------------------------------------------

export async function createDraftSettlementBatchAction(input: CreateDraftSettlementBatchInput): Promise<ActionResult<{ id: string; settlement_number: string }>> {
  await requirePermission("settlements.create");

  const parsed = createDraftSettlementBatchSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_draft_settlement_batch", {
    p_settlement_route_id: parsed.data.settlement_route_id,
    p_settlement_date: parsed.data.settlement_date,
    p_provider_statement_reference: parsed.data.provider_statement_reference ?? null,
    p_notes: parsed.data.notes ?? null,
  });

  if (error) {
    console.error("[settlements] create_draft_settlement_batch failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.settlements);
  return actionSuccess({ id: row.id, settlement_number: row.settlement_number }, `تم إنشاء مسودة تسوية رقم ${row.settlement_number} بنجاح.`);
}

export async function updateDraftSettlementBatchAction(input: UpdateDraftSettlementBatchInput): Promise<ActionResult<{ row_version: number }>> {
  await requirePermission("settlements.create");

  const parsed = updateDraftSettlementBatchSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  // Patch 7.1 §27 — update_draft_settlement_batch() v2 (0189) makes
  // keep/set/clear explicit via two trailing "_provided" flags: an unset
  // flag ALWAYS keeps the existing value, a set flag applies p_X verbatim
  // (including clearing it to NULL when p_X is null/blank). This form
  // always has SOME value for both text fields (possibly empty, after a
  // user clears it) and always shows the batch's CURRENT value otherwise —
  // so always passing provided:=true with the form's current value is
  // simultaneously correct for "left untouched" (a no-op re-set of the same
  // value) AND "user cleared it" (actually clears server-side, fixing the
  // bug 0177's ambiguous NULL-means-keep contract had).
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("update_draft_settlement_batch", {
    p_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_settlement_route_id: parsed.data.settlement_route_id,
    p_settlement_date: parsed.data.settlement_date,
    p_provider_statement_reference: parsed.data.provider_statement_reference ?? null,
    p_notes: parsed.data.notes ?? null,
    p_provider_statement_reference_provided: true,
    p_notes_provided: true,
  });

  if (error) {
    console.error("[settlements] update_draft_settlement_batch failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.settlements);
  revalidatePath(`${ROUTES.settlements}/${parsed.data.id}`);
  return actionSuccess({ row_version: row.row_version }, "تم حفظ التعديلات بنجاح.");
}

export async function finalizeSettlementBatchAction(input: FinalizeSettlementBatchInput): Promise<ActionResult<{ id: string; settlement_number: string; row_version: number }>> {
  await requirePermission("settlements.finalize");

  const parsed = finalizeSettlementBatchSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("finalize_settlement_batch", {
    p_settlement_batch_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_selected_sources: parsed.data.selected_sources,
    p_batch_fee_override: parsed.data.batch_fee_override ?? null,
    p_override_reason: parsed.data.override_reason ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[settlements] finalize_settlement_batch failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.settlements);
  revalidatePath(`${ROUTES.settlements}/${parsed.data.id}`);
  return actionSuccess({ id: row.id, settlement_number: row.settlement_number, row_version: row.row_version }, `تم اعتماد دفعة التسوية رقم ${row.settlement_number} بنجاح.`);
}

// ---------------------------------------------------------------------------
// settlement_bank_movement_events record/reverse (migration 0179).
// ---------------------------------------------------------------------------

export async function recordSettlementBankMovementAction(input: RecordSettlementBankMovementInput): Promise<ActionResult<{ id: string }>> {
  await requirePermission("settlements.record_bank_movement");

  const parsed = recordSettlementBankMovementSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("record_settlement_bank_movement", {
    p_settlement_batch_id: parsed.data.settlement_batch_id,
    p_movement_business_date: parsed.data.movement_business_date,
    p_amount: parsed.data.amount,
    p_bank_reference: parsed.data.bank_reference ?? null,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[settlements] record_settlement_bank_movement failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(`${ROUTES.settlements}/${parsed.data.settlement_batch_id}`);
  return actionSuccess({ id: data as string }, "تم تسجيل الحركة البنكية بنجاح.");
}

export async function reverseSettlementBankMovementAction(input: ReverseSettlementBankMovementInput, settlementBatchId: string): Promise<ActionResult<{ id: string }>> {
  await requirePermission("settlements.record_bank_movement");

  const parsed = reverseSettlementBankMovementSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reverse_settlement_bank_movement", {
    p_bank_movement_event_id: parsed.data.bank_movement_event_id,
    p_reversal_business_date: parsed.data.reversal_business_date,
    p_reason: parsed.data.reason,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[settlements] reverse_settlement_bank_movement failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(`${ROUTES.settlements}/${settlementBatchId}`);
  return actionSuccess({ id: data as string }, "تم عكس الحركة البنكية بنجاح.");
}

// ---------------------------------------------------------------------------
// reconcile_settlement_batch() (migration 0180).
// ---------------------------------------------------------------------------

export async function reconcileSettlementBatchAction(input: ReconcileSettlementBatchInput): Promise<ActionResult<{ row_version: number; actual_bank_movement: string; variance: string }>> {
  await requirePermission("settlements.reconcile");

  const parsed = reconcileSettlementBatchSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reconcile_settlement_batch", {
    p_settlement_batch_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_variance_reason: parsed.data.variance_reason ?? null,
  });

  if (error) {
    console.error("[settlements] reconcile_settlement_batch failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.settlements);
  revalidatePath(`${ROUTES.settlements}/${parsed.data.id}`);
  return actionSuccess({ row_version: row.row_version, actual_bank_movement: row.actual_bank_movement, variance: row.variance }, "تمت مطابقة دفعة التسوية بنجاح.");
}

// ---------------------------------------------------------------------------
// cancel_settlement_batch() (migration 0181).
// ---------------------------------------------------------------------------

export async function cancelSettlementBatchAction(input: CancelSettlementBatchInput): Promise<ActionResult<{ id: string }>> {
  await requirePermission("settlements.cancel");

  const parsed = cancelSettlementBatchSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("cancel_settlement_batch", {
    p_settlement_batch_id: parsed.data.id,
    p_expected_version: parsed.data.row_version,
    p_cancellation_business_date: parsed.data.cancellation_business_date,
    p_reason: parsed.data.reason,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[settlements] cancel_settlement_batch failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  revalidatePath(ROUTES.settlements);
  revalidatePath(`${ROUTES.settlements}/${parsed.data.id}`);
  return actionSuccess({ id: data as string }, "تم إلغاء دفعة التسوية بنجاح.");
}

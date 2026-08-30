"use server";

import { revalidatePath } from "next/cache";
import { requirePermission, requireAnyPermission } from "@/lib/permissions/guard";
import { createClient } from "@/lib/supabase/server";
import { actionError, actionSuccess, dbErrorMessage, GENERIC_ERROR_MESSAGE_AR, type ActionResult } from "@/lib/action-result";
import { ROUTES } from "@/lib/constants";
import {
  createShipmentSchema,
  addShipmentStatusEventSchema,
  recordShipmentActualCostSchema,
  correctShipmentActualCostSchema,
  correctShipmentCustomerChargeSchema,
  recordShipmentCodCollectionStateSchema,
  type CreateShipmentInput,
  type AddShipmentStatusEventInput,
  type RecordShipmentActualCostInput,
  type CorrectShipmentActualCostInput,
  type CorrectShipmentCustomerChargeInput,
  type RecordShipmentCodCollectionStateInput,
} from "./schema";

// Every mutation below goes through a single trusted RPC (create_shipment/
// add_shipment_status_event/record_shipment_actual_cost/correct_shipment_
// actual_cost/correct_shipment_customer_charge — migrations 0117/0118) —
// never a raw insert/update, mirroring src/features/returns/actions.ts
// exactly. Every financial input stays a string from the browser through
// Zod through this file to the RPC call — never Number().

export async function createShipmentAction(input: CreateShipmentInput): Promise<ActionResult<{ id: string; shipment_number: string }>> {
  await requirePermission("shipments.create");

  const parsed = createShipmentSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_shipment", {
    p_sales_order_id: parsed.data.sales_order_id,
    p_store_id: parsed.data.store_id,
    p_shipment_date: parsed.data.shipment_date,
    p_direction: parsed.data.direction,
    p_carrier_id: parsed.data.carrier_id,
    p_shipping_zone_id: parsed.data.shipping_zone_id,
    p_customer_shipping_charge: parsed.data.customer_shipping_charge,
    p_sales_return_id: parsed.data.sales_return_id ?? null,
    p_fulfillment_type: parsed.data.fulfillment_type,
    p_tracking_number: parsed.data.tracking_number ?? null,
    p_external_reference: parsed.data.external_reference ?? null,
    p_customer_name: parsed.data.customer_name ?? null,
    p_customer_phone: parsed.data.customer_phone ?? null,
    p_recipient_address: parsed.data.recipient_address ?? null,
    p_is_cod: parsed.data.is_cod,
    p_cod_expected_amount: parsed.data.cod_expected_amount ?? null,
    p_manual_expected_cost: parsed.data.manual_expected_cost ?? null,
    p_manual_expected_cost_reason: parsed.data.manual_expected_cost_reason ?? null,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
    // Hotfix 5.1.1 item 1 — wired through to create_shipment()'s trailing
    // parameter (migration 0125); mandatory server-side only when the
    // submitted p_customer_shipping_charge actually diverges from the
    // resolved standard return fee (ignored for outbound, where it is
    // always null).
    p_customer_return_shipping_charge_override_reason: parsed.data.customer_return_shipping_charge_override_reason ?? null,
  });

  if (error) {
    console.error("[shipping] create_shipment failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.shipments);
  return actionSuccess({ id: row.id, shipment_number: row.shipment_number }, `تم إنشاء الشحنة رقم ${row.shipment_number} بنجاح.`);
}

/**
 * Narrow, shipments.create-gated previews the /shipments/new UI calls
 * before submission (migration 0117) — never require shipping_rates.view.
 */
export async function previewShipmentExpectedCostAction(params: {
  carrierId: string;
  shippingZoneId: string;
  direction: string;
  shipmentDate?: string;
}): Promise<ActionResult<{ found: boolean; rate_version_id: string | null; expected_carrier_cost: string | null }>> {
  await requirePermission("shipments.create");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("preview_shipment_expected_cost", {
    p_carrier_id: params.carrierId,
    p_shipping_zone_id: params.shippingZoneId,
    p_direction: params.direction,
    p_shipment_date: params.shipmentDate ?? undefined,
  });

  if (error) {
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0] ?? { found: false, rate_version_id: null, expected_carrier_cost: null };
  return actionSuccess(row);
}

export async function previewCustomerReturnShippingFeeAction(params: {
  shippingZoneId: string;
  date?: string;
}): Promise<ActionResult<{ found: boolean; rate_version_id: string | null; fee_amount: string | null }>> {
  await requirePermission("shipments.create");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("preview_customer_return_shipping_fee", {
    p_shipping_zone_id: params.shippingZoneId,
    p_date: params.date ?? undefined,
  });

  if (error) {
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0] ?? { found: false, rate_version_id: null, fee_amount: null };
  return actionSuccess(row);
}

export async function addShipmentStatusEventAction(input: AddShipmentStatusEventInput): Promise<ActionResult<{ row_version: number }>> {
  // Hotfix 5.1.1 item 4 — this Server Action used to hard-require
  // shipments.update_status alone, which meant an actor who holds ONLY
  // shipments.correct_status (and not shipments.update_status) was
  // rejected by this gate before the request ever reached the RPC, even
  // though the RPC itself would have accepted the call. Both shipments.
  // update_status and shipments.correct_status can legitimately call this
  // RPC — the DB decides which is actually required based on whether the
  // transition is a normal forward move or a correction (0118); this gate
  // now only needs to confirm the actor holds AT LEAST ONE of the two,
  // matching the <ShipmentStatusActions> UI's own `Can anyOf={[...]}` gate
  // exactly. The RPC remains the real authority on which one a given
  // transition actually needs.
  await requireAnyPermission(["shipments.update_status", "shipments.correct_status"]);

  const parsed = addShipmentStatusEventSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("add_shipment_status_event", {
    p_shipment_id: parsed.data.shipment_id,
    p_new_status: parsed.data.new_status,
    p_expected_version: parsed.data.row_version,
    p_event_business_date: parsed.data.event_business_date,
    p_notes: parsed.data.notes ?? null,
    p_external_reference: parsed.data.external_reference ?? null,
    p_reason: parsed.data.reason ?? null,
  });

  if (error) {
    console.error("[shipping] add_shipment_status_event failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(ROUTES.shipments);
  revalidatePath(`${ROUTES.shipments}/${parsed.data.shipment_id}`);
  return actionSuccess({ row_version: row.row_version }, "تم تحديث حالة الشحنة بنجاح.");
}

export async function recordShipmentActualCostAction(input: RecordShipmentActualCostInput): Promise<ActionResult<{ row_version: number }>> {
  await requirePermission("shipments.manage_cost");

  const parsed = recordShipmentActualCostSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("record_shipment_actual_cost", {
    p_shipment_id: parsed.data.shipment_id,
    p_expected_version: parsed.data.row_version,
    p_amount: parsed.data.amount,
    p_business_date: parsed.data.business_date,
    p_reference: parsed.data.reference ?? null,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[shipping] record_shipment_actual_cost failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(`${ROUTES.shipments}/${parsed.data.shipment_id}`);
  return actionSuccess({ row_version: row.row_version }, "تم تسجيل التكلفة الفعلية للشحن بنجاح.");
}

export async function correctShipmentActualCostAction(input: CorrectShipmentActualCostInput): Promise<ActionResult<{ row_version: number }>> {
  await requirePermission("shipments.manage_cost");

  const parsed = correctShipmentActualCostSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("correct_shipment_actual_cost", {
    p_shipment_id: parsed.data.shipment_id,
    p_expected_version: parsed.data.row_version,
    p_amount: parsed.data.amount,
    p_business_date: parsed.data.business_date,
    p_reason: parsed.data.reason,
    p_reference: parsed.data.reference ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[shipping] correct_shipment_actual_cost failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(`${ROUTES.shipments}/${parsed.data.shipment_id}`);
  return actionSuccess({ row_version: row.row_version }, "تم تصحيح التكلفة الفعلية للشحن بنجاح.");
}

export async function correctShipmentCustomerChargeAction(input: CorrectShipmentCustomerChargeInput): Promise<ActionResult<{ row_version: number }>> {
  await requirePermission("shipments.manage_cost");

  const parsed = correctShipmentCustomerChargeSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("correct_shipment_customer_charge", {
    p_shipment_id: parsed.data.shipment_id,
    p_expected_version: parsed.data.row_version,
    p_amount: parsed.data.amount,
    p_business_date: parsed.data.business_date,
    p_reason: parsed.data.reason,
    p_reference: parsed.data.reference ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[shipping] correct_shipment_customer_charge failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(`${ROUTES.shipments}/${parsed.data.shipment_id}`);
  return actionSuccess({ row_version: row.row_version }, "تم تصحيح رسوم الشحن على العميل بنجاح.");
}

/**
 * COD collection-state workflow (Patch 5.1 items 13/14, migration 0127) —
 * append-only, gated shipments.manage_cost, rejects non-COD shipments and
 * backdated events server-side, Daily-Close aware exactly like the actual-
 * cost/customer-charge RPCs above. Never auto-triggered by status events —
 * always an explicit actor action.
 */
export async function recordShipmentCodCollectionStateAction(input: RecordShipmentCodCollectionStateInput): Promise<ActionResult<{ row_version: number }>> {
  await requirePermission("shipments.manage_cost");

  const parsed = recordShipmentCodCollectionStateSchema.safeParse(input);
  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("record_shipment_cod_collection_state", {
    p_shipment_id: parsed.data.shipment_id,
    p_expected_version: parsed.data.row_version,
    p_new_state: parsed.data.new_state,
    p_business_date: parsed.data.business_date,
    p_reference: parsed.data.reference ?? null,
    p_notes: parsed.data.notes ?? null,
    p_closed_day_reason: parsed.data.closed_day_reason ?? null,
  });

  if (error) {
    console.error("[shipping] record_shipment_cod_collection_state failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  const row = data?.[0];
  if (!row) return actionError(GENERIC_ERROR_MESSAGE_AR);

  revalidatePath(`${ROUTES.shipments}/${parsed.data.shipment_id}`);
  return actionSuccess({ row_version: row.row_version }, "تم تسجيل حالة تحصيل الدفع عند الاستلام بنجاح.");
}

/** Order lookup step of /shipments/new (outbound) — thin wrapper over search_sales_orders_for_shipment() (0120), gated on shipments.create ALONE. */
export async function searchSalesOrdersForShipmentAction(orderNumber: string): Promise<
  ActionResult<{ id: string; order_number: string; sale_date: string; store_id: string; store_name: string | null; customer_name: string | null; customer_phone: string | null }[]>
> {
  await requirePermission("shipments.create");

  const trimmed = orderNumber.trim();
  if (!trimmed) return actionSuccess([]);

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("search_sales_orders_for_shipment", {
    p_order_number: trimmed,
    p_limit: 10,
  });

  if (error) {
    console.error("[shipping] search sales orders failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  return actionSuccess(data ?? []);
}

/** Return lookup step of /shipments/new (return direction) — thin wrapper over search_sales_returns_for_shipment() (0120), gated on shipments.create ALONE. Only approved/reversed returns are returned. */
export async function searchSalesReturnsForShipmentAction(params: { returnNumber?: string; salesOrderId?: string }): Promise<
  ActionResult<
    { id: string; return_number: string; return_date: string; status: string; sales_order_id: string; order_number: string | null; processed_store_id: string; store_name: string | null }[]
  >
> {
  await requirePermission("shipments.create");

  const trimmed = params.returnNumber?.trim();
  if (!trimmed && !params.salesOrderId) return actionSuccess([]);

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("search_sales_returns_for_shipment", {
    p_return_number: trimmed || null,
    p_sales_order_id: params.salesOrderId ?? null,
    p_limit: 10,
  });

  if (error) {
    console.error("[shipping] search sales returns failed", error);
    return actionError(dbErrorMessage(error, GENERIC_ERROR_MESSAGE_AR));
  }

  return actionSuccess(data ?? []);
}

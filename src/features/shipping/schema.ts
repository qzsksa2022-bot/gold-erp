import { z } from "zod";
import { hasMaxDecimalPlaces, isNonNegativeDecimal } from "@/lib/decimal";

// Every financial input here stays a STRING all the way to the RPC call —
// never parsed through Number()/parseFloat() at any point in this file or
// in actions.ts, exactly mirroring src/features/returns/schema.ts. This
// file only validates shape/presence of genuine business inputs; every
// cross-field money computation (net_shipping_expected/actual, rate
// resolution) happens inside the DB (create_shipment()/record_shipment_
// actual_cost()/etc., migrations 0117/0118), never re-derived client-side.

/** Mirrors shipments.direction's check constraint (migration 0116). */
export const SHIPMENT_DIRECTIONS = ["outbound", "return"] as const;

export const SHIPMENT_DIRECTION_LABELS_AR: Record<(typeof SHIPMENT_DIRECTIONS)[number], string> = {
  outbound: "ذهاب (للعميل)",
  return: "إرجاع (من العميل)",
};

/** Mirrors shipments.fulfillment_type's check constraint (migration 0116). */
export const SHIPMENT_FULFILLMENT_TYPES = ["delivery", "store_courier", "pickup", "other"] as const;

export const SHIPMENT_FULFILLMENT_TYPE_LABELS_AR: Record<(typeof SHIPMENT_FULFILLMENT_TYPES)[number], string> = {
  delivery: "توصيل",
  store_courier: "مندوب المتجر",
  pickup: "استلام من الفرع",
  other: "أخرى",
};

/** Mirrors shipments.current_status's check constraint / shipment_status_events.status (migration 0116). */
export const SHIPMENT_STATUSES = [
  "created",
  "ready_for_pickup",
  "picked_up",
  "in_transit",
  "out_for_delivery",
  "delivered",
  "delivery_failed",
  "customer_refused",
  "customer_never_received",
  "returned_to_store",
  "cancelled",
] as const;

export const SHIPMENT_STATUS_LABELS_AR: Record<(typeof SHIPMENT_STATUSES)[number], string> = {
  created: "تم الإنشاء",
  ready_for_pickup: "جاهزة للاستلام",
  picked_up: "تم الاستلام من قِبل الشحن",
  in_transit: "قيد النقل",
  out_for_delivery: "خارجة للتوصيل",
  delivered: "تم التسليم",
  delivery_failed: "فشل التسليم",
  customer_refused: "رفض العميل الاستلام",
  customer_never_received: "لم يستلم العميل الشحنة",
  returned_to_store: "أُعيدت للمتجر",
  cancelled: "ملغاة",
};

/** Mirrors shipments.cod_collection_state's check constraint (migration 0116). */
export const COD_COLLECTION_STATES = ["expected", "collected", "not_collected", "unknown"] as const;

export const COD_COLLECTION_STATE_LABELS_AR: Record<(typeof COD_COLLECTION_STATES)[number], string> = {
  expected: "متوقَّع",
  collected: "تم التحصيل",
  not_collected: "لم يتم التحصيل",
  unknown: "غير معروف",
};

const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined));

const moneyAmountSchema = (label: string) =>
  z
    .string({ required_error: `${label} مطلوبة` })
    .trim()
    .refine((v) => isNonNegativeDecimal(v), `${label} يجب أن تكون رقمًا موجبًا أو صفرًا`)
    .refine((v) => hasMaxDecimalPlaces(v, 2), `${label} يجب ألا تتجاوز منزلتين عشريتين`);

const optionalMoneyAmountSchema = (label: string) =>
  z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined))
    .refine((v) => v === undefined || (isNonNegativeDecimal(v) && hasMaxDecimalPlaces(v, 2)), `${label} يجب أن تكون رقمًا موجبًا أو صفرًا (منزلتان عشريتان كحد أقصى)`);

const rowVersionSchema = z.number({ required_error: "إصدار السجل مطلوب" }).int().nonnegative();

// ---------------------------------------------------------------------------
// create_shipment() (migration 0117)
// ---------------------------------------------------------------------------
export const createShipmentSchema = z
  .object({
    sales_order_id: z.string({ required_error: "عملية البيع مطلوبة" }).uuid("عملية بيع غير صالحة"),
    store_id: z.string({ required_error: "المتجر مطلوب" }).uuid("متجر غير صالح"),
    shipment_date: z.string({ required_error: "تاريخ الشحنة مطلوب" }).trim().min(1, "تاريخ الشحنة مطلوب"),
    direction: z.enum(SHIPMENT_DIRECTIONS, { required_error: "اتجاه الشحنة مطلوب" }),
    carrier_id: z.string({ required_error: "شركة الشحن مطلوبة" }).uuid("شركة شحن غير صالحة"),
    shipping_zone_id: z.string({ required_error: "المنطقة مطلوبة" }).uuid("منطقة غير صالحة"),
    customer_shipping_charge: moneyAmountSchema("رسوم الشحن على العميل"),
    sales_return_id: z.string().uuid().optional().or(z.literal("")).transform((v) => (v ? v : undefined)),
    fulfillment_type: z.enum(SHIPMENT_FULFILLMENT_TYPES).default("delivery"),
    tracking_number: optionalText(200),
    external_reference: optionalText(200),
    customer_name: optionalText(200),
    customer_phone: optionalText(50),
    recipient_address: optionalText(1000),
    is_cod: z.boolean().default(false),
    cod_expected_amount: optionalMoneyAmountSchema("المبلغ المتوقع تحصيله (COD)"),
    manual_expected_cost: optionalMoneyAmountSchema("التكلفة المتوقعة اليدوية"),
    manual_expected_cost_reason: optionalText(500),
    notes: optionalText(1000),
    closed_day_reason: optionalText(500),
    // Hotfix 5.1.1 item 1 — mandatory server-side (create_shipment(),
    // migration 0125) whenever the submitted customer_shipping_charge
    // diverges from the resolved standard return-shipping fee, or no
    // configuration exists at all for the zone/date. This schema only
    // validates shape/length here — the actual "does it diverge" decision
    // needs the live preview_customer_return_shipping_fee() suggestion,
    // which is only known at render time in <ShipmentEntryForm/>, not at
    // parse time; the DB remains the true authority and will reject a
    // missing-but-required reason regardless of what the client computed.
    customer_return_shipping_charge_override_reason: optionalText(500),
  })
  .refine((v) => v.direction !== "return" || !!v.sales_return_id, {
    message: "يجب تحديد المرتجع المرتبط عند اختيار اتجاه إرجاع",
    path: ["sales_return_id"],
  })
  .refine((v) => v.manual_expected_cost === undefined || !!v.manual_expected_cost_reason, {
    message: "يجب إدخال سبب عند إدخال تكلفة متوقعة يدوية",
    path: ["manual_expected_cost_reason"],
  })
  .refine((v) => !v.is_cod || v.cod_expected_amount !== undefined, {
    message: "يجب إدخال المبلغ المتوقع تحصيله عند تفعيل الدفع عند الاستلام (COD)",
    path: ["cod_expected_amount"],
  });

export type CreateShipmentInput = z.infer<typeof createShipmentSchema>;

// ---------------------------------------------------------------------------
// add_shipment_status_event() (migration 0118)
// ---------------------------------------------------------------------------
export const addShipmentStatusEventSchema = z.object({
  shipment_id: z.string().uuid(),
  row_version: rowVersionSchema,
  new_status: z.enum(SHIPMENT_STATUSES, { required_error: "الحالة الجديدة مطلوبة" }),
  event_business_date: z.string({ required_error: "تاريخ الحدث مطلوب" }).trim().min(1, "تاريخ الحدث مطلوب"),
  notes: optionalText(1000),
  external_reference: optionalText(200),
  // Only actually required server-side when the transition is a correction
  // (validate_shipment_status_transition() returns false) — the DB is the
  // authority on which transitions need one; this schema just allows it.
  reason: optionalText(1000),
});

export type AddShipmentStatusEventInput = z.infer<typeof addShipmentStatusEventSchema>;

// ---------------------------------------------------------------------------
// record_shipment_actual_cost() (migration 0118)
// ---------------------------------------------------------------------------
export const recordShipmentActualCostSchema = z.object({
  shipment_id: z.string().uuid(),
  row_version: rowVersionSchema,
  amount: moneyAmountSchema("التكلفة الفعلية"),
  business_date: z.string({ required_error: "تاريخ العملية المالية مطلوب" }).trim().min(1, "تاريخ العملية المالية مطلوب"),
  reference: optionalText(200),
  notes: optionalText(1000),
  closed_day_reason: optionalText(500),
});

export type RecordShipmentActualCostInput = z.infer<typeof recordShipmentActualCostSchema>;

// ---------------------------------------------------------------------------
// correct_shipment_actual_cost() (migration 0118) — mandatory reason.
// ---------------------------------------------------------------------------
export const correctShipmentActualCostSchema = z.object({
  shipment_id: z.string().uuid(),
  row_version: rowVersionSchema,
  amount: moneyAmountSchema("التكلفة الفعلية"),
  business_date: z.string({ required_error: "تاريخ العملية المالية مطلوب" }).trim().min(1, "تاريخ العملية المالية مطلوب"),
  reason: z.string({ required_error: "سبب التصحيح مطلوب" }).trim().min(1, "سبب التصحيح مطلوب").max(1000),
  reference: optionalText(200),
  closed_day_reason: optionalText(500),
});

export type CorrectShipmentActualCostInput = z.infer<typeof correctShipmentActualCostSchema>;

// ---------------------------------------------------------------------------
// correct_shipment_customer_charge() (migration 0118) — mandatory reason.
// ---------------------------------------------------------------------------
export const correctShipmentCustomerChargeSchema = z.object({
  shipment_id: z.string().uuid(),
  row_version: rowVersionSchema,
  amount: moneyAmountSchema("رسوم الشحن على العميل"),
  business_date: z.string({ required_error: "تاريخ العملية المالية مطلوب" }).trim().min(1, "تاريخ العملية المالية مطلوب"),
  reason: z.string({ required_error: "سبب التصحيح مطلوب" }).trim().min(1, "سبب التصحيح مطلوب").max(1000),
  reference: optionalText(200),
  closed_day_reason: optionalText(500),
});

export type CorrectShipmentCustomerChargeInput = z.infer<typeof correctShipmentCustomerChargeSchema>;

// ---------------------------------------------------------------------------
// list_shipments() (migration 0119, expanded 0126 — Patch 5.1 item 12) filters
// ---------------------------------------------------------------------------
export const shipmentsListFiltersSchema = z.object({
  date_from: z.string().optional(),
  date_to: z.string().optional(),
  store_id: z.string().uuid().optional(),
  carrier_id: z.string().uuid().optional(),
  shipping_zone_id: z.string().uuid().optional(),
  direction: z.enum(SHIPMENT_DIRECTIONS).optional(),
  current_status: z.enum(SHIPMENT_STATUSES).optional(),
  shipment_number: z.string().optional(),
  tracking_number: z.string().optional(),
  sales_order_id: z.string().uuid().optional(),
  sales_return_id: z.string().uuid().optional(),
  // Patch 5.1 item 12 — new filters.
  order_number: z.string().optional(),
  return_number: z.string().optional(),
  original_sale_store_id: z.string().uuid().optional(),
  cod_collection_state: z.enum(COD_COLLECTION_STATES).optional(),
  page: z.number().int().min(1).default(1),
});

export type ShipmentsListFilters = z.infer<typeof shipmentsListFiltersSchema>;

// ---------------------------------------------------------------------------
// record_shipment_cod_collection_state() (migration 0127) — Patch 5.1
// items 13/14. Append-only COD event workflow, Daily-Close gated like any
// other financial-adjacent event. Never Number() — business_date is a plain
// ISO date string, no money field is involved here.
// ---------------------------------------------------------------------------
export const recordShipmentCodCollectionStateSchema = z.object({
  shipment_id: z.string().uuid(),
  row_version: rowVersionSchema,
  new_state: z.enum(COD_COLLECTION_STATES, { required_error: "الحالة الجديدة مطلوبة" }),
  business_date: z.string({ required_error: "تاريخ العملية مطلوب" }).trim().min(1, "تاريخ العملية مطلوب"),
  reference: optionalText(200),
  notes: optionalText(1000),
  closed_day_reason: optionalText(500),
});

export type RecordShipmentCodCollectionStateInput = z.infer<typeof recordShipmentCodCollectionStateSchema>;

/** True when a DB error message indicates the target day is closed — mirrors returns/schema.ts's isClosedDayError(). */
export function isClosedDayError(message: string): boolean {
  return message.includes("مقفل");
}

/** True when a DB error message indicates an optimistic-concurrency Conflict (row_version mismatch) — mirrors returns/schema.ts's isVersionConflictError(). The client must reload rather than auto-resubmit. */
export function isVersionConflictError(message: string): boolean {
  return message.includes("مستخدم آخر");
}

/** True when create_shipment() rejected because no carrier rate configuration exists for (carrier, zone, direction, date) — the UI should reveal the manual-cost + reason fields instead of a dead-end error (Section 17). */
export function isNoRateConfigError(message: string): boolean {
  return message.includes("لا يوجد تسعير شحن معتمد");
}

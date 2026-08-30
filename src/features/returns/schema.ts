import { z } from "zod";
import { hasMaxDecimalPlaces, isNonNegativeDecimal, isPositiveDecimal } from "@/lib/decimal";

// Every financial input here stays a STRING all the way to the RPC call —
// never parsed through Number()/parseFloat() at any point in this file or
// in actions.ts, exactly mirroring src/features/sales/schema.ts. Returns
// never call a price/fee/VAT resolver client- or server-side — every cost
// figure the UI sees is a snapshot already computed and stored by
// create_sales_return()/update_pending_sales_return()/approve_sales_return()
// (migrations 0085-0087, rewritten by Patch 4.1's 0093-0098); this file only
// validates the genuine business inputs (which items + their condition,
// scenario, collection state, deduction, approved refund, an optional
// manual fee override) before forwarding them. Cross-field math that needs
// the actual sale_price sums (deduction <= returned total, refund-
// difference-reason vs the real revenue reversal) is NOT re-derived here —
// only the DB (which holds the authoritative snapshots) can compute it;
// this file validates shape/presence only, matching the project's existing
// client-validates-shape / server-validates-business-math split.

/** Mirrors sales_returns.scenario's check constraint (migration 0082). */
export const RETURN_SCENARIOS = [
  "defective_product",
  "customer_changed_mind",
  "wrong_item_delivered",
  "customer_never_received",
  "other",
] as const;

export const RETURN_SCENARIO_LABELS_AR: Record<(typeof RETURN_SCENARIOS)[number], string> = {
  defective_product: "منتج معيب",
  customer_changed_mind: "العميل غيّر رأيه",
  wrong_item_delivered: "تم تسليم صنف خاطئ",
  customer_never_received: "لم يستلم العميل الطلب",
  other: "أخرى",
};

/** Mirrors sales_returns.status's check constraint (migration 0082). */
export const RETURN_STATUSES = ["pending", "approved", "rejected", "reversed"] as const;

export const RETURN_STATUS_LABELS_AR: Record<(typeof RETURN_STATUSES)[number], string> = {
  pending: "قيد المراجعة",
  approved: "معتمد",
  rejected: "مرفوض",
  reversed: "متراجَع عنه",
};

/** Patch 4.1 (Section 1/2) — mirrors sales_returns.collection_state's check constraint (migration 0092). */
export const COLLECTION_STATES = ["collected", "not_collected", "partially_collected", "unknown"] as const;

export const COLLECTION_STATE_LABELS_AR: Record<(typeof COLLECTION_STATES)[number], string> = {
  collected: "تم التحصيل",
  not_collected: "لم يتم التحصيل",
  partially_collected: "تحصيل جزئي",
  unknown: "غير معروف",
};

/** Patch 4.1 (Section 3) — mirrors sales_return_items.condition's check constraint (migration 0092). */
export const RETURN_ITEM_CONDITIONS = ["good_resellable", "needs_service", "damaged", "unknown", "not_applicable"] as const;

export const RETURN_ITEM_CONDITION_LABELS_AR: Record<(typeof RETURN_ITEM_CONDITIONS)[number], string> = {
  good_resellable: "قابل لإعادة البيع",
  needs_service: "يحتاج صيانة",
  damaged: "تالف",
  unknown: "غير معروف",
  not_applicable: "لا ينطبق",
};

/** Patch 4.1 (Section 11) — refund_reconciliation_state, derived by get_sales_return()/list_sales_returns() (migration 0098), never stored directly. */
export const REFUND_RECONCILIATION_STATES = ["not_applicable", "pending", "finalized_matched", "finalized_with_variance"] as const;

export const REFUND_RECONCILIATION_STATE_LABELS_AR: Record<(typeof REFUND_RECONCILIATION_STATES)[number], string> = {
  not_applicable: "لا ينطبق",
  pending: "بانتظار التسوية",
  finalized_matched: "تمت التسوية (مطابقة)",
  finalized_with_variance: "تمت التسوية (بفارق)",
};

const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined));

const scenarioSchema = z.enum(RETURN_SCENARIOS, { required_error: "السيناريو مطلوب", invalid_type_error: "سيناريو غير صالح" });
const collectionStateSchema = z.enum(COLLECTION_STATES, { required_error: "حالة تحصيل المبلغ الأصلي مطلوبة", invalid_type_error: "حالة تحصيل غير صالحة" });
const conditionSchema = z.enum(RETURN_ITEM_CONDITIONS, { invalid_type_error: "حالة بند غير صالحة" }).default("unknown");

const rowVersionSchema = z.number({ required_error: "إصدار السجل مطلوب" }).int().nonnegative();

/** Patch 4.1 (Section 3) — one element per returned line; sales_order_item_id is the stable identity (0067), condition/reason/notes are the new per-item business data. */
export const returnItemInputSchema = z.object({
  sales_order_item_id: z.string().uuid(),
  condition: conditionSchema,
  item_return_reason: optionalText(500),
  item_notes: optionalText(1000),
});

const returnItemsSchema = z.array(returnItemInputSchema).min(1, "يجب اختيار بند واحد على الأقل للإرجاع");

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
    .transform((v) => (v ? v : "0"))
    .refine((v) => isNonNegativeDecimal(v), `${label} يجب أن تكون رقمًا موجبًا أو صفرًا`)
    .refine((v) => hasMaxDecimalPlaces(v, 2), `${label} يجب ألا تتجاوز منزلتين عشريتين`);

// The Section 1 business inputs shared by create_sales_return() and
// update_pending_sales_return() — split out so both schemas stay in sync.
const returnBusinessInputsShape = {
  collection_state: collectionStateSchema,
  approved_refund_amount: moneyAmountSchema("قيمة الاسترداد المعتمد"),
  non_shipping_deduction_amount: optionalMoneyAmountSchema("قيمة الاستقطاع"),
  deduction_reason: optionalText(500),
  refund_difference_reason: optionalText(500),
};

// ---------------------------------------------------------------------------
// create_sales_return() (migration 0085, rewritten 0093)
// ---------------------------------------------------------------------------
export const createSalesReturnSchema = z
  .object({
    sales_order_id: z.string({ required_error: "عملية البيع مطلوبة" }).uuid("عملية بيع غير صالحة"),
    processed_store_id: z.string({ required_error: "المتجر مطلوب" }).uuid("متجر غير صالح"),
    return_date: z.string({ required_error: "تاريخ المرتجع مطلوب" }).trim().min(1, "تاريخ المرتجع مطلوب"),
    scenario: scenarioSchema,
    items: returnItemsSchema,
    expected_sale_version: rowVersionSchema,
    scenario_notes: optionalText(1000),
    closed_day_reason: optionalText(500),
    ...returnBusinessInputsShape,
  })
  .refine((v) => v.scenario !== "other" || !!v.scenario_notes, {
    message: 'يجب إدخال ملاحظات عند اختيار سيناريو "أخرى"',
    path: ["scenario_notes"],
  })
  .refine((v) => v.non_shipping_deduction_amount === "0" || !!v.deduction_reason, {
    message: "يجب إدخال سبب الاستقطاع عندما تكون قيمته أكبر من صفر",
    path: ["deduction_reason"],
  });

export type CreateSalesReturnInput = z.infer<typeof createSalesReturnSchema>;

// ---------------------------------------------------------------------------
// preview_sales_return() (migration 0085, rewritten 0093) — read-only
// estimate, extended (Section 16) to accept the same Business Inputs
// create_sales_return() does.
// ---------------------------------------------------------------------------
export const previewSalesReturnSchema = z.object({
  sales_order_id: z.string().uuid(),
  items: returnItemsSchema,
  scenario: scenarioSchema.optional(),
  collection_state: collectionStateSchema.optional(),
  non_shipping_deduction_amount: optionalMoneyAmountSchema("قيمة الاستقطاع").optional(),
  deduction_reason: optionalText(500),
  approved_refund_amount: z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  refund_difference_reason: optionalText(500),
  fee_reversal_override: z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
});

export type PreviewSalesReturnInput = z.infer<typeof previewSalesReturnSchema>;

// ---------------------------------------------------------------------------
// update_pending_sales_return() (migration 0086, rewritten 0094)
// ---------------------------------------------------------------------------
export const updatePendingSalesReturnSchema = z
  .object({
    return_id: z.string().uuid(),
    row_version: rowVersionSchema,
    scenario: scenarioSchema,
    items: returnItemsSchema,
    scenario_notes: optionalText(1000),
    closed_day_reason: optionalText(500),
    ...returnBusinessInputsShape,
  })
  .refine((v) => v.scenario !== "other" || !!v.scenario_notes, {
    message: 'يجب إدخال ملاحظات عند اختيار سيناريو "أخرى"',
    path: ["scenario_notes"],
  })
  .refine((v) => v.non_shipping_deduction_amount === "0" || !!v.deduction_reason, {
    message: "يجب إدخال سبب الاستقطاع عندما تكون قيمته أكبر من صفر",
    path: ["deduction_reason"],
  });

export type UpdatePendingSalesReturnInput = z.infer<typeof updatePendingSalesReturnSchema>;

// ---------------------------------------------------------------------------
// refresh_pending_sales_return_from_sale() (Patch 4.1 Section 4, new — 0093)
// ---------------------------------------------------------------------------
export const refreshPendingSalesReturnSchema = z.object({
  return_id: z.string().uuid(),
  row_version: rowVersionSchema,
});

export type RefreshPendingSalesReturnInput = z.infer<typeof refreshPendingSalesReturnSchema>;

// ---------------------------------------------------------------------------
// approve_sales_return() (migration 0087, rewritten 0095) — fee_reversal_
// override is only meaningful (and only accepted server-side) when the
// order's payment method's refund_fee_policy is 'manual' — this schema does
// not know the policy, so it only validates shape/precision here; the DB is
// the real authority. Signature unchanged by Patch 4.1 (only the body was
// rewritten — business inputs live on the return itself, set at create/
// update-pending time, Section 16).
// ---------------------------------------------------------------------------
export const approveSalesReturnSchema = z.object({
  return_id: z.string().uuid(),
  row_version: rowVersionSchema,
  fee_reversal_override: z
    .string()
    .trim()
    .refine((v) => v === "" || (isNonNegativeDecimal(v) && hasMaxDecimalPlaces(v, 2)), "قيمة استرداد العمولة يجب أن تكون رقمًا موجبًا أو صفرًا (منزلتان عشريتان كحد أقصى)")
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  closed_day_reason: optionalText(500),
});

export type ApproveSalesReturnInput = z.infer<typeof approveSalesReturnSchema>;

// ---------------------------------------------------------------------------
// reject_sales_return() (migration 0087, rewritten 0095)
// ---------------------------------------------------------------------------
export const rejectSalesReturnSchema = z.object({
  return_id: z.string().uuid(),
  row_version: rowVersionSchema,
  rejection_reason: z.string({ required_error: "سبب الرفض مطلوب" }).trim().min(1, "سبب الرفض مطلوب").max(1000),
});

export type RejectSalesReturnInput = z.infer<typeof rejectSalesReturnSchema>;

// ---------------------------------------------------------------------------
// reverse_sales_return() (migration 0088, rewritten 0096) — gains an
// optional reversal_business_date (Section 9); defaults to business_today()
// server-side when omitted.
// ---------------------------------------------------------------------------
export const reverseSalesReturnSchema = z.object({
  return_id: z.string().uuid(),
  row_version: rowVersionSchema,
  reversal_reason: z.string({ required_error: "سبب التراجع مطلوب" }).trim().min(1, "سبب التراجع مطلوب").max(1000),
  reversal_business_date: optionalText(20),
  closed_day_reason: optionalText(500),
});

export type ReverseSalesReturnInput = z.infer<typeof reverseSalesReturnSchema>;

// ---------------------------------------------------------------------------
// record_sales_return_refund() (migration 0089, rewritten 0097, gains an
// optional reference in Hotfix 4.2.1 Section 6 / migration 0107) — gains an
// optional refund_business_date (Section 9).
// ---------------------------------------------------------------------------
export const recordSalesReturnRefundSchema = z.object({
  return_id: z.string().uuid(),
  amount: z
    .string({ required_error: "قيمة الاسترداد مطلوبة" })
    .trim()
    .refine((v) => isPositiveDecimal(v), "قيمة الاسترداد يجب أن تكون رقمًا أكبر من صفر")
    .refine((v) => hasMaxDecimalPlaces(v, 2), "قيمة الاسترداد يجب ألا تتجاوز منزلتين عشريتين"),
  refund_method_id: z.string({ required_error: "طريقة الاسترداد مطلوبة" }).uuid("طريقة استرداد غير صالحة"),
  refund_business_date: optionalText(20),
  notes: optionalText(1000),
  closed_day_reason: optionalText(500),
  // Hotfix 4.2.1 (Section 6) — optional free-text external reference (bank
  // transfer number, payment-gateway reference, internal reference). No
  // uniqueness enforced — different systems format references differently.
  reference: optionalText(200),
});

export type RecordSalesReturnRefundInput = z.infer<typeof recordSalesReturnRefundSchema>;

// ---------------------------------------------------------------------------
// reverse_sales_return_refund_event() (migration 0089, rewritten 0097) —
// gains an optional reversal_business_date (Section 9).
// ---------------------------------------------------------------------------
export const reverseSalesReturnRefundEventSchema = z.object({
  event_id: z.string().uuid(),
  reversal_reason: z.string({ required_error: "سبب التراجع مطلوب" }).trim().min(1, "سبب التراجع مطلوب").max(1000),
  reversal_business_date: optionalText(20),
  closed_day_reason: optionalText(500),
});

export type ReverseSalesReturnRefundEventInput = z.infer<typeof reverseSalesReturnRefundEventSchema>;

// ---------------------------------------------------------------------------
// finalize_sales_return_refund() (Patch 4.1 Section 11, new — 0097)
// ---------------------------------------------------------------------------
export const finalizeSalesReturnRefundSchema = z.object({
  return_id: z.string().uuid(),
  row_version: rowVersionSchema,
  variance_reason: optionalText(1000),
});

export type FinalizeSalesReturnRefundInput = z.infer<typeof finalizeSalesReturnRefundSchema>;

// ---------------------------------------------------------------------------
// reopen_sales_return_refund_reconciliation() (Patch 4.2 Section 4, new — 0103)
// ---------------------------------------------------------------------------
export const reopenSalesReturnRefundReconciliationSchema = z.object({
  return_id: z.string().uuid(),
  row_version: rowVersionSchema,
  reason: z.string({ required_error: "سبب إعادة الفتح مطلوب" }).trim().min(1, "سبب إعادة الفتح مطلوب").max(1000),
});

export type ReopenSalesReturnRefundReconciliationInput = z.infer<typeof reopenSalesReturnRefundReconciliationSchema>;

// ---------------------------------------------------------------------------
// list_sales_returns() (migration 0090, rewritten 0098) filters — Section
// 14 adds original_store_id/order_number/scenario.
// ---------------------------------------------------------------------------
export const returnsListFiltersSchema = z.object({
  date_from: z.string().optional(),
  date_to: z.string().optional(),
  processed_store_id: z.string().uuid().optional(),
  original_store_id: z.string().uuid().optional(),
  return_number: z.string().optional(),
  order_number: z.string().optional(),
  status: z.enum(RETURN_STATUSES).optional(),
  scenario: z.enum(RETURN_SCENARIOS).optional(),
  sales_order_id: z.string().uuid().optional(),
  page: z.number().int().min(1).default(1),
});

export type ReturnsListFilters = z.infer<typeof returnsListFiltersSchema>;

/** True when a DB error message indicates the target day is closed — mirrors sales/schema.ts's isClosedDayError(), used to trigger the mandatory closed_day_reason dialog instead of a dead-end error. */
export function isClosedDayError(message: string): boolean {
  return message.includes("مقفل");
}

/** True when a DB error message indicates an optimistic-concurrency Conflict (row_version mismatch) — mirrors sales/schema.ts's isVersionConflictError(). The client must reload (re-fetch row_version) rather than auto-resubmit. */
export function isVersionConflictError(message: string): boolean {
  return message.includes("مستخدم آخر");
}

/** True when a DB error message indicates the item is already EFFECTIVELY claimed by another approved return (Patch 4.1 Section 5 — sales_return_items_effective_claim_uq, migration 0092) — lets the UI show a targeted message and refresh the returnable-items list instead of a generic error. */
export function isItemAlreadyClaimedError(message: string): boolean {
  return message.includes("مرتجعة بالفعل") || message.includes("مرتبط بالفعل بمرتجع آخر نشط");
}

/** Patch 4.1 (Section 4) — true when a DB error message indicates the parent Sale changed since this Pending return was created/last refreshed (approve_sales_return()'s stale-sale guard, migration 0095). The UI should offer refresh_pending_sales_return_from_sale() instead of a dead-end error. */
export function isStaleSaleError(message: string): boolean {
  return message.includes("تم تعديل عملية البيع بعد إنشاء طلب المرتجع");
}

/** Patch 4.2 (Section 1) — true when a DB error message indicates this Pending return is flagged requires_sale_refresh (migration 0099/0101 — a legacy return whose item snapshots cannot be trusted without an explicit refresh, even though source_sale_row_version happens to match). The UI should offer refresh_pending_sales_return_from_sale() exactly like isStaleSaleError(), just for a different underlying reason. */
export function isSaleRefreshRequiredError(message: string): boolean {
  return message.includes("يجب تحديث بيانات المرتجع من عملية البيع قبل اعتماده");
}

/** Patch 4.2 (Section 3) — true when a DB error message indicates refund reconciliation for this return is already finalized, so record_sales_return_refund()/reverse_sales_return_refund_event() were rejected outright (migration 0103). The UI should offer reopen_sales_return_refund_reconciliation() instead of a dead-end error. */
export function isReconciliationFinalizedError(message: string): boolean {
  return message.includes("يجب إعادة فتح التسوية أولًا");
}

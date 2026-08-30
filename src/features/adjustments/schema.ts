import { z } from "zod";
import { hasMaxDecimalPlaces, isNonNegativeDecimal, isPositiveDecimal } from "@/lib/decimal";

// Every financial input here stays a STRING all the way to the RPC call —
// never parsed through Number()/parseFloat() at any point in this file or
// in actions.ts, exactly mirroring src/features/shipping/schema.ts and
// src/features/returns/schema.ts. This file only validates shape/presence
// of genuine business inputs; every cross-field money computation (payment
// fee resolution, gross/net profit) happens inside the DB
// (create_sales_order_adjustment()/approve_sales_order_adjustment(),
// migrations 0139/0140), never re-derived client-side. Direct cost/gross/net
// profit are entirely independent from Sales/Returns/Shipping (§2 of the
// governing spec) — this module never touches sales.subtotal or any Return/
// Shipping figure.

/** Mirrors sales_order_adjustments.status's check constraint (migration 0135). Base statuses only — 'reversed' is a server-derived effective_status, never stored. */
export const ADJUSTMENT_STATUSES = ["pending", "approved", "rejected"] as const;

/** Mirrors the server-computed effective_status returned by get_sales_order_adjustment()/list_sales_order_adjustments() (migration 0142). */
export const ADJUSTMENT_EFFECTIVE_STATUSES = ["pending", "approved", "rejected", "reversed"] as const;

export const ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR: Record<(typeof ADJUSTMENT_EFFECTIVE_STATUSES)[number], string> = {
  pending: "قيد الانتظار",
  approved: "معتمد",
  rejected: "مرفوض",
  reversed: "معكوس",
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

const optionalUuid = (label: string) =>
  z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined))
    .refine((v) => v === undefined || z.string().uuid().safeParse(v).success, `${label} غير صالحة`);

/**
 * Patch 6.1 items 9/10/28 — a genuinely FREE service (customer_charge = 0)
 * never carries a payment method/channel/reference, and never participates
 * in settlement — mirrors the DB's own sales_order_adjustments_zero_charge_
 * consistent CHECK (migration 0144) as a client-side pre-check, never the
 * source of truth. A non-zero charge requires both fields, matching
 * create_sales_order_adjustment()/update_sales_order_adjustment() v2's own
 * validation (migrations 0146/0147).
 */
function applyZeroChargeCrossFieldRules<
  T extends {
    customer_charge: string;
    payment_method_id?: string;
    collection_channel_id?: string;
    payment_reference?: string;
  },
>(data: T, ctx: z.RefinementCtx) {
  const isFree = isNonNegativeDecimal(data.customer_charge) && !isPositiveDecimal(data.customer_charge);
  if (isFree) {
    if (data.payment_method_id) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["payment_method_id"], message: "خدمة مجانية (تحصيل = 0) لا يجوز أن تحمل طريقة دفع" });
    }
    if (data.collection_channel_id) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["collection_channel_id"], message: "خدمة مجانية (تحصيل = 0) لا يجوز أن تحمل قناة تحصيل" });
    }
    if (data.payment_reference) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["payment_reference"], message: "خدمة مجانية (تحصيل = 0) لا يجوز أن تحمل مرجع دفع" });
    }
  } else {
    if (!data.payment_method_id) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["payment_method_id"], message: "طريقة الدفع مطلوبة لتعديل/خدمة بقيمة تحصيل أكبر من صفر" });
    }
    if (!data.collection_channel_id) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["collection_channel_id"], message: "قناة التحصيل مطلوبة لتعديل/خدمة بقيمة تحصيل أكبر من صفر" });
    }
  }
}

// ---------------------------------------------------------------------------
// create_sales_order_adjustment() v2 (migration 0146) — §36 + Patch 6.1
// items 9/10/11. direct_cost is accepted but NOT required while pending
// (§9); required only at approval time (enforced server-side by approve_
// sales_order_adjustment(), 0148) — AND now requires adjustments.manage_cost
// to supply at all (item 1A/1D — the entry-form component only renders the
// field for an actor holding that permission; a create-only actor must
// create with no cost and let a manage_cost holder set it afterward via the
// dedicated RPC, item 2). payment_method_id/collection_channel_id are now
// OPTIONAL (nullable for a genuinely free service, customer_charge = 0);
// participates_in_settlement stays a REQUIRED explicit boolean for a PAID
// record (§13) — no default, never inferred; the entry form forces/disables
// it to false for a free service. payment_reference is a NEW optional field
// (item 11), never accepted for a free service either.
// ---------------------------------------------------------------------------
export const createAdjustmentSchema = z
  .object({
    sales_order_id: z.string({ required_error: "عملية البيع مطلوبة" }).uuid("عملية بيع غير صالحة"),
    adjustment_type_id: z.string({ required_error: "نوع التعديل/الخدمة مطلوب" }).uuid("نوع غير صالح"),
    processing_store_id: z.string({ required_error: "المتجر المُعالِج مطلوب" }).uuid("متجر غير صالح"),
    adjustment_date: z.string({ required_error: "تاريخ التعديل/الخدمة مطلوب" }).trim().min(1, "تاريخ التعديل/الخدمة مطلوب"),
    payment_method_id: optionalUuid("طريقة الدفع"),
    collection_channel_id: optionalUuid("قناة التحصيل"),
    payment_reference: optionalText(200),
    participates_in_settlement: z.boolean({ required_error: "يجب تحديد ما إذا كان هذا التعديل ضمن التسوية" }),
    customer_charge: moneyAmountSchema("قيمة تحصيل العميل"),
    direct_cost: optionalMoneyAmountSchema("التكلفة المباشرة"),
    notes: optionalText(1000),
    closed_day_reason: optionalText(500),
  })
  .superRefine(applyZeroChargeCrossFieldRules);

export type CreateAdjustmentInput = z.infer<typeof createAdjustmentSchema>;

// ---------------------------------------------------------------------------
// update_sales_order_adjustment() v2 (migration 0147) — §16 + Patch 6.1 item
// 11. sales_order_id is intentionally NOT part of this schema — the order
// link is immutable. direct_cost is INTENTIONALLY ABSENT — 0147 dropped the
// parameter entirely (item 1B); the ONLY way to set/change a Pending
// record's direct_cost is the dedicated set_pending_sales_order_adjustment_
// direct_cost() RPC (0145, see setAdjustmentCostSchema below), never this
// general-purpose update. payment_method_id/collection_channel_id/
// payment_reference follow the same zero-charge rules as create.
// ---------------------------------------------------------------------------
export const updateAdjustmentSchema = z
  .object({
    id: z.string().uuid(),
    row_version: rowVersionSchema,
    adjustment_type_id: z.string({ required_error: "نوع التعديل/الخدمة مطلوب" }).uuid("نوع غير صالح"),
    processing_store_id: z.string({ required_error: "المتجر المُعالِج مطلوب" }).uuid("متجر غير صالح"),
    adjustment_date: z.string({ required_error: "تاريخ التعديل/الخدمة مطلوب" }).trim().min(1, "تاريخ التعديل/الخدمة مطلوب"),
    payment_method_id: optionalUuid("طريقة الدفع"),
    collection_channel_id: optionalUuid("قناة التحصيل"),
    payment_reference: optionalText(200),
    participates_in_settlement: z.boolean({ required_error: "يجب تحديد ما إذا كان هذا التعديل ضمن التسوية" }),
    customer_charge: moneyAmountSchema("قيمة تحصيل العميل"),
    notes: optionalText(1000),
    closed_day_reason: optionalText(500),
  })
  .superRefine(applyZeroChargeCrossFieldRules);

export type UpdateAdjustmentInput = z.infer<typeof updateAdjustmentSchema>;

// ---------------------------------------------------------------------------
// set_pending_sales_order_adjustment_direct_cost() (migration 0145) —
// Patch 6.1 item 2. The SINGLE sanctioned path for setting/correcting a
// PENDING record's direct_cost — requires adjustments.manage_cost ALONE
// (never adjustments.create/approve). Unlike the optional field on create,
// direct_cost is REQUIRED here — this RPC exists specifically to supply it.
// ---------------------------------------------------------------------------
export const setAdjustmentCostSchema = z.object({
  id: z.string().uuid(),
  row_version: rowVersionSchema,
  direct_cost: moneyAmountSchema("التكلفة المباشرة"),
  closed_day_reason: optionalText(500),
});

export type SetAdjustmentCostInput = z.infer<typeof setAdjustmentCostSchema>;

// ---------------------------------------------------------------------------
// approve_sales_order_adjustment() (migration 0140) — §17.
// ---------------------------------------------------------------------------
export const approveAdjustmentSchema = z.object({
  id: z.string().uuid(),
  row_version: rowVersionSchema,
  closed_day_reason: optionalText(500),
});

export type ApproveAdjustmentInput = z.infer<typeof approveAdjustmentSchema>;

// ---------------------------------------------------------------------------
// reject_sales_order_adjustment() (migration 0140) — §18, mandatory reason.
// ---------------------------------------------------------------------------
export const rejectAdjustmentSchema = z.object({
  id: z.string().uuid(),
  row_version: rowVersionSchema,
  reason: z.string({ required_error: "سبب الرفض مطلوب" }).trim().min(1, "سبب الرفض مطلوب").max(1000),
});

export type RejectAdjustmentInput = z.infer<typeof rejectAdjustmentSchema>;

// ---------------------------------------------------------------------------
// reverse_sales_order_adjustment() (migration 0141) — §19/§20/§21, mandatory
// reason + reversal_business_date. Append-only administrative reversal, NOT
// a customer refund engine.
// ---------------------------------------------------------------------------
export const reverseAdjustmentSchema = z.object({
  id: z.string().uuid(),
  row_version: rowVersionSchema,
  reversal_business_date: z.string({ required_error: "تاريخ العكس مطلوب" }).trim().min(1, "تاريخ العكس مطلوب"),
  reason: z.string({ required_error: "سبب العكس مطلوب" }).trim().min(1, "سبب العكس مطلوب").max(1000),
  closed_day_reason: optionalText(500),
});

export type ReverseAdjustmentInput = z.infer<typeof reverseAdjustmentSchema>;

// ---------------------------------------------------------------------------
// adjustment_types CRUD (migration 0136) — §5/§6. `code` is permanent once
// created; only accepted on create, never on update.
// ---------------------------------------------------------------------------
export const adjustmentTypeFormSchema = z.object({
  code: z
    .string({ required_error: "الرمز مطلوب" })
    .trim()
    .min(2, "الرمز قصير جدًا")
    .max(40, "الرمز طويل جدًا")
    .regex(/^[a-z0-9_]+$/, "الرمز يجب أن يتكون من حروف إنجليزية صغيرة وأرقام و _ فقط")
    .optional(),
  name_ar: z.string({ required_error: "الاسم بالعربية مطلوب" }).trim().min(1, "الاسم مطلوب").max(80),
  name_en: z
    .string()
    .trim()
    .max(80)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  description: optionalText(500),
  sort_order: z.coerce.number().int().min(0).max(10000).optional().default(0),
});

export type AdjustmentTypeFormInput = z.infer<typeof adjustmentTypeFormSchema>;

// ---------------------------------------------------------------------------
// list_sales_order_adjustments() filters — §38, expanded by Patch 6.1 item
// 21 (migration 0151): original_sale_store_id (the linked Sale's OWN store,
// distinct from processing store_id)/payment_method_id/collection_
// channel_id/participates_in_settlement.
// ---------------------------------------------------------------------------
export const adjustmentsListFiltersSchema = z.object({
  sales_order_id: z.string().uuid().optional(),
  store_id: z.string().uuid().optional(),
  original_sale_store_id: z.string().uuid().optional(),
  status: z.enum(ADJUSTMENT_EFFECTIVE_STATUSES).optional(),
  adjustment_type_id: z.string().uuid().optional(),
  payment_method_id: z.string().uuid().optional(),
  collection_channel_id: z.string().uuid().optional(),
  participates_in_settlement: z.boolean().optional(),
  date_from: z.string().optional(),
  date_to: z.string().optional(),
  search: z.string().optional(),
  page: z.number().int().min(1).default(1),
});

export type AdjustmentsListFilters = z.infer<typeof adjustmentsListFiltersSchema>;

/** True when a DB error message indicates the target day is closed — mirrors shipping/returns schema.ts's isClosedDayError(). */
export function isClosedDayError(message: string): boolean {
  return message.includes("مقفل");
}

/** True when a DB error message indicates an optimistic-concurrency Conflict (row_version mismatch) — the client must reload rather than auto-resubmit. */
export function isVersionConflictError(message: string): boolean {
  return message.includes("جهة أخرى");
}

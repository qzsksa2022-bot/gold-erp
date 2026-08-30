import { z } from "zod";
import { hasMaxDecimalPlaces, isNonNegativeDecimal, toDecimal } from "@/lib/decimal";

// Every financial input here stays a STRING all the way to the RPC call —
// never parsed through Number()/parseFloat()/parseInt() at any point in
// this file or in actions.ts, exactly mirroring
// src/features/adjustments/schema.ts. This file only validates
// shape/presence of genuine business inputs; every cross-field money
// computation (source gross/fee resolution, batch-fee application, actual/
// variance) happens inside the DB (finalize_settlement_batch()/reconcile_
// settlement_batch(), migrations 0178/0180), never re-derived client-side.
//
// Hotfix 7.1.1 §13 — this file previously used Number(v) TWICE, both inside
// .refine() validation callbacks (a percentage upper-bound check and a
// nonzero check) — the governing spec explicitly closed the "it's only
// inside refine" exception: even a comparison-only, non-mutating Number()
// call is still a JS float parse of a money/percent value, and is banned
// here unconditionally. Both are replaced with Decimal-based comparisons
// via toDecimal() (src/lib/decimal.ts, the project's single source of truth
// for financial arithmetic) — the validated string itself is still what
// gets returned/submitted, exactly as before; only the COMPARISON now goes
// through decimal.js instead of IEEE-754 double parsing.

/** Mirrors settlement_routes.route_kind's check constraint (migration 0168). */
export const SETTLEMENT_ROUTE_KINDS = ["payment_collection", "cod_carrier"] as const;

export const SETTLEMENT_ROUTE_KIND_LABELS_AR: Record<(typeof SETTLEMENT_ROUTE_KINDS)[number], string> = {
  payment_collection: "تحصيل دفع",
  cod_carrier: "COD ناقل شحن",
};

/** Mirrors settlement_batches.status's check constraint (migration 0172). Base statuses only — 'cancelled' is a server-derived effective_status, never stored (item 17). */
export const SETTLEMENT_BATCH_STATUSES = ["draft", "finalized", "reconciled"] as const;

/** Mirrors the server-computed effective_status returned by list_settlement_batches()/get_settlement_batch() (migration 0182). */
export const SETTLEMENT_BATCH_EFFECTIVE_STATUSES = ["draft", "finalized", "reconciled", "cancelled"] as const;

export const SETTLEMENT_BATCH_STATUS_LABELS_AR: Record<(typeof SETTLEMENT_BATCH_EFFECTIVE_STATUSES)[number], string> = {
  draft: "مسودة",
  finalized: "معتمدة",
  reconciled: "مطابَقة",
  cancelled: "ملغاة",
};

/** Mirrors settlement_route_fee_versions.transaction_fee_strategy's check constraint (migration 0170). */
export const TRANSACTION_FEE_STRATEGIES = ["source_snapshot", "route_formula", "none"] as const;

export const TRANSACTION_FEE_STRATEGY_LABELS_AR: Record<(typeof TRANSACTION_FEE_STRATEGIES)[number], string> = {
  source_snapshot: "استخدام اللقطة الأصلية للمصدر",
  route_formula: "معادلة خاصة بالمسار",
  none: "بدون رسوم",
};

/** Mirrors settlement_route_fee_versions.transaction_fee_model's check constraint (migration 0170). */
export const TRANSACTION_FEE_MODELS = ["percentage", "fixed", "percentage_plus_fixed", "none"] as const;

export const TRANSACTION_FEE_MODEL_LABELS_AR: Record<(typeof TRANSACTION_FEE_MODELS)[number], string> = {
  percentage: "نسبة مئوية",
  fixed: "قيمة ثابتة",
  percentage_plus_fixed: "نسبة مئوية + قيمة ثابتة",
  none: "بدون",
};

/** Mirrors settlement_route_fee_versions.cod_fee_reversal_policy's check constraint (migration 0170). */
export const COD_FEE_REVERSAL_POLICIES = ["full", "proportional", "none"] as const;

export const COD_FEE_REVERSAL_POLICY_LABELS_AR: Record<(typeof COD_FEE_REVERSAL_POLICIES)[number], string> = {
  full: "عكس كامل",
  proportional: "عكس تناسبي",
  none: "بدون عكس",
};

/**
 * Labels for settlement_batch_lines.source_kind /
 * _settlement_unsettled_source_candidates.source_kind. 'return_refund'/
 * 'return_refund_reversal' are DEAD as of Patch 7.1 (migration 0184) —
 * never emitted by new discovery/preview — but are RETAINED here (never
 * removed) because they may still appear on old, already-finalized
 * settlement_batch_lines rows read via get_settlement_batch(). The 4 new
 * kinds ('return_refund_event'/'return_refund_event_reversal'/
 * 'return_fee_reversal'/'return_fee_reversal_reversal') replace them going
 * forward — labels match 0184's own source_label prefixes exactly
 * ('استرداد فعلي '/'عكس استرداد فعلي '/'استرداد عمولة '/'عكس استرداد عمولة ').
 */
export const SOURCE_KIND_LABELS_AR: Record<string, string> = {
  sale: "عملية بيع",
  return_refund: "استرداد مرتجع",
  return_refund_reversal: "عكس استرداد مرتجع",
  return_refund_event: "استرداد فعلي",
  return_refund_event_reversal: "عكس استرداد فعلي",
  return_fee_reversal: "استرداد عمولة",
  return_fee_reversal_reversal: "عكس استرداد عمولة",
  adjustment_approved: "تعديل/خدمة معتمد",
  adjustment_reversal: "عكس تعديل/خدمة",
  cod_collection: "تحصيل COD",
  cod_reversal: "عكس تحصيل COD",
};

const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined));

const requiredText = (label: string, max: number) =>
  z
    .string({ required_error: `${label} مطلوب` })
    .trim()
    .min(1, `${label} مطلوب`)
    .max(max);

const rowVersionSchema = z.number({ required_error: "إصدار السجل مطلوب" }).int().nonnegative();

const optionalUuid = (label: string) =>
  z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined))
    .refine((v) => v === undefined || z.string().uuid().safeParse(v).success, `${label} غير صالحة`);

/** A non-negative money amount, at most 2 decimal places (batch fee, fixed fee). */
const nonNegativeMoneySchema = (label: string) =>
  z
    .string({ required_error: `${label} مطلوبة` })
    .trim()
    .refine((v) => isNonNegativeDecimal(v), `${label} يجب أن تكون رقمًا موجبًا أو صفرًا`)
    .refine((v) => hasMaxDecimalPlaces(v, 2), `${label} يجب ألا تتجاوز منزلتين عشريتين`);

const optionalNonNegativeMoneySchema = (label: string) =>
  z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined))
    .refine((v) => v === undefined || (isNonNegativeDecimal(v) && hasMaxDecimalPlaces(v, 2)), `${label} يجب أن تكون رقمًا موجبًا أو صفرًا (منزلتان عشريتان كحد أقصى)`);

/**
 * A non-negative money amount, at most 4 decimal places — used ONLY for
 * fixed_fee, which is numeric(12,4) (migration 0170). Patch 7.1 §18 fixed
 * create_settlement_route_fee_version() to actually validate p_fixed_fee to
 * 4dp (validate_money_scale_n(), 0190) instead of the old hardcoded-2dp
 * validate_money_scale() — this client-side pre-check must match, never
 * artificially cap fixed_fee to 2dp like every other money field here.
 */
const optionalFixedFeeMoneySchema = (label: string) =>
  z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined))
    .refine((v) => v === undefined || (isNonNegativeDecimal(v) && hasMaxDecimalPlaces(v, 4)), `${label} يجب أن تكون رقمًا موجبًا أو صفرًا (4 منازل عشرية كحد أقصى)`);

/** A non-negative percentage (0-100), at most 3 decimal places (matches percentage_fee numeric(6,3), migration 0170). */
const optionalPercentageSchema = (label: string) =>
  z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined))
    .refine(
      (v) => v === undefined || (isNonNegativeDecimal(v) && hasMaxDecimalPlaces(v, 3) && toDecimal(v).lte(100)),
      `${label} يجب أن تكون رقمًا بين 0 و100 (3 منازل عشرية كحد أقصى)`,
    );

/** A signed, non-zero bank movement amount (deposit = positive, debit/withdrawal = negative — never assumed always-positive, per record_settlement_bank_movement()'s own comment, migration 0179). */
const signedNonZeroMoneySchema = z
  .string({ required_error: "قيمة الحركة البنكية مطلوبة" })
  .trim()
  .refine((v) => {
    if (v === "" || v === "-" || v === "+") return false;
    if (!/^-?\d+(\.\d+)?$/.test(v)) return false;
    return true;
  }, "قيمة الحركة البنكية يجب أن تكون رقمًا صالحًا")
  .refine((v) => {
    // Guarded like decimal.ts's own isNonNegativeDecimal()/hasMaxDecimalPlaces()
    // helpers — the PREVIOUS refine above already rejects anything that
    // doesn't match the signed-decimal regex (""/"-"/"+"/garbage), but Zod's
    // chained .refine() calls each run independently against the same raw
    // value regardless of an earlier refine's result (no short-circuit) —
    // so an unguarded toDecimal(v) here still executes for that same bad
    // input and throws a raw DecimalError instead of a normal Zod
    // validation failure. Returning true on a throw is safe: the format
    // refine above has already flagged the value, so this one simply
    // declines to pile on a second, contradictory error message.
    try {
      return !toDecimal(v).isZero();
    } catch {
      return true;
    }
  }, "قيمة الحركة البنكية يجب ألا تساوي صفرًا")
  .refine((v) => hasMaxDecimalPlaces(v, 2), "قيمة الحركة البنكية يجب ألا تتجاوز منزلتين عشريتين");

// ---------------------------------------------------------------------------
// settlement_routes CRUD (migration 0169) — code/route_kind/payment_method_
// id/collection_channel_id/shipping_carrier_id are permanent once created
// (item 36); only accepted on create, never on update.
// ---------------------------------------------------------------------------
export const createSettlementRouteSchema = z
  .object({
    code: z
      .string({ required_error: "الرمز مطلوب" })
      .trim()
      .min(2, "الرمز قصير جدًا")
      .max(40, "الرمز طويل جدًا")
      .regex(/^[a-z0-9_]+$/, "الرمز يجب أن يتكون من حروف إنجليزية صغيرة وأرقام و _ فقط"),
    name_ar: requiredText("الاسم بالعربية", 80),
    name_en: optionalText(80),
    route_kind: z.enum(SETTLEMENT_ROUTE_KINDS, { required_error: "نوع مسار التسوية مطلوب" }),
    payment_method_id: optionalUuid("طريقة الدفع"),
    collection_channel_id: optionalUuid("قناة التحصيل"),
    shipping_carrier_id: optionalUuid("شركة الشحن"),
    description: optionalText(500),
  })
  .superRefine((data, ctx) => {
    if (data.route_kind === "payment_collection") {
      if (!data.payment_method_id) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["payment_method_id"], message: "طريقة الدفع مطلوبة لمسار تحصيل دفع" });
      }
      if (data.shipping_carrier_id) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["shipping_carrier_id"], message: "مسار تحصيل الدفع لا يجوز أن يحدد شركة شحن" });
      }
    } else {
      if (!data.shipping_carrier_id) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["shipping_carrier_id"], message: "شركة الشحن مطلوبة لمسار COD الناقل" });
      }
      if (data.payment_method_id) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["payment_method_id"], message: "مسار COD الناقل لا يجوز أن يحدد طريقة دفع" });
      }
      if (data.collection_channel_id) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["collection_channel_id"], message: "مسار COD الناقل لا يجوز أن يحدد قناة تحصيل" });
      }
    }
  });

export type CreateSettlementRouteInput = z.infer<typeof createSettlementRouteSchema>;

export const updateSettlementRouteSchema = z.object({
  id: z.string().uuid(),
  name_ar: requiredText("الاسم بالعربية", 80),
  name_en: optionalText(80),
  description: optionalText(500),
});

export type UpdateSettlementRouteInput = z.infer<typeof updateSettlementRouteSchema>;

// ---------------------------------------------------------------------------
// settlement_route_fee_versions create/cancel (migration 0171) — mirrors the
// enforce_settlement_route_fee_version_invariants() DB trigger (0170) as a
// client-side pre-check only; the DB is the sole source of truth.
// ---------------------------------------------------------------------------
export const createSettlementRouteFeeVersionSchema = z
  .object({
    settlement_route_id: z.string({ required_error: "مسار التسوية مطلوب" }).uuid(),
    route_kind: z.enum(SETTLEMENT_ROUTE_KINDS),
    effective_from: requiredText("تاريخ السريان", 10),
    transaction_fee_strategy: z.enum(TRANSACTION_FEE_STRATEGIES, { required_error: "استراتيجية الرسوم مطلوبة" }),
    transaction_fee_model: z.enum(TRANSACTION_FEE_MODELS).optional(),
    percentage_fee: optionalPercentageSchema("النسبة المئوية للرسوم"),
    fixed_fee: optionalFixedFeeMoneySchema("القيمة الثابتة للرسوم"),
    batch_fee_fixed: nonNegativeMoneySchema("رسوم الدفعة الثابتة").default("0"),
    cod_fee_reversal_policy: z.enum(COD_FEE_REVERSAL_POLICIES).optional(),
    notes: optionalText(500),
  })
  .superRefine((data, ctx) => {
    // Hotfix 7.1.1 §14 — create_settlement_route_fee_version() (Patch 7.1
    // §19, migration 0190) rejects transaction_fee_strategy='source_
    // snapshot' for a cod_carrier route at the DB layer (there is no
    // source-level fee snapshot for COD events at all) — this client-side
    // mirror stops the invalid combination from ever reaching the server in
    // the first place instead of round-tripping a rejection. The DB
    // invariant remains the sole source of truth; this is a UX pre-check
    // only.
    if (data.route_kind === "cod_carrier" && data.transaction_fee_strategy === "source_snapshot") {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["transaction_fee_strategy"],
        message: "استراتيجية source_snapshot غير صالحة لمسار COD ناقل — لا يوجد لقطة رسوم على مستوى المصدر لأحداث COD، استخدم route_formula أو بدون رسوم",
      });
    }
    if (data.transaction_fee_strategy === "route_formula") {
      if (!data.transaction_fee_model) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["transaction_fee_model"], message: "شكل الرسوم مطلوب عند اختيار معادلة خاصة بالمسار" });
      } else {
        if (["percentage", "percentage_plus_fixed"].includes(data.transaction_fee_model) && !data.percentage_fee) {
          ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["percentage_fee"], message: "النسبة المئوية مطلوبة لهذا الشكل" });
        }
        if (["fixed", "percentage_plus_fixed"].includes(data.transaction_fee_model) && !data.fixed_fee) {
          ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["fixed_fee"], message: "القيمة الثابتة مطلوبة لهذا الشكل" });
        }
      }
      if (data.route_kind === "cod_carrier" && !data.cod_fee_reversal_policy) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["cod_fee_reversal_policy"], message: "سياسة عكس رسوم COD مطلوبة لمسار COD الناقل عند استخدام معادلة خاصة" });
      }
    } else if (data.cod_fee_reversal_policy) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["cod_fee_reversal_policy"], message: "سياسة عكس رسوم COD لا تنطبق إلا مع معادلة خاصة بالمسار" });
    }
  });

export type CreateSettlementRouteFeeVersionInput = z.infer<typeof createSettlementRouteFeeVersionSchema>;

export const cancelSettlementRouteFeeVersionSchema = z.object({
  version_id: z.string().uuid(),
});

// ---------------------------------------------------------------------------
// settlement_batches draft lifecycle (migration 0177).
// ---------------------------------------------------------------------------
export const createDraftSettlementBatchSchema = z.object({
  settlement_route_id: z.string({ required_error: "مسار التسوية مطلوب" }).uuid("مسار غير صالح"),
  settlement_date: requiredText("تاريخ التسوية", 10),
  provider_statement_reference: optionalText(200),
  notes: optionalText(1000),
});

export type CreateDraftSettlementBatchInput = z.infer<typeof createDraftSettlementBatchSchema>;

export const updateDraftSettlementBatchSchema = z.object({
  id: z.string().uuid(),
  row_version: rowVersionSchema,
  settlement_route_id: z.string({ required_error: "مسار التسوية مطلوب" }).uuid("مسار غير صالح"),
  settlement_date: requiredText("تاريخ التسوية", 10),
  provider_statement_reference: optionalText(200),
  notes: optionalText(1000),
});

export type UpdateDraftSettlementBatchInput = z.infer<typeof updateDraftSettlementBatchSchema>;

// ---------------------------------------------------------------------------
// finalize_settlement_batch() (migration 0178) — p_selected_sources is a
// JSONB array of {"source_kind","source_event_id"} tokens (never a money
// figure, item 1/23). Batch-fee override + closed-day-reason are both
// OPTIONAL, permission-gated server-side (settlements.override_batch_fee /
// settlements.process_closed_day respectively) — this schema only checks
// the override_reason<->override presence pairing client-side.
// ---------------------------------------------------------------------------
export const selectedSourceTokenSchema = z.object({
  source_kind: z.string().min(1),
  source_event_id: z.string().uuid(),
});

export type SelectedSourceToken = z.infer<typeof selectedSourceTokenSchema>;

export const finalizeSettlementBatchSchema = z
  .object({
    id: z.string().uuid(),
    row_version: rowVersionSchema,
    selected_sources: z.array(selectedSourceTokenSchema).min(1, "يجب اختيار مصدر واحد على الأقل لاعتماد الدفعة"),
    batch_fee_override: optionalNonNegativeMoneySchema("رسوم الدفعة (تجاوز)"),
    override_reason: optionalText(500),
    closed_day_reason: optionalText(500),
  })
  .superRefine((data, ctx) => {
    if (data.batch_fee_override !== undefined && !data.override_reason) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ["override_reason"], message: "يجب إدخال سبب لتجاوز رسوم الدفعة الافتراضية" });
    }
  });

export type FinalizeSettlementBatchInput = z.infer<typeof finalizeSettlementBatchSchema>;

// ---------------------------------------------------------------------------
// settlement_bank_movement_events record/reverse (migration 0179, Daily
// Close + p_closed_day_reason added in Patch 7.1 §12, migration 0188 —
// mirrors the ClosedDayReasonDialog retry pattern used everywhere else in
// this codebase: the first submission never sends a reason, and the UI only
// asks for one after the server rejects with the closed-day error).
// ---------------------------------------------------------------------------
export const recordSettlementBankMovementSchema = z.object({
  settlement_batch_id: z.string().uuid(),
  movement_business_date: requiredText("تاريخ الحركة البنكية", 10),
  amount: signedNonZeroMoneySchema,
  bank_reference: optionalText(200),
  notes: optionalText(1000),
  closed_day_reason: optionalText(500),
});

export type RecordSettlementBankMovementInput = z.infer<typeof recordSettlementBankMovementSchema>;

export const reverseSettlementBankMovementSchema = z.object({
  bank_movement_event_id: z.string().uuid(),
  reversal_business_date: requiredText("تاريخ عكس الحركة البنكية", 10),
  reason: requiredText("سبب عكس الحركة البنكية", 1000),
  closed_day_reason: optionalText(500),
});

export type ReverseSettlementBankMovementInput = z.infer<typeof reverseSettlementBankMovementSchema>;

// ---------------------------------------------------------------------------
// reconcile_settlement_batch() (migration 0180) — variance_reason is only
// mandatory when the DB computes a nonzero variance (never knowable
// client-side ahead of time, since actual/variance are computed live) — the
// UI retries with a reason after the server's first rejection, exactly
// mirroring the closed-day-reason retry pattern.
// ---------------------------------------------------------------------------
export const reconcileSettlementBatchSchema = z.object({
  id: z.string().uuid(),
  row_version: rowVersionSchema,
  variance_reason: optionalText(1000),
});

export type ReconcileSettlementBatchInput = z.infer<typeof reconcileSettlementBatchSchema>;

// ---------------------------------------------------------------------------
// cancel_settlement_batch() (migration 0181) — mandatory reason + business
// date. Never touches settlement_batches/lines/reconciliation history. Gains
// p_closed_day_reason in Patch 7.1 §12 (migration 0188) — same retry pattern
// as record/reverse bank movement above.
// ---------------------------------------------------------------------------
export const cancelSettlementBatchSchema = z.object({
  id: z.string().uuid(),
  row_version: rowVersionSchema,
  cancellation_business_date: requiredText("تاريخ الإلغاء", 10),
  reason: requiredText("سبب الإلغاء", 1000),
  closed_day_reason: optionalText(500),
});

export type CancelSettlementBatchInput = z.infer<typeof cancelSettlementBatchSchema>;

// ---------------------------------------------------------------------------
// list_settlement_batches() filters (migration 0182, complete filter set +
// original/effective semantics added in Patch 7.1 §25/§26, migration 0191).
// `effective_status` replaces the old plain `status` filter — it is a
// strict superset (draft/finalized/reconciled, PLUS 'cancelled', which is a
// server-derived status and was never independently filterable before
// 0191's p_effective_status[] parameter existed). `has_variance` is only
// ever sent when the actor holds settlements.view_financials — the RPC
// itself refuses the filter outright otherwise (§25), so the UI never even
// offers the control without that permission.
// ---------------------------------------------------------------------------
export const settlementBatchesListFiltersSchema = z.object({
  effective_status: z.enum(SETTLEMENT_BATCH_EFFECTIVE_STATUSES).optional(),
  settlement_route_id: z.string().uuid().optional(),
  route_kind: z.enum(SETTLEMENT_ROUTE_KINDS).optional(),
  payment_method_id: z.string().uuid().optional(),
  collection_channel_id: z.string().uuid().optional(),
  shipping_carrier_id: z.string().uuid().optional(),
  store_id: z.string().uuid().optional(),
  has_variance: z.boolean().optional(),
  date_from: z.string().optional(),
  date_to: z.string().optional(),
  search: z.string().optional(),
  page: z.number().int().min(1).default(1),
});

export type SettlementBatchesListFilters = z.infer<typeof settlementBatchesListFiltersSchema>;

/** True when a DB error message indicates the target day is closed — mirrors adjustments/schema.ts's isClosedDayError(). */
export function isClosedDayError(message: string): boolean {
  return message.includes("مقفل");
}

/** True when a DB error message indicates an optimistic-concurrency Conflict (row_version mismatch) — the client must reload rather than auto-resubmit. */
export function isVersionConflictError(message: string): boolean {
  return message.includes("جهة أخرى") || message.includes("مستخدم آخر");
}

/** True when reconcile_settlement_batch() rejected because a NONZERO variance needs a mandatory reason (the actor already holds settlements.reconcile_variance) — distinct from the "lacks permission entirely" message, which is shown as a plain error instead. */
export function isVarianceReasonRequiredError(message: string): boolean {
  return message.includes("يجب إدخال سبب لفرق المطابقة");
}

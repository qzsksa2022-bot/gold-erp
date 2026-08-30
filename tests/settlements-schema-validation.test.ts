import { describe, expect, it } from "vitest";
import {
  finalizeSettlementBatchSchema,
  cancelSettlementBatchSchema,
  reconcileSettlementBatchSchema,
  recordSettlementBankMovementSchema,
  reverseSettlementBankMovementSchema,
  createSettlementRouteSchema,
  createSettlementRouteFeeVersionSchema,
  isClosedDayError,
  isVersionConflictError,
  isVarianceReasonRequiredError,
} from "@/features/settlements/schema";

// Phase 7 (Settlements Core) — Zod-layer regression tests, mirroring
// tests/adjustments-zero-charge-schema.test.ts's precedent: every one of
// these rules also exists as a DB-level guard (see supabase/tests/
// settlements_phase7.test.sql), so this file's job is only to prove the
// CLIENT-SIDE pre-check actually rejects bad input before a Server Action
// would ever reach the RPC (exercised separately in
// tests/settlements-actions-permission-boundary.test.ts).

const BATCH_ID = "11111111-1111-1111-1111-111111111111";
const SOURCE_EVENT_ID = "22222222-2222-2222-2222-222222222222";
const ROUTE_ID = "33333333-3333-3333-3333-333333333333";
const PM_ID = "44444444-4444-4444-4444-444444444444";
const CHANNEL_ID = "55555555-5555-5555-5555-555555555555";
const CARRIER_ID = "66666666-6666-6666-6666-666666666666";

describe("finalizeSettlementBatchSchema — item 1/23: at least one selected source, batch-fee override <-> reason pairing", () => {
  it("rejects an empty selected_sources array — 'اعتماد بلا مصادر' must never reach the RPC", () => {
    const result = finalizeSettlementBatchSchema.safeParse({
      id: BATCH_ID,
      row_version: 1,
      selected_sources: [],
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.selected_sources?.[0]).toContain("مصدر واحد على الأقل");
    }
  });

  it("accepts exactly one selected source", () => {
    const result = finalizeSettlementBatchSchema.safeParse({
      id: BATCH_ID,
      row_version: 1,
      selected_sources: [{ source_kind: "sale", source_event_id: SOURCE_EVENT_ID }],
    });
    expect(result.success).toBe(true);
  });

  it("rejects a batch_fee_override with no override_reason", () => {
    const result = finalizeSettlementBatchSchema.safeParse({
      id: BATCH_ID,
      row_version: 1,
      selected_sources: [{ source_kind: "sale", source_event_id: SOURCE_EVENT_ID }],
      batch_fee_override: "15.00",
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.override_reason).toBeDefined();
    }
  });

  it("accepts a batch_fee_override paired with a non-blank override_reason", () => {
    const result = finalizeSettlementBatchSchema.safeParse({
      id: BATCH_ID,
      row_version: 1,
      selected_sources: [{ source_kind: "sale", source_event_id: SOURCE_EVENT_ID }],
      batch_fee_override: "15.00",
      override_reason: "اتفاق خاص مع المزوّد",
    });
    expect(result.success).toBe(true);
  });

  it("a negative batch_fee_override is rejected even with a reason present (mirrors the DB's own rejection)", () => {
    const result = finalizeSettlementBatchSchema.safeParse({
      id: BATCH_ID,
      row_version: 1,
      selected_sources: [{ source_kind: "sale", source_event_id: SOURCE_EVENT_ID }],
      batch_fee_override: "-5.00",
      override_reason: "سبب",
    });
    expect(result.success).toBe(false);
  });
});

describe("cancelSettlementBatchSchema — mandatory cancellation reason", () => {
  it("rejects a blank reason", () => {
    const result = cancelSettlementBatchSchema.safeParse({
      id: BATCH_ID,
      row_version: 1,
      cancellation_business_date: "2026-08-20",
      reason: "",
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.reason).toBeDefined();
    }
  });

  it("rejects a whitespace-only reason (trimmed to empty)", () => {
    const result = cancelSettlementBatchSchema.safeParse({
      id: BATCH_ID,
      row_version: 1,
      cancellation_business_date: "2026-08-20",
      reason: "   ",
    });
    expect(result.success).toBe(false);
  });

  it("accepts a non-blank reason", () => {
    const result = cancelSettlementBatchSchema.safeParse({
      id: BATCH_ID,
      row_version: 1,
      cancellation_business_date: "2026-08-20",
      reason: "خطأ في اختيار المسار",
    });
    expect(result.success).toBe(true);
  });
});

describe("reconcileSettlementBatchSchema — variance_reason is OPTIONAL at the schema layer (mandatory-ness is a live server-computed fact, per the schema's own comment — the UI retries with a reason only after the RPC's first rejection)", () => {
  it("accepts no variance_reason at all", () => {
    const result = reconcileSettlementBatchSchema.safeParse({ id: BATCH_ID, row_version: 1 });
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.variance_reason).toBeUndefined();
    }
  });

  it("an empty-string variance_reason is normalized to undefined, never sent as a blank string", () => {
    const result = reconcileSettlementBatchSchema.safeParse({ id: BATCH_ID, row_version: 1, variance_reason: "" });
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.variance_reason).toBeUndefined();
    }
  });

  it("a supplied non-blank variance_reason passes through untouched", () => {
    const result = reconcileSettlementBatchSchema.safeParse({ id: BATCH_ID, row_version: 1, variance_reason: "فرق بنكي بسبب رسوم إضافية" });
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.variance_reason).toBe("فرق بنكي بسبب رسوم إضافية");
    }
  });
});

describe("reverseSettlementBankMovementSchema — mandatory reversal reason", () => {
  it("rejects a blank reason", () => {
    const result = reverseSettlementBankMovementSchema.safeParse({
      bank_movement_event_id: BATCH_ID,
      reversal_business_date: "2026-08-20",
      reason: "",
    });
    expect(result.success).toBe(false);
  });

  it("accepts a non-blank reason", () => {
    const result = reverseSettlementBankMovementSchema.safeParse({
      bank_movement_event_id: BATCH_ID,
      reversal_business_date: "2026-08-20",
      reason: "قيد بنكي خاطئ",
    });
    expect(result.success).toBe(true);
  });
});

describe("recordSettlementBankMovementSchema — signed, NON-ZERO bank movement amount (0179's own comment: deposit=positive, debit=negative)", () => {
  const BASE = { settlement_batch_id: BATCH_ID, movement_business_date: "2026-08-20" };

  it("rejects a zero amount ('0')", () => {
    const result = recordSettlementBankMovementSchema.safeParse({ ...BASE, amount: "0" });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.amount?.[0]).toContain("صفرًا");
    }
  });

  it("rejects a zero amount with decimals ('0.00')", () => {
    const result = recordSettlementBankMovementSchema.safeParse({ ...BASE, amount: "0.00" });
    expect(result.success).toBe(false);
  });

  it("rejects an empty string, a bare '-' and a bare '+'", () => {
    expect(recordSettlementBankMovementSchema.safeParse({ ...BASE, amount: "" }).success).toBe(false);
    expect(recordSettlementBankMovementSchema.safeParse({ ...BASE, amount: "-" }).success).toBe(false);
    expect(recordSettlementBankMovementSchema.safeParse({ ...BASE, amount: "+" }).success).toBe(false);
  });

  it("accepts a positive amount (deposit)", () => {
    const result = recordSettlementBankMovementSchema.safeParse({ ...BASE, amount: "12500.00" });
    expect(result.success).toBe(true);
  });

  it("accepts a negative amount (debit/withdrawal) — never assumed always-positive", () => {
    const result = recordSettlementBankMovementSchema.safeParse({ ...BASE, amount: "-300.00" });
    expect(result.success).toBe(true);
  });

  it("rejects more than 2 decimal places", () => {
    const result = recordSettlementBankMovementSchema.safeParse({ ...BASE, amount: "100.123" });
    expect(result.success).toBe(false);
  });
});

describe("createSettlementRouteSchema — route_kind cross-field rules (migration 0168's own check constraint, mirrored client-side)", () => {
  it("payment_collection requires payment_method_id and forbids shipping_carrier_id", () => {
    const missingMethod = createSettlementRouteSchema.safeParse({
      code: "visa_route",
      name_ar: "مسار فيزا",
      route_kind: "payment_collection",
    });
    expect(missingMethod.success).toBe(false);

    const withCarrier = createSettlementRouteSchema.safeParse({
      code: "visa_route",
      name_ar: "مسار فيزا",
      route_kind: "payment_collection",
      payment_method_id: PM_ID,
      shipping_carrier_id: CARRIER_ID,
    });
    expect(withCarrier.success).toBe(false);

    const valid = createSettlementRouteSchema.safeParse({
      code: "visa_route",
      name_ar: "مسار فيزا",
      route_kind: "payment_collection",
      payment_method_id: PM_ID,
      collection_channel_id: CHANNEL_ID,
    });
    expect(valid.success).toBe(true);
  });

  it("cod_carrier requires shipping_carrier_id and forbids payment_method_id/collection_channel_id", () => {
    const missingCarrier = createSettlementRouteSchema.safeParse({
      code: "cod_route",
      name_ar: "مسار COD",
      route_kind: "cod_carrier",
    });
    expect(missingCarrier.success).toBe(false);

    const withPaymentMethod = createSettlementRouteSchema.safeParse({
      code: "cod_route",
      name_ar: "مسار COD",
      route_kind: "cod_carrier",
      shipping_carrier_id: CARRIER_ID,
      payment_method_id: PM_ID,
    });
    expect(withPaymentMethod.success).toBe(false);

    const valid = createSettlementRouteSchema.safeParse({
      code: "cod_route",
      name_ar: "مسار COD",
      route_kind: "cod_carrier",
      shipping_carrier_id: CARRIER_ID,
    });
    expect(valid.success).toBe(true);
  });
});

describe("createSettlementRouteFeeVersionSchema — route_formula requires a fee model + matching fee fields (mirrors 0170's trigger)", () => {
  const BASE = { settlement_route_id: ROUTE_ID, route_kind: "payment_collection" as const, effective_from: "2026-08-20" };

  it("source_snapshot strategy needs no fee model/percentage/fixed fields", () => {
    const result = createSettlementRouteFeeVersionSchema.safeParse({ ...BASE, transaction_fee_strategy: "source_snapshot" });
    expect(result.success).toBe(true);
  });

  it("route_formula strategy without a transaction_fee_model is rejected", () => {
    const result = createSettlementRouteFeeVersionSchema.safeParse({ ...BASE, transaction_fee_strategy: "route_formula" });
    expect(result.success).toBe(false);
  });

  it("route_formula + percentage model without percentage_fee is rejected", () => {
    const result = createSettlementRouteFeeVersionSchema.safeParse({
      ...BASE,
      transaction_fee_strategy: "route_formula",
      transaction_fee_model: "percentage",
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.percentage_fee).toBeDefined();
    }
  });

  it("route_formula + percentage model with percentage_fee is accepted", () => {
    const result = createSettlementRouteFeeVersionSchema.safeParse({
      ...BASE,
      transaction_fee_strategy: "route_formula",
      transaction_fee_model: "percentage",
      percentage_fee: "2.5",
    });
    expect(result.success).toBe(true);
  });

  it("a cod_carrier route using route_formula requires cod_fee_reversal_policy", () => {
    const result = createSettlementRouteFeeVersionSchema.safeParse({
      settlement_route_id: ROUTE_ID,
      route_kind: "cod_carrier",
      effective_from: "2026-08-20",
      transaction_fee_strategy: "route_formula",
      transaction_fee_model: "fixed",
      fixed_fee: "10.00",
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.cod_fee_reversal_policy).toBeDefined();
    }
  });

  it("cod_fee_reversal_policy set while NOT using route_formula is rejected", () => {
    const result = createSettlementRouteFeeVersionSchema.safeParse({
      ...BASE,
      transaction_fee_strategy: "source_snapshot",
      cod_fee_reversal_policy: "full",
    });
    expect(result.success).toBe(false);
  });

  // Hotfix 7.1.1 §14 — source_snapshot has no meaning for a COD-carrier route
  // (no source-level fee snapshot exists for COD events at all), rejected by
  // create_settlement_route_fee_version() (migration 0190) at the DB layer —
  // this superRefine mirrors that rejection client-side so it never even
  // round-trips to the RPC.
  it("route_kind='cod_carrier' + transaction_fee_strategy='source_snapshot' is rejected, on the transaction_fee_strategy field", () => {
    const result = createSettlementRouteFeeVersionSchema.safeParse({
      settlement_route_id: ROUTE_ID,
      route_kind: "cod_carrier",
      effective_from: "2026-08-20",
      transaction_fee_strategy: "source_snapshot",
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.transaction_fee_strategy?.[0]).toContain("source_snapshot");
    }
  });

  it("route_kind='payment_collection' + transaction_fee_strategy='source_snapshot' stays accepted — the §14 rejection is COD-carrier-specific, never a blanket ban on source_snapshot", () => {
    const result = createSettlementRouteFeeVersionSchema.safeParse({
      settlement_route_id: ROUTE_ID,
      route_kind: "payment_collection",
      effective_from: "2026-08-20",
      transaction_fee_strategy: "source_snapshot",
    });
    expect(result.success).toBe(true);
  });
});

describe("error-message classifier helpers (mirror adjustments/schema.ts's own precedent)", () => {
  it("isClosedDayError matches the closed-day Arabic substring", () => {
    expect(isClosedDayError("اليوم التشغيلي مقفل بالفعل")).toBe(true);
    expect(isClosedDayError("دفعة التسوية هذه ليست في حالة مسودة")).toBe(false);
  });

  it("isVersionConflictError matches either concurrency-conflict phrasing", () => {
    expect(isVersionConflictError("تم تعديل السجل من قبل جهة أخرى")).toBe(true);
    expect(isVersionConflictError("تم تعديل السجل من قبل مستخدم آخر")).toBe(true);
    expect(isVersionConflictError("دفعة التسوية هذه ليست في حالة مسودة")).toBe(false);
  });

  it("isVarianceReasonRequiredError matches only the mandatory-variance-reason phrasing", () => {
    expect(isVarianceReasonRequiredError("يجب إدخال سبب لفرق المطابقة")).toBe(true);
    expect(isVarianceReasonRequiredError("دفعة التسوية هذه ليست في حالة معتمدة")).toBe(false);
  });
});

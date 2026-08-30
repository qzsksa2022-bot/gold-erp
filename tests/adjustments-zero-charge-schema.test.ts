import { describe, expect, it } from "vitest";
import { createAdjustmentSchema, updateAdjustmentSchema, setAdjustmentCostSchema } from "@/features/adjustments/schema";

// Patch 6.1 items 9/10/28 (migration 0144's sales_order_adjustments_zero_
// charge_consistent CHECK, mirrored client-side) — a genuinely FREE service
// (customer_charge = 0) must never carry a payment method/channel/reference,
// and a PAID service (customer_charge > 0) must always require both a
// payment method and a collection channel. This exercises
// applyZeroChargeCrossFieldRules() (schema.ts) directly through both
// createAdjustmentSchema and updateAdjustmentSchema, which share it.

const SALES_ORDER_ID = "22222222-2222-2222-2222-222222222222";
const ADJUSTMENT_TYPE_ID = "33333333-3333-3333-3333-333333333333";
const STORE_ID = "44444444-4444-4444-4444-444444444444";
const PAYMENT_METHOD_ID = "55555555-5555-5555-5555-555555555555";
const CHANNEL_ID = "66666666-6666-6666-6666-666666666666";
const ADJUSTMENT_ID = "11111111-1111-1111-1111-111111111111";

const BASE_CREATE = {
  sales_order_id: SALES_ORDER_ID,
  adjustment_type_id: ADJUSTMENT_TYPE_ID,
  processing_store_id: STORE_ID,
  adjustment_date: "2026-08-18",
};

describe("createAdjustmentSchema — Patch 6.1 zero-charge cross-field rules", () => {
  it("accepts a zero-charge (free) service with no payment method/channel/reference and participates_in_settlement=false", () => {
    const result = createAdjustmentSchema.safeParse({ ...BASE_CREATE, participates_in_settlement: false, customer_charge: "0.00" });
    expect(result.success).toBe(true);
  });

  it("rejects a zero-charge service that supplies a payment_method_id anyway", () => {
    const result = createAdjustmentSchema.safeParse({
      ...BASE_CREATE,
      participates_in_settlement: false,
      customer_charge: "0.00",
      payment_method_id: PAYMENT_METHOD_ID,
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.payment_method_id).toBeDefined();
    }
  });

  it("rejects a zero-charge service that supplies a payment_reference anyway", () => {
    const result = createAdjustmentSchema.safeParse({
      ...BASE_CREATE,
      participates_in_settlement: false,
      customer_charge: "0.00",
      payment_reference: "REF-1",
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.payment_reference).toBeDefined();
    }
  });

  it("accepts a paid (>0) service that supplies both payment_method_id and collection_channel_id", () => {
    const result = createAdjustmentSchema.safeParse({
      ...BASE_CREATE,
      participates_in_settlement: true,
      customer_charge: "100.00",
      payment_method_id: PAYMENT_METHOD_ID,
      collection_channel_id: CHANNEL_ID,
    });
    expect(result.success).toBe(true);
  });

  it("rejects a paid (>0) service missing payment_method_id", () => {
    const result = createAdjustmentSchema.safeParse({
      ...BASE_CREATE,
      participates_in_settlement: true,
      customer_charge: "100.00",
      collection_channel_id: CHANNEL_ID,
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.payment_method_id).toBeDefined();
    }
  });

  it("rejects a paid (>0) service missing collection_channel_id", () => {
    const result = createAdjustmentSchema.safeParse({
      ...BASE_CREATE,
      participates_in_settlement: true,
      customer_charge: "100.00",
      payment_method_id: PAYMENT_METHOD_ID,
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.collection_channel_id).toBeDefined();
    }
  });

  it("Patch 6.1 item 1A: direct_cost is genuinely optional at create time (never required while pending)", () => {
    const result = createAdjustmentSchema.safeParse({
      ...BASE_CREATE,
      participates_in_settlement: false,
      customer_charge: "0.00",
    });
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.direct_cost).toBeUndefined();
    }
  });
});

describe("updateAdjustmentSchema — Patch 6.1 zero-charge cross-field rules + item 1B (no direct_cost field)", () => {
  const BASE_UPDATE = { ...BASE_CREATE, id: ADJUSTMENT_ID, row_version: 1 };

  it("shares the same zero-charge rule as create — rejects a zero-charge update carrying a collection_channel_id", () => {
    const result = updateAdjustmentSchema.safeParse({
      ...BASE_UPDATE,
      participates_in_settlement: false,
      customer_charge: "0.00",
      collection_channel_id: CHANNEL_ID,
    });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error.flatten().fieldErrors.collection_channel_id).toBeDefined();
    }
  });

  it("has no direct_cost field at all — a stray direct_cost key is simply stripped, never validated or carried through", () => {
    const parsed = updateAdjustmentSchema.safeParse({
      ...BASE_UPDATE,
      participates_in_settlement: true,
      customer_charge: "100.00",
      payment_method_id: PAYMENT_METHOD_ID,
      collection_channel_id: CHANNEL_ID,
      direct_cost: "999.00",
    });
    expect(parsed.success).toBe(true);
    if (parsed.success) {
      expect(parsed.data).not.toHaveProperty("direct_cost");
    }
  });
});

describe("setAdjustmentCostSchema — Patch 6.1 item 2 (the sole path to set a pending record's direct_cost)", () => {
  it("requires a non-negative, max-2-decimal direct_cost", () => {
    expect(setAdjustmentCostSchema.safeParse({ id: ADJUSTMENT_ID, row_version: 1, direct_cost: "30.00" }).success).toBe(true);
    expect(setAdjustmentCostSchema.safeParse({ id: ADJUSTMENT_ID, row_version: 1, direct_cost: "-1.00" }).success).toBe(false);
    expect(setAdjustmentCostSchema.safeParse({ id: ADJUSTMENT_ID, row_version: 1, direct_cost: "30.123" }).success).toBe(false);
  });

  it("accepts an exact zero direct_cost — a manage_cost holder correcting a free service's cost to exactly 0.00 is valid", () => {
    expect(setAdjustmentCostSchema.safeParse({ id: ADJUSTMENT_ID, row_version: 1, direct_cost: "0.00" }).success).toBe(true);
  });
});

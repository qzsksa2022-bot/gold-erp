import { describe, expect, it, vi, beforeEach } from "vitest";

// Phase 6 (Services / Adjustments Core) — permission-boundary regression
// tests exercising the Server Actions THEMSELVES (not components that mock
// the action away), mirroring
// tests/shipping-actions-permission-boundary.test.ts exactly. Each action
// below must gate on its OWN distinct permission — approve/reject share
// adjustments.approve, reverse requires the separate adjustments.reverse
// (never adjustments.approve alone), create/update require adjustments.
// create. A future accidental collapse of these into a single shared gate
// (or a swap between them) would silently widen who can approve vs. who can
// reverse — this file fails immediately if that regression is introduced,
// without needing a live database.

// vi.mock(...) factories are hoisted above ALL top-level code in this file
// (including const declarations) — vi.hoisted() is the documented escape
// hatch so the mocks are initialized before any vi.mock() factory runs.
const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const { revalidatePath } = vi.hoisted(() => ({ revalidatePath: vi.fn() }));
vi.mock("next/cache", () => ({ revalidatePath }));

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({ rpc: rpcMock }),
}));

import { createAdjustmentAction, updateAdjustmentAction, approveAdjustmentAction, rejectAdjustmentAction, reverseAdjustmentAction, setAdjustmentCostAction } from "@/features/adjustments/actions";
import type { UpdateAdjustmentInput } from "@/features/adjustments/schema";

const ADJUSTMENT_ID = "11111111-1111-1111-1111-111111111111";

const VALID_CREATE_INPUT = {
  sales_order_id: "22222222-2222-2222-2222-222222222222",
  adjustment_type_id: "33333333-3333-3333-3333-333333333333",
  processing_store_id: "44444444-4444-4444-4444-444444444444",
  adjustment_date: "2026-08-18",
  payment_method_id: "55555555-5555-5555-5555-555555555555",
  collection_channel_id: "66666666-6666-6666-6666-666666666666",
  participates_in_settlement: false,
  customer_charge: "100.00",
};

describe("Adjustments actions — each lifecycle step gates on its OWN distinct permission", () => {
  beforeEach(() => {
    requirePermission.mockReset();
    revalidatePath.mockReset();
    rpcMock.mockReset();
  });

  it("createAdjustmentAction gates on adjustments.create alone", async () => {
    requirePermission.mockResolvedValue({ userId: "actor-1" });
    rpcMock.mockResolvedValue({ data: [{ id: ADJUSTMENT_ID, adjustment_number: "ADJ-0000000001" }], error: null });

    await createAdjustmentAction(VALID_CREATE_INPUT);

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("adjustments.create");
    expect(rpcMock).toHaveBeenCalledWith("create_sales_order_adjustment", expect.objectContaining({ p_sales_order_id: VALID_CREATE_INPUT.sales_order_id }));
  });

  it("approveAdjustmentAction gates on adjustments.approve — NOT adjustments.create", async () => {
    requirePermission.mockResolvedValue({ userId: "actor-1" });
    rpcMock.mockResolvedValue({ data: [{ id: ADJUSTMENT_ID, adjustment_number: "ADJ-0000000001", row_version: 2, net_adjustment_profit: "67.50" }], error: null });

    await approveAdjustmentAction({ id: ADJUSTMENT_ID, row_version: 1 });

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("adjustments.approve");
    expect(rpcMock).toHaveBeenCalledWith("approve_sales_order_adjustment", expect.objectContaining({ p_id: ADJUSTMENT_ID, p_expected_version: 1 }));
  });

  it("rejectAdjustmentAction ALSO gates on adjustments.approve (mirrors Returns' approve/reject symmetry) — NOT a separate adjustments.reject permission that does not exist", async () => {
    requirePermission.mockResolvedValue({ userId: "actor-1" });
    rpcMock.mockResolvedValue({ data: [{ id: ADJUSTMENT_ID, row_version: 2 }], error: null });

    await rejectAdjustmentAction({ id: ADJUSTMENT_ID, row_version: 1, reason: "خطأ في الإدخال" });

    expect(requirePermission).toHaveBeenCalledWith("adjustments.approve");
  });

  it("reverseAdjustmentAction gates on the DISTINCT adjustments.reverse permission — NOT adjustments.approve, even though both act on an approved record", async () => {
    requirePermission.mockResolvedValue({ userId: "actor-1" });
    rpcMock.mockResolvedValue({ data: [{ id: ADJUSTMENT_ID, reversal_id: "77777777-7777-7777-7777-777777777777" }], error: null });

    await reverseAdjustmentAction({ id: ADJUSTMENT_ID, row_version: 2, reversal_business_date: "2026-08-18", reason: "تصحيح إداري" });

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("adjustments.reverse");
    expect(requirePermission).not.toHaveBeenCalledWith("adjustments.approve");
    expect(rpcMock).toHaveBeenCalledWith(
      "reverse_sales_order_adjustment",
      expect.objectContaining({ p_id: ADJUSTMENT_ID, p_expected_version: 2, p_reversal_business_date: "2026-08-18", p_reason: "تصحيح إداري" }),
    );
  });

  it("an actor lacking the required permission is rejected before any RPC is reached (requirePermission's own redirect/throw propagates, no silent fallthrough)", async () => {
    requirePermission.mockRejectedValue(new Error("NEXT_REDIRECT;replace;/403"));

    await expect(reverseAdjustmentAction({ id: ADJUSTMENT_ID, row_version: 2, reversal_business_date: "2026-08-18", reason: "سبب" })).rejects.toThrow();
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("reverseAdjustmentAction rejects an empty reason client-side (Zod), never reaching the RPC — mirrors the DB's own mandatory-reason guard (0141) defensively", async () => {
    requirePermission.mockResolvedValue({ userId: "actor-1" });

    const result = await reverseAdjustmentAction({ id: ADJUSTMENT_ID, row_version: 2, reversal_business_date: "2026-08-18", reason: "" });

    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------
  // Patch 6.1 (migrations 0144-0156) additions below.
  // ---------------------------------------------------------------------

  it("Patch 6.1 item 2: setAdjustmentCostAction gates on the DISTINCT adjustments.manage_cost permission — NOT adjustments.create/approve", async () => {
    requirePermission.mockResolvedValue({ userId: "actor-1" });
    rpcMock.mockResolvedValue({ data: [{ id: ADJUSTMENT_ID, row_version: 2, direct_cost: "30.00", has_direct_cost: true }], error: null });

    await setAdjustmentCostAction({ id: ADJUSTMENT_ID, row_version: 1, direct_cost: "30.00" });

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("adjustments.manage_cost");
    expect(requirePermission).not.toHaveBeenCalledWith("adjustments.create");
    expect(requirePermission).not.toHaveBeenCalledWith("adjustments.approve");
    expect(rpcMock).toHaveBeenCalledWith(
      "set_pending_sales_order_adjustment_direct_cost",
      expect.objectContaining({ p_id: ADJUSTMENT_ID, p_expected_version: 1, p_direct_cost: "30.00" }),
    );
  });

  it("Patch 6.1 item 2: setAdjustmentCostAction rejects an empty direct_cost client-side (Zod), never reaching the RPC", async () => {
    requirePermission.mockResolvedValue({ userId: "actor-1" });

    const result = await setAdjustmentCostAction({ id: ADJUSTMENT_ID, row_version: 1, direct_cost: "" });

    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("Patch 6.1 item 1B: updateAdjustmentAction never sends p_direct_cost to the RPC — 0147 dropped the parameter entirely, and updateAdjustmentSchema has no such field to carry it through", async () => {
    requirePermission.mockResolvedValue({ userId: "actor-1" });
    rpcMock.mockResolvedValue({ data: [{ id: ADJUSTMENT_ID, row_version: 2 }], error: null });

    const input: UpdateAdjustmentInput = {
      id: ADJUSTMENT_ID,
      row_version: 1,
      adjustment_type_id: VALID_CREATE_INPUT.adjustment_type_id,
      processing_store_id: VALID_CREATE_INPUT.processing_store_id,
      adjustment_date: VALID_CREATE_INPUT.adjustment_date,
      payment_method_id: VALID_CREATE_INPUT.payment_method_id,
      collection_channel_id: VALID_CREATE_INPUT.collection_channel_id,
      participates_in_settlement: false,
      customer_charge: "100.00",
    };
    await updateAdjustmentAction(input);

    expect(rpcMock).toHaveBeenCalledTimes(1);
    const [, payload] = rpcMock.mock.calls[0];
    expect(payload).not.toHaveProperty("p_direct_cost");
  });

  it("Patch 6.1 items 9/10: createAdjustmentAction sends null payment_method_id/collection_channel_id/payment_reference for a genuinely free (zero-charge) service", async () => {
    requirePermission.mockResolvedValue({ userId: "actor-1" });
    rpcMock.mockResolvedValue({ data: [{ id: ADJUSTMENT_ID, adjustment_number: "ADJ-0000000002" }], error: null });

    await createAdjustmentAction({
      sales_order_id: VALID_CREATE_INPUT.sales_order_id,
      adjustment_type_id: VALID_CREATE_INPUT.adjustment_type_id,
      processing_store_id: VALID_CREATE_INPUT.processing_store_id,
      adjustment_date: VALID_CREATE_INPUT.adjustment_date,
      participates_in_settlement: false,
      customer_charge: "0.00",
    });

    expect(rpcMock).toHaveBeenCalledWith(
      "create_sales_order_adjustment",
      expect.objectContaining({ p_payment_method_id: null, p_collection_channel_id: null, p_payment_reference: null, p_customer_charge: "0.00" }),
    );
  });
});

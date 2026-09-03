import { describe, expect, it, vi, beforeEach } from "vitest";

// Phase 9 (Inventory Core) — permission-boundary regression tests exercising
// the Server Actions THEMSELVES (not components that mock the action away),
// mirroring tests/adjustments-actions-permission-boundary.test.ts and
// tests/settlements-actions-permission-boundary.test.ts exactly. Every
// mutation gates on its OWN permission (inventory.receive for create_item/
// receive_stock, inventory.adjust for update_item/adjust_stock) — a future
// accidental collapse of these into a shared gate would silently widen who
// can correct stock. This file also covers Zod-before-RPC validation and DB
// error-message propagation via dbErrorMessage.

const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const { revalidatePath } = vi.hoisted(() => ({ revalidatePath: vi.fn() }));
vi.mock("next/cache", () => ({ revalidatePath }));

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({ rpc: rpcMock }),
}));

import { createInventoryItemAction, updateInventoryItemAction, receiveInventoryStockAction, adjustInventoryStockAction } from "@/features/inventory/actions";

const ITEM_ID = "11111111-1111-1111-1111-111111111111";
const CATEGORY_ID = "22222222-2222-2222-2222-222222222222";
const STORE_ID = "33333333-3333-3333-3333-333333333333";

beforeEach(() => {
  requirePermission.mockReset();
  revalidatePath.mockReset();
  rpcMock.mockReset();
  requirePermission.mockResolvedValue({ userId: "actor-1" });
});

describe("createInventoryItemAction — gates on inventory.receive alone", () => {
  it("gates on inventory.receive, not inventory.adjust", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: ITEM_ID, sku: "RING-001", row_version: 1 }], error: null });
    await createInventoryItemAction({ sku: "RING-001", name_ar: "خاتم ذهب", category_id: CATEGORY_ID, unit: "gram" });
    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("inventory.receive");
    expect(requirePermission).not.toHaveBeenCalledWith("inventory.adjust");
    expect(rpcMock).toHaveBeenCalledWith("create_inventory_item", expect.objectContaining({ p_sku: "RING-001", p_category_id: CATEGORY_ID }));
  });

  it("rejects a blank sku client-side (Zod), never reaching the RPC", async () => {
    const result = await createInventoryItemAction({ sku: "", name_ar: "خاتم ذهب", category_id: CATEGORY_ID, unit: "gram" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });
});

describe("updateInventoryItemAction — gates on the DISTINCT inventory.adjust permission", () => {
  it("gates on inventory.adjust, not inventory.receive", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: ITEM_ID, row_version: 2 }], error: null });
    await updateInventoryItemAction({ id: ITEM_ID, row_version: 1, name_ar: "خاتم ذهب معدل", category_id: CATEGORY_ID, unit: "gram", active: true });
    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("inventory.adjust");
    expect(requirePermission).not.toHaveBeenCalledWith("inventory.receive");
    expect(rpcMock).toHaveBeenCalledWith("update_inventory_item", expect.objectContaining({ p_id: ITEM_ID, p_expected_version: 1 }));
  });
});

describe("receiveInventoryStockAction — gates on inventory.receive alone", () => {
  it("gates on inventory.receive, not inventory.adjust", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: "44444444-4444-4444-4444-444444444444", resulting_balance: "10.000" }], error: null });
    await receiveInventoryStockAction({ item_id: ITEM_ID, store_id: STORE_ID, quantity: "10", business_date: "2026-08-20" });
    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("inventory.receive");
    expect(requirePermission).not.toHaveBeenCalledWith("inventory.adjust");
    expect(rpcMock).toHaveBeenCalledWith("receive_inventory_stock", expect.objectContaining({ p_item_id: ITEM_ID, p_store_id: STORE_ID, p_quantity: "10" }));
  });

  it("rejects a zero quantity client-side (Zod), never reaching the RPC", async () => {
    const result = await receiveInventoryStockAction({ item_id: ITEM_ID, store_id: STORE_ID, quantity: "0", business_date: "2026-08-20" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("rejects a negative quantity client-side (Zod) — receive must be positive", async () => {
    const result = await receiveInventoryStockAction({ item_id: ITEM_ID, store_id: STORE_ID, quantity: "-5", business_date: "2026-08-20" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });
});

describe("adjustInventoryStockAction — gates on the DISTINCT inventory.adjust permission", () => {
  it("gates on inventory.adjust, not inventory.receive", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: "55555555-5555-5555-5555-555555555555", resulting_balance: "7.500" }], error: null });
    await adjustInventoryStockAction({ item_id: ITEM_ID, store_id: STORE_ID, quantity_delta: "-2.5", reason: "جرد فعلي", business_date: "2026-08-20" });
    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("inventory.adjust");
    expect(requirePermission).not.toHaveBeenCalledWith("inventory.receive");
    expect(rpcMock).toHaveBeenCalledWith("adjust_inventory_stock", expect.objectContaining({ p_quantity_delta: "-2.5", p_reason: "جرد فعلي" }));
  });

  it("accepts a positive quantity_delta (found extra stock)", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: "66666666-6666-6666-6666-666666666666", resulting_balance: "12.500" }], error: null });
    const result = await adjustInventoryStockAction({ item_id: ITEM_ID, store_id: STORE_ID, quantity_delta: "2.5", reason: "جرد فعلي", business_date: "2026-08-20" });
    expect(result.success).toBe(true);
    expect(rpcMock).toHaveBeenCalledWith("adjust_inventory_stock", expect.objectContaining({ p_quantity_delta: "2.5" }));
  });

  it("rejects a zero quantity_delta client-side (Zod), never reaching the RPC", async () => {
    const result = await adjustInventoryStockAction({ item_id: ITEM_ID, store_id: STORE_ID, quantity_delta: "0", reason: "جرد فعلي", business_date: "2026-08-20" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("rejects a blank reason client-side (Zod), never reaching the RPC — mirrors the DB's own mandatory-reason guard defensively", async () => {
    const result = await adjustInventoryStockAction({ item_id: ITEM_ID, store_id: STORE_ID, quantity_delta: "-1", reason: "", business_date: "2026-08-20" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });
});

describe("an actor lacking the required permission is rejected before any RPC is reached", () => {
  it("requirePermission's own redirect/throw propagates, no silent fallthrough", async () => {
    requirePermission.mockRejectedValue(new Error("NEXT_REDIRECT;replace;/403"));
    await expect(receiveInventoryStockAction({ item_id: ITEM_ID, store_id: STORE_ID, quantity: "5", business_date: "2026-08-20" })).rejects.toThrow();
    expect(rpcMock).not.toHaveBeenCalled();
  });
});

describe("DB error propagation — dbErrorMessage() passes a safe (P0001) message through verbatim, collapses anything else to the generic message", () => {
  it("a P0001 negative-stock rejection from adjust_inventory_stock surfaces its real Arabic message unchanged", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "الكمية الناتجة ستكون سالبة، العملية مرفوضة" } });
    const result = await adjustInventoryStockAction({ item_id: ITEM_ID, store_id: STORE_ID, quantity_delta: "-100", reason: "جرد فعلي", business_date: "2026-08-20" });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error).toBe("الكمية الناتجة ستكون سالبة، العملية مرفوضة");
    }
  });

  it("an unsafe/unexpected error code is collapsed to the generic Arabic message — internals never leak to the client", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "23505", message: 'duplicate key value violates unique constraint "inventory_items_sku_unique_idx"' } });
    const result = await createInventoryItemAction({ sku: "RING-001", name_ar: "خاتم ذهب", category_id: CATEGORY_ID, unit: "gram" });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error).toBe("حدث خطأ غير متوقع. الرجاء المحاولة مرة أخرى.");
      expect(result.error).not.toContain("constraint");
    }
  });
});

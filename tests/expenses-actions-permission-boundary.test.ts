import { describe, expect, it, vi, beforeEach } from "vitest";

// Phase 10 (Store Expenses Core) — permission-boundary regression tests
// exercising the Server Actions THEMSELVES (not components that mock the
// action away), mirroring tests/inventory-actions-permission-boundary.test.ts
// exactly. Every mutation gates on its OWN permission — recording, reversing
// and managing the category catalog are three genuinely different powers, and
// a future accidental collapse of these into a shared gate would silently
// widen who can post or undo money. This file also covers Zod-before-RPC
// validation, the money-as-string contract at the action boundary, and DB
// error-message propagation via dbErrorMessage.

const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const { revalidatePath } = vi.hoisted(() => ({ revalidatePath: vi.fn() }));
vi.mock("next/cache", () => ({ revalidatePath }));

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({ rpc: rpcMock }),
}));

import {
  createExpenseCategoryAction,
  updateExpenseCategoryAction,
  setExpenseCategoryStatusAction,
  recordStoreExpenseAction,
  reverseStoreExpenseAction,
} from "@/features/expenses/actions";

const STORE_ID = "11111111-1111-1111-1111-111111111111";
const CATEGORY_ID = "22222222-2222-2222-2222-222222222222";
const EXPENSE_ID = "33333333-3333-3333-3333-333333333333";

beforeEach(() => {
  requirePermission.mockReset();
  revalidatePath.mockReset();
  rpcMock.mockReset();
  requirePermission.mockResolvedValue({ userId: "actor-1" });
});

describe("recordStoreExpenseAction — gates on expenses.create alone", () => {
  it("gates on expenses.create, never on reverse or manage_categories", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: EXPENSE_ID, expense_number: "EXP-0000000001", amount: "1500.00" }], error: null });

    await recordStoreExpenseAction({
      store_id: STORE_ID,
      expense_category_id: CATEGORY_ID,
      amount: "1500.00",
      business_date: "2026-09-05",
    });

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("expenses.create");
    expect(requirePermission).not.toHaveBeenCalledWith("expenses.reverse");
    expect(requirePermission).not.toHaveBeenCalledWith("expenses.manage_categories");
  });

  it("passes the amount through as a STRING — never a Number", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: EXPENSE_ID, expense_number: "EXP-0000000001", amount: "1500.50" }], error: null });

    await recordStoreExpenseAction({
      store_id: STORE_ID,
      expense_category_id: CATEGORY_ID,
      amount: "1500.50",
      business_date: "2026-09-05",
    });

    const args = rpcMock.mock.calls[0][1];
    expect(typeof args.p_amount).toBe("string");
    expect(args.p_amount).toBe("1500.50");
  });

  it("rejects a zero, negative or over-scaled amount client-side (Zod), never reaching the RPC", async () => {
    for (const amount of ["0", "-5", "10.123"]) {
      rpcMock.mockReset();
      const result = await recordStoreExpenseAction({
        store_id: STORE_ID,
        expense_category_id: CATEGORY_ID,
        amount,
        business_date: "2026-09-05",
      });
      expect(result.success, `amount ${amount} should be rejected`).toBe(false);
      expect(rpcMock).not.toHaveBeenCalled();
    }
  });

  it("forwards the closed-day reason only when supplied, otherwise null", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: EXPENSE_ID, expense_number: "EXP-1", amount: "10.00" }], error: null });
    await recordStoreExpenseAction({ store_id: STORE_ID, expense_category_id: CATEGORY_ID, amount: "10.00", business_date: "2026-09-05" });
    expect(rpcMock.mock.calls[0][1].p_closed_day_reason).toBeNull();

    rpcMock.mockReset();
    rpcMock.mockResolvedValue({ data: [{ id: EXPENSE_ID, expense_number: "EXP-1", amount: "10.00" }], error: null });
    await recordStoreExpenseAction({
      store_id: STORE_ID,
      expense_category_id: CATEGORY_ID,
      amount: "10.00",
      business_date: "2026-09-05",
      closed_day_reason: "تسوية متأخرة",
    });
    expect(rpcMock.mock.calls[0][1].p_closed_day_reason).toBe("تسوية متأخرة");
  });

  it("propagates the DB error message (e.g. the closed-day refusal) rather than swallowing it", async () => {
    // code P0001 is what every `raise exception ... using errcode = 'P0001'`
    // in the RPCs produces, and is the class dbErrorMessage() is allowed to
    // surface verbatim — anything else falls back to the generic message.
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "تاريخ المصروف يقع في يوم مقفل لهذا الفرع" } });
    const result = await recordStoreExpenseAction({
      store_id: STORE_ID,
      expense_category_id: CATEGORY_ID,
      amount: "10.00",
      business_date: "2026-09-05",
    });
    expect(result.success).toBe(false);
    expect(result.success === false && result.error).toContain("يوم مقفل");
  });
});

describe("reverseStoreExpenseAction — gates on the DISTINCT expenses.reverse permission", () => {
  it("gates on expenses.reverse, never on expenses.create", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: "44444444-4444-4444-4444-444444444444", expense_number: "EXP-0000000002", amount: "-1500.00" }], error: null });

    await reverseStoreExpenseAction({ expense_id: EXPENSE_ID, reason: "دفعة مكررة", business_date: "2026-09-05" });

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("expenses.reverse");
    expect(requirePermission).not.toHaveBeenCalledWith("expenses.create");
  });

  it("requires a reason client-side (Zod), never reaching the RPC", async () => {
    const result = await reverseStoreExpenseAction({ expense_id: EXPENSE_ID, reason: "   ", business_date: "2026-09-05" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("sends the reversal's OWN business date (§85 Event Date), not the original's", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: "44444444-4444-4444-4444-444444444444", expense_number: "EXP-2", amount: "-10.00" }], error: null });
    await reverseStoreExpenseAction({ expense_id: EXPENSE_ID, reason: "تصحيح", business_date: "2026-09-30" });
    expect(rpcMock).toHaveBeenCalledWith("reverse_store_expense", expect.objectContaining({ p_reversal_business_date: "2026-09-30" }));
  });
});

describe("expense category actions — gate on expenses.manage_categories alone", () => {
  it("createExpenseCategoryAction gates on manage_categories", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: CATEGORY_ID, code: "RENT", row_version: 1 }], error: null });
    await createExpenseCategoryAction({ code: "RENT", name_ar: "إيجار" });
    expect(requirePermission).toHaveBeenCalledWith("expenses.manage_categories");
    expect(requirePermission).not.toHaveBeenCalledWith("expenses.create");
  });

  it("updateExpenseCategoryAction always sends the row_version (never null/undefined)", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: CATEGORY_ID, row_version: 2 }], error: null });
    await updateExpenseCategoryAction({ id: CATEGORY_ID, row_version: 1, name_ar: "إيجار محدث" });
    const args = rpcMock.mock.calls[0][1];
    expect(args.p_expected_version).toBe(1);
    expect(args.p_expected_version).not.toBeNull();
  });

  it("updateExpenseCategoryAction rejects a missing row_version client-side — a NULL version would bypass optimistic concurrency in the DB", async () => {
    // @ts-expect-error deliberately omitting the required row_version
    const result = await updateExpenseCategoryAction({ id: CATEGORY_ID, name_ar: "إيجار" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("setExpenseCategoryStatusAction picks the matching RPC for each direction", async () => {
    rpcMock.mockResolvedValue({ error: null });
    await setExpenseCategoryStatusAction(CATEGORY_ID, "disabled");
    expect(rpcMock).toHaveBeenCalledWith("disable_expense_category", { p_id: CATEGORY_ID });

    rpcMock.mockReset();
    rpcMock.mockResolvedValue({ error: null });
    await setExpenseCategoryStatusAction(CATEGORY_ID, "active");
    expect(rpcMock).toHaveBeenCalledWith("enable_expense_category", { p_id: CATEGORY_ID });
  });
});

describe("no action ever writes the base tables directly", () => {
  it("every mutation goes through a SECURITY DEFINER RPC (Layer-A lockdown, 0234)", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: EXPENSE_ID, expense_number: "EXP-1", amount: "10.00" }], error: null });
    await recordStoreExpenseAction({ store_id: STORE_ID, expense_category_id: CATEGORY_ID, amount: "10.00", business_date: "2026-09-05" });

    // Only `.rpc` exists on the mocked client — a `.from(...)` write would
    // throw here, which is exactly the point.
    expect(rpcMock).toHaveBeenCalledWith("record_store_expense", expect.any(Object));
  });
});

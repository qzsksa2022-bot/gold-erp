import { describe, expect, it, vi, beforeEach } from "vitest";

// Phase 11 (Purchases & Suppliers Core) — permission-boundary regression tests
// exercising the Server Actions THEMSELVES (not components that mock the
// action away), mirroring tests/expenses-actions-permission-boundary.test.ts
// exactly. Every mutation gates on its OWN permission — posting a purchase,
// reversing it, paying a supplier, reversing that payment, and managing the
// supplier catalogue are five genuinely different powers, and a future
// accidental collapse of these into a shared gate would silently widen who can
// commit or undo money AND stock. This file also covers Zod-before-RPC
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
  createSupplierAction,
  updateSupplierAction,
  setSupplierStatusAction,
  postPurchaseInvoiceAction,
  reversePurchaseInvoiceAction,
  recordSupplierPaymentAction,
  reverseSupplierPaymentAction,
} from "@/features/purchases/actions";

const SUPPLIER_ID = "11111111-1111-1111-1111-111111111111";
const STORE_ID = "22222222-2222-2222-2222-222222222222";
const ITEM_ID = "33333333-3333-3333-3333-333333333333";
const INVOICE_ID = "44444444-4444-4444-4444-444444444444";
const PAYMENT_ID = "55555555-5555-5555-5555-555555555555";

/** One internally-consistent standard-rated line: 10 × 100 net + 15% VAT. */
function line(overrides: Record<string, string> = {}) {
  return {
    inventory_item_id: ITEM_ID,
    quantity: "10",
    unit_net_cost: "100",
    tax_treatment: "standard" as const,
    tax_rate_percent: "15",
    net_amount: "1000.00",
    vat_amount: "150.00",
    gross_amount: "1150.00",
    ...overrides,
  };
}

function invoiceInput(overrides: Record<string, unknown> = {}) {
  return {
    supplier_id: SUPPLIER_ID,
    store_id: STORE_ID,
    business_date: "2026-09-05",
    lines: [line()],
    net_total: "1000.00",
    vat_total: "150.00",
    gross_total: "1150.00",
    ...overrides,
  };
}

const POST_OK = { data: [{ id: INVOICE_ID, purchase_number: "PUR-0000000001", gross_total: "1150.00" }], error: null };
const PAY_OK = { data: [{ id: PAYMENT_ID, payment_number: "SPY-0000000001", amount: "500.00", outstanding_after: "650.00" }], error: null };

beforeEach(() => {
  requirePermission.mockReset();
  revalidatePath.mockReset();
  rpcMock.mockReset();
  requirePermission.mockResolvedValue({ userId: "actor-1" });
});

describe("postPurchaseInvoiceAction — gates on purchases.create alone", () => {
  it("gates on purchases.create, never on reverse, payment or supplier management", async () => {
    rpcMock.mockResolvedValue(POST_OK);

    await postPurchaseInvoiceAction(invoiceInput());

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("purchases.create");
    expect(requirePermission).not.toHaveBeenCalledWith("purchases.reverse");
    expect(requirePermission).not.toHaveBeenCalledWith("purchases.record_payment");
    expect(requirePermission).not.toHaveBeenCalledWith("purchases.manage_suppliers");
  });

  it("does NOT require an inventory permission, even though posting also receives stock", async () => {
    // Decision 2: the invoice's own permission authorises the stock movement
    // too — record_inventory_stock_movement() is called with 'purchases.create'
    // as its permission parameter (0239). A purchasing clerk needs no
    // inventory.* grant.
    rpcMock.mockResolvedValue(POST_OK);
    await postPurchaseInvoiceAction(invoiceInput());
    expect(requirePermission).not.toHaveBeenCalledWith("inventory.receive");
    expect(requirePermission).not.toHaveBeenCalledWith("inventory.adjust");
  });

  it("passes every monetary value through as a STRING — never a Number", async () => {
    rpcMock.mockResolvedValue(POST_OK);
    await postPurchaseInvoiceAction(invoiceInput());

    const args = rpcMock.mock.calls[0][1];
    expect(typeof args.p_net_total).toBe("string");
    expect(typeof args.p_vat_total).toBe("string");
    expect(typeof args.p_gross_total).toBe("string");
    expect(args.p_gross_total).toBe("1150.00");

    const sentLine = args.p_lines[0];
    expect(typeof sentLine.net_amount).toBe("string");
    expect(typeof sentLine.vat_amount).toBe("string");
    expect(typeof sentLine.gross_amount).toBe("string");
    expect(typeof sentLine.quantity).toBe("string");
    expect(typeof sentLine.unit_net_cost).toBe("string");
  });

  it("rejects a line whose gross <> net + vat client-side (Zod), never reaching the RPC", async () => {
    const result = await postPurchaseInvoiceAction(
      invoiceInput({ lines: [line({ gross_amount: "1149.99" })], gross_total: "1149.99" }),
    );
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("rejects a header total that disagrees with the sum of the lines, never reaching the RPC", async () => {
    const result = await postPurchaseInvoiceAction(invoiceInput({ gross_total: "1151.00" }));
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("rejects a non-standard line that carries VAT — Phase 11 refuses a document contradicting its own declared treatment", async () => {
    const result = await postPurchaseInvoiceAction(
      invoiceInput({
        lines: [line({ tax_treatment: "exempt", vat_amount: "150.00", tax_rate_percent: "15" })],
      }),
    );
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("accepts a zero-rated line carrying no VAT", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: INVOICE_ID, purchase_number: "PUR-1", gross_total: "1000.00" }], error: null });
    const result = await postPurchaseInvoiceAction(
      invoiceInput({
        lines: [line({ tax_treatment: "zero_rated", vat_amount: "0", tax_rate_percent: "0", gross_amount: "1000.00" })],
        vat_total: "0",
        gross_total: "1000.00",
      }),
    );
    expect(result.success).toBe(true);
    expect(rpcMock).toHaveBeenCalledWith("post_purchase_invoice", expect.any(Object));
  });

  it("rejects an empty line list, never reaching the RPC", async () => {
    const result = await postPurchaseInvoiceAction(invoiceInput({ lines: [], net_total: "0", vat_total: "0", gross_total: "0" }));
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("forwards the closed-day reason only when supplied, otherwise null", async () => {
    rpcMock.mockResolvedValue(POST_OK);
    await postPurchaseInvoiceAction(invoiceInput());
    expect(rpcMock.mock.calls[0][1].p_closed_day_reason).toBeNull();

    rpcMock.mockReset();
    rpcMock.mockResolvedValue(POST_OK);
    await postPurchaseInvoiceAction(invoiceInput({ closed_day_reason: "تسوية متأخرة" }));
    expect(rpcMock.mock.calls[0][1].p_closed_day_reason).toBe("تسوية متأخرة");
  });

  it("propagates the DB error message (e.g. the closed-day refusal) rather than swallowing it", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "تاريخ الفاتورة يقع في يوم مقفل لهذا الفرع" } });
    const result = await postPurchaseInvoiceAction(invoiceInput());
    expect(result.success).toBe(false);
    expect(result.success === false && result.error).toContain("يوم مقفل");
  });

  it("revalidates the inventory route too — posting an invoice moved stock in the same transaction", async () => {
    rpcMock.mockResolvedValue(POST_OK);
    await postPurchaseInvoiceAction(invoiceInput());
    const paths = revalidatePath.mock.calls.map((c) => c[0]);
    expect(paths).toContain("/purchases");
    expect(paths).toContain("/inventory");
  });
});

describe("reversePurchaseInvoiceAction — gates on the DISTINCT purchases.reverse permission", () => {
  it("gates on purchases.reverse, never on purchases.create", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: "66666666-6666-6666-6666-666666666666", purchase_number: "PUR-0000000002", gross_total: "-1150.00" }], error: null });

    await reversePurchaseInvoiceAction({ invoice_id: INVOICE_ID, reason: "بضاعة مرتجعة", business_date: "2026-09-05" });

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("purchases.reverse");
    expect(requirePermission).not.toHaveBeenCalledWith("purchases.create");
  });

  it("requires a reason client-side (Zod), never reaching the RPC", async () => {
    const result = await reversePurchaseInvoiceAction({ invoice_id: INVOICE_ID, reason: "   ", business_date: "2026-09-05" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("sends the reversal's OWN business date (§85 Event Date), not the original's", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: "66666666-6666-6666-6666-666666666666", purchase_number: "PUR-2", gross_total: "-10.00" }], error: null });
    await reversePurchaseInvoiceAction({ invoice_id: INVOICE_ID, reason: "تصحيح", business_date: "2026-09-30" });
    expect(rpcMock).toHaveBeenCalledWith("reverse_purchase_invoice", expect.objectContaining({ p_reversal_business_date: "2026-09-30" }));
  });

  it("propagates the refusal when an unreversed payment still stands against the invoice", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "لا يمكن عكس الفاتورة: توجد دفعة غير معكوسة مرتبطة بها" } });
    const result = await reversePurchaseInvoiceAction({ invoice_id: INVOICE_ID, reason: "تصحيح", business_date: "2026-09-05" });
    expect(result.success).toBe(false);
    expect(result.success === false && result.error).toContain("دفعة غير معكوسة");
  });
});

describe("supplier payment actions — record and reverse are two distinct powers", () => {
  it("recordSupplierPaymentAction gates on purchases.record_payment alone", async () => {
    rpcMock.mockResolvedValue(PAY_OK);
    await recordSupplierPaymentAction({ invoice_id: INVOICE_ID, amount: "500.00", payment_mode: "cash", business_date: "2026-09-05" });

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("purchases.record_payment");
    expect(requirePermission).not.toHaveBeenCalledWith("purchases.create");
    expect(requirePermission).not.toHaveBeenCalledWith("purchases.reverse_payment");
  });

  it("reverseSupplierPaymentAction gates on purchases.reverse_payment, NOT on purchases.reverse", async () => {
    // Reversing a PAYMENT and reversing an INVOICE are separate permissions;
    // conflating them would let a payment clerk undo a purchase document.
    rpcMock.mockResolvedValue({ data: [{ id: "77777777-7777-7777-7777-777777777777", payment_number: "SPY-2", amount: "-500.00", outstanding_after: "1150.00" }], error: null });
    await reverseSupplierPaymentAction({ payment_id: PAYMENT_ID, reason: "حوالة مرتجعة", business_date: "2026-09-05" });

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("purchases.reverse_payment");
    expect(requirePermission).not.toHaveBeenCalledWith("purchases.reverse");
  });

  it("passes the payment amount through as a STRING — never a Number", async () => {
    rpcMock.mockResolvedValue(PAY_OK);
    await recordSupplierPaymentAction({ invoice_id: INVOICE_ID, amount: "500.50", payment_mode: "bank_transfer", business_date: "2026-09-05" });
    const args = rpcMock.mock.calls[0][1];
    expect(typeof args.p_amount).toBe("string");
    expect(args.p_amount).toBe("500.50");
  });

  it("rejects a zero, negative or over-scaled payment client-side (Zod), never reaching the RPC", async () => {
    for (const amount of ["0", "-5", "10.123"]) {
      rpcMock.mockReset();
      const result = await recordSupplierPaymentAction({ invoice_id: INVOICE_ID, amount, payment_mode: "cash", business_date: "2026-09-05" });
      expect(result.success, `amount ${amount} should be rejected`).toBe(false);
      expect(rpcMock).not.toHaveBeenCalled();
    }
  });

  it("rejects an unknown payment mode client-side", async () => {
    // @ts-expect-error deliberately passing a mode outside the enum
    const result = await recordSupplierPaymentAction({ invoice_id: INVOICE_ID, amount: "10.00", payment_mode: "crypto", business_date: "2026-09-05" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("propagates the overpayment refusal — the remaining balance is decided server-side under a row lock", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "مبلغ الدفعة يتجاوز المتبقي على الفاتورة" } });
    const result = await recordSupplierPaymentAction({ invoice_id: INVOICE_ID, amount: "99999.00", payment_mode: "cash", business_date: "2026-09-05" });
    expect(result.success).toBe(false);
    expect(result.success === false && result.error).toContain("يتجاوز المتبقي");
  });

  it("surfaces the server's outstanding_after verbatim — the client never recomputes a balance", async () => {
    rpcMock.mockResolvedValue(PAY_OK);
    const result = await recordSupplierPaymentAction({ invoice_id: INVOICE_ID, amount: "500.00", payment_mode: "cash", business_date: "2026-09-05" });
    expect(result.success).toBe(true);
    expect(result.success === true && result.data.outstanding_after).toBe("650.00");
  });
});

describe("supplier catalogue actions — gate on purchases.manage_suppliers alone", () => {
  it("createSupplierAction gates on manage_suppliers, not on purchases.create", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: SUPPLIER_ID, code: "SUP-1", row_version: 1 }], error: null });
    await createSupplierAction({ code: "SUP-1", name_ar: "مورّد" });
    expect(requirePermission).toHaveBeenCalledWith("purchases.manage_suppliers");
    expect(requirePermission).not.toHaveBeenCalledWith("purchases.create");
  });

  it("updateSupplierAction always sends the row_version (never null/undefined)", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: SUPPLIER_ID, row_version: 2 }], error: null });
    await updateSupplierAction({ id: SUPPLIER_ID, row_version: 1, name_ar: "مورّد محدث" });
    const args = rpcMock.mock.calls[0][1];
    expect(args.p_expected_version).toBe(1);
    expect(args.p_expected_version).not.toBeNull();
  });

  it("updateSupplierAction rejects a missing row_version client-side — a NULL version would bypass optimistic concurrency in the DB", async () => {
    // @ts-expect-error deliberately omitting the required row_version
    const result = await updateSupplierAction({ id: SUPPLIER_ID, name_ar: "مورّد" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("setSupplierStatusAction forwards the requested status to the single status RPC", async () => {
    rpcMock.mockResolvedValue({ error: null });
    await setSupplierStatusAction(SUPPLIER_ID, "disabled");
    expect(rpcMock).toHaveBeenCalledWith("set_supplier_status", { p_id: SUPPLIER_ID, p_status: "disabled" });

    rpcMock.mockReset();
    rpcMock.mockResolvedValue({ error: null });
    await setSupplierStatusAction(SUPPLIER_ID, "active");
    expect(rpcMock).toHaveBeenCalledWith("set_supplier_status", { p_id: SUPPLIER_ID, p_status: "active" });
  });

  it("passes the supplier's VAT number through verbatim — recorded as supplied, never normalised or validated", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: SUPPLIER_ID, code: "SUP-1", row_version: 1 }], error: null });
    await createSupplierAction({ code: "SUP-1", name_ar: "مورّد", vat_number: "300000000000003" });
    expect(rpcMock.mock.calls[0][1].p_vat_number).toBe("300000000000003");
  });
});

describe("no action ever writes the base tables directly", () => {
  it("every mutation goes through a SECURITY DEFINER RPC (Layer-A lockdown, 0238)", async () => {
    rpcMock.mockResolvedValue(POST_OK);
    await postPurchaseInvoiceAction(invoiceInput());

    // Only `.rpc` exists on the mocked client — a `.from(...)` write would
    // throw here, which is exactly the point.
    expect(rpcMock).toHaveBeenCalledWith("post_purchase_invoice", expect.any(Object));
  });
});

describe("DECISION 5 — no purchase action can ever touch the operating-expense ledger", () => {
  it("not one purchase RPC name relates to expenses", async () => {
    rpcMock.mockResolvedValue(POST_OK);
    await postPurchaseInvoiceAction(invoiceInput());

    rpcMock.mockResolvedValue(PAY_OK);
    await recordSupplierPaymentAction({ invoice_id: INVOICE_ID, amount: "10.00", payment_mode: "cash", business_date: "2026-09-05" });

    const called = rpcMock.mock.calls.map((c) => c[0] as string);
    expect(called.length).toBeGreaterThan(0);
    for (const name of called) {
      expect(name).not.toMatch(/expense/);
    }
  });

  it("no purchase action revalidates the expenses route — the two ledgers do not affect each other", async () => {
    rpcMock.mockResolvedValue(POST_OK);
    await postPurchaseInvoiceAction(invoiceInput());
    const paths = revalidatePath.mock.calls.map((c) => c[0] as string);
    expect(paths).not.toContain("/expenses");
    expect(paths).not.toContain("/dashboard");
  });
});

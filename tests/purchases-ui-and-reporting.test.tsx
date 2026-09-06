import { describe, expect, it, vi, beforeEach, beforeAll } from "vitest";
import { cleanup, render, screen, fireEvent, waitFor } from "@testing-library/react";
import "@testing-library/jest-dom";

// Phase 11 (Purchases & Suppliers Core) — UI behaviour + reporting
// presentation.
//
//   * PurchaseInvoiceForm: the accounting boundary is stated on screen; the
//     closed-day reason is revealed only after the server refuses the date;
//     amounts submit as raw strings; a line whose arithmetic does not hold
//     blocks submission instead of being silently "corrected".
//   * PurchaseReverseDialog: refuses up front while an unreversed payment
//     stands, and otherwise sends the reversal's OWN date and reason.
//   * SupplierPaymentDialog: partial payment with a mandatory mode; amount
//     submitted verbatim.
//   * The purchases report definition: no recoverable-input-VAT column, and
//     the VAT column is honestly labelled as what the supplier charged.

beforeAll(() => {
  // Radix <Select>/<Dialog> need these jsdom polyfills — same well-known
  // requirement already established by tests/expenses-ui-and-reporting.test.tsx.
  /* eslint-disable @typescript-eslint/no-explicit-any */
  (window.HTMLElement.prototype as any).hasPointerCapture = vi.fn(() => false);
  (window.HTMLElement.prototype as any).releasePointerCapture = vi.fn();
  (window.HTMLElement.prototype as any).setPointerCapture = vi.fn();
  window.HTMLElement.prototype.scrollIntoView = vi.fn();
  (global as any).ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  /* eslint-enable @typescript-eslint/no-explicit-any */
});

const { postPurchaseInvoiceAction, reversePurchaseInvoiceAction, recordSupplierPaymentAction, reverseSupplierPaymentAction } = vi.hoisted(() => ({
  postPurchaseInvoiceAction: vi.fn(),
  reversePurchaseInvoiceAction: vi.fn(),
  recordSupplierPaymentAction: vi.fn(),
  reverseSupplierPaymentAction: vi.fn(),
}));
vi.mock("@/features/purchases/actions", () => ({
  postPurchaseInvoiceAction,
  reversePurchaseInvoiceAction,
  recordSupplierPaymentAction,
  reverseSupplierPaymentAction,
  createSupplierAction: vi.fn(),
  updateSupplierAction: vi.fn(),
  setSupplierStatusAction: vi.fn(),
}));

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

const { push } = vi.hoisted(() => ({ push: vi.fn() }));
vi.mock("next/navigation", () => ({ useRouter: () => ({ push }) }));

// The report registry starts with `import "server-only"`, whose default Node
// resolution condition throws unconditionally — mocked exactly as in
// tests/expenses-ui-and-reporting.test.tsx.
vi.mock("server-only", () => ({}));

import { PurchaseInvoiceForm } from "@/features/purchases/components/purchase-invoice-form";
import { PurchaseReverseDialog, SupplierPaymentDialog } from "@/features/purchases/components/purchase-dialogs";
import { PURCHASES_COLUMNS, PURCHASES_SUMMARY_FIELDS, TABLE_REPORTS } from "@/features/reports/export/report-registry";

const STORES = [{ id: "11111111-1111-1111-1111-111111111111", name_ar: "فرع الرياض" }];
const SUPPLIERS = [{ id: "22222222-2222-2222-2222-222222222222", code: "SUP-1", name_ar: "مورّد الذهب" }];
const ITEMS = [{ id: "33333333-3333-3333-3333-333333333333", sku: "SKU-1", name_ar: "خاتم" }];
const INVOICE_ID = "44444444-4444-4444-4444-444444444444";

/** Fills the single default line with an internally consistent 1000 + 150 = 1150. */
function fillConsistentLine() {
  fireEvent.change(screen.getByLabelText("كمية البند 1"), { target: { value: "10" } });
  fireEvent.change(screen.getByLabelText("تكلفة وحدة البند 1"), { target: { value: "100" } });
  fireEvent.change(screen.getByLabelText("صافي البند 1"), { target: { value: "1000.00" } });
  fireEvent.change(screen.getByLabelText("ضريبة البند 1"), { target: { value: "150.00" } });
  fireEvent.change(screen.getByLabelText("إجمالي البند 1"), { target: { value: "1150.00" } });
}

beforeEach(() => {
  cleanup();
  postPurchaseInvoiceAction.mockReset();
  reversePurchaseInvoiceAction.mockReset();
  recordSupplierPaymentAction.mockReset();
  reverseSupplierPaymentAction.mockReset();
  push.mockReset();
});

describe("PurchaseInvoiceForm — DECISION 5 stated honestly on the screen the operator uses", () => {
  it("says plainly that an inventory purchase is not an operating expense", () => {
    render(<PurchaseInvoiceForm stores={STORES} suppliers={SUPPLIERS} items={ITEMS} />);
    expect(screen.getByText(/شراء المخزون ليس مصروفًا تشغيليًا/)).toBeInTheDocument();
  });

  it("names the three figures a purchase must NOT reach", () => {
    render(<PurchaseInvoiceForm stores={STORES} suppliers={SUPPLIERS} items={ITEMS} />);
    const text = document.body.textContent ?? "";
    expect(text).toContain("مصروفات الفروع");
    expect(text).toContain("صافي العائد التشغيلي");
    expect(text).toContain("تكلفة البضاعة المباعة");
  });

  it("admits the duplicate-entry risk is HUMAN rather than claiming a structural guarantee", () => {
    // The task is explicit: report any unavoidable human double-entry risk
    // honestly, and do not pretend classification provides a guarantee. If this
    // sentence is ever softened into a promise, this test fails.
    render(<PurchaseInvoiceForm stores={STORES} suppliers={SUPPLIERS} items={ITEMS} />);
    expect(screen.getByText(/النظام لا يمنع ذلك تقنيًا/)).toBeInTheDocument();
  });
});

describe("PurchaseInvoiceForm — totals, validation and the money-as-string contract", () => {
  it("computes the running totals exactly from the line amounts", () => {
    render(<PurchaseInvoiceForm stores={STORES} suppliers={SUPPLIERS} items={ITEMS} />);
    fillConsistentLine();

    const text = document.body.textContent ?? "";
    expect(text).toContain("1000.00");
    expect(text).toContain("150.00");
    expect(text).toContain("1150.00");
  });

  it("flags a line whose gross <> net + vat instead of silently correcting it", () => {
    render(<PurchaseInvoiceForm stores={STORES} suppliers={SUPPLIERS} items={ITEMS} />);
    fillConsistentLine();
    fireEvent.change(screen.getByLabelText("إجمالي البند 1"), { target: { value: "1149.99" } });

    expect(screen.getByText(/إجماليها لا يساوي الصافي \+ الضريبة/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /ترحيل الفاتورة/ })).toBeDisabled();
  });

  it("disables VAT and rate entry on a non-standard treatment — such a line may not carry either", async () => {
    render(<PurchaseInvoiceForm stores={STORES} suppliers={SUPPLIERS} items={ITEMS} />);
    expect(screen.getByLabelText("ضريبة البند 1")).not.toBeDisabled();

    fireEvent.click(screen.getByLabelText("المعالجة الضريبية للبند 1"));
    fireEvent.click(await screen.findByRole("option", { name: "معفاة" }));

    await waitFor(() => expect(screen.getByLabelText("ضريبة البند 1")).toBeDisabled());
    expect(screen.getByLabelText("نسبة ضريبة البند 1")).toBeDisabled();
    expect((screen.getByLabelText("ضريبة البند 1") as HTMLInputElement).value).toBe("0");
  });

  it("supports multiple lines, and the totals follow", () => {
    render(<PurchaseInvoiceForm stores={STORES} suppliers={SUPPLIERS} items={ITEMS} />);
    fillConsistentLine();
    fireEvent.click(screen.getByRole("button", { name: /إضافة بند/ }));

    fireEvent.change(screen.getByLabelText("صافي البند 2"), { target: { value: "0.10" } });
    fireEvent.change(screen.getByLabelText("ضريبة البند 2"), { target: { value: "0.02" } });
    fireEvent.change(screen.getByLabelText("إجمالي البند 2"), { target: { value: "0.12" } });

    // 1000.00 + 0.10 = 1000.10 exactly — a float sum would risk 1000.0999...
    expect(document.body.textContent ?? "").toContain("1000.10");
    expect(document.body.textContent ?? "").toContain("1150.12");
  });

  it("submits every amount as a raw string, exactly as typed", async () => {
    postPurchaseInvoiceAction.mockResolvedValue({ success: true, data: { id: INVOICE_ID, purchase_number: "PUR-1", gross_total: "1150.00" }, message: "ok" });

    render(<PurchaseInvoiceForm stores={STORES} suppliers={SUPPLIERS} items={ITEMS} />);
    fillConsistentLine();

    fireEvent.click(screen.getByLabelText("صنف البند 1"));
    fireEvent.click(await screen.findByRole("option", { name: /خاتم/ }));
    fireEvent.click(screen.getByText("المورّد").parentElement!.querySelector("button")!);
    fireEvent.click(await screen.findByRole("option", { name: "مورّد الذهب" }));
    fireEvent.click(screen.getByText("الفرع المستلِم").parentElement!.querySelector("button")!);
    fireEvent.click(await screen.findByRole("option", { name: "فرع الرياض" }));

    fireEvent.submit(screen.getByLabelText("صافي البند 1").closest("form")!);

    await waitFor(() => expect(postPurchaseInvoiceAction).toHaveBeenCalled());
    const payload = postPurchaseInvoiceAction.mock.calls[0][0];
    expect(typeof payload.gross_total).toBe("string");
    expect(payload.gross_total).toBe("1150.00");
    expect(typeof payload.lines[0].net_amount).toBe("string");
    expect(payload.lines[0].net_amount).toBe("1000.00");
  });

  it("does not render the closed-day reason field until the server refuses the date", () => {
    render(<PurchaseInvoiceForm stores={STORES} suppliers={SUPPLIERS} items={ITEMS} />);
    expect(screen.queryByLabelText("سبب الترحيل في يوم مقفل")).not.toBeInTheDocument();
  });

  it("reveals the closed-day reason field ONLY after the server returns a closed-day error", async () => {
    postPurchaseInvoiceAction.mockResolvedValue({
      success: false,
      error: "تاريخ الفاتورة (2026-09-01) يقع في يوم مقفل لهذا الفرع — يتطلب صلاحية خاصة (purchases.process_closed_day)",
    });

    render(<PurchaseInvoiceForm stores={STORES} suppliers={SUPPLIERS} items={ITEMS} />);
    fillConsistentLine();
    fireEvent.submit(screen.getByLabelText("صافي البند 1").closest("form")!);

    await waitFor(() => expect(screen.getByLabelText("سبب الترحيل في يوم مقفل")).toBeInTheDocument());
  });
});

describe("PurchaseReverseDialog — the payment ordering rule is enforced before a failed round-trip", () => {
  it("refuses up front while an unreversed payment stands, offering no form at all", () => {
    render(<PurchaseReverseDialog invoiceId={INVOICE_ID} purchaseNumber="PUR-0000000001" grossTotal="1150.00" hasUnreversedPayment />);
    fireEvent.click(screen.getByRole("button", { name: /عكس الفاتورة/ }));

    expect(screen.getByText(/اعكس الدفعات أولًا/)).toBeInTheDocument();
    expect(screen.queryByLabelText("سبب العكس")).not.toBeInTheDocument();
  });

  it("sends the reversal's own business date and reason, keyed to the original invoice", async () => {
    reversePurchaseInvoiceAction.mockResolvedValue({ success: true, data: { id: "x", purchase_number: "PUR-2", gross_total: "-1150.00" }, message: "ok" });

    render(<PurchaseReverseDialog invoiceId={INVOICE_ID} purchaseNumber="PUR-0000000001" grossTotal="1150.00" hasUnreversedPayment={false} />);
    fireEvent.click(screen.getByRole("button", { name: /عكس الفاتورة/ }));

    const reason = screen.getByLabelText("سبب العكس");
    fireEvent.change(reason, { target: { value: "بضاعة مرتجعة للمورّد" } });
    fireEvent.change(screen.getByLabelText("تاريخ العكس"), { target: { value: "2026-09-30" } });
    fireEvent.submit(reason.closest("form")!);

    await waitFor(() => expect(reversePurchaseInvoiceAction).toHaveBeenCalled());
    expect(reversePurchaseInvoiceAction.mock.calls[0][0]).toMatchObject({
      invoice_id: INVOICE_ID,
      reason: "بضاعة مرتجعة للمورّد",
      business_date: "2026-09-30",
    });
  });

  it("tells the user the original is never edited or deleted, and that stock comes back out", () => {
    render(<PurchaseReverseDialog invoiceId={INVOICE_ID} purchaseNumber="PUR-0000000001" grossTotal="1150.00" hasUnreversedPayment={false} />);
    fireEvent.click(screen.getByRole("button", { name: /عكس الفاتورة/ }));
    expect(screen.getByText(/لا تُعدَّل الفاتورة الأصلية ولا تُحذف/)).toBeInTheDocument();
    expect(screen.getByText(/يُعاد إخراج كميات الفاتورة من المخزون/)).toBeInTheDocument();
  });
});

describe("SupplierPaymentDialog — partial payments, amount verbatim", () => {
  it("shows the current remaining balance and submits the amount as a raw string", async () => {
    recordSupplierPaymentAction.mockResolvedValue({
      success: true,
      data: { id: "p", payment_number: "SPY-1", amount: "350.50", outstanding_after: "799.50" },
      message: "ok",
    });

    render(<SupplierPaymentDialog invoiceId={INVOICE_ID} purchaseNumber="PUR-0000000001" outstanding="1150.00" />);
    fireEvent.click(screen.getByRole("button", { name: /تسجيل دفعة/ }));

    expect(screen.getByText(/المتبقي حاليًا: 1150.00/)).toBeInTheDocument();

    const amount = screen.getByLabelText("المبلغ");
    fireEvent.change(amount, { target: { value: "350.50" } });
    fireEvent.submit(amount.closest("form")!);

    await waitFor(() => expect(recordSupplierPaymentAction).toHaveBeenCalled());
    const payload = recordSupplierPaymentAction.mock.calls[0][0];
    expect(typeof payload.amount).toBe("string");
    expect(payload.amount).toBe("350.50");
    expect(payload.payment_mode).toBe("cash");
  });

  it("states that a payment is corrected by a dated reversal, never edited", () => {
    render(<SupplierPaymentDialog invoiceId={INVOICE_ID} purchaseNumber="PUR-0000000001" outstanding="1150.00" />);
    fireEvent.click(screen.getByRole("button", { name: /تسجيل دفعة/ }));
    expect(screen.getByText(/التصحيح يتم بحركة عكس مؤرَّخة/)).toBeInTheDocument();
  });
});

describe("purchases report definition — tax data without a recoverability claim", () => {
  it("is registered under the purchases.view domain permission and reuses the screen's own engine", () => {
    expect(TABLE_REPORTS.purchases).toBeDefined();
    expect(TABLE_REPORTS.purchases.domainPermission).toBe("purchases.view");
    expect(TABLE_REPORTS.purchases.columns).toBe(PURCHASES_COLUMNS);
    expect(TABLE_REPORTS.purchases.summaryFields).toBe(PURCHASES_SUMMARY_FIELDS);
  });

  it("exposes NO recoverable-input-VAT column or summary field", () => {
    // Decision 4: Phase 11 stores tax data without deciding eligibility. A
    // column implying recoverability would assert something never determined.
    const keys = [...PURCHASES_COLUMNS.map((c) => c.key), ...PURCHASES_SUMMARY_FIELDS.map((f) => f.key)];
    for (const key of keys) {
      expect(key).not.toMatch(/recover|reclaim|deduct|input_vat/i);
    }
    const labels = [...PURCHASES_COLUMNS.map((c) => c.label), ...PURCHASES_SUMMARY_FIELDS.map((f) => f.label)];
    for (const label of labels) {
      expect(label).not.toMatch(/قابلة للاسترداد|الضريبة المستردة|خصم الضريبة/);
    }
  });

  it("labels the VAT summary as what suppliers charged, not as a recoverable amount", () => {
    const vat = PURCHASES_SUMMARY_FIELDS.find((f) => f.key === "vat_total");
    expect(vat?.label).toContain("كما وردت من الموردين");
  });

  it("states in its own description that acquisition cost stays out of expenses, net operating return and COGS", () => {
    const description = TABLE_REPORTS.purchases.descriptionAr;
    expect(description).toContain("توثيقية");
    expect(description).toContain("صافي العائد التشغيلي");
    expect(description).toContain("تكلفة البضاعة المباعة");
  });

  it("carries an outstanding-liability summary derived server-side", () => {
    expect(PURCHASES_SUMMARY_FIELDS.some((f) => f.key === "outstanding_total")).toBe(true);
  });
});

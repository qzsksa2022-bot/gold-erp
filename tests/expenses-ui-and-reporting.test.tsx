import { describe, expect, it, vi, beforeEach, beforeAll } from "vitest";
import { cleanup, render, screen, fireEvent, waitFor } from "@testing-library/react";
import "@testing-library/jest-dom";

// Phase 10 (Store Expenses Core) — UI behaviour + reporting presentation.
//
//   * ExpenseRecordDialog: the closed-day reason field is REVEALED only after
//     the server has actually refused the date, so it can never be used to
//     pre-emptively bypass the daily-close guard.
//   * ExpenseReverseDialog: the reversal carries its OWN date and a mandatory
//     reason.
//   * NetOperatingReturnCard: the long-standing net_operating_return value is
//     never labelled as an after-expenses figure, and the genuine
//     after-expenses result is shown only when the actor holds expenses.view
//     (§79 true key-absence, migration 0236).

beforeAll(() => {
  // Radix <Select>/<Dialog> need these jsdom polyfills — same well-known
  // requirement already established by tests/report-filter-bar-and-period-
  // picker.test.tsx and tests/settlements-preview-state-machine.test.tsx.
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

const { recordStoreExpenseAction, reverseStoreExpenseAction } = vi.hoisted(() => ({
  recordStoreExpenseAction: vi.fn(),
  reverseStoreExpenseAction: vi.fn(),
}));
vi.mock("@/features/expenses/actions", () => ({
  recordStoreExpenseAction,
  reverseStoreExpenseAction,
  createExpenseCategoryAction: vi.fn(),
  updateExpenseCategoryAction: vi.fn(),
  setExpenseCategoryStatusAction: vi.fn(),
}));

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

// NetOperatingReturnCard imports MANAGEMENT_NOR_FIELDS from the reports
// export registry, which starts with `import "server-only"` — that module's
// default Node resolution condition throws unconditionally, and only no-ops
// under the "react-server" condition Next.js's bundler sets (which Vitest does
// not). Mocked exactly as in tests/reports-dashboard-components.test.tsx.
vi.mock("server-only", () => ({}));

import { ExpenseRecordDialog } from "@/features/expenses/components/expense-record-dialog";
import { ExpenseReverseDialog } from "@/features/expenses/components/expense-reverse-dialog";
import { NetOperatingReturnCard } from "@/features/dashboard/components/net-operating-return-card";
import { formatSAR } from "@/lib/money";

const STORES = [{ id: "11111111-1111-1111-1111-111111111111", name_ar: "فرع الرياض" }];
const CATEGORIES = [{ id: "22222222-2222-2222-2222-222222222222", code: "RENT", name_ar: "إيجار" }];

beforeEach(() => {
  cleanup();
  recordStoreExpenseAction.mockReset();
  reverseStoreExpenseAction.mockReset();
});

describe("ExpenseRecordDialog — closed-day reason is server-driven, never pre-emptive", () => {
  it("does not render the closed-day reason field until the server refuses the date", async () => {
    render(<ExpenseRecordDialog stores={STORES} categories={CATEGORIES} />);
    fireEvent.click(screen.getByRole("button", { name: /تسجيل مصروف/ }));

    expect(screen.queryByLabelText("سبب التسجيل في يوم مقفل")).not.toBeInTheDocument();
  });

  it("reveals the closed-day reason field ONLY after the server returns a closed-day error", async () => {
    recordStoreExpenseAction.mockResolvedValue({
      success: false,
      error: "تاريخ المصروف (2026-09-01) يقع في يوم مقفل لهذا الفرع — يتطلب صلاحية خاصة (expenses.process_closed_day)",
    });

    render(<ExpenseRecordDialog stores={STORES} categories={CATEGORIES} />);
    fireEvent.click(screen.getByRole("button", { name: /تسجيل مصروف/ }));

    fireEvent.change(screen.getByLabelText("المبلغ"), { target: { value: "100.00" } });
    fireEvent.submit(screen.getByLabelText("المبلغ").closest("form")!);

    await waitFor(() => expect(screen.getByLabelText("سبب التسجيل في يوم مقفل")).toBeInTheDocument());
  });

  it("submits the amount as a raw string, exactly as typed", async () => {
    recordStoreExpenseAction.mockResolvedValue({ success: true, data: { id: "x", expense_number: "EXP-1", amount: "1500.50" }, message: "ok" });

    render(<ExpenseRecordDialog stores={STORES} categories={CATEGORIES} />);
    fireEvent.click(screen.getByRole("button", { name: /تسجيل مصروف/ }));

    fireEvent.change(screen.getByLabelText("المبلغ"), { target: { value: "1500.50" } });
    fireEvent.submit(screen.getByLabelText("المبلغ").closest("form")!);

    await waitFor(() => expect(recordStoreExpenseAction).toHaveBeenCalled());
    const payload = recordStoreExpenseAction.mock.calls[0][0];
    expect(typeof payload.amount).toBe("string");
    expect(payload.amount).toBe("1500.50");
  });
});

describe("ExpenseReverseDialog — dated reversal with a mandatory reason", () => {
  it("sends the reversal's own business date and reason, keyed to the original expense", async () => {
    reverseStoreExpenseAction.mockResolvedValue({ success: true, data: { id: "y", expense_number: "EXP-2", amount: "-1500.00" }, message: "ok" });

    render(<ExpenseReverseDialog expenseId="33333333-3333-3333-3333-333333333333" expenseNumber="EXP-0000000001" amount="1500.00" />);
    fireEvent.click(screen.getByRole("button", { name: /عكس/ }));

    const reason = screen.getByLabelText("سبب العكس");
    fireEvent.change(reason, { target: { value: "دفعة مكررة" } });
    fireEvent.change(screen.getByLabelText("تاريخ العكس"), { target: { value: "2026-09-30" } });
    fireEvent.submit(reason.closest("form")!);

    await waitFor(() => expect(reverseStoreExpenseAction).toHaveBeenCalled());
    expect(reverseStoreExpenseAction.mock.calls[0][0]).toMatchObject({
      expense_id: "33333333-3333-3333-3333-333333333333",
      reason: "دفعة مكررة",
      business_date: "2026-09-30",
    });
  });

  it("tells the user the original is never edited or deleted", () => {
    render(<ExpenseReverseDialog expenseId="33333333-3333-3333-3333-333333333333" expenseNumber="EXP-0000000001" amount="1500.00" />);
    fireEvent.click(screen.getByRole("button", { name: /عكس/ }));
    expect(screen.getByText(/لن يُعدَّل أو يُحذف المصروف الأصلي/)).toBeInTheDocument();
  });
});

describe("NetOperatingReturnCard — the legacy value is never presented as an after-expenses result", () => {
  const LEGACY_ONLY = {
    effective_net_sales_profit: "0.00",
    net_shipping_result: "10.00",
    net_adjustments_result: "58.00",
    net_operating_return: "68.00",
    previous_net_operating_return: "0.00",
    net_operating_return_change: "68.00",
    net_operating_return_pct_change: null,
  };

  it("labels the legacy figure as a contribution BEFORE expenses", () => {
    render(<NetOperatingReturnCard nor={LEGACY_ONLY} />);
    // The wording appears both as the card heading and in the formula line —
    // both must say "before expenses", so getAllByText is the correct query.
    expect(screen.getAllByText(/المساهمة التشغيلية قبل المصروفات/).length).toBeGreaterThan(0);
    // And the old wording must be gone entirely.
    expect(screen.queryByText(/^صافي العائد التشغيلي —/)).not.toBeInTheDocument();
  });

  it("§79: an actor without expenses.view sees no after-expenses figure at all (the keys are absent, not zero)", () => {
    render(<NetOperatingReturnCard nor={LEGACY_ONLY} />);
    expect(screen.queryByText(/صافي النتيجة التشغيلية بعد المصروفات/)).not.toBeInTheDocument();
    expect(screen.queryByText(/المصروفات التشغيلية:/)).not.toBeInTheDocument();
  });

  it("shows BOTH figures when the expense keys are present, without altering the legacy one", () => {
    render(
      <NetOperatingReturnCard
        nor={{
          ...LEGACY_ONLY,
          operating_contribution_before_expenses: "68.00",
          operating_expenses_total: "18.00",
          net_operating_result_after_expenses: "50.00",
        }}
      />,
    );

    expect(screen.getByText(/صافي النتيجة التشغيلية بعد المصروفات/)).toBeInTheDocument();
    // The legacy 68.00 is still rendered as the headline contribution, and the
    // 50.00 after-expenses result is rendered separately — proving the two are
    // reported independently rather than one replacing the other. Compared
    // through the SAME formatter the component uses, since formatSAR() renders
    // locale-specific digits and a currency symbol, not raw "68.00".
    const text = document.body.textContent ?? "";
    expect(text).toContain(formatSAR("68.00"));
    expect(text).toContain(formatSAR("50.00"));
    expect(text).toContain(formatSAR("18.00"));
  });

  it("renders nothing at all when net_operating_return itself is absent (§79)", () => {
    const { container } = render(<NetOperatingReturnCard nor={undefined} />);
    expect(container).toBeEmptyDOMElement();
  });
});

// Hotfix 4.2.1 (Section 16) — mandatory regression test for the button-
// gating fix in refund-events-panel.tsx.
//
// Bug being guarded against: BEFORE this hotfix, "تسجيل استرداد" (Record
// Refund) and the per-event "تراجع" (Reverse) button were shown whenever
// their OWN narrower conditions held (return approved / event active),
// completely independent of whether the refund reconciliation had already
// been Finalized — clicking either one then always failed server-side with
// a "يجب إعادة فتح التسوية أولاً" (must reopen first) error. The DB
// (record_sales_return_refund()/reverse_sales_return_refund_event(),
// migration 0107) remains the real authority either way; this test proves
// the CLIENT no longer offers an action guaranteed to be rejected.
//
// Two states are asserted, mirroring the spec's own wording exactly:
//   - Finalized state: no Record Refund action, no Reverse Refund action
//     (even though the event itself is still 'active'), Reopen visible.
//   - Open (not finalized) state: Record visible, Reverse (for active
//     events) visible, Reopen NOT visible.
import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import "@testing-library/jest-dom/vitest";

vi.mock("next/navigation", () => ({
  useRouter: () => ({
    refresh: vi.fn(),
    push: vi.fn(),
    replace: vi.fn(),
    back: vi.fn(),
    forward: vi.fn(),
    prefetch: vi.fn(),
  }),
}));

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn() },
}));

// ../actions.ts is a "use server" module (imports @/lib/supabase/server,
// which imports the `server-only` package guard). Real Next.js replaces a
// "use server" module's exports with callable server-action proxies when
// imported from client code; plain Vite/Vitest has no such transform and
// would otherwise execute the real module body (and its `server-only`
// import) directly. Stub it out — this test only exercises the panel's
// button-gating render logic, never actually invokes these actions.
vi.mock("../actions", () => ({
  recordSalesReturnRefundAction: vi.fn(),
  reverseSalesReturnRefundEventAction: vi.fn(),
  finalizeSalesReturnRefundAction: vi.fn(),
  reopenSalesReturnRefundReconciliationAction: vi.fn(),
}));

import { PermissionsProvider } from "@/lib/permissions/context";
import { RefundEventsPanel, type ReconciliationHistoryEvent } from "./refund-events-panel";

const ACTIVE_EVENT = {
  id: "event-active-1",
  amount: "100.00",
  refund_method_id: "method-1",
  refund_method_name_snapshot: "تحويل بنكي",
  reference: null,
  refund_business_date: "2026-08-01",
  refunded_at: "2026-08-01T10:00:00Z",
  notes: null,
  status: "active" as const,
  reversed_at: null,
  reversal_business_date: null,
  reversal_reason: null,
};

const REVERSED_EVENT = {
  ...ACTIVE_EVENT,
  id: "event-reversed-1",
  status: "reversed" as const,
  reversed_at: "2026-08-02T10:00:00Z",
  reversal_reason: "خطأ في القيد",
};

function renderPanel(overrides: Partial<Parameters<typeof RefundEventsPanel>[0]> = {}) {
  const props = {
    returnId: "return-1",
    returnStatus: "approved",
    rowVersion: 1,
    refundEvents: [ACTIVE_EVENT],
    refundMethods: [{ id: "method-1", name_ar: "تحويل بنكي" }],
    approvedRefundAmount: "100.00",
    actualRefundedTotal: "100.00",
    refundReconciliationState: "pending",
    refundFinalizedAt: null as string | null,
    refundFinalVarianceReason: null as string | null,
    reconciliationHistory: [] as ReconciliationHistoryEvent[],
    ...overrides,
  };

  return render(
    <PermissionsProvider permissions={["returns.record_refund"]} isSuperAdmin={false}>
      <RefundEventsPanel {...props} />
    </PermissionsProvider>,
  );
}

describe("RefundEventsPanel — Hotfix 4.2.1 Section 16 button gating", () => {
  it("Open state (not finalized): shows Record Refund and shows Reverse for the active event, does not show Reopen", () => {
    renderPanel({
      returnStatus: "approved",
      refundFinalizedAt: null,
      refundReconciliationState: "pending",
      refundEvents: [ACTIVE_EVENT],
    });

    expect(screen.getByRole("button", { name: /تسجيل استرداد/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^تراجع$/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /إعادة فتح التسوية/ })).not.toBeInTheDocument();
  });

  it("Finalized state: hides Record Refund and hides Reverse (even though the event is still active), shows Reopen", () => {
    renderPanel({
      returnStatus: "approved",
      refundFinalizedAt: "2026-08-05T12:00:00Z",
      refundReconciliationState: "finalized_matched",
      refundEvents: [ACTIVE_EVENT],
    });

    expect(screen.queryByRole("button", { name: /تسجيل استرداد/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^تراجع$/ })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /إعادة فتح التسوية/ })).toBeInTheDocument();
  });

  it("Finalized state with a REVERSED event: no Reverse button is offered (already reversed), and a 'متراجَع عنه' badge is shown instead — never a dead action", () => {
    renderPanel({
      returnStatus: "approved",
      refundFinalizedAt: "2026-08-05T12:00:00Z",
      refundReconciliationState: "finalized_matched",
      refundEvents: [REVERSED_EVENT],
    });

    expect(screen.queryByRole("button", { name: /^تراجع$/ })).not.toBeInTheDocument();
    expect(screen.getByText("متراجَع عنه")).toBeInTheDocument();
  });

  it("Open state with a REVERSED event: still no Reverse button for that event (an already-reversed event is never re-offered for reversal)", () => {
    renderPanel({
      returnStatus: "approved",
      refundFinalizedAt: null,
      refundReconciliationState: "pending",
      refundEvents: [REVERSED_EVENT],
    });

    expect(screen.queryByRole("button", { name: /^تراجع$/ })).not.toBeInTheDocument();
    expect(screen.getByText("متراجَع عنه")).toBeInTheDocument();
  });

  it("Non-approved return status (e.g. 'pending'): Record Refund is never offered regardless of finalized state", () => {
    renderPanel({
      returnStatus: "pending",
      refundFinalizedAt: null,
      refundReconciliationState: "not_applicable",
      refundEvents: [],
    });

    expect(screen.queryByRole("button", { name: /تسجيل استرداد/ })).not.toBeInTheDocument();
  });
});

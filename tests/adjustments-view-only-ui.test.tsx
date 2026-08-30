import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import { PermissionsProvider } from "@/lib/permissions/context";
import { AdjustmentLifecycleActions } from "@/features/adjustments/components/adjustment-lifecycle-actions";
import AdjustmentsPage from "@/app/(app)/adjustments/page";

// Phase 6 (Services / Adjustments Core) — "adjustments.view-only UI
// regression", mirroring tests/shipment-view-only-ui.test.tsx exactly. An
// actor holding ONLY adjustments.view (no adjustments.create/approve/
// reverse) must never even SEE the approve/reject/edit/reverse action UI —
// gated client-side via <Can>, which is UX-only (the real authority is each
// Server Action's own requirePermission() call, exercised separately in
// tests/adjustments-actions-permission-boundary.test.ts) — but a regression
// here would still let a view-only actor see (and attempt) actions the
// server will reject.
//
// Also covers §29 (DB-level profit privacy) at the UI layer: a view-only
// actor without sales.view_profit must see customer_charge (customer-
// facing, never profit-gated) but never net_adjustment_profit — proven
// against the REAL AdjustmentsPage list Server Component, called directly.

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
  usePathname: () => "/adjustments",
}));

vi.mock("@/features/adjustments/actions", () => ({
  approveAdjustmentAction: vi.fn(),
  rejectAdjustmentAction: vi.fn(),
  reverseAdjustmentAction: vi.fn(),
}));

const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const {
  listAdjustmentsPage,
  getAdjustmentsVisibleStoreLookups,
  getAdjustmentsFilterTypeLookups,
  getAdjustmentsFilterPaymentMethodLookups,
  getAdjustmentsFilterCollectionChannelLookups,
} = vi.hoisted(() => ({
  listAdjustmentsPage: vi.fn(),
  getAdjustmentsVisibleStoreLookups: vi.fn(async () => []),
  // Patch 6.1 item 22 — the /adjustments list page now calls the VIEW-only
  // filter lookups (0152), not the old CREATE-flow active-only pickers.
  getAdjustmentsFilterTypeLookups: vi.fn(async () => []),
  getAdjustmentsFilterPaymentMethodLookups: vi.fn(async () => []),
  getAdjustmentsFilterCollectionChannelLookups: vi.fn(async () => []),
}));
vi.mock("@/features/adjustments/queries", () => ({
  listAdjustmentsPage,
  getAdjustmentsVisibleStoreLookups,
  getAdjustmentsFilterTypeLookups,
  getAdjustmentsFilterPaymentMethodLookups,
  getAdjustmentsFilterCollectionChannelLookups,
}));

function renderLifecycleActions(permissions: string[], effectiveStatus: "pending" | "approved" | "rejected" | "reversed") {
  return render(
    <PermissionsProvider permissions={permissions as never} isSuperAdmin={false}>
      <AdjustmentLifecycleActions adjustmentId="adj-1" adjustmentNumber="ADJ-0000000001" effectiveStatus={effectiveStatus} rowVersion={1} />
    </PermissionsProvider>,
  );
}

describe("AdjustmentLifecycleActions — adjustments.view-only UI regression", () => {
  beforeEach(() => {
    cleanup();
  });

  it("a view-only actor (pending record) sees no approve/reject/edit buttons at all", () => {
    renderLifecycleActions(["adjustments.view"], "pending");
    expect(screen.queryByRole("button", { name: /اعتماد/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /رفض/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: /تعديل/ })).not.toBeInTheDocument();
  });

  it("an actor holding adjustments.approve sees approve/reject on a pending record", () => {
    renderLifecycleActions(["adjustments.view", "adjustments.approve"], "pending");
    expect(screen.getByRole("button", { name: /اعتماد/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /رفض/ })).toBeInTheDocument();
  });

  it("an actor holding adjustments.create (not adjustments.approve) sees the edit link but not approve/reject on a pending record", () => {
    renderLifecycleActions(["adjustments.view", "adjustments.create"], "pending");
    expect(screen.getByRole("link", { name: /تعديل/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /اعتماد/ })).not.toBeInTheDocument();
  });

  it("a view-only actor (approved record) sees no reverse button — adjustments.reverse is a distinct, unheld permission", () => {
    renderLifecycleActions(["adjustments.view"], "approved");
    expect(screen.queryByRole("button", { name: /عكس إداري/ })).not.toBeInTheDocument();
  });

  it("an actor holding adjustments.reverse (not adjustments.approve) DOES see the reverse button on an approved record", () => {
    renderLifecycleActions(["adjustments.view", "adjustments.reverse"], "approved");
    expect(screen.getByRole("button", { name: /عكس إداري/ })).toBeInTheDocument();
  });

  it("a rejected/reversed record shows no lifecycle action at all, regardless of permissions", () => {
    renderLifecycleActions(["adjustments.view", "adjustments.approve", "adjustments.reverse", "adjustments.create"], "rejected");
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
    expect(screen.queryByRole("link")).not.toBeInTheDocument();
  });
});

const ADJUSTMENT_ROW = {
  id: "adj-1",
  adjustment_number: "ADJ-0000000001",
  sales_order_id: "so-1",
  order_number: "SALE-0000000090",
  adjustment_type_name_ar: "خدمة تلميع",
  processing_store_name: "فرع الرياض",
  adjustment_date: "2026-08-15",
  payment_method_name: "فيزا",
  customer_charge: "100.00",
  // Patch 6.1 item 19 (migration 0151) renamed this to effective_
  // net_adjustment_profit — see AdjustmentsPage's table cell.
  effective_net_adjustment_profit: "67.50",
  status: "approved",
  effective_status: "approved",
  participates_in_settlement: false,
};

async function renderAdjustmentsPage(permissions: string[]) {
  requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(permissions) });
  listAdjustmentsPage.mockResolvedValue({ rows: [ADJUSTMENT_ROW], total: 1 });
  // AdjustmentsPage is `export default async function AdjustmentsPage(...)`
  // — a Server Component is just an async function returning JSX; calling
  // it directly and rendering the resolved element is the same technique
  // used throughout this codebase (see tests/shipment-view-only-ui.test.tsx).
  const ui = await AdjustmentsPage({ searchParams: Promise.resolve({}) });
  return render(
    <PermissionsProvider permissions={permissions as never} isSuperAdmin={false}>
      {ui}
    </PermissionsProvider>,
  );
}

describe("AdjustmentsPage (/adjustments list) — §29 DB-level profit privacy at the UI layer", () => {
  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    listAdjustmentsPage.mockReset();
    getAdjustmentsVisibleStoreLookups.mockClear();
    getAdjustmentsFilterTypeLookups.mockClear();
    getAdjustmentsFilterPaymentMethodLookups.mockClear();
    getAdjustmentsFilterCollectionChannelLookups.mockClear();
  });

  it("a view-only actor without sales.view_profit sees the adjustment number, order number, and customer_charge", async () => {
    await renderAdjustmentsPage(["adjustments.view"]);

    expect(screen.getByText("ADJ-0000000001")).toBeInTheDocument();
    expect(screen.getByText("SALE-0000000090")).toBeInTheDocument();
    // customer_charge is customer-facing, never profit-gated (§29, same
    // precedent as Shipping's customer_shipping_charge) — must stay visible.
    expect(screen.getByText("100.00")).toBeInTheDocument();
  });

  it("the SAME actor sees no 'صافي الربح' column header or value at all — canViewProfit gates the column itself, not just its value", async () => {
    await renderAdjustmentsPage(["adjustments.view"]);

    expect(screen.queryByText("صافي الربح")).not.toBeInTheDocument();
    expect(screen.queryByText("67.50")).not.toBeInTheDocument();
  });

  it("the SAME actor sees no 'تعديل/خدمة جديد' action — gated on adjustments.create, which this actor lacks", async () => {
    await renderAdjustmentsPage(["adjustments.view"]);

    expect(screen.queryByRole("link", { name: /تعديل\/خدمة جديد/ })).not.toBeInTheDocument();
  });

  it("control: an actor who ALSO holds sales.view_profit sees the 'صافي الربح' column and value — proves the view-only assertions above are meaningful, not vacuous", async () => {
    await renderAdjustmentsPage(["adjustments.view", "sales.view_profit"]);

    expect(screen.getByText("صافي الربح")).toBeInTheDocument();
    expect(screen.getByText("67.50")).toBeInTheDocument();
  });

  it("control: an actor who ALSO holds adjustments.create sees the 'تعديل/خدمة جديد' action", async () => {
    await renderAdjustmentsPage(["adjustments.view", "adjustments.create"]);

    expect(screen.getByRole("link", { name: /تعديل\/خدمة جديد/ })).toBeInTheDocument();
  });
});

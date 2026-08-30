import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import { PermissionsProvider } from "@/lib/permissions/context";
import { ShipmentStatusActions } from "@/features/shipping/components/shipment-status-actions";
import { ShipmentCodStateAction } from "@/features/shipping/components/shipment-cod-state-action";
import ShipmentsPage from "@/app/(app)/shipments/page";

// Hotfix 5.1.2 item 4 — "shipments.view-only UI regression" — a real actor
// holding ONLY shipments.view (no shipments.update_status/correct_status/
// manage_cost) must never even SEE the status-update or COD-recording
// action UI on the shipment detail page — both are gated client-side via
// <Can>/<PermissionsProvider>, which is UX-only (the real authority is each
// Server Action's own requirePermission()/requireAnyPermission() call,
// exercised separately by the SQL/HTTP suites) — but a regression here
// would still let a view-only actor see (and attempt) actions the server
// will reject, which is exactly the class of bug this test guards against.
//
// Hotfix 5.1.3 item 6 — the file's name/description always promised
// "viewer-only UI regression" coverage, but until now only the DETAIL
// page's two action components were actually tested — the /shipments LIST
// page (the original Requirement) had zero coverage here. Added below:
// ShipmentsPage (the actual Server Component, called directly and its
// resolved JSX rendered) for a shipments.view-only actor (no
// shipments.create, no sales.view_profit).

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
  usePathname: () => "/shipments",
}));

vi.mock("@/features/shipping/actions", () => ({
  addShipmentStatusEventAction: vi.fn(),
  recordShipmentCodCollectionStateAction: vi.fn(),
}));

// ShipmentsPage is an async Server Component — importing/calling it
// directly requires stubbing everything it touches at module load: the
// session gate (requirePermission) and every data query it awaits.
const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const { listShipmentsPage, getShipmentsVisibleStoreLookups, getShipmentsFilterCarrierLookups, getShipmentsFilterZoneLookups } = vi.hoisted(() => ({
  listShipmentsPage: vi.fn(),
  getShipmentsVisibleStoreLookups: vi.fn(async () => []),
  getShipmentsFilterCarrierLookups: vi.fn(async () => []),
  getShipmentsFilterZoneLookups: vi.fn(async () => []),
}));
vi.mock("@/features/shipping/queries", () => ({
  listShipmentsPage,
  getShipmentsVisibleStoreLookups,
  getShipmentsFilterCarrierLookups,
  getShipmentsFilterZoneLookups,
}));

function renderStatusActions(permissions: string[]) {
  return render(
    <PermissionsProvider permissions={permissions as never} isSuperAdmin={false}>
      <ShipmentStatusActions shipmentId="shp-1" currentStatus="created" rowVersion={1} />
    </PermissionsProvider>,
  );
}

function renderCodAction(permissions: string[]) {
  return render(
    <PermissionsProvider permissions={permissions as never} isSuperAdmin={false}>
      <ShipmentCodStateAction shipmentId="shp-1" rowVersion={1} currentState="unknown" suggestedNotCollected={false} />
    </PermissionsProvider>,
  );
}

describe("Shipment detail action components — shipments.view-only UI regression (Hotfix 5.1.2 item 4)", () => {
  beforeEach(() => {
    cleanup();
  });

  it("ShipmentStatusActions: a shipments.view-only actor sees no 'تحديث الحالة' button at all", () => {
    renderStatusActions(["shipments.view"]);
    expect(screen.queryByRole("button", { name: /تحديث الحالة/ })).not.toBeInTheDocument();
  });

  it("ShipmentStatusActions: an actor holding shipments.update_status DOES see the button", () => {
    renderStatusActions(["shipments.view", "shipments.update_status"]);
    expect(screen.getByRole("button", { name: /تحديث الحالة/ })).toBeInTheDocument();
  });

  it("ShipmentStatusActions: an actor holding ONLY shipments.correct_status (not update_status) also sees the button — <Can anyOf=[...]> must accept either, mirroring the Server Action's own requireAnyPermission (Hotfix 5.1.1 item 4)", () => {
    renderStatusActions(["shipments.view", "shipments.correct_status"]);
    expect(screen.getByRole("button", { name: /تحديث الحالة/ })).toBeInTheDocument();
  });

  it("ShipmentCodStateAction: a shipments.view-only actor sees no 'تسجيل حالة التحصيل' button and no current-state label at all", () => {
    renderCodAction(["shipments.view"]);
    expect(screen.queryByRole("button", { name: /تسجيل حالة التحصيل/ })).not.toBeInTheDocument();
    expect(screen.queryByText(/الحالة الحالية/)).not.toBeInTheDocument();
  });

  it("ShipmentCodStateAction: an actor holding shipments.manage_cost DOES see the button", () => {
    renderCodAction(["shipments.view", "shipments.manage_cost"]);
    expect(screen.getByRole("button", { name: /تسجيل حالة التحصيل/ })).toBeInTheDocument();
  });
});

const SHIPMENT_ROW = {
  id: "shp-1",
  shipment_number: "SHP-0000000001",
  order_number: "SALE-0000000090",
  return_number: null,
  shipment_date: "2026-08-15",
  store_name: "فرع الرياض",
  carrier_name: "سمسا",
  zone_name: "الرياض",
  tracking_number: "TRACK123",
  direction: "outbound",
  current_status: "created",
  customer_shipping_charge: "35.00",
  net_shipping_expected: "5.00",
  net_shipping_actual: "4.50",
};

async function renderShipmentsPage(permissions: string[]) {
  requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(permissions) });
  listShipmentsPage.mockResolvedValue({ rows: [SHIPMENT_ROW], total: 1 });
  // ShipmentsPage is `export default async function ShipmentsPage(...)` —
  // a Server Component is just an async function returning JSX; calling it
  // directly and rendering the resolved element is the same technique
  // used throughout this codebase's Server Action unit tests (see
  // tests/shipping-actions-permission-boundary.test.ts), applied here to a
  // page instead of an action. <Can permission="shipments.create"> inside
  // it still needs a real PermissionsProvider ancestor, same as the detail-
  // page components above (the page itself does not render one — that
  // happens in the (app) layout in the real app).
  const ui = await ShipmentsPage({ searchParams: Promise.resolve({}) });
  return render(
    <PermissionsProvider permissions={permissions as never} isSuperAdmin={false}>
      {ui}
    </PermissionsProvider>,
  );
}

describe("ShipmentsPage (/shipments list) — shipments.view-only UI regression (Hotfix 5.1.3 item 6)", () => {
  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    listShipmentsPage.mockReset();
    getShipmentsVisibleStoreLookups.mockClear();
    getShipmentsFilterCarrierLookups.mockClear();
    getShipmentsFilterZoneLookups.mockClear();
  });

  it("a shipments.view-only actor (no shipments.create, no sales.view_profit) sees shipment number, order number, and customer shipping charge", async () => {
    await renderShipmentsPage(["shipments.view"]);

    expect(screen.getByText("SHP-0000000001")).toBeInTheDocument();
    expect(screen.getByText("SALE-0000000090")).toBeInTheDocument();
    // Hotfix 5.1.1 item 8/Patch 5.1 item 10 — customer_shipping_charge is a
    // customer-facing operational figure, never profit-gated, so it must
    // stay visible even without sales.view_profit.
    expect(screen.getByText("35.00")).toBeInTheDocument();
  });

  it("the SAME view-only actor sees no Net Shipping (expected/actual) columns at all — canViewProfit gates the column headers themselves, not just their values", async () => {
    await renderShipmentsPage(["shipments.view"]);

    expect(screen.queryByText("صافي الشحن المتوقع")).not.toBeInTheDocument();
    expect(screen.queryByText("صافي الشحن الفعلي")).not.toBeInTheDocument();
    expect(screen.queryByText("5.00")).not.toBeInTheDocument();
    expect(screen.queryByText("4.50")).not.toBeInTheDocument();
  });

  it("the SAME view-only actor sees no 'شحنة جديدة' (new shipment) action — gated on shipments.create, which this actor lacks", async () => {
    await renderShipmentsPage(["shipments.view"]);

    expect(screen.queryByRole("link", { name: /شحنة جديدة/ })).not.toBeInTheDocument();
  });

  it("the page loads successfully for a shipments.view-only actor using the shipments.view-gated filter lookups — NOT the shipments.create-gated ones", async () => {
    await renderShipmentsPage(["shipments.view"]);

    // Patch 5.1 item 11 — the page must call shipments_filter_carrier_
    // lookups()/shipments_filter_zone_lookups() (gated on shipments.view
    // alone), never the older shipments.create-gated shipments_carrier_
    // lookups()/shipments_zone_lookups() the /shipments/new form uses. The
    // page rendering successfully at all (no throw from an RLS-style
    // denial) for a create-less actor, PLUS these specific mocks being the
    // ones actually invoked, together prove the page's data dependencies
    // never require shipments.create.
    expect(getShipmentsFilterCarrierLookups).toHaveBeenCalledTimes(1);
    expect(getShipmentsFilterZoneLookups).toHaveBeenCalledTimes(1);
    expect(getShipmentsVisibleStoreLookups).toHaveBeenCalledTimes(1);
  });

  it("control: an actor who ALSO holds sales.view_profit sees the Net Shipping columns and figures — proves the view-only assertions above are meaningful, not vacuous", async () => {
    await renderShipmentsPage(["shipments.view", "sales.view_profit"]);

    expect(screen.getByText("صافي الشحن المتوقع")).toBeInTheDocument();
    expect(screen.getByText("صافي الشحن الفعلي")).toBeInTheDocument();
    expect(screen.getByText("5.00")).toBeInTheDocument();
    expect(screen.getByText("4.50")).toBeInTheDocument();
  });

  it("control: an actor who ALSO holds shipments.create sees the 'شحنة جديدة' action", async () => {
    await renderShipmentsPage(["shipments.view", "shipments.create"]);

    expect(screen.getByRole("link", { name: /شحنة جديدة/ })).toBeInTheDocument();
  });
});

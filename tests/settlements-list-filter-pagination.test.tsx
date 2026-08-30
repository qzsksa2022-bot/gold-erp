import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import { PermissionsProvider } from "@/lib/permissions/context";
import SettlementsPage from "@/app/(app)/settlements/page";

// Phase 7 (Settlements Core) — mirrors Hotfix 6.1.1 item 10's own
// precedent (tests/adjustments-hotfix-6-1-1-list-reversal-pagination.test.
// tsx): the /settlements list page must carry every active filter through
// into both the Next and Previous pagination hrefs, driven purely by
// listSettlementBatchesPage()'s hasNextPage (never a fabricated total —
// see tests/settlements-pagination.test.tsx for the pageSize+1 query-layer
// technique itself, and settlement-batches-pager.tsx's own header comment).
// This file lives separately from settlements-pagination.test.tsx because
// that file imports queries.ts directly (unmocked) to exercise the real
// pagination arithmetic, and a second, conflicting vi.mock("@/features/
// settlements/queries", ...) in the same file would silently shadow that
// real import (vi.mock calls are hoisted file-wide, not scoped to where
// they're written).

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
  usePathname: () => "/settlements",
}));

const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const {
  listSettlementBatchesPage,
  getSettlementRouteFilterLookups,
  getSettlementStoreFilterLookups,
  getPaymentMethodFilterLookupsForSettlements,
  getCollectionChannelFilterLookupsForSettlements,
  getShippingCarrierFilterLookupsForSettlements,
} = vi.hoisted(() => ({
  listSettlementBatchesPage: vi.fn(),
  getSettlementRouteFilterLookups: vi.fn(async () => []),
  getSettlementStoreFilterLookups: vi.fn(async () => []),
  getPaymentMethodFilterLookupsForSettlements: vi.fn(async (): Promise<{ id: string; name_ar: string }[]> => []),
  getCollectionChannelFilterLookupsForSettlements: vi.fn(async (): Promise<{ id: string; name_ar: string }[]> => []),
  getShippingCarrierFilterLookupsForSettlements: vi.fn(async () => []),
}));
vi.mock("@/features/settlements/queries", () => ({
  listSettlementBatchesPage,
  getSettlementRouteFilterLookups,
  getSettlementStoreFilterLookups,
  getPaymentMethodFilterLookupsForSettlements,
  getCollectionChannelFilterLookupsForSettlements,
  getShippingCarrierFilterLookupsForSettlements,
}));

const ROW = { id: "b-1", settlement_number: "STL-0000000001", route_name_ar: "مسار فيزا", settlement_date: "2026-08-20", effective_status: "finalized", status: "finalized" };

describe("SettlementsPage — active filters survive Next/Previous pagination-link generation", () => {
  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    listSettlementBatchesPage.mockReset();
  });

  async function renderPage(searchParams: Record<string, string>) {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.view"]) });
    listSettlementBatchesPage.mockResolvedValue({ rows: [ROW], hasNextPage: true });
    const ui = await SettlementsPage({ searchParams: Promise.resolve(searchParams) });
    return render(
      <PermissionsProvider permissions={["settlements.view"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );
  }

  it("a 'finalized' status filter is preserved in the Next href", async () => {
    await renderPage({ effective_status: "finalized", page: "1" });
    const nextLink = screen.getByRole("link", { name: "التالي" }) as HTMLAnchorElement;
    expect(nextLink.getAttribute("href")).toContain("effective_status=finalized");
    expect(nextLink.getAttribute("href")).toContain("page=2");
  });

  it("a settlement_route_id filter is preserved in the Next href alongside a date range", async () => {
    await renderPage({ settlement_route_id: "route-9", date_from: "2026-08-01", date_to: "2026-08-31", page: "1" });
    const nextLink = screen.getByRole("link", { name: "التالي" }) as HTMLAnchorElement;
    expect(nextLink.getAttribute("href")).toContain("settlement_route_id=route-9");
    expect(nextLink.getAttribute("href")).toContain("date_from=2026-08-01");
    expect(nextLink.getAttribute("href")).toContain("date_to=2026-08-31");
  });

  it("SettlementsPage calls listSettlementBatchesPage with page derived from the searchParams, defaulting to 1 when absent/invalid", async () => {
    await renderPage({});
    expect(listSettlementBatchesPage).toHaveBeenCalledWith(expect.objectContaining({ page: 1 }), expect.any(Number));

    listSettlementBatchesPage.mockClear();
    await renderPage({ page: "4" });
    expect(listSettlementBatchesPage).toHaveBeenCalledWith(expect.objectContaining({ page: 4 }), expect.any(Number));
  });
});

// ---------------------------------------------------------------------------
// Hotfix 7.1.1 §12 (migration 0196) — getPaymentMethodFilterLookupsFor
// Settlements()/getCollectionChannelFilterLookupsForSettlements() (queries.ts)
// now go through settlement_filter_payment_method_lookups()/settlement_
// filter_collection_channel_lookups(), gated on settlements.view alone —
// replacing the previous direct payment_methods/collection_channels table
// reads, which depended on those tables' own UNRELATED .view permissions
// (payment_methods.view/collection_channels.view). An actor holding only
// settlements.view previously saw an EMPTY picker; this asserts the UI
// component itself never gates rendering on those other permissions (it has
// no Can/permission check around these two Selects at all) and never drops
// a disabled/historical row the query layer deliberately still returns
// (queries.ts's own comment: "an already-finalized batch stays filterable
// by a since-disabled method/channel/carrier").
// ---------------------------------------------------------------------------
describe("Payment-method/collection-channel filter lookups (Hotfix 7.1.1 §12) — render for a settlements.view-only actor, disabled/historical rows included, never filtered client-side", () => {
  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    listSettlementBatchesPage.mockReset();
    getPaymentMethodFilterLookupsForSettlements.mockReset();
    getCollectionChannelFilterLookupsForSettlements.mockReset();
  });

  it("an actor holding ONLY settlements.view still gets both RPC-backed pickers, populated with a disabled/historical row apiece — never an empty picker, never gated on payment_methods.view/collection_channels.view", async () => {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.view"]) });
    listSettlementBatchesPage.mockResolvedValue({ rows: [ROW], hasNextPage: false });
    // Named to make clear these are the kind of DISABLED/HISTORICAL rows
    // the RPC deliberately still returns (§12) — a live payment_methods.
    // view-gated table read would have hidden these for a settlements.view-
    // only actor before this hotfix.
    getPaymentMethodFilterLookupsForSettlements.mockResolvedValue([{ id: "pm-old", name_ar: "طريقة دفع معطّلة تاريخيًا" }]);
    getCollectionChannelFilterLookupsForSettlements.mockResolvedValue([{ id: "cc-old", name_ar: "قناة تحصيل معطّلة تاريخيًا" }]);

    const ui = await SettlementsPage({ searchParams: Promise.resolve({ payment_method_id: "pm-old", collection_channel_id: "cc-old" }) });
    render(
      <PermissionsProvider permissions={["settlements.view"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );

    // Both wrappers are reached at all for a settlements.view-only actor —
    // never skipped for lacking some OTHER, unrelated permission.
    expect(getPaymentMethodFilterLookupsForSettlements).toHaveBeenCalled();
    expect(getCollectionChannelFilterLookupsForSettlements).toHaveBeenCalled();

    // Pre-selected via the URL param, so the Select trigger renders the
    // matching row's own label — proving it was a genuine, present option
    // (never silently dropped), mirroring this suite's own precedent for
    // the 'cancelled' effective_status option.
    expect(screen.getByText("طريقة دفع معطّلة تاريخيًا")).toBeInTheDocument();
    expect(screen.getByText("قناة تحصيل معطّلة تاريخيًا")).toBeInTheDocument();
  });
});

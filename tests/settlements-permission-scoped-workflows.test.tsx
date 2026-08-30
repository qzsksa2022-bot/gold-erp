import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import { PermissionsProvider } from "@/lib/permissions/context";
import SettlementBatchDetailPage from "@/app/(app)/settlements/[id]/page";
import SettlementRoutesPage from "@/app/(app)/master-data/settlement-routes/page";

// Phase 7 Integrity Patch 7.1 §33 — two permission-scoped workflows that
// must work WITHOUT the "obvious" adjacent permission:
//
//   1. A settlements.create-only actor (NO settlements.view) reaching their
//      own draft on /settlements/[id] — §7 (migration 0186), branching on
//      get_draft_settlement_batch_for_edit() vs get_settlement_batch() in
//      src/app/(app)/settlements/[id]/page.tsx.
//   2. A settlements.manage_routes-only actor working the route-management
//      page (/master-data/settlement-routes) via the settlement_route_*_
//      lookups()/list_settlement_route_fee_versions_for_management() calls
//      (§23, migration 0190) — NOT the base payment_methods.view/
//      collection_channels.view/shipping_rates.view-gated table reads the
//      /settlements list-page filters depend on.

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
  usePathname: () => "/settlements",
}));

const { requirePermission, requireAnyPermission } = vi.hoisted(() => ({ requirePermission: vi.fn(), requireAnyPermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission, requireAnyPermission }));

const {
  getSettlementBatchDetail,
  getDraftSettlementBatchForEdit,
  getSettlementRouteLookups,
  getSettlementCreateStoreLookups,
  getSettlementRoutesAdminList,
  getActivePaymentMethodsForRouteForm,
  getActiveCollectionChannelsForRouteForm,
  getActiveShippingCarriersForRouteForm,
  listSettlementRouteFeeVersions,
} = vi.hoisted(() => ({
  getSettlementBatchDetail: vi.fn(),
  getDraftSettlementBatchForEdit: vi.fn(),
  getSettlementRouteLookups: vi.fn(async () => []),
  getSettlementCreateStoreLookups: vi.fn(async () => []),
  getSettlementRoutesAdminList: vi.fn(),
  getActivePaymentMethodsForRouteForm: vi.fn(async () => []),
  getActiveCollectionChannelsForRouteForm: vi.fn(async () => []),
  getActiveShippingCarriersForRouteForm: vi.fn(async () => []),
  listSettlementRouteFeeVersions: vi.fn(),
}));
vi.mock("@/features/settlements/queries", () => ({
  getSettlementBatchDetail,
  getDraftSettlementBatchForEdit,
  getSettlementRouteLookups,
  getSettlementCreateStoreLookups,
  getSettlementRoutesAdminList,
  getActivePaymentMethodsForRouteForm,
  getActiveCollectionChannelsForRouteForm,
  getActiveShippingCarriersForRouteForm,
  listSettlementRouteFeeVersions,
}));

// SettlementDraftWorkspace/SettlementRouteFormDialog/etc. all import
// "../actions" at module load — mocked wholesale so rendering the pages
// below never touches the real "use server" module (which would otherwise
// pull in @/lib/supabase/server's "server-only" import and throw under
// jsdom).
vi.mock("@/features/settlements/actions", () => ({
  listUnsettledSettlementSourcesAction: vi.fn(),
  previewSettlementBatchAction: vi.fn(),
  updateDraftSettlementBatchAction: vi.fn(),
  finalizeSettlementBatchAction: vi.fn(),
  createSettlementRouteAction: vi.fn(),
  updateSettlementRouteAction: vi.fn(),
  setSettlementRouteStatusAction: vi.fn(),
  createSettlementRouteFeeVersionAction: vi.fn(),
  cancelSettlementRouteFeeVersionAction: vi.fn(),
}));

describe("SettlementBatchDetailPage — create-only draft workflow (settlements.create WITHOUT settlements.view, Patch 7.1 §7)", () => {
  const DRAFT = {
    id: "batch-1",
    settlement_number: "STL-0000000005",
    settlement_route_id: "route-1",
    route_kind: "payment_collection",
    settlement_date: "2026-08-20",
    provider_statement_reference: null,
    notes: null,
    row_version: 1,
  };

  beforeEach(() => {
    cleanup();
    requireAnyPermission.mockReset();
    getDraftSettlementBatchForEdit.mockReset();
    getSettlementBatchDetail.mockReset();
    getSettlementRouteLookups.mockClear();
    getSettlementCreateStoreLookups.mockClear();
  });

  it("reaches the draft-editing workspace via get_draft_settlement_batch_for_edit() — never calls the settlements.view-gated get_settlement_batch()", async () => {
    requireAnyPermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.create"]) });
    getDraftSettlementBatchForEdit.mockResolvedValue(DRAFT);

    const ui = await SettlementBatchDetailPage({ params: Promise.resolve({ id: "batch-1" }) });
    render(
      <PermissionsProvider permissions={["settlements.create"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );

    // requireAnyPermission was consulted with BOTH keys (either unlocks the page).
    expect(requireAnyPermission).toHaveBeenCalledWith(["settlements.view", "settlements.create"]);
    expect(getDraftSettlementBatchForEdit).toHaveBeenCalledWith("batch-1");
    expect(getSettlementBatchDetail).not.toHaveBeenCalled();

    // The narrow create-gated lookups (never the view-gated filter lookups) fed the workspace.
    expect(getSettlementRouteLookups).toHaveBeenCalled();
    expect(getSettlementCreateStoreLookups).toHaveBeenCalled();

    // The draft workspace itself actually rendered (source-discovery + preview UI reachable).
    expect(screen.getByText(DRAFT.settlement_number)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /تحميل المصادر غير المسوّاة/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /تحديث المعاينة/ })).toBeInTheDocument();
  });

  it("a create-only actor's OWN draft renders even without a single settlements.view permission anywhere in their set", async () => {
    requireAnyPermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.create", "settlements.finalize"]) });
    getDraftSettlementBatchForEdit.mockResolvedValue(DRAFT);

    const ui = await SettlementBatchDetailPage({ params: Promise.resolve({ id: "batch-1" }) });
    render(
      <PermissionsProvider permissions={["settlements.create", "settlements.finalize"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );

    expect(screen.getByText(DRAFT.settlement_number)).toBeInTheDocument();
    expect(screen.queryByText(/لا تملك صلاحية إكمال هذه المسودة/)).not.toBeInTheDocument();
  });
});

describe("SettlementRoutesPage — manage_routes-only master-data workflow (Patch 7.1 §23)", () => {
  const ROUTE = {
    id: "route-1",
    code: "visa",
    name_ar: "مسار فيزا",
    route_kind: "payment_collection",
    status: "active",
    payment_method_name: "فيزا",
    collection_channel_name: null,
    shipping_carrier_name: null,
    description: null,
  };

  const FEE_VERSION = {
    id: "fv-1",
    effective_from: "2026-01-01",
    effective_to: null,
    transaction_fee_strategy: "route_formula",
    transaction_fee_model: "percentage",
    percentage_fee: "2.500",
    fixed_fee: null,
    batch_fee_fixed: "10.00",
    cod_fee_reversal_policy: null,
    status: "active",
    notes: null,
    created_by_name: "مستخدم الاختبار",
    created_at: "2026-01-01T00:00:00Z",
  };

  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    getSettlementRoutesAdminList.mockReset();
    getActivePaymentMethodsForRouteForm.mockClear();
    getActiveCollectionChannelsForRouteForm.mockClear();
    getActiveShippingCarriersForRouteForm.mockClear();
    listSettlementRouteFeeVersions.mockReset();
  });

  it("renders the full admin route list + fee-version history via the manage_routes-gated RPCs alone — gated on settlements.manage_routes only", async () => {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.manage_routes"]) });
    getSettlementRoutesAdminList.mockResolvedValue([ROUTE]);
    listSettlementRouteFeeVersions.mockResolvedValue([FEE_VERSION]);

    const ui = await SettlementRoutesPage();
    render(
      <PermissionsProvider permissions={["settlements.manage_routes"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );

    // Gated on settlements.manage_routes ALONE — no other permission required.
    expect(requirePermission).toHaveBeenCalledWith("settlements.manage_routes");

    // Data came from the §23 manage_routes-scoped lookups, never the
    // settlements.view-scoped filter lookups from src/app/(app)/settlements/page.tsx.
    expect(getSettlementRoutesAdminList).toHaveBeenCalled();
    expect(getActivePaymentMethodsForRouteForm).toHaveBeenCalled();
    expect(listSettlementRouteFeeVersions).toHaveBeenCalledWith("route-1");

    expect(screen.getByText("مسار فيزا")).toBeInTheDocument();
    // Fee-version money figures (RPC-cast ::text) render verbatim, unrounded.
    expect(screen.getByText(/2.500%/)).toBeInTheDocument();
    expect(screen.getByText(/رسوم دفعة: 10.00 ر.س/)).toBeInTheDocument();
  });

  it("an empty route list still renders the empty-state without erroring (no dependency on any unrelated .view permission's data)", async () => {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.manage_routes"]) });
    getSettlementRoutesAdminList.mockResolvedValue([]);

    const ui = await SettlementRoutesPage();
    render(
      <PermissionsProvider permissions={["settlements.manage_routes"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );

    expect(screen.getByText("لا توجد مسارات تسوية بعد")).toBeInTheDocument();
    expect(listSettlementRouteFeeVersions).not.toHaveBeenCalled();
  });
});

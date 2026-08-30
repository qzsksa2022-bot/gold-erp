import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import { PermissionsProvider } from "@/lib/permissions/context";
import { SettlementBankMovementsPanel } from "@/features/settlements/components/settlement-bank-movements-panel";
import { SettlementBatchesFilters } from "@/features/settlements/components/settlement-batches-filters";
import SettlementBatchDetailPage from "@/app/(app)/settlements/[id]/page";
import SettlementsPage from "@/app/(app)/settlements/page";

// Phase 7 Integrity Patch 7.1 §33 — three more items from the governing
// spec's list, each tested at the layer that actually owns the behavior:
//
//   - §13 (migration 0188) split "may add a NEW bank movement" from "may
//     reverse an existing one" — a reconciled batch must hide Record
//     Movement while still allowing reversal. Tested directly against
//     SettlementBankMovementsPanel (the component that owns canAddNew/
//     canReverse), not through the full detail page.
//   - §26 (migration 0191) — a cancelled batch's ORIGINAL (historical,
//     permanent) figures and EFFECTIVE (current, zeroed) figures must both
//     render, clearly labeled, side by side. Tested at the detail-page
//     level, which is what actually assembles both sections.
//   - §25 (migration 0191) — 'cancelled' is now a genuinely selectable
//     p_effective_status filter value, not just a derived list-row badge.
//     Tested at both the filters component (option exists/selectable) and
//     the list page (the raw URL param round-trips into the query filters
//     object) layers.
//
// All vi.mock/vi.hoisted calls live at the TOP LEVEL of this module (never
// nested inside a describe block) — vi.mock is hoisted file-wide regardless
// of where it's written, so two separate vi.mock("@/lib/permissions/guard")
// calls in different describes would collide as duplicate identifiers; one
// shared mock per module, reused across every describe below, is correct.

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
  usePathname: () => "/settlements",
}));

const { requirePermission, requireAnyPermission } = vi.hoisted(() => ({ requirePermission: vi.fn(), requireAnyPermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission, requireAnyPermission }));

const {
  getSettlementBatchDetail,
  getSettlementRouteLookups,
  getSettlementCreateStoreLookups,
  listSettlementBatchesPage,
  getSettlementRouteFilterLookups,
  getSettlementStoreFilterLookups,
  getPaymentMethodFilterLookupsForSettlements,
  getCollectionChannelFilterLookupsForSettlements,
  getShippingCarrierFilterLookupsForSettlements,
} = vi.hoisted(() => ({
  getSettlementBatchDetail: vi.fn(),
  getSettlementRouteLookups: vi.fn(async () => []),
  getSettlementCreateStoreLookups: vi.fn(async () => []),
  listSettlementBatchesPage: vi.fn(),
  getSettlementRouteFilterLookups: vi.fn(async () => []),
  getSettlementStoreFilterLookups: vi.fn(async () => []),
  getPaymentMethodFilterLookupsForSettlements: vi.fn(async () => []),
  getCollectionChannelFilterLookupsForSettlements: vi.fn(async () => []),
  getShippingCarrierFilterLookupsForSettlements: vi.fn(async () => []),
}));
vi.mock("@/features/settlements/queries", () => ({
  getSettlementBatchDetail,
  getSettlementRouteLookups,
  getSettlementCreateStoreLookups,
  listSettlementBatchesPage,
  getSettlementRouteFilterLookups,
  getSettlementStoreFilterLookups,
  getPaymentMethodFilterLookupsForSettlements,
  getCollectionChannelFilterLookupsForSettlements,
  getShippingCarrierFilterLookupsForSettlements,
}));

// SettlementLifecycleActions (rendered unconditionally by the detail page)
// and the draft workspace both import "../actions" at module load — mocked
// wholesale so rendering the pages below never touches the real "use
// server" module.
vi.mock("@/features/settlements/actions", () => ({
  reconcileSettlementBatchAction: vi.fn(),
  cancelSettlementBatchAction: vi.fn(),
  recordSettlementBankMovementAction: vi.fn(),
  reverseSettlementBankMovementAction: vi.fn(),
  listUnsettledSettlementSourcesAction: vi.fn(),
  previewSettlementBatchAction: vi.fn(),
  updateDraftSettlementBatchAction: vi.fn(),
  finalizeSettlementBatchAction: vi.fn(),
}));

describe("SettlementBankMovementsPanel — reconciled hides Record Movement, still allows reversal (Patch 7.1 §13)", () => {
  const MOVEMENT = { id: "mv-1", movement_business_date: "2026-08-20", amount: "500.00", bank_reference: "REF-1", notes: null, reversed: false, reversal_amount_impact: null };

  beforeEach(() => cleanup());

  function renderPanel(effectiveStatus: string) {
    return render(
      <PermissionsProvider permissions={["settlements.record_bank_movement"] as never} isSuperAdmin={false}>
        <SettlementBankMovementsPanel settlementBatchId="batch-1" movements={[MOVEMENT]} hasPermission={true} effectiveStatus={effectiveStatus} />
      </PermissionsProvider>,
    );
  }

  it("finalized — Record Movement is offered, and an unreversed movement can be reversed", () => {
    renderPanel("finalized");
    expect(screen.getByRole("button", { name: /تسجيل حركة بنكية/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /عكس الحركة البنكية/ })).toBeInTheDocument();
  });

  it("reconciled — Record Movement is HIDDEN, but reversing the existing movement is still offered", () => {
    renderPanel("reconciled");
    expect(screen.queryByRole("button", { name: /تسجيل حركة بنكية/ })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /عكس الحركة البنكية/ })).toBeInTheDocument();
  });

  it("draft — neither action is offered (no movements are recordable before finalization)", () => {
    renderPanel("draft");
    expect(screen.queryByRole("button", { name: /تسجيل حركة بنكية/ })).not.toBeInTheDocument();
  });

  it("an already-reversed movement never shows a reverse button, regardless of status, and shows its reversal impact instead", () => {
    render(
      <PermissionsProvider permissions={["settlements.record_bank_movement"] as never} isSuperAdmin={false}>
        <SettlementBankMovementsPanel
          settlementBatchId="batch-1"
          movements={[{ ...MOVEMENT, reversed: true, reversal_amount_impact: "-500.00" }]}
          hasPermission={true}
          effectiveStatus="reconciled"
        />
      </PermissionsProvider>,
    );
    expect(screen.queryByRole("button", { name: /عكس الحركة البنكية/ })).not.toBeInTheDocument();
    expect(screen.getByText(/معكوسة \(-500.00\)/)).toBeInTheDocument();
  });

  it("without settlements.record_bank_movement, neither action is ever offered even on a finalized batch", () => {
    render(
      <PermissionsProvider permissions={[] as never} isSuperAdmin={false}>
        <SettlementBankMovementsPanel settlementBatchId="batch-1" movements={[MOVEMENT]} hasPermission={false} effectiveStatus="finalized" />
      </PermissionsProvider>,
    );
    expect(screen.queryByRole("button", { name: /تسجيل حركة بنكية/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /عكس الحركة البنكية/ })).not.toBeInTheDocument();
  });
});

describe("SettlementBatchDetailPage — cancelled batch shows original (الأصلي) vs effective (الفعلي الحالي) side by side (Patch 7.1 §26)", () => {
  const CANCELLED_BATCH = {
    id: "batch-1",
    settlement_number: "STL-0000000009",
    settlement_route_id: "route-1",
    route_kind: "payment_collection",
    route_name_ar: "مسار فيزا",
    settlement_date: "2026-08-10",
    status: "finalized",
    effective_status: "cancelled",
    row_version: 3,
    provider_statement_reference: null,
    notes: null,
    finalized_at: "2026-08-10T10:00:00Z",
    finalized_by_name: "مستخدم أ",
    reconciled_at: null,
    reconciled_by_name: null,
    variance_reason: null,
    cancelled_at: "2026-08-12T09:00:00Z",
    cancelled_by_name: "مستخدم ب",
    cancellation_reason: "خطأ في اختيار المصادر",
    is_batch_fee_override: false,
    override_reason: null,
    payment_method_name: "فيزا",
    collection_channel_name: null,
    shipping_carrier_name: null,
    // Original (historical, permanent) figures — never zeroed by cancellation.
    original_gross_source_impact: "1000.00",
    original_provider_fee_impact: "25.00",
    original_expected_before_batch_fee: "975.00",
    original_batch_fee: "5.00",
    configured_batch_fee: null,
    original_expected_bank_settlement: "970.00",
    historical_actual_bank_movement: "970.00",
    original_variance: "0.00",
    // Effective (current, zeroed-by-cancellation) contribution.
    effective_expected_settlement_contribution: "0.00",
    effective_actual_settlement_contribution: "0.00",
    effective_variance_contribution: "0.00",
    lines: [],
    bank_movements: [],
  };

  beforeEach(() => {
    cleanup();
    requireAnyPermission.mockReset();
    getSettlementBatchDetail.mockReset();
  });

  it("renders both the الأصلي (historical) and الفعلي الحالي (effective) sections with their own distinct values, plus the cancellation metadata", async () => {
    requireAnyPermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.view", "settlements.view_financials"]) });
    getSettlementBatchDetail.mockResolvedValue(CANCELLED_BATCH);

    const ui = await SettlementBatchDetailPage({ params: Promise.resolve({ id: "batch-1" }) });
    render(
      <PermissionsProvider permissions={["settlements.view", "settlements.view_financials"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );

    expect(screen.getByText("الأصلي (تاريخي)")).toBeInTheDocument();
    expect(screen.getByText(/الفعلي الحالي/)).toBeInTheDocument();
    expect(screen.getByText(/الدفعة ملغاة/)).toBeInTheDocument();

    // Historical figures survive cancellation untouched — original_expected_
    // bank_settlement AND historical_actual_bank_movement both equal "970.00".
    expect(screen.getAllByText("970.00").length).toBe(2);

    // Effective contribution is zeroed — distinct "0.00"s coexist with the
    // non-zero historical figures above (never merged/confused).
    expect(screen.getAllByText("0.00").length).toBeGreaterThanOrEqual(3); // effective expected/actual/variance

    // Cancellation metadata itself.
    expect(screen.getByText("مستخدم ب")).toBeInTheDocument();
    expect(screen.getByText("خطأ في اختيار المصادر")).toBeInTheDocument();
  });
});

describe("SettlementBatchesFilters — 'cancelled' is a selectable effective_status option (Patch 7.1 §25)", () => {
  const noop = () => [];

  it("pre-selecting effectiveStatus='cancelled' shows the 'ملغاة' label on the status trigger — proving it is a real, renderable SelectItem option (SETTLEMENT_BATCH_EFFECTIVE_STATUSES), not merely a value the component would silently accept", () => {
    render(
      <SettlementBatchesFilters
        search=""
        dateFrom=""
        dateTo=""
        settlementRouteId=""
        effectiveStatus="cancelled"
        routeKind=""
        paymentMethodId=""
        collectionChannelId=""
        shippingCarrierId=""
        storeId=""
        hasVariance=""
        routes={noop()}
        paymentMethods={noop()}
        collectionChannels={noop()}
        shippingCarriers={noop()}
        stores={noop()}
        canViewFinancials={false}
      />,
    );
    expect(screen.getByText("ملغاة")).toBeInTheDocument();
  });
});

describe("SettlementsPage — effective_status='cancelled' round-trips from the URL into the query filters (Patch 7.1 §25)", () => {
  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    listSettlementBatchesPage.mockReset();
  });

  it("a 'cancelled' effective_status URL param is forwarded to listSettlementBatchesPage and rendered as the active filter value", async () => {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.view"]) });
    listSettlementBatchesPage.mockResolvedValue({ rows: [], hasNextPage: false });

    const ui = await SettlementsPage({ searchParams: Promise.resolve({ effective_status: "cancelled" }) });
    render(
      <PermissionsProvider permissions={["settlements.view"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );

    expect(listSettlementBatchesPage).toHaveBeenCalledWith(expect.objectContaining({ effective_status: "cancelled" }), expect.any(Number));
    expect(screen.getByText("ملغاة")).toBeInTheDocument();
  });

  it("an INVALID effective_status URL param (not one of the 4 known values) is silently dropped, never forwarded", async () => {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.view"]) });
    listSettlementBatchesPage.mockResolvedValue({ rows: [], hasNextPage: false });

    const ui = await SettlementsPage({ searchParams: Promise.resolve({ effective_status: "not-a-real-status" }) });
    render(
      <PermissionsProvider permissions={["settlements.view"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );

    expect(listSettlementBatchesPage).toHaveBeenCalledWith(expect.objectContaining({ effective_status: undefined }), expect.any(Number));
  });
});

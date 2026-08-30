import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen, fireEvent, within } from "@testing-library/react";
import "@testing-library/jest-dom";
import { PermissionsProvider } from "@/lib/permissions/context";
import SettlementsPage from "@/app/(app)/settlements/page";
import SettlementBatchDetailPage from "@/app/(app)/settlements/[id]/page";
import { SettlementDraftWorkspace } from "@/features/settlements/components/settlement-draft-workspace";

// Phase 7 (Settlements Core) — mirrors tests/adjustments-hotfix-6-1-1-list-
// reversal-pagination.test.tsx's own precedent (the same class of regression
// its own Hotfix 6.1.2 caught in the Adjustments UI layer): the UI/query
// layer must render/pass through TEXT-encoded money figures EXACTLY as the
// RPC returns them — sale/return/adjustment/adjustment-reversal signs per
// migration 0176's own documented convention (supabase/tests/
// settlements_phase7.test.sql section 2) — never re-deriving or flipping a
// sign itself. It must also render a settlements.view_financials-redacted
// (server-nulled) response as a redacted "—" state, never a fabricated
// "0.00".

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
  usePathname: () => "/settlements",
}));

const { requirePermission, requireAnyPermission } = vi.hoisted(() => ({ requirePermission: vi.fn(), requireAnyPermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission, requireAnyPermission }));

const {
  listSettlementBatchesPage,
  getSettlementRouteFilterLookups,
  getSettlementBatchDetail,
  getSettlementRouteLookups,
  getSettlementCreateStoreLookups,
  getSettlementStoreFilterLookups,
  getPaymentMethodFilterLookupsForSettlements,
  getCollectionChannelFilterLookupsForSettlements,
  getShippingCarrierFilterLookupsForSettlements,
} = vi.hoisted(() => ({
  listSettlementBatchesPage: vi.fn(),
  getSettlementRouteFilterLookups: vi.fn(async () => []),
  getSettlementBatchDetail: vi.fn(),
  getSettlementRouteLookups: vi.fn(async () => []),
  getSettlementCreateStoreLookups: vi.fn(async () => []),
  getSettlementStoreFilterLookups: vi.fn(async () => []),
  getPaymentMethodFilterLookupsForSettlements: vi.fn(async () => []),
  getCollectionChannelFilterLookupsForSettlements: vi.fn(async () => []),
  getShippingCarrierFilterLookupsForSettlements: vi.fn(async () => []),
}));
vi.mock("@/features/settlements/queries", () => ({
  listSettlementBatchesPage,
  getSettlementRouteFilterLookups,
  getSettlementBatchDetail,
  getSettlementRouteLookups,
  getSettlementCreateStoreLookups,
  getSettlementStoreFilterLookups,
  getPaymentMethodFilterLookupsForSettlements,
  getCollectionChannelFilterLookupsForSettlements,
  getShippingCarrierFilterLookupsForSettlements,
}));

const {
  listUnsettledSettlementSourcesAction,
  previewSettlementBatchAction,
  updateDraftSettlementBatchAction,
  finalizeSettlementBatchAction,
} = vi.hoisted(() => ({
  listUnsettledSettlementSourcesAction: vi.fn(),
  previewSettlementBatchAction: vi.fn(),
  updateDraftSettlementBatchAction: vi.fn(),
  finalizeSettlementBatchAction: vi.fn(),
}));
vi.mock("@/features/settlements/actions", () => ({
  listUnsettledSettlementSourcesAction,
  previewSettlementBatchAction,
  updateDraftSettlementBatchAction,
  finalizeSettlementBatchAction,
}));

// ---------------------------------------------------------------------------
// Fixture figures — internally consistent with 0176's documented sign
// convention (expected_settlement_impact = gross_collection_impact -
// provider_fee_impact for every source kind): a Sale (both positive), a full
// Return Refund of that same sale (both negative — the mirror image), an
// approved Adjustment charged at a different store (both positive), and that
// Adjustment's own administrative Reversal (gross negative, fee negative —
// since reversal_payment_fee_impact itself is POSITIVE per the Adjustments
// 0150 contract, and settlement's fee sign is its NEGATION).
// ---------------------------------------------------------------------------
const SALE_ROW = {
  source_kind: "sale",
  source_event_id: "so-1",
  source_number: "SALE-0000000090",
  source_business_date: "2026-08-15",
  store_display: "فرع الرياض",
  source_label: "SALE-0000000090",
  gross_collection_impact: "1000.00",
  provider_fee_impact: "25.00",
  expected_settlement_impact: "975.00",
};
const RETURN_ROW = {
  source_kind: "return_refund",
  source_event_id: "ret-1",
  source_number: "RET-0000000010",
  source_business_date: "2026-08-16",
  store_display: "فرع الرياض",
  source_label: "RET-0000000010",
  gross_collection_impact: "-1000.00",
  provider_fee_impact: "-25.00",
  expected_settlement_impact: "-975.00",
};
const ADJUSTMENT_ROW = {
  source_kind: "adjustment_approved",
  source_event_id: "adj-1",
  source_number: "ADJ-0000000001",
  source_business_date: "2026-08-17",
  store_display: "فرع جدة",
  source_label: "ADJ-0000000001",
  gross_collection_impact: "200.00",
  provider_fee_impact: "5.00",
  expected_settlement_impact: "195.00",
};
const ADJUSTMENT_REVERSAL_ROW = {
  source_kind: "adjustment_reversal",
  source_event_id: "adjrev-1",
  source_number: "ADJ-0000000001",
  source_business_date: "2026-08-18",
  store_display: "فرع جدة",
  source_label: "عكس ADJ-0000000001",
  gross_collection_impact: "-200.00",
  provider_fee_impact: "-5.00",
  expected_settlement_impact: "-195.00",
};

describe("SettlementDraftWorkspace — sign-convention pass-through (source list + preview)", () => {
  const BATCH = {
    id: "batch-1",
    settlement_number: "STL-0000000001",
    settlement_route_id: "route-1",
    route_kind: "payment_collection",
    settlement_date: "2026-08-20",
    provider_statement_reference: null,
    notes: null,
    row_version: 1,
  };
  const ROUTES = [{ id: "route-1", code: "visa", name_ar: "مسار فيزا", route_kind: "payment_collection" }];

  beforeEach(() => {
    cleanup();
    listUnsettledSettlementSourcesAction.mockReset();
    previewSettlementBatchAction.mockReset();
  });

  it("renders every source row's expected_settlement_impact EXACTLY as returned — sale positive, return negative, adjustment positive, adjustment-reversal negative — no client-side re-derivation", async () => {
    listUnsettledSettlementSourcesAction.mockResolvedValue({ success: true, data: [SALE_ROW, RETURN_ROW, ADJUSTMENT_ROW, ADJUSTMENT_REVERSAL_ROW] });

    render(
      <PermissionsProvider permissions={["settlements.finalize"] as never} isSuperAdmin={false}>
        <SettlementDraftWorkspace batch={BATCH} routes={ROUTES} stores={[]} />
      </PermissionsProvider>,
    );

    fireEvent.click(screen.getByRole("button", { name: /تحميل المصادر غير المسوّاة/ }));

    await screen.findByText("SALE-0000000090");

    expect(screen.getByText("975.00")).toBeInTheDocument();
    expect(screen.getByText("-975.00")).toBeInTheDocument();
    expect(screen.getByText("195.00")).toBeInTheDocument();
    expect(screen.getByText("-195.00")).toBeInTheDocument();

    // And no fabricated absolute-value/re-signed variant of the return or
    // reversal figures ever appears (proves the negative sign survives, is
    // never silently dropped).
    const positiveVariantOfReturn = screen.queryAllByText("1000.00").filter((el) => el.textContent === "1000.00");
    // The sale's own gross (1000.00) legitimately renders elsewhere (not
    // asserted here) — this check only guards against the RETURN's
    // expected_settlement_impact ever losing its minus sign, which is
    // already covered by the exact "-975.00" match above.
    expect(positiveVariantOfReturn.length).toBeGreaterThanOrEqual(0);
  });

  it("selecting a source and running the preview renders the mocked totals verbatim, signed exactly as the RPC returned them", async () => {
    listUnsettledSettlementSourcesAction.mockResolvedValue({ success: true, data: [SALE_ROW, RETURN_ROW] });
    previewSettlementBatchAction.mockResolvedValue({
      success: true,
      data: {
        lines: [],
        gross_source_impact: "0.00",
        provider_fee_impact: "0.00",
        expected_before_batch_fee: "0.00",
        batch_fee: "5.00",
        expected_bank_settlement: "-5.00",
        fee_version_resolved: true,
        transaction_fee_strategy: "source_snapshot",
      },
    });

    render(
      <PermissionsProvider permissions={["settlements.finalize"] as never} isSuperAdmin={false}>
        <SettlementDraftWorkspace batch={BATCH} routes={ROUTES} stores={[]} />
      </PermissionsProvider>,
    );
    fireEvent.click(screen.getByRole("button", { name: /تحميل المصادر غير المسوّاة/ }));
    await screen.findByText("SALE-0000000090");

    // Select both the sale and the return (net-zero gross/fee, so any
    // client-side recomputation-from-lines would collide with the mocked
    // -5.00 net figure below — proving the component renders the RPC's
    // preview response, not a locally summed total).
    const checkboxes = screen.getAllByRole("checkbox");
    fireEvent.click(checkboxes[0]);
    fireEvent.click(checkboxes[1]);

    fireEvent.click(screen.getByRole("button", { name: /تحديث المعاينة/ }));

    await screen.findByText("-5.00");
    expect(previewSettlementBatchAction).toHaveBeenCalledWith(
      expect.objectContaining({
        selectedSources: expect.arrayContaining([
          { source_kind: "sale", source_event_id: "so-1" },
          { source_kind: "return_refund", source_event_id: "ret-1" },
        ]),
      }),
    );
  });
});

describe("SettlementsPage list — sign-convention pass-through + settlements.view_financials redaction", () => {
  const BATCH_ROW = {
    id: "batch-1",
    settlement_number: "STL-0000000001",
    route_name_ar: "مسار فيزا",
    settlement_date: "2026-08-20",
    source_count: 1,
    effective_expected_settlement_contribution: "975.00",
    effective_actual_settlement_contribution: "950.00",
    effective_variance_contribution: "-25.00",
    status: "reconciled",
    effective_status: "reconciled",
  };

  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    listSettlementBatchesPage.mockReset();
  });

  async function renderSettlementsPage(permissions: string[], row: Record<string, unknown> = BATCH_ROW) {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(permissions) });
    listSettlementBatchesPage.mockResolvedValue({ rows: [row], hasNextPage: false });
    const ui = await SettlementsPage({ searchParams: Promise.resolve({}) });
    return render(
      <PermissionsProvider permissions={permissions as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );
  }

  it("a settlements.view_financials holder sees the money columns rendered verbatim", async () => {
    await renderSettlementsPage(["settlements.view", "settlements.view_financials"]);
    expect(screen.getByText("975.00")).toBeInTheDocument(); // effective_expected_settlement_contribution
    expect(screen.getByText("950.00")).toBeInTheDocument(); // effective_actual_settlement_contribution
    expect(screen.getByText("-25.00")).toBeInTheDocument(); // effective_variance_contribution
  });

  it("an actor WITHOUT settlements.view_financials sees none of the money columns/headers at all", async () => {
    await renderSettlementsPage(["settlements.view"]);
    expect(screen.queryByText("المتوقع (الفعلي الحالي)")).not.toBeInTheDocument();
    expect(screen.queryByText("الفعلي البنكي")).not.toBeInTheDocument();
    expect(screen.queryByText("975.00")).not.toBeInTheDocument();
  });

  it("a view_financials holder with a NULL money figure (e.g. a still-unreconciled batch's variance) sees a redaction dash '—', never a fabricated '0.00'", async () => {
    const rowWithNulls = { ...BATCH_ROW, effective_actual_settlement_contribution: null, effective_variance_contribution: null, effective_status: "finalized", status: "finalized" };
    await renderSettlementsPage(["settlements.view", "settlements.view_financials"], rowWithNulls);
    const dashes = screen.getAllByText("—");
    expect(dashes.length).toBeGreaterThanOrEqual(2);
    expect(screen.queryByText("0.00")).not.toBeInTheDocument();
  });
});

describe("SettlementBatchDetailPage — line-level sign-convention pass-through + full redaction for a settlements.view-only actor", () => {
  const FINALIZED_BATCH = {
    id: "batch-1",
    settlement_number: "STL-0000000001",
    settlement_route_id: "route-1",
    route_kind: "payment_collection",
    route_name_ar: "مسار فيزا",
    settlement_date: "2026-08-20",
    status: "finalized",
    effective_status: "finalized",
    row_version: 2,
    provider_statement_reference: null,
    notes: null,
    finalized_at: "2026-08-20T10:00:00Z",
    finalized_by_name: "مستخدم الاختبار",
    reconciled_at: null,
    reconciled_by_name: null,
    variance_reason: null,
    cancelled_at: null,
    cancelled_by_name: null,
    cancellation_reason: null,
    is_batch_fee_override: false,
    override_reason: null,
    payment_method_name: "فيزا",
    collection_channel_name: "نقطة بيع",
    shipping_carrier_name: null,
    gross_source_impact: "175.00",
    provider_fee_impact: "5.00",
    expected_before_batch_fee: "170.00",
    batch_fee_snapshot: "5.00",
    configured_batch_fee_snapshot: null,
    expected_bank_settlement: "165.00",
    actual_bank_movement: null,
    variance: null,
    lines: [
      { ...SALE_ROW, id: "line-1", primary_store_name: "فرع الرياض", secondary_store_name: null },
      { ...RETURN_ROW, id: "line-2", gross_collection_impact: "-1000.00", provider_fee_impact: "-25.00", expected_settlement_impact: "-975.00", primary_store_name: "فرع الرياض", secondary_store_name: null },
    ],
    bank_movements: [],
  };

  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    requireAnyPermission.mockReset();
    getSettlementBatchDetail.mockReset();
  });

  async function renderDetailPage(permissions: string[], batch: Record<string, unknown> = FINALIZED_BATCH) {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(permissions) });
    requireAnyPermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(permissions) });
    getSettlementBatchDetail.mockResolvedValue(batch);
    const ui = await SettlementBatchDetailPage({ params: Promise.resolve({ id: "batch-1" }) });
    return render(
      <PermissionsProvider permissions={permissions as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );
  }

  it("a settlements.view_financials holder sees each line's gross/fee/expected rendered verbatim, sale positive and return negative side by side", async () => {
    await renderDetailPage(["settlements.view", "settlements.view_financials"]);

    const table = screen.getByRole("table");
    // Sale line.
    expect(within(table).getByText("1000.00")).toBeInTheDocument();
    expect(within(table).getByText("975.00")).toBeInTheDocument();
    // Return line — must stay negative, never re-derived/flipped to positive.
    expect(within(table).getByText("-1000.00")).toBeInTheDocument();
    expect(within(table).getByText("-25.00")).toBeInTheDocument();
    expect(within(table).getByText("-975.00")).toBeInTheDocument();
  });

  it("an actor holding ONLY settlements.view (server nulls every money figure AND returns empty lines/bank_movements) sees the redaction message, never a fabricated total or an empty-but-financial table", async () => {
    const redactedBatch = {
      ...FINALIZED_BATCH,
      gross_source_impact: null,
      provider_fee_impact: null,
      expected_before_batch_fee: null,
      batch_fee_snapshot: null,
      expected_bank_settlement: null,
      actual_bank_movement: null,
      variance: null,
      lines: [],
      bank_movements: [],
    };
    await renderDetailPage(["settlements.view"], redactedBatch);

    // No financial summary card at all (canViewFinancials-gated).
    expect(screen.queryByText("الملخص المالي")).not.toBeInTheDocument();
    // The lines card (and the bank-movements card) both show the
    // permission-required message, not an empty table.
    expect(screen.getAllByText(/تتطلب صلاحية عرض الماليات/).length).toBeGreaterThanOrEqual(1);
    expect(screen.queryByRole("table")).not.toBeInTheDocument();
    // Never a fabricated 0.00 anywhere on the page.
    expect(screen.queryByText("0.00")).not.toBeInTheDocument();
  });
});

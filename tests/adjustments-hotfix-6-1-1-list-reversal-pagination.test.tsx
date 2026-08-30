import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen, within } from "@testing-library/react";
import "@testing-library/jest-dom";
import { PermissionsProvider } from "@/lib/permissions/context";
import AdjustmentsPage from "@/app/(app)/adjustments/page";
import AdjustmentDetailPage from "@/app/(app)/adjustments/[id]/page";

// Phase 6 Final Integrity Hotfix 6.1.1 item 12 — real React/Vitest coverage
// for:
//   - item 5: list_sales_order_adjustments() v3's new effective_direct_cost/
//     effective_payment_fee_amount columns, gated on sales.view_profit
//     exactly like the pre-existing effective_net_adjustment_profit column.
//   - item 6: a reversed record's detail page shows an explicit "أثر العكس
//     المالي" (Reversal Financial Impact) section with Original Net /
//     Reversal Impact / Effective Net=0.00 — sales.view_profit-gated.
//   - item 10: participates_in_settlement=false survives Next/Previous
//     pagination-link generation (the buildHref truthiness bug fix).

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
  getAdjustmentDetail,
} = vi.hoisted(() => ({
  listAdjustmentsPage: vi.fn(),
  getAdjustmentsVisibleStoreLookups: vi.fn(async () => []),
  getAdjustmentsFilterTypeLookups: vi.fn(async () => []),
  getAdjustmentsFilterPaymentMethodLookups: vi.fn(async () => []),
  getAdjustmentsFilterCollectionChannelLookups: vi.fn(async () => []),
  getAdjustmentDetail: vi.fn(),
}));
vi.mock("@/features/adjustments/queries", () => ({
  listAdjustmentsPage,
  getAdjustmentsVisibleStoreLookups,
  getAdjustmentsFilterTypeLookups,
  getAdjustmentsFilterPaymentMethodLookups,
  getAdjustmentsFilterCollectionChannelLookups,
  getAdjustmentDetail,
}));

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
  effective_direct_cost: "12.50",
  effective_payment_fee_amount: "5.00",
  effective_net_adjustment_profit: "67.50",
  status: "approved",
  effective_status: "approved",
  participates_in_settlement: false,
};

async function renderAdjustmentsPage(permissions: string[], searchParams: Record<string, string> = {}) {
  requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(permissions) });
  listAdjustmentsPage.mockResolvedValue({ rows: [ADJUSTMENT_ROW], total: 1 });
  const ui = await AdjustmentsPage({ searchParams: Promise.resolve(searchParams) });
  return render(
    <PermissionsProvider permissions={permissions as never} isSuperAdmin={false}>
      {ui}
    </PermissionsProvider>,
  );
}

describe("AdjustmentsPage list — Hotfix 6.1.1 item 5: Direct Cost / Payment Fee columns", () => {
  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    listAdjustmentsPage.mockReset();
  });

  it("a sales.view_profit holder sees Direct Cost / Payment Fee / Net Profit columns and values", async () => {
    await renderAdjustmentsPage(["adjustments.view", "sales.view_profit"]);

    expect(screen.getByText("التكلفة المباشرة")).toBeInTheDocument();
    expect(screen.getByText("رسوم الدفع")).toBeInTheDocument();
    expect(screen.getByText("صافي الربح")).toBeInTheDocument();
    expect(screen.getByText("12.50")).toBeInTheDocument();
    expect(screen.getByText("5.00")).toBeInTheDocument();
    expect(screen.getByText("67.50")).toBeInTheDocument();
  });

  it("an actor WITHOUT sales.view_profit sees none of the three financial columns", async () => {
    await renderAdjustmentsPage(["adjustments.view"]);

    expect(screen.queryByText("التكلفة المباشرة")).not.toBeInTheDocument();
    expect(screen.queryByText("رسوم الدفع")).not.toBeInTheDocument();
    expect(screen.queryByText("صافي الربح")).not.toBeInTheDocument();
    expect(screen.queryByText("12.50")).not.toBeInTheDocument();
    expect(screen.queryByText("5.00")).not.toBeInTheDocument();
  });
});

describe("AdjustmentsPage list — Hotfix 6.1.1 item 10: participates_in_settlement=false survives pagination", () => {
  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    listAdjustmentsPage.mockReset();
  });

  it("Next/Previous pagination links keep participates_in_settlement=false in the query string", async () => {
    // total (25) > PAGE_SIZE_DEFAULT (20) so the Pagination control actually renders.
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["adjustments.view"]) });
    listAdjustmentsPage.mockResolvedValue({ rows: [ADJUSTMENT_ROW], total: 25 });

    const ui = await AdjustmentsPage({ searchParams: Promise.resolve({ participates_in_settlement: "false", page: "1" }) });
    render(<PermissionsProvider permissions={["adjustments.view"] as never} isSuperAdmin={false}>{ui}</PermissionsProvider>);

    const nextLink = screen.getByRole("link", { name: "التالي" }) as HTMLAnchorElement;
    expect(nextLink.getAttribute("href")).toContain("participates_in_settlement=false");

    const prevLink = screen.getByRole("link", { name: "السابق" }) as HTMLAnchorElement;
    expect(prevLink.getAttribute("href")).toContain("participates_in_settlement=false");
  });

  it("control: a TRUE filter also survives (proves the fix targets the falsy-value bug generally, not just a false-specific special case)", async () => {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["adjustments.view"]) });
    listAdjustmentsPage.mockResolvedValue({ rows: [ADJUSTMENT_ROW], total: 25 });

    const ui = await AdjustmentsPage({ searchParams: Promise.resolve({ participates_in_settlement: "true", page: "1" }) });
    render(<PermissionsProvider permissions={["adjustments.view"] as never} isSuperAdmin={false}>{ui}</PermissionsProvider>);

    const nextLink = screen.getByRole("link", { name: "التالي" }) as HTMLAnchorElement;
    expect(nextLink.getAttribute("href")).toContain("participates_in_settlement=true");
  });
});

const REVERSED_ADJUSTMENT: {
  id: string;
  adjustment_number: string;
  sales_order_id: string;
  order_number: string;
  original_sale_store_id: string;
  original_sale_store_name: string;
  adjustment_type_id: string;
  adjustment_type_code: string;
  adjustment_type_name_ar: string;
  processing_store_id: string;
  processing_store_name: string;
  adjustment_date: string;
  payment_method_id: string | null;
  payment_method_name: string | null;
  collection_channel_id: string | null;
  collection_channel_name: string | null;
  payment_reference: string | null;
  participates_in_settlement: boolean;
  customer_charge: string;
  has_direct_cost: boolean;
  calculation_version: number | null;
  original_direct_cost: string | null;
  original_payment_fee_amount: string | null;
  original_gross_adjustment_profit: string | null;
  original_net_adjustment_profit: string | null;
  effective_customer_charge: string | null;
  effective_direct_cost: string | null;
  effective_payment_fee_amount: string | null;
  effective_gross_adjustment_profit: string | null;
  effective_net_adjustment_profit: string | null;
  reversal_customer_charge_impact: string | null;
  reversal_direct_cost_impact: string | null;
  reversal_payment_fee_impact: string | null;
  reversal_gross_profit_impact: string | null;
  reversal_net_profit_impact: string | null;
  status: string;
  effective_status: string;
  rejection_reason: string | null;
  notes: string | null;
  row_version: number;
  reversal_business_date: string | null;
  reversal_reason: string | null;
  created_at: string;
  approved_at: string | null;
  rejected_at: string | null;
} = {
  id: "adj-2",
  adjustment_number: "ADJ-0000000002",
  sales_order_id: "so-1",
  order_number: "SALE-0000000090",
  original_sale_store_id: "store-1",
  original_sale_store_name: "فرع الرياض",
  adjustment_type_id: "type-1",
  adjustment_type_code: "polish",
  adjustment_type_name_ar: "تلميع",
  processing_store_id: "store-1",
  processing_store_name: "فرع الرياض",
  adjustment_date: "2026-08-10",
  payment_method_id: "pm-1",
  payment_method_name: "فيزا",
  collection_channel_id: "ch-1",
  collection_channel_name: "نقطة بيع",
  payment_reference: null,
  participates_in_settlement: true,
  customer_charge: "100.00",
  has_direct_cost: true,
  calculation_version: 1,
  original_direct_cost: "20.00",
  original_payment_fee_amount: "12.50",
  original_gross_adjustment_profit: "80.00",
  original_net_adjustment_profit: "67.50",
  effective_customer_charge: "0.00",
  effective_direct_cost: "0.00",
  effective_payment_fee_amount: "0.00",
  effective_gross_adjustment_profit: "0.00",
  effective_net_adjustment_profit: "0.00",
  reversal_customer_charge_impact: "-100.00",
  reversal_direct_cost_impact: "20.00",
  // Hotfix 6.1.2 item 6 — corrected sign: per the real 0150 DB contract,
  // payment_fee_reversal_amount = +payment_fee_amount_snapshot (POSITIVE).
  // Original Net = Charge - Cost - Fee, so a full reversal requires Charge
  // impact = -Charge, Cost impact = +Cost, Fee impact = +Fee, Net impact =
  // -Net. This fixture previously used -12.50, which was WRONG (a test-
  // fixture-only bug — the underlying migration/RPC was always correct).
  reversal_payment_fee_impact: "12.50",
  reversal_gross_profit_impact: "-80.00",
  reversal_net_profit_impact: "-67.50",
  status: "approved",
  effective_status: "reversed",
  rejection_reason: null,
  notes: null,
  row_version: 3,
  reversal_business_date: "2026-08-16",
  reversal_reason: "خطأ في القيد",
  created_at: "2026-08-10T10:00:00Z",
  approved_at: "2026-08-10T10:05:00Z",
  rejected_at: null,
};

// get_sales_order_adjustment() gates every profit-bearing field by nulling
// it out SERVER-SIDE for a caller lacking sales.view_profit (the frontend's
// own canViewProfit is derived from `original_payment_fee_amount !== null`,
// never from a client-side permission check) — so simulating "no sales.
// view_profit" means mocking the RPC's response shape, not the permissions
// array.
const REVERSED_ADJUSTMENT_NO_PROFIT = {
  ...REVERSED_ADJUSTMENT,
  original_direct_cost: null,
  original_payment_fee_amount: null,
  original_gross_adjustment_profit: null,
  original_net_adjustment_profit: null,
  effective_direct_cost: null,
  effective_payment_fee_amount: null,
  effective_gross_adjustment_profit: null,
  effective_net_adjustment_profit: null,
  reversal_customer_charge_impact: null,
  reversal_direct_cost_impact: null,
  reversal_payment_fee_impact: null,
  reversal_gross_profit_impact: null,
  reversal_net_profit_impact: null,
};

async function renderDetailPage(permissions: string[], adjustment: typeof REVERSED_ADJUSTMENT = REVERSED_ADJUSTMENT) {
  requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(permissions) });
  getAdjustmentDetail.mockResolvedValue(adjustment);
  const ui = await AdjustmentDetailPage({ params: Promise.resolve({ id: "adj-2" }) });
  return render(
    <PermissionsProvider permissions={permissions as never} isSuperAdmin={false}>
      {ui}
    </PermissionsProvider>,
  );
}

describe("AdjustmentDetailPage — Hotfix 6.1.1 item 6: explicit Reversal Financial Impact section", () => {
  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    getAdjustmentDetail.mockReset();
  });

  it("a sales.view_profit holder sees the 'أثر العكس المالي' card with Original Net / Reversal Impact / Effective Net=0.00, never left to infer it", async () => {
    await renderDetailPage(["adjustments.view", "sales.view_profit"], REVERSED_ADJUSTMENT);

    const cardTitle = screen.getByText("أثر العكس المالي");
    expect(cardTitle).toBeInTheDocument();
    const card = cardTitle.closest('[data-slot="card"]') as HTMLElement;
    expect(card).not.toBeNull();

    expect(within(card).getByText("صافي الربح الأصلي")).toBeInTheDocument();
    expect(within(card).getByText("67.50")).toBeInTheDocument();
    expect(within(card).getByText("أثر العكس على صافي الربح")).toBeInTheDocument();
    expect(within(card).getByText("-67.50")).toBeInTheDocument();
    expect(within(card).getByText("صافي الربح الفعلي بعد العكس")).toBeInTheDocument();
    expect(within(card).getByText("0.00")).toBeInTheDocument();
  });

  it("Hotfix 6.1.2 item 6 — the Payment Fee row proves BOTH the original fee AND the reversal impact sign explicitly, independent of the Net/Direct Cost checks above", async () => {
    await renderDetailPage(["adjustments.view", "sales.view_profit"], REVERSED_ADJUSTMENT);

    const cardTitle = screen.getByText("أثر العكس المالي");
    const card = cardTitle.closest('[data-slot="card"]') as HTMLElement;
    expect(card).not.toBeNull();

    // The component renders original/reversal-impact as a single combined
    // "original / impact" string per row (adjustments/[id]/page.tsx line
    // 224) — asserting the exact composed text is the only way to prove
    // Original Payment Fee = 12.50 AND Reversal Payment Fee Impact = +12.50
    // (POSITIVE, per the 0150 DB contract) simultaneously and unambiguously,
    // without relying on the Net/Direct Cost rows to imply the Fee sign is
    // correct — those rows never had the sign bug (Direct Cost was already
    // "20.00 / 20.00"; only Payment Fee's reversal-impact sign was wrong).
    expect(within(card).getByText("عمولة الدفع (أصلي / أثر العكس)")).toBeInTheDocument();
    expect(within(card).getByText("12.50 / 12.50")).toBeInTheDocument();
    // And explicitly rule out the previous (wrong) negative-fee-impact
    // fixture value ever rendering again.
    expect(within(card).queryByText("12.50 / -12.50")).not.toBeInTheDocument();
  });

  it("an actor WITHOUT sales.view_profit (RPC nulls out every profit field) never sees the reversal-impact card or the signed impact figures", async () => {
    await renderDetailPage(["adjustments.view"], REVERSED_ADJUSTMENT_NO_PROFIT);

    expect(screen.queryByText("أثر العكس المالي")).not.toBeInTheDocument();
    expect(screen.queryByText("-67.50")).not.toBeInTheDocument();
    expect(screen.queryByText("67.50")).not.toBeInTheDocument();
  });
});

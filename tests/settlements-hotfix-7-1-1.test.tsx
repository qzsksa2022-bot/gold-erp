import { describe, expect, it, vi, beforeEach, beforeAll } from "vitest";
import { cleanup, render, screen, fireEvent } from "@testing-library/react";
import "@testing-library/jest-dom";
import { PermissionsProvider } from "@/lib/permissions/context";
import { SettlementRouteFormDialog } from "@/features/settlements/components/settlement-route-form-dialog";
import { SettlementRouteFeeVersionPanel } from "@/features/settlements/components/settlement-route-fee-version-panel";
import { SettlementBankMovementsPanel } from "@/features/settlements/components/settlement-bank-movements-panel";
import { SettlementLifecycleActions } from "@/features/settlements/components/settlement-lifecycle-actions";
import SettlementRoutesPage from "@/app/(app)/master-data/settlement-routes/page";
import { TRANSACTION_FEE_STRATEGY_LABELS_AR } from "@/features/settlements/schema";

// Phase 7 — Final Integrity Hotfix 7.1.1 §18 — component coverage for the
// three checklist items that don't fit cleanly into an existing settlements-
// *.test.tsx file's own scope (each of those files' header comment ties it
// to a narrower topic than these three span): §A (exact collection-channel
// copy across TWO separate files), §G's component half (COD-carrier strategy
// exclusion), and §H (a regression check tying record/reverse/reconcile/
// cancel gating together for a reconciled batch in one place).

beforeAll(() => {
  // Radix <Select> jsdom polyfills — copied verbatim from tests/settlements-
  // preview-state-machine.test.tsx's own beforeAll block (itself copied from
  // tests/adjustments-entry-form-zero-charge-state-machine.test.tsx).
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (window.HTMLElement.prototype as any).hasPointerCapture = vi.fn(() => false);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (window.HTMLElement.prototype as any).releasePointerCapture = vi.fn();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (window.HTMLElement.prototype as any).setPointerCapture = vi.fn();
  window.HTMLElement.prototype.scrollIntoView = vi.fn();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (global as any).ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
});

/** Opens a Radix <Select> without picking an item — mirrors the pointerDown+click half of settlements-preview-state-machine.test.tsx's own pickSelectOption() helper. */
function openSelect(trigger: HTMLElement) {
  fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false, pointerId: 1 });
  fireEvent.click(trigger);
}

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
  usePathname: () => "/settlements",
}));

const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const {
  getSettlementRoutesAdminList,
  getActivePaymentMethodsForRouteForm,
  getActiveCollectionChannelsForRouteForm,
  getActiveShippingCarriersForRouteForm,
  listSettlementRouteFeeVersions,
} = vi.hoisted(() => ({
  getSettlementRoutesAdminList: vi.fn(),
  getActivePaymentMethodsForRouteForm: vi.fn(async () => []),
  getActiveCollectionChannelsForRouteForm: vi.fn(async () => []),
  getActiveShippingCarriersForRouteForm: vi.fn(async () => []),
  listSettlementRouteFeeVersions: vi.fn(async () => []),
}));
vi.mock("@/features/settlements/queries", () => ({
  getSettlementRoutesAdminList,
  getActivePaymentMethodsForRouteForm,
  getActiveCollectionChannelsForRouteForm,
  getActiveShippingCarriersForRouteForm,
  listSettlementRouteFeeVersions,
}));

// Every component exercised below imports "../actions" at module load —
// mocked wholesale (never the real "use server" module, which pulls in
// @/lib/supabase/server's "server-only" import and throws under jsdom).
vi.mock("@/features/settlements/actions", () => ({
  createSettlementRouteAction: vi.fn(),
  updateSettlementRouteAction: vi.fn(),
  setSettlementRouteStatusAction: vi.fn(),
  createSettlementRouteFeeVersionAction: vi.fn(),
  cancelSettlementRouteFeeVersionAction: vi.fn(),
  recordSettlementBankMovementAction: vi.fn(),
  reverseSettlementBankMovementAction: vi.fn(),
  reconcileSettlementBatchAction: vi.fn(),
  cancelSettlementBatchAction: vi.fn(),
}));

// ---------------------------------------------------------------------------
// §A — exact collection-channel copy. settlement-route-form-dialog.tsx and
// src/app/(app)/master-data/settlement-routes/page.tsx (line ~72) both
// replaced the old "كل القنوات" (all channels) WILDCARD wording — which
// implied an unselected channel would match every collection channel — with
// "بدون قناة تحصيل" (no collection channel) plus the clarifying phrase
// "مطابقة حصرية للمصادر بلا قناة — ليست كل القنوات" (exact match for
// channel-less sources only — not all channels). Note that clarifying phrase
// legitimately CONTAINS the substring "كل القنوات" as a NEGATION ("ليست كل
// القنوات" = "not all channels") — so this checks EXACT-text absence (no
// element's own full text is precisely "كل القنوات"), not substring absence,
// which is the only way to state "the old wildcard label is gone" without
// also forbidding its own negation from ever explaining itself.
// ---------------------------------------------------------------------------
describe('§A — exact collection-channel copy: "كل القنوات" never rendered as a standalone label, "بدون قناة تحصيل" copy renders instead', () => {
  beforeEach(() => {
    cleanup();
    requirePermission.mockReset();
    getSettlementRoutesAdminList.mockReset();
  });

  it("SettlementRouteFormDialog (create, payment_collection, no channel selected): the old wildcard label never renders standalone, the new exact-match copy does", () => {
    render(
      <PermissionsProvider permissions={["settlements.manage_routes"] as never} isSuperAdmin={false}>
        <SettlementRouteFormDialog paymentMethods={[{ id: "pm-1", name_ar: "فيزا" }]} collectionChannels={[{ id: "cc-1", name_ar: "نقطة بيع" }]} shippingCarriers={[]} />
      </PermissionsProvider>,
    );
    fireEvent.click(screen.getByRole("button", { name: /إضافة مسار تسوية/ }));

    // The old wildcard label never appears as an element's OWN full text —
    // not the Label, not the default SelectItem, not the trigger's mirrored
    // value (all of which, pre-hotfix, could have been exactly "كل القنوات").
    expect(screen.queryByText("كل القنوات", { exact: true })).not.toBeInTheDocument();

    // The Label's own clarifying sentence (always visible, no need to open
    // the dropdown) carries the new copy verbatim.
    expect(screen.getByText(/بدون قناة تحصيل يطابق فقط المصادر التي ليس لها قناة تحصيل محددة لهذه الطريقة، وليس كل القنوات/)).toBeInTheDocument();

    // The default ("no channel selected") SelectItem's own text — mirrored
    // into the trigger via SelectValue since collectionChannelId starts
    // empty ("" normalizes to "none", which matches this very item). Radix
    // also renders a hidden native <option> fallback with the same text, so
    // this legitimately matches more than one element.
    expect(screen.getAllByText("بدون قناة تحصيل (مطابقة حصرية للمصادر بلا قناة — ليست كل القنوات)").length).toBeGreaterThanOrEqual(1);
  });

  it("SettlementRoutesPage route summary (collection_channel_name: null): renders ' — بدون قناة تحصيل', never the old ' — كل القنوات'", async () => {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.manage_routes"]) });
    getSettlementRoutesAdminList.mockResolvedValue([
      {
        id: "route-1",
        code: "visa",
        name_ar: "مسار فيزا",
        route_kind: "payment_collection",
        status: "active",
        payment_method_name: "فيزا",
        collection_channel_name: null,
        shipping_carrier_name: null,
        description: null,
      },
    ]);

    const ui = await SettlementRoutesPage();
    render(
      <PermissionsProvider permissions={["settlements.manage_routes"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );

    expect(screen.queryByText("كل القنوات", { exact: true })).not.toBeInTheDocument();
    expect(screen.queryByText(/— كل القنوات/)).not.toBeInTheDocument();
    expect(screen.getByText(/فيزا — بدون قناة تحصيل/)).toBeInTheDocument();
  });

  it("SettlementRoutesPage route summary (collection_channel_name present): renders the real channel name, not the no-channel copy", async () => {
    requirePermission.mockResolvedValue({ isSuperAdmin: false, permissions: new Set(["settlements.manage_routes"]) });
    getSettlementRoutesAdminList.mockResolvedValue([
      {
        id: "route-2",
        code: "mada_pos",
        name_ar: "مسار مدى نقطة بيع",
        route_kind: "payment_collection",
        status: "active",
        payment_method_name: "مدى",
        collection_channel_name: "نقطة بيع الرياض",
        shipping_carrier_name: null,
        description: null,
      },
    ]);

    const ui = await SettlementRoutesPage();
    render(
      <PermissionsProvider permissions={["settlements.manage_routes"] as never} isSuperAdmin={false}>
        {ui}
      </PermissionsProvider>,
    );

    expect(screen.getByText(/مدى — نقطة بيع الرياض/)).toBeInTheDocument();
    expect(screen.queryByText(/بدون قناة تحصيل/)).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// §G (component half) — settlement-route-fee-version-panel.tsx excludes
// 'source_snapshot' from the selectable transaction_fee_strategy options
// (via `availableStrategies`) whenever routeKind === 'cod_carrier', with the
// informational note always shown for a COD route. The schema-level half
// (createSettlementRouteFeeVersionSchema's superRefine rejection) is covered
// separately in tests/settlements-schema-validation.test.ts.
// ---------------------------------------------------------------------------
describe("§G — COD client-side validation (component half): source_snapshot excluded for routeKind='cod_carrier'", () => {
  beforeEach(() => cleanup());

  it("routeKind='cod_carrier': source_snapshot is NOT a selectable strategy option, and the informational note is always shown", async () => {
    render(
      <PermissionsProvider permissions={["settlements.manage_routes"] as never} isSuperAdmin={false}>
        <SettlementRouteFeeVersionPanel routeId="route-1" routeKind="cod_carrier" versions={[]} />
      </PermissionsProvider>,
    );
    fireEvent.click(screen.getByRole("button", { name: /إصدار رسوم جديد/ }));

    // The informational note is unconditional for a COD route — no need to
    // open the Select first.
    expect(await screen.findByText(/استراتيجية اللقطة الأصلية غير متاحة لمسار COD ناقل/)).toBeInTheDocument();

    const strategyTrigger = screen.getAllByRole("combobox")[0];
    openSelect(strategyTrigger);

    expect(screen.queryByRole("option", { name: TRANSACTION_FEE_STRATEGY_LABELS_AR.source_snapshot })).not.toBeInTheDocument();
    expect(screen.getByRole("option", { name: TRANSACTION_FEE_STRATEGY_LABELS_AR.route_formula })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: TRANSACTION_FEE_STRATEGY_LABELS_AR.none })).toBeInTheDocument();
  });

  it("routeKind='payment_collection': source_snapshot IS a selectable strategy option — the §14 exclusion is COD-carrier-specific, never a blanket removal", async () => {
    render(
      <PermissionsProvider permissions={["settlements.manage_routes"] as never} isSuperAdmin={false}>
        <SettlementRouteFeeVersionPanel routeId="route-1" routeKind="payment_collection" versions={[]} />
      </PermissionsProvider>,
    );
    fireEvent.click(screen.getByRole("button", { name: /إصدار رسوم جديد/ }));

    expect(screen.queryByText(/استراتيجية اللقطة الأصلية غير متاحة لمسار COD ناقل/)).not.toBeInTheDocument();

    const strategyTrigger = await screen.findAllByRole("combobox");
    openSelect(strategyTrigger[0]);

    expect(screen.getByRole("option", { name: TRANSACTION_FEE_STRATEGY_LABELS_AR.source_snapshot })).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// §H — Reconciled-write-actions correctness. This is a REGRESSION test for
// existing-but-previously-unverified-at-the-component-level behavior (the
// governing spec's own framing), tying record/reverse (Settlement
// BankMovementsPanel) together with reconcile/cancel (SettlementLifecycle
// Actions) for the SAME batch in one place — each already has its own
// narrower coverage elsewhere (tests/settlements-lifecycle-presentation.
// test.tsx for the movements panel alone), but this is the one place the two
// components' rules are asserted side by side for a single effective_status.
// Both components were found to be ALREADY CORRECT while writing this test
// (canAddNew = hasPermission && effectiveStatus === 'finalized' in
// settlement-bank-movements-panel.tsx; ReconcileDialog only rendered for
// effectiveStatus === 'finalized' in settlement-lifecycle-actions.tsx) — no
// production bug found here.
// ---------------------------------------------------------------------------
describe("§H — Reconciled-write-actions correctness (regression)", () => {
  const MOVEMENT = { id: "mv-1", movement_business_date: "2026-08-20", amount: "500.00", bank_reference: "REF-1", notes: null, reversed: false, reversal_amount_impact: null };

  beforeEach(() => cleanup());

  function renderBoth(effectiveStatus: string, movements: typeof MOVEMENT[] = [MOVEMENT]) {
    return render(
      <PermissionsProvider permissions={["settlements.record_bank_movement", "settlements.reconcile", "settlements.cancel"] as never} isSuperAdmin={false}>
        <>
          <SettlementBankMovementsPanel settlementBatchId="batch-1" movements={movements} hasPermission={true} effectiveStatus={effectiveStatus} />
          <SettlementLifecycleActions batchId="batch-1" settlementNumber="STL-0000000001" effectiveStatus={effectiveStatus} rowVersion={3} />
        </>
      </PermissionsProvider>,
    );
  }

  it("RECONCILED — record_settlement_bank_movement is disabled/hidden (mirrors the reconciled batch rejecting new movements, §13/0188); reverse stays offered; reconcile is no longer offered (already done); cancel stays offered", () => {
    renderBoth("reconciled");

    expect(screen.queryByRole("button", { name: /تسجيل حركة بنكية/ })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /عكس الحركة البنكية/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^مطابقة$/ })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /إلغاء الدفعة/ })).toBeInTheDocument();
  });

  it("FINALIZED — record_settlement_bank_movement IS offered; reconcile IS offered (reachable exactly once, from finalized); cancel is offered", () => {
    renderBoth("finalized");

    expect(screen.getByRole("button", { name: /تسجيل حركة بنكية/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^مطابقة$/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /إلغاء الدفعة/ })).toBeInTheDocument();
  });

  it("DRAFT/CANCELLED — SettlementLifecycleActions renders nothing at all (neither reconcile nor cancel is ever reachable from either status), and Record Movement stays unreachable pre-finalization too", () => {
    const { container: draftActions } = render(
      <PermissionsProvider permissions={["settlements.reconcile", "settlements.cancel"] as never} isSuperAdmin={false}>
        <SettlementLifecycleActions batchId="batch-1" settlementNumber="STL-0000000001" effectiveStatus="draft" rowVersion={1} />
      </PermissionsProvider>,
    );
    expect(draftActions.querySelector("button")).toBeNull();

    cleanup();
    const { container: cancelledActions } = render(
      <PermissionsProvider permissions={["settlements.reconcile", "settlements.cancel"] as never} isSuperAdmin={false}>
        <SettlementLifecycleActions batchId="batch-1" settlementNumber="STL-0000000001" effectiveStatus="cancelled" rowVersion={4} />
      </PermissionsProvider>,
    );
    expect(cancelledActions.querySelector("button")).toBeNull();

    cleanup();
    renderBoth("draft", []);
    expect(screen.queryByRole("button", { name: /تسجيل حركة بنكية/ })).not.toBeInTheDocument();
  });

  it("without settlements.record_bank_movement, Record Movement is never offered even on a finalized batch — regardless of the reconciled-specific gate above", () => {
    render(
      <PermissionsProvider permissions={["settlements.reconcile", "settlements.cancel"] as never} isSuperAdmin={false}>
        <SettlementBankMovementsPanel settlementBatchId="batch-1" movements={[MOVEMENT]} hasPermission={false} effectiveStatus="finalized" />
      </PermissionsProvider>,
    );
    expect(screen.queryByRole("button", { name: /تسجيل حركة بنكية/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /عكس الحركة البنكية/ })).not.toBeInTheDocument();
  });
});

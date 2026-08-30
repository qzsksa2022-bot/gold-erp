import { describe, expect, it, vi, beforeEach, beforeAll } from "vitest";
import { cleanup, render, screen, fireEvent, within, waitFor } from "@testing-library/react";
import "@testing-library/jest-dom";
import { PermissionsProvider } from "@/lib/permissions/context";
import { SettlementDraftWorkspace } from "@/features/settlements/components/settlement-draft-workspace";

// Radix's <Select> (used for the route picker below) needs a few jsdom
// polyfills for its pointer interactions — same well-known requirement as
// tests/adjustments-entry-form-zero-charge-state-machine.test.tsx's own
// beforeAll block, copied verbatim.
beforeAll(() => {
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

// Phase 7 Integrity Patch 7.1 §16/§33 — the Preview Key / freshness state
// machine on the draft-batch workspace (/settlements/[id] while status =
// 'draft'). Mirrors tests/settlements-financials-pass-through.test.tsx's own
// render/mock conventions for SettlementDraftWorkspace exactly (same two
// vi.mock blocks, same PermissionsProvider wrapper), but focuses entirely on
// idle/loading/valid/stale/error transitions and Finalize gating instead of
// sign-convention pass-through.
//
// previewStatus itself (see settlement-draft-workspace.tsx's own header
// comment) has no dedicated data-testid — it is a pure derivation of
// (isPreviewPending, previewError, previewResult, previewKey), so every test
// below asserts it indirectly through what actually renders: the idle hint,
// the "محدّثة" success badge, the "المعاينة قديمة" stale warning, the error
// message, and the Finalize trigger's disabled attribute.

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn(), refresh: vi.fn() }),
  useSearchParams: () => new URLSearchParams(),
  usePathname: () => "/settlements",
}));

const { listUnsettledSettlementSourcesAction, previewSettlementBatchAction, updateDraftSettlementBatchAction, finalizeSettlementBatchAction } = vi.hoisted(() => ({
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

const ROUTES = [
  { id: "route-1", code: "visa", name_ar: "مسار فيزا", route_kind: "payment_collection" },
  { id: "route-2", code: "mada", name_ar: "مسار مدى", route_kind: "payment_collection" },
];

const SOURCE_ROW = {
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

// Hotfix 7.1.1 §9 — SettlementBatchPreview (../actions.ts) carries configured_
// batch_fee/effective_batch_fee/batch_fee_overridden (replacing the single
// pre-hotfix `batch_fee` field the workspace's Row rendering no longer reads
// at all) so a pending override actually changes what Preview shows. Both
// fixtures below are NOT overridden (batch_fee_overridden: false) — the §9
// override-display branch itself (configured vs effective, both rendering
// side by side) is exercised separately below.
const VALID_PREVIEW = {
  success: true as const,
  data: {
    lines: [],
    gross_source_impact: "1000.00",
    provider_fee_impact: "25.00",
    expected_before_batch_fee: "975.00",
    configured_batch_fee: "5.00",
    effective_batch_fee: "5.00",
    batch_fee_overridden: false,
    expected_bank_settlement: "970.00",
    fee_version_resolved: true,
    transaction_fee_strategy: "source_snapshot",
  },
};

const ROUTE_FORMULA_PREVIEW = {
  success: true as const,
  data: {
    lines: [],
    gross_source_impact: "2000.00",
    provider_fee_impact: "60.00",
    expected_before_batch_fee: "1940.00",
    configured_batch_fee: "37.50",
    effective_batch_fee: "37.50",
    batch_fee_overridden: false,
    expected_bank_settlement: "1902.50",
    fee_version_resolved: true,
    transaction_fee_strategy: "route_formula",
  },
};

/** Mirrors tests/adjustments-entry-form-zero-charge-state-machine.test.tsx's own pickSelectOption helper for a Radix <Select> in jsdom. */
function pickSelectOption(trigger: HTMLElement, optionName: string | RegExp) {
  fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false, pointerId: 1 });
  fireEvent.click(trigger);
  const option = screen.getByRole("option", { name: optionName });
  fireEvent.pointerUp(option);
  fireEvent.click(option);
}

function renderWorkspace() {
  return render(
    <PermissionsProvider permissions={["settlements.finalize", "settlements.override_batch_fee"] as never} isSuperAdmin={false}>
      <SettlementDraftWorkspace batch={BATCH} routes={ROUTES} stores={[]} />
    </PermissionsProvider>,
  );
}

async function loadAndSelectOneSource() {
  listUnsettledSettlementSourcesAction.mockResolvedValue({ success: true, data: [SOURCE_ROW] });
  fireEvent.click(screen.getByRole("button", { name: /تحميل المصادر غير المسوّاة/ }));
  await screen.findByText("SALE-0000000090");
  fireEvent.click(screen.getAllByRole("checkbox")[0]);
}

function finalizeTrigger() {
  return screen.getByRole("button", { name: /اعتماد الدفعة/ });
}

function runPreviewButton() {
  return screen.getByRole("button", { name: /تحديث المعاينة/ });
}

describe("SettlementDraftWorkspace — Preview state machine (Patch 7.1 §16/§33)", () => {
  beforeEach(() => {
    cleanup();
    listUnsettledSettlementSourcesAction.mockReset();
    previewSettlementBatchAction.mockReset();
  });

  it("idle — no preview has run yet: idle hint shown, Finalize disabled", () => {
    renderWorkspace();
    expect(screen.getByText(/لم تُجرَ معاينة بعد/)).toBeInTheDocument();
    expect(finalizeTrigger()).toBeDisabled();
  });

  it("Finalize disabled without preview (dedicated gate check, item 33)", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    // A source is selected but "تحديث المعاينة" was never clicked — still idle.
    expect(screen.getByText(/لم تُجرَ معاينة بعد/)).toBeInTheDocument();
    expect(finalizeTrigger()).toBeDisabled();
  });

  it("loading — while the preview RPC is in flight, no idle/valid/error UI renders and Finalize stays disabled", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();

    let releasePreview: (() => void) | undefined;
    previewSettlementBatchAction.mockImplementation(
      () =>
        new Promise((resolve) => {
          releasePreview = () => resolve(VALID_PREVIEW);
        }),
    );

    fireEvent.click(runPreviewButton());

    // In flight: none of the terminal-state UI has appeared yet.
    expect(screen.queryByText(/لم تُجرَ معاينة بعد/)).not.toBeInTheDocument();
    expect(screen.queryByText("محدّثة")).not.toBeInTheDocument();
    expect(finalizeTrigger()).toBeDisabled();
    expect(runPreviewButton()).toBeDisabled();

    // Release so the transition settles cleanly before the test ends.
    releasePreview?.();
    await screen.findByText("محدّثة");
  });

  it("success — a resolved preview shows the 'محدّثة' badge, renders the RPC's figures verbatim, and enables Finalize", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    previewSettlementBatchAction.mockResolvedValue(VALID_PREVIEW);

    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    expect(screen.getByText("970.00")).toBeInTheDocument();
    expect(screen.getByText("5.00")).toBeInTheDocument();
    expect(finalizeTrigger()).not.toBeDisabled();
  });

  it("route_formula — a route_formula-derived fee/total renders exactly as the RPC returned it", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    previewSettlementBatchAction.mockResolvedValue(ROUTE_FORMULA_PREVIEW);

    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    expect(screen.getByText("37.50")).toBeInTheDocument(); // batch_fee (route_formula-derived)
    expect(screen.getByText("1902.50")).toBeInTheDocument(); // expected_bank_settlement
    expect(finalizeTrigger()).not.toBeDisabled();
  });

  it("error — preview_settlement_batch() rejecting the whole call shows the error message, no partial data, Finalize disabled", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    previewSettlementBatchAction.mockResolvedValue({ success: false, error: "أحد المصادر المختارة لم يعد صالحًا للتسوية — يرجى تحديث الاختيار." });

    fireEvent.click(runPreviewButton());
    await screen.findByText(/أحد المصادر المختارة لم يعد صالحًا للتسوية/);

    // No partial preview figures ever render alongside the error.
    expect(screen.queryByText("محدّثة")).not.toBeInTheDocument();
    expect(screen.queryByText(/المتوقع بنكيًا \(نهائي\)/)).not.toBeInTheDocument();
    expect(finalizeTrigger()).toBeDisabled();
  });

  it("a selected-source mismatch/staleness rejects the WHOLE preview call (§15) — surfaces as the error state, never a partial result", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    // Simulate the §15 contract: preview_settlement_batch() errors out
    // entirely when a selected token is stale/invalid, rather than returning
    // a row with a reduced/partial selected-count.
    previewSettlementBatchAction.mockResolvedValue({ success: false, error: "لم يعد أحد المصادر المختارة متاحًا للتسوية (ربما حُجز ضمن دفعة أخرى) — أعد تحميل المصادر واختر مجددًا." });

    fireEvent.click(runPreviewButton());
    await screen.findByText(/لم يعد أحد المصادر المختارة متاحًا للتسوية/);

    expect(finalizeTrigger()).toBeDisabled();
    // Nothing resembling a successful/partial preview total ever appears.
    expect(screen.queryByText("970.00")).not.toBeInTheDocument();
  });

  it("stale after a route change — a successful preview goes stale the moment the route selection changes", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    previewSettlementBatchAction.mockResolvedValue(VALID_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");
    expect(finalizeTrigger()).not.toBeDisabled();

    pickSelectOption(screen.getAllByRole("combobox")[0], "مسار مدى");

    expect(screen.queryByText("محدّثة")).not.toBeInTheDocument();
    expect(screen.getByText(/المعاينة قديمة/)).toBeInTheDocument();
    expect(finalizeTrigger()).toBeDisabled();
  });

  it("stale after a settlement-date change — the top-level settlement date is part of the preview key", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    previewSettlementBatchAction.mockResolvedValue(VALID_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    const settlementDateInput = document.querySelectorAll('input[type="date"]')[0] as HTMLInputElement;
    fireEvent.change(settlementDateInput, { target: { value: "2026-08-21" } });

    expect(screen.queryByText("محدّثة")).not.toBeInTheDocument();
    expect(screen.getByText(/المعاينة قديمة/)).toBeInTheDocument();
    expect(finalizeTrigger()).toBeDisabled();
  });

  it("stale after a source date-range change — sourceDateFrom/sourceDateTo are both part of the preview key", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    previewSettlementBatchAction.mockResolvedValue(VALID_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    const dateInputs = document.querySelectorAll('input[type="date"]');
    const sourceDateTo = dateInputs[2] as HTMLInputElement; // [0]=settlementDate, [1]=sourceDateFrom, [2]=sourceDateTo
    fireEvent.change(sourceDateTo, { target: { value: "2026-08-25" } });

    expect(screen.queryByText("محدّثة")).not.toBeInTheDocument();
    expect(screen.getByText(/المعاينة قديمة/)).toBeInTheDocument();
    expect(finalizeTrigger()).toBeDisabled();
  });

  it("stale after a source-selection change — toggling a source in/out after a successful preview invalidates it", async () => {
    listUnsettledSettlementSourcesAction.mockResolvedValue({
      success: true,
      data: [
        SOURCE_ROW,
        { ...SOURCE_ROW, source_event_id: "so-2", source_number: "SALE-0000000091", source_label: "SALE-0000000091" },
      ],
    });
    renderWorkspace();
    fireEvent.click(screen.getByRole("button", { name: /تحميل المصادر غير المسوّاة/ }));
    await screen.findByText("SALE-0000000090");
    fireEvent.click(screen.getAllByRole("checkbox")[0]);

    previewSettlementBatchAction.mockResolvedValue(VALID_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    // Select a second source — membership of the selected set changed.
    fireEvent.click(screen.getAllByRole("checkbox")[1]);

    expect(screen.queryByText("محدّثة")).not.toBeInTheDocument();
    expect(screen.getByText(/المعاينة قديمة/)).toBeInTheDocument();
    expect(finalizeTrigger()).toBeDisabled();
  });

  it("Finalize enabled ONLY for the current, matching successful preview — stale after a change, then re-enabled once re-previewed under the new key", async () => {
    // Hotfix 7.1.1 §10 — the "change" that flips this stale is a SOURCE-
    // SELECTION toggle rather than a route change: changing the route
    // selector now ALSO marks the header dirty (isHeaderDirty), which
    // disables the "تحديث المعاينة" button itself (not merely invalidating
    // the last preview) — that specific route/date scenario is covered on
    // its own terms in the "Header-dirty state machine" describe block
    // below. A source-selection toggle invalidates the SAME preview key
    // (membership is part of it, see previewKey's tokenPart) without ever
    // touching persistedRouteId/persistedSettlementDate, so re-previewing
    // immediately stays possible here — exactly what this test exercises.
    listUnsettledSettlementSourcesAction.mockResolvedValue({
      success: true,
      data: [SOURCE_ROW, { ...SOURCE_ROW, source_event_id: "so-2", source_number: "SALE-0000000091", source_label: "SALE-0000000091" }],
    });
    renderWorkspace();
    fireEvent.click(screen.getByRole("button", { name: /تحميل المصادر غير المسوّاة/ }));
    await screen.findByText("SALE-0000000090");
    fireEvent.click(screen.getAllByRole("checkbox")[0]);

    previewSettlementBatchAction.mockResolvedValueOnce(VALID_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");
    expect(finalizeTrigger()).not.toBeDisabled();

    // Select a second source -> preview key changes (membership), Finalize
    // must disable itself again without needing any other interaction.
    fireEvent.click(screen.getAllByRole("checkbox")[1]);
    expect(finalizeTrigger()).toBeDisabled();

    // Re-preview under the NEW key -> Finalize re-enables for that new
    // successful preview only.
    previewSettlementBatchAction.mockResolvedValueOnce(ROUTE_FORMULA_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");
    expect(finalizeTrigger()).not.toBeDisabled();
    expect(screen.getByText("1902.50")).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Hotfix 7.1.1 §10 — the persistedRouteId/persistedSettlementDate vs live
// routeId/settlementDate state machine (settlement-draft-workspace.tsx's own
// header comment). isHeaderDirty = routeId !== persistedRouteId ||
// settlementDate !== persistedSettlementDate — computed fresh every render,
// seeded from `batch` on mount, advanced ONLY inside saveHeader()'s success
// path. Reuses this file's own renderWorkspace/pickSelectOption/
// loadAndSelectOneSource/finalizeTrigger/runPreviewButton helpers.
// ---------------------------------------------------------------------------
describe("Header-dirty state machine (Hotfix 7.1.1 §10)", () => {
  beforeEach(() => {
    cleanup();
    listUnsettledSettlementSourcesAction.mockReset();
    previewSettlementBatchAction.mockReset();
    updateDraftSettlementBatchAction.mockReset();
  });

  it("changing the route selector without saving marks the header dirty: the warning renders, and discovery/Preview/Finalize all disable", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    expect(screen.queryByText(/احفظ بيانات المسودة أولًا/)).not.toBeInTheDocument();

    pickSelectOption(screen.getAllByRole("combobox")[0], "مسار مدى");

    expect(screen.getAllByText(/احفظ بيانات المسودة أولًا/).length).toBeGreaterThanOrEqual(1);
    expect(screen.getByRole("button", { name: /تحميل المصادر غير المسوّاة/ })).toBeDisabled();
    expect(runPreviewButton()).toBeDisabled();
    expect(finalizeTrigger()).toBeDisabled();
  });

  it("changing the settlement date without saving ALSO marks the header dirty — both routeId and settlementDate are compared against their persisted counterparts", () => {
    renderWorkspace();
    const settlementDateInput = document.querySelectorAll('input[type="date"]')[0] as HTMLInputElement;

    fireEvent.change(settlementDateInput, { target: { value: "2026-08-25" } });

    expect(screen.getAllByText(/احفظ بيانات المسودة أولًا/).length).toBeGreaterThanOrEqual(1);
    expect(screen.getByRole("button", { name: /تحميل المصادر غير المسوّاة/ })).toBeDisabled();
    expect(runPreviewButton()).toBeDisabled();
    expect(finalizeTrigger()).toBeDisabled();
  });
});

// ---------------------------------------------------------------------------
// Hotfix 7.1.1 §10 — the post-save reset: a successful updateDraftSettlement
// BatchAction() call advances persistedRouteId/persistedSettlementDate to
// what was just saved (clearing isHeaderDirty), AND explicitly clears
// sources/selected/previewResult/previewError — anything computed against
// the PREVIOUS persisted route/date is stale the instant the persisted
// route/date itself moves, so it must never survive to look valid by
// coincidence (see saveHeader()'s own comment).
// ---------------------------------------------------------------------------
describe("Post-save reset (Hotfix 7.1.1 §10)", () => {
  beforeEach(() => {
    cleanup();
    listUnsettledSettlementSourcesAction.mockReset();
    previewSettlementBatchAction.mockReset();
    updateDraftSettlementBatchAction.mockReset();
  });

  it("a successful save clears the dirty warning, advances the persisted route/date, and wipes the prior source selection + preview so nothing stale survives", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    previewSettlementBatchAction.mockResolvedValueOnce(VALID_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");
    expect(screen.getByText(/المصادر المختارة \(1\)/)).toBeInTheDocument();

    // Change the route without saving -> dirty.
    pickSelectOption(screen.getAllByRole("combobox")[0], "مسار مدى");
    expect(screen.getAllByText(/احفظ بيانات المسودة أولًا/).length).toBeGreaterThanOrEqual(1);

    updateDraftSettlementBatchAction.mockResolvedValue({ success: true, data: { row_version: 2 } });
    fireEvent.click(screen.getByRole("button", { name: /حفظ بيانات المسودة/ }));

    // Once the save lands, the idle preview hint reappears — this alone
    // proves previewResult was actually cleared (a "محدّثة"/stale badge
    // would show instead if the old preview had survived).
    await screen.findByText(/لم تُجرَ معاينة بعد/);

    expect(screen.queryByText(/احفظ بيانات المسودة أولًا/)).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: /تحميل المصادر غير المسوّاة/ })).not.toBeDisabled();

    // The stale selection + the previously-loaded source list are both gone.
    expect(screen.getByText(/المصادر المختارة \(0\)/)).toBeInTheDocument();
    expect(screen.queryByText("SALE-0000000090")).not.toBeInTheDocument();
    expect(screen.queryByText("محدّثة")).not.toBeInTheDocument();
    // Finalize is disabled again — now because there is no fresh preview,
    // never because of the (now-cleared) dirty header.
    expect(finalizeTrigger()).toBeDisabled();
  });

  it("the preview is genuinely invalidated (never reused) after a save — re-discovering/re-selecting/re-previewing afterward calls previewSettlementBatchAction again rather than resurrecting the pre-save result", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    previewSettlementBatchAction.mockResolvedValueOnce(VALID_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    pickSelectOption(screen.getAllByRole("combobox")[0], "مسار مدى");
    updateDraftSettlementBatchAction.mockResolvedValue({ success: true, data: { row_version: 2 } });
    fireEvent.click(screen.getByRole("button", { name: /حفظ بيانات المسودة/ }));
    await screen.findByText(/لم تُجرَ معاينة بعد/);

    listUnsettledSettlementSourcesAction.mockResolvedValue({ success: true, data: [SOURCE_ROW] });
    fireEvent.click(screen.getByRole("button", { name: /تحميل المصادر غير المسوّاة/ }));
    await screen.findByText("SALE-0000000090");
    fireEvent.click(screen.getAllByRole("checkbox")[0]);

    previewSettlementBatchAction.mockResolvedValueOnce(ROUTE_FORMULA_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    expect(previewSettlementBatchAction).toHaveBeenCalledTimes(2);
    expect(screen.getByText("1902.50")).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Hotfix 7.1.1 §9 — the preview card's Row rendering branches on
// previewResult.data.batch_fee_overridden: TRUE renders BOTH configured_
// batch_fee (default) and effective_batch_fee (post-override), plus a
// distinguishing note; FALSE renders a single "رسوم الدفعة" row from
// effective_batch_fee alone. VALID_PREVIEW (batch_fee_overridden: false)
// covers the FALSE branch; OVERRIDDEN_PREVIEW below covers TRUE.
// ---------------------------------------------------------------------------
describe("Override preview display (Hotfix 7.1.1 §9)", () => {
  const OVERRIDDEN_PREVIEW = {
    success: true as const,
    data: {
      lines: [],
      gross_source_impact: "1000.00",
      provider_fee_impact: "25.00",
      expected_before_batch_fee: "975.00",
      configured_batch_fee: "5.00",
      effective_batch_fee: "20.00",
      batch_fee_overridden: true,
      expected_bank_settlement: "955.00",
      fee_version_resolved: true,
      transaction_fee_strategy: "source_snapshot",
    },
  };

  beforeEach(() => {
    cleanup();
    listUnsettledSettlementSourcesAction.mockReset();
    previewSettlementBatchAction.mockReset();
  });

  it("batch_fee_overridden=true renders BOTH the configured (default) and effective (post-override) fee rows, with a visible distinguishing note", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    previewSettlementBatchAction.mockResolvedValue(OVERRIDDEN_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    expect(screen.getByText("رسوم الدفعة (الافتراضية)")).toBeInTheDocument();
    expect(screen.getByText("رسوم الدفعة (بعد التجاوز)")).toBeInTheDocument();
    expect(screen.getByText("5.00")).toBeInTheDocument(); // configured_batch_fee
    expect(screen.getByText("20.00")).toBeInTheDocument(); // effective_batch_fee
    expect(screen.getByText(/تم تجاوز رسوم الدفعة الافتراضية/)).toBeInTheDocument();
    // The single, non-override label never renders alongside the split pair.
    expect(screen.queryByText("رسوم الدفعة")).not.toBeInTheDocument();
  });

  it("batch_fee_overridden=false renders only the single 'رسوم الدفعة' row — no configured/effective split, no override note", async () => {
    renderWorkspace();
    await loadAndSelectOneSource();
    previewSettlementBatchAction.mockResolvedValue(VALID_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    expect(screen.getByText("رسوم الدفعة")).toBeInTheDocument();
    expect(screen.queryByText("رسوم الدفعة (الافتراضية)")).not.toBeInTheDocument();
    expect(screen.queryByText("رسوم الدفعة (بعد التجاوز)")).not.toBeInTheDocument();
    expect(screen.queryByText(/تم تجاوز رسوم الدفعة الافتراضية/)).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Hotfix 7.1.1 §9/§13 — runPreview() sends overrideAmount.trim() as
// batchFeeOverride; the FinalizeDialog's submit() must send the SAME string
// as batch_fee_override — byte-identical, never coerced through Number()/
// parseFloat(). This exercises the real, lifted-up override state (owned by
// SettlementDraftWorkspace, edited inside FinalizeDialog) end to end: open
// Finalize, enable + fill the override, re-preview under the new key
// (mirroring the dialog's own retry-after-stale flow), then submit — and
// inspects BOTH mocked action calls' actual arguments.
// ---------------------------------------------------------------------------
describe("Override value consistency (Hotfix 7.1.1 §9/§13)", () => {
  beforeEach(() => {
    cleanup();
    listUnsettledSettlementSourcesAction.mockReset();
    previewSettlementBatchAction.mockReset();
    finalizeSettlementBatchAction.mockReset();
  });

  it("an override value with several decimal places reaches BOTH preview_settlement_batch and finalize_settlement_batch as the exact same string", async () => {
    const OVERRIDE_VALUE = "15.1234";
    renderWorkspace();
    await loadAndSelectOneSource();

    // An initial, non-overridden successful preview so Finalize is reachable.
    previewSettlementBatchAction.mockResolvedValueOnce(VALID_PREVIEW);
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    fireEvent.click(finalizeTrigger());
    const dialog = await screen.findByRole("dialog");

    fireEvent.click(within(dialog).getByRole("checkbox"));
    const overrideAmountInput = dialog.querySelector('input[type="number"]') as HTMLInputElement;
    fireEvent.change(overrideAmountInput, { target: { value: OVERRIDE_VALUE } });
    const overrideReasonTextarea = dialog.querySelector("textarea") as HTMLTextAreaElement;
    fireEvent.change(overrideReasonTextarea, { target: { value: "اتفاق خاص مع المزوّد" } });

    // Enabling/editing the override is part of the preview key (§16) — the
    // dialog's own stale warning confirms the parent state actually updated.
    expect(within(dialog).getByText(/المعاينة قديمة/)).toBeInTheDocument();

    // Radix marks the rest of the page aria-hidden while this dialog is
    // open (see the dialog's own copy: "أغلق هذا الحوار وحدّث المعاينة قبل
    // الاعتماد") — so re-previewing means closing the dialog first, exactly
    // as a real user would, then reopening it to submit. overrideAmount/
    // overrideReason are owned by the PARENT (lifted up, per this
    // component's own header comment) and survive the dialog closing.
    fireEvent.click(within(dialog).getByRole("button", { name: "إلغاء" }));

    previewSettlementBatchAction.mockResolvedValueOnce({
      success: true as const,
      data: { ...VALID_PREVIEW.data, configured_batch_fee: "5.00", effective_batch_fee: OVERRIDE_VALUE, batch_fee_overridden: true },
    });
    fireEvent.click(runPreviewButton());
    await screen.findByText("محدّثة");

    finalizeSettlementBatchAction.mockResolvedValue({ success: true, data: { id: "batch-1", settlement_number: "STL-0000000001", row_version: 2 } });
    fireEvent.click(finalizeTrigger());
    const dialogAgain = await screen.findByRole("dialog");
    fireEvent.click(within(dialogAgain).getByRole("button", { name: /تأكيد الاعتماد/ }));
    await waitFor(() => expect(finalizeSettlementBatchAction).toHaveBeenCalled());

    expect(previewSettlementBatchAction).toHaveBeenLastCalledWith(expect.objectContaining({ batchFeeOverride: OVERRIDE_VALUE }));
    expect(finalizeSettlementBatchAction).toHaveBeenCalledWith(expect.objectContaining({ batch_fee_override: OVERRIDE_VALUE }));
  });
});

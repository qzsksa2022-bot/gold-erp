import { describe, expect, it, vi, beforeEach } from "vitest";

// Phase 7 (Settlements Core) — permission-boundary regression tests
// exercising the Server Actions THEMSELVES (not components that mock the
// action away), mirroring tests/adjustments-actions-permission-boundary.
// test.ts exactly. Every lifecycle step gates on its OWN permission
// (settlements.create vs settlements.finalize vs settlements.reconcile vs
// settlements.cancel vs settlements.record_bank_movement vs settlements.
// manage_routes) — a future accidental collapse of these into a shared gate
// would silently widen who can finalize/cancel/reconcile a settlement
// batch. This file also covers Zod-before-RPC validation and DB error-
// message propagation via dbErrorMessage (P0001 passed through verbatim,
// anything else collapsed to the generic Arabic message) — the same
// dbErrorMessage() helper adjustments/actions.ts uses.

const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const { revalidatePath } = vi.hoisted(() => ({ revalidatePath: vi.fn() }));
vi.mock("next/cache", () => ({ revalidatePath }));

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({ rpc: rpcMock }),
}));

import {
  createSettlementRouteAction,
  updateSettlementRouteAction,
  setSettlementRouteStatusAction,
  createSettlementRouteFeeVersionAction,
  cancelSettlementRouteFeeVersionAction,
  listUnsettledSettlementSourcesAction,
  previewSettlementBatchAction,
  createDraftSettlementBatchAction,
  updateDraftSettlementBatchAction,
  finalizeSettlementBatchAction,
  recordSettlementBankMovementAction,
  reverseSettlementBankMovementAction,
  reconcileSettlementBatchAction,
  cancelSettlementBatchAction,
} from "@/features/settlements/actions";

const BATCH_ID = "11111111-1111-1111-1111-111111111111";
const ROUTE_ID = "22222222-2222-2222-2222-222222222222";
const SOURCE_EVENT_ID = "33333333-3333-3333-3333-333333333333";
const PM_ID = "44444444-4444-4444-4444-444444444444";
const CHANNEL_ID = "55555555-5555-5555-5555-555555555555";
const VERSION_ID = "66666666-6666-6666-6666-666666666666";
const MOVEMENT_ID = "77777777-7777-7777-7777-777777777777";

beforeEach(() => {
  requirePermission.mockReset();
  revalidatePath.mockReset();
  rpcMock.mockReset();
  requirePermission.mockResolvedValue({ userId: "actor-1" });
});

describe("settlement_routes / fee-version actions — all gate on settlements.manage_routes", () => {
  it("createSettlementRouteAction", async () => {
    rpcMock.mockResolvedValue({ data: ROUTE_ID, error: null });
    await createSettlementRouteAction({
      code: "visa_route",
      name_ar: "مسار فيزا",
      route_kind: "payment_collection",
      payment_method_id: PM_ID,
      collection_channel_id: CHANNEL_ID,
    });
    expect(requirePermission).toHaveBeenCalledWith("settlements.manage_routes");
    expect(rpcMock).toHaveBeenCalledWith("create_settlement_route", expect.objectContaining({ p_code: "visa_route" }));
  });

  it("updateSettlementRouteAction", async () => {
    rpcMock.mockResolvedValue({ data: null, error: null });
    await updateSettlementRouteAction({ id: ROUTE_ID, name_ar: "اسم جديد" });
    expect(requirePermission).toHaveBeenCalledWith("settlements.manage_routes");
    expect(rpcMock).toHaveBeenCalledWith("update_settlement_route", expect.objectContaining({ p_id: ROUTE_ID }));
  });

  it("setSettlementRouteStatusAction calls disable_settlement_route for 'disabled' and enable_settlement_route otherwise", async () => {
    rpcMock.mockResolvedValue({ data: null, error: null });
    await setSettlementRouteStatusAction(ROUTE_ID, "disabled");
    expect(requirePermission).toHaveBeenCalledWith("settlements.manage_routes");
    expect(rpcMock).toHaveBeenCalledWith("disable_settlement_route", { p_id: ROUTE_ID });

    rpcMock.mockClear();
    await setSettlementRouteStatusAction(ROUTE_ID, "active");
    expect(rpcMock).toHaveBeenCalledWith("enable_settlement_route", { p_id: ROUTE_ID });
  });

  it("createSettlementRouteFeeVersionAction", async () => {
    rpcMock.mockResolvedValue({ data: VERSION_ID, error: null });
    await createSettlementRouteFeeVersionAction({
      settlement_route_id: ROUTE_ID,
      route_kind: "payment_collection",
      effective_from: "2026-08-20",
      transaction_fee_strategy: "source_snapshot",
      batch_fee_fixed: "0",
    });
    expect(requirePermission).toHaveBeenCalledWith("settlements.manage_routes");
    expect(rpcMock).toHaveBeenCalledWith("create_settlement_route_fee_version", expect.objectContaining({ p_settlement_route_id: ROUTE_ID }));
  });

  it("cancelSettlementRouteFeeVersionAction", async () => {
    rpcMock.mockResolvedValue({ data: null, error: null });
    await cancelSettlementRouteFeeVersionAction(VERSION_ID);
    expect(requirePermission).toHaveBeenCalledWith("settlements.manage_routes");
    expect(rpcMock).toHaveBeenCalledWith("cancel_settlement_route_fee_version", { p_version_id: VERSION_ID });
  });
});

describe("Settlement Source Discovery actions — gate on settlements.create alone", () => {
  it("listUnsettledSettlementSourcesAction", async () => {
    rpcMock.mockResolvedValue({ data: [], error: null });
    await listUnsettledSettlementSourcesAction({ settlementRouteId: ROUTE_ID, sourceDateFrom: "2026-08-01", sourceDateTo: "2026-08-20" });
    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("settlements.create");
    expect(rpcMock).toHaveBeenCalledWith("list_unsettled_settlement_sources", expect.objectContaining({ p_settlement_route_id: ROUTE_ID }));
  });

  it("previewSettlementBatchAction", async () => {
    rpcMock.mockResolvedValue({ data: [{ lines: [], gross_source_impact: "0.00" }], error: null });
    await previewSettlementBatchAction({
      settlementRouteId: ROUTE_ID,
      sourceDateFrom: "2026-08-01",
      sourceDateTo: "2026-08-20",
      selectedSources: [{ source_kind: "sale", source_event_id: SOURCE_EVENT_ID }],
    });
    expect(requirePermission).toHaveBeenCalledWith("settlements.create");
    expect(rpcMock).toHaveBeenCalledWith("preview_settlement_batch", expect.objectContaining({ p_settlement_route_id: ROUTE_ID }));
  });
});

describe("settlement_batches draft lifecycle — create/update gate on settlements.create, finalize on the DISTINCT settlements.finalize", () => {
  it("createDraftSettlementBatchAction gates on settlements.create", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: BATCH_ID, settlement_number: "STL-0000000001" }], error: null });
    await createDraftSettlementBatchAction({ settlement_route_id: ROUTE_ID, settlement_date: "2026-08-20" });
    expect(requirePermission).toHaveBeenCalledWith("settlements.create");
    expect(rpcMock).toHaveBeenCalledWith("create_draft_settlement_batch", expect.objectContaining({ p_settlement_route_id: ROUTE_ID }));
  });

  it("updateDraftSettlementBatchAction gates on settlements.create — NOT settlements.finalize", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: BATCH_ID, row_version: 2 }], error: null });
    await updateDraftSettlementBatchAction({ id: BATCH_ID, row_version: 1, settlement_route_id: ROUTE_ID, settlement_date: "2026-08-20" });
    expect(requirePermission).toHaveBeenCalledWith("settlements.create");
    expect(requirePermission).not.toHaveBeenCalledWith("settlements.finalize");
  });

  it("finalizeSettlementBatchAction gates on the DISTINCT settlements.finalize permission — NOT settlements.create, even though both act on a draft", async () => {
    rpcMock.mockResolvedValue({ data: [{ id: BATCH_ID, settlement_number: "STL-0000000001", row_version: 2 }], error: null });
    await finalizeSettlementBatchAction({
      id: BATCH_ID,
      row_version: 1,
      selected_sources: [{ source_kind: "sale", source_event_id: SOURCE_EVENT_ID }],
    });
    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("settlements.finalize");
    expect(requirePermission).not.toHaveBeenCalledWith("settlements.create");
    expect(rpcMock).toHaveBeenCalledWith(
      "finalize_settlement_batch",
      expect.objectContaining({ p_settlement_batch_id: BATCH_ID, p_expected_version: 1, p_selected_sources: [{ source_kind: "sale", source_event_id: SOURCE_EVENT_ID }] }),
    );
  });

  it("finalizeSettlementBatchAction rejects an empty selected_sources array client-side (Zod), never reaching the RPC", async () => {
    const result = await finalizeSettlementBatchAction({ id: BATCH_ID, row_version: 1, selected_sources: [] });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });
});

describe("settlement_bank_movement_events actions — both gate on settlements.record_bank_movement", () => {
  it("recordSettlementBankMovementAction", async () => {
    rpcMock.mockResolvedValue({ data: MOVEMENT_ID, error: null });
    await recordSettlementBankMovementAction({ settlement_batch_id: BATCH_ID, movement_business_date: "2026-08-20", amount: "12500.00" });
    expect(requirePermission).toHaveBeenCalledWith("settlements.record_bank_movement");
    expect(rpcMock).toHaveBeenCalledWith("record_settlement_bank_movement", expect.objectContaining({ p_amount: "12500.00" }));
  });

  it("recordSettlementBankMovementAction rejects a zero amount client-side (Zod), never reaching the RPC", async () => {
    const result = await recordSettlementBankMovementAction({ settlement_batch_id: BATCH_ID, movement_business_date: "2026-08-20", amount: "0.00" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("reverseSettlementBankMovementAction", async () => {
    rpcMock.mockResolvedValue({ data: "88888888-8888-4888-8888-888888888888", error: null });
    await reverseSettlementBankMovementAction({ bank_movement_event_id: MOVEMENT_ID, reversal_business_date: "2026-08-20", reason: "قيد بنكي خاطئ" }, BATCH_ID);
    expect(requirePermission).toHaveBeenCalledWith("settlements.record_bank_movement");
    expect(rpcMock).toHaveBeenCalledWith("reverse_settlement_bank_movement", expect.objectContaining({ p_bank_movement_event_id: MOVEMENT_ID, p_reason: "قيد بنكي خاطئ" }));
  });

  it("reverseSettlementBankMovementAction rejects a blank reason client-side (Zod), never reaching the RPC", async () => {
    const result = await reverseSettlementBankMovementAction({ bank_movement_event_id: MOVEMENT_ID, reversal_business_date: "2026-08-20", reason: "" }, BATCH_ID);
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });
});

describe("reconcileSettlementBatchAction — gates on settlements.reconcile alone (settlements.reconcile_variance is enforced server-side inside the RPC, never client-side)", () => {
  it("gates on settlements.reconcile — NOT settlements.cancel", async () => {
    rpcMock.mockResolvedValue({ data: [{ row_version: 3, actual_bank_movement: "975.00", variance: "0.00" }], error: null });
    await reconcileSettlementBatchAction({ id: BATCH_ID, row_version: 2 });
    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("settlements.reconcile");
    expect(requirePermission).not.toHaveBeenCalledWith("settlements.cancel");
    expect(rpcMock).toHaveBeenCalledWith("reconcile_settlement_batch", expect.objectContaining({ p_settlement_batch_id: BATCH_ID, p_expected_version: 2, p_variance_reason: null }));
  });

  it("passes a supplied variance_reason through to the RPC unchanged", async () => {
    rpcMock.mockResolvedValue({ data: [{ row_version: 3, actual_bank_movement: "985.00", variance: "10.00" }], error: null });
    await reconcileSettlementBatchAction({ id: BATCH_ID, row_version: 2, variance_reason: "فرق بنكي بسبب رسوم إضافية" });
    expect(rpcMock).toHaveBeenCalledWith("reconcile_settlement_batch", expect.objectContaining({ p_variance_reason: "فرق بنكي بسبب رسوم إضافية" }));
  });
});

describe("cancelSettlementBatchAction — gates on the DISTINCT settlements.cancel permission", () => {
  it("gates on settlements.cancel — NOT settlements.reconcile", async () => {
    rpcMock.mockResolvedValue({ data: BATCH_ID, error: null });
    await cancelSettlementBatchAction({ id: BATCH_ID, row_version: 2, cancellation_business_date: "2026-08-20", reason: "خطأ في اختيار المسار" });
    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("settlements.cancel");
    expect(requirePermission).not.toHaveBeenCalledWith("settlements.reconcile");
  });

  it("rejects a blank reason client-side (Zod), never reaching the RPC — mirrors the DB's own mandatory-reason guard defensively", async () => {
    const result = await cancelSettlementBatchAction({ id: BATCH_ID, row_version: 2, cancellation_business_date: "2026-08-20", reason: "" });
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });
});

describe("an actor lacking the required permission is rejected before any RPC is reached", () => {
  it("requirePermission's own redirect/throw propagates, no silent fallthrough", async () => {
    requirePermission.mockRejectedValue(new Error("NEXT_REDIRECT;replace;/403"));
    await expect(finalizeSettlementBatchAction({ id: BATCH_ID, row_version: 1, selected_sources: [{ source_kind: "sale", source_event_id: SOURCE_EVENT_ID }] })).rejects.toThrow();
    expect(rpcMock).not.toHaveBeenCalled();
  });
});

describe("DB error propagation — dbErrorMessage() passes a safe (P0001) message through verbatim, collapses anything else to the generic message", () => {
  it("a P0001 rejection from finalize_settlement_batch surfaces its real Arabic message unchanged", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "دفعة التسوية هذه ليست في حالة مسودة" } });
    const result = await finalizeSettlementBatchAction({ id: BATCH_ID, row_version: 1, selected_sources: [{ source_kind: "sale", source_event_id: SOURCE_EVENT_ID }] });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error).toBe("دفعة التسوية هذه ليست في حالة مسودة");
    }
  });

  it("an unsafe/unexpected error code is collapsed to the generic Arabic message — internals never leak to the client", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "23505", message: "duplicate key value violates unique constraint \"settlement_batches_pkey\"" } });
    const result = await finalizeSettlementBatchAction({ id: BATCH_ID, row_version: 1, selected_sources: [{ source_kind: "sale", source_event_id: SOURCE_EVENT_ID }] });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error).toBe("حدث خطأ غير متوقع. الرجاء المحاولة مرة أخرى.");
      expect(result.error).not.toContain("constraint");
    }
  });

  it("cancel_settlement_batch's own P0001 rejection ('still has unreversed bank movements') surfaces unchanged", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "لا يمكن إلغاء دفعة التسوية قبل عكس كل حركاتها البنكية" } });
    const result = await cancelSettlementBatchAction({ id: BATCH_ID, row_version: 2, cancellation_business_date: "2026-08-20", reason: "محاولة إلغاء" });
    expect(result.success).toBe(false);
    if (!result.success) {
      expect(result.error).toBe("لا يمكن إلغاء دفعة التسوية قبل عكس كل حركاتها البنكية");
    }
  });
});

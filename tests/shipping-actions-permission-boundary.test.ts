import { describe, expect, it, vi, beforeEach } from "vitest";

// Hotfix 5.1.2 item 4 — "correct_status-only permission boundary": a real
// regression test exercising addShipmentStatusEventAction ITSELF (not a
// component that merely mocks the action away, as every other test in this
// suite does), proving the Hotfix 5.1.1 item 4 fix — requireAnyPermission
// (not requirePermission) — is what actually gates it. A future accidental
// revert to `requirePermission("shipments.update_status")` would silently
// re-lock out a correct_status-only actor; this test fails immediately if
// that regression is reintroduced, without needing a live database.

// vi.mock(...) factories are hoisted above ALL top-level code in this file
// (including const declarations) — a factory that closes over a plain
// top-level `const` throws a TDZ ReferenceError at import time. vi.hoisted()
// is the documented escape hatch: its own callback runs at hoist time too,
// so the mocks it returns are safely initialized before any vi.mock()
// factory (or the later `import` below) ever runs.
const { requireAnyPermission, requirePermission } = vi.hoisted(() => ({
  requireAnyPermission: vi.fn(),
  requirePermission: vi.fn(),
}));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission, requireAnyPermission }));

const { revalidatePath } = vi.hoisted(() => ({ revalidatePath: vi.fn() }));
vi.mock("next/cache", () => ({ revalidatePath }));

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({ rpc: rpcMock }),
}));

import { addShipmentStatusEventAction } from "@/features/shipping/actions";

const VALID_INPUT = {
  shipment_id: "11111111-1111-1111-1111-111111111111",
  row_version: 1,
  new_status: "ready_for_pickup" as const,
  event_business_date: "2026-08-19",
};

describe("addShipmentStatusEventAction — correct_status-only permission boundary (Hotfix 5.1.2 item 4, regression for Hotfix 5.1.1 item 4)", () => {
  beforeEach(() => {
    requireAnyPermission.mockReset();
    requirePermission.mockReset();
    rpcMock.mockReset();
  });

  it("gates on requireAnyPermission(['shipments.update_status', 'shipments.correct_status']) — NOT a single requirePermission('shipments.update_status') call", async () => {
    requireAnyPermission.mockResolvedValue({ user: { id: "actor-1" } });
    rpcMock.mockResolvedValue({ data: [{ row_version: 2 }], error: null });

    await addShipmentStatusEventAction(VALID_INPUT);

    expect(requireAnyPermission).toHaveBeenCalledTimes(1);
    expect(requireAnyPermission).toHaveBeenCalledWith(["shipments.update_status", "shipments.correct_status"]);
    // The old, buggy gate must never be called at all — asserting its
    // absence is the actual regression guard (a revert to the single-
    // permission gate would still pass a looser "was requireAnyPermission
    // called" check unless we also assert requirePermission was NOT).
    expect(requirePermission).not.toHaveBeenCalled();
  });

  it("a correct_status-only actor (simulated: requireAnyPermission resolves normally, exactly as it would for either permission) reaches the RPC — the Server Action itself imposes no narrower gate than the DB", async () => {
    requireAnyPermission.mockResolvedValue({ user: { id: "correct-status-only-actor" } });
    rpcMock.mockResolvedValue({ data: [{ row_version: 2 }], error: null });

    const result = await addShipmentStatusEventAction(VALID_INPUT);

    expect(result.success).toBe(true);
    expect(rpcMock).toHaveBeenCalledWith(
      "add_shipment_status_event",
      expect.objectContaining({ p_shipment_id: VALID_INPUT.shipment_id, p_new_status: VALID_INPUT.new_status }),
    );
  });

  it("an actor holding NEITHER permission is rejected before the RPC is ever reached (requireAnyPermission's own redirect/throw propagates, no silent fallthrough)", async () => {
    requireAnyPermission.mockRejectedValue(new Error("NEXT_REDIRECT;replace;/403"));

    await expect(addShipmentStatusEventAction(VALID_INPUT)).rejects.toThrow();
    expect(rpcMock).not.toHaveBeenCalled();
  });
});

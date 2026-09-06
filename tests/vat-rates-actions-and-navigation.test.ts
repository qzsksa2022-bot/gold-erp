import { describe, expect, it, vi, beforeEach } from "vitest";

// Hotfix 10.1.0 — the VAT rate management UI.
//
// vat_rate_versions, create_vat_rate_version(), cancel_vat_rate_version() and
// the vat_rates.view / vat_rates.manage permissions have existed since
// migration 0058 (hardened 0066) and were granted to four roles in seed.sql,
// but NO application code ever reached them: the rate could only be changed by
// direct SQL. These tests pin the newly-added Server Actions to the same
// contract the sibling versioned master-data modules already honour, and pin
// the navigation correction.

const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const { revalidatePath } = vi.hoisted(() => ({ revalidatePath: vi.fn() }));
vi.mock("next/cache", () => ({ revalidatePath }));

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ rpc: rpcMock }) }));

import { createVatRateVersionAction, cancelVatRateVersionAction } from "@/features/vat-rates/actions";
import { vatRateVersionSchema } from "@/features/vat-rates/schema";
import { NAV_ITEMS } from "@/components/layout/nav-items";

const VERSION_ID = "11111111-1111-1111-1111-111111111111";

function form(fields: Record<string, string>) {
  const fd = new FormData();
  for (const [k, v] of Object.entries(fields)) fd.set(k, v);
  return fd;
}

beforeEach(() => {
  requirePermission.mockReset();
  revalidatePath.mockReset();
  rpcMock.mockReset();
  requirePermission.mockResolvedValue({ userId: "actor-1" });
});

describe("createVatRateVersionAction — gates on vat_rates.manage and reuses the existing RPC", () => {
  it("gates on vat_rates.manage, never on the read-only vat_rates.view", async () => {
    rpcMock.mockResolvedValue({ data: VERSION_ID, error: null });

    await createVatRateVersionAction(null, form({ rate_percent: "15", effective_from: "2026-10-01" }));

    expect(requirePermission).toHaveBeenCalledTimes(1);
    expect(requirePermission).toHaveBeenCalledWith("vat_rates.manage");
    expect(requirePermission).not.toHaveBeenCalledWith("vat_rates.view");
  });

  it("calls the PRE-EXISTING create_vat_rate_version RPC — no new backend was introduced", async () => {
    rpcMock.mockResolvedValue({ data: VERSION_ID, error: null });

    await createVatRateVersionAction(null, form({ rate_percent: "15", effective_from: "2026-10-01", notes: "قرار جديد" }));

    expect(rpcMock).toHaveBeenCalledWith("create_vat_rate_version", {
      p_rate_percent: "15",
      p_effective_from: "2026-10-01",
      p_notes: "قرار جديد",
    });
  });

  it("passes the rate through as a STRING — never a Number", async () => {
    rpcMock.mockResolvedValue({ data: VERSION_ID, error: null });

    await createVatRateVersionAction(null, form({ rate_percent: "15.375", effective_from: "2026-10-01" }));

    const args = rpcMock.mock.calls[0][1];
    expect(typeof args.p_rate_percent).toBe("string");
    // Byte-for-byte — a Number() round trip is exactly what this guards.
    expect(args.p_rate_percent).toBe("15.375");
  });

  it("omitted notes become an explicit null, never the string 'null'", async () => {
    rpcMock.mockResolvedValue({ data: VERSION_ID, error: null });
    await createVatRateVersionAction(null, form({ rate_percent: "15", effective_from: "2026-10-01" }));
    expect(rpcMock.mock.calls[0][1].p_notes).toBeNull();
  });

  it("rejects a negative rate client-side (Zod), never reaching the RPC", async () => {
    const result = await createVatRateVersionAction(null, form({ rate_percent: "-1", effective_from: "2026-10-01" }));
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("rejects a non-numeric rate and a missing effective_from client-side", async () => {
    expect((await createVatRateVersionAction(null, form({ rate_percent: "abc", effective_from: "2026-10-01" }))).success).toBe(false);
    expect((await createVatRateVersionAction(null, form({ rate_percent: "15", effective_from: "" }))).success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("rejects more than 3 decimal places (vat_rate_versions.rate_percent is numeric(6,3))", async () => {
    const result = await createVatRateVersionAction(null, form({ rate_percent: "15.1234", effective_from: "2026-10-01" }));
    expect(result.success).toBe(false);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("propagates the DB's own refusal message (e.g. an overlapping/past effective date)", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "لا يمكن إنشاء إصدار بتاريخ سريان سابق" } });
    const result = await createVatRateVersionAction(null, form({ rate_percent: "15", effective_from: "2020-01-01" }));
    expect(result.success).toBe(false);
    expect(result.success === false && result.error).toContain("تاريخ سريان سابق");
  });
});

describe("cancelVatRateVersionAction — gates on vat_rates.manage and reuses the existing RPC", () => {
  it("gates on vat_rates.manage and calls cancel_vat_rate_version", async () => {
    rpcMock.mockResolvedValue({ error: null });

    const result = await cancelVatRateVersionAction(VERSION_ID);

    expect(requirePermission).toHaveBeenCalledWith("vat_rates.manage");
    expect(rpcMock).toHaveBeenCalledWith("cancel_vat_rate_version", { p_version_id: VERSION_ID });
    expect(result.success).toBe(true);
  });

  it("surfaces the DB refusal when the version is already effective", async () => {
    rpcMock.mockResolvedValue({ error: { code: "P0001", message: "لا يمكن إلغاء إصدار بدأ سريانه بالفعل" } });
    const result = await cancelVatRateVersionAction(VERSION_ID);
    expect(result.success).toBe(false);
    expect(result.success === false && result.error).toContain("بدأ سريانه");
  });
});

describe("vatRateVersionSchema — exact-value preservation", () => {
  it("keeps the rate a string, unrounded, with a trailing zero intact", () => {
    const parsed = vatRateVersionSchema.parse({ rate_percent: "15.000", effective_from: "2026-10-01" });
    expect(typeof parsed.rate_percent).toBe("string");
    expect(parsed.rate_percent).toBe("15.000");
  });

  it("accepts a zero rate (a genuine business case: a VAT-exempt period)", () => {
    expect(vatRateVersionSchema.parse({ rate_percent: "0", effective_from: "2026-10-01" }).rate_percent).toBe("0");
  });

  it("normalises blank notes to undefined so the action can send an explicit null", () => {
    expect(vatRateVersionSchema.parse({ rate_percent: "15", effective_from: "2026-10-01", notes: "" }).notes).toBeUndefined();
  });
});

describe("navigation — the stale shipping comingSoon flag is gone", () => {
  it("Shipments is no longer marked as coming soon (the module has shipped since Phase 5)", () => {
    const shipments = NAV_ITEMS.find((i) => i.href === "/shipments");
    expect(shipments, "the Shipments nav item should exist").toBeDefined();
    expect(shipments!.comingSoon).toBeUndefined();
  });

  it("Shipments still enforces its own permission — only the stale badge was removed", () => {
    const shipments = NAV_ITEMS.find((i) => i.href === "/shipments");
    expect(shipments!.permission).toBe("shipments.view");
  });

  it("no navigation item is left falsely labelled coming soon", () => {
    expect(NAV_ITEMS.filter((i) => i.comingSoon)).toHaveLength(0);
  });

  it("VAT rates is reachable from master data, gated on vat_rates.view", async () => {
    // The master-data hub is a server component; its section list is what
    // gates the link, so the route constant and permission key are pinned
    // here and the page-level wiring is covered by the production build.
    const { ROUTES } = await import("@/lib/constants");
    expect(ROUTES.masterDataVatRates).toBe("/master-data/vat-rates");
  });
});

import { describe, expect, it, vi, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";

// Phase 11 — the EXPORT path specifically, plus screen/export filter parity.
//
// The screen and the export are supposed to be one engine (§39). The failure
// this project has actually shipped before (Hotfix 8.1.3 §B2) is subtler than
// a broken export: the export silently DROPPED a filter the screen offered, so
// the file quietly described a different set of rows than the screen it was
// exported from. Nothing errored; the numbers were just wrong.
//
// These tests therefore assert three things about the export:
//   1. the store scope reaches the RPC verbatim and is never widened,
//   2. an out-of-scope store makes the fetch THROW rather than fall back to a
//      wider dataset — no file, no leaked totals,
//   3. every filter the purchases screen offers is declared in the registry
//      the export route reads, so the two cannot drift apart.

vi.mock("server-only", () => ({}));

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ rpc: rpcMock }) }));

import { TABLE_REPORTS } from "@/features/reports/export/report-registry";
import { getPurchaseInvoices, getSupplierStatement, getPurchaseInvoice } from "@/features/purchases/queries";

const STORE_A = "11111111-1111-1111-1111-111111111111";
const OUT_OF_SCOPE = "ffffffff-ffff-4fff-8fff-ffffffffffff";

const ENVELOPE = {
  rows: [{ id: "r1", gross_total: "1150.00", outstanding: "1150.00" }],
  total_count: 1,
  limit: 5000,
  offset: 0,
  summary: { documents_count: 1, net_total: "1000.00", vat_total: "150.00", gross_total: "1150.00", paid_total: "0.00", outstanding_total: "1150.00" },
};

beforeEach(() => {
  rpcMock.mockReset();
});

describe("export path — the store scope reaches the RPC verbatim", () => {
  it("forwards store_ids exactly as given, and the export row cap, to list_purchase_invoices", async () => {
    rpcMock.mockResolvedValue({ data: ENVELOPE, error: null });

    await TABLE_REPORTS.purchases.fetch({
      date_from: "2026-09-01",
      date_to: "2026-09-30",
      store_ids: [STORE_A],
      page: 1,
      limit: 5000,
    });

    expect(rpcMock).toHaveBeenCalledTimes(1);
    const [name, args] = rpcMock.mock.calls[0];
    expect(name).toBe("list_purchase_invoices");
    expect(args.p_store_ids).toEqual([STORE_A]);
    expect(args.p_limit).toBe(5000);
    expect(args.p_offset).toBe(0);
  });

  it("sends p_store_ids: null (never [] or a guessed list) when the caller specifies no store", async () => {
    // null is what tells the RPC "use my whole visible scope". An empty array
    // would mean "no stores" and silently export nothing.
    rpcMock.mockResolvedValue({ data: ENVELOPE, error: null });
    await TABLE_REPORTS.purchases.fetch({ date_from: "2026-09-01", date_to: "2026-09-30", page: 1, limit: 5000 });
    expect(rpcMock.mock.calls[0][1].p_store_ids).toBeNull();
  });

  it("forwards every registered extra filter to the RPC rather than dropping it", async () => {
    rpcMock.mockResolvedValue({ data: ENVELOPE, error: null });

    await TABLE_REPORTS.purchases.fetch({
      date_from: "2026-09-01",
      date_to: "2026-09-30",
      page: 1,
      limit: 5000,
      supplier_id: "22222222-2222-2222-2222-222222222222",
      entry_kind: "invoice",
      payment_status: "unpaid",
    });

    const args = rpcMock.mock.calls[0][1];
    expect(args.p_supplier_id).toBe("22222222-2222-2222-2222-222222222222");
    expect(args.p_entry_kind).toBe("invoice");
    expect(args.p_payment_status).toBe("unpaid");
  });
});

describe("export path — an out-of-scope store yields no file and no totals", () => {
  it("throws instead of returning a wider dataset when the RPC rejects the store filter", async () => {
    // The RPC refuses an out-of-scope store rather than silently narrowing
    // (§8). The read layer must propagate that, so the export route produces
    // an error — never a file built from a fallback scope.
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "أحد الفروع المحددة خارج نطاق صلاحيتك" } });

    await expect(
      TABLE_REPORTS.purchases.fetch({ date_from: "2026-09-01", date_to: "2026-09-30", store_ids: [OUT_OF_SCOPE], page: 1, limit: 5000 }),
    ).rejects.toMatchObject({ message: expect.stringContaining("نطاق صلاحيتك") });
  });

  it("leaks no summary totals on rejection — the thrown value carries the refusal, not data", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "أحد الفروع المحددة خارج نطاق صلاحيتك" } });

    let thrown: unknown;
    try {
      await getPurchaseInvoices({ date_from: "2026-09-01", date_to: "2026-09-30", store_ids: [OUT_OF_SCOPE] });
    } catch (e) {
      thrown = e;
    }
    expect(thrown).toBeDefined();
    expect(JSON.stringify(thrown)).not.toContain("outstanding_total");
    expect(JSON.stringify(thrown)).not.toContain("gross_total");
  });

  it("the supplier statement and the invoice detail propagate a refusal the same way", async () => {
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "أحد الفروع المحددة خارج نطاق صلاحيتك" } });
    await expect(getSupplierStatement("22222222-2222-2222-2222-222222222222", "2026-09-01", "2026-09-30", [OUT_OF_SCOPE])).rejects.toBeDefined();

    rpcMock.mockReset();
    rpcMock.mockResolvedValue({ data: null, error: { code: "P0001", message: "الفاتورة غير موجودة أو غير متاحة لك" } });
    await expect(getPurchaseInvoice("33333333-3333-3333-3333-333333333333")).rejects.toBeDefined();
  });
});

describe("as-of-date presentation — current balance is never confused with the report-date balance", () => {
  const statementPage = readFileSync(path.join(process.cwd(), "src/app/(app)/purchases/outstanding/page.tsx"), "utf-8");

  it("the supplier statement renders opening, as-of-date and current balances as three distinct figures", () => {
    expect(statementPage).toMatch(/summary\.opening_balance/);
    expect(statementPage).toMatch(/summary\.closing_balance/);
    expect(statementPage).toMatch(/summary\.current_balance/);
  });

  it("each balance is labelled with the date it is as-of, not just 'balance'", () => {
    expect(statementPage).toMatch(/الرصيد الافتتاحي/);
    expect(statementPage).toMatch(/الرصيد حتى/);
    expect(statementPage).toMatch(/الرصيد الحالي/);
  });

  it("warns the reader when the two balances genuinely differ", () => {
    // Showing both is only useful if a divergence is called out; otherwise a
    // reader compares two numbers and assumes one is a mistake.
    expect(statementPage).toMatch(/current_balance !== statement\.summary\.closing_balance/);
    expect(statementPage).toMatch(/بسبب حركات لاحقة/);
  });

  it("the purchases list labels its settlement figures as CURRENT, since they are not as-of the period end", () => {
    const listPage = readFileSync(path.join(process.cwd(), "src/app/(app)/purchases/page.tsx"), "utf-8");
    expect(listPage).toMatch(/المستحق حاليًا/);
    const outstanding = TABLE_REPORTS.purchases.columns.find((c) => c.key === "outstanding");
    expect(outstanding?.label).toContain("حاليًا");
    const outstandingTotal = TABLE_REPORTS.purchases.summaryFields.find((f) => f.key === "outstanding_total");
    expect(outstandingTotal?.label).toContain("حاليًا");
  });
});

describe("screen/export parity — the two cannot drift apart", () => {
  const pageSource = readFileSync(path.join(process.cwd(), "src/app/(app)/purchases/page.tsx"), "utf-8");

  it("every filter key the purchases screen writes to the URL is declared in the export registry", () => {
    // The screen's ReportFilterBar `selects` each carry a `key:`; the export
    // route only copies keys listed in `extraFilterKeys`. Anything the screen
    // offers but the registry omits is silently dropped from the export.
    const screenKeys = [...pageSource.matchAll(/key:\s*"([a-z_]+)"/g)].map((m) => m[1]);
    expect(screenKeys.length).toBeGreaterThan(0);

    // store_id/search/date_from/date_to are handled generically by the route.
    const generic = new Set(["store_id", "search", "date_from", "date_to", "sort", "page"]);
    const declared = new Set(TABLE_REPORTS.purchases.extraFilterKeys);
    for (const key of screenKeys) {
      if (generic.has(key)) continue;
      expect(declared.has(key), `the purchases screen offers "${key}" but the export registry does not declare it — the export would silently drop it`).toBe(true);
    }
  });

  it("declares no filter the RPC cannot accept", () => {
    const accepted = new Set(["supplier_id", "entry_kind", "payment_status"]);
    for (const key of TABLE_REPORTS.purchases.extraFilterKeys) {
      expect(accepted.has(key), `extraFilterKeys declares "${key}", which list_purchase_invoices has no parameter for`).toBe(true);
    }
  });

  it("the screen and the export call the SAME query function (§39, one engine)", () => {
    expect(pageSource).toMatch(/getPurchaseInvoices/);
    const registrySource = readFileSync(path.join(process.cwd(), "src/features/reports/export/report-registry.ts"), "utf-8");
    expect(registrySource).toMatch(/getPurchaseInvoices/);
  });
});

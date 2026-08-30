// @vitest-environment node
//
// This route ultimately calls into export/pdf.ts (pdfkit), which needs a
// plain Node environment, not the project-wide jsdom default -- see
// tests/reports-export-generation.test.ts's own identical header comment
// for the full explanation: under jsdom, Vite/Vitest's module resolution
// prefers packages' "browser" field, which silently swaps pdfkit's real
// Node implementation (the one that actually calls fs.readFileSync on the
// embedded Amiri .ttf files) for its browser-bundled bundle, and font
// registration then fails with "Not a supported font format" even though
// the exact same code works correctly under plain Node. Overriding to
// "node" for just this file is correct, not a workaround for a real bug --
// this route handler is pure server-side Node code with no DOM dependency.
//
// Patch 8.1 §68-69 — REAL integration test for the export route handler
// itself (`GET /api/reports/export`), not just its individual pieces in
// isolation. Existing coverage before this file: `report-url-typed-
// filters.test.ts` unit-tests the query-param typing helpers alone,
// `reports-export-generation.test.ts` unit-tests `renderTableReportPdf`/
// `renderTableReportExcel` alone against hand-built envelopes, and the real
// HTTP/PostgREST script proves every report RPC's own behavior over the
// wire — but nothing before this file ever exercised the actual exported
// `GET` handler in `src/app/api/reports/export/route.ts` end to end: real
// query-string parsing -> `typedBooleanFilter` -> the real `TABLE_REPORTS`
// registry's `fetch()` wrapper -> real permission-based column redaction
// (§61/§62) -> the real PDF/Excel renderers -> a real, parseable file
// response. This file closes that gap.
//
// Follows this project's own established "actions-permission-boundary"
// convention (see e.g. tests/settlements-actions-permission-boundary.test.
// ts) for testing server-only Next.js code under Vitest: mock ONLY the two
// true I/O boundaries (`@/lib/permissions/guard`'s `requirePermission`,
// which normally reads real cookies, and `@/lib/supabase/server`'s
// `createClient`, which normally makes a real network call) with a
// realistic canned RPC response shaped exactly like a real report RPC's
// jsonb payload -- every other layer (route.ts's own logic, report-
// registry.ts's real column/permission definitions, excel.ts/pdf.ts's real
// renderers, sessionHasPermission's real pure logic) runs for real, un-
// mocked, through the actual production `GET` function.
import { describe, expect, it, vi, beforeEach } from "vitest";
import ExcelJS from "exceljs";
import { NextRequest } from "next/server";

const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({
    rpc: rpcMock,
    // Hotfix 8.1.1 §20-21 -- route.ts now also calls `getPublicBranding()`
    // (the same safe, pre-login-readable general-settings read the login
    // screen itself uses) to put the tenant's real system name into export
    // metadata. This chainable stub reproduces just enough of that one
    // `.from("system_settings").select("key, value").in("category", ...)`
    // shape -- an empty result set is fine, `getPublicBranding()` falls
    // back to APP_DEFAULTS, which is not what any test in this file asserts on.
    from: () => ({ select: () => ({ in: async () => ({ data: [], error: null }) }) }),
  }),
}));

// route.ts (and its own transitive imports) start with `import
// "server-only"` -- its default Node resolution condition points at a
// module that throws unconditionally; it only no-ops under the
// `"react-server"` condition Next.js's own bundler sets, which Vitest does
// not set. Mocked exactly as in tests/reports-export-generation.test.ts /
// tests/settlements-pagination.test.tsx / tests/reports-dashboard-
// components.test.tsx -- the established project convention for this.
vi.mock("server-only", () => ({}));

import { GET } from "@/app/api/reports/export/route";

const PROFIT_PERMISSIONS = new Set(["reports.view", "sales.view", "sales.view_profit", "reports.export_excel", "reports.export_pdf"]);
const NO_PROFIT_PERMISSIONS = new Set(["reports.view", "sales.view", "reports.export_excel", "reports.export_pdf"]);

function sessionWith(permissions: Set<string>) {
  return {
    userId: "actor-1",
    email: "exporter@example.invalid",
    profile: { status: "active" },
    permissions,
    isSuperAdmin: false,
  };
}

const SALES_RPC_ENVELOPE = {
  total_count: 1,
  limit: 5000,
  offset: 0,
  basis: undefined,
  summary: {
    orders_count: 1,
    items_count: 1,
    weight_grams: "2.500",
    sales_revenue: "1000.00",
    average_order_value: "1000.00",
    average_item_weight: "2.5000",
    net_sales_profit: "150.00",
  },
  rows: [
    {
      order_id: "order-1",
      order_number: "SALE-0000000001",
      sale_date: "2026-07-05",
      store_id: "store-1",
      store_name: "Test Store",
      employee_name: "—",
      payment_method_name: "Cash",
      collection_channel_name: "Direct",
      items_count: 1,
      weight_grams: "2.500",
      sales_revenue: "1000.00",
      net_sales_profit: "150.00",
    },
  ],
};

function rpcRouter(implementations: Record<string, unknown>) {
  return vi.fn(async (name: string) => {
    if (name in implementations) return { data: implementations[name], error: null };
    throw new Error(`unexpected rpc call in test: ${name}`);
  });
}

beforeEach(() => {
  requirePermission.mockReset();
  rpcMock.mockReset();
});

function exportUrl(params: Record<string, string>) {
  const url = new URL("http://localhost/api/reports/export");
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  return url.toString();
}

/**
 * Hotfix 8.1.1 §15-16 — a table export is now ALWAYS split across a
 * "Summary" sheet and one-or-more "Data" sheets (never one flat sheet).
 * Flattening EVERY worksheet's text (rather than just `worksheets[0]`, the
 * old single-sheet convention) keeps the redaction assertions below just as
 * strong as before the sheet split — a bug that redacted a column on only
 * ONE of the two sheets would otherwise go undetected.
 */
function allSheetsText(workbook: ExcelJS.Workbook): string {
  return workbook.worksheets
    .flatMap((sheet) => sheet.getSheetValues().flat())
    .map((v) => String(v ?? ""))
    .join(" | ");
}

describe("GET /api/reports/export — real route handler integration", () => {
  it("§68-69: a profit-permitted actor's Excel export includes the net_sales_profit column, built from a real RPC envelope through the real route+renderer pipeline", async () => {
    requirePermission.mockResolvedValue(sessionWith(PROFIT_PERMISSIONS));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [{ id: "store-1", code: "S1", name_ar: "متجر 1", status: "active" }],
        get_sales_report: SALES_RPC_ENVELOPE,
      }),
    );

    const req = new NextRequest(exportUrl({ report: "sales", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");

    const buf = Buffer.from(await res.arrayBuffer());
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buf as unknown as ArrayBuffer);
    expect(workbook.worksheets.map((w) => w.name)).toEqual(["Summary", "Data"]); // §15-16
    expect(allSheetsText(workbook)).toContain("صافي الربح");
  });

  it("§61/§62 CRITICAL (real route, not the renderer in isolation): a caller lacking sales.view_profit gets an Excel file with the net_sales_profit HEADER entirely absent, via the actual production redaction path in route.ts", async () => {
    requirePermission.mockResolvedValue(sessionWith(NO_PROFIT_PERMISSIONS));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [{ id: "store-1", code: "S1", name_ar: "متجر 1", status: "active" }],
        // A real get_sales_report() call for a non-profit actor never
        // returns the profit keys AT ALL (§79 true key-absence) -- this
        // mock reproduces that contract exactly, never just omitting it by
        // accident.
        get_sales_report: {
          ...SALES_RPC_ENVELOPE,
          summary: { ...SALES_RPC_ENVELOPE.summary, net_sales_profit: undefined },
          rows: [{ ...SALES_RPC_ENVELOPE.rows[0], net_sales_profit: undefined }],
        },
      }),
    );

    const req = new NextRequest(exportUrl({ report: "sales", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);

    expect(res.status).toBe(200);
    const buf = Buffer.from(await res.arrayBuffer());
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buf as unknown as ArrayBuffer);
    expect(allSheetsText(workbook)).not.toContain("صافي الربح");
  });

  it("§68-69: the SAME real pipeline produces a structurally valid PDF (magic bytes + Content-Type) for format=pdf", async () => {
    requirePermission.mockResolvedValue(sessionWith(PROFIT_PERMISSIONS));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [{ id: "store-1", code: "S1", name_ar: "متجر 1", status: "active" }],
        get_sales_report: SALES_RPC_ENVELOPE,
      }),
    );

    const req = new NextRequest(exportUrl({ report: "sales", format: "pdf", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);

    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("application/pdf");
    const buf = Buffer.from(await res.arrayBuffer());
    expect(buf.subarray(0, 5).toString("ascii")).toBe("%PDF-");
  });

  it("§11/§60: total_count exceeding EXPORT_MAX_ROWS returns an explicit 422 error through the real route, never a silently truncated file", async () => {
    requirePermission.mockResolvedValue(sessionWith(PROFIT_PERMISSIONS));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [],
        get_sales_report: { ...SALES_RPC_ENVELOPE, total_count: 5001 },
      }),
    );

    const req = new NextRequest(exportUrl({ report: "sales", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);

    expect(res.status).toBe(422);
    const body = await res.json();
    expect(body.error).toBe("export_too_large");
    expect(body.total_count).toBe(5001);
  });

  it("§13 CRITICAL: total_count <= EXPORT_MAX_ROWS but rows.length under-reports it returns an explicit 422 export_incomplete_dataset, never a silently incomplete file", async () => {
    requirePermission.mockResolvedValue(sessionWith(PROFIT_PERMISSIONS));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [],
        // total_count says 3 rows exist, but the RPC only actually returned
        // 1 -- exactly the future-RPC-bug scenario §13 guards against.
        get_sales_report: { ...SALES_RPC_ENVELOPE, total_count: 3 },
      }),
    );

    const req = new NextRequest(exportUrl({ report: "sales", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);

    expect(res.status).toBe(422);
    const body = await res.json();
    expect(body.error).toBe("export_incomplete_dataset");
    expect(body.total_count).toBe(3);
    expect(body.rows_received).toBe(1);
  });

  /**
   * Hotfix 8.1.1 §11-14/§60 — explicit row-count BOUNDARY coverage for the
   * export cap raised 500 -> 5000. 51 and 1200 are ordinary values that sat
   * comfortably UNDER the OLD 500 cap and ABOVE it respectively (1200 would
   * have been wrongly rejected as "too large" before this hotfix); 501 is
   * one row past the OLD cap (the exact value that used to 422 and now must
   * not); 5000 is the NEW cap's own exact boundary (must still succeed);
   * 5001 (already covered by the "§11/§60: total_count exceeding..." test
   * above) is one row past the NEW cap and must still 422. Each row object
   * only needs the fields report-registry.ts's `sales` column set actually
   * reads — a real envelope carries far more, but the redaction/rendering
   * pipeline itself is already proven in the tests above; this block is
   * purely about the row-count guard's own boundary arithmetic.
   */
  function makeSalesRow(n: number) {
    return { ...SALES_RPC_ENVELOPE.rows[0], order_id: `order-${n}`, order_number: `SALE-${String(n).padStart(10, "0")}` };
  }

  it.each([51, 501, 1200, 5000])(
    "§11-14/§60: total_count=%i (a value only reachable under the RAISED 500->5000 cap for 501/1200) succeeds with a real, non-truncated export through the real route",
    async (n) => {
      requirePermission.mockResolvedValue(sessionWith(PROFIT_PERMISSIONS));
      const rows = Array.from({ length: n }, (_, i) => makeSalesRow(i + 1));
      rpcMock.mockImplementation(
        rpcRouter({
          report_visible_stores_lookup: [],
          get_sales_report: { ...SALES_RPC_ENVELOPE, total_count: n, limit: 5000, rows },
        }),
      );

      const req = new NextRequest(exportUrl({ report: "sales", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
      const res = await GET(req);

      expect(res.status).toBe(200);
      const buf = Buffer.from(await res.arrayBuffer());
      const workbook = new ExcelJS.Workbook();
      await workbook.xlsx.load(buf as unknown as ArrayBuffer);
      const dataSheet = workbook.worksheets.find((w) => w.name === "Data")!;
      // +1 for the header row (§18 frozen header row).
      expect(dataSheet.rowCount).toBe(n + 1);
    },
  );

  /**
   * Hotfix 8.1.2 §37-39 — the row-count boundary proof above (§11-14/§60)
   * only ever exercised `get_sales_report`. get_items_report()/
   * get_adjustments_report() share the exact SAME generic export pipeline
   * (route.ts -> resolveReportSections -> renderer, no report-specific
   * branching anywhere in the row-count-handling logic) but had never
   * themselves been driven past 500 rows through the real route+renderer
   * pipeline — this closes that gap for both, at 550 rows (comfortably
   * >500). Complements the genuinely-DB-backed real-Postgres proof in
   * supabase/tests/hotfix_8_1_2_row_count_proof.test.sql (which proves
   * these SAME two RPCs actually RETURN 550 real rows with a matching
   * total_count from real inserted data) — this test instead proves the
   * export RENDERING side of that claim never silently truncates it.
   */
  const ITEMS_RPC_ENVELOPE = {
    total_count: 1,
    limit: 5000,
    offset: 0,
    summary: { items_count: 1, units_sold: 1, weight_grams: "2.500", revenue: "1000.00", gross_profit: "150.00" },
    rows: [{ item_name: "Test Item", sku: "SKU-1", category_label: "Category", karat_label: "Karat", units_sold: 1, weight_grams: "2.500", revenue: "1000.00", gross_profit: "150.00" }],
  };
  const ADJUSTMENTS_RPC_ENVELOPE = {
    total_count: 1,
    limit: 5000,
    offset: 0,
    summary: { movements_count: 1, approved_count: 1, reversed_count: 0, customer_charge_effect: "50.00", gross_profit_effect: "30.00", net_profit_effect: "30.00" },
    rows: [
      {
        adjustment_number: "ADJ-0000000001",
        order_number: "SALE-0000000001",
        movement_date: "2026-07-05",
        movement_type: "approved",
        store_name: "Test Store",
        adjustment_type_label: "Service",
        customer_charge_effect: "50.00",
        net_profit_effect: "30.00",
      },
    ],
  };
  function makeItemRow(n: number) {
    return { ...ITEMS_RPC_ENVELOPE.rows[0], item_name: `RowProof Item ${n}`, sku: `SKU-${n}` };
  }
  function makeAdjustmentRow(n: number) {
    return { ...ADJUSTMENTS_RPC_ENVELOPE.rows[0], adjustment_number: `ADJ-${String(n).padStart(10, "0")}` };
  }

  it("§37-39: get_items_report at 550 rows (>500) exports a real, non-truncated Excel Data sheet through the real route+renderer pipeline", async () => {
    requirePermission.mockResolvedValue(sessionWith(PROFIT_PERMISSIONS));
    const rows = Array.from({ length: 550 }, (_, i) => makeItemRow(i + 1));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [],
        get_items_report: { ...ITEMS_RPC_ENVELOPE, total_count: 550, limit: 5000, rows },
      }),
    );

    const req = new NextRequest(exportUrl({ report: "items", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);

    expect(res.status).toBe(200);
    const buf = Buffer.from(await res.arrayBuffer());
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buf as unknown as ArrayBuffer);
    const dataSheet = workbook.worksheets.find((w) => w.name === "Data")!;
    expect(dataSheet.rowCount).toBe(551);
  });

  it("§37-39: get_adjustments_report at 550 rows (>500) exports a real, non-truncated Excel Data sheet through the real route+renderer pipeline", async () => {
    requirePermission.mockResolvedValue(sessionWith(PROFIT_PERMISSIONS));
    const rows = Array.from({ length: 550 }, (_, i) => makeAdjustmentRow(i + 1));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [],
        get_adjustments_report: { ...ADJUSTMENTS_RPC_ENVELOPE, total_count: 550, limit: 5000, rows },
      }),
    );

    const req = new NextRequest(exportUrl({ report: "adjustments", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);

    expect(res.status).toBe(200);
    const buf = Buffer.from(await res.arrayBuffer());
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buf as unknown as ArrayBuffer);
    const dataSheet = workbook.worksheets.find((w) => w.name === "Data")!;
    expect(dataSheet.rowCount).toBe(551);
  });

  it("§1/§5/§6-10: a genuine 3-section Payment Methods report resolves through the REAL resolver+route+renderer pipeline into a Summary sheet plus one Data sheet per section actually present in the envelope", async () => {
    requirePermission.mockResolvedValue(sessionWith(new Set(["reports.view", "reports.export_excel", "reports.export_pdf", "sales.view_profit"])));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [],
        get_payment_methods_report: {
          total_count: 1,
          limit: 5000,
          offset: 0,
          summary: { payment_method_pairs_count: 1, orders_count: 1, revenue: "1000.00", net_sales_profit: "150.00" },
          rows: [{ payment_method_id: "pm-1", payment_method_name: "Mada", collection_channel_name: null, orders_count: 1, revenue: "1000.00", payment_fees: "10.00", net_sales_profit: "150.00" }],
          // §79 -- both secondary sections genuinely present this time.
          refund_summary: { refund_methods_count: 1, refund_events_count: 1, actual_refunded_cash: "50.00" },
          refund_rows: [{ refund_method_id: "pm-1", refund_method_name: "Mada", events_count: 1, actual_refunded_cash: "50.00" }],
          settlement_summary: { settlement_routes_count: 1, settlement_batches_count: 1, settlement_expected: "900.00", settlement_actual: "900.00", settlement_variance: "0.00" },
          settlement_rows: [{ settlement_route_id: "r-1", route_name: "المسار الرئيسي", payment_method_name: "Mada", collection_channel_name: null, batches_count: 1, expected: "900.00", actual: "900.00", variance: "0.00" }],
        },
      }),
    );

    const req = new NextRequest(exportUrl({ report: "payment-methods", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);

    expect(res.status).toBe(200);
    const buf = Buffer.from(await res.arrayBuffer());
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buf as unknown as ArrayBuffer);
    expect(workbook.worksheets.map((w) => w.name)).toEqual(["Summary", "المبيعات (التحصيل الأصلي)", "الاسترداد النقدي الفعلي", "التسويات البنكية"]);
  });

  it("§79/§9: when the RPC omits the Settlements section entirely (actor lacks that domain permission at the DB level), the route resolves only the sections the envelope actually carries -- never a fabricated empty Settlements sheet", async () => {
    requirePermission.mockResolvedValue(sessionWith(new Set(["reports.view", "reports.export_excel", "reports.export_pdf", "sales.view_profit"])));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [],
        get_payment_methods_report: {
          total_count: 1,
          limit: 5000,
          offset: 0,
          summary: { payment_method_pairs_count: 1, orders_count: 1, revenue: "1000.00", net_sales_profit: "150.00" },
          rows: [{ payment_method_id: "pm-1", payment_method_name: "Mada", collection_channel_name: null, orders_count: 1, revenue: "1000.00", payment_fees: "10.00", net_sales_profit: "150.00" }],
          // No refund_rows/refund_summary/settlement_rows/settlement_summary keys at all (§79 true key-absence).
        },
      }),
    );

    const req = new NextRequest(exportUrl({ report: "payment-methods", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);

    expect(res.status).toBe(200);
    const buf = Buffer.from(await res.arrayBuffer());
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buf as unknown as ArrayBuffer);
    // Only ONE section resolved -> sheet named "Data" (§16), NOT the
    // section's own title -- that naming is reserved for when MORE than one
    // section is actually present (proven by the 3-section test above).
    expect(workbook.worksheets.map((w) => w.name)).toEqual(["Summary", "Data"]);
  });

  /**
   * Hotfix 8.1.3 Blocker 2 — Payment Methods export parity. The screen page
   * has offered a `payment_method_id` filter ("طريقة الدفع الأصلية", the
   * SALE's own / the settlement route's own payment method, 0225's
   * `p_payment_method_id` — distinct from the Actual Refund Cash section's
   * `refund_method_id`) since Hotfix 8.1.2 §31-33, and `ReportExportButtons`
   * forwards `location.search` verbatim, so the key always ARRIVED at the
   * export route. But `payment-methods.extraFilterKeys` did not list it, and
   * route.ts only copies the keys that registry entry names — so the export
   * silently dropped the filter and produced a WIDER dataset than the screen
   * it was exported from (§39/§44 screen/export parity).
   *
   * This asserts on the arguments of the REAL `get_payment_methods_report`
   * call the real route made through the real registry `fetch()` wrapper —
   * not on the registry array's contents, which would restate the fix rather
   * than prove it reaches the RPC.
   */
  it("Hotfix 8.1.3 B2 CRITICAL: payment_method_id from the export query string actually reaches get_payment_methods_report as p_payment_method_id", async () => {
    requirePermission.mockResolvedValue(sessionWith(new Set(["reports.view", "reports.export_excel", "reports.export_pdf", "sales.view_profit"])));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [],
        // An active non-skipped filter key makes resolveFilterLabels()
        // (§20-22) fan out to all nine lookups regardless of report slug.
        report_categories_lookup: [],
        report_karats_lookup: [],
        report_payment_methods_lookup: [{ id: "pm-1", name_ar: "مدى" }],
        report_collection_channels_lookup: [],
        report_shipping_carriers_lookup: [],
        report_shipping_zones_lookup: [],
        report_adjustment_types_lookup: [],
        report_settlement_routes_lookup: [],
        report_employees_lookup: [],
        get_payment_methods_report: {
          total_count: 1,
          limit: 5000,
          offset: 0,
          summary: { payment_method_pairs_count: 1, orders_count: 1, revenue: "1000.00", net_sales_profit: "150.00" },
          rows: [{ payment_method_id: "pm-1", payment_method_name: "مدى", collection_channel_name: null, orders_count: 1, revenue: "1000.00", payment_fees: "10.00", net_sales_profit: "150.00" }],
        },
      }),
    );

    const req = new NextRequest(
      exportUrl({
        report: "payment-methods",
        format: "excel",
        date_from: "2026-07-01",
        date_to: "2026-07-31",
        payment_method_id: "pm-1",
        // The two filter keys that ALREADY worked, asserted alongside so a
        // future regression that swaps one for the other is caught too.
        refund_method_id: "pm-2",
        collection_channel_id: "cc-1",
      }),
    );
    const res = await GET(req);

    expect(res.status).toBe(200);
    const reportCall = rpcMock.mock.calls.find((c) => c[0] === "get_payment_methods_report");
    expect(reportCall).toBeDefined();
    expect(reportCall![1]).toMatchObject({
      p_date_from: "2026-07-01",
      p_date_to: "2026-07-31",
      p_payment_method_id: "pm-1",
      p_refund_method_id: "pm-2",
      p_collection_channel_id: "cc-1",
    });
  });

  it("Hotfix 8.1.3 B2: an ABSENT payment_method_id still reaches the RPC as an explicit null (never the string \"undefined\"), so the unfiltered export stays unfiltered", async () => {
    requirePermission.mockResolvedValue(sessionWith(new Set(["reports.view", "reports.export_excel", "reports.export_pdf", "sales.view_profit"])));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [],
        get_payment_methods_report: {
          total_count: 0,
          limit: 5000,
          offset: 0,
          summary: { payment_method_pairs_count: 0, orders_count: 0, revenue: "0.00", net_sales_profit: "0.00" },
          rows: [],
        },
      }),
    );

    const req = new NextRequest(exportUrl({ report: "payment-methods", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);

    expect(res.status).toBe(200);
    const reportCall = rpcMock.mock.calls.find((c) => c[0] === "get_payment_methods_report");
    expect(reportCall![1]).toMatchObject({ p_payment_method_id: null });
  });

  /**
   * Hotfix 8.1.3 B2 — the parity claim itself, stated as an invariant over
   * the registry rather than one report: every filter key the Payment
   * Methods SCREEN can put in the URL must be a key the export forwards.
   * This is what actually failed before the fix, and what would fail again
   * the next time a filter is added to the page but not to the registry.
   */
  it("Hotfix 8.1.3 B2: payment-methods' export filter keys cover every filter the screen page offers", async () => {
    const { TABLE_REPORTS } = await import("@/features/reports/export/report-registry");
    // The three `selects` rendered by src/app/(app)/reports/payment-methods/page.tsx.
    for (const screenFilterKey of ["payment_method_id", "refund_method_id", "collection_channel_id"]) {
      expect(TABLE_REPORTS["payment-methods"].extraFilterKeys).toContain(screenFilterKey);
    }
  });

  it("§2/§36: Returns report under basis=actual_cash resolves the actual_cash columns (refund_method_name/cash_effect), never the business_effect shape, through the real pipeline", async () => {
    requirePermission.mockResolvedValue(sessionWith(new Set(["reports.view", "returns.view", "reports.export_excel", "reports.export_pdf"])));
    rpcMock.mockImplementation(
      rpcRouter({
        report_visible_stores_lookup: [],
        // resolveFilterLabels() (§20-22) resolves EVERY active filter key's
        // label in one Promise.all of all 9 lookups, regardless of which
        // report is being exported -- `basis` (an active, non-skipped
        // filter key here) triggers the full fan-out, so every lookup must
        // have a canned response even though only `basis` itself is used.
        report_categories_lookup: [],
        report_karats_lookup: [],
        report_payment_methods_lookup: [],
        report_collection_channels_lookup: [],
        report_shipping_carriers_lookup: [],
        report_shipping_zones_lookup: [],
        report_adjustment_types_lookup: [],
        report_settlement_routes_lookup: [],
        report_employees_lookup: [],
        get_returns_report: {
          total_count: 1,
          limit: 5000,
          offset: 0,
          basis: "actual_cash",
          summary: { movements_count: 1, refund_events_count: 1, reversal_events_count: 0, cash_effect: "-200.00" },
          rows: [{ return_number: "RET-1", order_number: "SALE-1", movement_date: "2026-07-10", movement_type: "actual_refund", store_name: "متجر 1", refund_method_name: "Mada", cash_effect: "-200.00", refund_reconciliation_state: "pending" }],
        },
      }),
    );

    const req = new NextRequest(exportUrl({ report: "returns", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31", basis: "actual_cash" }));
    const res = await GET(req);

    expect(res.status).toBe(200);
    const buf = Buffer.from(await res.arrayBuffer());
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buf as unknown as ArrayBuffer);
    const text = allSheetsText(workbook);
    expect(text).toContain("طريقة الاسترداد الفعلية"); // actual_cash-only column
    expect(text).toContain("الأثر النقدي الفعلي"); // actual_cash-only column
    expect(text).not.toContain("أثر مبلغ الاسترداد المعتمد"); // business_effect-only column, must NOT leak in under this basis
  });

  it("rejects an unknown report slug with 404 before ever touching the database", async () => {
    requirePermission.mockResolvedValue(sessionWith(PROFIT_PERMISSIONS));
    const req = new NextRequest(exportUrl({ report: "not-a-real-report", format: "excel" }));
    const res = await GET(req);
    expect(res.status).toBe(404);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("rejects an invalid format with 400 before ever touching the database", async () => {
    requirePermission.mockResolvedValue(sessionWith(PROFIT_PERMISSIONS));
    const req = new NextRequest(exportUrl({ report: "sales", format: "csv" }));
    const res = await GET(req);
    expect(res.status).toBe(400);
    expect(rpcMock).not.toHaveBeenCalled();
  });

  it("§44: an actor holding reports.view + sales.view but NOT reports.export_excel is forbidden (403) from the Excel export specifically", async () => {
    requirePermission.mockResolvedValue(sessionWith(new Set(["reports.view", "sales.view"])));
    const req = new NextRequest(exportUrl({ report: "sales", format: "excel", date_from: "2026-07-01", date_to: "2026-07-31" }));
    const res = await GET(req);
    expect(res.status).toBe(403);
    expect(rpcMock).not.toHaveBeenCalled();
  });
});

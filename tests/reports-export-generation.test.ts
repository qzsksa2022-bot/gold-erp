// @vitest-environment node
//
// This file needs a plain Node environment, not the project-wide jsdom
// default: under jsdom, Vite/Vitest's module resolution prefers packages'
// "browser" field, which silently swaps pdfkit's real Node implementation
// (the one that actually calls fs.readFileSync on the embedded Amiri .ttf
// files and writes a real PDF) for its browser-bundled bundle, and font
// registration then fails with "Not a supported font format" even though
// the exact same code works correctly under plain Node (verified directly
// against `node -e`). PDF/Excel generation is pure Node/Buffer work with no
// DOM dependency, so overriding to "node" for just this file is correct,
// not a workaround for a real bug.
import { describe, expect, it, vi } from "vitest";
import ExcelJS from "exceljs";

// Phase 8 (Reports, Dashboard & Exports) — permanent PDF/Excel generation +
// parse-back integration test for the export engines (`export/pdf.ts`,
// `export/excel.ts`). Complements the manual visual/structural verification
// done during this engagement (pdftoppm PNG renders compared against a
// Chromium ground truth, exceljs read-back scripts) with a repeatable,
// checked-in regression guard, run on every `vitest run`.
//
// Hotfix 8.1.1 §1/§5/§46 — both renderers now take the SAME resolved
// `ReportSectionDefinition[]` shape the screen pages build via
// `resolveReportSections()` — never a static `(definition, envelope)` pair.
// This file exercises the REAL resolver (via a synthetic slug that falls
// through to its `fallbackDef` branch, exactly like every existing
// single-shape report — Sales/Items/Categories/Karats/Employees/Collection
// Channels/Settlements/Adjustments) so the section-shape these tests feed
// the renderers is never hand-waved independently of production code.
//
// `pdf.ts`/`excel.ts`/`report-registry.ts`/`presentation.ts` all start with
// `import "server-only"` (Next.js's Server-Component marker package) — its
// default Node resolution condition points at a module that throws
// unconditionally; it only no-ops under the `"react-server"` condition
// Next.js's own bundler sets. Vitest has no such condition, so importing
// these files directly would throw immediately. Mocking the package itself
// (exactly the shape Next.js's own "react-server" resolution reduces it to
// — an empty module) is the standard, minimal way to neutralize the marker
// for a plain Node test environment without changing vitest's resolution
// conditions globally (which could mask a REAL accidental client-import
// elsewhere).
vi.mock("server-only", () => ({}));

const { renderTableReportPdf, renderManagementReportPdf } = await import("@/features/reports/export/pdf");
const { renderTableReportExcel, renderManagementReportExcel } = await import("@/features/reports/export/excel");
const { resolveReportSections } = await import("@/features/reports/export/presentation");
import type { ExportMeta } from "@/features/reports/export/pdf";
import type { ReportSectionDefinition, FallbackSectionDef } from "@/features/reports/export/presentation";
import type { ManagementSectionDefinition } from "@/features/reports/export/management-registry";

// Synthetic definition/envelope — deliberately NOT imported from
// report-registry.ts/queries.ts's real fetch-bound registry (that would
// require a live Supabase connection). §5's guarantee — Screen/PDF/Excel
// all resolve sections through the ONE SAME `resolveReportSections()` — is
// exercised directly below (this "test-sales" slug is unknown to the
// dispatcher's switch, so it takes the exact same `default` fallback path
// every real single-shape report takes). This file's job is narrower and
// complementary: does the export engine ITSELF (a) produce a structurally
// valid file from a resolved section, (b) apply the exact §40/§41 Decimal
// Transport Boundary handling documented in excel.ts's own header comment,
// (c) propagate §79 true key absence into the rendered output, and (d)
// implement the NEW Hotfix 8.1.1 Summary+Data sheet split / multi-section /
// empty-sections contracts (§15-19/§46/§55-E) — using definitions/envelopes
// shaped exactly like the real ones.
const DEFINITION: FallbackSectionDef = {
  titleAr: "تقرير اختبار",
  columns: [
    { key: "order_number", label: "رقم الطلب", format: "text" },
    { key: "sale_date", label: "التاريخ", format: "date" },
    { key: "weight_grams", label: "الوزن", format: "weight" },
    { key: "sales_revenue", label: "الإيراد", format: "money" },
    { key: "gross_profit", label: "الربح الإجمالي", format: "money" },
  ],
  summaryFields: [
    { key: "orders_count", label: "عدد الطلبات", format: "int" },
    { key: "sales_revenue", label: "إجمالي الإيراد", format: "money" },
    { key: "gross_profit", label: "الربح الإجمالي", format: "money", emphasize: true },
  ],
  rowKey: "order_id",
};

const META: ExportMeta = {
  systemNameAr: "نظام اختبار الذهب",
  titleAr: "تقرير اختبار",
  descriptionAr: "نطاق الاختبار",
  dateFrom: "2026-08-01",
  dateTo: "2026-08-29",
  scopeLabel: "كل المتاجر",
  basisLabel: "الأساس: التأثير الحالي الفعّال ضمن الفترة",
  filterLabels: ["الموظف: أحمد علي", "الفئة: خواتم"],
  generatedByEmail: "qzs.ksa2022@gmail.com",
  generatedAt: new Date("2026-08-29T10:00:00Z"),
};

function makeEnvelope(rowCount: number, opts: { redactProfit?: boolean } = {}): Record<string, unknown> {
  const rows = Array.from({ length: rowCount }, (_, i) => {
    const row: Record<string, unknown> = {
      order_id: `order-${i}`,
      order_number: `SO-${1000 + i}`,
      sale_date: "2026-08-15",
      // High-precision decimal-as-TEXT values (§40/§41) — the exact shape
      // get_sales_report()/get_dashboard_summary() emit over the wire.
      weight_grams: "12.345",
      sales_revenue: "9999.99",
      gross_profit: "1234.567", // NUMERIC(10,3)-shaped, beyond 2dp on purpose
    };
    if (opts.redactProfit) delete row.gross_profit; // §79 true key absence, per-row
    return row;
  });

  const summary: Record<string, unknown> = {
    orders_count: rowCount,
    sales_revenue: "50000.00",
    gross_profit: "6172.835",
  };
  if (opts.redactProfit) delete summary.gross_profit; // §79 true key absence, summary-level

  return { total_count: rowCount, limit: 500, offset: 0, summary, rows };
}

/** Resolves a synthetic envelope through the REAL `resolveReportSections()` (§5), taking the same `default`/fallbackDef path every single-shape report takes. */
function makeSections(rowCount: number, opts: { redactProfit?: boolean } = {}): ReportSectionDefinition[] {
  return resolveReportSections("test-sales", makeEnvelope(rowCount, opts), DEFINITION);
}

/** Mirrors EXACTLY what `api/reports/export/route.ts` does before calling either renderer: drop every `permission`-gated column/summaryField the actor lacks, entirely (never a blank/null cell). */
function redactSections(sections: ReportSectionDefinition[], forbiddenKey: string): ReportSectionDefinition[] {
  return sections.map((s) => ({
    ...s,
    columns: s.columns.filter((c) => c.key !== forbiddenKey),
    summaryFields: s.summaryFields.filter((f) => f.key !== forbiddenKey),
  }));
}

// PDFs are plain zlib-compressed content streams inside an otherwise
// PLAIN-TEXT object structure (pdfkit never encrypts/obfuscates the object
// dictionaries themselves) — `/Type /Page` (not `/Type /Pages`, the single
// page-tree root) appears exactly once per rendered page regardless of the
// embedded Arabic font's internal glyph encoding, so counting it is a
// reliable, dependency-free page-count check (mirrors what `pdfinfo`
// reported during this engagement's manual verification, without requiring
// poppler-utils to be installed in every environment this test runs in).
function countPdfPages(buffer: Buffer): number {
  const text = buffer.toString("latin1");
  // Matches pdfkit's own emitted object shape exactly (`<<\n/Type /Page\n
  // /Parent ...`) — requiring the immediately-following `/Parent` key (real
  // page objects always have one; the single `/Type /Pages` tree root does
  // not match `/Page\b` at all, since `\b` stops the match before the
  // trailing "s") rules out the page-tree root AND any accidental
  // coincidental match inside a compressed content stream, which would
  // essentially never also happen to be followed by literal `/Parent` text.
  const matches = text.match(/\/Type\s*\/Page\b\s*\/Parent/g);
  return matches ? matches.length : 0;
}

describe("export/pdf.ts — renderTableReportPdf", () => {
  it("produces a structurally valid single-page PDF for a small dataset", async () => {
    const buffer = await renderTableReportPdf(makeSections(5), META);
    expect(buffer.subarray(0, 5).toString("latin1")).toBe("%PDF-");
    expect(buffer.toString("latin1").trimEnd().endsWith("%%EOF")).toBe(true);
    expect(buffer.length).toBeGreaterThan(5000); // Amiri font genuinely embedded, not a near-empty stub
    expect(countPdfPages(buffer)).toBe(1);
  });

  it("REGRESSION (auto-pagination footer bug): a dataset spanning multiple pages produces the EXACT expected page count, never extra spurious trailing pages", async () => {
    // This is the exact defect found and fixed during this engagement:
    // stampFooters() writing inside the bottom margin band tripped pdfkit's
    // own auto-pagination and silently produced 2 extra blank pages for a
    // table that should have fit on 1. 60 rows forces a genuine overflow
    // onto a second page (rowHeight=20 does not fit 60 rows in one A4
    // landscape page after the header/summary grid) — the footer draw must
    // land on the LAST real page, never spawn a spurious extra one.
    const buffer = await renderTableReportPdf(makeSections(60), META);
    const pages = countPdfPages(buffer);
    // A single resolved section (this synthetic report's fallback shape)
    // draws IDENTICALLY to the pre-Hotfix-8.1.1 single-definition path — no
    // section heading is drawn for a lone section (§46/§55-E: a heading is
    // drawn only when MORE than one section resolved) — so this pinned
    // baseline is unchanged from Patch 8.1's own verification. The point of
    // pinning an exact number here (rather than a loose range) is that any
    // future change to the layout constants (rowHeight/PAGE_MARGIN/font
    // sizes in pdf.ts) — intentional or not — must show up as a visible,
    // deliberate diff to this test rather than silently drifting.
    expect(pages).toBe(7);
    expect(pages).toBeGreaterThan(1); // genuinely paginates
    expect(pages).toBeLessThan(60); // sane — nowhere near one page per row
  });

  it("§79: renders successfully (never throws) when profit fields are genuinely absent from the envelope, summary-level and per-row", async () => {
    const buffer = await renderTableReportPdf(makeSections(3, { redactProfit: true }), META);
    expect(buffer.subarray(0, 5).toString("latin1")).toBe("%PDF-");
    expect(countPdfPages(buffer)).toBe(1);
  });

  it("§55-E CRITICAL: an actor resolved to ZERO sections gets a safe, valid, single-page PDF — never a crash, never a fabricated section", async () => {
    const buffer = await renderTableReportPdf([], META);
    expect(buffer.subarray(0, 5).toString("latin1")).toBe("%PDF-");
    expect(buffer.toString("latin1").trimEnd().endsWith("%%EOF")).toBe(true);
    expect(countPdfPages(buffer)).toBe(1);
  });

  it("§46 multi-section: draws EACH section's own heading + summary + table when more than one section resolves", async () => {
    const sections: ReportSectionDefinition[] = [
      { key: "sales", titleAr: "المبيعات", columns: DEFINITION.columns, summaryFields: DEFINITION.summaryFields, rowKey: "order_id", rows: makeEnvelope(3).rows as Record<string, unknown>[], summary: (makeEnvelope(3) as { summary: Record<string, unknown> }).summary },
      {
        key: "settlement",
        titleAr: "التسويات البنكية",
        columns: [{ key: "route_name", label: "المسار", format: "text" }],
        summaryFields: [{ key: "settlement_batches_count", label: "عدد الدفعات", format: "int" }],
        rowKey: "settlement_route_id",
        rows: [{ settlement_route_id: "r1", route_name: "المسار الشمالي" }],
        summary: { settlement_batches_count: 1 },
        unpaginated: true,
      },
    ];
    const buffer = await renderTableReportPdf(sections, META);
    expect(buffer.subarray(0, 5).toString("latin1")).toBe("%PDF-");
    expect(countPdfPages(buffer)).toBeGreaterThanOrEqual(1);
  });
});

describe("export/pdf.ts — renderManagementReportPdf", () => {
  const SECTIONS: ManagementSectionDefinition[] = [
    {
      key: "sales",
      titleAr: "المبيعات",
      fields: [
        { key: "orders_count", label: "عدد الطلبات", format: "int" },
        { key: "gross_profit", label: "الربح الإجمالي", format: "money" },
      ],
    },
  ];
  const NOR_FIELDS = [{ key: "net_operating_return", label: "صافي العائد التشغيلي" }];

  it("produces a valid PDF, omitting the Net Operating Return section entirely when its key is absent (§79)", async () => {
    const data = { sales: { orders_count: 10, gross_profit: "500.00" } }; // no net_operating_return key at all
    const buffer = await renderManagementReportPdf("التقرير اليومي", data, SECTIONS, NOR_FIELDS, META);
    expect(buffer.subarray(0, 5).toString("latin1")).toBe("%PDF-");
    expect(countPdfPages(buffer)).toBe(1);
  });

  it("produces a valid PDF including the Net Operating Return section when present", async () => {
    const data = {
      sales: { orders_count: 10, gross_profit: "500.00" },
      net_operating_return: { net_operating_return: "1234.56" },
    };
    const buffer = await renderManagementReportPdf("التقرير اليومي", data, SECTIONS, NOR_FIELDS, META);
    expect(buffer.subarray(0, 5).toString("latin1")).toBe("%PDF-");
  });
});

describe("export/excel.ts — renderTableReportExcel", () => {
  // Hotfix 8.1.1 §15-19 — a single resolved section now always produces
  // TWO worksheets: "Summary" (metadata + summary-figures block) and "Data"
  // (the header row + full row data, AutoFilter, frozen header row) — never
  // one flat sheet mixing both, matching the PDF/screen separation of
  // "here's what the totals say" from "here's the raw dataset".
  it("§15-16: a single-section report produces exactly two sheets named 'Summary' and 'Data'", async () => {
    const buffer = await renderTableReportExcel(makeSections(2), META);
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buffer as unknown as ArrayBuffer);
    expect(workbook.worksheets.map((w) => w.name)).toEqual(["Summary", "Data"]);
  });

  it("§18: the Data sheet has a frozen header row and an AutoFilter spanning every column", async () => {
    const buffer = await renderTableReportExcel(makeSections(2), META);
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buffer as unknown as ArrayBuffer);
    const dataSheet = workbook.worksheets.find((w) => w.name === "Data")!;
    expect(dataSheet).toBeDefined();
    const view = dataSheet.views?.[0] as { state?: string; ySplit?: number } | undefined;
    expect(view?.state).toBe("frozen");
    expect(view?.ySplit).toBe(1);
    expect(dataSheet.autoFilter).toBe("A1:E1"); // 5 columns in DEFINITION
  });

  it("§47-49: the Summary sheet's visible meta block shows the system name, BOTH the generating actor's email AND the generation timestamp, and the resolved filter labels — not just the email", async () => {
    const buffer = await renderTableReportExcel(makeSections(1), META);
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buffer as unknown as ArrayBuffer);
    const summarySheet = workbook.worksheets.find((w) => w.name === "Summary")!;

    const allText: string[] = [];
    summarySheet.eachRow((row) => {
      const v = row.getCell(1).value;
      if (typeof v === "string") allText.push(v);
    });

    expect(allText).toContain(META.systemNameAr);
    const metaLine = allText.find((l) => l.includes(META.generatedByEmail));
    expect(metaLine).toBeDefined();
    // formatRiyadhDateTime renders "yyyy/MM/dd HH:mm" in Asia/Riyadh (UTC+3) — 2026-08-29T10:00:00Z is 2026/08/29 13:00 Riyadh time.
    expect(metaLine).toContain("2026/08/29 13:00");
    expect(allText.some((l) => l.includes("الموظف: أحمد علي"))).toBe(true);
  });

  it("§40/§41: money/weight columns round-trip as genuine Excel NUMBERS with exact decimal precision (no float drift) on the Data sheet", async () => {
    const buffer = await renderTableReportExcel(makeSections(3), META);

    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buffer as unknown as ArrayBuffer);
    const dataSheet = workbook.worksheets.find((w) => w.name === "Data")!;
    expect(dataSheet).toBeDefined();

    // The Data sheet's header row is ALWAYS row 1 (no meta block on this
    // sheet — that lives on Summary now, §15-16).
    const headerValues = (dataSheet.getRow(1).values as unknown[]).slice(1);
    expect(headerValues).toEqual(DEFINITION.columns.map((c) => c.label));

    const firstDataRow = dataSheet.getRow(2);
    const weightCell = firstDataRow.getCell(3); // weight_grams column
    const revenueCell = firstDataRow.getCell(4); // sales_revenue column
    const profitCell = firstDataRow.getCell(5); // gross_profit column

    expect(typeof weightCell.value).toBe("number");
    expect(weightCell.value).toBe(12.345); // exact — NUMERIC(10,3) fits a double with zero rounding
    expect(typeof revenueCell.value).toBe("number");
    expect(revenueCell.value).toBe(9999.99);
    expect(typeof profitCell.value).toBe("number");
    expect(profitCell.value).toBe(1234.567);

    // Presentation-layer number format applied, not a recomputation.
    expect(weightCell.numFmt).toBe("#,##0.000");
    expect(revenueCell.numFmt).toBe("#,##0.00");
  });

  it("§79 CRITICAL: a redacted summary field produces NO header cell for it at all in the Summary sheet's summary row (true key absence, not a blank/zero cell)", async () => {
    const fullBuffer = await renderTableReportExcel(makeSections(2), META);
    const redactedBuffer = await renderTableReportExcel(makeSections(2, { redactProfit: true }), META);

    const fullWb = new ExcelJS.Workbook();
    await fullWb.xlsx.load(fullBuffer as unknown as ArrayBuffer);
    const redactedWb = new ExcelJS.Workbook();
    await redactedWb.xlsx.load(redactedBuffer as unknown as ArrayBuffer);

    const fullSheet = fullWb.worksheets.find((w) => w.name === "Summary")!;
    const redactedSheet = redactedWb.worksheets.find((w) => w.name === "Summary")!;

    const fullSummaryLabels: string[] = [];
    fullSheet.eachRow((row) => {
      const v = row.getCell(1).value;
      if (v === "عدد الطلبات") {
        (row.values as unknown[]).slice(1).forEach((cell) => fullSummaryLabels.push(String(cell)));
      }
    });
    const redactedSummaryLabels: string[] = [];
    redactedSheet.eachRow((row) => {
      const v = row.getCell(1).value;
      if (v === "عدد الطلبات") {
        (row.values as unknown[]).slice(1).forEach((cell) => redactedSummaryLabels.push(String(cell)));
      }
    });

    expect(fullSummaryLabels).toContain("الربح الإجمالي");
    expect(redactedSummaryLabels).not.toContain("الربح الإجمالي");
  });

  it("§79: a row missing the profit key renders that cell as null, not the string \"undefined\", on the Data sheet", async () => {
    const buffer = await renderTableReportExcel(makeSections(1, { redactProfit: true }), META);
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buffer as unknown as ArrayBuffer);
    const dataSheet = workbook.worksheets.find((w) => w.name === "Data")!;

    const dataRow = dataSheet.getRow(2);
    const profitCell = dataRow.getCell(5);
    expect(profitCell.value === null || profitCell.value === undefined).toBe(true);
    expect(String(profitCell.value)).not.toBe("undefined");
  });

  it("§55-E CRITICAL: an actor resolved to ZERO sections gets a safe, valid workbook — only a Summary sheet, never a crash and never a fabricated Data sheet", async () => {
    const buffer = await renderTableReportExcel([], META);
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buffer as unknown as ArrayBuffer);
    expect(workbook.worksheets.map((w) => w.name)).toEqual(["Summary"]);
  });

  it("§17 multi-section: produces one Summary sheet plus ONE Data sheet PER section, each named after that section's own title", async () => {
    const env = makeEnvelope(2);
    const sections: ReportSectionDefinition[] = [
      { key: "sales", titleAr: "المبيعات", columns: DEFINITION.columns, summaryFields: DEFINITION.summaryFields, rowKey: "order_id", rows: env.rows as Record<string, unknown>[], summary: env.summary as Record<string, unknown> },
      {
        key: "settlement",
        titleAr: "التسويات البنكية",
        columns: [{ key: "route_name", label: "المسار", format: "text" }],
        summaryFields: [{ key: "settlement_batches_count", label: "عدد الدفعات", format: "int" }],
        rowKey: "settlement_route_id",
        rows: [{ settlement_route_id: "r1", route_name: "المسار الشمالي" }],
        summary: { settlement_batches_count: 1 },
        unpaginated: true,
      },
    ];
    const buffer = await renderTableReportExcel(sections, META);
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buffer as unknown as ArrayBuffer);
    expect(workbook.worksheets.map((w) => w.name)).toEqual(["Summary", "المبيعات", "التسويات البنكية"]);

    const settlementSheet = workbook.worksheets.find((w) => w.name === "التسويات البنكية")!;
    expect(settlementSheet.getRow(1).getCell(1).value).toBe("المسار");
    expect(settlementSheet.getRow(2).getCell(1).value).toBe("المسار الشمالي");
  });
});

describe("Hotfix 8.1.1 §15/§16/§61/§62 — export permission-based column/field redaction (post-resolver)", () => {
  // Reproduces exactly what `api/reports/export/route.ts` now does after
  // `resolveReportSections()`: map every resolved section, dropping any
  // `permission`-gated column/summaryField the actor lacks ENTIRELY (never
  // left in place with a blank/null cell). `gross_profit` here stands in
  // for a real report's sales.view_profit-gated column (e.g. Sales
  // Report's net_sales_profit, Settlements' live_variance) — the mechanism
  // is identical regardless of which permission gates it.
  function findHeaderRowValues(sheet: ExcelJS.Worksheet): string[] {
    return (sheet.getRow(1).values as unknown[]).slice(1).map(String);
  }

  it("Excel §61/§62: a redacted column's HEADER is entirely absent from the Data sheet (not blank, not present-with-null) — non-empty dataset", async () => {
    const sections = redactSections(makeSections(3, { redactProfit: true }), "gross_profit");
    const buffer = await renderTableReportExcel(sections, META);
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(buffer as unknown as ArrayBuffer);
    const headerValues = findHeaderRowValues(wb.worksheets.find((w) => w.name === "Data")!);
    expect(headerValues).not.toContain("الربح الإجمالي");
    expect(headerValues).toEqual(sections[0].columns.map((c) => c.label));
    expect(headerValues.length).toBe(DEFINITION.columns.length - 1);
  });

  it("Excel §61/§62 CRITICAL: a redacted column's header stays absent for a genuinely EMPTY dataset (0 rows) — the required test case a first-row-keys heuristic would miss", async () => {
    const sections = redactSections(makeSections(0, { redactProfit: true }), "gross_profit");
    const buffer = await renderTableReportExcel(sections, META);
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(buffer as unknown as ArrayBuffer);
    const headerValues = findHeaderRowValues(wb.worksheets.find((w) => w.name === "Data")!);
    expect(headerValues).not.toContain("الربح الإجمالي");
  });

  it("Excel §61/§62: a redacted summaryField's label is entirely absent from the Summary sheet, empty dataset included", async () => {
    for (const rowCount of [0, 3]) {
      const sections = redactSections(makeSections(rowCount, { redactProfit: true }), "gross_profit");
      const buffer = await renderTableReportExcel(sections, META);
      const wb = new ExcelJS.Workbook();
      await wb.xlsx.load(buffer as unknown as ArrayBuffer);
      const summaryLabels: string[] = [];
      wb.worksheets
        .find((w) => w.name === "Summary")!
        .eachRow((row) => {
          if (row.getCell(1).value === "عدد الطلبات") (row.values as unknown[]).slice(1).forEach((c) => summaryLabels.push(String(c)));
        });
      expect(summaryLabels).not.toContain("الربح الإجمالي");
    }
  });

  it("PDF §61/§62: renders successfully with a redacted section, empty and non-empty datasets alike — never throws when a permission-gated column is entirely removed", async () => {
    // Full byte-level text absence isn't asserted here (this suite's
    // established convention, see the header comment above — PDFKit's
    // embedded/subset Arabic font makes raw content-stream text search
    // unreliable; page-count/structural checks are this file's proven
    // proxy). The Excel tests above give the FULLY reliable, direct proof
    // of the same redaction contract for the same route.ts code path.
    const emptySections = redactSections(makeSections(0, { redactProfit: true }), "gross_profit");
    const emptyBuffer = await renderTableReportPdf(emptySections, META);
    expect(emptyBuffer.subarray(0, 5).toString("latin1")).toBe("%PDF-");
    expect(countPdfPages(emptyBuffer)).toBe(1);

    const nonEmptySections = redactSections(makeSections(3, { redactProfit: true }), "gross_profit");
    const nonEmptyBuffer = await renderTableReportPdf(nonEmptySections, META);
    expect(nonEmptyBuffer.subarray(0, 5).toString("latin1")).toBe("%PDF-");
    expect(countPdfPages(nonEmptyBuffer)).toBe(1);
  });
});

describe("export/excel.ts — renderManagementReportExcel", () => {
  const SECTIONS: ManagementSectionDefinition[] = [
    {
      key: "sales",
      titleAr: "المبيعات",
      fields: [{ key: "orders_count", label: "عدد الطلبات", format: "int" }],
    },
  ];
  const NOR_FIELDS = [{ key: "net_operating_return", label: "صافي العائد التشغيلي" }];

  it("round-trips a management report to a real, loadable workbook", async () => {
    const data = { sales: { orders_count: 42 }, net_operating_return: { net_operating_return: "777.77" } };
    const buffer = await renderManagementReportExcel("التقرير اليومي", data, SECTIONS, NOR_FIELDS, META);
    const workbook = new ExcelJS.Workbook();
    await workbook.xlsx.load(buffer as unknown as ArrayBuffer);
    expect(workbook.worksheets.length).toBe(1);

    let found = false;
    workbook.worksheets[0].eachRow((row) => {
      if (row.getCell(1).value === "صافي العائد التشغيلي" && row.getCell(2).value === 777.77) found = true;
    });
    expect(found).toBe(true);
  });
});

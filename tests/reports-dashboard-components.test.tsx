import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import "@testing-library/jest-dom";
import { FileQuestion } from "lucide-react";

// Phase 8 (Reports, Dashboard & Exports) — component-level regression tests
// for the shared presentational building blocks every one of the 16 report
// pages + 4 Management Report pages + the Dashboard page renders through
// (report-registry.ts's/management-registry.ts's §39 single-source-of-truth
// guarantee is a TypeScript-checked structural fact by construction — this
// file's job is the RUNTIME behavior of the components themselves: §79 true
// key-absence rendering, §83 basis-indicator wording, money/weight/int/date
// formatting, and permission-gated visibility).
//
// management-registry.ts (imported transitively by NetOperatingReturnCard)
// starts with `import "server-only"` — mocked exactly as in
// tests/reports-export-generation.test.ts, for the same reason (Vitest has
// no "react-server" resolution condition, so the real package throws
// unconditionally).
vi.mock("server-only", () => ({}));

const { ReportBasisBadge, formatBasisLines } = await import("@/features/reports/components/report-basis-badge");
const { ReportSummaryCards } = await import("@/features/reports/components/report-summary-cards");
const { ReportTable } = await import("@/features/reports/components/report-table");
const { KpiSection } = await import("@/features/dashboard/components/kpi-section");
const { NetOperatingReturnCard } = await import("@/features/dashboard/components/net-operating-return-card");
const { TrendChart, formatTrendValue } = await import("@/features/dashboard/components/trend-chart");
const { ReportExportButtons } = await import("@/features/reports/components/report-export-buttons");
const { buildReportHref } = await import("@/features/reports/url");
const { formatSAR, formatGrams } = await import("@/lib/money");

beforeEach(() => {
  cleanup();
});

describe("report-basis-badge.tsx — formatBasisLines (§83 Report Basis Indicator)", () => {
  it("returns an empty array when no basis field is present at all (report has no basis concept)", () => {
    expect(formatBasisLines(undefined, undefined, undefined)).toEqual([]);
  });

  it("returns exactly one line, using the Arabic label map, for a single `basis` field", () => {
    expect(formatBasisLines("current_effective_impact_within_period")).toEqual(["الأساس: الأثر الفعلي الحالي ضمن الفترة"]);
  });

  it("falls back to the raw key verbatim if it is not in BASIS_LABELS_AR (never silently drops an unrecognized basis)", () => {
    expect(formatBasisLines("some_future_basis_kind")).toEqual(["some_future_basis_kind"]);
  });

  it("returns TWO labeled lines (rows + summary) for the dual-basis (Settlements Report) shape, never collapsing them into one", () => {
    const lines = formatBasisLines(undefined, "current_effective", "movements_during_period");
    expect(lines).toEqual(["الصفوف — الأساس: الحالة الفعلية الحالية", "الإجمالي — الأساس: الحركات خلال الفترة"]);
  });

  it("omits a dual-basis line whose OWN value is absent, without producing an empty/undefined entry", () => {
    const lines = formatBasisLines(undefined, "current_effective", undefined);
    expect(lines).toEqual(["الصفوف — الأساس: الحالة الفعلية الحالية"]);
  });

  it("`basis` takes precedence over row_basis/summary_basis when (hypothetically) both were somehow present", () => {
    expect(formatBasisLines("current_effective", "movements_during_period", "movements_during_period")).toEqual(["الأساس: الحالة الفعلية الحالية"]);
  });

  // Patch 8.1 §26-29/§30-32 regression guard — Returns' and COD's dual-basis
  // values (0208/0209) were introduced WITHOUT ever updating BASIS_LABELS_AR,
  // so the Returns report's own DEFAULT basis ('business_effect', shown on
  // every first page load) fell straight through to the raw-string fallback
  // above — a real, live "الأساس: business_effect" label leak. These three
  // values must each resolve to a translated line, never their raw key.
  it.each([
    ["business_effect", "الأساس: الأثر التجاري المعتمد"],
    ["actual_cash", "الأساس: التدفق النقدي الفعلي"],
    ["collection_transitions", "الأساس: حركات التحصيل الفعلية"],
  ])("resolves Returns/COD dual-basis value %s to its Arabic label, never the raw key", (basis, expected) => {
    expect(formatBasisLines(basis)).toEqual([expected]);
  });
});

describe("report-basis-badge.tsx — BASIS_SELECT_OPTIONS (Patch 8.1 §39-42 basis selector)", () => {
  it("offers exactly the two RPC-valid basis values for shipping, returns, and cod — never a value the RPC itself would reject", async () => {
    const { BASIS_SELECT_OPTIONS } = await import("@/features/reports/components/report-basis-badge");
    expect(BASIS_SELECT_OPTIONS.shipping.map((o) => o.value)).toEqual(["current_effective", "movements_during_period"]);
    expect(BASIS_SELECT_OPTIONS.returns.map((o) => o.value)).toEqual(["business_effect", "actual_cash"]);
    expect(BASIS_SELECT_OPTIONS.cod.map((o) => o.value)).toEqual(["current_effective", "collection_transitions"]);
  });
});

describe("ReportBasisBadge component", () => {
  it("renders nothing for a report with no basis field", () => {
    const { container } = render(<ReportBasisBadge />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders the single-basis line for a movements-ledger report", () => {
    render(<ReportBasisBadge basis="movements_during_period" />);
    expect(screen.getByText("الأساس: الحركات خلال الفترة")).toBeInTheDocument();
  });

  it("renders both dual-basis lines for the Settlements Report shape", () => {
    render(<ReportBasisBadge rowBasis="current_effective" summaryBasis="movements_during_period" />);
    expect(screen.getByText(/الصفوف — /)).toBeInTheDocument();
    expect(screen.getByText(/الإجمالي — /)).toBeInTheDocument();
  });
});

describe("ReportSummaryCards — §79 true key-absence + money/weight/int formatting", () => {
  const FIELDS = [
    { key: "orders_count", label: "عدد الطلبات", format: "int" as const },
    { key: "sales_revenue", label: "إجمالي الإيراد", format: "money" as const },
    { key: "weight_grams", label: "إجمالي الوزن", format: "weight" as const },
    { key: "gross_profit", label: "الربح الإجمالي", format: "money" as const, emphasize: true },
  ];

  it("renders nothing when the summary object has NONE of the configured fields", () => {
    const { container } = render(<ReportSummaryCards summary={{}} fields={FIELDS} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders ONLY the fields genuinely present in `summary` — a redacted (absent) field produces no card at all, not a '—' placeholder", () => {
    const summary = { orders_count: 12, sales_revenue: "50000.00" }; // gross_profit and weight_grams genuinely ABSENT
    render(<ReportSummaryCards summary={summary} fields={FIELDS} />);
    expect(screen.getByText("عدد الطلبات")).toBeInTheDocument();
    expect(screen.getByText("إجمالي الإيراد")).toBeInTheDocument();
    expect(screen.queryByText("الربح الإجمالي")).not.toBeInTheDocument();
    expect(screen.queryByText("إجمالي الوزن")).not.toBeInTheDocument();
  });

  it("formats a NUMERIC(10,3)-precision weight string exactly (no silent rounding within its real precision) via the SAME formatGrams() the rest of the app uses", () => {
    render(<ReportSummaryCards summary={{ weight_grams: "12.345" }} fields={FIELDS} />);
    expect(screen.getByText(formatGrams("12.345"))).toBeInTheDocument();
  });

  it("renders a genuinely-present-but-null field as an em dash '—', distinct from an absent field (which renders no card)", () => {
    render(<ReportSummaryCards summary={{ orders_count: null }} fields={FIELDS} />);
    expect(screen.getByText("—")).toBeInTheDocument();
  });

  it("formats an int field via ar-SA Intl grouping", () => {
    render(<ReportSummaryCards summary={{ orders_count: 1234 }} fields={FIELDS} />);
    expect(screen.getByText("١٬٢٣٤")).toBeInTheDocument();
  });
});

describe("ReportTable — §79 column-level redaction + cell formatting", () => {
  const COLUMNS = [
    { key: "order_number", label: "رقم الطلب", format: "text" as const },
    { key: "weight_grams", label: "الوزن", format: "weight" as const },
    { key: "sales_revenue", label: "الإيراد", format: "money" as const },
    { key: "gross_profit", label: "الربح الإجمالي", format: "money" as const },
    { key: "status", label: "الحالة", format: "badge" as const, labelMap: { approved: "معتمد" } },
  ];

  it("renders the EmptyState when rows is empty, not an empty table shell", () => {
    render(
      <ReportTable
        rows={[]}
        columns={COLUMNS}
        emptyIcon={FileQuestion}
        emptyTitle="لا توجد بيانات"
        emptyDescription="لا توجد نتائج مطابقة"
        rowKey="order_id"
      />,
    );
    expect(screen.getByText("لا توجد بيانات")).toBeInTheDocument();
  });

  it("§79: omits the gross_profit column ENTIRELY (no header, no cells) when the first row lacks the key — a redacted column, not a column of dashes", () => {
    const rows = [{ order_id: "1", order_number: "SO-1", weight_grams: "5.000", sales_revenue: "100.00", status: "approved" }]; // no gross_profit key
    render(<ReportTable rows={rows} columns={COLUMNS} emptyIcon={FileQuestion} emptyTitle="" emptyDescription="" rowKey="order_id" />);
    expect(screen.queryByText("الربح الإجمالي")).not.toBeInTheDocument();
    expect(screen.getByText("رقم الطلب")).toBeInTheDocument();
  });

  it("renders money/weight/badge cells with the correct formatting and Arabic label mapping", () => {
    const rows = [{ order_id: "1", order_number: "SO-1", weight_grams: "5.000", sales_revenue: "100.00", gross_profit: "25.50", status: "approved" }];
    const { container } = render(<ReportTable rows={rows} columns={COLUMNS} emptyIcon={FileQuestion} emptyTitle="" emptyDescription="" rowKey="order_id" />);
    expect(screen.getByText(formatGrams("5.000"))).toBeInTheDocument();
    // formatSAR()'s output embeds a real NBSP between amount and currency —
    // testing-library's default text normalizer collapses that to a plain
    // space before matching, so an exact getByText() against the raw
    // formatSAR() string (which still has the real NBSP) would spuriously
    // fail even though the rendered text is correct; comparing raw
    // textContent sidesteps that normalization entirely.
    expect(container.textContent).toContain(formatSAR("100.00"));
    expect(screen.getByText("معتمد")).toBeInTheDocument(); // badge labelMap applied, not the raw "approved"
  });

  it("renders a genuinely null cell value as an em dash, per-cell, without breaking the row", () => {
    const rows = [{ order_id: "1", order_number: "SO-1", weight_grams: null, sales_revenue: "100.00", gross_profit: "25.50", status: "approved" }];
    render(<ReportTable rows={rows} columns={COLUMNS} emptyIcon={FileQuestion} emptyTitle="" emptyDescription="" rowKey="order_id" />);
    expect(screen.getByText("—")).toBeInTheDocument();
  });
});

describe("KpiSection / KpiCard — §13 Comparison Engine + §79 redaction", () => {
  const FIELDS = [
    { key: "orders_count", label: "عدد الطلبات", format: "int" as const },
    { key: "net_shipping_result", label: "صافي نتيجة الشحن", format: "money" as const, invertColor: true },
  ];

  it("renders nothing when the section itself is undefined (actor lacks the domain permission entirely, §79)", () => {
    const { container } = render(<KpiSection title="المبيعات" section={undefined} fields={FIELDS} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders nothing when the section is present but none of its configured fields are (edge case: financial-only section, no-financials actor)", () => {
    const { container } = render(<KpiSection title="المبيعات" section={{}} fields={FIELDS} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("skips only the individual redacted field, rendering the rest of the section normally", () => {
    render(<KpiSection title="المبيعات" section={{ orders_count: 10 }} fields={FIELDS} />); // net_shipping_result absent
    expect(screen.getByText("عدد الطلبات")).toBeInTheDocument();
    expect(screen.queryByText("صافي نتيجة الشحن")).not.toBeInTheDocument();
  });

  it("shows an up-arrow in the SUCCESS color for a positive change on a normal (non-inverted) metric", () => {
    render(<KpiSection title="المبيعات" section={{ orders_count: 10, orders_count_pct_change: "12.5" }} fields={[FIELDS[0]]} />);
    const indicator = screen.getByText("12.5%");
    expect(indicator.closest("span")).toHaveClass("text-success");
  });

  it("inverts the color for a cost-like metric (invertColor): a positive change (cost went UP) renders as destructive, not success", () => {
    render(<KpiSection title="الشحن" section={{ net_shipping_result: "500.00", net_shipping_result_pct_change: "10.0" }} fields={[FIELDS[1]]} />);
    const indicator = screen.getByText("10.0%");
    expect(indicator.closest("span")).toHaveClass("text-destructive");
  });

  it("shows the 'no comparison data' message rather than a misleading 0%/arrow when pct_change is null", () => {
    render(<KpiSection title="المبيعات" section={{ orders_count: 10, orders_count_pct_change: null }} fields={[FIELDS[0]]} />);
    expect(screen.getByText("لا توجد بيانات مقارنة")).toBeInTheDocument();
  });
});

describe("NetOperatingReturnCard — §18/§20 formula + §79 redaction", () => {
  it("renders nothing when nor is undefined (actor lacks one of the four constituent permissions)", () => {
    const { container } = render(<NetOperatingReturnCard nor={undefined} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders nothing when nor is present but missing its own net_operating_return key (defensive — should never happen per the RPC's own contract, but must not crash)", () => {
    const { container } = render(<NetOperatingReturnCard nor={{ effective_net_sales_profit: "100.00" }} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders the formula with all three named components plus the total when fully present", () => {
    const nor = {
      effective_net_sales_profit: "1000.00",
      net_shipping_result: "-50.00",
      net_adjustments_result: "25.00",
      net_operating_return: "975.00",
    };
    const { container } = render(<NetOperatingReturnCard nor={nor} />);
    expect(screen.getByText(/صافي العائد التشغيلي — Net Operating Return/)).toBeInTheDocument();
    // The hero total AND the trailing "= total" line both render the same
    // formatted figure — at least twice, via the SAME formatSAR() the rest
    // of the app uses (avoids hard-coding ar-SA's Arabic-Indic digit glyphs).
    const totalFormatted = formatSAR(975);
    const occurrences = (container.textContent?.split(totalFormatted).length ?? 1) - 1;
    expect(occurrences).toBeGreaterThanOrEqual(2);
  });
});

describe("ReportExportButtons — §44 permission-gated visibility + href construction", () => {
  it("renders nothing when the actor holds neither export permission", () => {
    const { container } = render(<ReportExportButtons slug="sales" searchParams={{}} canPdf={false} canExcel={false} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("renders ONLY the PDF button when only reports.export_pdf is granted (hidden, not disabled, per §79-style convention)", () => {
    render(<ReportExportButtons slug="sales" searchParams={{}} canPdf={true} canExcel={false} />);
    expect(screen.getByText("PDF")).toBeInTheDocument();
    expect(screen.queryByText("Excel")).not.toBeInTheDocument();
  });

  it("forwards the page's current filters, plus report slug and format, verbatim into the export URL", () => {
    render(<ReportExportButtons slug="sales" searchParams={{ date_from: "2026-08-01", date_to: "2026-08-29", store_id: "abc-123" }} canPdf={true} canExcel={true} />);
    const pdfLink = screen.getByText("PDF").closest("a");
    expect(pdfLink).toHaveAttribute("href", expect.stringContaining("report=sales"));
    expect(pdfLink).toHaveAttribute("href", expect.stringContaining("format=pdf"));
    expect(pdfLink).toHaveAttribute("href", expect.stringContaining("date_from=2026-08-01"));
    expect(pdfLink).toHaveAttribute("href", expect.stringContaining("store_id=abc-123"));

    const excelLink = screen.getByText("Excel").closest("a");
    expect(excelLink).toHaveAttribute("href", expect.stringContaining("format=excel"));
  });

  it("ignores array-shaped/empty searchParams entries rather than emitting 'undefined' into the URL", () => {
    render(<ReportExportButtons slug="sales" searchParams={{ date_from: "", store_id: undefined, weird: ["a", "b"] } as never} canPdf={true} canExcel={false} />);
    const pdfLink = screen.getByText("PDF").closest("a");
    expect(pdfLink!.getAttribute("href")).not.toContain("date_from=");
    expect(pdfLink!.getAttribute("href")).not.toContain("weird=");
    expect(pdfLink!.getAttribute("href")).not.toContain("undefined");
  });
});

describe("url.ts — buildReportHref (pagination link builder)", () => {
  it("sets the page number and preserves ordinary filter values", () => {
    const href = buildReportHref("/reports/sales", { date_from: "2026-08-01", search: "SO-1" }, undefined, 3);
    expect(href).toBe("/reports/sales?date_from=2026-08-01&search=SO-1&page=3");
  });

  it("never leaks the internal store_ids array param into the URL (store_id is the singular, explicit param instead)", () => {
    const href = buildReportHref("/reports/sales", { date_from: "2026-08-01", store_ids: ["a", "b"] }, "a", 1);
    expect(href).not.toContain("store_ids");
    expect(href).toContain("store_id=a");
  });

  it("drops undefined/null/empty-string filter values instead of writing them as literal 'undefined'", () => {
    const href = buildReportHref("/reports/sales", { search: undefined, sort: null, employee_id: "" }, undefined, 1);
    expect(href).toBe("/reports/sales?page=1");
  });

  it("never includes an incoming `page` filter key twice (the explicit page argument always wins)", () => {
    const href = buildReportHref("/reports/sales", { page: 99, date_from: "2026-08-01" }, undefined, 2);
    expect(href).toBe("/reports/sales?date_from=2026-08-01&page=2");
  });
});

describe("trend-chart.tsx — formatTrendValue (Patch 8.1 §43-46 format-by-metric)", () => {
  it("formats a money value via formatSAR", () => {
    expect(formatTrendValue("1234.50", "money")).toBe(formatSAR("1234.50"));
  });

  it("formats an int value as a plain localized count, never money-formatted", () => {
    expect(formatTrendValue(7, "int")).toBe(new Intl.NumberFormat("ar-SA").format(7));
  });

  it("formats a weight value via formatGrams", () => {
    expect(formatTrendValue("12.345", "weight")).toBe(formatGrams("12.345"));
  });

  it("defaults to money formatting for an unrecognized format value (matches the component's own default prop)", () => {
    expect(formatTrendValue("50.00", "money")).toBe(formatSAR("50.00"));
  });
});

describe("trend-chart.tsx — TrendChart", () => {
  const buckets = [
    { bucket_start: "2026-08-01", bucket_end: "2026-08-01", bucket_label: "1 أغسطس", net_operating_return: "-200.00", orders_count: 3 },
    { bucket_start: "2026-08-02", bucket_end: "2026-08-02", bucket_label: "2 أغسطس", net_operating_return: "500.00", orders_count: 5 },
  ];

  it("renders nothing when buckets is empty", () => {
    const { container } = render(<TrendChart buckets={[]} title="اتجاه" />);
    expect(container.firstChild).toBeNull();
  });

  it("renders nothing when the requested valueKey is absent from the bucket shape (§79 true key-absence — e.g. a viewer without sales.view_profit)", () => {
    const { container } = render(<TrendChart buckets={buckets as never} valueKey="effective_net_sales_profit" title="اتجاه" />);
    expect(container.firstChild).toBeNull();
  });

  it("renders one bar per bucket, positive and negative values colored distinctly", () => {
    const { container } = render(<TrendChart buckets={buckets as never} valueKey="net_operating_return" format="money" title="اتجاه العائد" />);
    const rects = container.querySelectorAll("rect");
    expect(rects.length).toBe(2);
    expect(rects[0].getAttribute("class")).toContain("fill-destructive");
    expect(rects[1].getAttribute("class")).toContain("fill-accent");
  });

  it("formats each bar's tooltip using the `format` prop — an int-typed metric's tooltip is never SAR-formatted", () => {
    const { container } = render(<TrendChart buckets={buckets as never} valueKey="orders_count" format="int" title="اتجاه الطلبات" />);
    const titles = Array.from(container.querySelectorAll("title")).map((t) => t.textContent);
    expect(titles).toEqual([`1 أغسطس: ${new Intl.NumberFormat("ar-SA").format(3)}`, `2 أغسطس: ${new Intl.NumberFormat("ar-SA").format(5)}`]);
  });

  it("defaults `format` to money when omitted, preserving pre-§43-46 behavior for existing callers", () => {
    const { container } = render(<TrendChart buckets={buckets as never} valueKey="net_operating_return" title="اتجاه العائد" />);
    const titles = Array.from(container.querySelectorAll("title")).map((t) => t.textContent);
    expect(titles[0]).toBe(`1 أغسطس: ${formatSAR("-200.00")}`);
  });
});

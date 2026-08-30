import "server-only";

import PDFDocument from "pdfkit";
import path from "node:path";
import { formatSAR, formatGrams } from "@/lib/money";
import { decimalSign, decimalAbsFixed } from "@/lib/decimal";
import { formatRiyadhDate, formatRiyadhDateTime } from "@/lib/date";
import { MANAGEMENT_BREAKDOWN_COLUMNS, MANAGEMENT_BREAKDOWN_GRANULARITY_LABELS_AR } from "./management-registry";
import type { ManagementSectionDefinition } from "./management-registry";
import type { KpiFieldConfig } from "@/features/dashboard/components/kpi-section";
import type { ReportSectionDefinition } from "./presentation";

/**
 * Phase 8 §39/§40/§41 — PDF export engine.
 *
 * Hotfix 8.1.1 §5/§48 — renders from the SAME resolved `ReportSectionDefinition[]`
 * the screen pages build via `resolveReportSections()` — never a static
 * single-schema definition. A basis-varying report (Returns/Shipping/COD)
 * or a genuine multi-section report (Payment Methods) renders each section
 * with ITS OWN columns/labels/summary — repeated table headers, page
 * numbers, and the actor/generated-time footer all still apply uniformly
 * across every page of every section (§48).
 *
 * PDFKit 0.20+ ships its own Unicode bidi table and, via fontkit, Arabic
 * contextual glyph shaping for a registered OpenType font — passing raw
 * logical-order Arabic text straight into `doc.text(..., { align: 'right'
 * })` with the embedded Amiri font renders correctly shaped, correctly
 * right-to-left text with LTR numeral/Latin runs (order numbers, SAR
 * amounts, ISO dates) preserved in their own reading order.
 */

const FONT_DIR = path.join(process.cwd(), "src/assets/fonts");
const FONT_REGULAR = path.join(FONT_DIR, "Amiri-Regular.ttf");
const FONT_BOLD = path.join(FONT_DIR, "Amiri-Bold.ttf");

const PAGE_MARGIN = 36;

export interface ExportMeta {
  /** Hotfix 8.1.1 §20-21 — the tenant's own system/company name (read from the same safe, pre-login-readable general-settings path the login screen uses). */
  systemNameAr: string;
  titleAr: string;
  descriptionAr?: string;
  dateFrom: string;
  dateTo: string;
  scopeLabel: string;
  basisLabel?: string;
  /** Hotfix 8.1.2 §41 — the calendar-aware comparison range a Management Report's figures were compared against (e.g. "مقارنة بكامل الأسبوع السابق — الفترة السابقة: من ... إلى ..."), so PDF/Excel exports carry the SAME explicit basis/comparison metadata the screen's `ComparisonRangeNote` shows. */
  comparisonLabel?: string;
  /** Hotfix 8.1.1 §22 — every ACTIVE filter's resolved human label ("<Filter>: <Value>"), never a raw UUID when resolvable. */
  filterLabels?: string[];
  generatedByEmail: string;
  generatedAt: Date;
}

function newDoc(layout: "portrait" | "landscape"): PDFKit.PDFDocument {
  const doc = new PDFDocument({ size: "A4", layout, margin: PAGE_MARGIN, bufferPages: true });
  doc.registerFont("Amiri", FONT_REGULAR);
  doc.registerFont("Amiri-Bold", FONT_BOLD);
  return doc;
}

function drawHeader(doc: PDFKit.PDFDocument, meta: ExportMeta) {
  doc.font("Amiri").fontSize(8.5).fillColor("#888888").text(meta.systemNameAr, { align: "right" });
  doc.moveDown(0.15);
  doc.font("Amiri-Bold").fontSize(18).fillColor("#111111").text(meta.titleAr, { align: "right" });
  doc.moveDown(0.3);
  if (meta.descriptionAr) {
    doc.font("Amiri").fontSize(9).fillColor("#555555").text(meta.descriptionAr, { align: "right" });
    doc.moveDown(0.2);
  }
  doc.font("Amiri").fontSize(10).fillColor("#333333");
  doc.text(`الفترة: من ${formatRiyadhDate(meta.dateFrom)} إلى ${formatRiyadhDate(meta.dateTo)}   —   النطاق: ${meta.scopeLabel}`, { align: "right" });
  if (meta.basisLabel) {
    doc.moveDown(0.15);
    doc.font("Amiri").fontSize(9).fillColor("#8a6d1f").text(meta.basisLabel, { align: "right" });
  }
  if (meta.comparisonLabel) {
    doc.moveDown(0.15);
    doc.font("Amiri").fontSize(8.5).fillColor("#555555").text(meta.comparisonLabel, { align: "right" });
  }
  if (meta.filterLabels && meta.filterLabels.length > 0) {
    doc.moveDown(0.15);
    doc.font("Amiri").fontSize(8.5).fillColor("#555555").text(`الفلاتر المُطبّقة: ${meta.filterLabels.join(" — ")}`, { align: "right" });
  }
  doc.moveDown(0.3);
  const y = doc.y;
  doc.moveTo(PAGE_MARGIN, y).lineTo(doc.page.width - PAGE_MARGIN, y).strokeColor("#dddddd").lineWidth(1).stroke();
  doc.moveDown(0.6);
}

function stampFooters(doc: PDFKit.PDFDocument, meta: ExportMeta) {
  const range = doc.bufferedPageRange();
  // Writing inside the bottom margin band (deliberately, for a footer) would
  // otherwise trip pdfkit's own auto-pagination — `doc.text()` inserts a
  // NEW page whenever the target y falls past `page.height - margins.bottom`,
  // even for an absolute-positioned call. Zero the bottom margin for the
  // duration of the footer draw so it lands on the CURRENT page instead of
  // silently spawning extra blank trailing pages.
  const savedBottom = doc.page.margins.bottom;
  doc.page.margins.bottom = 0;
  for (let i = range.start; i < range.start + range.count; i++) {
    doc.switchToPage(i);
    const bottom = doc.page.height - PAGE_MARGIN + 14;
    doc.font("Amiri").fontSize(8).fillColor("#888888");
    doc.text(`تم الإنشاء بواسطة ${meta.generatedByEmail} — ${formatRiyadhDateTime(meta.generatedAt)}`, PAGE_MARGIN, bottom, {
      width: doc.page.width - PAGE_MARGIN * 2,
      align: "left",
      lineBreak: false,
    });
    doc.text(`الصفحة ${i - range.start + 1} من ${range.count}`, PAGE_MARGIN, bottom, {
      width: doc.page.width - PAGE_MARGIN * 2,
      align: "right",
      lineBreak: false,
    });
  }
  doc.page.margins.bottom = savedBottom;
}

function formatCellText(raw: unknown, format: string, labelMap?: Record<string, string>): string {
  if (raw === null || raw === undefined) return "—";
  switch (format) {
    case "money":
      return formatSAR(raw as string | number);
    case "weight":
      return formatGrams(raw as string | number);
    case "int":
      // no-float-ok: a count, never money/weight/percent — single-shot Intl.NumberFormat argument, not used in further arithmetic (§21).
      return new Intl.NumberFormat("ar-SA").format(Number(raw));
    case "date":
      return formatRiyadhDate(raw as string);
    case "badge":
    case "text":
      return labelMap?.[String(raw)] ?? String(raw);
    default:
      return String(raw);
  }
}

function drawSummaryGrid(doc: PDFKit.PDFDocument, summary: Record<string, unknown>, fields: { key: string; label: string; format: string }[]) {
  const visible = fields.filter((f) => f.key in summary);
  if (visible.length === 0) return;

  const perRow = 4;
  const gap = 8;
  const usableWidth = doc.page.width - PAGE_MARGIN * 2;
  const cardWidth = (usableWidth - gap * (perRow - 1)) / perRow;
  const cardHeight = 40;

  let col = 0;
  let rowTop = doc.y;

  for (const f of visible) {
    if (rowTop + cardHeight > doc.page.height - PAGE_MARGIN - 22) {
      doc.addPage();
      rowTop = PAGE_MARGIN;
    }
    const x = doc.page.width - PAGE_MARGIN - (col + 1) * cardWidth - col * gap;
    doc.roundedRect(x, rowTop, cardWidth, cardHeight, 4).fillAndStroke("#f7f7f5", "#e5e5e0");
    doc.font("Amiri").fontSize(7.5).fillColor("#777777").text(f.label, x + 6, rowTop + 6, { width: cardWidth - 12, align: "right" });
    doc.font("Amiri-Bold").fontSize(11).fillColor("#111111").text(formatCellText(summary[f.key], f.format), x + 6, rowTop + 18, { width: cardWidth - 12, align: "right" });
    col++;
    if (col === perRow) {
      col = 0;
      rowTop += cardHeight + gap;
    }
  }
  if (col !== 0) rowTop += cardHeight + gap;
  doc.y = rowTop + 4;
}

const FORMAT_WEIGHT: Record<string, number> = { text: 1.5, badge: 1.3, date: 1, int: 0.85, money: 1.1, weight: 1 };

function drawSectionTable(doc: PDFKit.PDFDocument, section: ReportSectionDefinition) {
  const columns = section.columns;
  const usableWidth = doc.page.width - PAGE_MARGIN * 2;
  const totalWeight = columns.reduce((sum, c) => sum + (FORMAT_WEIGHT[c.format] ?? 1), 0);
  const colWidths = columns.map((c) => ((FORMAT_WEIGHT[c.format] ?? 1) / totalWeight) * usableWidth);

  const rowHeight = 20;
  const headerHeight = 22;

  function drawTableHeader(y: number): number {
    let x = doc.page.width - PAGE_MARGIN;
    doc.rect(PAGE_MARGIN, y, usableWidth, headerHeight).fill("#2d2a24");
    doc.font("Amiri-Bold").fontSize(9).fillColor("#ffffff");
    columns.forEach((col, i) => {
      x -= colWidths[i];
      doc.text(col.label, x + 4, y + 6, { width: colWidths[i] - 8, align: "right" });
    });
    return y + headerHeight;
  }

  if (columns.length === 0) return;

  let y = drawTableHeader(doc.y);

  section.rows.forEach((row, rowIdx) => {
    if (y + rowHeight > doc.page.height - PAGE_MARGIN - 22) {
      doc.addPage();
      y = drawTableHeader(PAGE_MARGIN);
    }
    if (rowIdx % 2 === 1) {
      doc.rect(PAGE_MARGIN, y, usableWidth, rowHeight).fill("#f7f7f5");
    }
    let x = doc.page.width - PAGE_MARGIN;
    doc.font("Amiri").fontSize(8.5).fillColor("#222222");
    columns.forEach((col, i) => {
      x -= colWidths[i];
      const text = formatCellText(row[col.key], col.format, col.labelMap);
      doc.text(text, x + 4, y + 5, { width: colWidths[i] - 8, align: "right", ellipsis: true, lineBreak: false });
    });
    y += rowHeight;
  });

  doc.y = y;
}

export async function renderTableReportPdf(sections: ReportSectionDefinition[], meta: ExportMeta): Promise<Buffer> {
  const doc = newDoc("landscape");
  const chunks: Buffer[] = [];
  doc.on("data", (c: Buffer) => chunks.push(c));
  const done = waitForEnd(doc, chunks);

  drawHeader(doc, meta);

  // Hotfix 8.1.1 §55-E — an actor permitted only the base report.view (no
  // section-granting domain permission at all, e.g. Payment Methods) must
  // get a SAFE, valid, empty-looking document — never a crash and never a
  // fabricated section.
  if (sections.length === 0) {
    doc.font("Amiri").fontSize(11).fillColor("#888888").text("لا توجد أقسام مصرّح بعرضها لهذا المستخدم.", { align: "right" });
  }

  sections.forEach((section, i) => {
    if (i > 0) doc.moveDown(0.8);
    if (sections.length > 1) {
      doc.font("Amiri-Bold").fontSize(13).fillColor("#111111").text(section.titleAr, { align: "right" });
      doc.moveDown(0.3);
    }
    drawSummaryGrid(doc, section.summary, section.summaryFields);
    drawSectionTable(doc, section);
  });

  stampFooters(doc, meta);
  doc.end();

  return done;
}

export async function renderManagementReportPdf(
  titleAr: string,
  data: Record<string, unknown>,
  sections: ManagementSectionDefinition[],
  norFields: { key: string; label: string }[],
  meta: ExportMeta,
): Promise<Buffer> {
  const doc = newDoc("portrait");
  const chunks: Buffer[] = [];
  doc.on("data", (c: Buffer) => chunks.push(c));
  const done = waitForEnd(doc, chunks);

  drawHeader(doc, { ...meta, titleAr });

  const nor = data.net_operating_return as Record<string, unknown> | undefined;
  if (nor && "net_operating_return" in nor) {
    doc.font("Amiri-Bold").fontSize(12).fillColor("#111111").text("صافي العائد التشغيلي (Net Operating Return)", { align: "right" });
    doc.moveDown(0.2);
    for (const f of norFields) {
      if (!(f.key in nor)) continue;
      doc.font("Amiri").fontSize(10).fillColor("#333333").text(`${f.label}: ${formatCellText(nor[f.key], "money")}`, { align: "right" });
    }
    doc.moveDown(0.5);
  }

  for (const section of sections) {
    const sectionData = data[section.key] as Record<string, unknown> | undefined;
    if (!sectionData) continue;
    const visible = section.fields.filter((f) => f.key in sectionData);
    if (visible.length === 0) continue;

    doc.font("Amiri-Bold").fontSize(11).fillColor("#111111").text(section.titleAr, { align: "right" });
    doc.moveDown(0.15);
    drawKpiGrid(doc, sectionData, visible);
    doc.moveDown(0.4);
  }

  // Hotfix 8.1.2 §6-15/§41 — Weekly/Monthly/Yearly's period breakdown
  // (0222's `breakdown`/`breakdown_granularity`). Absent entirely for
  // Daily (no breakdown key at all, per 0222's own comment), so this
  // renders nothing for it — same true-key-absence contract (§79) every
  // other report component follows.
  const breakdown = data.breakdown as Record<string, unknown>[] | undefined;
  if (Array.isArray(breakdown) && breakdown.length > 0) {
    doc.moveDown(0.2);
    drawManagementBreakdownTable(doc, breakdown, (data.breakdown_granularity as string | undefined) ?? "day");
  }

  stampFooters(doc, meta);
  doc.end();

  return done;
}

/** Hotfix 8.1.2 §6-15/§41 — renders the Weekly/Monthly/Yearly period breakdown as a repeated-header table, mirroring `drawSectionTable`'s pagination pattern but sized for the management report's portrait layout and its own fixed `MANAGEMENT_BREAKDOWN_COLUMNS` (a column only appears when the first bucket actually carries that key, §79). */
function drawManagementBreakdownTable(doc: PDFKit.PDFDocument, breakdown: Record<string, unknown>[], granularity: string) {
  const columns = MANAGEMENT_BREAKDOWN_COLUMNS.filter((c) => c.key in breakdown[0]);
  if (columns.length === 0) return;

  const granLabel = MANAGEMENT_BREAKDOWN_GRANULARITY_LABELS_AR[granularity] ?? granularity;
  doc.font("Amiri-Bold").fontSize(11).fillColor("#111111").text(`التفصيل حسب ${granLabel}`, { align: "right" });
  doc.moveDown(0.15);

  const usableWidth = doc.page.width - PAGE_MARGIN * 2;
  const periodColWidth = usableWidth * 0.16;
  const dataColWidth = (usableWidth - periodColWidth) / columns.length;
  const rowHeight = 16;
  const headerHeight = 18;

  function drawHead(y: number): number {
    let x = doc.page.width - PAGE_MARGIN;
    doc.rect(PAGE_MARGIN, y, usableWidth, headerHeight).fill("#2d2a24");
    doc.font("Amiri-Bold").fontSize(7.5).fillColor("#ffffff");
    x -= periodColWidth;
    doc.text("الفترة", x + 3, y + 5, { width: periodColWidth - 6, align: "right" });
    columns.forEach((c) => {
      x -= dataColWidth;
      doc.text(c.label, x + 3, y + 5, { width: dataColWidth - 6, align: "right" });
    });
    return y + headerHeight;
  }

  let y = drawHead(doc.y);
  breakdown.forEach((row, i) => {
    if (y + rowHeight > doc.page.height - PAGE_MARGIN - 22) {
      doc.addPage();
      y = drawHead(PAGE_MARGIN);
    }
    if (i % 2 === 1) doc.rect(PAGE_MARGIN, y, usableWidth, rowHeight).fill("#f7f7f5");
    let x = doc.page.width - PAGE_MARGIN;
    doc.font("Amiri").fontSize(7.5).fillColor("#222222");
    x -= periodColWidth;
    const periodLabel = granularity === "month" || typeof row.bucket_start !== "string" ? String(row.bucket_label ?? "") : formatRiyadhDate(row.bucket_start);
    doc.text(periodLabel, x + 3, y + 4, { width: periodColWidth - 6, align: "right", lineBreak: false });
    columns.forEach((c) => {
      x -= dataColWidth;
      doc.text(formatCellText(row[c.key], c.format), x + 3, y + 4, { width: dataColWidth - 6, align: "right", ellipsis: true, lineBreak: false });
    });
    y += rowHeight;
  });

  doc.y = y;
}

function drawKpiGrid(doc: PDFKit.PDFDocument, section: Record<string, unknown>, fields: KpiFieldConfig[]) {
  const perRow = 3;
  const gap = 8;
  const usableWidth = doc.page.width - PAGE_MARGIN * 2;
  const cardWidth = (usableWidth - gap * (perRow - 1)) / perRow;
  const cardHeight = 46;

  let col = 0;
  let rowTop = doc.y;

  for (const f of fields) {
    const x = doc.page.width - PAGE_MARGIN - (col + 1) * cardWidth - col * gap;
    doc.roundedRect(x, rowTop, cardWidth, cardHeight, 4).fillAndStroke("#f7f7f5", "#e5e5e0");
    doc.font("Amiri").fontSize(7.5).fillColor("#777777").text(f.label, x + 6, rowTop + 6, { width: cardWidth - 12, align: "right" });
    doc.font("Amiri-Bold").fontSize(11).fillColor("#111111").text(formatCellText(section[f.key], f.format), x + 6, rowTop + 18, { width: cardWidth - 12, align: "right" });
    const pct = section[`${f.key}_pct_change`];
    if (pct !== null && pct !== undefined) {
      // §19 — sign and magnitude are computed via Decimal (`decimalSign`/
      // `decimalAbsFixed` in @/lib/decimal), never a bare `Number(pct)`
      // fed into a `>`/`===` comparison — `decimalAbsFixed` itself never
      // touches a JS double at all (decimal.js's own `.toFixed()`).
      const sign = decimalSign(pct as string | number);
      const signChar = sign > 0 ? "+" : sign < 0 ? "-" : "";
      doc.font("Amiri").fontSize(8).fillColor(sign === 0 ? "#888888" : sign > 0 ? "#1a7a3c" : "#b3261e");
      doc.text(`${signChar}${decimalAbsFixed(pct as string | number, 1)}%`, x + 6, rowTop + 32, { width: cardWidth - 12, align: "right" });
    }
    col++;
    if (col === perRow) {
      col = 0;
      rowTop += cardHeight + gap;
    }
  }
  if (col !== 0) rowTop += cardHeight + gap;
  doc.y = rowTop + 4;
}

/** pdfkit streams its output asynchronously even though page layout itself is synchronous CPU work — wait for the 'end' event (fired after `doc.end()` flushes every buffered page) before resolving with the fully-concatenated PDF buffer. */
function waitForEnd(doc: PDFKit.PDFDocument, chunks: Buffer[]): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    doc.on("end", () => resolve(Buffer.concat(chunks)));
    doc.on("error", reject);
  });
}

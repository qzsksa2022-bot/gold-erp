import "server-only";

import ExcelJS from "exceljs";
import { safeExcelNumber, toDecimal } from "@/lib/decimal";
import { formatRiyadhDate, formatRiyadhDateTime } from "@/lib/date";
import { MANAGEMENT_BREAKDOWN_COLUMNS, MANAGEMENT_BREAKDOWN_GRANULARITY_LABELS_AR } from "./management-registry";
import type { ManagementSectionDefinition } from "./management-registry";
import type { ExportMeta } from "./pdf";
import type { ReportSectionDefinition } from "./presentation";

/**
 * Phase 8 §39/§40/§41 — Excel export engine (exceljs).
 *
 * Hotfix 8.1.1 §5/§15-19 — renders from the SAME resolved
 * `ReportSectionDefinition[]` the screen pages build via
 * `resolveReportSections()` and the PDF export consumes — never an
 * independent column list, and never a single flat sheet for a
 * basis-varying or genuinely multi-section report (Returns/Shipping/COD/
 * Payment Methods). The workbook is always:
 *
 *   - ONE "Summary" sheet: system/report metadata (title, period, scope,
 *     basis, resolved filter labels, actor/generation stamp, §20-22) plus
 *     one summary-figures block per section (with a section heading when
 *     more than one section resolved, §17).
 *   - ONE "Data" sheet per resolved section — named "Data" when only one
 *     section resolved (single-shape reports: Sales/Items/Categories/
 *     Karats/Employees/Collection Channels/Settlements/Adjustments), or
 *     that section's own Arabic title (sanitized for Excel's sheet-name
 *     rules, §16-17) when more than one section resolved — each carrying
 *     its OWN header row, AutoFilter, and a frozen header row (§18).
 *
 * Money/weight values are parsed via `decimal.js` (never `parseFloat`)
 * straight from the RPC's TEXT values and written as genuine Excel
 * *numbers* (not text) so a report opened in Excel/Sheets supports native
 * SUM/AVERAGE over a column, with a `#,##0.00`/`#,##0.000` number format
 * applied for display — this is a presentation-layer conversion only
 * (identical to what `formatSAR`/`formatGrams` do for the screen), never a
 * recomputation of any financial figure (§1): the exact decimal text
 * already produced by the report RPC is parsed once and written as-is, and
 * money/weight columns in this schema (NUMERIC(14,2) SAR, NUMERIC(10,3)
 * grams) fit exactly in a double with no rounding.
 *
 * Excel needs no font embedding or bidi handling at all — it is Unicode
 * text in a spreadsheet cell, rendered by Excel/Sheets' own text engine;
 * `rightToLeft: true` in a sheet's `views` makes column A the rightmost
 * column and right-aligns the sheet's reading direction to match the rest
 * of the app.
 */

/**
 * Patch 8.1 §18 — writes a money/weight TEXT value as a genuine Excel
 * number when safe (per `safeExcelNumber()`'s precision-safety contract in
 * `@/lib/decimal`), or returns the exact decimal TEXT string as a fallback
 * when it is not — the caller must apply `numFmt` only in the numeric
 * case (a text cell must never carry a numeric display format). `scale` is
 * 2 for SAR money, 3 for gram weights (this schema's NUMERIC precisions).
 */
function toCellValue(raw: unknown, scale: number): { numeric: number | null } | { text: string } {
  const result = safeExcelNumber(raw, scale);
  return result.safe ? { numeric: result.value } : { text: result.text };
}

/**
 * Resolves one cell's Excel value + whether a numeric `numFmt` may be
 * applied to it, for every format this export engine renders. "int"
 * (counts) is exempt from the Decimal/§18 safety check — a count was never
 * money/weight and is nowhere near `Number.MAX_SAFE_INTEGER` — so it goes
 * through a direct `Number()`, matching the established no-float-guard
 * exception for counts/pixel indices. `defaultZero` reproduces the
 * pre-existing summary-row behavior (a present-but-null summary figure
 * displays as 0) without changing row-level behavior (a null/absent row
 * cell stays a genuinely empty cell, per the caller's own null guard).
 */
function cellValueFor(raw: unknown, format: string, opts: { defaultZero?: boolean } = {}): { value: number | string | null; isNumeric: boolean } {
  if (format === "text") return { value: String(raw ?? ""), isNumeric: false };
  if (format === "int") {
    if (raw === null || raw === undefined) return { value: opts.defaultZero ? 0 : null, isNumeric: true };
    // no-float-ok: a count, never money/weight/percent — Excel numeric cell value, not used in further arithmetic (§21).
    const n = Number(raw);
    return { value: Number.isFinite(n) ? n : null, isNumeric: true };
  }
  const scale = format === "weight" ? 3 : 2;
  const cell = toCellValue(raw, scale);
  if ("numeric" in cell) return { value: cell.numeric ?? (opts.defaultZero ? 0 : null), isNumeric: true };
  return { value: cell.text, isNumeric: false };
}

function styleHeaderRow(row: ExcelJS.Row) {
  row.eachCell((cell) => {
    cell.font = { name: "Arial", bold: true, color: { argb: "FFFFFFFF" } };
    cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: "FF2D2A24" } };
    cell.alignment = { horizontal: "right", vertical: "middle" };
  });
  row.height = 20;
}

function cellFormatFor(format: string): string | undefined {
  switch (format) {
    case "money":
      return "#,##0.00";
    case "weight":
      return "#,##0.000";
    case "int":
      return "#,##0";
    default:
      return undefined;
  }
}

/** Excel sheet names may not contain `\ / ? * [ ]` or `:`, may not be blank, and are capped at 31 characters. */
const INVALID_SHEET_CHARS = /[\\/*?:[\]]/g;
function sanitizeSheetName(name: string, fallback: string): string {
  const cleaned = name.replace(INVALID_SHEET_CHARS, " ").replace(/\s+/g, " ").trim();
  const base = cleaned || fallback;
  return base.slice(0, 31);
}

/** Converts a 1-based column index into its Excel column letter(s) (1 → "A", 27 → "AA") for building an `A1:<col>1` AutoFilter range. */
function excelColumnLetter(n: number): string {
  let s = "";
  let num = n;
  while (num > 0) {
    const rem = (num - 1) % 26;
    s = String.fromCharCode(65 + rem) + s;
    num = Math.floor((num - 1) / 26);
  }
  return s;
}

function writeMetaBlock(sheet: ExcelJS.Worksheet, meta: ExportMeta) {
  sheet.views = [{ rightToLeft: true }];
  // Hotfix 8.1.1 §20-22 — same visible metadata as the PDF header
  // (`drawHeader` in pdf.ts): system/company name, title, description,
  // period, scope, basis (when this report is basis-varying), every
  // resolved filter label, and the actor/generation stamp — so "what was
  // exported, under what filters, by whom, and when" reads identically
  // regardless of which format the file was exported as (§5/§48 parity).
  const lines: { text: string; bold?: boolean; size?: number; color?: string }[] = [
    { text: meta.systemNameAr, size: 8.5, color: "FF888888" },
    { text: meta.titleAr, bold: true, size: 14 },
    ...(meta.descriptionAr ? [{ text: meta.descriptionAr, size: 9, color: "FF555555" }] : []),
    { text: `الفترة: من ${formatRiyadhDate(meta.dateFrom)} إلى ${formatRiyadhDate(meta.dateTo)}`, size: 9 },
    { text: `النطاق: ${meta.scopeLabel}`, size: 9 },
    ...(meta.basisLabel ? [{ text: meta.basisLabel, size: 9, color: "FF8A6D1F" }] : []),
    ...(meta.comparisonLabel ? [{ text: meta.comparisonLabel, size: 8.5, color: "FF555555" }] : []),
    ...(meta.filterLabels && meta.filterLabels.length > 0 ? [{ text: `الفلاتر المُطبّقة: ${meta.filterLabels.join(" — ")}`, size: 8.5, color: "FF555555" }] : []),
    { text: `تم الإنشاء بواسطة ${meta.generatedByEmail} — ${formatRiyadhDateTime(meta.generatedAt)}`, size: 9, color: "FF555555" },
  ];
  lines.forEach((l) => {
    const row = sheet.addRow([l.text]);
    row.getCell(1).font = { name: "Arial", bold: l.bold ?? false, size: l.size ?? 11, color: { argb: l.color ?? "FF111111" } };
    row.getCell(1).alignment = { horizontal: "right" };
  });
  sheet.addRow([]);
}

/** Writes one section's summary-figures block (label row + value row) to the Summary sheet, preceded by a section heading only when more than one section resolved (§17 — a single-section report's own page/sheet title already says this). */
function writeSectionSummaryBlock(sheet: ExcelJS.Worksheet, section: ReportSectionDefinition, withHeading: boolean) {
  if (withHeading) {
    const headingRow = sheet.addRow([section.titleAr]);
    headingRow.getCell(1).font = { name: "Arial", bold: true, size: 12 };
    headingRow.getCell(1).alignment = { horizontal: "right" };
  }

  const summaryFields = section.summaryFields.filter((f) => f.key in section.summary);
  if (summaryFields.length === 0) {
    sheet.addRow([]);
    return;
  }

  const summaryHeaderRow = sheet.addRow(summaryFields.map((f) => f.label));
  styleHeaderRow(summaryHeaderRow);
  const summaryCells = summaryFields.map((f) => cellValueFor(section.summary[f.key], f.format, { defaultZero: true }));
  const summaryValueRow = sheet.addRow(summaryCells.map((c) => c.value));
  summaryFields.forEach((f, i) => {
    const cell = summaryValueRow.getCell(i + 1);
    cell.alignment = { horizontal: "right" };
    // §18: a TEXT-fallback cell (unsafe for a genuine Excel number) must
    // never also carry a numeric display format.
    if (summaryCells[i].isNumeric) {
      const fmt = cellFormatFor(f.format);
      if (fmt) cell.numFmt = fmt;
    }
  });
  sheet.addRow([]);
}

/** Writes one section's full row data to its own Data sheet: header row (styled), every row (money/weight/int as genuine numbers per §18), column widths, an AutoFilter over the header row, and a frozen header row (§18). */
function writeSectionDataSheet(workbook: ExcelJS.Workbook, sheetName: string, section: ReportSectionDefinition): void {
  const dataSheet = workbook.addWorksheet(sheetName);
  dataSheet.views = [{ state: "frozen", ySplit: 1, rightToLeft: true }];

  const columns = section.columns;
  const headerRow = dataSheet.addRow(columns.map((c) => c.label));
  styleHeaderRow(headerRow);

  for (const row of section.rows) {
    const rowCells = columns.map((col) => {
      const raw = row[col.key];
      if (raw === null || raw === undefined) return { value: null, isNumeric: false };
      switch (col.format) {
        case "money":
        case "weight":
        case "int":
          return cellValueFor(raw, col.format);
        case "date":
          return { value: formatRiyadhDate(raw as string), isNumeric: false };
        case "badge":
        case "text":
          return { value: col.labelMap?.[String(raw)] ?? String(raw), isNumeric: false };
        default:
          return { value: String(raw), isNumeric: false };
      }
    });
    const excelRow = dataSheet.addRow(rowCells.map((c) => c.value));
    columns.forEach((col, i) => {
      const cell = excelRow.getCell(i + 1);
      cell.alignment = { horizontal: "right" };
      if (rowCells[i].isNumeric) {
        const fmt = cellFormatFor(col.format);
        if (fmt) cell.numFmt = fmt;
      }
    });
  }

  columns.forEach((col, i) => {
    const width = col.format === "text" ? 22 : col.format === "badge" ? 16 : 14;
    dataSheet.getColumn(i + 1).width = width;
  });

  if (columns.length > 0) {
    dataSheet.autoFilter = `A1:${excelColumnLetter(columns.length)}1`;
  }
}

export function renderTableReportExcel(sections: ReportSectionDefinition[], meta: ExportMeta): Promise<Buffer> {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = meta.generatedByEmail;
  workbook.created = meta.generatedAt;

  const summarySheet = workbook.addWorksheet("Summary");
  writeMetaBlock(summarySheet, meta);

  // Hotfix 8.1.1 §55-E — Excel/PDF parity: an actor permitted only the base
  // report.view (no section-granting domain permission at all, e.g.
  // Payment Methods) must get a SAFE, valid workbook — a Summary sheet with
  // no data sheets, never a crash and never a fabricated section.
  if (sections.length === 0) {
    const row = summarySheet.addRow(["لا توجد أقسام مصرّح بعرضها لهذا المستخدم."]);
    row.getCell(1).font = { name: "Arial", italic: true, size: 10, color: { argb: "FF888888" } };
    row.getCell(1).alignment = { horizontal: "right" };
  }

  const usedSheetNames = new Set<string>(["Summary"]);
  sections.forEach((section, i) => {
    writeSectionSummaryBlock(summarySheet, section, sections.length > 1);

    const baseName = sections.length === 1 ? "Data" : sanitizeSheetName(section.titleAr, `Section ${i + 1}`);
    let sheetName = baseName;
    let suffix = 2;
    while (usedSheetNames.has(sheetName)) {
      sheetName = `${baseName.slice(0, 28)} (${suffix})`;
      suffix++;
    }
    usedSheetNames.add(sheetName);

    writeSectionDataSheet(workbook, sheetName, section);
  });

  return workbook.xlsx.writeBuffer().then((data) => Buffer.from(data));
}

export function renderManagementReportExcel(
  titleAr: string,
  data: Record<string, unknown>,
  sections: ManagementSectionDefinition[],
  norFields: { key: string; label: string }[],
  meta: ExportMeta,
): Promise<Buffer> {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = meta.generatedByEmail;
  workbook.created = meta.generatedAt;
  const sheet = workbook.addWorksheet(titleAr.slice(0, 31) || "Management Report");

  writeMetaBlock(sheet, { ...meta, titleAr });

  const nor = data.net_operating_return as Record<string, unknown> | undefined;
  if (nor && "net_operating_return" in nor) {
    const norHeader = sheet.addRow(["صافي العائد التشغيلي (Net Operating Return)"]);
    norHeader.getCell(1).font = { name: "Arial", bold: true, size: 12 };
    norHeader.getCell(1).alignment = { horizontal: "right" };
    for (const f of norFields) {
      if (!(f.key in nor)) continue;
      const row = sheet.addRow([f.label, cellValueFor(nor[f.key], "money", { defaultZero: true }).value]);
      row.getCell(1).alignment = { horizontal: "right" };
      row.getCell(2).alignment = { horizontal: "right" };
      row.getCell(2).numFmt = "#,##0.00";
    }
    sheet.addRow([]);
  }

  for (const section of sections) {
    const sectionData = data[section.key] as Record<string, unknown> | undefined;
    if (!sectionData) continue;
    const visible = section.fields.filter((f) => f.key in sectionData);
    if (visible.length === 0) continue;

    const sectionHeader = sheet.addRow([section.titleAr]);
    sectionHeader.getCell(1).font = { name: "Arial", bold: true, size: 11 };
    sectionHeader.getCell(1).alignment = { horizontal: "right" };

    const headerRow = sheet.addRow(["المؤشر", "القيمة الحالية", "نسبة التغيّر"]);
    styleHeaderRow(headerRow);

    for (const f of visible) {
      const pctRaw = sectionData[`${f.key}_pct_change`];
      // §19 — the percent ratio is computed via Decimal all the way through
      // the /100 division; `.toNumber()` is the legitimate final rendering
      // boundary (an Excel numeric cell requires a primitive number),
      // never an intermediate step used for further comparison/math.
      const pct = pctRaw === null || pctRaw === undefined ? null : toDecimal(pctRaw as string | number).div(100).toNumber();
      const valueCell = cellValueFor(sectionData[f.key], f.format === "money" ? "money" : "int", { defaultZero: true });
      const row = sheet.addRow([f.label, valueCell.value, pct]);
      row.getCell(1).alignment = { horizontal: "right" };
      row.getCell(2).alignment = { horizontal: "right" };
      if (valueCell.isNumeric) row.getCell(2).numFmt = f.format === "money" ? "#,##0.00" : "#,##0";
      row.getCell(3).alignment = { horizontal: "right" };
      if (pct !== null) row.getCell(3).numFmt = "+0.0%;-0.0%";
    }
    sheet.addRow([]);
  }

  sheet.getColumn(1).width = 28;
  sheet.getColumn(2).width = 18;
  sheet.getColumn(3).width = 14;

  // Hotfix 8.1.2 §6-15/§41 — Weekly/Monthly/Yearly's period breakdown
  // (0222's `breakdown`/`breakdown_granularity`) gets its OWN sheet, same
  // frozen-header + AutoFilter convention as `writeSectionDataSheet`.
  // Absent entirely for Daily (no breakdown key at all), so no sheet is
  // added for it — same true-key-absence contract (§79) every other
  // report export follows.
  const breakdown = data.breakdown as Record<string, unknown>[] | undefined;
  if (Array.isArray(breakdown) && breakdown.length > 0) {
    writeManagementBreakdownSheet(workbook, breakdown, (data.breakdown_granularity as string | undefined) ?? "day");
  }

  return workbook.xlsx.writeBuffer().then((data) => Buffer.from(data));
}

/** Hotfix 8.1.2 §6-15/§41 — one "التفصيل" sheet for the Weekly/Monthly/Yearly period breakdown, mirroring `writeSectionDataSheet`'s frozen-header/AutoFilter/RTL conventions with the management report's own fixed `MANAGEMENT_BREAKDOWN_COLUMNS` (a column only appears when the first bucket actually carries that key, §79). */
function writeManagementBreakdownSheet(workbook: ExcelJS.Workbook, breakdown: Record<string, unknown>[], granularity: string): void {
  const columns = MANAGEMENT_BREAKDOWN_COLUMNS.filter((c) => c.key in breakdown[0]);
  if (columns.length === 0) return;

  const granLabel = MANAGEMENT_BREAKDOWN_GRANULARITY_LABELS_AR[granularity] ?? granularity;
  const sheet = workbook.addWorksheet(sanitizeSheetName(`التفصيل حسب ${granLabel}`, "التفصيل"));
  sheet.views = [{ state: "frozen", ySplit: 1, rightToLeft: true }];

  const headerRow = sheet.addRow(["الفترة", ...columns.map((c) => c.label)]);
  styleHeaderRow(headerRow);

  for (const row of breakdown) {
    const periodLabel = granularity === "month" || typeof row.bucket_start !== "string" ? String(row.bucket_label ?? "") : formatRiyadhDate(row.bucket_start);
    const cells = columns.map((c) => cellValueFor(row[c.key], c.format));
    const excelRow = sheet.addRow([periodLabel, ...cells.map((c) => c.value)]);
    excelRow.getCell(1).alignment = { horizontal: "right" };
    columns.forEach((c, i) => {
      const cell = excelRow.getCell(i + 2);
      cell.alignment = { horizontal: "right" };
      if (cells[i].isNumeric) {
        const fmt = cellFormatFor(c.format);
        if (fmt) cell.numFmt = fmt;
      }
    });
  }

  sheet.getColumn(1).width = 14;
  columns.forEach((_c, i) => {
    sheet.getColumn(i + 2).width = 16;
  });
  sheet.autoFilter = `A1:${excelColumnLetter(columns.length + 1)}1`;
}

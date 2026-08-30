import "server-only";

import { NextRequest, NextResponse } from "next/server";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { riyadhTodayIsoDate, formatRiyadhDate } from "@/lib/date";
import { getReportVisibleStores, EXPORT_MAX_ROWS } from "@/features/reports/queries";
import { TABLE_REPORTS } from "@/features/reports/export/report-registry";
import { resolveReportSections, type ReportSectionDefinition } from "@/features/reports/export/presentation";
import { resolveFilterLabels } from "@/features/reports/export/filter-labels";
import { typedBooleanFilter } from "@/features/reports/url";
import { MANAGEMENT_REPORTS, MANAGEMENT_SECTIONS, MANAGEMENT_NOR_FIELDS, PERIOD_PRESET_LABELS_AR } from "@/features/reports/export/management-registry";
import { formatBasisLines } from "@/features/reports/components/report-basis-badge";
import { getPublicBranding } from "@/features/settings/queries";
import { renderTableReportPdf, renderManagementReportPdf, type ExportMeta } from "@/features/reports/export/pdf";
import { renderTableReportExcel, renderManagementReportExcel } from "@/features/reports/export/excel";

export const dynamic = "force-dynamic";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

/**
 * Phase 8 §39/§44 — single export endpoint for every report/format
 * combination. `GET /api/reports/export?report=<slug>&format=pdf|excel&...`
 * carries the exact same filter query params as the corresponding screen
 * page's URL (date_from/date_to/store_id/search/sort/page + report-specific
 * extras), so exporting "what's on screen right now" is a matter of the
 * "PDF"/"Excel" buttons forwarding `location.search` verbatim (see
 * `ReportExportButtons`) — Screen and export always read identically-scoped
 * data through the SAME `queries.ts` wrapper functions.
 *
 * Hotfix 8.1.1 §1/§5/§46 — table reports are now rendered through the SAME
 * basis-aware/multi-section presentation resolver the screen pages use
 * (`resolveReportSections`) — never a static single-schema definition — so
 * a report with more than one section (Payment Methods) or a basis-varying
 * shape (Returns/Shipping/COD) exports the CORRECT columns for whatever the
 * RPC actually returned, identically to what is on screen.
 */
export async function GET(request: NextRequest) {
  const params = request.nextUrl.searchParams;
  const slug = params.get("report") ?? "";
  const format = params.get("format") ?? "";

  if (format !== "pdf" && format !== "excel") {
    return NextResponse.json({ error: "invalid format" }, { status: 400 });
  }

  const tableDef = TABLE_REPORTS[slug];
  const managementDef = MANAGEMENT_REPORTS[slug];
  if (!tableDef && !managementDef) {
    return NextResponse.json({ error: "unknown report" }, { status: 404 });
  }

  // §44/§79 permission gates — mirrors the screen page's own
  // requirePermission calls exactly; the RPC re-enforces regardless.
  // Hotfix 8.1.1 §8 — for payment-methods, tableDef.domainPermission is now
  // "reports.view" (already satisfied by the call just above), matching the
  // RPC's own actual base gate — each SECTION's own visibility is decided
  // entirely by which keys the envelope carries (§79), never a second,
  // stricter TS-side domain check.
  const session = await requirePermission("reports.view");
  await requirePermission(tableDef?.domainPermission ?? managementDef!.domainPermission);
  const exportPermission = format === "pdf" ? "reports.export_pdf" : "reports.export_excel";
  if (!sessionHasPermission(session, exportPermission)) {
    return NextResponse.json({ error: "forbidden" }, { status: 403 });
  }

  const str = (k: string) => params.get(k) ?? undefined;
  const storeId = str("store_id");
  const stores = await getReportVisibleStores();
  const storeLabelMap = new Map(stores.map((s) => [s.id, s.name_ar]));
  const scopeLabel = storeId ? (storeLabelMap.get(storeId) ?? storeId) : "كل المتاجر المتاحة";
  const branding = await getPublicBranding();

  const generatedAt = new Date();
  const generatedByEmail = session.email;

  if (tableDef) {
    const dateFrom = str("date_from") || monthStart();
    const dateTo = str("date_to") || riyadhTodayIsoDate();
    // Patch 8.1 §11-14/§60 — Full Export Dataset Contract. `limit:
    // EXPORT_MAX_ROWS` makes this the SAME `fetch()` the screen page calls
    // (identical filters/permissions/store scope/redaction/summary, one DB
    // snapshot/statement — never a second, divergent export query, and
    // never a page-1-then-page-2 loop over the paginated RPC), just with a
    // larger `p_limit` than the screen's default 50. `page: 1` guarantees
    // offset 0 regardless of whatever page the user was viewing on screen —
    // an export is always the FULL matching set, not "page N onward".
    const filters: Record<string, unknown> = {
      date_from: dateFrom,
      date_to: dateTo,
      store_ids: storeId ? [storeId] : undefined,
      search: str("search"),
      sort: str("sort"),
      page: 1,
      limit: EXPORT_MAX_ROWS,
    };
    const booleanKeys = new Set(tableDef.booleanFilterKeys ?? []);
    for (const key of tableDef.extraFilterKeys) {
      // Patch 8.1 §39-42 — a boolean-typed RPC filter (e.g. `has_variance`,
      // `is_cod`, `participates_in_settlement`) must become a real
      // `boolean | undefined`, never the raw "true"/"false" string passed
      // through untyped.
      filters[key] = booleanKeys.has(key) ? typedBooleanFilter(str(key)) : str(key);
    }

    const envelope = (await tableDef.fetch(filters as never)) as unknown as Record<string, unknown>;

    // §11/§13/§60 CRITICAL — export integrity guard, in TWO layers:
    //   1) the RPC's own `total_count` (always the TRUE total match count,
    //      computed before its own LIMIT/OFFSET) exceeding EXPORT_MAX_ROWS
    //      means some rows structurally cannot have come back in this one
    //      call — an explicit, actionable error, never a silently
    //      truncated file.
    //   2) Even when total_count <= EXPORT_MAX_ROWS, do NOT trust that
    //      alone — verify the primary (paginated) section's `rows.length`
    //      genuinely equals `total_count` at this offset-0 call. A future
    //      RPC bug that under-returns rows while reporting a small
    //      total_count must never silently ship an incomplete export.
    //      Secondary/unpaginated sections (Payment Methods' refund_rows/
    //      settlement_rows, COD's settlement_rows) always return their
    //      complete set by RPC design (no p_limit/p_offset applied to
    //      them) — this check applies only to the primary section, which
    //      is the only one with a `total_count` to compare against.
    const totalCount = envelope.total_count;
    if (typeof totalCount === "number") {
      if (totalCount > EXPORT_MAX_ROWS) {
        return NextResponse.json({ error: "export_too_large", total_count: totalCount, max_rows: EXPORT_MAX_ROWS }, { status: 422 });
      }
      const primaryRows = (envelope.rows as unknown[] | undefined) ?? [];
      if (primaryRows.length !== totalCount) {
        return NextResponse.json({ error: "export_incomplete_dataset", total_count: totalCount, rows_received: primaryRows.length }, { status: 422 });
      }
    }

    // Hotfix 8.1.1 §1/§46 — resolve the envelope into its actual section(s)
    // (basis-aware / multi-section, §5 same resolver as the screen) rather
    // than assuming `tableDef.columns` describes the whole report.
    const rawSections = resolveReportSections(slug, envelope, {
      titleAr: tableDef.titleAr,
      columns: tableDef.columns,
      summaryFields: tableDef.summaryFields,
      rowKey: tableDef.rowKey,
    });

    // Patch 8.1 §15/§16/§61/§62; Hotfix 8.1.1 §47 — the PDF/Excel renderers
    // iterate `section.columns`/`summaryFields` UNCONDITIONALLY (unlike the
    // on-screen ReportTable, which already safely filters by
    // `c.key in rows[0]`). A forbidden financial column's HEADER must never
    // render at all — not with a blank/null cell, and not only when the
    // dataset happens to be non-empty (§61/§62's explicit empty-report test
    // case). Every section is redacted here, once, from the session
    // already resolved above — never relying on dataset shape to decide
    // visibility. A section itself that the actor cannot see at all is
    // already absent from `rawSections` (§79 true key-absence, resolved by
    // `resolveReportSections` from the envelope's own key presence) — this
    // loop only redacts individual COLUMNS within a section the actor CAN
    // see (e.g. a profit column inside a section they otherwise have
    // access to).
    const sections: ReportSectionDefinition[] = rawSections.map((s) => ({
      ...s,
      columns: s.columns.filter((c) => !c.permission || sessionHasPermission(session, c.permission)),
      summaryFields: s.summaryFields.filter((f) => !f.permission || sessionHasPermission(session, f.permission)),
    }));

    const basisLines = formatBasisLines(envelope.basis as string | undefined, envelope.row_basis as string | undefined, envelope.summary_basis as string | undefined);
    // Hotfix 8.1.1 §20-22 — complete export metadata: system/company name
    // (§21, read via the same safe, pre-login-readable general-settings
    // path the login screen itself uses — no financial/security settings
    // opened) and every ACTIVE filter's resolved human label (§22, never a
    // raw UUID when a label can be resolved).
    const filterLabels = await resolveFilterLabels(filters, storeLabelMap, tableDef.slug);
    const meta: ExportMeta = {
      systemNameAr: branding.system_name_ar,
      titleAr: tableDef.titleAr,
      descriptionAr: tableDef.descriptionAr,
      dateFrom,
      dateTo,
      scopeLabel,
      basisLabel: basisLines.length > 0 ? basisLines.join(" · ") : undefined,
      filterLabels,
      generatedByEmail,
      generatedAt,
    };

    const buffer = format === "pdf" ? await renderTableReportPdf(sections, meta) : await renderTableReportExcel(sections, meta);
    return fileResponse(buffer, slug, dateFrom, dateTo, format);
  }

  // Management (periodic) reports.
  const def = managementDef!;
  let dateFrom: string;
  let dateTo: string;
  let data: Record<string, unknown>;

  if (def.slug === "daily") {
    const date = str("date_from") || riyadhTodayIsoDate();
    data = await def.fetch(date, storeId ? [storeId] : undefined);
    dateFrom = String(data.business_date ?? date);
    dateTo = dateFrom;
  } else if (def.slug === "weekly") {
    const referenceDate = str("date_from") || riyadhTodayIsoDate();
    data = await def.fetch(referenceDate, storeId ? [storeId] : undefined);
    dateFrom = String(data.week_start ?? referenceDate);
    dateTo = String(data.week_end ?? referenceDate);
  } else if (def.slug === "monthly") {
    const today = riyadhTodayIsoDate();
    const year = Number(str("year")) || Number(today.slice(0, 4)); // no-float-ok: calendar date part, never money/weight/percent (§21).
    const month = Number(str("month")) || Number(today.slice(5, 7)); // no-float-ok: calendar date part, never money/weight/percent (§21).
    data = await def.fetch(undefined, storeId ? [storeId] : undefined, { year, month });
    dateFrom = String(data.month_start ?? "");
    dateTo = String(data.month_end ?? "");
  } else {
    const today = riyadhTodayIsoDate();
    // no-float-ok: year is a calendar date part, never money/weight/percent (§21).
    const year = Number(str("year")) || Number(today.slice(0, 4));
    data = await def.fetch(undefined, storeId ? [storeId] : undefined, { year });
    dateFrom = String(data.year_start ?? "");
    dateTo = String(data.year_end ?? "");
  }

  // Hotfix 8.1.2 §41 — the SAME explicit basis + calendar-aware comparison
  // range metadata the screen's `ReportBasisBadge`/`ComparisonRangeNote`
  // show, so a PDF/Excel export carries identical basis/comparison wording
  // to whatever the actor saw on screen when they exported it (§5/§48
  // format parity).
  const managementBasisLines = formatBasisLines(data.basis as string | undefined);
  const previousDateFrom = data.previous_date_from as string | undefined;
  const previousDateTo = data.previous_date_to as string | undefined;
  const periodPreset = data.period_preset as string | undefined;
  const presetLabel = periodPreset ? PERIOD_PRESET_LABELS_AR[periodPreset] : undefined;
  const comparisonLabel =
    previousDateFrom && previousDateTo
      ? `${presetLabel ? `${presetLabel} — ` : ""}الفترة السابقة للمقارنة: من ${formatRiyadhDate(previousDateFrom)} إلى ${formatRiyadhDate(previousDateTo)}`
      : undefined;

  const meta: ExportMeta = {
    systemNameAr: branding.system_name_ar,
    titleAr: def.titleAr,
    dateFrom,
    dateTo,
    scopeLabel,
    basisLabel: managementBasisLines.length > 0 ? managementBasisLines.join(" · ") : undefined,
    comparisonLabel,
    generatedByEmail,
    generatedAt,
  };

  const buffer =
    format === "pdf"
      ? await renderManagementReportPdf(def.titleAr, data, MANAGEMENT_SECTIONS, MANAGEMENT_NOR_FIELDS, meta)
      : await renderManagementReportExcel(def.titleAr, data, MANAGEMENT_SECTIONS, MANAGEMENT_NOR_FIELDS, meta);
  return fileResponse(buffer, slug, dateFrom, dateTo, format);
}

function fileResponse(buffer: Buffer, slug: string, dateFrom: string, dateTo: string, format: "pdf" | "excel"): NextResponse {
  const ext = format === "pdf" ? "pdf" : "xlsx";
  const contentType = format === "pdf" ? "application/pdf" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
  const filename = `report-${slug}-${dateFrom}-${dateTo}.${ext}`;
  return new NextResponse(new Uint8Array(buffer), {
    status: 200,
    headers: {
      "Content-Type": contentType,
      "Content-Disposition": `attachment; filename="${filename}"`,
      "Cache-Control": "no-store",
    },
  });
}

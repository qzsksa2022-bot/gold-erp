import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getMonthlyManagementReport, getReportVisibleStores } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { PeriodPicker } from "@/features/reports/components/period-picker";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { KpiSection } from "@/features/dashboard/components/kpi-section";
import { NetOperatingReturnCard } from "@/features/dashboard/components/net-operating-return-card";
import { ReportBasisBadge } from "@/features/reports/components/report-basis-badge";
import { ComparisonRangeNote } from "@/features/reports/components/comparison-range-note";
import { ManagementBreakdownTable } from "@/features/reports/components/management-breakdown-table";
import { MANAGEMENT_SECTIONS } from "@/features/reports/export/management-registry";
import { riyadhTodayIsoDate, formatRiyadhDate } from "@/lib/date";

export default async function MonthlyManagementReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");

  const today = riyadhTodayIsoDate();
  const year = Number(str("year")) || Number(today.slice(0, 4));
  const month = Number(str("month")) || Number(today.slice(5, 7));
  const storeId = str("store_id") || undefined;

  const [report, stores] = await Promise.all([getMonthlyManagementReport(year, month, storeId ? [storeId] : undefined), getReportVisibleStores()]);

  const nor = report.net_operating_return as Record<string, unknown> | undefined;
  const monthStart = String(report.month_start ?? "");
  const monthEnd = String(report.month_end ?? "");

  return (
    <div>
      <PageHeader
        title="التقرير الشهري"
        description={monthStart && monthEnd ? `ملخص إداري شامل للشهر من ${formatRiyadhDate(monthStart)} إلى ${formatRiyadhDate(monthEnd)}.` : "ملخص إداري شامل للشهر المحدد."}
        actions={
          <ReportExportButtons
            slug="monthly"
            searchParams={sp}
            canPdf={sessionHasPermission(session, "reports.export_pdf")}
            canExcel={sessionHasPermission(session, "reports.export_excel")}
          />
        }
      />

      <PeriodPicker year={year} month={month} showMonth storeId={storeId} stores={stores} />

      <ReportBasisBadge basis={report.basis as string | undefined} />
      <ComparisonRangeNote previousDateFrom={report.previous_date_from} previousDateTo={report.previous_date_to} periodPreset={report.period_preset} />

      <NetOperatingReturnCard nor={nor} />
      {MANAGEMENT_SECTIONS.map((section) => (
        <KpiSection key={section.key} title={section.titleAr} section={report[section.key] as Record<string, unknown> | undefined} fields={section.fields} />
      ))}
      <ManagementBreakdownTable breakdown={report.breakdown} granularity={report.breakdown_granularity} />
    </div>
  );
}

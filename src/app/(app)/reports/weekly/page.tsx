import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getWeeklyManagementReport, getReportVisibleStores } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { KpiSection } from "@/features/dashboard/components/kpi-section";
import { NetOperatingReturnCard } from "@/features/dashboard/components/net-operating-return-card";
import { ReportBasisBadge } from "@/features/reports/components/report-basis-badge";
import { ComparisonRangeNote } from "@/features/reports/components/comparison-range-note";
import { ManagementBreakdownTable } from "@/features/reports/components/management-breakdown-table";
import { MANAGEMENT_SECTIONS } from "@/features/reports/export/management-registry";
import { riyadhTodayIsoDate, formatRiyadhDate } from "@/lib/date";

export default async function WeeklyManagementReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");

  const referenceDate = str("date_from") || riyadhTodayIsoDate();
  const storeId = str("store_id") || undefined;

  const [report, stores] = await Promise.all([getWeeklyManagementReport(referenceDate, storeId ? [storeId] : undefined), getReportVisibleStores()]);

  const nor = report.net_operating_return as Record<string, unknown> | undefined;
  const weekStart = String(report.week_start ?? referenceDate);
  const weekEnd = String(report.week_end ?? referenceDate);

  return (
    <div>
      <PageHeader
        title="التقرير الأسبوعي"
        description={`ملخص إداري شامل للأسبوع من ${formatRiyadhDate(weekStart)} إلى ${formatRiyadhDate(weekEnd)} (السبت إلى الجمعة).`}
        actions={
          <ReportExportButtons
            slug="weekly"
            searchParams={sp}
            canPdf={sessionHasPermission(session, "reports.export_pdf")}
            canExcel={sessionHasPermission(session, "reports.export_excel")}
          />
        }
      />

      <ReportFilterBar dateFrom={referenceDate} storeId={storeId} stores={stores} showSearch={false} singleDate />

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

import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getDailyManagementReport, getReportVisibleStores } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { KpiSection } from "@/features/dashboard/components/kpi-section";
import { NetOperatingReturnCard } from "@/features/dashboard/components/net-operating-return-card";
import { ReportBasisBadge } from "@/features/reports/components/report-basis-badge";
import { ComparisonRangeNote } from "@/features/reports/components/comparison-range-note";
import { MANAGEMENT_SECTIONS } from "@/features/reports/export/management-registry";
import { riyadhTodayIsoDate, formatRiyadhDate } from "@/lib/date";

export default async function DailyManagementReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");

  const date = str("date_from") || riyadhTodayIsoDate();
  const storeId = str("store_id") || undefined;

  const [report, stores] = await Promise.all([getDailyManagementReport(date, storeId ? [storeId] : undefined), getReportVisibleStores()]);

  const nor = report.net_operating_return as Record<string, unknown> | undefined;

  return (
    <div>
      <PageHeader
        title="التقرير اليومي"
        description={`ملخص إداري شامل ليوم ${formatRiyadhDate(String(report.business_date ?? date))}.`}
        actions={
          <ReportExportButtons
            slug="daily"
            searchParams={sp}
            canPdf={sessionHasPermission(session, "reports.export_pdf")}
            canExcel={sessionHasPermission(session, "reports.export_excel")}
          />
        }
      />

      <ReportFilterBar dateFrom={date} storeId={storeId} stores={stores} showSearch={false} singleDate />

      <ReportBasisBadge basis={report.basis as string | undefined} />
      <ComparisonRangeNote previousDateFrom={report.previous_date_from} previousDateTo={report.previous_date_to} periodPreset={report.period_preset} />

      <NetOperatingReturnCard nor={nor} />
      {MANAGEMENT_SECTIONS.map((section) => (
        <KpiSection key={section.key} title={section.titleAr} section={report[section.key] as Record<string, unknown> | undefined} fields={section.fields} />
      ))}
    </div>
  );
}

import { Users } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getEmployeesReport, getReportVisibleStores } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Pagination } from "@/components/shared/pagination";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportSummaryCards } from "@/features/reports/components/report-summary-cards";
import { ReportTable } from "@/features/reports/components/report-table";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { buildReportHref } from "@/features/reports/url";
import { EMPLOYEES_COLUMNS as COLUMNS, EMPLOYEES_SUMMARY_FIELDS } from "@/features/reports/export/report-registry";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function EmployeesReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || monthStart(),
    date_to: str("date_to") || riyadhTodayIsoDate(),
    store_ids: str("store_id") ? [str("store_id")] : undefined,
    search: str("search") || undefined,
    sort: str("sort") || undefined,
    page,
  };

  const [report, stores] = await Promise.all([getEmployeesReport(filters), getReportVisibleStores()]);

  return (
    <div>
      <PageHeader
        title="تقرير الموظفين"
        description="أداء المبيعات لكل موظف بيع خلال الفترة."
        actions={
          <ReportExportButtons
            slug="employees"
            searchParams={sp}
            canPdf={sessionHasPermission(session, "reports.export_pdf")}
            canExcel={sessionHasPermission(session, "reports.export_excel")}
          />
        }
      />

      <ReportFilterBar search={filters.search} dateFrom={filters.date_from} dateTo={filters.date_to} storeId={str("store_id")} stores={stores} searchPlaceholder="اسم الموظف..." />

      <ReportSummaryCards summary={report.summary} fields={EMPLOYEES_SUMMARY_FIELDS} />

      <ReportTable
        rows={report.rows}
        columns={COLUMNS}
        rowKey="employee_id"
        emptyIcon={Users}
        emptyTitle="لا توجد بيانات موظفين مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        footer={<Pagination page={page} pageSize={report.limit} total={report.total_count} buildHref={(p) => buildReportHref(ROUTES.reportsEmployees, filters, str("store_id"), p)} />}
      />
    </div>
  );
}

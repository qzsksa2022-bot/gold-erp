import { Share2 } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getCollectionChannelsReport, getReportVisibleStores } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Pagination } from "@/components/shared/pagination";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportSummaryCards } from "@/features/reports/components/report-summary-cards";
import { ReportTable } from "@/features/reports/components/report-table";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { buildReportHref } from "@/features/reports/url";
import { COLLECTION_CHANNELS_COLUMNS as COLUMNS, COLLECTION_CHANNELS_SUMMARY_FIELDS } from "@/features/reports/export/report-registry";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function CollectionChannelsReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
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

  const [report, stores] = await Promise.all([getCollectionChannelsReport(filters), getReportVisibleStores()]);

  return (
    <div>
      <PageHeader
        title="تقرير قنوات التحصيل"
        description="توزيع المبيعات خلال الفترة حسب قناة التحصيل."
        actions={
          <ReportExportButtons
            slug="collection-channels"
            searchParams={sp}
            canPdf={sessionHasPermission(session, "reports.export_pdf")}
            canExcel={sessionHasPermission(session, "reports.export_excel")}
          />
        }
      />

      <ReportFilterBar search={filters.search} dateFrom={filters.date_from} dateTo={filters.date_to} storeId={str("store_id")} stores={stores} searchPlaceholder="اسم القناة..." />

      <ReportSummaryCards summary={report.summary} fields={COLLECTION_CHANNELS_SUMMARY_FIELDS} />

      <ReportTable
        rows={report.rows}
        columns={COLUMNS}
        rowKey="collection_channel_id"
        emptyIcon={Share2}
        emptyTitle="لا توجد بيانات مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        footer={<Pagination page={page} pageSize={report.limit} total={report.total_count} buildHref={(p) => buildReportHref(ROUTES.reportsCollectionChannels, filters, str("store_id"), p)} />}
      />
    </div>
  );
}

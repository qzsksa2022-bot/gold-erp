import { Banknote } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getCodReport, getReportVisibleStores } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Pagination } from "@/components/shared/pagination";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportSections } from "@/features/reports/components/report-sections";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { ReportBasisBadge, BASIS_SELECT_OPTIONS } from "@/features/reports/components/report-basis-badge";
import { resolveReportSections } from "@/features/reports/export/presentation";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { buildReportHref } from "@/features/reports/url";
import { COD_STATE_LABELS_AR } from "@/features/reports/export/report-registry";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function CodReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || monthStart(),
    date_to: str("date_to") || riyadhTodayIsoDate(),
    store_ids: str("store_id") ? [str("store_id")] : undefined,
    cod_collection_state: str("cod_collection_state") || undefined,
    basis: str("basis") || undefined,
    search: str("search") || undefined,
    sort: str("sort") || undefined,
    page,
  };

  const [report, stores] = await Promise.all([getCodReport(filters), getReportVisibleStores()]);

  return (
    <div>
      <PageHeader
        title="تقرير الدفع عند الاستلام"
        description="حالة تحصيل شحنات الدفع عند الاستلام (COD) خلال الفترة."
        actions={
          <ReportExportButtons
            slug="cod"
            searchParams={sp}
            canPdf={sessionHasPermission(session, "reports.export_pdf")}
            canExcel={sessionHasPermission(session, "reports.export_excel")}
          />
        }
      />

      <ReportFilterBar
        search={filters.search}
        dateFrom={filters.date_from}
        dateTo={filters.date_to}
        storeId={str("store_id")}
        stores={stores}
        searchPlaceholder="رقم الشحنة أو الطلب..."
        selects={[
          { key: "cod_collection_state", placeholder: "حالة التحصيل", allLabel: "كل الحالات", value: str("cod_collection_state"), options: Object.entries(COD_STATE_LABELS_AR).map(([value, label]) => ({ value, label })) },
          { key: "basis", placeholder: "أساس العرض", allLabel: "الافتراضي", value: str("basis"), options: BASIS_SELECT_OPTIONS.cod },
        ]}
      />

      <ReportBasisBadge basis={report.basis} />

      <ReportSections
        sections={resolveReportSections("cod", report as unknown as Record<string, unknown>)}
        emptyIcon={Banknote}
        emptyTitle="لا توجد شحنات دفع عند الاستلام مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        primaryFooter={<Pagination page={page} pageSize={report.limit} total={report.total_count} buildHref={(p) => buildReportHref(ROUTES.reportsCod, filters, str("store_id"), p)} />}
      />
    </div>
  );
}

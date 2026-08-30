import { LibraryBig } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getCategoriesReport, getReportVisibleStores, getReportKarats, getReportCategories } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Pagination } from "@/components/shared/pagination";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportSummaryCards } from "@/features/reports/components/report-summary-cards";
import { ReportTable } from "@/features/reports/components/report-table";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { buildReportHref } from "@/features/reports/url";
import { CATEGORIES_COLUMNS as COLUMNS, CATEGORIES_SUMMARY_FIELDS } from "@/features/reports/export/report-registry";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function CategoriesReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || monthStart(),
    date_to: str("date_to") || riyadhTodayIsoDate(),
    store_ids: str("store_id") ? [str("store_id")] : undefined,
    karat_id: str("karat_id") || undefined,
    // Hotfix 8.1.1 §41-42 — direct-children drill-down: only categories
    // whose parent_id matches exactly (never the whole subtree) match.
    parent_id: str("parent_id") || undefined,
    search: str("search") || undefined,
    sort: str("sort") || undefined,
    page,
  };

  const [report, stores, karats, categories] = await Promise.all([getCategoriesReport(filters), getReportVisibleStores(), getReportKarats(), getReportCategories()]);

  return (
    <div>
      <PageHeader
        title="تقرير الفئات"
        description="أداء المبيعات مجمّعًا حسب فئة المنتج خلال الفترة."
        actions={
          <ReportExportButtons
            slug="categories"
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
        searchPlaceholder="اسم الفئة أو الرمز..."
        selects={[
          { key: "karat_id", placeholder: "العيار", allLabel: "كل العيارات", value: str("karat_id"), options: karats.map((k) => ({ value: k.id, label: k.name_ar })) },
          {
            key: "parent_id",
            placeholder: "الفئة الرئيسية",
            allLabel: "كل الفئات (كل المستويات)",
            value: str("parent_id"),
            options: categories.map((c: { id: string; name_ar: string }) => ({ value: c.id, label: c.name_ar })),
          },
        ]}
      />

      <ReportSummaryCards summary={report.summary} fields={CATEGORIES_SUMMARY_FIELDS} />

      <ReportTable
        rows={report.rows}
        columns={COLUMNS}
        rowKey="category_id"
        emptyIcon={LibraryBig}
        emptyTitle="لا توجد فئات مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        footer={
          <Pagination page={page} pageSize={report.limit} total={report.total_count} buildHref={(p) => buildReportHref(ROUTES.reportsCategories, filters, str("store_id"), p)} />
        }
      />
    </div>
  );
}

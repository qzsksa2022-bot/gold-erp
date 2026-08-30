import { Package } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getItemsReport, getReportVisibleStores, getReportCategories, getReportKarats, getReportEmployees } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Pagination } from "@/components/shared/pagination";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportSummaryCards } from "@/features/reports/components/report-summary-cards";
import { ReportTable } from "@/features/reports/components/report-table";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { buildReportHref } from "@/features/reports/url";
import { ITEMS_COLUMNS as COLUMNS, ITEMS_SUMMARY_FIELDS } from "@/features/reports/export/report-registry";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function ItemsReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || monthStart(),
    date_to: str("date_to") || riyadhTodayIsoDate(),
    store_ids: str("store_id") ? [str("store_id")] : undefined,
    category_id: str("category_id") || undefined,
    karat_id: str("karat_id") || undefined,
    // Hotfix 8.1.2 §34-36 — bound to sales_orders.salesperson_id.
    salesperson_id: str("salesperson_id") || undefined,
    search: str("search") || undefined,
    sort: str("sort") || undefined,
    page,
  };

  const [report, stores, categories, karats, employees] = await Promise.all([
    getItemsReport(filters),
    getReportVisibleStores(),
    getReportCategories(),
    getReportKarats(),
    getReportEmployees(),
  ]);

  return (
    <div>
      <PageHeader
        title="تقرير الأصناف"
        description="ترتيب الأصناف المباعة خلال الفترة حسب الإيراد والوزن — مجمّعة حسب الفئة والعيار والاسم/الرمز."
        actions={
          <ReportExportButtons
            slug="items"
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
        searchPlaceholder="اسم الصنف أو SKU..."
        selects={[
          { key: "category_id", placeholder: "الفئة", allLabel: "كل الفئات", value: str("category_id"), options: categories.map((c) => ({ value: c.id, label: c.name_ar })) },
          { key: "karat_id", placeholder: "العيار", allLabel: "كل العيارات", value: str("karat_id"), options: karats.map((k) => ({ value: k.id, label: k.name_ar })) },
          {
            // Hotfix 8.1.2 §34-36
            key: "salesperson_id",
            placeholder: "موظف المبيعات",
            allLabel: "كل الموظفين",
            value: str("salesperson_id"),
            options: employees.map((e) => ({ value: e.id, label: e.full_name })),
          },
        ]}
      />

      <ReportSummaryCards summary={report.summary} fields={ITEMS_SUMMARY_FIELDS} />

      <ReportTable
        rows={report.rows}
        columns={COLUMNS}
        rowKey="__row_index__"
        emptyIcon={Package}
        emptyTitle="لا توجد أصناف مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        footer={
          <Pagination page={page} pageSize={report.limit} total={report.total_count} buildHref={(p) => buildReportHref(ROUTES.reportsItems, filters, str("store_id"), p)} />
        }
      />
    </div>
  );
}

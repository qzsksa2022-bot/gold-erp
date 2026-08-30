import { ShoppingCart } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getSalesReport, getReportVisibleStores, getReportCategories, getReportKarats, getReportPaymentMethods, getReportCollectionChannels, getReportEmployees } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Pagination } from "@/components/shared/pagination";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportSummaryCards } from "@/features/reports/components/report-summary-cards";
import { ReportTable } from "@/features/reports/components/report-table";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { buildReportHref } from "@/features/reports/url";
import { SALES_COLUMNS as COLUMNS, SALES_SUMMARY_FIELDS } from "@/features/reports/export/report-registry";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function SalesReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || monthStart(),
    date_to: str("date_to") || riyadhTodayIsoDate(),
    store_ids: str("store_id") ? [str("store_id")] : undefined,
    employee_id: str("employee_id") || undefined,
    category_id: str("category_id") || undefined,
    karat_id: str("karat_id") || undefined,
    payment_method_id: str("payment_method_id") || undefined,
    collection_channel_id: str("collection_channel_id") || undefined,
    search: str("search") || undefined,
    sort: str("sort") || undefined,
    page,
  };

  const [report, stores, categories, karats, paymentMethods, channels, employees] = await Promise.all([
    getSalesReport(filters),
    getReportVisibleStores(),
    getReportCategories(),
    getReportKarats(),
    getReportPaymentMethods(),
    getReportCollectionChannels(),
    getReportEmployees(),
  ]);

  return (
    <div>
      <PageHeader
        title="تقرير المبيعات"
        description="تفاصيل طلبات البيع خلال الفترة المحددة — القيم المالية مقروءة مباشرة من بيانات الطلب المخزّنة، دون إعادة احتساب."
        actions={
          <ReportExportButtons
            slug="sales"
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
        searchPlaceholder="رقم الطلب أو اسم الصنف..."
        selects={[
          { key: "employee_id", placeholder: "الموظف", allLabel: "كل الموظفين", value: str("employee_id"), options: employees.map((e) => ({ value: e.id, label: e.full_name })) },
          { key: "category_id", placeholder: "الفئة", allLabel: "كل الفئات", value: str("category_id"), options: categories.map((c) => ({ value: c.id, label: c.name_ar })) },
          { key: "karat_id", placeholder: "العيار", allLabel: "كل العيارات", value: str("karat_id"), options: karats.map((k) => ({ value: k.id, label: k.name_ar })) },
          { key: "payment_method_id", placeholder: "طريقة الدفع", allLabel: "كل الطرق", value: str("payment_method_id"), options: paymentMethods.map((p) => ({ value: p.id, label: p.name_ar })) },
          { key: "collection_channel_id", placeholder: "قناة التحصيل", allLabel: "كل القنوات", value: str("collection_channel_id"), options: channels.map((c) => ({ value: c.id, label: c.name_ar })) },
        ]}
      />

      <ReportSummaryCards summary={report.summary} fields={SALES_SUMMARY_FIELDS} />

      <ReportTable
        rows={report.rows}
        columns={COLUMNS}
        rowKey="order_id"
        emptyIcon={ShoppingCart}
        emptyTitle="لا توجد طلبات مبيعات مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        footer={
          <Pagination
            page={page}
            pageSize={report.limit}
            total={report.total_count}
            buildHref={(p) => buildReportHref(ROUTES.reportsSales, filters, str("store_id"), p)}
          />
        }
      />
    </div>
  );
}

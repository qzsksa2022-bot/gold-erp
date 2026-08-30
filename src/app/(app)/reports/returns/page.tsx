import { Undo2 } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getReturnsReport, getReportVisibleStores, getReportPaymentMethods, getReportCollectionChannels, getReportEmployees } from "@/features/reports/queries";
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
import { RETURNS_SCENARIO_LABELS_AR, RETURNS_STATUS_LABELS_AR, REFUND_RECONCILIATION_STATE_LABELS_AR } from "@/features/reports/export/report-registry";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function ReturnsReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || monthStart(),
    date_to: str("date_to") || riyadhTodayIsoDate(),
    store_ids: str("store_id") ? [str("store_id")] : undefined,
    scenario: str("scenario") || undefined,
    status: str("status") || undefined,
    payment_method_id: str("payment_method_id") || undefined,
    collection_channel_id: str("collection_channel_id") || undefined,
    basis: str("basis") || undefined,
    refund_method_id: str("refund_method_id") || undefined,
    salesperson_id: str("salesperson_id") || undefined,
    original_sale_date_from: str("original_sale_date_from") || undefined,
    original_sale_date_to: str("original_sale_date_to") || undefined,
    refund_reconciliation_state: str("refund_reconciliation_state") || undefined,
    search: str("search") || undefined,
    sort: str("sort") || undefined,
    page,
  };

  // Hotfix 8.1.2 §28-30 — payment_method_id (business_effect basis: the
  // original sale's own payment method) and refund_method_id (actual_cash
  // basis: the refund EVENT's own method, 0219 §36) are mutually exclusive
  // by basis — rendering both dropdowns unconditionally (as before) showed
  // one filter that silently had no effect no matter which basis was
  // active. isActualCash decides which ONE to render; the basis select's
  // clearKeys wipes whichever field becomes stale the moment basis changes.
  const isActualCash = filters.basis === "actual_cash";

  const [report, stores, paymentMethods, channels, employees] = await Promise.all([
    getReturnsReport(filters),
    getReportVisibleStores(),
    getReportPaymentMethods(),
    getReportCollectionChannels(),
    getReportEmployees(),
  ]);

  return (
    <div>
      <PageHeader
        title="تقرير المرتجعات"
        description="سجل حركات المرتجعات (اعتماد وعكس) خلال الفترة — كل حركة بتاريخها الفعلي الخاص، وليس تاريخ إنشاء السجل."
        actions={
          <ReportExportButtons
            slug="returns"
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
        searchPlaceholder="رقم المرتجع أو الطلب..."
        selects={[
          {
            key: "scenario",
            placeholder: "السبب",
            allLabel: "كل الأسباب",
            value: str("scenario"),
            options: Object.entries(RETURNS_SCENARIO_LABELS_AR).map(([value, label]) => ({ value, label })),
          },
          { key: "status", placeholder: "الحالة", allLabel: "كل الحالات", value: str("status"), options: Object.entries(RETURNS_STATUS_LABELS_AR).map(([value, label]) => ({ value, label })) },
          // Hotfix 8.1.2 §28-30 — basis-aware: only the filter that
          // actually applies under the CURRENT basis is rendered at all
          // (never a dropdown that silently does nothing, §36).
          ...(!isActualCash
            ? [
                {
                  key: "payment_method_id",
                  placeholder: "طريقة الدفع الأصلية",
                  allLabel: "كل الطرق",
                  value: str("payment_method_id"),
                  options: paymentMethods.map((p) => ({ value: p.id, label: p.name_ar })),
                },
              ]
            : [
                {
                  key: "refund_method_id",
                  placeholder: "طريقة الاسترداد الفعلية",
                  allLabel: "كل الطرق",
                  value: str("refund_method_id"),
                  options: paymentMethods.map((p) => ({ value: p.id, label: p.name_ar })),
                },
              ]),
          { key: "collection_channel_id", placeholder: "قناة التحصيل", allLabel: "كل القنوات", value: str("collection_channel_id"), options: channels.map((c) => ({ value: c.id, label: c.name_ar })) },
          { key: "salesperson_id", placeholder: "موظف المبيعات", allLabel: "كل الموظفين", value: str("salesperson_id"), options: employees.map((e) => ({ value: e.id, label: e.full_name })) },
          {
            key: "refund_reconciliation_state",
            placeholder: "حالة تسوية الاسترداد",
            allLabel: "كل الحالات",
            value: str("refund_reconciliation_state"),
            options: Object.entries(REFUND_RECONCILIATION_STATE_LABELS_AR).map(([value, label]) => ({ value, label })),
          },
          {
            key: "basis",
            placeholder: "أساس العرض",
            allLabel: "الافتراضي (الأثر التجاري)",
            value: str("basis"),
            options: BASIS_SELECT_OPTIONS.returns,
            // §28-30 — switching basis makes whichever of payment_method_id/
            // refund_method_id applied under the OLD basis stale; clear both
            // so neither resurfaces with a moot value if the user switches back.
            clearKeys: ["payment_method_id", "refund_method_id"],
          },
        ]}
        extraDateRange={{
          fromKey: "original_sale_date_from",
          toKey: "original_sale_date_to",
          label: "تاريخ البيع الأصلي:",
          fromValue: str("original_sale_date_from"),
          toValue: str("original_sale_date_to"),
        }}
      />

      <ReportBasisBadge basis={report.basis} />

      <ReportSections
        sections={resolveReportSections("returns", report as unknown as Record<string, unknown>)}
        emptyIcon={Undo2}
        emptyTitle="لا توجد حركات مرتجعات مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        primaryFooter={<Pagination page={page} pageSize={report.limit} total={report.total_count} buildHref={(p) => buildReportHref(ROUTES.reportsReturns, filters, str("store_id"), p)} />}
      />
    </div>
  );
}

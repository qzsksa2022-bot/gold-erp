import { Wrench } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import {
  getAdjustmentsReport,
  getReportVisibleStores,
  getReportAdjustmentTypes,
  getReportPaymentMethods,
  getReportCollectionChannels,
  getReportEmployees,
} from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Pagination } from "@/components/shared/pagination";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportSummaryCards } from "@/features/reports/components/report-summary-cards";
import { ReportTable } from "@/features/reports/components/report-table";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { ReportBasisBadge } from "@/features/reports/components/report-basis-badge";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { buildReportHref, typedBooleanFilter } from "@/features/reports/url";
import { ADJUSTMENTS_COLUMNS as COLUMNS, ADJUSTMENTS_SUMMARY_FIELDS, MOVEMENT_TYPE_LABELS_AR } from "@/features/reports/export/report-registry";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function AdjustmentsReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || monthStart(),
    date_to: str("date_to") || riyadhTodayIsoDate(),
    store_ids: str("store_id") ? [str("store_id")] : undefined,
    adjustment_type_id: str("adjustment_type_id") || undefined,
    // Hotfix 8.1.1 §32-35 — complete filter set: original sale's store vs
    // the adjustment's own processing store (independent, never OR-merged),
    // the adjustment's OWN payment method/channel (not the original sale's),
    // a real boolean for participates_in_settlement, the ledger movement
    // kind, and who created/approved the underlying adjustment.
    original_sale_store_id: str("original_sale_store_id") || undefined,
    processing_store_id: str("processing_store_id") || undefined,
    payment_method_id: str("payment_method_id") || undefined,
    collection_channel_id: str("collection_channel_id") || undefined,
    participates_in_settlement: typedBooleanFilter(str("participates_in_settlement")),
    movement_type: str("movement_type") || undefined,
    created_by: str("created_by") || undefined,
    approved_by: str("approved_by") || undefined,
    search: str("search") || undefined,
    sort: str("sort") || undefined,
    page,
  };

  const [report, stores, adjustmentTypes, paymentMethods, channels, employees] = await Promise.all([
    getAdjustmentsReport(filters),
    getReportVisibleStores(),
    getReportAdjustmentTypes(),
    getReportPaymentMethods(),
    getReportCollectionChannels(),
    getReportEmployees(),
  ]);

  return (
    <div>
      <PageHeader
        title="تقرير التعديلات والخدمات"
        description="سجل حركات التعديلات (اعتماد وعكس) خلال الفترة — كل حركة بتاريخها الفعلي الخاص."
        actions={
          <ReportExportButtons
            slug="adjustments"
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
        searchPlaceholder="رقم التعديل أو الطلب..."
        selects={[
          {
            key: "adjustment_type_id",
            placeholder: "نوع الخدمة",
            allLabel: "كل الأنواع",
            value: str("adjustment_type_id"),
            options: adjustmentTypes.map((t) => ({ value: t.id, label: t.name_ar })),
          },
          {
            key: "original_sale_store_id",
            placeholder: "متجر البيع الأصلي",
            allLabel: "كل المتاجر",
            value: str("original_sale_store_id"),
            options: stores.map((s) => ({ value: s.id, label: s.name_ar })),
          },
          {
            key: "processing_store_id",
            placeholder: "متجر المعالجة",
            allLabel: "كل المتاجر",
            value: str("processing_store_id"),
            options: stores.map((s) => ({ value: s.id, label: s.name_ar })),
          },
          {
            key: "payment_method_id",
            placeholder: "طريقة الدفع",
            allLabel: "كل الطرق",
            value: str("payment_method_id"),
            options: paymentMethods.map((p) => ({ value: p.id, label: p.name_ar })),
          },
          {
            key: "collection_channel_id",
            placeholder: "قناة التحصيل",
            allLabel: "كل القنوات",
            value: str("collection_channel_id"),
            options: channels.map((c) => ({ value: c.id, label: c.name_ar })),
          },
          {
            key: "participates_in_settlement",
            placeholder: "يشارك في التسوية؟",
            allLabel: "الكل",
            value: str("participates_in_settlement"),
            options: [
              { value: "true", label: "نعم" },
              { value: "false", label: "لا" },
            ],
          },
          {
            key: "movement_type",
            placeholder: "نوع الحركة",
            allLabel: "كل الحركات",
            value: str("movement_type"),
            options: Object.entries(MOVEMENT_TYPE_LABELS_AR).map(([value, label]) => ({ value, label })),
          },
          { key: "created_by", placeholder: "أنشئ بواسطة", allLabel: "الكل", value: str("created_by"), options: employees.map((e) => ({ value: e.id, label: e.full_name })) },
          { key: "approved_by", placeholder: "اعتُمد بواسطة", allLabel: "الكل", value: str("approved_by"), options: employees.map((e) => ({ value: e.id, label: e.full_name })) },
        ]}
      />

      <ReportBasisBadge basis={report.basis} />

      <ReportSummaryCards summary={report.summary} fields={ADJUSTMENTS_SUMMARY_FIELDS} />

      <ReportTable
        rows={report.rows}
        columns={COLUMNS}
        rowKey="__row_index__"
        emptyIcon={Wrench}
        emptyTitle="لا توجد حركات تعديلات مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        footer={<Pagination page={page} pageSize={report.limit} total={report.total_count} buildHref={(p) => buildReportHref(ROUTES.reportsAdjustments, filters, str("store_id"), p)} />}
      />
    </div>
  );
}

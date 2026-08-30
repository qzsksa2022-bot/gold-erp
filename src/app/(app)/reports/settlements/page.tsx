import { HandCoins } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import {
  getSettlementsReport,
  getReportVisibleStores,
  getReportSettlementRoutes,
  getReportPaymentMethods,
  getReportCollectionChannels,
  getReportShippingCarriers,
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
import {
  SETTLEMENTS_COLUMNS as COLUMNS,
  SETTLEMENTS_SUMMARY_FIELDS,
  SETTLEMENT_STATUS_LABELS_AR,
  SETTLEMENT_EFFECTIVE_STATUS_LABELS_AR,
  ROUTE_KIND_LABELS_AR,
} from "@/features/reports/export/report-registry";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function SettlementsReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const canViewFinancials = sessionHasPermission(session, "settlements.view_financials");

  const filters = {
    date_from: str("date_from") || monthStart(),
    date_to: str("date_to") || riyadhTodayIsoDate(),
    store_ids: str("store_id") ? [str("store_id")] : undefined,
    settlement_route_id: str("settlement_route_id") || undefined,
    status: str("status") || undefined,
    route_kind: str("route_kind") || undefined,
    payment_method_id: str("payment_method_id") || undefined,
    collection_channel_id: str("collection_channel_id") || undefined,
    shipping_carrier_id: str("shipping_carrier_id") || undefined,
    effective_status: str("effective_status") || undefined,
    // §41; Hotfix 8.1.1 §28-31 — has_variance is financial; only ever sent
    // when the actor can see financial fields at all — never shows a
    // control whose effect the actor can't observe, and never risks the
    // RPC's own explicit-rejection gate (0218) firing for a normal,
    // legitimate page load.
    has_variance: canViewFinancials ? typedBooleanFilter(str("has_variance")) : undefined,
    provider_statement_reference: str("provider_statement_reference") || undefined,
    search: str("search") || undefined,
    sort: str("sort") || undefined,
    page,
  };

  const [report, stores, routes, paymentMethods, channels, carriers] = await Promise.all([
    getSettlementsReport(filters),
    getReportVisibleStores(),
    getReportSettlementRoutes(),
    getReportPaymentMethods(),
    getReportCollectionChannels(),
    getReportShippingCarriers(),
  ]);

  return (
    <div>
      <PageHeader
        title="تقرير التسويات البنكية"
        description="دفعات التسوية خلال الفترة — المتوقع مقابل الفعلي البنكي والفرق، مستقلة تمامًا عن حساب ربح المبيعات."
        actions={
          <ReportExportButtons
            slug="settlements"
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
        searchPlaceholder="رقم دفعة التسوية..."
        selects={[
          { key: "settlement_route_id", placeholder: "المسار", allLabel: "كل المسارات", value: str("settlement_route_id"), options: routes.map((r) => ({ value: r.id, label: r.name_ar })) },
          {
            // §41 — the CORRECT, working "cancelled" filter (raw `status` can never literally equal 'cancelled', 0172's CHECK constraint) — kept as the recommended filter; `status` below is kept only for backward compatibility.
            key: "effective_status",
            placeholder: "الحالة الفعلية",
            allLabel: "كل الحالات",
            value: str("effective_status"),
            options: Object.entries(SETTLEMENT_EFFECTIVE_STATUS_LABELS_AR).map(([value, label]) => ({ value, label })),
          },
          {
            key: "status",
            placeholder: "الحالة الأصلية (قديم)",
            allLabel: "كل الحالات",
            value: str("status"),
            options: Object.entries(SETTLEMENT_STATUS_LABELS_AR).map(([value, label]) => ({ value, label })),
          },
          { key: "route_kind", placeholder: "نوع المسار", allLabel: "كل الأنواع", value: str("route_kind"), options: Object.entries(ROUTE_KIND_LABELS_AR).map(([value, label]) => ({ value, label })) },
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
            key: "shipping_carrier_id",
            placeholder: "ناقل الشحن",
            allLabel: "كل الناقلين",
            value: str("shipping_carrier_id"),
            options: carriers.map((c) => ({ value: c.id, label: c.name_ar })),
          },
          ...(canViewFinancials
            ? [
                {
                  key: "has_variance",
                  placeholder: "بها فرق؟",
                  allLabel: "الكل",
                  value: str("has_variance"),
                  options: [
                    { value: "true", label: "نعم" },
                    { value: "false", label: "لا" },
                  ],
                },
              ]
            : []),
        ]}
        textFilters={[{ key: "provider_statement_reference", placeholder: "مرجع كشف مزود الخدمة...", value: str("provider_statement_reference") }]}
      />

      <ReportBasisBadge rowBasis={report.row_basis} summaryBasis={report.summary_basis} />

      <ReportSummaryCards summary={report.summary} fields={SETTLEMENTS_SUMMARY_FIELDS} />

      <ReportTable
        rows={report.rows}
        columns={COLUMNS}
        rowKey="settlement_batch_id"
        emptyIcon={HandCoins}
        emptyTitle="لا توجد دفعات تسوية مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        footer={<Pagination page={page} pageSize={report.limit} total={report.total_count} buildHref={(p) => buildReportHref(ROUTES.reportsSettlements, filters, str("store_id"), p)} />}
      />
    </div>
  );
}

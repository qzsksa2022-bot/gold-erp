import { Truck } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getShippingReport, getReportVisibleStores, getReportShippingCarriers, getReportShippingZones } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Pagination } from "@/components/shared/pagination";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportSections } from "@/features/reports/components/report-sections";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { ReportBasisBadge, BASIS_SELECT_OPTIONS } from "@/features/reports/components/report-basis-badge";
import { resolveReportSections } from "@/features/reports/export/presentation";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { buildReportHref, typedBooleanFilter } from "@/features/reports/url";
import { SHIPPING_STATUS_LABELS_AR } from "@/features/reports/export/report-registry";

const DIRECTION_LABELS_AR: Record<string, string> = { outbound: "صادر", return: "مرتجع" };

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function ShippingReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("reports.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || monthStart(),
    date_to: str("date_to") || riyadhTodayIsoDate(),
    store_ids: str("store_id") ? [str("store_id")] : undefined,
    carrier_id: str("carrier_id") || undefined,
    shipping_zone_id: str("shipping_zone_id") || undefined,
    direction: str("direction") || undefined,
    current_status: str("current_status") || undefined,
    is_cod: typedBooleanFilter(str("is_cod")),
    basis: str("basis") || undefined,
    search: str("search") || undefined,
    sort: str("sort") || undefined,
    page,
  };

  const [report, stores, carriers, zones] = await Promise.all([
    getShippingReport(filters),
    getReportVisibleStores(),
    getReportShippingCarriers(),
    getReportShippingZones(),
  ]);

  return (
    <div>
      <PageHeader
        title="تقرير الشحن"
        description="تفاصيل الشحنات وتكاليف الناقل خلال الفترة."
        actions={
          <ReportExportButtons
            slug="shipping"
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
        searchPlaceholder="رقم الشحنة أو رقم التتبع..."
        selects={[
          { key: "carrier_id", placeholder: "الناقل", allLabel: "كل الناقلين", value: str("carrier_id"), options: carriers.map((c) => ({ value: c.id, label: c.name_ar })) },
          { key: "shipping_zone_id", placeholder: "المنطقة", allLabel: "كل المناطق", value: str("shipping_zone_id"), options: zones.map((z) => ({ value: z.id, label: z.name_ar })) },
          { key: "direction", placeholder: "الاتجاه", allLabel: "كل الاتجاهات", value: str("direction"), options: Object.entries(DIRECTION_LABELS_AR).map(([value, label]) => ({ value, label })) },
          { key: "current_status", placeholder: "الحالة", allLabel: "كل الحالات", value: str("current_status"), options: Object.entries(SHIPPING_STATUS_LABELS_AR).map(([value, label]) => ({ value, label })) },
          { key: "is_cod", placeholder: "دفع عند الاستلام؟", allLabel: "الكل", value: str("is_cod"), options: [{ value: "true", label: "نعم" }, { value: "false", label: "لا" }] },
          { key: "basis", placeholder: "أساس العرض", allLabel: "الافتراضي", value: str("basis"), options: BASIS_SELECT_OPTIONS.shipping },
        ]}
      />

      <ReportBasisBadge basis={report.basis} />

      <ReportSections
        sections={resolveReportSections("shipping", report as unknown as Record<string, unknown>)}
        emptyIcon={Truck}
        emptyTitle="لا توجد شحنات مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        primaryFooter={<Pagination page={page} pageSize={report.limit} total={report.total_count} buildHref={(p) => buildReportHref(ROUTES.reportsShipping, filters, str("store_id"), p)} />}
      />
    </div>
  );
}

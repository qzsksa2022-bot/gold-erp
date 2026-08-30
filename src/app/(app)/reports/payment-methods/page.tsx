import { CreditCard } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getPaymentMethodsReport, getReportVisibleStores, getReportPaymentMethods, getReportCollectionChannels } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Pagination } from "@/components/shared/pagination";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportSections } from "@/features/reports/components/report-sections";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { resolveReportSections } from "@/features/reports/export/presentation";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { buildReportHref } from "@/features/reports/url";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function PaymentMethodsReportPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
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
    // Hotfix 8.1.1 §10 — refund_method_id scopes ONLY the Actual Refund
    // Cash section; collection_channel_id scopes the Sales section's
    // (payment_method_id, collection_channel_id) pair AND the Settlements
    // section's route — each section applies only the filters that are
    // actually meaningful to it (§9), never a filter that silently does
    // nothing on a section it was never meant to affect.
    refund_method_id: str("refund_method_id") || undefined,
    // Hotfix 8.1.2 §31-33 — distinct from refund_method_id: filters the
    // Sales section by the sale's own payment_method_id (and the
    // Settlements section by route payment_method_id), never the Actual
    // Refund Cash section.
    payment_method_id: str("payment_method_id") || undefined,
    collection_channel_id: str("collection_channel_id") || undefined,
  };

  const [report, stores, paymentMethods, channels] = await Promise.all([
    getPaymentMethodsReport(filters),
    getReportVisibleStores(),
    getReportPaymentMethods(),
    getReportCollectionChannels(),
  ]);

  return (
    <div>
      <PageHeader
        title="تقرير طرق الدفع"
        description="توزيع المبيعات خلال الفترة حسب طريقة الدفع."
        actions={
          <ReportExportButtons
            slug="payment-methods"
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
        searchPlaceholder="اسم طريقة الدفع..."
        selects={[
          {
            // Hotfix 8.1.2 §31-33 — Sales + Settlements sections ONLY
            // (the sale's own / route's own payment_method_id) — distinct
            // from refund_method_id below (Actual Refund Cash ONLY).
            key: "payment_method_id",
            placeholder: "طريقة الدفع الأصلية",
            allLabel: "كل الطرق",
            value: str("payment_method_id"),
            options: paymentMethods.map((p) => ({ value: p.id, label: p.name_ar })),
          },
          {
            // Hotfix 8.1.1 §10 — Actual Refund Cash section ONLY.
            key: "refund_method_id",
            placeholder: "طريقة الاسترداد الفعلية",
            allLabel: "كل الطرق",
            value: str("refund_method_id"),
            options: paymentMethods.map((p) => ({ value: p.id, label: p.name_ar })),
          },
          {
            // Hotfix 8.1.1 §10 — Sales pair + Settlements route.
            key: "collection_channel_id",
            placeholder: "قناة التحصيل",
            allLabel: "كل القنوات",
            value: str("collection_channel_id"),
            options: channels.map((c) => ({ value: c.id, label: c.name_ar })),
          },
        ]}
      />

      {/* Hotfix 8.1.1 §6-10 — a genuine 3-section report (Sales / Actual
          Refund Cash / Settlements), each independently gated by which
          keys the RPC's envelope actually carries (§79) — never a static
          single-schema table. */}
      <ReportSections
        sections={resolveReportSections("payment-methods", report as unknown as Record<string, unknown>)}
        emptyIcon={CreditCard}
        emptyTitle="لا توجد بيانات مطابقة"
        emptyDescription="جرّب تعديل الفلاتر أو نطاق التاريخ."
        primaryFooter={
          // Hotfix 8.1.2 §24-25 — total_count is entirely ABSENT (not 0)
          // when the actor lacks sales.view (the Sales section, the only
          // one this Pagination footer paginates, never rendered at all) —
          // rendering unconditionally previously passed total={undefined}.
          typeof report.total_count === "number" ? (
            <Pagination page={page} pageSize={report.limit} total={report.total_count} buildHref={(p) => buildReportHref(ROUTES.reportsPaymentMethods, filters, str("store_id"), p)} />
          ) : undefined
        }
      />
    </div>
  );
}

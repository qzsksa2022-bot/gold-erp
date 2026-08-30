import Link from "next/link";
import { Wrench, Plus } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import {
  listAdjustmentsPage,
  getAdjustmentsVisibleStoreLookups,
  getAdjustmentsFilterTypeLookups,
  getAdjustmentsFilterPaymentMethodLookups,
  getAdjustmentsFilterCollectionChannelLookups,
} from "@/features/adjustments/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Can } from "@/lib/permissions/context";
import { AdjustmentsFilters } from "@/features/adjustments/components/adjustments-filters";
import { ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR } from "@/features/adjustments/schema";
import { formatRiyadhDate } from "@/lib/date";
import { ROUTES, PAGE_SIZE_DEFAULT } from "@/lib/constants";

const STATUS_BADGE_VARIANT: Record<string, "warning" | "success" | "destructive" | "secondary"> = {
  pending: "warning",
  approved: "success",
  rejected: "destructive",
  reversed: "secondary",
};

export default async function AdjustmentsPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const session = await requirePermission("adjustments.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    search: str("search") || undefined,
    date_from: str("date_from") || undefined,
    date_to: str("date_to") || undefined,
    store_id: str("store_id") || undefined,
    original_sale_store_id: str("original_sale_store_id") || undefined,
    adjustment_type_id: str("adjustment_type_id") || undefined,
    payment_method_id: str("payment_method_id") || undefined,
    collection_channel_id: str("collection_channel_id") || undefined,
    participates_in_settlement: str("participates_in_settlement") ? str("participates_in_settlement") === "true" : undefined,
    status: (str("status") || undefined) as keyof typeof ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR | undefined,
    page,
  };

  const canViewProfit = session.isSuperAdmin || session.permissions.has("sales.view_profit");

  // Patch 6.1 item 22 — the type/payment-method/collection-channel filter
  // lookups below are the VIEW-only ones (0152, adjustments.view alone,
  // full catalog including disabled), NOT the old CREATE-flow active-only
  // pickers (adjustments_active_type_lookups() et al.) — this page only
  // requires adjustments.view, and the old lookups silently required
  // adjustments.create too (masked by a .catch(() => []) that degraded to
  // an empty, confusing filter for a view-only actor).
  const [{ rows, total }, visibleStores, types, paymentMethods, collectionChannels] = await Promise.all([
    listAdjustmentsPage(filters, PAGE_SIZE_DEFAULT),
    getAdjustmentsVisibleStoreLookups(),
    getAdjustmentsFilterTypeLookups(),
    getAdjustmentsFilterPaymentMethodLookups(),
    getAdjustmentsFilterCollectionChannelLookups(),
  ]);

  return (
    <div>
      <PageHeader
        title="التعديلات والخدمات"
        description="سجل خدمات ما بعد البيع (رسوم/تعديلات) على عمليات بيع قائمة — مستقل تمامًا عن حساب ربح المبيعات والمرتجعات والشحن."
        actions={
          <Can permission="adjustments.create">
            <Button asChild variant="accent">
              <Link href={ROUTES.adjustmentsNew}>
                <Plus className="size-4" />
                تعديل/خدمة جديد
              </Link>
            </Button>
          </Can>
        }
      />

      <AdjustmentsFilters
        search={filters.search ?? ""}
        dateFrom={filters.date_from ?? ""}
        dateTo={filters.date_to ?? ""}
        storeId={filters.store_id ?? ""}
        originalSaleStoreId={filters.original_sale_store_id ?? ""}
        adjustmentTypeId={filters.adjustment_type_id ?? ""}
        paymentMethodId={filters.payment_method_id ?? ""}
        collectionChannelId={filters.collection_channel_id ?? ""}
        participatesInSettlement={filters.participates_in_settlement === undefined ? "" : String(filters.participates_in_settlement)}
        status={filters.status ?? ""}
        stores={visibleStores}
        types={types}
        paymentMethods={paymentMethods}
        collectionChannels={collectionChannels}
      />

      {rows.length === 0 ? (
        <EmptyState icon={Wrench} title="لا توجد تعديلات/خدمات مطابقة" description="جرّب تعديل الفلاتر، أو ابدأ تعديل/خدمة جديد." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>رقم التعديل/الخدمة</TableHead>
                <TableHead>عملية البيع</TableHead>
                <TableHead className="hidden sm:table-cell">التاريخ</TableHead>
                <TableHead className="hidden sm:table-cell">المتجر</TableHead>
                <TableHead>النوع</TableHead>
                <TableHead className="hidden md:table-cell">طريقة الدفع</TableHead>
                <TableHead>تحصيل العميل</TableHead>
                {canViewProfit && <TableHead className="hidden lg:table-cell">التكلفة المباشرة</TableHead>}
                {canViewProfit && <TableHead className="hidden lg:table-cell">رسوم الدفع</TableHead>}
                {canViewProfit && <TableHead className="hidden lg:table-cell">صافي الربح</TableHead>}
                <TableHead>الحالة</TableHead>
                <TableHead className="hidden md:table-cell">ضمن التسوية</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id} className="cursor-pointer hover:bg-muted/40">
                  <TableCell className="font-medium">
                    <Link href={`${ROUTES.adjustments}/${row.id}`} className="font-mono text-sm text-accent hover:underline" dir="ltr">
                      {row.adjustment_number}
                    </Link>
                  </TableCell>
                  <TableCell className="font-mono text-xs text-muted-foreground" dir="ltr">
                    {row.order_number}
                  </TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground sm:table-cell">{formatRiyadhDate(row.adjustment_date)}</TableCell>
                  <TableCell className="hidden text-sm sm:table-cell">{row.processing_store_name ?? "—"}</TableCell>
                  <TableCell className="text-sm">{row.adjustment_type_name_ar ?? "—"}</TableCell>
                  <TableCell className="hidden text-sm md:table-cell">{row.payment_method_name ?? "—"}</TableCell>
                  <TableCell className="text-sm font-medium" dir="ltr">
                    {row.customer_charge}
                  </TableCell>
                  {canViewProfit && (
                    <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                      {row.effective_direct_cost ?? "—"}
                    </TableCell>
                  )}
                  {canViewProfit && (
                    <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                      {row.effective_payment_fee_amount ?? "—"}
                    </TableCell>
                  )}
                  {canViewProfit && (
                    <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                      {row.effective_net_adjustment_profit ?? "—"}
                    </TableCell>
                  )}
                  <TableCell>
                    <Badge variant={STATUS_BADGE_VARIANT[row.effective_status] ?? "secondary"}>
                      {ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR[row.effective_status as keyof typeof ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR] ?? row.effective_status}
                    </Badge>
                  </TableCell>
                  <TableCell className="hidden text-sm md:table-cell">{row.participates_in_settlement ? "نعم" : "لا"}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <Pagination
            page={page}
            pageSize={PAGE_SIZE_DEFAULT}
            total={total}
            buildHref={(p) => {
              const params = new URLSearchParams();
              // Hotfix 6.1.1 item 10 — `if (v)` drops the boolean `false`
              // value of participates_in_settlement (an "outside settlement
              // only" filter click), silently losing that filter across
              // Next/Previous page navigation. A value is present whenever
              // it isn't undefined/null/empty-string — `false` and `0` must
              // both survive.
              for (const [k, v] of Object.entries(filters)) {
                if (v !== undefined && v !== null && v !== "") params.set(k, String(v));
              }
              params.set("page", String(p));
              return `${ROUTES.adjustments}?${params.toString()}`;
            }}
          />
        </div>
      )}
    </div>
  );
}

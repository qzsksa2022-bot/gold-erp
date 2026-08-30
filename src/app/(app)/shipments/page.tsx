import Link from "next/link";
import { Truck, Plus } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listShipmentsPage, getShipmentsVisibleStoreLookups, getShipmentsFilterCarrierLookups, getShipmentsFilterZoneLookups } from "@/features/shipping/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Can } from "@/lib/permissions/context";
import { ShipmentsFilters } from "@/features/shipping/components/shipments-filters";
import { SHIPMENT_STATUS_LABELS_AR, SHIPMENT_DIRECTION_LABELS_AR, COD_COLLECTION_STATE_LABELS_AR } from "@/features/shipping/schema";
import { formatRiyadhDate } from "@/lib/date";
import { ROUTES, PAGE_SIZE_DEFAULT } from "@/lib/constants";

const STATUS_BADGE_VARIANT: Record<string, "warning" | "success" | "destructive" | "secondary"> = {
  created: "secondary",
  ready_for_pickup: "secondary",
  picked_up: "warning",
  in_transit: "warning",
  out_for_delivery: "warning",
  delivered: "success",
  delivery_failed: "destructive",
  customer_refused: "destructive",
  customer_never_received: "destructive",
  returned_to_store: "secondary",
  cancelled: "destructive",
};

export default async function ShipmentsPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const session = await requirePermission("shipments.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || undefined,
    date_to: str("date_to") || undefined,
    store_id: str("store_id") || undefined,
    carrier_id: str("carrier_id") || undefined,
    shipping_zone_id: str("shipping_zone_id") || undefined,
    direction: (str("direction") || undefined) as "outbound" | "return" | undefined,
    current_status: (str("current_status") || undefined) as keyof typeof SHIPMENT_STATUS_LABELS_AR | undefined,
    shipment_number: str("shipment_number") || undefined,
    tracking_number: str("tracking_number") || undefined,
    // Patch 5.1 item 12 — new filters.
    order_number: str("order_number") || undefined,
    return_number: str("return_number") || undefined,
    original_sale_store_id: str("original_sale_store_id") || undefined,
    cod_collection_state: (str("cod_collection_state") || undefined) as keyof typeof COD_COLLECTION_STATE_LABELS_AR | undefined,
    page,
  };

  const canViewProfit = session.isSuperAdmin || session.permissions.has("sales.view_profit");

  // Patch 5.1 item 11 fix — these two lookups are now gated on
  // shipments.view alone (shipments_filter_carrier_lookups()/
  // shipments_filter_zone_lookups(), migration 0126), so a shipments.view-
  // only actor (no shipments.create) no longer gets a hard failure loading
  // this page, unlike the old shipments.create-gated lookups this page used
  // to call.
  const [{ rows, total }, visibleStores, carriers, zones] = await Promise.all([
    listShipmentsPage(filters, PAGE_SIZE_DEFAULT),
    getShipmentsVisibleStoreLookups(),
    getShipmentsFilterCarrierLookups(),
    getShipmentsFilterZoneLookups(),
  ]);

  return (
    <div>
      <PageHeader
        title="الشحنات"
        description="قائمة شحنات الذهاب والإرجاع عبر جميع المتاجر المتاحة لك."
        actions={
          <Can permission="shipments.create">
            <Button asChild variant="accent">
              <Link href={ROUTES.shipmentsNew}>
                <Plus className="size-4" />
                شحنة جديدة
              </Link>
            </Button>
          </Can>
        }
      />

      <ShipmentsFilters
        shipmentNumber={filters.shipment_number ?? ""}
        trackingNumber={filters.tracking_number ?? ""}
        orderNumber={filters.order_number ?? ""}
        returnNumber={filters.return_number ?? ""}
        dateFrom={filters.date_from ?? ""}
        dateTo={filters.date_to ?? ""}
        storeId={filters.store_id ?? ""}
        originalSaleStoreId={filters.original_sale_store_id ?? ""}
        carrierId={filters.carrier_id ?? ""}
        shippingZoneId={filters.shipping_zone_id ?? ""}
        direction={filters.direction ?? ""}
        currentStatus={filters.current_status ?? ""}
        codCollectionState={filters.cod_collection_state ?? ""}
        stores={visibleStores}
        carriers={carriers}
        zones={zones}
      />

      {rows.length === 0 ? (
        <EmptyState icon={Truck} title="لا توجد شحنات مطابقة" description="جرّب تعديل الفلاتر، أو ابدأ شحنة جديدة." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>رقم الشحنة</TableHead>
                <TableHead>عملية البيع</TableHead>
                <TableHead className="hidden md:table-cell">رقم المرتجع</TableHead>
                <TableHead className="hidden sm:table-cell">التاريخ</TableHead>
                <TableHead className="hidden sm:table-cell">المتجر</TableHead>
                <TableHead>شركة الشحن</TableHead>
                <TableHead className="hidden md:table-cell">المنطقة</TableHead>
                <TableHead className="hidden md:table-cell">رقم التتبع</TableHead>
                <TableHead>الاتجاه</TableHead>
                <TableHead>الحالة</TableHead>
                {/* Hotfix 5.1.1 item 8 — رسوم الشحن على العميل مبلغ تشغيلي
                    غير مرتبط بالربح (item 10 من Patch 5.1)، لذا يظهر دومًا
                    بلا اشتراط sales.view_profit، خلافًا لعمودَي الصافي
                    التاليَين. */}
                <TableHead className="hidden lg:table-cell">رسوم الشحن على العميل</TableHead>
                {canViewProfit && <TableHead className="hidden lg:table-cell">صافي الشحن المتوقع</TableHead>}
                {canViewProfit && <TableHead className="hidden lg:table-cell">صافي الشحن الفعلي</TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id} className="cursor-pointer hover:bg-muted/40">
                  <TableCell className="font-medium">
                    <Link href={`${ROUTES.shipments}/${row.id}`} className="font-mono text-sm text-accent hover:underline" dir="ltr">
                      {row.shipment_number}
                    </Link>
                  </TableCell>
                  <TableCell className="font-mono text-xs text-muted-foreground" dir="ltr">
                    {row.order_number}
                  </TableCell>
                  <TableCell className="hidden font-mono text-xs text-muted-foreground md:table-cell" dir="ltr">
                    {row.return_number ?? "—"}
                  </TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground sm:table-cell">{formatRiyadhDate(row.shipment_date)}</TableCell>
                  <TableCell className="hidden text-sm sm:table-cell">{row.store_name ?? "—"}</TableCell>
                  <TableCell className="text-sm">{row.carrier_name ?? "—"}</TableCell>
                  <TableCell className="hidden text-sm md:table-cell">{row.zone_name ?? "—"}</TableCell>
                  <TableCell className="hidden font-mono text-xs text-muted-foreground md:table-cell" dir="ltr">
                    {row.tracking_number ?? "—"}
                  </TableCell>
                  <TableCell className="text-sm">{SHIPMENT_DIRECTION_LABELS_AR[row.direction as keyof typeof SHIPMENT_DIRECTION_LABELS_AR] ?? row.direction}</TableCell>
                  <TableCell>
                    <Badge variant={STATUS_BADGE_VARIANT[row.current_status] ?? "secondary"}>
                      {SHIPMENT_STATUS_LABELS_AR[row.current_status as keyof typeof SHIPMENT_STATUS_LABELS_AR] ?? row.current_status}
                    </Badge>
                  </TableCell>
                  <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                    {row.customer_shipping_charge ?? "—"}
                  </TableCell>
                  {canViewProfit && (
                    <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                      {row.net_shipping_expected ?? "—"}
                    </TableCell>
                  )}
                  {canViewProfit && (
                    <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                      {row.net_shipping_actual ?? "—"}
                    </TableCell>
                  )}
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
              for (const [k, v] of Object.entries(filters)) if (v) params.set(k, String(v));
              params.set("page", String(p));
              return `${ROUTES.shipments}?${params.toString()}`;
            }}
          />
        </div>
      )}
    </div>
  );
}

import Link from "next/link";
import { HandCoins, Plus } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import {
  listSettlementBatchesPage,
  getSettlementRouteFilterLookups,
  getSettlementStoreFilterLookups,
  getPaymentMethodFilterLookupsForSettlements,
  getCollectionChannelFilterLookupsForSettlements,
  getShippingCarrierFilterLookupsForSettlements,
} from "@/features/settlements/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Can } from "@/lib/permissions/context";
import { SettlementBatchesFilters } from "@/features/settlements/components/settlement-batches-filters";
import { SettlementBatchesPager } from "@/features/settlements/components/settlement-batches-pager";
import { SETTLEMENT_BATCH_EFFECTIVE_STATUSES, SETTLEMENT_BATCH_STATUS_LABELS_AR, SETTLEMENT_ROUTE_KINDS } from "@/features/settlements/schema";
import { formatRiyadhDate } from "@/lib/date";
import { ROUTES, PAGE_SIZE_DEFAULT } from "@/lib/constants";

const STATUS_BADGE_VARIANT: Record<string, "warning" | "success" | "destructive" | "secondary" | "accent"> = {
  draft: "secondary",
  finalized: "accent",
  reconciled: "success",
  cancelled: "destructive",
};

function isEffectiveStatus(value: string | undefined): value is (typeof SETTLEMENT_BATCH_EFFECTIVE_STATUSES)[number] {
  return !!value && (SETTLEMENT_BATCH_EFFECTIVE_STATUSES as readonly string[]).includes(value);
}

function isRouteKind(value: string | undefined): value is (typeof SETTLEMENT_ROUTE_KINDS)[number] {
  return !!value && (SETTLEMENT_ROUTE_KINDS as readonly string[]).includes(value);
}

export default async function SettlementsPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("settlements.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const canViewFinancials = session.isSuperAdmin || session.permissions.has("settlements.view_financials");

  const rawEffectiveStatus = str("effective_status");
  const rawRouteKind = str("route_kind");
  const rawHasVariance = str("has_variance");
  const filters = {
    search: str("search") || undefined,
    date_from: str("date_from") || undefined,
    date_to: str("date_to") || undefined,
    settlement_route_id: str("settlement_route_id") || undefined,
    effective_status: isEffectiveStatus(rawEffectiveStatus) ? rawEffectiveStatus : undefined,
    route_kind: isRouteKind(rawRouteKind) ? rawRouteKind : undefined,
    payment_method_id: str("payment_method_id") || undefined,
    collection_channel_id: str("collection_channel_id") || undefined,
    shipping_carrier_id: str("shipping_carrier_id") || undefined,
    store_id: str("store_id") || undefined,
    // §25 — has_variance is refused outright by the RPC without settlements.
    // view_financials, so it is never sent for an actor lacking it, even if
    // the raw URL param is present (a stale/shared link, e.g.).
    has_variance: canViewFinancials && (rawHasVariance === "true" || rawHasVariance === "false") ? rawHasVariance === "true" : undefined,
    page,
  };

  const [{ rows, hasNextPage }, routes, stores, paymentMethods, collectionChannels, shippingCarriers] = await Promise.all([
    listSettlementBatchesPage(filters, PAGE_SIZE_DEFAULT),
    getSettlementRouteFilterLookups(),
    getSettlementStoreFilterLookups(),
    getPaymentMethodFilterLookupsForSettlements(),
    getCollectionChannelFilterLookupsForSettlements(),
    getShippingCarrierFilterLookupsForSettlements(),
  ]);

  return (
    <div>
      <PageHeader
        title="التسويات"
        description="دفعات تسوية أرصدة تحصيل الدفع/COD مقابل مصادر البيع والمرتجعات والتعديلات — مستقلة تمامًا عن حساب ربح المبيعات."
        actions={
          <Can permission="settlements.create">
            <Button asChild variant="accent">
              <Link href={ROUTES.settlementsNew}>
                <Plus className="size-4" />
                تسوية جديدة
              </Link>
            </Button>
          </Can>
        }
      />

      <SettlementBatchesFilters
        search={filters.search ?? ""}
        dateFrom={filters.date_from ?? ""}
        dateTo={filters.date_to ?? ""}
        settlementRouteId={filters.settlement_route_id ?? ""}
        effectiveStatus={filters.effective_status ?? ""}
        routeKind={filters.route_kind ?? ""}
        paymentMethodId={filters.payment_method_id ?? ""}
        collectionChannelId={filters.collection_channel_id ?? ""}
        shippingCarrierId={filters.shipping_carrier_id ?? ""}
        storeId={filters.store_id ?? ""}
        hasVariance={filters.has_variance === undefined ? "" : String(filters.has_variance)}
        routes={routes}
        paymentMethods={paymentMethods}
        collectionChannels={collectionChannels}
        shippingCarriers={shippingCarriers}
        stores={stores}
        canViewFinancials={canViewFinancials}
      />

      {rows.length === 0 ? (
        <EmptyState icon={HandCoins} title="لا توجد دفعات تسوية مطابقة" description="جرّب تعديل الفلاتر، أو ابدأ تسوية جديدة." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>رقم الدفعة</TableHead>
                <TableHead>المسار</TableHead>
                <TableHead className="hidden sm:table-cell">التاريخ</TableHead>
                <TableHead className="hidden md:table-cell">عدد المصادر</TableHead>
                {canViewFinancials && <TableHead className="hidden lg:table-cell">المتوقع (الفعلي الحالي)</TableHead>}
                {canViewFinancials && <TableHead className="hidden lg:table-cell">الفعلي البنكي</TableHead>}
                {canViewFinancials && <TableHead className="hidden lg:table-cell">الفرق</TableHead>}
                <TableHead>الحالة</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id} className="cursor-pointer hover:bg-muted/40">
                  <TableCell className="font-medium">
                    <Link href={`${ROUTES.settlements}/${row.id}`} className="font-mono text-sm text-accent hover:underline" dir="ltr">
                      {row.settlement_number}
                    </Link>
                  </TableCell>
                  <TableCell className="text-sm">{row.route_name_ar}</TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground sm:table-cell">{formatRiyadhDate(row.settlement_date)}</TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground md:table-cell" dir="ltr">
                    {row.source_count}
                  </TableCell>
                  {canViewFinancials && (
                    <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                      {row.effective_expected_settlement_contribution ?? "—"}
                    </TableCell>
                  )}
                  {canViewFinancials && (
                    <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                      {row.effective_actual_settlement_contribution ?? "—"}
                    </TableCell>
                  )}
                  {canViewFinancials && (
                    <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                      {row.effective_variance_contribution ?? "—"}
                    </TableCell>
                  )}
                  <TableCell>
                    <Badge variant={STATUS_BADGE_VARIANT[row.effective_status] ?? "secondary"}>
                      {SETTLEMENT_BATCH_STATUS_LABELS_AR[row.effective_status as keyof typeof SETTLEMENT_BATCH_STATUS_LABELS_AR] ?? row.effective_status}
                    </Badge>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <SettlementBatchesPager
            page={page}
            hasNextPage={hasNextPage}
            buildHref={(p) => {
              const params = new URLSearchParams();
              for (const [k, v] of Object.entries(filters)) {
                if (v !== undefined && v !== null && v !== "") params.set(k, String(v));
              }
              params.set("page", String(p));
              return `${ROUTES.settlements}?${params.toString()}`;
            }}
          />
        </div>
      )}
    </div>
  );
}

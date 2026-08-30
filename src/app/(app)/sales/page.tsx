import Link from "next/link";
import { ShoppingCart, Plus } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listSalesOrdersPage, getVisibleStoresForSalesFilters, getOperableStoresForCloseDay, getSalespeopleForSalesFilters } from "@/features/sales/queries";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Can } from "@/lib/permissions/context";
import { SalesFilters } from "@/features/sales/components/sales-filters";
import { CloseDayDialog } from "@/features/sales/components/close-day-dialog";
import { formatRiyadhDate } from "@/lib/date";
import { ROUTES, PAGE_SIZE_DEFAULT } from "@/lib/constants";

export default async function SalesPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const session = await requirePermission("sales.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || undefined,
    date_to: str("date_to") || undefined,
    store_id: str("store_id") || undefined,
    order_number: str("order_number") || undefined,
    salesperson_id: str("salesperson_id") || undefined,
    payment_method_id: str("payment_method_id") || undefined,
    collection_channel_id: str("collection_channel_id") || undefined,
    page,
  };

  const canViewProfit = session.isSuperAdmin || session.permissions.has("sales.view_profit");
  const canClose = session.isSuperAdmin || session.permissions.has("sales.close_day");

  const supabase = await createClient();
  const [{ rows, total }, visibleStores, operableStores, salespeople, { data: paymentMethods }, { data: collectionChannels }] = await Promise.all([
    listSalesOrdersPage(filters, PAGE_SIZE_DEFAULT),
    getVisibleStoresForSalesFilters(),
    getOperableStoresForCloseDay(),
    getSalespeopleForSalesFilters(),
    supabase.from("payment_methods").select("*").order("sort_order"),
    supabase.from("collection_channels").select("*").order("sort_order"),
  ]);

  return (
    <div>
      <PageHeader
        title="المبيعات"
        description="قائمة عمليات البيع عبر جميع المتاجر المتاحة لك."
        actions={
          <div className="flex items-center gap-2">
            {canClose && <CloseDayDialog stores={operableStores} />}
            <Can permission="sales.create">
              <Button asChild variant="accent">
                <Link href={ROUTES.salesNew}>
                  <Plus className="size-4" />
                  عملية بيع جديدة
                </Link>
              </Button>
            </Can>
          </div>
        }
      />

      <SalesFilters
        orderNumber={filters.order_number ?? ""}
        dateFrom={filters.date_from ?? ""}
        dateTo={filters.date_to ?? ""}
        storeId={filters.store_id ?? ""}
        salespersonId={filters.salesperson_id ?? ""}
        paymentMethodId={filters.payment_method_id ?? ""}
        collectionChannelId={filters.collection_channel_id ?? ""}
        stores={visibleStores}
        salespeople={salespeople}
        paymentMethods={paymentMethods ?? []}
        collectionChannels={collectionChannels ?? []}
      />

      {rows.length === 0 ? (
        <EmptyState icon={ShoppingCart} title="لا توجد عمليات بيع مطابقة" description="جرّب تعديل الفلاتر، أو ابدأ عملية بيع جديدة." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>رقم العملية</TableHead>
                <TableHead>التاريخ</TableHead>
                <TableHead className="hidden sm:table-cell">المتجر</TableHead>
                <TableHead className="hidden md:table-cell">الموظف</TableHead>
                <TableHead className="hidden sm:table-cell">عدد البنود</TableHead>
                <TableHead>الإجمالي</TableHead>
                {canViewProfit && <TableHead className="hidden lg:table-cell">الربح الإجمالي</TableHead>}
                {canViewProfit && <TableHead className="hidden lg:table-cell">صافي الربح</TableHead>}
                <TableHead className="hidden md:table-cell">طريقة الدفع</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id} className="cursor-pointer hover:bg-muted/40">
                  <TableCell className="font-medium">
                    <Link href={`${ROUTES.sales}/${row.id}`} className="font-mono text-sm text-accent hover:underline" dir="ltr">
                      {row.order_number}
                    </Link>
                  </TableCell>
                  <TableCell className="text-sm text-muted-foreground">{formatRiyadhDate(row.sale_date)}</TableCell>
                  <TableCell className="hidden text-sm sm:table-cell">{row.store?.name_ar ?? "—"}</TableCell>
                  <TableCell className="hidden text-sm md:table-cell">{row.salesperson?.full_name ?? "—"}</TableCell>
                  <TableCell className="hidden text-sm sm:table-cell">{row.item_count}</TableCell>
                  <TableCell className="font-medium" dir="ltr">
                    {row.subtotal}
                  </TableCell>
                  {canViewProfit && (
                    <TableCell className="hidden text-sm lg:table-cell" dir="ltr">
                      {row.gross_profit ?? "—"}
                    </TableCell>
                  )}
                  {canViewProfit && (
                    <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                      {row.net_sales_profit ?? "—"}
                    </TableCell>
                  )}
                  <TableCell className="hidden text-sm md:table-cell">{row.paymentMethod?.name_ar ?? "—"}</TableCell>
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
              return `${ROUTES.sales}?${params.toString()}`;
            }}
          />
        </div>
      )}
    </div>
  );
}

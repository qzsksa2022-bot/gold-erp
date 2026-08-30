import Link from "next/link";
import { Undo2, Plus } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listSalesReturnsPage, getReturnsVisibleStoreLookups } from "@/features/returns/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Can } from "@/lib/permissions/context";
import { ReturnsFilters } from "@/features/returns/components/returns-filters";
import { RETURN_STATUS_LABELS_AR } from "@/features/returns/schema";
import { formatRiyadhDate } from "@/lib/date";
import { ROUTES, PAGE_SIZE_DEFAULT } from "@/lib/constants";

const STATUS_BADGE_VARIANT: Record<string, "warning" | "success" | "destructive" | "secondary"> = {
  pending: "warning",
  approved: "success",
  rejected: "destructive",
  reversed: "secondary",
};

export default async function ReturnsPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const session = await requirePermission("returns.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    date_from: str("date_from") || undefined,
    date_to: str("date_to") || undefined,
    processed_store_id: str("processed_store_id") || undefined,
    original_store_id: str("original_store_id") || undefined,
    return_number: str("return_number") || undefined,
    order_number: str("order_number") || undefined,
    status: (str("status") || undefined) as "pending" | "approved" | "rejected" | "reversed" | undefined,
    scenario: (str("scenario") || undefined) as "defective_product" | "customer_changed_mind" | "wrong_item_delivered" | "customer_never_received" | "other" | undefined,
    page,
  };

  const canViewProfit = session.isSuperAdmin || session.permissions.has("sales.view_profit");

  const [{ rows, total }, visibleStores] = await Promise.all([listSalesReturnsPage(filters, PAGE_SIZE_DEFAULT), getReturnsVisibleStoreLookups()]);

  return (
    <div>
      <PageHeader
        title="المرتجعات"
        description="قائمة مرتجعات المبيعات عبر جميع المتاجر المتاحة لك."
        actions={
          <Can permission="returns.create">
            <Button asChild variant="accent">
              <Link href={ROUTES.returnsNew}>
                <Plus className="size-4" />
                مرتجع جديد
              </Link>
            </Button>
          </Can>
        }
      />

      <ReturnsFilters
        returnNumber={filters.return_number ?? ""}
        orderNumber={filters.order_number ?? ""}
        dateFrom={filters.date_from ?? ""}
        dateTo={filters.date_to ?? ""}
        processedStoreId={filters.processed_store_id ?? ""}
        originalStoreId={filters.original_store_id ?? ""}
        status={filters.status ?? ""}
        scenario={filters.scenario ?? ""}
        stores={visibleStores}
      />

      {rows.length === 0 ? (
        <EmptyState icon={Undo2} title="لا توجد مرتجعات مطابقة" description="جرّب تعديل الفلاتر، أو ابدأ مرتجعًا جديدًا." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>رقم المرتجع</TableHead>
                <TableHead>عملية البيع</TableHead>
                <TableHead>التاريخ</TableHead>
                <TableHead className="hidden sm:table-cell">المتجر</TableHead>
                <TableHead className="hidden sm:table-cell">عدد البنود</TableHead>
                <TableHead>الحالة</TableHead>
                <TableHead>رد المبيعات</TableHead>
                <TableHead className="hidden md:table-cell">المسترد فعليًا</TableHead>
                {canViewProfit && <TableHead className="hidden lg:table-cell">أثر صافي الربح</TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id} className="cursor-pointer hover:bg-muted/40">
                  <TableCell className="font-medium">
                    <Link href={`${ROUTES.returns}/${row.id}`} className="font-mono text-sm text-accent hover:underline" dir="ltr">
                      {row.return_number}
                    </Link>
                  </TableCell>
                  <TableCell className="font-mono text-xs text-muted-foreground" dir="ltr">
                    {row.order_number}
                  </TableCell>
                  <TableCell className="text-sm text-muted-foreground">{formatRiyadhDate(row.return_date)}</TableCell>
                  <TableCell className="hidden text-sm sm:table-cell">{row.processed_store_name ?? "—"}</TableCell>
                  <TableCell className="hidden text-sm sm:table-cell">{row.item_count}</TableCell>
                  <TableCell>
                    <Badge variant={STATUS_BADGE_VARIANT[row.status] ?? "secondary"}>{RETURN_STATUS_LABELS_AR[row.status as keyof typeof RETURN_STATUS_LABELS_AR] ?? row.status}</Badge>
                  </TableCell>
                  <TableCell className="font-medium" dir="ltr">
                    {row.sales_revenue_reversal_amount ?? "—"}
                  </TableCell>
                  <TableCell className="hidden text-sm md:table-cell" dir="ltr">
                    {row.actual_refunded_total}
                  </TableCell>
                  {canViewProfit && (
                    <TableCell className="hidden text-sm font-medium lg:table-cell" dir="ltr">
                      {row.net_sales_profit_adjustment ?? "—"}
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
              return `${ROUTES.returns}?${params.toString()}`;
            }}
          />
        </div>
      )}
    </div>
  );
}

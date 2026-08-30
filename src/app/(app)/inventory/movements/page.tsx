import { History } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listInventoryStockMovementsPage, getInventoryVisibleStoreLookups, getInventoryActiveItemLookups } from "@/features/inventory/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { InventoryMovementsFilters } from "@/features/inventory/components/inventory-movements-filters";
import { formatRiyadhDate } from "@/lib/date";
import { ROUTES, PAGE_SIZE_DEFAULT } from "@/lib/constants";

const MOVEMENT_KIND_LABELS_AR: Record<string, string> = {
  receive: "استلام",
  adjust: "تصحيح",
};

export default async function InventoryMovementsPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requirePermission("inventory.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const filters = {
    item_id: str("item_id") || undefined,
    store_id: str("store_id") || undefined,
    date_from: str("date_from") || undefined,
    date_to: str("date_to") || undefined,
    page,
  };

  const [{ rows, total }, stores, items] = await Promise.all([
    listInventoryStockMovementsPage(filters, PAGE_SIZE_DEFAULT),
    getInventoryVisibleStoreLookups(),
    getInventoryActiveItemLookups().catch(() => []),
  ]);

  return (
    <div>
      <PageHeader title="سجل حركات المخزون" description="سجل للقراءة فقط — كل حركة استلام أو تصحيح، بما فيها من أنشأها ومتى." />

      <InventoryMovementsFilters storeId={filters.store_id ?? ""} itemId={filters.item_id ?? ""} dateFrom={filters.date_from ?? ""} dateTo={filters.date_to ?? ""} stores={stores} items={items} />

      {rows.length === 0 ? (
        <EmptyState icon={History} title="لا توجد حركات مخزون مطابقة" description="جرّب تعديل الفلاتر." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>التاريخ</TableHead>
                <TableHead>الصنف</TableHead>
                <TableHead className="hidden sm:table-cell">المتجر</TableHead>
                <TableHead>النوع</TableHead>
                <TableHead>الكمية</TableHead>
                <TableHead className="hidden md:table-cell">السبب / المرجع</TableHead>
                <TableHead className="hidden lg:table-cell">بواسطة</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="text-sm text-muted-foreground">{formatRiyadhDate(row.business_date)}</TableCell>
                  <TableCell className="text-sm">
                    <span className="font-mono" dir="ltr">
                      {row.sku}
                    </span>{" "}
                    — {row.item_name_ar}
                  </TableCell>
                  <TableCell className="hidden text-sm sm:table-cell">{row.store_name_ar}</TableCell>
                  <TableCell>
                    <Badge variant={row.movement_kind === "receive" ? "success" : "secondary"}>{MOVEMENT_KIND_LABELS_AR[row.movement_kind] ?? row.movement_kind}</Badge>
                  </TableCell>
                  <TableCell className="font-mono text-sm font-medium" dir="ltr">
                    {row.quantity_delta}
                  </TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground md:table-cell">{row.reason ?? row.reference ?? "—"}</TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground lg:table-cell">{row.created_by_name ?? "—"}</TableCell>
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
              for (const [k, v] of Object.entries(filters)) {
                if (v) params.set(k, String(v));
              }
              params.set("page", String(p));
              return `${ROUTES.inventoryMovements}?${params.toString()}`;
            }}
          />
        </div>
      )}
    </div>
  );
}

import Link from "next/link";
import { Boxes, History, LibraryBig } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listInventoryStockBalancesPage, getInventoryVisibleStoreLookups, getInventoryOperableStoreLookups, getInventoryActiveItemLookups } from "@/features/inventory/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Button } from "@/components/ui/button";
import { Can } from "@/lib/permissions/context";
import { InventoryBalancesFilters } from "@/features/inventory/components/inventory-balances-filters";
import { InventoryReceiveStockDialog } from "@/features/inventory/components/inventory-receive-stock-dialog";
import { InventoryAdjustStockDialog } from "@/features/inventory/components/inventory-adjust-stock-dialog";
import { ROUTES, PAGE_SIZE_DEFAULT } from "@/lib/constants";

export default async function InventoryPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requirePermission("inventory.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const search = str("search") || undefined;
  const storeId = str("store_id") || undefined;

  const [{ rows, total }, visibleStores, operableStores, itemLookupRows] = await Promise.all([
    listInventoryStockBalancesPage({ storeId, search }, page, PAGE_SIZE_DEFAULT),
    getInventoryVisibleStoreLookups(),
    getInventoryOperableStoreLookups().catch(() => []),
    getInventoryActiveItemLookups().catch(() => []),
  ]);

  return (
    <div>
      <PageHeader
        title="المخزون"
        description="أرصدة المخزون الحالية لكل صنف في كل متجر — الرصيد محسوب دائمًا من سجل الحركات، وليس قيمة مخزّنة."
        actions={
          <div className="flex flex-wrap gap-2">
            <Can permission="inventory.view">
              <Button asChild variant="outline">
                <Link href={ROUTES.inventoryItems}>
                  <LibraryBig className="size-4" />
                  كتالوج الأصناف
                </Link>
              </Button>
              <Button asChild variant="outline">
                <Link href={ROUTES.inventoryMovements}>
                  <History className="size-4" />
                  سجل الحركات
                </Link>
              </Button>
            </Can>
            <Can permission="inventory.adjust">
              <InventoryAdjustStockDialog items={itemLookupRows} stores={operableStores} />
            </Can>
            <Can permission="inventory.receive">
              <InventoryReceiveStockDialog items={itemLookupRows} stores={operableStores} />
            </Can>
          </div>
        }
      />

      <InventoryBalancesFilters search={search ?? ""} storeId={storeId ?? ""} stores={visibleStores} />

      {rows.length === 0 ? (
        <EmptyState icon={Boxes} title="لا توجد أرصدة مخزون مطابقة" description="جرّب تعديل الفلاتر، أو سجّل استلام مخزون لصنف جديد." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>رمز الصنف</TableHead>
                <TableHead>الاسم</TableHead>
                <TableHead>المتجر</TableHead>
                <TableHead>الرصيد</TableHead>
                <TableHead className="hidden sm:table-cell">الوحدة</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={`${row.item_id}-${row.store_id}`}>
                  <TableCell className="font-mono text-sm" dir="ltr">
                    {row.sku}
                  </TableCell>
                  <TableCell className="text-sm font-medium">{row.name_ar}</TableCell>
                  <TableCell className="text-sm">{row.store_name_ar}</TableCell>
                  <TableCell className="font-mono text-sm font-medium" dir="ltr">
                    {row.balance}
                  </TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground sm:table-cell">{row.unit}</TableCell>
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
              if (search) params.set("search", search);
              if (storeId) params.set("store_id", storeId);
              params.set("page", String(p));
              return `${ROUTES.inventory}?${params.toString()}`;
            }}
          />
        </div>
      )}
    </div>
  );
}

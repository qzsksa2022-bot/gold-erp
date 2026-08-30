import { LibraryBig } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listInventoryItemsPage, getInventoryCategoryLookups, getInventoryKaratLookups } from "@/features/inventory/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { InventoryItemFormDialog } from "@/features/inventory/components/inventory-item-form-dialog";
import { ROUTES, PAGE_SIZE_DEFAULT } from "@/lib/constants";

export default async function InventoryItemsPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requirePermission("inventory.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const [{ rows, total }, categories, karats] = await Promise.all([
    listInventoryItemsPage({ page, search: str("search") || undefined }, PAGE_SIZE_DEFAULT),
    getInventoryCategoryLookups().catch(() => []),
    getInventoryKaratLookups().catch(() => []),
  ]);

  return (
    <div>
      <PageHeader
        title="كتالوج أصناف المخزون"
        description="الأصناف (SKU) المتاحة للاستلام والتصحيح في المخزون — رمز الصنف غير قابل للتعديل بعد الإنشاء."
        actions={
          <Can permission="inventory.receive">
            <InventoryItemFormDialog categories={categories} karats={karats} />
          </Can>
        }
      />

      {rows.length === 0 ? (
        <EmptyState icon={LibraryBig} title="لا توجد أصناف مخزون بعد" description="أضف صنفًا جديدًا لبدء تسجيل حركات المخزون." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>رمز الصنف</TableHead>
                <TableHead>الاسم</TableHead>
                <TableHead className="hidden sm:table-cell">التصنيف</TableHead>
                <TableHead className="hidden sm:table-cell">العيار</TableHead>
                <TableHead className="hidden md:table-cell">الوحدة</TableHead>
                <TableHead>الحالة</TableHead>
                <Can permission="inventory.adjust">
                  <TableHead></TableHead>
                </Can>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="font-mono text-sm" dir="ltr">
                    {row.sku}
                  </TableCell>
                  <TableCell className="text-sm font-medium">{row.name_ar}</TableCell>
                  <TableCell className="hidden text-sm sm:table-cell">{row.category_name_ar ?? "—"}</TableCell>
                  <TableCell className="hidden text-sm sm:table-cell">{row.karat_name_ar ?? "—"}</TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground md:table-cell">{row.unit}</TableCell>
                  <TableCell>
                    <Badge variant={row.active ? "success" : "secondary"}>{row.active ? "مفعّل" : "معطّل"}</Badge>
                  </TableCell>
                  <Can permission="inventory.adjust">
                    <TableCell className="text-end">
                      <InventoryItemFormDialog item={row} categories={categories} karats={karats} />
                    </TableCell>
                  </Can>
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
              if (str("search")) params.set("search", str("search"));
              params.set("page", String(p));
              return `${ROUTES.inventoryItems}?${params.toString()}`;
            }}
          />
        </div>
      )}
    </div>
  );
}

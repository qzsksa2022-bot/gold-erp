import { Store as StoreIcon } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listStores } from "@/features/stores/queries";
import { listSearchParamsSchema } from "@/lib/validation/common";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Can } from "@/lib/permissions/context";
import { StoreFormDialog } from "@/features/stores/components/store-form-dialog";
import { StoreStatusBadge } from "@/features/stores/components/store-status-badge";
import { StoreStatusToggle } from "@/features/stores/components/store-status-toggle";
import { StoresToolbar } from "@/features/stores/components/stores-toolbar";
import { formatRiyadhDate } from "@/lib/date";

export default async function StoresPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await requirePermission("stores.view");

  const sp = await searchParams;
  const { q, page, pageSize } = listSearchParamsSchema.parse(sp);
  const status = (typeof sp.status === "string" ? sp.status : "all") as "all" | "active" | "disabled";

  const { stores, total } = await listStores({ q, status, page, pageSize });

  return (
    <div>
      <PageHeader
        title="المتاجر"
        description="إدارة فروع المتجر — الإضافة، التعديل، والتعطيل عند الحاجة."
        actions={
          <Can permission="stores.create">
            <StoreFormDialog />
          </Can>
        }
      />

      <StoresToolbar q={q} status={status} />

      {stores.length === 0 ? (
        <EmptyState
          icon={StoreIcon}
          title="لا توجد متاجر مطابقة"
          description={q || status !== "all" ? "جرّب تعديل كلمة البحث أو الفلتر." : "ابدأ بإضافة أول متجر لمنشأتك."}
        />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>المتجر</TableHead>
                <TableHead className="hidden sm:table-cell">الكود</TableHead>
                <TableHead>الحالة</TableHead>
                <TableHead className="hidden md:table-cell">تاريخ الإنشاء</TableHead>
                <TableHead className="w-24 text-left">إجراءات</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {stores.map((store) => (
                <TableRow key={store.id}>
                  <TableCell>
                    <div className="flex flex-col">
                      <span className="font-medium">{store.name_ar}</span>
                      {store.name_en && <span className="text-xs text-muted-foreground">{store.name_en}</span>}
                    </div>
                  </TableCell>
                  <TableCell className="hidden font-mono text-xs sm:table-cell">{store.code}</TableCell>
                  <TableCell>
                    <StoreStatusBadge status={store.status} />
                  </TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground md:table-cell">
                    {formatRiyadhDate(store.created_at)}
                  </TableCell>
                  <TableCell>
                    <div className="flex items-center justify-end gap-1">
                      <Can permission="stores.edit">
                        <StoreFormDialog store={store} />
                      </Can>
                      <Can permission="stores.disable">
                        <StoreStatusToggle storeId={store.id} status={store.status} storeName={store.name_ar} />
                      </Can>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <Pagination
            page={page}
            pageSize={pageSize}
            total={total}
            buildHref={(p) => `/stores?${new URLSearchParams({ q, status, page: String(p) }).toString()}`}
          />
        </div>
      )}
    </div>
  );
}

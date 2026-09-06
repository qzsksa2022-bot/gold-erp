import { Tags } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { getExpenseCategories } from "@/features/expenses/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import {
  ExpenseCategoryCreateDialog,
  ExpenseCategoryEditDialog,
  ExpenseCategoryStatusToggle,
} from "@/features/expenses/components/expense-category-dialogs";

export default async function ExpenseCategoriesPage() {
  // Reading the catalog only needs expenses.view; every WRITE control below is
  // additionally gated on expenses.manage_categories (and re-enforced by the
  // RPCs themselves, migration 0235).
  await requirePermission("expenses.view");

  const { rows } = await getExpenseCategories();

  return (
    <div>
      <PageHeader
        title="تصنيفات المصروفات"
        description="قائمة عامة (غير مقيَّدة بفرع) لأنواع المصروفات التشغيلية. الرمز دائم، والتصنيف لا يُحذف أبدًا — يُعطَّل فقط، حتى تبقى المصروفات التاريخية قابلة للقراءة."
        actions={
          <Can permission="expenses.manage_categories">
            <ExpenseCategoryCreateDialog />
          </Can>
        }
      />

      {rows.length === 0 ? (
        <EmptyState icon={Tags} title="لا توجد تصنيفات مصروفات" description="أضف تصنيفًا لتتمكن من تسجيل المصروفات." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>الرمز</TableHead>
                <TableHead>الاسم</TableHead>
                <TableHead className="hidden sm:table-cell">الاسم بالإنجليزية</TableHead>
                <TableHead>الحالة</TableHead>
                <TableHead className="hidden lg:table-cell">ملاحظات</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="font-mono text-sm" dir="ltr">
                    {row.code}
                  </TableCell>
                  <TableCell className="text-sm font-medium">{row.name_ar}</TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground sm:table-cell" dir="ltr">
                    {row.name_en ?? "—"}
                  </TableCell>
                  <TableCell>
                    <Badge variant={row.status === "active" ? "success" : "secondary"}>{row.status === "active" ? "نشط" : "معطّل"}</Badge>
                  </TableCell>
                  <TableCell className="hidden max-w-xs truncate text-sm text-muted-foreground lg:table-cell">{row.notes ?? "—"}</TableCell>
                  <TableCell>
                    <Can permission="expenses.manage_categories">
                      <div className="flex items-center justify-end gap-2">
                        <ExpenseCategoryEditDialog category={row} />
                        <ExpenseCategoryStatusToggle categoryId={row.id} status={row.status} categoryName={row.name_ar} />
                      </div>
                    </Can>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}

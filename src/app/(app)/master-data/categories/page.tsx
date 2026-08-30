import { FolderTree } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listCategoriesFlat } from "@/features/categories/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Can } from "@/lib/permissions/context";
import { CategoryFormDialog } from "@/features/categories/components/category-form-dialog";
import { CategoryTreeView } from "@/features/categories/components/category-tree-view";

export default async function CategoriesPage() {
  await requirePermission("categories.view");
  const categories = await listCategoriesFlat();

  return (
    <div>
      <PageHeader
        title="تصنيفات المنتجات"
        description="شجرة تصنيفات رئيسية وفرعية بلا حد للعمق — لا يُحذف تصنيف استُخدم سابقًا، فقط يُعطَّل."
        actions={
          <Can permission="categories.manage">
            <CategoryFormDialog allCategories={categories} />
          </Can>
        }
      />

      {categories.length === 0 ? (
        <EmptyState icon={FolderTree} title="لا توجد تصنيفات بعد" description="ابدأ بإضافة أول تصنيف رئيسي." />
      ) : (
        <CategoryTreeView categories={categories} />
      )}
    </div>
  );
}

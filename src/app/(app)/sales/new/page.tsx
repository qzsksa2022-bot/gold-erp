import { requirePermission } from "@/lib/permissions/guard";
import { getSalesFormLookups } from "@/features/sales/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { SalesEntryForm } from "@/features/sales/components/sales-entry-form";
import { ShoppingCart } from "lucide-react";

export default async function NewSalePage() {
  await requirePermission("sales.create");
  const lookups = await getSalesFormLookups();

  if (lookups.operableStores.length === 0) {
    return (
      <div>
        <PageHeader title="عملية بيع جديدة" description="أدخل بيانات العملية والبنود، ثم احفظ." />
        <EmptyState
          icon={ShoppingCart}
          title="لا يوجد متجر متاح لك"
          description="لا يمكنك إنشاء عملية بيع بدون متجر نشط ضمن نطاق صلاحياتك — تواصل مع مدير النظام."
        />
      </div>
    );
  }

  return (
    <div>
      <PageHeader title="عملية بيع جديدة" description="أدخل بيانات العملية والبنود، ثم اضغط «حفظ عملية البيع»." />
      <SalesEntryForm lookups={lookups} />
    </div>
  );
}

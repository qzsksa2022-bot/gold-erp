import { Undo2 } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { getReturnableSalesOrder, getReturnsOperableStoreLookups } from "@/features/returns/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { ReturnOrderSearch } from "@/features/returns/components/return-order-search";
import { ReturnEntryForm, type ReturnableOrder } from "@/features/returns/components/return-entry-form";

export default async function NewReturnPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await requirePermission("returns.create");
  const sp = await searchParams;
  const salesOrderId = typeof sp.sales_order_id === "string" ? sp.sales_order_id : undefined;

  if (!salesOrderId) {
    return (
      <div>
        <PageHeader title="مرتجع جديد" description="ابحث عن عملية البيع المراد إرجاع بنود منها." />
        <ReturnOrderSearch />
      </div>
    );
  }

  let order: ReturnableOrder;
  try {
    order = (await getReturnableSalesOrder(salesOrderId)) as unknown as ReturnableOrder;
  } catch {
    return (
      <div>
        <PageHeader title="مرتجع جديد" description="ابحث عن عملية البيع المراد إرجاع بنود منها." />
        <EmptyState icon={Undo2} title="عملية البيع غير موجودة" description="لم يتم العثور على عملية البيع، أو أنها غير متاحة لك." />
      </div>
    );
  }

  const operableStores = await getReturnsOperableStoreLookups();

  return (
    <div>
      <PageHeader title="مرتجع جديد" description={`إرجاع بنود من عملية البيع ${order.order_number}`} />
      {operableStores.length === 0 ? (
        <EmptyState icon={Undo2} title="لا يوجد متجر متاح لك" description="لا يمكنك معالجة مرتجع بدون متجر نشط ضمن نطاق صلاحياتك — تواصل مع مدير النظام." />
      ) : (
        <ReturnEntryForm mode="create" order={order} stores={operableStores} />
      )}
    </div>
  );
}

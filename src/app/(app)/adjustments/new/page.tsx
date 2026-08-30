import { Wrench } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import {
  searchSalesOrdersForAdjustment,
  getAdjustmentsOperableStoreLookups,
  getAdjustmentsActiveTypeLookups,
  getAdjustmentsPaymentMethodLookups,
  getAdjustmentsCollectionChannelLookups,
} from "@/features/adjustments/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { AdjustmentOrderSearch } from "@/features/adjustments/components/adjustment-order-search";
import { AdjustmentEntryForm } from "@/features/adjustments/components/adjustment-entry-form";

export default async function NewAdjustmentPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const session = await requirePermission("adjustments.create");
  const canManageCost = session.isSuperAdmin || sessionHasPermission(session, "adjustments.manage_cost");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : undefined);

  const salesOrderId = str("sales_order_id");
  const orderNumber = str("order_number");

  if (!salesOrderId || !orderNumber) {
    return (
      <div>
        <PageHeader title="تعديل/خدمة جديد" description="ابحث عن عملية بيع لبدء تعديل/خدمة جديد مرتبط بها." />
        <AdjustmentOrderSearch />
      </div>
    );
  }

  // Re-resolve the exact order via the same narrow search RPC used to find
  // it (§25 provides only search-by-text, no get-by-id lookup) — the search
  // matches by order number, so filtering by order_number is exact.
  const orderMatches = await searchSalesOrdersForAdjustment(orderNumber);
  const order = orderMatches.find((o) => o.sales_order_id === salesOrderId);

  if (!order) {
    return (
      <div>
        <PageHeader title="تعديل/خدمة جديد" description="ابحث عن عملية بيع لبدء تعديل/خدمة جديد." />
        <EmptyState icon={Wrench} title="عملية البيع غير موجودة" description="لم يتم العثور على عملية البيع، أو أنها غير متاحة لك." />
      </div>
    );
  }

  const [operableStores, types, paymentMethods, collectionChannels] = await Promise.all([
    getAdjustmentsOperableStoreLookups(),
    getAdjustmentsActiveTypeLookups(),
    getAdjustmentsPaymentMethodLookups(),
    getAdjustmentsCollectionChannelLookups(),
  ]);

  if (operableStores.length === 0) {
    return (
      <div>
        <PageHeader title="تعديل/خدمة جديد" description={`إنشاء تعديل/خدمة لعملية البيع ${order.order_number}`} />
        <EmptyState icon={Wrench} title="لا يوجد متجر متاح لك" description="لا يمكنك إنشاء تعديل/خدمة بدون متجر نشط ضمن نطاق صلاحياتك — تواصل مع مدير النظام." />
      </div>
    );
  }

  if (types.length === 0) {
    return (
      <div>
        <PageHeader title="تعديل/خدمة جديد" description={`إنشاء تعديل/خدمة لعملية البيع ${order.order_number}`} />
        <EmptyState icon={Wrench} title="لا يوجد نوع تعديل/خدمة نشط" description="لم يتم إعداد أي نوع تعديل/خدمة نشط بعد — تواصل مع مدير النظام لإضافة نوع من صفحة البيانات الأساسية." />
      </div>
    );
  }

  return (
    <div>
      <PageHeader title="تعديل/خدمة جديد" description={`إنشاء تعديل/خدمة لعملية البيع ${order.order_number}`} />
      <AdjustmentEntryForm order={order} stores={operableStores} types={types} paymentMethods={paymentMethods} collectionChannels={collectionChannels} mode="create" canManageCost={canManageCost} />
    </div>
  );
}

import { Truck } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { searchSalesOrdersForShipment, searchSalesReturnsForShipment, getShipmentsOperableStoreLookups, getShipmentsCarrierLookups, getShipmentsZoneLookups } from "@/features/shipping/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { ShipmentOrderSearch } from "@/features/shipping/components/shipment-order-search";
import { ShipmentEntryForm } from "@/features/shipping/components/shipment-entry-form";

export default async function NewShipmentPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await requirePermission("shipments.create");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : undefined);

  const salesOrderId = str("sales_order_id");
  const orderNumber = str("order_number");
  const direction = str("direction") === "return" ? "return" : "outbound";
  const salesReturnId = str("sales_return_id");

  if (!salesOrderId || !orderNumber) {
    return (
      <div>
        <PageHeader title="شحنة جديدة" description="ابحث عن عملية بيع (شحنة ذهاب) أو مرتجع معتمَد (شحنة إرجاع) لبدء شحنة جديدة." />
        <ShipmentOrderSearch />
      </div>
    );
  }

  // Re-resolve the exact order via the same narrow search RPC used to find
  // it (Section 38 provides only search-by-text, no get-by-id lookup) —
  // order_number is UNIQUE, so filtering the search results by id is exact.
  const orderMatches = await searchSalesOrdersForShipment(orderNumber);
  const order = orderMatches.find((o) => o.id === salesOrderId);

  if (!order) {
    return (
      <div>
        <PageHeader title="شحنة جديدة" description="ابحث عن عملية بيع أو مرتجع معتمَد لبدء شحنة جديدة." />
        <EmptyState icon={Truck} title="عملية البيع غير موجودة" description="لم يتم العثور على عملية البيع، أو أنها غير متاحة لك." />
      </div>
    );
  }

  let existingReturn: { id: string; return_number: string; return_date: string; status: string } | undefined;
  if (direction === "return") {
    if (!salesReturnId) {
      return (
        <div>
          <PageHeader title="شحنة جديدة" description="ابحث عن مرتجع معتمَد لبدء شحنة إرجاع." />
          <ShipmentOrderSearch />
        </div>
      );
    }
    const returnMatches = await searchSalesReturnsForShipment({ salesOrderId });
    const found = returnMatches.find((r) => r.id === salesReturnId);
    if (!found) {
      return (
        <div>
          <PageHeader title="شحنة جديدة" description="ابحث عن مرتجع معتمَد لبدء شحنة إرجاع." />
          <EmptyState icon={Truck} title="المرتجع غير موجود" description="لم يتم العثور على المرتجع، أو أنه غير معتمَد/متاح لك." />
        </div>
      );
    }
    existingReturn = { id: found.id, return_number: found.return_number, return_date: found.return_date, status: found.status };
  }

  const [operableStores, carriers, zones] = await Promise.all([getShipmentsOperableStoreLookups(), getShipmentsCarrierLookups(), getShipmentsZoneLookups()]);

  if (operableStores.length === 0) {
    return (
      <div>
        <PageHeader title="شحنة جديدة" description={`إنشاء شحنة لعملية البيع ${order.order_number}`} />
        <EmptyState icon={Truck} title="لا يوجد متجر متاح لك" description="لا يمكنك إنشاء شحنة بدون متجر نشط ضمن نطاق صلاحياتك — تواصل مع مدير النظام." />
      </div>
    );
  }

  return (
    <div>
      <PageHeader
        title="شحنة جديدة"
        description={direction === "outbound" ? `شحنة ذهاب لعملية البيع ${order.order_number}` : `شحنة إرجاع للمرتجع ${existingReturn?.return_number ?? "—"}`}
      />
      <ShipmentEntryForm order={order} existingReturn={existingReturn} direction={direction} stores={operableStores} carriers={carriers} zones={zones} />
    </div>
  );
}

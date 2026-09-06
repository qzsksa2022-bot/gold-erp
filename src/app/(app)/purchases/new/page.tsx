import { requirePermission } from "@/lib/permissions/guard";
import { getActiveSuppliers } from "@/features/purchases/queries";
import { getInventoryOperableStoreLookups, getInventoryActiveItemLookups } from "@/features/inventory/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { PurchaseInvoiceForm } from "@/features/purchases/components/purchase-invoice-form";
import { Users } from "lucide-react";

export default async function NewPurchasePage() {
  await requirePermission("purchases.create");

  // Writes use the OPERABLE store scope, reads use the visible one — the RPC
  // re-enforces the operable scope regardless of what this form offers.
  const [suppliers, stores, items] = await Promise.all([getActiveSuppliers(), getInventoryOperableStoreLookups(), getInventoryActiveItemLookups()]);

  return (
    <div>
      <PageHeader
        title="فاتورة شراء جديدة"
        description="تُرحَّل الفاتورة وتُدخل كمياتها للمخزون في عملية واحدة غير قابلة للتجزئة — إما أن ينجح الاثنان معًا أو لا يُكتب شيء."
      />

      {suppliers.length === 0 ? (
        <EmptyState icon={Users} title="لا يوجد موردون نشطون" description="أضف مورّدًا نشطًا أولًا من شاشة الموردين لتتمكن من ترحيل فاتورة شراء." />
      ) : (
        <PurchaseInvoiceForm stores={stores} suppliers={suppliers} items={items} />
      )}
    </div>
  );
}

import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getPendingAdjustmentForEdit, searchSalesOrdersForAdjustment, getAdjustmentsOperableStoreLookups, getAdjustmentsActiveTypeLookups, getAdjustmentsPaymentMethodLookups, getAdjustmentsCollectionChannelLookups } from "@/features/adjustments/queries";
import { PageHeader } from "@/components/shared/page-header";
import { AdjustmentEntryForm } from "@/features/adjustments/components/adjustment-entry-form";

// Patch 6.1 item 23 (migration 0152) — uses get_pending_sales_order_
// adjustment_for_edit(), gated on adjustments.create ALONE (never
// adjustments.view), closing the hidden-permission-dependency bug: a
// create-only actor (no adjustments.view) can now land here — both right
// after creating (see adjustment-entry-form.tsx's post-create redirect) and
// on any later revisit — without being denied. The narrow getter is
// explicitly pending-only by construction (throws/returns nothing for an
// approved/rejected/nonexistent id), so a not-found here already covers
// "not pending anymore" — no separate effective_status redirect needed.
export default async function EditAdjustmentPage({ params }: { params: Promise<{ id: string }> }) {
  const session = await requirePermission("adjustments.create");
  const canManageCost = session.isSuperAdmin || sessionHasPermission(session, "adjustments.manage_cost");
  const { id } = await params;

  let adj: Awaited<ReturnType<typeof getPendingAdjustmentForEdit>>;
  try {
    adj = await getPendingAdjustmentForEdit(id);
  } catch {
    notFound();
  }

  const orderMatches = await searchSalesOrdersForAdjustment(adj.order_number);
  const order = orderMatches.find((o) => o.sales_order_id === adj.sales_order_id) ?? {
    sales_order_id: adj.sales_order_id,
    order_number: adj.order_number,
    sale_date: adj.adjustment_date,
    store_name: null,
    customer_name: null,
    original_invoice_amount: "—",
  };

  const [operableStores, types, paymentMethods, collectionChannels] = await Promise.all([
    getAdjustmentsOperableStoreLookups(),
    getAdjustmentsActiveTypeLookups(),
    getAdjustmentsPaymentMethodLookups(),
    getAdjustmentsCollectionChannelLookups(),
  ]);

  return (
    <div>
      {/* get_pending_sales_order_adjustment_for_edit() (0152) deliberately omits adjustment_number — it's not a form input — so the title uses the linked Sale's order_number instead, which the narrow getter DOES return. */}
      <PageHeader title="تعديل تعديل/خدمة" description={`تعديل بيانات التعديل/الخدمة لعملية البيع ${adj.order_number} — متاح فقط بينما الحالة "قيد الانتظار"`} />
      <AdjustmentEntryForm
        order={order}
        stores={operableStores}
        types={types}
        paymentMethods={paymentMethods}
        collectionChannels={collectionChannels}
        mode="edit"
        canManageCost={canManageCost}
        existing={{
          id: adj.id,
          row_version: adj.row_version,
          adjustment_type_id: adj.adjustment_type_id,
          processing_store_id: adj.processing_store_id,
          adjustment_date: adj.adjustment_date,
          payment_method_id: adj.payment_method_id,
          collection_channel_id: adj.collection_channel_id,
          payment_reference: adj.payment_reference,
          participates_in_settlement: adj.participates_in_settlement,
          customer_charge: adj.customer_charge,
          has_direct_cost: adj.has_direct_cost,
          direct_cost: adj.direct_cost,
          notes: adj.notes,
        }}
      />
    </div>
  );
}

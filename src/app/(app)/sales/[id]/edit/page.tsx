import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/permissions/guard";
import { getSalesOrderDetail, getSalesOrderEditLookups } from "@/features/sales/queries";
import { PageHeader } from "@/components/shared/page-header";
import { SalesEntryForm } from "@/features/sales/components/sales-entry-form";

type OrderDetail = {
  id: string;
  order_number: string;
  store_id: string;
  // Patch 3.2 item 8 (migration 0079) -- get_sales_order() now resolves
  // this itself, so the Edit page no longer needs its own fallback query
  // (or the old "inject the order's own store if it fell outside operable
  // scope" workaround below) just to display the store's name; store_id
  // itself remains immutable/read-only here either way.
  store_name: string | null;
  sale_date: string;
  payment_method_id: string;
  collection_channel_id: string;
  customer_name: string | null;
  customer_phone: string | null;
  notes: string | null;
  is_day_closed: boolean;
  // Patch 3.2 item 2 (migration 0075/0079) -- optimistic-concurrency token;
  // must be threaded through to the Edit form and sent back as
  // p_expected_version on every Preview/Save.
  row_version: number;
  items: {
    id: string;
    category_id: string;
    karat_id: string;
    weight_grams: string;
    sale_price: string;
    item_name: string | null;
    description: string | null;
  }[];
};

export default async function EditSalePage({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission("sales.edit");
  const { id } = await params;

  let order: OrderDetail;
  try {
    order = (await getSalesOrderDetail(id)) as unknown as OrderDetail;
  } catch {
    notFound();
  }

  // Patch 3.2 item 6 (migration 0080) -- historical-inclusive lookups
  // scoped to this exact order, replacing the active-only
  // getSalesFormLookups() the New Sale form uses: active options plus this
  // order's own currently-used category/karat/payment-method/collection-
  // channel value even if it has since gone inactive.
  const editLookups = await getSalesOrderEditLookups(id);

  return (
    <div>
      <PageHeader title={`تعديل ${order.order_number}`} description="المتجر وتاريخ البيع غير قابلين للتعديل في هذا الإصدار." />
      {/*
        Hotfix 3.2.1 item 1 -- `key={order.row_version}` is load-bearing,
        not decorative. SalesEntryForm's own local useState (items,
        paymentMethodId, collectionChannelId, customer fields, notes) is
        seeded ONCE from `existingOrder` at mount and is never re-derived
        from a later prop update -- and router.refresh() (fired by the
        Conflict banner's "تحديث الصفحة" button) re-renders this Server
        Component with a fresh `order` WITHOUT unmounting the already-
        mounted client component, per Next.js's App Router semantics.
        Without a key tied to row_version, a user who reloads after a
        Conflict would still be looking at (and could still Save) the
        stale pre-Conflict form values under the NEW row_version, silently
        clobbering the other user's just-committed edit -- exactly the
        Lost Update optimistic concurrency exists to prevent. Changing
        `key` forces React to unmount the stale instance and mount a
        brand-new one, so EVERY piece of local state (not just the
        row_version/conflict flag) is re-initialized from the fresh
        `order`. See tests/sales-entry-form-conflict-reload.test.tsx.
      */}
      <SalesEntryForm key={order.row_version} editLookups={editLookups} existingOrder={order} />
    </div>
  );
}

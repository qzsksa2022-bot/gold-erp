import { notFound, redirect } from "next/navigation";
import { requirePermission } from "@/lib/permissions/guard";
import { getSalesReturnDetail, getReturnableSalesOrder, getReturnsOperableStoreLookups } from "@/features/returns/queries";
import { PageHeader } from "@/components/shared/page-header";
import { ReturnEntryForm, type ReturnableOrder, type ExistingReturn } from "@/features/returns/components/return-entry-form";
import { ROUTES } from "@/lib/constants";

type ReturnDetailForEdit = ExistingReturn & {
  id: string;
  return_number: string;
  sales_order_id: string;
  status: "pending" | "approved" | "rejected" | "reversed";
};

export default async function EditReturnPage({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission("returns.create");
  const { id } = await params;

  let existingReturn: ReturnDetailForEdit;
  try {
    existingReturn = (await getSalesReturnDetail(id)) as unknown as ReturnDetailForEdit;
  } catch {
    notFound();
  }

  // Only a still-'pending' return may be edited — mirrors update_pending_
  // sales_return()'s own status guard (migration 0086). Send an already-
  // decided return back to its read-only detail page instead of a dead-end
  // form.
  if (existingReturn.status !== "pending") {
    redirect(`${ROUTES.returns}/${existingReturn.id}`);
  }

  const [order, operableStores] = await Promise.all([
    getReturnableSalesOrder(existingReturn.sales_order_id) as Promise<unknown> as Promise<ReturnableOrder>,
    getReturnsOperableStoreLookups(),
  ]);

  return (
    <div>
      <PageHeader title={`تعديل ${existingReturn.return_number}`} description="المتجر المعالِج وتاريخ المرتجع غير قابلين للتعديل." />
      {/*
        `key={existingReturn.row_version}` mirrors the Sales Edit page's own
        load-bearing key (see src/app/(app)/sales/[id]/edit/page.tsx) — it
        forces a full remount (re-initializing every local field, including
        the version-conflict banner) whenever the user reloads after a
        Conflict, instead of leaving stale local state mounted over a fresh
        row_version.
      */}
      <ReturnEntryForm key={existingReturn.row_version} mode="edit" order={order} stores={operableStores} existingReturn={existingReturn} />
    </div>
  );
}

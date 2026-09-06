import { Users } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { getSuppliers } from "@/features/purchases/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { SupplierCreateDialog, SupplierEditDialog, SupplierStatusToggle } from "@/features/purchases/components/supplier-dialogs";

export default async function SuppliersPage() {
  // Reading the catalogue only needs purchases.view; every WRITE control below
  // is additionally gated on purchases.manage_suppliers (and re-enforced by the
  // RPCs themselves, migration 0239).
  await requirePermission("purchases.view");

  const { rows } = await getSuppliers();

  return (
    <div>
      <PageHeader
        title="الموردون"
        description="قائمة عامة (غير مقيَّدة بفرع) للموردين. الرمز دائم، والمورّد لا يُحذف أبدًا — يُعطَّل فقط، حتى تبقى فواتير الشراء التاريخية قابلة للقراءة."
        actions={
          <Can permission="purchases.manage_suppliers">
            <SupplierCreateDialog />
          </Can>
        }
      />

      {rows.length === 0 ? (
        <EmptyState icon={Users} title="لا يوجد موردون" description="أضف مورّدًا لتتمكن من ترحيل فواتير الشراء." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>الرمز</TableHead>
                <TableHead>الاسم</TableHead>
                <TableHead className="hidden lg:table-cell">الرقم الضريبي</TableHead>
                <TableHead className="hidden sm:table-cell">التواصل</TableHead>
                <TableHead>الحالة</TableHead>
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
                  <TableCell className="hidden font-mono text-sm text-muted-foreground lg:table-cell" dir="ltr">
                    {row.vat_number ?? "—"}
                  </TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground sm:table-cell">
                    {row.contact_person ?? "—"}
                    {row.phone && (
                      <span className="ms-2 font-mono text-xs" dir="ltr">
                        {row.phone}
                      </span>
                    )}
                  </TableCell>
                  <TableCell>
                    <Badge variant={row.status === "active" ? "success" : "secondary"}>{row.status === "active" ? "نشط" : "معطّل"}</Badge>
                  </TableCell>
                  <TableCell>
                    <Can permission="purchases.manage_suppliers">
                      <div className="flex items-center justify-end gap-2">
                        <SupplierEditDialog supplier={row} />
                        <SupplierStatusToggle supplierId={row.id} status={row.status} supplierName={row.name_ar} />
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

import { Wrench } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { getAdjustmentTypesAdminList } from "@/features/adjustments/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { AdjustmentTypeFormDialog } from "@/features/adjustments/components/adjustment-type-form-dialog";
import { AdjustmentTypeStatusToggle } from "@/features/adjustments/components/adjustment-type-status-toggle";

export default async function AdjustmentTypesPage() {
  await requirePermission("adjustments.manage_types");
  const types = await getAdjustmentTypesAdminList();

  return (
    <div>
      <PageHeader
        title="أنواع التعديلات والخدمات"
        description="كل تعديل/خدمة جديد يُنشأ لاحقًا يجب أن يرتبط بنوع نشط من هذه القائمة — تعطيل نوع لا يؤثر على السجلات التاريخية التي تستخدمه."
        actions={
          <Can permission="adjustments.manage_types">
            <AdjustmentTypeFormDialog />
          </Can>
        }
      />

      {types.length === 0 ? (
        <EmptyState icon={Wrench} title="لا توجد أنواع تعديلات/خدمات بعد" description="ابدأ بإضافة أول نوع." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>النوع</TableHead>
                <TableHead className="hidden sm:table-cell">الرمز</TableHead>
                <TableHead className="hidden md:table-cell">الوصف</TableHead>
                <TableHead>الحالة</TableHead>
                <TableHead className="w-24 text-left">إجراءات</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {types.map((type) => (
                <TableRow key={type.id}>
                  <TableCell>
                    <div className="flex flex-col">
                      <span className="font-medium">{type.name_ar}</span>
                      {type.name_en && <span className="text-xs text-muted-foreground">{type.name_en}</span>}
                    </div>
                  </TableCell>
                  <TableCell className="hidden font-mono text-xs sm:table-cell" dir="ltr">
                    {type.code}
                  </TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground md:table-cell">{type.description ?? "—"}</TableCell>
                  <TableCell>
                    <Badge variant={type.status === "active" ? "success" : "secondary"}>{type.status === "active" ? "نشط" : "معطّل"}</Badge>
                  </TableCell>
                  <TableCell>
                    <div className="flex items-center justify-end gap-1">
                      <Can permission="adjustments.manage_types">
                        <AdjustmentTypeFormDialog type={type} />
                        <AdjustmentTypeStatusToggle typeId={type.id} status={type.status as "active" | "disabled"} typeName={type.name_ar} />
                      </Can>
                    </div>
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

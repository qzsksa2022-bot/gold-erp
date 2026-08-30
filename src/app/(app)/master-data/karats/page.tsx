import { Gem } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listKarats } from "@/features/karats/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Can } from "@/lib/permissions/context";
import { KaratFormDialog } from "@/features/karats/components/karat-form-dialog";
import { KaratStatusBadge } from "@/features/karats/components/karat-status-badge";
import { KaratStatusToggle } from "@/features/karats/components/karat-status-toggle";

export default async function KaratsPage() {
  await requirePermission("karats.view");
  const karats = await listKarats();

  return (
    <div>
      <PageHeader
        title="العيارات"
        description="عيارات الذهب المستخدمة في النظام — تُستخدم في أسعار الذهب والمصنعية. لا يُحذف عيار استُخدم سابقًا، فقط يُعطَّل."
        actions={
          <Can permission="karats.manage">
            <KaratFormDialog />
          </Can>
        }
      />

      {karats.length === 0 ? (
        <EmptyState icon={Gem} title="لا توجد عيارات بعد" description="ابدأ بإضافة أول عيار." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>العيار</TableHead>
                <TableHead className="hidden sm:table-cell">الكود</TableHead>
                <TableHead className="hidden md:table-cell">النقاء بالألف</TableHead>
                <TableHead>الحالة</TableHead>
                <TableHead className="w-24 text-left">إجراءات</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {karats.map((karat) => (
                <TableRow key={karat.id}>
                  <TableCell>
                    <div className="flex flex-col">
                      <span className="font-medium">{karat.name_ar}</span>
                      {karat.name_en && <span className="text-xs text-muted-foreground">{karat.name_en}</span>}
                    </div>
                  </TableCell>
                  <TableCell className="hidden font-mono text-xs sm:table-cell">{karat.code}</TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground md:table-cell">
                    {karat.purity_per_mille ?? "—"}
                  </TableCell>
                  <TableCell>
                    <KaratStatusBadge status={karat.status} />
                  </TableCell>
                  <TableCell>
                    <div className="flex items-center justify-end gap-1">
                      <Can permission="karats.manage">
                        <KaratFormDialog karat={karat} />
                        <KaratStatusToggle karatId={karat.id} status={karat.status} karatName={karat.name_ar} />
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

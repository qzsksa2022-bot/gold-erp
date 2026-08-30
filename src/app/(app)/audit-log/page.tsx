import { ScrollText } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { listAuditLogs, listAuditActors } from "@/features/audit-log/queries";
import { listSearchParamsSchema } from "@/lib/validation/common";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { AuditLogFilters } from "@/features/audit-log/components/audit-log-filters";
import { AuditLogDetailDialog } from "@/features/audit-log/components/audit-log-detail-dialog";
import { auditActionLabel, auditEntityLabel } from "@/lib/audit/action-labels";
import { formatRiyadhDateTime } from "@/lib/date";

export default async function AuditLogPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await requirePermission("audit_logs.view");
  const sp = await searchParams;
  const { q, page, pageSize } = listSearchParamsSchema.parse(sp);
  const userId = typeof sp.userId === "string" ? sp.userId : "";
  const action = typeof sp.action === "string" ? sp.action : "";
  const entityType = typeof sp.entityType === "string" ? sp.entityType : "";

  const [{ logs, total }, actors] = await Promise.all([
    listAuditLogs({ q, userId, action, entityType, page, pageSize }),
    listAuditActors(),
  ]);

  return (
    <div>
      <PageHeader title="سجل الأحداث" description="سجل كامل بكل العمليات الإدارية والأمنية الحساسة في النظام." />

      <AuditLogFilters q={q} userId={userId} action={action} entityType={entityType} actors={actors} />

      {logs.length === 0 ? (
        <EmptyState icon={ScrollText} title="لا توجد أحداث مطابقة" description="جرّب تعديل الفلاتر أو كلمة البحث." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>العملية</TableHead>
                <TableHead className="hidden sm:table-cell">النوع</TableHead>
                <TableHead>المستخدم</TableHead>
                <TableHead className="hidden md:table-cell">التاريخ</TableHead>
                <TableHead className="w-16 text-left">التفاصيل</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {logs.map((log) => (
                <TableRow key={log.id}>
                  <TableCell className="font-medium">{auditActionLabel(log.action)}</TableCell>
                  <TableCell className="hidden sm:table-cell">
                    <Badge variant="outline">{auditEntityLabel(log.entity_type)}</Badge>
                  </TableCell>
                  <TableCell className="text-sm">{log.actor?.full_name ?? "—"}</TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground md:table-cell">
                    {formatRiyadhDateTime(log.created_at)}
                  </TableCell>
                  <TableCell>
                    <AuditLogDetailDialog log={log} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <Pagination
            page={page}
            pageSize={pageSize}
            total={total}
            buildHref={(p) => `/audit-log?${new URLSearchParams({ q, userId, action, entityType, page: String(p) }).toString()}`}
          />
        </div>
      )}
    </div>
  );
}

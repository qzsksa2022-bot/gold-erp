"use client";

import { useState } from "react";
import { Eye } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { auditActionLabel, auditEntityLabel } from "@/lib/audit/action-labels";
import { formatRiyadhDateTime } from "@/lib/date";
import type { Json } from "@/types/database";

type LogRow = {
  id: string;
  action: string;
  entity_type: string;
  entity_id: string | null;
  old_values: Json | null;
  new_values: Json | null;
  reason: string | null;
  ip_address: string | null;
  user_agent: string | null;
  created_at: string;
  actor: { full_name: string; email: string } | null;
};

function JsonBlock({ value }: { value: Json | null }) {
  if (value === null || value === undefined) return <span className="text-muted-foreground">—</span>;
  return (
    <pre className="max-h-56 overflow-auto rounded-md bg-secondary/60 p-3 text-xs" dir="ltr">
      {JSON.stringify(value, null, 2)}
    </pre>
  );
}

export function AuditLogDetailDialog({ log }: { log: LogRow }) {
  const [open, setOpen] = useState(false);

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label="عرض التفاصيل">
        <Eye className="size-4" />
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-w-xl">
          <DialogHeader>
            <DialogTitle>{auditActionLabel(log.action)}</DialogTitle>
          </DialogHeader>
          <ScrollArea className="max-h-[65vh] pe-3">
            <div className="flex flex-col gap-4 text-sm">
              <div className="grid grid-cols-2 gap-3">
                <Field label="المستخدم" value={log.actor ? `${log.actor.full_name} (${log.actor.email})` : "غير معروف / قبل الدخول"} />
                <Field label="التاريخ" value={formatRiyadhDateTime(log.created_at)} />
                <Field label="النوع" value={auditEntityLabel(log.entity_type)} />
                <Field label="المعرّف" value={log.entity_id ?? "—"} mono />
                <Field label="عنوان IP" value={log.ip_address ?? "—"} mono />
                <Field label="السبب" value={log.reason ?? "—"} />
              </div>
              <div>
                <p className="mb-1.5 text-xs font-semibold text-muted-foreground">القيم السابقة</p>
                <JsonBlock value={log.old_values} />
              </div>
              <div>
                <p className="mb-1.5 text-xs font-semibold text-muted-foreground">القيم الجديدة</p>
                <JsonBlock value={log.new_values} />
              </div>
              {log.user_agent && (
                <div>
                  <p className="mb-1.5 text-xs font-semibold text-muted-foreground">User Agent</p>
                  <p className="break-all text-xs text-muted-foreground" dir="ltr">
                    {log.user_agent}
                  </p>
                </div>
              )}
            </div>
          </ScrollArea>
        </DialogContent>
      </Dialog>
    </>
  );
}

function Field({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div>
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className={mono ? "font-mono text-xs" : "text-sm"}>{value}</p>
    </div>
  );
}

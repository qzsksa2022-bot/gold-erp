"use client";

import { useState } from "react";
import { AlertTriangle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

/**
 * Mandatory-reason dialog for creating/editing a Sale on an already-closed
 * business day (spec §20) — only ever opened after the server has already
 * rejected the first attempt with the closed-day error (see isClosedDayError
 * in ../schema.ts), never shown speculatively. The reason typed here is
 * sent straight through to create_sales_order()/update_sales_order()'s
 * p_closed_day_reason, which the DB requires to be non-empty and writes
 * into audit_logs as the `sale.closed_day_update` event's reason column —
 * this component only collects it, the DB is what actually enforces and
 * records it.
 */
export function ClosedDayReasonDialog({
  open,
  onOpenChange,
  onConfirm,
  isPending,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onConfirm: (reason: string) => void;
  isPending: boolean;
}) {
  const [reason, setReason] = useState("");

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <AlertTriangle className="size-5 text-warning" />
            اليوم مغلق — سبب إلزامي
          </DialogTitle>
          <DialogDescription>
            هذا اليوم مُقفل لهذا المتجر. لديك صلاحية التعديل بعد الإقفال، لكن يجب إدخال سبب واضح — سيُسجَّل السبب في سجل الأحداث
            مرتبطًا بهذه العملية.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-1.5">
          <Label htmlFor="closed_day_reason">السبب</Label>
          <Textarea
            id="closed_day_reason"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="مثال: تصحيح خطأ في سعر البيع تم اكتشافه بعد الإقفال"
            disabled={isPending}
            rows={3}
          />
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)} disabled={isPending}>
            إلغاء
          </Button>
          <Button
            variant="accent"
            disabled={isPending || reason.trim().length === 0}
            onClick={() => onConfirm(reason.trim())}
          >
            تأكيد ومتابعة
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

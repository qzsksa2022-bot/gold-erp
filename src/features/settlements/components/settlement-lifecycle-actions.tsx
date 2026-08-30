"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Ban, CheckCircle2, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Can } from "@/lib/permissions/context";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";
import { riyadhTodayIsoDate } from "@/lib/date";
import { reconcileSettlementBatchAction, cancelSettlementBatchAction } from "../actions";
import { isClosedDayError, isVarianceReasonRequiredError } from "../schema";

/**
 * Status-driven action set for the Settlement Batch detail page —
 * reconcile only reachable from 'finalized', cancel reachable from
 * 'finalized' or 'reconciled' (never 'draft', never an already-cancelled
 * batch — effectiveStatus already folds cancellation in, item 17).
 */
export function SettlementLifecycleActions({ batchId, settlementNumber, effectiveStatus, rowVersion }: { batchId: string; settlementNumber: string; effectiveStatus: string; rowVersion: number }) {
  if (effectiveStatus === "draft" || effectiveStatus === "cancelled") return null;

  return (
    <div className="flex items-center gap-2">
      {effectiveStatus === "finalized" && (
        <Can permission="settlements.reconcile">
          <ReconcileDialog batchId={batchId} rowVersion={rowVersion} />
        </Can>
      )}
      <Can permission="settlements.cancel">
        <CancelDialog batchId={batchId} settlementNumber={settlementNumber} rowVersion={rowVersion} />
      </Can>
    </div>
  );
}

function ReconcileDialog({ batchId, rowVersion }: { batchId: string; rowVersion: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [pendingVarianceReason, setPendingVarianceReason] = useState(false);
  const [varianceReason, setVarianceReason] = useState("");
  const [isPending, startTransition] = useTransition();

  function submit(reason?: string) {
    startTransition(async () => {
      const result = await reconcileSettlementBatchAction({ id: batchId, row_version: rowVersion, variance_reason: reason });
      if (result.success) {
        toast.success(result.message ?? "تمت مطابقة دفعة التسوية");
        setOpen(false);
        setPendingVarianceReason(false);
        router.refresh();
        return;
      }

      if (!reason && isVarianceReasonRequiredError(result.error)) {
        setPendingVarianceReason(true);
        return;
      }

      toast.error(result.error);
    });
  }

  return (
    <>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogTrigger asChild>
          <Button variant="accent">
            <CheckCircle2 className="size-4" />
            مطابقة
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>مطابقة دفعة التسوية</DialogTitle>
            <DialogDescription>سيُحسب الفعلي البنكي والفرق حيًا من سجل الحركات البنكية المسجَّلة. إذا وُجد فرق، سيُطلب منك سبب قبل المتابعة.</DialogDescription>
          </DialogHeader>

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="accent" onClick={() => submit()} disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تأكيد المطابقة
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={pendingVarianceReason} onOpenChange={setPendingVarianceReason}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>يوجد فرق مطابقة — سبب إلزامي</DialogTitle>
            <DialogDescription>الفعلي البنكي المسجَّل لا يساوي المتوقع بنكيًا لهذه الدفعة. يجب إدخال سبب واضح — سيُسجَّل مرتبطًا بهذه المطابقة.</DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-1.5">
            <Label>سبب الفرق</Label>
            <Textarea value={varianceReason} onChange={(e) => setVarianceReason(e.target.value)} disabled={isPending} rows={3} />
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setPendingVarianceReason(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="accent" disabled={isPending || varianceReason.trim().length === 0} onClick={() => submit(varianceReason.trim())}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تأكيد ومتابعة
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

function CancelDialog({ batchId, settlementNumber, rowVersion }: { batchId: string; settlementNumber: string; rowVersion: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(riyadhTodayIsoDate());
  const [reason, setReason] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await cancelSettlementBatchAction({ id: batchId, row_version: rowVersion, cancellation_business_date: date, reason: reason.trim(), closed_day_reason: closedDayReason });
      if (result.success) {
        toast.success(result.message ?? "تم إلغاء دفعة التسوية");
        setOpen(false);
        setPendingCloseReason(false);
        router.refresh();
        return;
      }

      if (!closedDayReason && isClosedDayError(result.error)) {
        setPendingCloseReason(true);
        return;
      }
      toast.error(result.error);
    });
  }

  return (
    <>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogTrigger asChild>
          <Button variant="outline" className="text-destructive">
            <Ban className="size-4" />
            إلغاء الدفعة
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>إلغاء دفعة التسوية {settlementNumber}</DialogTitle>
            <DialogDescription>
              لا يمكن الإلغاء إلا بعد عكس كل الحركات البنكية المسجَّلة على هذه الدفعة (إن وجدت) عبر زر عكس الحركة البنكية أولًا. الإلغاء يحرر كل المصادر المحجوزة لهذه الدفعة ليصبح بالإمكان تسويتها ضمن دفعة أخرى — دون المساس بسجل الدفعة أو سطورها أو تاريخ مطابقتها. يجب إدخال سبب الإلغاء.
            </DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-1.5">
            <Label>سبب الإلغاء</Label>
            <Textarea value={reason} onChange={(e) => setReason(e.target.value)} disabled={isPending} rows={3} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>تاريخ الإلغاء</Label>
            <Input type="date" dir="ltr" value={date} onChange={(e) => setDate(e.target.value)} disabled={isPending} />
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              تراجع
            </Button>
            <Button variant="destructive" onClick={() => submit()} disabled={isPending || reason.trim().length === 0 || !date}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تأكيد الإلغاء
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason) => submit(reason)} />
    </>
  );
}

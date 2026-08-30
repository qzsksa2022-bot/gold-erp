"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { CheckCircle2, XCircle, Undo2, Loader2, Pencil } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Can } from "@/lib/permissions/context";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";
import { riyadhTodayIsoDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { approveAdjustmentAction, rejectAdjustmentAction, reverseAdjustmentAction } from "../actions";
import { isClosedDayError } from "../schema";

/**
 * Status-driven action set for the Adjustment/Service detail page —
 * approve/reject/edit only reachable from 'pending', reverse only from
 * 'approved' (mirrors ReturnLifecycleActions exactly, but on top of the
 * fully independent Adjustments engine — no Settlement/Return/Shipping
 * interaction anywhere in this file).
 */
export function AdjustmentLifecycleActions({
  adjustmentId,
  adjustmentNumber,
  effectiveStatus,
  rowVersion,
  hasDirectCost,
}: {
  adjustmentId: string;
  adjustmentNumber: string;
  effectiveStatus: string;
  rowVersion: number;
  hasDirectCost?: boolean;
}) {
  if (effectiveStatus === "pending") {
    return (
      <div className="flex items-center gap-2">
        <Can permission="adjustments.create">
          <Button asChild variant="outline">
            <Link href={`${ROUTES.adjustments}/${adjustmentId}/edit`}>
              <Pencil className="size-4" />
              تعديل
            </Link>
          </Button>
        </Can>
        <RejectDialog adjustmentId={adjustmentId} rowVersion={rowVersion} />
        <ApproveDialog adjustmentId={adjustmentId} adjustmentNumber={adjustmentNumber} rowVersion={rowVersion} hasDirectCost={hasDirectCost} />
      </div>
    );
  }

  if (effectiveStatus === "approved") {
    return (
      <Can permission="adjustments.reverse">
        <ReverseDialog adjustmentId={adjustmentId} rowVersion={rowVersion} />
      </Can>
    );
  }

  return null;
}

function ApproveDialog({ adjustmentId, adjustmentNumber, rowVersion, hasDirectCost }: { adjustmentId: string; adjustmentNumber: string; rowVersion: number; hasDirectCost?: boolean }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await approveAdjustmentAction({ id: adjustmentId, row_version: rowVersion, closed_day_reason: closedDayReason });

      if (result.success) {
        toast.success(result.message ?? `تم اعتماد التعديل/الخدمة رقم ${adjustmentNumber}`);
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
      <Can permission="adjustments.approve">
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild>
            <Button variant="accent">
              <CheckCircle2 className="size-4" />
              اعتماد
            </Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>اعتماد التعديل/الخدمة {adjustmentNumber}</DialogTitle>
              <DialogDescription>سيتم احتساب عمولة الدفع والربح الإجمالي والصافي نهائيًا من بيانات النظام الحالية عند الاعتماد. تتطلب هذه الخطوة إدخال التكلفة المباشرة مسبقًا (حتى لخدمة مجانية بقيمة تحصيل صفر).</DialogDescription>
            </DialogHeader>

            {hasDirectCost === false && (
              <p className="rounded-md border border-warning/40 bg-warning/10 p-2 text-xs text-warning">
                لم تُدخَل التكلفة المباشرة بعد لهذا التعديل/الخدمة — سيُرفض الاعتماد حتى يقوم من يملك صلاحية إدارة التكلفة المباشرة (adjustments.manage_cost) بإدخالها من صفحة التعديل.
              </p>
            )}

            <DialogFooter>
              <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
                إلغاء
              </Button>
              <Button variant="accent" onClick={() => submit()} disabled={isPending || hasDirectCost === false}>
                {isPending && <Loader2 className="size-4 animate-spin" />}
                تأكيد الاعتماد
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      </Can>

      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason) => submit(reason)} />
    </>
  );
}

function RejectDialog({ adjustmentId, rowVersion }: { adjustmentId: string; rowVersion: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [isPending, startTransition] = useTransition();

  function submit() {
    startTransition(async () => {
      const result = await rejectAdjustmentAction({ id: adjustmentId, row_version: rowVersion, reason: reason.trim() });
      if (result.success) {
        toast.success(result.message ?? "تم رفض التعديل/الخدمة");
        setOpen(false);
        router.refresh();
      } else {
        toast.error(result.error);
      }
    });
  }

  return (
    <Can permission="adjustments.approve">
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogTrigger asChild>
          <Button variant="outline">
            <XCircle className="size-4" />
            رفض
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>رفض التعديل/الخدمة</DialogTitle>
            <DialogDescription>لن يُعتمد هذا التعديل/الخدمة ولن يُحتسب عليه أي ربح. يجب إدخال سبب الرفض.</DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-1.5">
            <Label>سبب الرفض</Label>
            <Textarea value={reason} onChange={(e) => setReason(e.target.value)} disabled={isPending} rows={3} />
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="destructive" onClick={submit} disabled={isPending || reason.trim().length === 0}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تأكيد الرفض
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Can>
  );
}

function ReverseDialog({ adjustmentId, rowVersion }: { adjustmentId: string; rowVersion: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [reversalDate, setReversalDate] = useState(riyadhTodayIsoDate());
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await reverseAdjustmentAction({
        id: adjustmentId,
        row_version: rowVersion,
        reversal_business_date: reversalDate,
        reason: reason.trim(),
        closed_day_reason: closedDayReason,
      });
      if (result.success) {
        toast.success(result.message ?? "تم عكس التعديل/الخدمة");
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
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" className="text-destructive">
          <Undo2 className="size-4" />
          عكس إداري
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>العكس الإداري للتعديل/الخدمة</DialogTitle>
          <DialogDescription>
            هذا تصحيح إداري وليس آلية استرداد للعميل. ستبقى القيم المالية الأصلية محفوظة تاريخيًا عند تاريخ التعديل، وسيُسجَّل أثر
            العكس بتاريخ منفصل. يجب إدخال سبب العكس.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-1.5">
          <Label>سبب العكس</Label>
          <Textarea value={reason} onChange={(e) => setReason(e.target.value)} disabled={isPending} rows={3} />
        </div>

        <div className="flex flex-col gap-1.5">
          <Label>تاريخ عملية العكس</Label>
          <Input type="date" dir="ltr" value={reversalDate} onChange={(e) => setReversalDate(e.target.value)} disabled={isPending} />
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
            إلغاء
          </Button>
          <Button variant="destructive" onClick={() => submit()} disabled={isPending || reason.trim().length === 0 || !reversalDate}>
            {isPending && <Loader2 className="size-4 animate-spin" />}
            تأكيد العكس
          </Button>
        </DialogFooter>
      </DialogContent>
      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason2) => submit(reason2)} />
    </Dialog>
  );
}

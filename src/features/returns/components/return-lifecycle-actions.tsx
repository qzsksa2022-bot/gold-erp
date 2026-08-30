"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { CheckCircle2, XCircle, Undo2, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Can } from "@/lib/permissions/context";
import { approveSalesReturnAction, rejectSalesReturnAction, reverseSalesReturnAction, refreshPendingSalesReturnAction } from "../actions";
import { isClosedDayError, isStaleSaleError, isSaleRefreshRequiredError } from "../schema";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";

/**
 * Status-driven action set for the Return detail page — approve/reject are
 * only reachable from 'pending', reverse only from 'approved' (mirrors
 * approve_sales_return()/reject_sales_return()/reverse_sales_return()'s own
 * status guards). Each action is gated both by <Can> (UX only) and
 * requirePermission() server-side inside the action. Patch 4.1 (Section 4)
 * adds a "refresh from Sale" action for a Pending return whose parent Sale
 * has changed since creation.
 */
export function ReturnLifecycleActions({ returnId, returnNumber, status, rowVersion }: { returnId: string; returnNumber: string; status: string; rowVersion: number }) {
  if (status === "pending") {
    return (
      <div className="flex items-center gap-2">
        <RefreshFromSaleButton returnId={returnId} rowVersion={rowVersion} />
        <RejectDialog returnId={returnId} rowVersion={rowVersion} />
        <ApproveDialog returnId={returnId} returnNumber={returnNumber} rowVersion={rowVersion} />
      </div>
    );
  }

  if (status === "approved") {
    return (
      <Can permission="returns.reverse">
        <ReverseDialog returnId={returnId} rowVersion={rowVersion} />
      </Can>
    );
  }

  return null;
}

/**
 * Patch 4.1 (Section 4) — the explicit refresh path: never triggered
 * automatically by approve_sales_return()'s stale-sale rejection, only by
 * the user choosing this button after seeing that rejection (or
 * proactively, before attempting approval).
 */
function RefreshFromSaleButton({ returnId, rowVersion }: { returnId: string; rowVersion: number }) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();

  function submit() {
    startTransition(async () => {
      const result = await refreshPendingSalesReturnAction({ return_id: returnId, row_version: rowVersion });
      if (result.success) {
        toast.success(result.message ?? "تم تحديث بيانات المرتجع من أحدث نسخة لعملية البيع");
        router.refresh();
      } else {
        toast.error(result.error);
      }
    });
  }

  return (
    <Can permission="returns.create">
      <Button variant="outline" onClick={submit} disabled={isPending}>
        {isPending && <Loader2 className="size-4 animate-spin" />}
        تحديث من عملية البيع
      </Button>
    </Can>
  );
}

function ApproveDialog({ returnId, returnNumber, rowVersion }: { returnId: string; returnNumber: string; rowVersion: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [feeOverride, setFeeOverride] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [staleSale, setStaleSale] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await approveSalesReturnAction({
        return_id: returnId,
        row_version: rowVersion,
        fee_reversal_override: feeOverride || undefined,
        closed_day_reason: closedDayReason,
      });

      if (result.success) {
        toast.success(result.message ?? `تم اعتماد المرتجع رقم ${returnNumber}`);
        setOpen(false);
        setPendingCloseReason(false);
        router.refresh();
        return;
      }

      if (!closedDayReason && isClosedDayError(result.error)) {
        setPendingCloseReason(true);
        return;
      }

      // Patch 4.2 (Section 1) — requires_sale_refresh is a distinct guard
      // from the pre-existing row_version-mismatch stale-sale check above;
      // both are resolved the exact same way (the "تحديث من عملية البيع"
      // button), so they share this one banner/flag.
      if (isStaleSaleError(result.error) || isSaleRefreshRequiredError(result.error)) {
        setStaleSale(true);
      }

      toast.error(result.error);
    });
  }

  return (
    <>
      <Can permission="returns.approve">
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild>
            <Button variant="accent">
              <CheckCircle2 className="size-4" />
              اعتماد المرتجع
            </Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>اعتماد المرتجع {returnNumber}</DialogTitle>
              <DialogDescription>
                سيتم حساب مبالغ رد المبيعات والربح واسترداد العمولة نهائيًا عند الاعتماد. إذا كانت سياسة استرداد العمولة لطريقة
                الدفع &quot;يدوي&quot;، أدخل القيمة أدناه — بخلاف ذلك اتركها فارغة.
              </DialogDescription>
            </DialogHeader>

            {staleSale && (
              <div className="rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-sm text-warning-foreground">
                بيانات عملية البيع لهذا المرتجع قديمة أو تحتاج تحديثًا صريحًا. أغلق هذا الحوار واستخدم زر &quot;تحديث من عملية البيع&quot; قبل إعادة محاولة الاعتماد.
              </div>
            )}

            <div className="flex flex-col gap-1.5">
              <Label>قيمة استرداد العمولة يدويًا (عند الحاجة فقط)</Label>
              <Input type="number" step="0.01" min="0" dir="ltr" value={feeOverride} onChange={(e) => setFeeOverride(e.target.value)} disabled={isPending} />
            </div>

            <DialogFooter>
              <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
                إلغاء
              </Button>
              <Button variant="accent" onClick={() => submit()} disabled={isPending}>
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

function RejectDialog({ returnId, rowVersion }: { returnId: string; rowVersion: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [isPending, startTransition] = useTransition();

  function submit() {
    startTransition(async () => {
      const result = await rejectSalesReturnAction({ return_id: returnId, row_version: rowVersion, rejection_reason: reason.trim() });
      if (result.success) {
        toast.success(result.message ?? "تم رفض المرتجع");
        setOpen(false);
        router.refresh();
      } else {
        toast.error(result.error);
      }
    });
  }

  return (
    <Can permission="returns.approve">
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogTrigger asChild>
          <Button variant="outline">
            <XCircle className="size-4" />
            رفض المرتجع
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>رفض المرتجع</DialogTitle>
            <DialogDescription>لن يتم اعتماد هذا المرتجع، ولن يُحتسب عليه أي رد مبيعات أو ربح. يجب إدخال سبب الرفض.</DialogDescription>
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

function ReverseDialog({ returnId, rowVersion }: { returnId: string; rowVersion: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [businessDate, setBusinessDate] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await reverseSalesReturnAction({
        return_id: returnId,
        row_version: rowVersion,
        reversal_reason: reason.trim(),
        reversal_business_date: businessDate || undefined,
        closed_day_reason: closedDayReason,
      });
      if (result.success) {
        toast.success(result.message ?? "تم التراجع عن المرتجع");
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
          التراجع عن الاعتماد
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>التراجع عن اعتماد المرتجع</DialogTitle>
          <DialogDescription>
            ستبقى مبالغ رد المبيعات والربح المحسوبة عند الاعتماد محفوظة تاريخيًا، لكن هذا المرتجع لن يُحتسب بعد الآن ضمن حالة
            العملية، وستصبح بنوده قابلة للإرجاع مجددًا. يجب إدخال سبب التراجع.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-1.5">
          <Label>سبب التراجع</Label>
          <Textarea value={reason} onChange={(e) => setReason(e.target.value)} disabled={isPending} rows={3} />
        </div>

        <div className="flex flex-col gap-1.5">
          <Label>تاريخ عملية التراجع (اختياري — الافتراضي اليوم)</Label>
          <Input type="date" dir="ltr" value={businessDate} onChange={(e) => setBusinessDate(e.target.value)} disabled={isPending} />
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
            إلغاء
          </Button>
          <Button variant="destructive" onClick={() => submit()} disabled={isPending || reason.trim().length === 0}>
            {isPending && <Loader2 className="size-4 animate-spin" />}
            تأكيد التراجع
          </Button>
        </DialogFooter>
      </DialogContent>
      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason2) => submit(reason2)} />
    </Dialog>
  );
}

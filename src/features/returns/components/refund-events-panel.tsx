"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Plus, Undo2, BadgeCheck, History, LockOpen } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { formatRiyadhDateTime } from "@/lib/date";
import { recordSalesReturnRefundAction, reverseSalesReturnRefundEventAction, finalizeSalesReturnRefundAction, reopenSalesReturnRefundReconciliationAction } from "../actions";
import { isClosedDayError, REFUND_RECONCILIATION_STATE_LABELS_AR } from "../schema";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";

// Patch 4.2 (Section 7) — narrowed to the {id, name_ar} shape
// returns_refund_method_lookups() (migration 0105) returns, gated on
// returns.record_refund rather than the Master Data payment_methods.view.
type PaymentMethod = { id: string; name_ar: string };

// Patch 4.2 (Section 4) — one row of the append-only sales_return_refund_
// reconciliation_events history (migration 0099/0103), surfaced by
// get_sales_return() (0104). Never mutated/deleted — a 'finalized' event
// followed later by a 'reopened' event followed by a second 'finalized'
// event is the expected shape of a corrected reconciliation.
export type ReconciliationHistoryEvent = {
  id: string;
  event_type: "finalized" | "reopened";
  actual_refunded_total: string;
  approved_refund_amount: string | null;
  variance: string;
  reason: string | null;
  actor: string | null;
  created_at: string;
};

const RECONCILIATION_EVENT_LABELS_AR: Record<string, string> = {
  finalized: "تسوية",
  reopened: "إعادة فتح",
};

type RefundEvent = {
  id: string;
  amount: string;
  refund_method_id: string;
  // Hotfix 4.2.1 (Section 17) — stable historical label captured at record
  // time by record_sales_return_refund() (migration 0107), so the Detail
  // view never depends on payment_methods.view or the method's CURRENT
  // name. Backfilled once for pre-existing events (migration 0106).
  refund_method_name_snapshot?: string | null;
  // Hotfix 4.2.1 (Section 6) — optional external reference (bank transfer
  // number, payment-gateway reference, internal reference).
  reference?: string | null;
  refund_business_date?: string | null;
  refunded_at: string;
  notes: string | null;
  // Hotfix 4.2.1 (Sections 1/4) — DERIVED by get_sales_return() (migration
  // 0111) from the presence/absence of a row in sales_return_refund_event_
  // reversals — never read off a mutated original event row anymore (the
  // original row is genuinely append-only/trigger-protected, migration
  // 0106/0107).
  status: "active" | "reversed";
  reversed_at: string | null;
  reversal_business_date?: string | null;
  reversal_reason: string | null;
};

const RECONCILIATION_BADGE_VARIANT: Record<string, "warning" | "success" | "destructive" | "secondary"> = {
  not_applicable: "secondary",
  pending: "warning",
  finalized_matched: "success",
  finalized_with_variance: "destructive",
};

/**
 * The actual-cash-refund ledger (sales_return_refund_events, migration
 * 0082/0089) — fully independent from sales_returns.approved_refund_amount
 * (the computed target). "تسجيل استرداد" is only offered on an 'approved'
 * return (mirrors record_sales_return_refund()'s own status guard); each
 * active event can be individually reversed (soft-void, never edited).
 * Patch 4.1 (Section 9/11) adds business-date inputs to record/reverse, and
 * a finalize_sales_return_refund() reconciliation step usable on 'approved'
 * or 'reversed' returns.
 */
export function RefundEventsPanel({
  returnId,
  returnStatus,
  rowVersion,
  refundEvents,
  refundMethods,
  approvedRefundAmount,
  actualRefundedTotal,
  refundReconciliationState,
  refundFinalizedAt,
  refundFinalVarianceReason,
  reconciliationHistory,
}: {
  returnId: string;
  returnStatus: string;
  rowVersion: number;
  refundEvents: RefundEvent[];
  refundMethods: PaymentMethod[];
  approvedRefundAmount: string | null;
  actualRefundedTotal: string;
  refundReconciliationState?: string | null;
  refundFinalizedAt?: string | null;
  refundFinalVarianceReason?: string | null;
  reconciliationHistory?: ReconciliationHistoryEvent[];
}) {
  const canFinalize = (returnStatus === "approved" || returnStatus === "reversed") && !refundFinalizedAt;
  // Patch 4.2 (Section 4) — the explicit Reopen workflow: only offered once
  // reconciliation is actually Finalized. After it succeeds, record/reverse
  // refund-ledger actions become possible again and canFinalize flips back
  // to true (refundFinalizedAt is cleared by reopen_sales_return_refund_
  // reconciliation()), so both buttons never show at once.
  const canReopen = (returnStatus === "approved" || returnStatus === "reversed") && !!refundFinalizedAt;

  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between">
        <CardTitle className="text-base">الاسترداد النقدي الفعلي</CardTitle>
        <div className="flex items-center gap-2">
          {/* Hotfix 4.2.1 (Section 16) — Record Refund must be hidden once
              reconciliation is Finalized, not merely rejected server-side
              with a "Reopen first" error. The DB (record_sales_return_
              refund(), migration 0107) remains the real backstop. */}
          {returnStatus === "approved" && !refundFinalizedAt && (
            <Can permission="returns.record_refund">
              <RecordRefundDialog returnId={returnId} refundMethods={refundMethods} />
            </Can>
          )}
          {canFinalize && (
            <Can permission="returns.record_refund">
              <FinalizeRefundDialog returnId={returnId} rowVersion={rowVersion} approvedRefundAmount={approvedRefundAmount} actualRefundedTotal={actualRefundedTotal} />
            </Can>
          )}
          {canReopen && (
            <Can permission="returns.record_refund">
              <ReopenReconciliationDialog returnId={returnId} rowVersion={rowVersion} />
            </Can>
          )}
        </div>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        <div className="grid grid-cols-2 gap-4 text-sm">
          <div>
            <div className="text-muted-foreground">المستهدف (approved_refund_amount)</div>
            <div className="font-medium" dir="ltr">
              {approvedRefundAmount ?? "—"}
            </div>
          </div>
          <div>
            <div className="text-muted-foreground">إجمالي المسترد فعليًا</div>
            <div className="font-bold" dir="ltr">
              {actualRefundedTotal}
            </div>
          </div>
        </div>

        {refundReconciliationState && (
          <div className="flex flex-col gap-1">
            <div className="flex items-center gap-2">
              <span className="text-sm text-muted-foreground">حالة التسوية</span>
              <Badge variant={RECONCILIATION_BADGE_VARIANT[refundReconciliationState] ?? "secondary"}>
                {REFUND_RECONCILIATION_STATE_LABELS_AR[refundReconciliationState as keyof typeof REFUND_RECONCILIATION_STATE_LABELS_AR] ?? refundReconciliationState}
              </Badge>
              {refundFinalizedAt && <span className="text-xs text-muted-foreground">({formatRiyadhDateTime(refundFinalizedAt)})</span>}
            </div>
            {refundFinalVarianceReason && <span className="text-xs text-muted-foreground">سبب الفارق: {refundFinalVarianceReason}</span>}
          </div>
        )}

        {refundEvents.length === 0 ? (
          <p className="text-sm text-muted-foreground">لا يوجد أي استرداد نقدي فعلي مسجَّل بعد.</p>
        ) : (
          <div className="flex flex-col divide-y divide-border rounded-lg border border-border">
            {refundEvents.map((event) => (
              <div key={event.id} className="flex items-center justify-between gap-3 px-4 py-3 text-sm">
                <div className="flex flex-col gap-0.5">
                  <span className="font-medium" dir="ltr">
                    {event.amount} ر.س
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {formatRiyadhDateTime(event.refunded_at)}
                    {event.refund_method_name_snapshot ? ` · ${event.refund_method_name_snapshot}` : ""}
                  </span>
                  {event.reference && <span className="text-xs text-muted-foreground">مرجع: {event.reference}</span>}
                  {event.notes && <span className="text-xs text-muted-foreground">{event.notes}</span>}
                  {event.status === "reversed" && event.reversal_reason && (
                    <span className="text-xs text-destructive">تراجع: {event.reversal_reason}</span>
                  )}
                </div>
                {event.status === "reversed" ? (
                  <Badge variant="warning">متراجَع عنه</Badge>
                ) : (
                  // Hotfix 4.2.1 (Section 16) — Reverse must also be hidden
                  // once reconciliation is Finalized (previously only the
                  // event's own status gated this button, so a Finalized
                  // active event still showed a Reverse button that always
                  // failed server-side demanding Reopen first).
                  !refundFinalizedAt && (
                    <Can permission="returns.record_refund">
                      <ReverseRefundEventDialog eventId={event.id} />
                    </Can>
                  )
                )}
              </div>
            ))}
          </div>
        )}

        {!!reconciliationHistory?.length && (
          <div className="flex flex-col gap-2">
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <History className="size-4" />
              سجل تسوية الاسترداد
            </div>
            <div className="flex flex-col divide-y divide-border rounded-lg border border-border">
              {reconciliationHistory.map((ev) => (
                <div key={ev.id} className="flex flex-col gap-1 px-4 py-3 text-sm">
                  <div className="flex items-center justify-between gap-2">
                    <Badge variant={ev.event_type === "finalized" ? "success" : "warning"}>{RECONCILIATION_EVENT_LABELS_AR[ev.event_type] ?? ev.event_type}</Badge>
                    <span className="text-xs text-muted-foreground">{formatRiyadhDateTime(ev.created_at)}</span>
                  </div>
                  <div className="grid grid-cols-3 gap-2 text-xs text-muted-foreground" dir="ltr">
                    <span>المسترد فعليًا: {ev.actual_refunded_total}</span>
                    <span>المستهدف: {ev.approved_refund_amount ?? "—"}</span>
                    <span>الفارق: {ev.variance}</span>
                  </div>
                  {ev.reason && <span className="text-xs text-muted-foreground">السبب: {ev.reason}</span>}
                </div>
              ))}
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  );
}

function RecordRefundDialog({ returnId, refundMethods }: { returnId: string; refundMethods: PaymentMethod[] }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState("");
  const [methodId, setMethodId] = useState("");
  const [businessDate, setBusinessDate] = useState("");
  const [notes, setNotes] = useState("");
  const [reference, setReference] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await recordSalesReturnRefundAction({
        return_id: returnId,
        amount,
        refund_method_id: methodId,
        refund_business_date: businessDate || undefined,
        notes: notes || undefined,
        closed_day_reason: closedDayReason,
        reference: reference || undefined,
      });
      if (result.success) {
        toast.success(result.message ?? "تم تسجيل الاسترداد");
        setOpen(false);
        setPendingCloseReason(false);
        setAmount("");
        setNotes("");
        setReference("");
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
          <Button variant="outline" size="sm">
            <Plus className="size-4" />
            تسجيل استرداد
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>تسجيل استرداد نقدي</DialogTitle>
            <DialogDescription>هذا السجل مستقل عن المبلغ المستهدف — يُستخدم للمطابقة لاحقًا، ولا يوجد حد أقصى مفروض هنا.</DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-4">
            <div className="flex flex-col gap-1.5">
              <Label>القيمة</Label>
              <Input type="number" step="0.01" min="0" dir="ltr" value={amount} onChange={(e) => setAmount(e.target.value)} disabled={isPending} />
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>طريقة الاسترداد</Label>
              <Select value={methodId} onValueChange={setMethodId} disabled={isPending}>
                <SelectTrigger>
                  <SelectValue placeholder="اختر طريقة الاسترداد" />
                </SelectTrigger>
                <SelectContent>
                  {refundMethods.map((m) => (
                    <SelectItem key={m.id} value={m.id}>
                      {m.name_ar}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>تاريخ عملية الاسترداد (اختياري — الافتراضي اليوم)</Label>
              <Input type="date" dir="ltr" value={businessDate} onChange={(e) => setBusinessDate(e.target.value)} disabled={isPending} />
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>ملاحظات (اختياري)</Label>
              <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>مرجع عملية الاسترداد (اختياري)</Label>
              <Input dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} disabled={isPending} />
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="accent" onClick={() => submit()} disabled={isPending || !amount || !methodId}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تسجيل
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason) => submit(reason)} />
    </>
  );
}

function ReverseRefundEventDialog({ eventId }: { eventId: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [businessDate, setBusinessDate] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await reverseSalesReturnRefundEventAction({
        event_id: eventId,
        reversal_reason: reason.trim(),
        reversal_business_date: businessDate || undefined,
        closed_day_reason: closedDayReason,
      });
      if (result.success) {
        toast.success(result.message ?? "تم التراجع عن الاسترداد");
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
          <Button variant="ghost" size="sm" className="text-destructive">
            <Undo2 className="size-4" />
            تراجع
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>التراجع عن سجل استرداد</DialogTitle>
            <DialogDescription>سيبقى هذا السجل ظاهرًا للتدقيق لكن لن يُحتسب ضمن إجمالي المسترد فعليًا. يجب إدخال سبب.</DialogDescription>
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
              تأكيد
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason2) => submit(reason2)} />
    </>
  );
}

/**
 * Patch 4.1 (Section 11) — reconciliation step, usable once on an 'approved'
 * or 'reversed' return. variance_reason is only required when the actual
 * refunded total differs from approved_refund_amount (enforced server-side
 * too, this is just a friendlier client nudge); supports the
 * approved_refund_amount=0 case reaching a final state with zero events.
 */
function FinalizeRefundDialog({
  returnId,
  rowVersion,
  approvedRefundAmount,
  actualRefundedTotal,
}: {
  returnId: string;
  rowVersion: number;
  approvedRefundAmount: string | null;
  actualRefundedTotal: string;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [varianceReason, setVarianceReason] = useState("");
  const [isPending, startTransition] = useTransition();

  const hasVariance = (approvedRefundAmount ?? "0") !== actualRefundedTotal;

  function submit() {
    startTransition(async () => {
      const result = await finalizeSalesReturnRefundAction({
        return_id: returnId,
        row_version: rowVersion,
        variance_reason: varianceReason.trim() || undefined,
      });
      if (result.success) {
        toast.success(result.message ?? "تمت تسوية الاسترداد");
        setOpen(false);
        router.refresh();
      } else {
        toast.error(result.error);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <BadgeCheck className="size-4" />
          تسوية الاسترداد
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تسوية الاسترداد النقدي</DialogTitle>
          <DialogDescription>
            يقارن هذا الإجراء إجمالي المسترد فعليًا بالمبلغ المستهدف ويقفل حالة المطابقة. لا يمكن التراجع عن هذا الإجراء لاحقًا.
          </DialogDescription>
        </DialogHeader>

        <div className="grid grid-cols-2 gap-4 text-sm">
          <div>
            <div className="text-muted-foreground">المستهدف</div>
            <div className="font-medium" dir="ltr">
              {approvedRefundAmount ?? "—"}
            </div>
          </div>
          <div>
            <div className="text-muted-foreground">المسترد فعليًا</div>
            <div className="font-medium" dir="ltr">
              {actualRefundedTotal}
            </div>
          </div>
        </div>

        {hasVariance && (
          <div className="flex flex-col gap-1.5">
            <Label>سبب الفارق (مطلوب)</Label>
            <Textarea value={varianceReason} onChange={(e) => setVarianceReason(e.target.value)} disabled={isPending} rows={3} />
          </div>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
            إلغاء
          </Button>
          <Button variant="accent" onClick={submit} disabled={isPending || (hasVariance && varianceReason.trim().length === 0)}>
            {isPending && <Loader2 className="size-4 animate-spin" />}
            تأكيد التسوية
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/**
 * Patch 4.2 (Section 4) — the explicit, reason-required escape hatch from a
 * Finalized reconciliation. Mirrors FinalizeRefundDialog's shape; a
 * mandatory reason is enforced client-side as a friendlier nudge, the DB
 * (reopen_sales_return_refund_reconciliation(), migration 0103) is the real
 * authority. Reopening does NOT erase the prior 'finalized' history entry —
 * it appends a new 'reopened' one (rendered above in reconciliationHistory)
 * and only then clears the CURRENT-state finalize columns, so record/
 * reverse refund-ledger actions become callable again and finalize can run
 * a second time.
 */
function ReopenReconciliationDialog({ returnId, rowVersion }: { returnId: string; rowVersion: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [isPending, startTransition] = useTransition();

  function submit() {
    startTransition(async () => {
      const result = await reopenSalesReturnRefundReconciliationAction({
        return_id: returnId,
        row_version: rowVersion,
        reason: reason.trim(),
      });
      if (result.success) {
        toast.success(result.message ?? "تمت إعادة فتح التسوية");
        setOpen(false);
        setReason("");
        router.refresh();
      } else {
        toast.error(result.error);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <LockOpen className="size-4" />
          إعادة فتح التسوية
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إعادة فتح تسوية الاسترداد</DialogTitle>
          <DialogDescription>
            يُستخدم هذا عندما تحتاج لتسجيل استرداد أو تراجع جديد بعد إغلاق التسوية سابقًا (مثلًا: تراجع عن المرتجع بعد استرداد كان قد تم بالفعل). لن يُحذف سجل التسوية السابق — سيُضاف كحدث جديد في السجل.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-1.5">
          <Label>سبب إعادة الفتح (مطلوب)</Label>
          <Textarea value={reason} onChange={(e) => setReason(e.target.value)} disabled={isPending} rows={3} />
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
            إلغاء
          </Button>
          <Button variant="accent" onClick={submit} disabled={isPending || reason.trim().length === 0}>
            {isPending && <Loader2 className="size-4 animate-spin" />}
            تأكيد إعادة الفتح
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Plus, Undo2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Can } from "@/lib/permissions/context";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";
import { formatRiyadhDate, riyadhTodayIsoDate } from "@/lib/date";
import { recordSettlementBankMovementAction, reverseSettlementBankMovementAction } from "../actions";
import { isClosedDayError } from "../schema";

type BankMovement = {
  id: string;
  movement_business_date: string;
  amount: string;
  bank_reference: string | null;
  notes: string | null;
  reversed: boolean;
  reversal_amount_impact: string | null;
};

/**
 * Append-only bank-movement ledger — record_settlement_bank_movement()
 * writes the ledger, reverse_settlement_bank_movement() writes the
 * ONE-AND-ONLY-EVER reversal of one event (never a raw edit/delete).
 *
 * Patch 7.1 §13 (migration 0188) split what used to be one combined gate
 * into two: a NEW movement is only recordable while the batch is
 * 'finalized' (reconciliation now freezes the actual/variance it was
 * computed against — a later movement would silently drift them), but
 * REVERSING an existing movement stays possible regardless of finalized/
 * reconciled status (§13 — Cancellation depends on every movement already
 * being reversible first, even on a reconciled batch). `hasPermission` is
 * the underlying settlements.record_bank_movement grant alone; the two
 * status-derived booleans below are computed here so no caller can
 * accidentally conflate "may add" with "may reverse" again.
 */
export function SettlementBankMovementsPanel({
  settlementBatchId,
  movements,
  hasPermission,
  effectiveStatus,
}: {
  settlementBatchId: string;
  movements: BankMovement[];
  hasPermission: boolean;
  effectiveStatus: string;
}) {
  const router = useRouter();
  const canAddNew = hasPermission && effectiveStatus === "finalized";
  const canReverse = hasPermission && (effectiveStatus === "finalized" || effectiveStatus === "reconciled");

  return (
    <div className="flex flex-col gap-3">
      {movements.length === 0 ? (
        <p className="text-xs text-muted-foreground">لا توجد أي حركة بنكية مسجَّلة بعد على هذه الدفعة.</p>
      ) : (
        <div className="flex flex-col divide-y divide-border rounded-md border border-border">
          {movements.map((m) => (
            <div key={m.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm">
              <div className="flex flex-col gap-0.5">
                <span className="font-mono" dir="ltr">
                  {formatRiyadhDate(m.movement_business_date)} — {m.amount}
                </span>
                <span className="text-xs text-muted-foreground">
                  {m.bank_reference ?? "بدون مرجع"}
                  {m.notes ? ` — ${m.notes}` : ""}
                </span>
              </div>
              <div className="flex items-center gap-2">
                {m.reversed ? (
                  <Badge variant="secondary">معكوسة ({m.reversal_amount_impact})</Badge>
                ) : (
                  <Can permission="settlements.record_bank_movement">
                    {canReverse && <ReverseMovementButton movementId={m.id} settlementBatchId={settlementBatchId} onDone={() => router.refresh()} />}
                  </Can>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {canAddNew && (
        <Can permission="settlements.record_bank_movement">
          <RecordMovementDialog settlementBatchId={settlementBatchId} onDone={() => router.refresh()} />
        </Can>
      )}
    </div>
  );
}

function RecordMovementDialog({ settlementBatchId, onDone }: { settlementBatchId: string; onDone: () => void }) {
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(riyadhTodayIsoDate());
  const [amount, setAmount] = useState("");
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await recordSettlementBankMovementAction({
        settlement_batch_id: settlementBatchId,
        movement_business_date: date,
        amount: amount.trim(),
        bank_reference: reference || undefined,
        notes: notes || undefined,
        closed_day_reason: closedDayReason,
      });
      if (result.success) {
        toast.success(result.message ?? "تم تسجيل الحركة البنكية");
        setOpen(false);
        setPendingCloseReason(false);
        setAmount("");
        setReference("");
        setNotes("");
        onDone();
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
            تسجيل حركة بنكية
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>تسجيل حركة بنكية</DialogTitle>
            <DialogDescription>القيمة الموجبة تعني إيداعًا/تحويلًا واردًا؛ القيمة السالبة تعني خصمًا/سحبًا — أدخل الإشارة الصحيحة.</DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-1.5">
            <Label>تاريخ الحركة</Label>
            <Input type="date" dir="ltr" value={date} onChange={(e) => setDate(e.target.value)} disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>القيمة (موجبة = إيداع، سالبة = خصم)</Label>
            <Input type="number" step="0.01" dir="ltr" value={amount} onChange={(e) => setAmount(e.target.value)} disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>المرجع البنكي (اختياري)</Label>
            <Input dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} disabled={isPending} maxLength={200} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>ملاحظات (اختياري)</Label>
            <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="accent" onClick={() => submit()} disabled={isPending || !amount.trim() || !date}>
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

function ReverseMovementButton({ movementId, settlementBatchId, onDone }: { movementId: string; settlementBatchId: string; onDone: () => void }) {
  const [open, setOpen] = useState(false);
  const [date, setDate] = useState(riyadhTodayIsoDate());
  const [reason, setReason] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await reverseSettlementBankMovementAction(
        { bank_movement_event_id: movementId, reversal_business_date: date, reason: reason.trim(), closed_day_reason: closedDayReason },
        settlementBatchId,
      );
      if (result.success) {
        toast.success(result.message ?? "تم عكس الحركة البنكية");
        setOpen(false);
        setPendingCloseReason(false);
        onDone();
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
          <Button variant="ghost" size="icon" aria-label="عكس الحركة البنكية">
            <Undo2 className="size-4 text-destructive" />
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>عكس الحركة البنكية</DialogTitle>
            <DialogDescription>يمكن عكس كل حركة بنكية مرة واحدة فقط. يجب إدخال سبب العكس.</DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-1.5">
            <Label>تاريخ العكس</Label>
            <Input type="date" dir="ltr" value={date} onChange={(e) => setDate(e.target.value)} disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>سبب العكس</Label>
            <Textarea value={reason} onChange={(e) => setReason(e.target.value)} disabled={isPending} rows={3} />
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="destructive" onClick={() => submit()} disabled={isPending || !reason.trim() || !date}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تأكيد العكس
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason) => submit(reason)} />
    </>
  );
}

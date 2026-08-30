"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Banknote } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Can } from "@/lib/permissions/context";
import { riyadhTodayIsoDate } from "@/lib/date";
import { recordShipmentActualCostAction, correctShipmentActualCostAction, correctShipmentCustomerChargeAction } from "../actions";
import { isClosedDayError } from "../schema";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";

/**
 * Financial-correction panel for the Shipment detail page (Sections
 * 18/19/20/33) — gated on shipments.manage_cost. hasActualCost decides
 * between "Record" (first time, record_shipment_actual_cost) and "Correct"
 * (already recorded, correct_shipment_actual_cost + mandatory reason) —
 * these are two distinct RPCs by design (0118), not one upsert.
 */
export function ShipmentFinancialActions({
  shipmentId,
  rowVersion,
  hasActualCost,
  currentActualCost,
  currentCustomerCharge,
}: {
  shipmentId: string;
  rowVersion: number;
  hasActualCost: boolean;
  currentActualCost: string | null;
  currentCustomerCharge: string | null;
}) {
  return (
    <Can permission="shipments.manage_cost">
      <div className="flex flex-wrap items-center gap-2">
        {hasActualCost ? (
          <CorrectActualCostDialog shipmentId={shipmentId} rowVersion={rowVersion} currentValue={currentActualCost} />
        ) : (
          <RecordActualCostDialog shipmentId={shipmentId} rowVersion={rowVersion} />
        )}
        <CorrectCustomerChargeDialog shipmentId={shipmentId} rowVersion={rowVersion} currentValue={currentCustomerCharge} />
      </div>
    </Can>
  );
}

function RecordActualCostDialog({ shipmentId, rowVersion }: { shipmentId: string; rowVersion: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState("");
  const [businessDate, setBusinessDate] = useState(riyadhTodayIsoDate());
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await recordShipmentActualCostAction({
        shipment_id: shipmentId,
        row_version: rowVersion,
        amount,
        business_date: businessDate,
        reference: reference || undefined,
        notes: notes || undefined,
        closed_day_reason: closedDayReason,
      });

      if (result.success) {
        toast.success(result.message ?? "تم تسجيل التكلفة الفعلية");
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
          <Button variant="outline">
            <Banknote className="size-4" />
            تسجيل التكلفة الفعلية
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>تسجيل التكلفة الفعلية لشركة الشحن</DialogTitle>
            <DialogDescription>يُسجَّل هذا مرة واحدة فقط — أي تعديل لاحق يتم عبر &quot;تصحيح التكلفة الفعلية&quot; مع سبب.</DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-1.5">
            <Label>المبلغ الفعلي</Label>
            <Input dir="ltr" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>تاريخ العملية المالية</Label>
            <Input type="date" dir="ltr" value={businessDate} onChange={(e) => setBusinessDate(e.target.value)} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>مرجع الفاتورة (اختياري)</Label>
            <Input dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>ملاحظات (اختياري)</Label>
            <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="accent" onClick={() => submit()} disabled={isPending || !amount || !businessDate}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تأكيد
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason) => submit(reason)} />
    </>
  );
}

function CorrectActualCostDialog({ shipmentId, rowVersion, currentValue }: { shipmentId: string; rowVersion: number; currentValue: string | null }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState(currentValue ?? "");
  const [businessDate, setBusinessDate] = useState(riyadhTodayIsoDate());
  const [reason, setReason] = useState("");
  const [reference, setReference] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await correctShipmentActualCostAction({
        shipment_id: shipmentId,
        row_version: rowVersion,
        amount,
        business_date: businessDate,
        reason: reason.trim(),
        reference: reference || undefined,
        closed_day_reason: closedDayReason,
      });

      if (result.success) {
        toast.success(result.message ?? "تم تصحيح التكلفة الفعلية");
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
          <Button variant="outline">
            <Banknote className="size-4" />
            تصحيح التكلفة الفعلية
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>تصحيح التكلفة الفعلية لشركة الشحن</DialogTitle>
            <DialogDescription>القيمة السابقة تبقى محفوظة في السجل التاريخي — هذا يضيف تصحيحًا جديدًا فوقها، ولا يحذف أي شيء.</DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-1.5">
            <Label>المبلغ الفعلي الجديد</Label>
            <Input dir="ltr" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>تاريخ العملية المالية</Label>
            <Input type="date" dir="ltr" value={businessDate} onChange={(e) => setBusinessDate(e.target.value)} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>سبب التصحيح</Label>
            <Textarea value={reason} onChange={(e) => setReason(e.target.value)} disabled={isPending} rows={2} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>مرجع الفاتورة (اختياري)</Label>
            <Input dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} disabled={isPending} />
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="accent" onClick={() => submit()} disabled={isPending || !amount || !businessDate || !reason.trim()}>
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

function CorrectCustomerChargeDialog({ shipmentId, rowVersion, currentValue }: { shipmentId: string; rowVersion: number; currentValue: string | null }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState(currentValue ?? "");
  const [businessDate, setBusinessDate] = useState(riyadhTodayIsoDate());
  const [reason, setReason] = useState("");
  const [reference, setReference] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await correctShipmentCustomerChargeAction({
        shipment_id: shipmentId,
        row_version: rowVersion,
        amount,
        business_date: businessDate,
        reason: reason.trim(),
        reference: reference || undefined,
        closed_day_reason: closedDayReason,
      });

      if (result.success) {
        toast.success(result.message ?? "تم تصحيح رسوم الشحن على العميل");
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
          <Button variant="outline">
            <Banknote className="size-4" />
            تصحيح رسوم الشحن على العميل
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>تصحيح رسوم الشحن على العميل</DialogTitle>
            <DialogDescription>القيمة الأصلية عند إنشاء الشحنة تبقى محفوظة كما هي — هذا يضيف تصحيحًا جديدًا في السجل ويُحدِّث صافي الربح المتوقع/الفعلي فقط.</DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-1.5">
            <Label>الرسوم الجديدة</Label>
            <Input dir="ltr" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>تاريخ العملية المالية</Label>
            <Input type="date" dir="ltr" value={businessDate} onChange={(e) => setBusinessDate(e.target.value)} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>سبب التصحيح</Label>
            <Textarea value={reason} onChange={(e) => setReason(e.target.value)} disabled={isPending} rows={2} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>مرجع (اختياري)</Label>
            <Input dir="ltr" value={reference} onChange={(e) => setReference(e.target.value)} disabled={isPending} />
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="accent" onClick={() => submit()} disabled={isPending || !amount || !businessDate || !reason.trim()}>
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

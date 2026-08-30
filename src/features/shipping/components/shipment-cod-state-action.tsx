"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Wallet, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Can } from "@/lib/permissions/context";
import { riyadhTodayIsoDate } from "@/lib/date";
import { recordShipmentCodCollectionStateAction } from "../actions";
import { COD_COLLECTION_STATES, COD_COLLECTION_STATE_LABELS_AR } from "../schema";
import { isClosedDayError } from "../schema";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";

/**
 * COD collection-state action for the Shipment detail page (Patch 5.1 items
 * 13/14, migration 0127) — gated on shipments.manage_cost, append-only
 * (record_shipment_cod_collection_state()). This is a Financial/Settlement-
 * adjacent event, so it is Daily-Close gated exactly like the actual-cost/
 * customer-charge corrections in ShipmentFinancialActions — never a plain
 * status flag toggle. currentState/suggestedNotCollected are display hints
 * only; the DB is the sole authority on what transitions are valid.
 */
export function ShipmentCodStateAction({
  shipmentId,
  rowVersion,
  currentState,
  suggestedNotCollected,
}: {
  shipmentId: string;
  rowVersion: number;
  currentState: string | null;
  suggestedNotCollected: boolean;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [newState, setNewState] = useState(suggestedNotCollected ? "not_collected" : "");
  const [businessDate, setBusinessDate] = useState(riyadhTodayIsoDate());
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit(closedDayReason?: string) {
    startTransition(async () => {
      const result = await recordShipmentCodCollectionStateAction({
        shipment_id: shipmentId,
        row_version: rowVersion,
        new_state: newState as (typeof COD_COLLECTION_STATES)[number],
        business_date: businessDate,
        reference: reference || undefined,
        notes: notes || undefined,
        closed_day_reason: closedDayReason,
      });

      if (result.success) {
        toast.success(result.message ?? "تم تسجيل حالة التحصيل");
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
    <Can permission="shipments.manage_cost">
      <div className="flex flex-wrap items-center gap-2">
        <div className="text-sm text-muted-foreground">
          الحالة الحالية: {currentState ? (COD_COLLECTION_STATE_LABELS_AR[currentState as keyof typeof COD_COLLECTION_STATE_LABELS_AR] ?? currentState) : "—"}
        </div>
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild>
            <Button variant="outline">
              <Wallet className="size-4" />
              تسجيل حالة التحصيل
            </Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>تسجيل حالة تحصيل الدفع عند الاستلام (COD)</DialogTitle>
              <DialogDescription>
                هذا سجل تراكمي (append-only) — كل تسجيل يُضاف كحدث جديد ولا يُعدَّل السجل السابق. لا يُغيَّر هذا تلقائيًا عند تغيير حالة الشحنة.
              </DialogDescription>
            </DialogHeader>

            <div className="flex flex-col gap-1.5">
              <Label>الحالة الجديدة</Label>
              <Select value={newState} onValueChange={setNewState} disabled={isPending}>
                <SelectTrigger>
                  <SelectValue placeholder="اختر الحالة" />
                </SelectTrigger>
                <SelectContent>
                  {COD_COLLECTION_STATES.map((s) => (
                    <SelectItem key={s} value={s}>
                      {COD_COLLECTION_STATE_LABELS_AR[s]}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>تاريخ العملية</Label>
              <Input type="date" dir="ltr" value={businessDate} onChange={(e) => setBusinessDate(e.target.value)} disabled={isPending} />
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>مرجع (اختياري)</Label>
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
              <Button variant="accent" onClick={() => submit()} disabled={isPending || !newState || !businessDate}>
                {isPending && <Loader2 className="size-4 animate-spin" />}
                تأكيد
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
        <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason) => submit(reason)} />
      </div>
    </Can>
  );
}

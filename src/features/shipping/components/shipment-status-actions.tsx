"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { RefreshCw, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Can } from "@/lib/permissions/context";
import { riyadhTodayIsoDate } from "@/lib/date";
import { addShipmentStatusEventAction } from "../actions";
import { SHIPMENT_STATUSES, SHIPMENT_STATUS_LABELS_AR } from "../schema";

/**
 * Status-update dialog for the Shipment detail page — every status is
 * offered (the DB's validate_shipment_status_transition(), 0116, is the
 * real authority on whether shipments.update_status alone is enough or
 * shipments.correct_status + a reason is required; the client does not
 * duplicate that state machine). If the server rejects a normal-looking
 * attempt because it is actually a correction, the reason field is
 * revealed and the actor can resubmit — never a dead-end error.
 */
export function ShipmentStatusActions({ shipmentId, currentStatus, rowVersion }: { shipmentId: string; currentStatus: string; rowVersion: number }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [newStatus, setNewStatus] = useState("");
  const [eventDate, setEventDate] = useState(riyadhTodayIsoDate());
  const [notes, setNotes] = useState("");
  const [reason, setReason] = useState("");
  const [needsReason, setNeedsReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  function submit() {
    startTransition(async () => {
      const result = await addShipmentStatusEventAction({
        shipment_id: shipmentId,
        row_version: rowVersion,
        new_status: newStatus as (typeof SHIPMENT_STATUSES)[number],
        event_business_date: eventDate,
        notes: notes || undefined,
        reason: reason || undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم تحديث حالة الشحنة");
        setOpen(false);
        setReason("");
        setNeedsReason(false);
        router.refresh();
        return;
      }

      if (result.error.includes("يتطلب تصحيح حالة") || result.error.includes("سبب لتصحيح")) {
        setNeedsReason(true);
      }

      toast.error(result.error);
    });
  }

  return (
    <Can anyOf={["shipments.update_status", "shipments.correct_status"]}>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogTrigger asChild>
          <Button variant="accent">
            <RefreshCw className="size-4" />
            تحديث الحالة
          </Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>تحديث حالة الشحنة</DialogTitle>
            <DialogDescription>الحالة الحالية: {SHIPMENT_STATUS_LABELS_AR[currentStatus as keyof typeof SHIPMENT_STATUS_LABELS_AR] ?? currentStatus}</DialogDescription>
          </DialogHeader>

          <div className="flex flex-col gap-1.5">
            <Label>الحالة الجديدة</Label>
            <Select value={newStatus} onValueChange={setNewStatus} disabled={isPending}>
              <SelectTrigger>
                <SelectValue placeholder="اختر الحالة" />
              </SelectTrigger>
              <SelectContent>
                {SHIPMENT_STATUSES.map((s) => (
                  <SelectItem key={s} value={s}>
                    {SHIPMENT_STATUS_LABELS_AR[s]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>تاريخ الحدث</Label>
            <Input type="date" dir="ltr" value={eventDate} onChange={(e) => setEventDate(e.target.value)} disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>ملاحظات (اختياري)</Label>
            <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
          </div>

          {needsReason && (
            <Can permission="shipments.correct_status">
              <div className="flex flex-col gap-1.5 rounded-lg border border-warning/40 bg-warning/5 p-3">
                <Label>هذا الانتقال يُعد تصحيحًا خارج التدفق الطبيعي — يجب إدخال السبب</Label>
                <Textarea value={reason} onChange={(e) => setReason(e.target.value)} disabled={isPending} rows={2} />
              </div>
            </Can>
          )}

          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
              إلغاء
            </Button>
            <Button variant="accent" onClick={submit} disabled={isPending || !newStatus || !eventDate || (needsReason && !reason.trim())}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تأكيد
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Can>
  );
}

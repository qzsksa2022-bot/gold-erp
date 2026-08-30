"use client";

import { useState, useTransition } from "react";
import { Loader2, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { riyadhTodayIsoDate } from "@/lib/date";
import { createCustomerReturnShippingFeeVersionAction } from "../actions";
import type { Zone } from "../queries";

/**
 * Create-a-new customer-return-shipping-fee-version dialog
 * (create_customer_return_shipping_fee_version(), migrations 0115/0122) —
 * RPC only. Same locked-when-preset behavior as CarrierRateVersionDialog.
 */
export function CustomerReturnFeeVersionDialog({ zones, preset, trigger }: { zones: Zone[]; preset?: { shippingZoneId: string }; trigger?: React.ReactNode }) {
  const [open, setOpen] = useState(false);
  const [shippingZoneId, setShippingZoneId] = useState(preset?.shippingZoneId ?? "");
  const [feeAmount, setFeeAmount] = useState("");
  const [effectiveFrom, setEffectiveFrom] = useState(riyadhTodayIsoDate());
  const [notes, setNotes] = useState("");
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [isPending, startTransition] = useTransition();

  const activeZones = zones.filter((z) => z.status === "active" || z.id === shippingZoneId);

  function submit() {
    setFieldErrors(undefined);
    startTransition(async () => {
      const result = await createCustomerReturnShippingFeeVersionAction({
        shipping_zone_id: shippingZoneId,
        fee_amount: feeAmount,
        effective_from: effectiveFrom,
        notes,
      });

      if (result.success) {
        toast.success(result.message ?? "تم إنشاء الإصدار بنجاح");
        setOpen(false);
        setFeeAmount("");
        setNotes("");
        return;
      }
      toast.error(result.error);
      setFieldErrors(result.fieldErrors);
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        {trigger ?? (
          <Button variant="accent">
            <Plus className="size-4" />
            إضافة رسوم إرجاع
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إصدار رسوم إرجاع جديد</DialogTitle>
          <DialogDescription>الرسوم المعيارية لشحن الإرجاع على العميل لهذه المنطقة — مستقلة تمامًا عن أي خصم/استرداد آخر في المرتجعات.</DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label>المنطقة</Label>
            <Select value={shippingZoneId} onValueChange={setShippingZoneId} disabled={isPending || Boolean(preset)}>
              <SelectTrigger>
                <SelectValue placeholder="اختر المنطقة" />
              </SelectTrigger>
              <SelectContent>
                {activeZones.map((z) => (
                  <SelectItem key={z.id} value={z.id}>
                    {z.name_ar}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="fee-amount">قيمة الرسوم</Label>
              <Input id="fee-amount" dir="ltr" inputMode="decimal" value={feeAmount} onChange={(e) => setFeeAmount(e.target.value)} disabled={isPending} />
              {fieldErrors?.fee_amount && <p className="text-xs font-medium text-destructive">{fieldErrors.fee_amount[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="fee-effective-from">تاريخ السريان</Label>
              <Input id="fee-effective-from" type="date" dir="ltr" value={effectiveFrom} onChange={(e) => setEffectiveFrom(e.target.value)} disabled={isPending} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="fee-notes">ملاحظات (اختياري)</Label>
            <Textarea id="fee-notes" value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
            إلغاء
          </Button>
          <Button variant="accent" onClick={submit} disabled={isPending || !shippingZoneId || !feeAmount || !effectiveFrom}>
            {isPending && <Loader2 className="size-4 animate-spin" />}
            إنشاء الإصدار
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

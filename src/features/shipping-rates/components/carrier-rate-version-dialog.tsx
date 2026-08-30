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
import { createShippingCarrierRateVersionAction } from "../actions";
import { SHIPMENT_RATE_DIRECTIONS, SHIPMENT_RATE_DIRECTION_LABELS_AR } from "../schema";
import type { Carrier, Zone } from "../queries";

/**
 * Create-a-new-rate-version dialog (create_shipping_carrier_rate_version(),
 * migrations 0114/0122) — RPC only, never a raw table write. When `preset`
 * is given (invoked from an existing carrier+zone+direction row), those
 * three fields are locked to that exact combination — this is a NEW
 * VERSION for an existing rate line, not a fresh combination. Without a
 * preset (the page-level "Add Rate" button), the actor picks all three,
 * which starts a brand-new rate line. The DB itself is the sole authority
 * on overlap/ordering — this dialog does not attempt to replicate that logic.
 */
export function CarrierRateVersionDialog({
  carriers,
  zones,
  preset,
  trigger,
}: {
  carriers: Carrier[];
  zones: Zone[];
  preset?: { carrierId: string; shippingZoneId: string; direction: string };
  trigger?: React.ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const [carrierId, setCarrierId] = useState(preset?.carrierId ?? "");
  const [shippingZoneId, setShippingZoneId] = useState(preset?.shippingZoneId ?? "");
  const [direction, setDirection] = useState(preset?.direction ?? "");
  const [baseCost, setBaseCost] = useState("");
  const [effectiveFrom, setEffectiveFrom] = useState(riyadhTodayIsoDate());
  const [notes, setNotes] = useState("");
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [isPending, startTransition] = useTransition();

  const activeCarriers = carriers.filter((c) => c.status === "active" || c.id === carrierId);
  const activeZones = zones.filter((z) => z.status === "active" || z.id === shippingZoneId);

  function submit() {
    setFieldErrors(undefined);
    startTransition(async () => {
      const result = await createShippingCarrierRateVersionAction({
        carrier_id: carrierId,
        shipping_zone_id: shippingZoneId,
        direction,
        base_cost: baseCost,
        effective_from: effectiveFrom,
        notes,
      });

      if (result.success) {
        toast.success(result.message ?? "تم إنشاء الإصدار بنجاح");
        setOpen(false);
        setBaseCost("");
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
            إضافة تسعير شحن
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إصدار تسعير شحن جديد</DialogTitle>
          <DialogDescription>
            لا يمكن تعديل تسعير سبق أن سرى — هذا يضيف إصدارًا جديدًا اعتبارًا من تاريخ سريان محدد ويُنهي الإصدار المفتوح الحالي تلقائيًا لهذه التركيبة.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label>شركة الشحن</Label>
            <Select value={carrierId} onValueChange={setCarrierId} disabled={isPending || Boolean(preset)}>
              <SelectTrigger>
                <SelectValue placeholder="اختر شركة الشحن" />
              </SelectTrigger>
              <SelectContent>
                {activeCarriers.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name_ar}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="grid grid-cols-2 gap-4">
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
            <div className="flex flex-col gap-1.5">
              <Label>الاتجاه</Label>
              <Select value={direction} onValueChange={setDirection} disabled={isPending || Boolean(preset)}>
                <SelectTrigger>
                  <SelectValue placeholder="اختر الاتجاه" />
                </SelectTrigger>
                <SelectContent>
                  {SHIPMENT_RATE_DIRECTIONS.map((d) => (
                    <SelectItem key={d} value={d}>
                      {SHIPMENT_RATE_DIRECTION_LABELS_AR[d]}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="rate-base-cost">التكلفة الأساسية</Label>
              <Input id="rate-base-cost" dir="ltr" inputMode="decimal" value={baseCost} onChange={(e) => setBaseCost(e.target.value)} disabled={isPending} />
              {fieldErrors?.base_cost && <p className="text-xs font-medium text-destructive">{fieldErrors.base_cost[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="rate-effective-from">تاريخ السريان</Label>
              <Input id="rate-effective-from" type="date" dir="ltr" value={effectiveFrom} onChange={(e) => setEffectiveFrom(e.target.value)} disabled={isPending} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="rate-notes">ملاحظات (اختياري)</Label>
            <Textarea id="rate-notes" value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
            إلغاء
          </Button>
          <Button variant="accent" onClick={submit} disabled={isPending || !carrierId || !shippingZoneId || !direction || !baseCost || !effectiveFrom}>
            {isPending && <Loader2 className="size-4 animate-spin" />}
            إنشاء الإصدار
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

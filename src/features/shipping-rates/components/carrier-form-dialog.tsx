"use client";

import { useState, useTransition } from "react";
import { Loader2, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { createShippingCarrierAction, updateShippingCarrierAction } from "../actions";
import { SHIPPING_CARRIER_TYPES, SHIPPING_CARRIER_TYPE_LABELS_AR } from "../schema";
import type { Carrier } from "../queries";

/**
 * Create/edit dialog for shipping_carriers — a direct table write gated on
 * shipping_rates.manage (migration 0113/0124). `code` is only enterable at
 * creation — immutable after that (0124's DB trigger), so the edit form
 * simply never offers the field, matching the DB truth rather than relying
 * on the trigger to reject a silent attempt.
 */
export function CarrierFormDialog({ carrier }: { carrier?: Carrier }) {
  const isEdit = Boolean(carrier);
  const [open, setOpen] = useState(false);
  const [code, setCode] = useState(carrier?.code ?? "");
  const [nameAr, setNameAr] = useState(carrier?.name_ar ?? "");
  const [nameEn, setNameEn] = useState(carrier?.name_en ?? "");
  const [carrierType, setCarrierType] = useState<string>(carrier?.carrier_type ?? "external");
  const [notes, setNotes] = useState(carrier?.notes ?? "");
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [isPending, startTransition] = useTransition();

  function submit() {
    setFieldErrors(undefined);
    startTransition(async () => {
      const payload = { code, name_ar: nameAr, name_en: nameEn, carrier_type: carrierType, notes };
      const result = isEdit ? await updateShippingCarrierAction(carrier!.id, payload) : await createShippingCarrierAction(payload);

      if (result.success) {
        toast.success(result.message ?? "تم الحفظ بنجاح");
        setOpen(false);
        return;
      }
      toast.error(result.error);
      setFieldErrors(result.fieldErrors);
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        {isEdit ? (
          <Button variant="ghost" size="icon" aria-label="تعديل شركة الشحن">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant="accent">
            <Plus className="size-4" />
            إضافة شركة شحن
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل شركة شحن" : "إضافة شركة شحن جديدة"}</DialogTitle>
          <DialogDescription>
            {isEdit ? "الكود ثابت ولا يمكن تعديله بعد الإنشاء." : "الكود يُستخدم كمفتاح داخلي ثابت — لا يمكن تعديله لاحقًا."}
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="carrier-code">الكود</Label>
              <Input
                id="carrier-code"
                dir="ltr"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="SMSA"
                disabled={isPending || isEdit}
              />
              {fieldErrors?.code && <p className="text-xs font-medium text-destructive">{fieldErrors.code[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label>نوع شركة الشحن</Label>
              <Select value={carrierType} onValueChange={setCarrierType} disabled={isPending}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {SHIPPING_CARRIER_TYPES.map((t) => (
                    <SelectItem key={t} value={t}>
                      {SHIPPING_CARRIER_TYPE_LABELS_AR[t]}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="carrier-name-ar">الاسم بالعربية</Label>
            <Input id="carrier-name-ar" value={nameAr} onChange={(e) => setNameAr(e.target.value)} placeholder="اس إم إس إيه" disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="carrier-name-en">الاسم بالإنجليزية (اختياري)</Label>
            <Input id="carrier-name-en" dir="ltr" value={nameEn} onChange={(e) => setNameEn(e.target.value)} placeholder="SMSA" disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="carrier-notes">ملاحظات (اختياري)</Label>
            <Textarea id="carrier-notes" value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
            إلغاء
          </Button>
          <Button variant="accent" onClick={submit} disabled={isPending || !code || !nameAr}>
            {isPending && <Loader2 className="size-4 animate-spin" />}
            {isEdit ? "حفظ التعديلات" : "إضافة شركة الشحن"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

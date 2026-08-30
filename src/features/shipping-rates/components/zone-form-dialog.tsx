"use client";

import { useState, useTransition } from "react";
import { Loader2, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { createShippingZoneAction, updateShippingZoneAction } from "../actions";
import type { Zone } from "../queries";

/** Create/edit dialog for shipping_zones — same code-immutability rule as CarrierFormDialog. */
export function ZoneFormDialog({ zone }: { zone?: Zone }) {
  const isEdit = Boolean(zone);
  const [open, setOpen] = useState(false);
  const [code, setCode] = useState(zone?.code ?? "");
  const [nameAr, setNameAr] = useState(zone?.name_ar ?? "");
  const [nameEn, setNameEn] = useState(zone?.name_en ?? "");
  const [sortOrder, setSortOrder] = useState(String(zone?.sort_order ?? 0));
  const [notes, setNotes] = useState(zone?.notes ?? "");
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [isPending, startTransition] = useTransition();

  function submit() {
    setFieldErrors(undefined);
    startTransition(async () => {
      const payload = { code, name_ar: nameAr, name_en: nameEn, sort_order: sortOrder ? Number(sortOrder) : 0, notes };
      const result = isEdit ? await updateShippingZoneAction(zone!.id, payload) : await createShippingZoneAction(payload);

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
          <Button variant="ghost" size="icon" aria-label="تعديل المنطقة">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant="accent">
            <Plus className="size-4" />
            إضافة منطقة
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل منطقة" : "إضافة منطقة جديدة"}</DialogTitle>
          <DialogDescription>
            {isEdit ? "الكود ثابت ولا يمكن تعديله بعد الإنشاء." : "الكود يُستخدم كمفتاح داخلي ثابت — لا يمكن تعديله لاحقًا."}
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="zone-code">الكود</Label>
              <Input id="zone-code" dir="ltr" value={code} onChange={(e) => setCode(e.target.value)} placeholder="RIYADH" disabled={isPending || isEdit} />
              {fieldErrors?.code && <p className="text-xs font-medium text-destructive">{fieldErrors.code[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="zone-sort">ترتيب العرض</Label>
              <Input id="zone-sort" type="number" min="0" value={sortOrder} onChange={(e) => setSortOrder(e.target.value)} disabled={isPending} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="zone-name-ar">الاسم بالعربية</Label>
            <Input id="zone-name-ar" value={nameAr} onChange={(e) => setNameAr(e.target.value)} placeholder="الرياض" disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="zone-name-en">الاسم بالإنجليزية (اختياري)</Label>
            <Input id="zone-name-en" dir="ltr" value={nameEn} onChange={(e) => setNameEn(e.target.value)} placeholder="Riyadh" disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="zone-notes">ملاحظات (اختياري)</Label>
            <Textarea id="zone-notes" value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
            إلغاء
          </Button>
          <Button variant="accent" onClick={submit} disabled={isPending || !code || !nameAr}>
            {isPending && <Loader2 className="size-4 animate-spin" />}
            {isEdit ? "حفظ التعديلات" : "إضافة المنطقة"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

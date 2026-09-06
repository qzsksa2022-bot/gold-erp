"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { createVatRateVersionAction } from "../actions";
import { riyadhTodayIsoDate } from "@/lib/date";

/**
 * Always creates a NEW version — there is no "edit the current rate" path, by
 * design (§4: a rate change ends the previous period and opens a new version;
 * it never silently rewrites historical financial data). Identical in shape to
 * ManufacturingFeeVersionDialog.
 */
export function VatRateVersionDialog() {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await createVatRateVersionAction(null, formData);
      if (result.success) {
        toast.success(result.message ?? "تم الحفظ بنجاح");
        setOpen(false);
        formRef.current?.reset();
      } else {
        toast.error(result.error);
        setFieldErrors(result.fieldErrors);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="accent">
          <Plus className="size-4" />
          إصدار ضريبة جديد
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إصدار ضريبة قيمة مضافة جديد</DialogTitle>
          <DialogDescription>
            هذا لا يُعدِّل النسبة الحالية — ينهي الإصدار الساري تلقائيًا عند تاريخ السريان الجديد، ويحتفظ بالنسبة القديمة في السجل
            التاريخي دون تغيير. النسبة تُطبَّق على كل عملية بيع جديدة اعتبارًا من تاريخ سريانها.
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="rate_percent">النسبة (%)</Label>
              <Input id="rate_percent" name="rate_percent" type="number" step="0.001" min="0" required disabled={isPending} dir="ltr" placeholder="15" />
              {fieldErrors?.rate_percent && <p className="text-xs font-medium text-destructive">{fieldErrors.rate_percent[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="effective_from">تاريخ السريان</Label>
              <Input
                id="effective_from"
                name="effective_from"
                type="date"
                min={riyadhTodayIsoDate()}
                defaultValue={riyadhTodayIsoDate()}
                required
                disabled={isPending}
              />
              {fieldErrors?.effective_from && <p className="text-xs font-medium text-destructive">{fieldErrors.effective_from[0]}</p>}
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="notes">ملاحظات (اختياري)</Label>
            <Textarea id="notes" name="notes" rows={2} disabled={isPending} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              حفظ الإصدار الجديد
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { createPaymentMethodFeeVersionAction } from "../actions";
import { riyadhTodayIsoDate } from "@/lib/date";
import type { Database } from "@/types/database";

type PaymentMethod = Database["public"]["Tables"]["payment_methods"]["Row"];

/** Always creates a NEW version, mirrors ManufacturingFeeVersionDialog exactly — see that component's comment. */
export function FeeVersionDialog({ method }: { method: PaymentMethod }) {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  const showPercentage = method.fee_model === "percentage" || method.fee_model === "percentage_plus_fixed";
  const showFixed = method.fee_model === "fixed" || method.fee_model === "percentage_plus_fixed";

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await createPaymentMethodFeeVersionAction(null, formData);
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
        <Button variant="outline" size="sm">
          <Plus className="size-4" />
          إصدار عمولة جديد
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إصدار عمولة جديد — {method.name_ar}</DialogTitle>
          <DialogDescription>
            هذا لا يُعدِّل العمولة الحالية — ينهي الإصدار الساري تلقائيًا عند تاريخ السريان الجديد، ويحتفظ بالقيمة القديمة في السجل
            التاريخي دون تغيير.
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <input type="hidden" name="payment_method_id" value={method.id} />

          <div className="grid grid-cols-2 gap-4">
            {showPercentage && (
              <div className="flex flex-col gap-1.5">
                <Label htmlFor="percentage_fee">النسبة (%)</Label>
                <Input id="percentage_fee" name="percentage_fee" type="number" step="0.001" min="0" dir="ltr" disabled={isPending} />
                {fieldErrors?.percentage_fee && <p className="text-xs font-medium text-destructive">{fieldErrors.percentage_fee[0]}</p>}
              </div>
            )}
            {showFixed && (
              <div className="flex flex-col gap-1.5">
                <Label htmlFor="fixed_fee">مبلغ ثابت (ر.س)</Label>
                <Input id="fixed_fee" name="fixed_fee" type="number" step="0.01" min="0" dir="ltr" disabled={isPending} />
                {fieldErrors?.fixed_fee && <p className="text-xs font-medium text-destructive">{fieldErrors.fixed_fee[0]}</p>}
              </div>
            )}
            {!showPercentage && !showFixed && (
              <p className="col-span-2 text-sm text-muted-foreground">
                شكل العمولة لهذه الطريقة &quot;بدون رسوم&quot; — سيُسجَّل إصدار بنسبة ومبلغ ثابت يساويان صفرًا.
              </p>
            )}
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

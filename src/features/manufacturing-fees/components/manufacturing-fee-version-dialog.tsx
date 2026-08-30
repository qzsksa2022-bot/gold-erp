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
import { createManufacturingFeeVersionAction } from "../actions";
import { riyadhTodayIsoDate } from "@/lib/date";
import type { Database } from "@/types/database";

type Karat = Database["public"]["Tables"]["karats"]["Row"];

/**
 * Always creates a NEW version — there is no "edit the current rate" path,
 * by design (spec §4: "تعديل السعر الحالي يكون بإنهاء الفترة السابقة
 * وإنشاء Version جديد، وليس تغيير التاريخ المالي القديم بصمت").
 */
export function ManufacturingFeeVersionDialog({ karat }: { karat?: Karat }) {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await createManufacturingFeeVersionAction(null, formData);
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
        <Button variant={karat ? "outline" : "accent"} size={karat ? "sm" : "default"}>
          <Plus className="size-4" />
          إصدار مصنعية جديد
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إصدار مصنعية جديد{karat ? ` — ${karat.name_ar}` : ""}</DialogTitle>
          <DialogDescription>
            هذا لا يُعدِّل المصنعية الحالية — ينهي الإصدار الساري تلقائيًا عند تاريخ السريان الجديد، ويحتفظ بالقيمة القديمة في السجل
            التاريخي دون تغيير.
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          {karat ? (
            <input type="hidden" name="karat_id" value={karat.id} />
          ) : (
            <p className="text-sm text-muted-foreground">اختر العيار من بطاقته مباشرة لفتح هذا النموذج.</p>
          )}

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="fee_per_gram">المصنعية (ر.س/جم)</Label>
              <Input
                id="fee_per_gram"
                name="fee_per_gram"
                type="number"
                step="0.01"
                min="0"
                required
                disabled={isPending}
                dir="ltr"
              />
              {fieldErrors?.fee_per_gram && <p className="text-xs font-medium text-destructive">{fieldErrors.fee_per_gram[0]}</p>}
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
            <Button type="submit" disabled={isPending || !karat}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              حفظ الإصدار الجديد
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

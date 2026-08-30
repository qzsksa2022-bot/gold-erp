"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { createKaratAction, updateKaratAction } from "../actions";
import type { Database } from "@/types/database";

type Karat = Database["public"]["Tables"]["karats"]["Row"];

export function KaratFormDialog({ karat }: { karat?: Karat }) {
  const isEdit = Boolean(karat);
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = isEdit ? await updateKaratAction(karat!.id, null, formData) : await createKaratAction(null, formData);

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
        {isEdit ? (
          <Button variant="ghost" size="icon" aria-label="تعديل العيار">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant="accent">
            <Plus className="size-4" />
            إضافة عيار
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل عيار" : "إضافة عيار جديد"}</DialogTitle>
          <DialogDescription>
            {isEdit ? "تحديث بيانات هذا العيار." : "أدخل بيانات العيار الجديد — لن يُحذف أي عيار موجود مسبقًا."}
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="code">الكود</Label>
              <Input id="code" name="code" defaultValue={karat?.code} placeholder="21" required disabled={isPending} />
              {fieldErrors?.code && <p className="text-xs font-medium text-destructive">{fieldErrors.code[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="purity_per_mille">النقاء بالألف (اختياري)</Label>
              <Input
                id="purity_per_mille"
                name="purity_per_mille"
                type="number"
                step="0.001"
                min="0"
                max="1000"
                defaultValue={karat?.purity_per_mille ?? ""}
                placeholder="875"
                disabled={isPending}
              />
              {fieldErrors?.purity_per_mille && <p className="text-xs font-medium text-destructive">{fieldErrors.purity_per_mille[0]}</p>}
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_ar">الاسم بالعربية</Label>
            <Input id="name_ar" name="name_ar" defaultValue={karat?.name_ar} placeholder="عيار 21" required disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="name_en">الاسم بالإنجليزية (اختياري)</Label>
              <Input id="name_en" name="name_en" defaultValue={karat?.name_en ?? ""} placeholder="21K" disabled={isPending} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sort_order">ترتيب العرض</Label>
              <Input
                id="sort_order"
                name="sort_order"
                type="number"
                min="0"
                defaultValue={karat?.sort_order ?? 0}
                disabled={isPending}
              />
            </div>
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              {isEdit ? "حفظ التعديلات" : "إضافة العيار"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { createAdjustmentTypeAction, updateAdjustmentTypeAction } from "../actions";

type AdjustmentType = {
  id: string;
  code: string;
  name_ar: string;
  name_en: string | null;
  description: string | null;
  sort_order: number;
};

/**
 * Create/edit dialog for adjustment_types (§5/§6) — every write goes through
 * create_adjustment_type()/update_adjustment_type() (0136), never a raw
 * table write (the base table has zero write RLS policy, 0134). `code` is
 * only editable on create — permanent thereafter.
 */
export function AdjustmentTypeFormDialog({ type }: { type?: AdjustmentType }) {
  const isEdit = Boolean(type);
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    const input = {
      code: formData.get("code") ? String(formData.get("code")) : undefined,
      name_ar: String(formData.get("name_ar") ?? ""),
      name_en: formData.get("name_en") ? String(formData.get("name_en")) : undefined,
      description: formData.get("description") ? String(formData.get("description")) : undefined,
      sort_order: formData.get("sort_order") ? Number(formData.get("sort_order")) : undefined,
    };

    startTransition(async () => {
      const result = isEdit ? await updateAdjustmentTypeAction(type!.id, input) : await createAdjustmentTypeAction(input);

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
          <Button variant="ghost" size="icon" aria-label="تعديل نوع التعديل/الخدمة">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant="accent">
            <Plus className="size-4" />
            إضافة نوع تعديل/خدمة
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل نوع تعديل/خدمة" : "إضافة نوع تعديل/خدمة جديد"}</DialogTitle>
          <DialogDescription>{isEdit ? "تحديث بيانات هذا النوع. الرمز غير قابل للتعديل بعد الإنشاء." : "كل تعديل/خدمة يُنشأ لاحقًا يجب أن يرتبط بنوع نشط من هذه القائمة."}</DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          {!isEdit && (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="code">الرمز (إنجليزي، بلا مسافات)</Label>
              <Input id="code" name="code" placeholder="engraving_service" required dir="ltr" disabled={isPending} />
              {fieldErrors?.code && <p className="text-xs font-medium text-destructive">{fieldErrors.code[0]}</p>}
            </div>
          )}

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_ar">الاسم بالعربية</Label>
            <Input id="name_ar" name="name_ar" defaultValue={type?.name_ar} required disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="name_en">الاسم بالإنجليزية (اختياري)</Label>
              <Input id="name_en" name="name_en" defaultValue={type?.name_en ?? ""} disabled={isPending} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sort_order">ترتيب العرض</Label>
              <Input id="sort_order" name="sort_order" type="number" min="0" defaultValue={type?.sort_order ?? 0} disabled={isPending} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="description">الوصف (اختياري)</Label>
            <Textarea id="description" name="description" defaultValue={type?.description ?? ""} disabled={isPending} rows={2} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              {isEdit ? "حفظ التعديلات" : "إضافة النوع"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

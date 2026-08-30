"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Pencil, Plus } from "lucide-react";
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
import { createStoreAction, updateStoreAction } from "../actions";
import type { Database } from "@/types/database";

type Store = Database["public"]["Tables"]["stores"]["Row"];

export function StoreFormDialog({ store }: { store?: Store }) {
  const isEdit = Boolean(store);
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  // Deliberately NOT useActionState + useEffect-on-result here: reacting to
  // an action's outcome by closing this dialog is a direct consequence of
  // the submit event, so it belongs in the submit handler itself (a real
  // event handler), not synchronized afterwards via an effect.
  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = isEdit ? await updateStoreAction(store!.id, null, formData) : await createStoreAction(null, formData);

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
          <Button variant="ghost" size="icon" aria-label="تعديل المتجر">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant="accent">
            <Plus className="size-4" />
            إضافة متجر
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل بيانات المتجر" : "إضافة متجر جديد"}</DialogTitle>
          <DialogDescription>
            {isEdit ? "تحديث المعلومات الأساسية لهذا المتجر." : "أدخل بيانات المتجر الجديد."}
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="code">كود المتجر</Label>
              <Input id="code" name="code" defaultValue={store?.code} placeholder="RYD01" required disabled={isPending} />
              {fieldErrors?.code && <p className="text-xs font-medium text-destructive">{fieldErrors.code[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="name_en">الاسم بالإنجليزية (اختياري)</Label>
              <Input id="name_en" name="name_en" defaultValue={store?.name_en ?? ""} disabled={isPending} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_ar">اسم المتجر بالعربية</Label>
            <Input id="name_ar" name="name_ar" defaultValue={store?.name_ar} required disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="logo_url">رابط الشعار (اختياري)</Label>
            <Input id="logo_url" name="logo_url" defaultValue={store?.logo_url ?? ""} placeholder="https://..." disabled={isPending} />
            {fieldErrors?.logo_url && <p className="text-xs font-medium text-destructive">{fieldErrors.logo_url[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="description">وصف مختصر (اختياري)</Label>
            <Textarea id="description" name="description" defaultValue={store?.description ?? ""} disabled={isPending} rows={3} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              {isEdit ? "حفظ التعديلات" : "إضافة المتجر"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

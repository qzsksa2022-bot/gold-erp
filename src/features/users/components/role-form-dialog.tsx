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
import { createRoleAction, updateRoleAction } from "../roles-actions";
import type { Database } from "@/types/database";

type Role = Database["public"]["Tables"]["roles"]["Row"];

export function RoleFormDialog({ role }: { role?: Role }) {
  const isEdit = Boolean(role);
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = isEdit ? await updateRoleAction(role!.id, null, formData) : await createRoleAction(null, formData);

      if (result.success) {
        toast.success(result.message ?? "تم الحفظ");
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
          <Button variant="ghost" size="icon" aria-label="تعديل الدور">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant="accent">
            <Plus className="size-4" />
            دور جديد
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل الدور" : "إنشاء دور جديد"}</DialogTitle>
          <DialogDescription>بعد الحفظ يمكنك تحديد صلاحيات هذا الدور من زر الصلاحيات.</DialogDescription>
        </DialogHeader>
        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_ar">اسم الدور بالعربية</Label>
            <Input id="name_ar" name="name_ar" defaultValue={role?.name_ar} required disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_en">الاسم بالإنجليزية (اختياري)</Label>
            <Input id="name_en" name="name_en" defaultValue={role?.name_en ?? ""} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="description_ar">وصف مختصر (اختياري)</Label>
            <Textarea id="description_ar" name="description_ar" defaultValue={role?.description_ar ?? ""} rows={3} disabled={isPending} />
          </div>
          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              {isEdit ? "حفظ التعديلات" : "إنشاء الدور"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

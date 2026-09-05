"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Plus, Pencil } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Switch } from "@/components/ui/switch";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { createExpenseCategoryAction, updateExpenseCategoryAction, setExpenseCategoryStatusAction } from "../actions";

/** Creates a global expense category via create_expense_category() (migration 0235), gated on expenses.manage_categories. */
export function ExpenseCategoryCreateDialog() {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await createExpenseCategoryAction({
        code: String(formData.get("code") ?? ""),
        name_ar: String(formData.get("name_ar") ?? ""),
        name_en: formData.get("name_en") ? String(formData.get("name_en")) : undefined,
        notes: formData.get("notes") ? String(formData.get("notes")) : undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تمت الإضافة");
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
        <Button>
          <Plus className="size-4" />
          تصنيف جديد
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إضافة تصنيف مصروف</DialogTitle>
          <DialogDescription>رمز التصنيف دائم ولا يمكن تعديله بعد الإنشاء. التصنيف عام لكل الفروع.</DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="cat_code">الرمز</Label>
              <Input id="cat_code" name="code" dir="ltr" required disabled={isPending} />
              {fieldErrors?.code && <p className="text-xs font-medium text-destructive">{fieldErrors.code[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="cat_name_ar">الاسم بالعربية</Label>
              <Input id="cat_name_ar" name="name_ar" required disabled={isPending} />
              {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="cat_name_en">الاسم بالإنجليزية (اختياري)</Label>
            <Input id="cat_name_en" name="name_en" dir="ltr" disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="cat_notes">ملاحظات (اختياري)</Label>
            <Textarea id="cat_notes" name="notes" rows={2} disabled={isPending} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              حفظ
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

/**
 * Edits a category via update_expense_category() (migration 0235). The
 * current row_version is always submitted — the RPC rejects a NULL expected
 * version outright, since `row_version <> NULL` would silently bypass the
 * optimistic-concurrency check.
 */
export function ExpenseCategoryEditDialog({
  category,
}: {
  category: { id: string; code: string; name_ar: string; name_en: string | null; notes: string | null; row_version: number };
}) {
  const [open, setOpen] = useState(false);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await updateExpenseCategoryAction({
        id: category.id,
        row_version: category.row_version,
        name_ar: String(formData.get("name_ar") ?? ""),
        name_en: formData.get("name_en") ? String(formData.get("name_en")) : undefined,
        notes: formData.get("notes") ? String(formData.get("notes")) : undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم التحديث");
        setOpen(false);
      } else {
        toast.error(result.error);
        setFieldErrors(result.fieldErrors);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="sm">
          <Pencil className="size-4" />
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تعديل التصنيف {category.code}</DialogTitle>
          <DialogDescription>لا يمكن تعديل رمز التصنيف بعد الإنشاء.</DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor={`edit_name_ar_${category.id}`}>الاسم بالعربية</Label>
            <Input id={`edit_name_ar_${category.id}`} name="name_ar" defaultValue={category.name_ar} required disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor={`edit_name_en_${category.id}`}>الاسم بالإنجليزية (اختياري)</Label>
            <Input id={`edit_name_en_${category.id}`} name="name_en" dir="ltr" defaultValue={category.name_en ?? ""} disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor={`edit_notes_${category.id}`}>ملاحظات (اختياري)</Label>
            <Textarea id={`edit_notes_${category.id}`} name="notes" rows={2} defaultValue={category.notes ?? ""} disabled={isPending} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              حفظ
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

/** Enable/disable toggle — goes through disable_expense_category()/enable_expense_category() (0235), never a raw table write. A category is never deleted, so historical expenses keep resolving. */
export function ExpenseCategoryStatusToggle({ categoryId, status, categoryName }: { categoryId: string; status: "active" | "disabled"; categoryName: string }) {
  const [isPending, startTransition] = useTransition();

  function handleChange(checked: boolean) {
    startTransition(async () => {
      const result = await setExpenseCategoryStatusAction(categoryId, checked ? "active" : "disabled");
      if (result.success) toast.success(result.message ?? "تم التحديث");
      else toast.error(result.error);
    });
  }

  return <Switch checked={status === "active"} onCheckedChange={handleChange} disabled={isPending} aria-label={`تفعيل/تعطيل ${categoryName}`} />;
}

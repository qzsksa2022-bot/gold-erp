"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { createCategoryAction, updateCategoryAction } from "../actions";
import { descendantIds, type Category } from "../tree";

export function CategoryFormDialog({
  category,
  allCategories,
  defaultParentId,
}: {
  category?: Category;
  allCategories: Category[];
  /** Pre-select a parent when adding a subcategory from within a specific node's row. */
  defaultParentId?: string;
}) {
  const isEdit = Boolean(category);
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [parentId, setParentId] = useState(category?.parent_id ?? defaultParentId ?? "");

  // A category can never be re-parented under itself or under any of its
  // own descendants (the DB rejects this too — see prevent_category_cycle,
  // 0043 — this is purely so the picker never even suggests an invalid
  // option).
  const excluded = isEdit ? new Set([category!.id, ...descendantIds(allCategories, category!.id)]) : new Set<string>();
  const parentOptions = allCategories.filter((c) => !excluded.has(c.id));

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    formData.set("parent_id", parentId);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = isEdit ? await updateCategoryAction(category!.id, null, formData) : await createCategoryAction(null, formData);

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
          <Button variant="ghost" size="icon" aria-label="تعديل التصنيف">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant={defaultParentId ? "outline" : "accent"} size={defaultParentId ? "sm" : "default"}>
            <Plus className="size-4" />
            {defaultParentId ? "تصنيف فرعي" : "إضافة تصنيف رئيسي"}
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل تصنيف" : "إضافة تصنيف جديد"}</DialogTitle>
          <DialogDescription>{isEdit ? "تحديث بيانات هذا التصنيف." : "أدخل بيانات التصنيف الجديد."}</DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label>التصنيف الأب (اختياري — اتركه فارغًا لتصنيف رئيسي)</Label>
            <Select value={parentId || "none"} onValueChange={(v) => setParentId(v === "none" ? "" : v)}>
              <SelectTrigger>
                <SelectValue placeholder="بلا (تصنيف رئيسي)" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="none">بلا (تصنيف رئيسي)</SelectItem>
                {parentOptions.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name_ar}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_ar">الاسم بالعربية</Label>
            <Input id="name_ar" name="name_ar" defaultValue={category?.name_ar} required disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="name_en">الاسم بالإنجليزية (اختياري)</Label>
              <Input id="name_en" name="name_en" defaultValue={category?.name_en ?? ""} disabled={isPending} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="code">الكود (اختياري)</Label>
              <Input id="code" name="code" defaultValue={category?.code ?? ""} disabled={isPending} />
              {fieldErrors?.code && <p className="text-xs font-medium text-destructive">{fieldErrors.code[0]}</p>}
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="sort_order">ترتيب العرض</Label>
            <Input
              id="sort_order"
              name="sort_order"
              type="number"
              min="0"
              defaultValue={category?.sort_order ?? 0}
              disabled={isPending}
            />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              {isEdit ? "حفظ التعديلات" : "إضافة التصنيف"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

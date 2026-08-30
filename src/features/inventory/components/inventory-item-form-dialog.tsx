"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Switch } from "@/components/ui/switch";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { createInventoryItemAction, updateInventoryItemAction } from "../actions";
import { INVENTORY_UNITS, INVENTORY_UNIT_LABELS_AR } from "../schema";

type Lookup = { id: string; name_ar: string };
type InventoryItem = {
  id: string;
  sku: string;
  name_ar: string;
  category_id: string;
  karat_id: string | null;
  unit: string;
  active: boolean;
  notes: string | null;
  row_version: number;
};

/**
 * Create/edit dialog for inventory_items (migration 0229) — every write
 * goes through create_inventory_item()/update_inventory_item(), never a raw
 * table write (the base table has zero write RLS policy, 0228). `sku` is
 * only editable on create — permanent thereafter, mirrors adjustment_
 * types.code (AdjustmentTypeFormDialog).
 */
export function InventoryItemFormDialog({ item, categories, karats }: { item?: InventoryItem; categories: Lookup[]; karats: Lookup[] }) {
  const isEdit = Boolean(item);
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [categoryId, setCategoryId] = useState(item?.category_id ?? "");
  const [karatId, setKaratId] = useState(item?.karat_id ?? "");
  const [unit, setUnit] = useState<(typeof INVENTORY_UNITS)[number]>((item?.unit as (typeof INVENTORY_UNITS)[number]) ?? "gram");
  const [active, setActive] = useState(item?.active ?? true);

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = isEdit
        ? await updateInventoryItemAction({
            id: item!.id,
            row_version: item!.row_version,
            name_ar: String(formData.get("name_ar") ?? ""),
            category_id: categoryId,
            karat_id: karatId || undefined,
            unit,
            active,
            notes: formData.get("notes") ? String(formData.get("notes")) : undefined,
          })
        : await createInventoryItemAction({
            sku: String(formData.get("sku") ?? ""),
            name_ar: String(formData.get("name_ar") ?? ""),
            category_id: categoryId,
            karat_id: karatId || undefined,
            unit,
            notes: formData.get("notes") ? String(formData.get("notes")) : undefined,
          });

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
          <Button variant="ghost" size="icon" aria-label="تعديل الصنف">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant="accent">
            <Plus className="size-4" />
            صنف جديد
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل صنف مخزون" : "إضافة صنف مخزون جديد"}</DialogTitle>
          <DialogDescription>{isEdit ? "تحديث بيانات هذا الصنف. رمز الصنف (SKU) غير قابل للتعديل بعد الإنشاء." : "أنشئ صنفًا جديدًا في كتالوج المخزون قبل تسجيل أي حركة استلام له."}</DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          {!isEdit && (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sku">رمز الصنف (SKU)</Label>
              <Input id="sku" name="sku" placeholder="RING-001" required dir="ltr" disabled={isPending} />
              {fieldErrors?.sku && <p className="text-xs font-medium text-destructive">{fieldErrors.sku[0]}</p>}
            </div>
          )}

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_ar">اسم الصنف</Label>
            <Input id="name_ar" name="name_ar" defaultValue={item?.name_ar} required disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="category_id">التصنيف</Label>
              <Select value={categoryId} onValueChange={setCategoryId} disabled={isPending}>
                <SelectTrigger id="category_id">
                  <SelectValue placeholder="اختر التصنيف" />
                </SelectTrigger>
                <SelectContent>
                  {categories.map((c) => (
                    <SelectItem key={c.id} value={c.id}>
                      {c.name_ar}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {fieldErrors?.category_id && <p className="text-xs font-medium text-destructive">{fieldErrors.category_id[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="karat_id">العيار (اختياري)</Label>
              <Select value={karatId || "none"} onValueChange={(v) => setKaratId(v === "none" ? "" : v)} disabled={isPending}>
                <SelectTrigger id="karat_id">
                  <SelectValue placeholder="بدون عيار" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="none">بدون عيار</SelectItem>
                  {karats.map((k) => (
                    <SelectItem key={k.id} value={k.id}>
                      {k.name_ar}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="unit">وحدة القياس</Label>
              <Select value={unit} onValueChange={(v) => setUnit(v as (typeof INVENTORY_UNITS)[number])} disabled={isPending}>
                <SelectTrigger id="unit">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {INVENTORY_UNITS.map((u) => (
                    <SelectItem key={u} value={u}>
                      {INVENTORY_UNIT_LABELS_AR[u]}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            {isEdit && (
              <div className="flex flex-col gap-1.5">
                <Label htmlFor="active">مفعّل</Label>
                <div className="flex h-9 items-center">
                  <Switch id="active" checked={active} onCheckedChange={setActive} disabled={isPending} />
                </div>
              </div>
            )}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="notes">ملاحظات (اختياري)</Label>
            <Textarea id="notes" name="notes" defaultValue={item?.notes ?? ""} disabled={isPending} rows={2} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending || !categoryId}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              {isEdit ? "حفظ التعديلات" : "إضافة الصنف"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

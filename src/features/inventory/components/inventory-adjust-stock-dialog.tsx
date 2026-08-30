"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, ClipboardEdit } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { adjustInventoryStockAction } from "../actions";

type Lookup = { id: string; name_ar: string; sku?: string };

/** Manual stock-correction dialog — records a signed movement via adjust_inventory_stock() (migration 0229), gated on inventory.adjust. Reason is mandatory (DB-enforced). */
export function InventoryAdjustStockDialog({ items, stores }: { items: Lookup[]; stores: Lookup[] }) {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [itemId, setItemId] = useState("");
  const [storeId, setStoreId] = useState("");

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await adjustInventoryStockAction({
        item_id: itemId,
        store_id: storeId,
        quantity_delta: String(formData.get("quantity_delta") ?? ""),
        reason: String(formData.get("reason") ?? ""),
        business_date: String(formData.get("business_date") ?? ""),
        reference: formData.get("reference") ? String(formData.get("reference")) : undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم الحفظ بنجاح");
        setOpen(false);
        formRef.current?.reset();
        setItemId("");
        setStoreId("");
      } else {
        toast.error(result.error);
        setFieldErrors(result.fieldErrors);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline">
          <ClipboardEdit className="size-4" />
          تصحيح مخزون
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تسجيل تصحيح مخزون يدوي</DialogTitle>
          <DialogDescription>استخدم قيمة موجبة عند وجود كمية زائدة، وقيمة سالبة عند وجود نقص. لا يمكن أن يصبح الرصيد الناتج سالبًا.</DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="adjust_item_id">الصنف</Label>
              <Select value={itemId} onValueChange={setItemId} disabled={isPending}>
                <SelectTrigger id="adjust_item_id">
                  <SelectValue placeholder="اختر الصنف" />
                </SelectTrigger>
                <SelectContent>
                  {items.map((i) => (
                    <SelectItem key={i.id} value={i.id}>
                      {i.sku ? `${i.sku} — ${i.name_ar}` : i.name_ar}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {fieldErrors?.item_id && <p className="text-xs font-medium text-destructive">{fieldErrors.item_id[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="adjust_store_id">المتجر</Label>
              <Select value={storeId} onValueChange={setStoreId} disabled={isPending}>
                <SelectTrigger id="adjust_store_id">
                  <SelectValue placeholder="اختر المتجر" />
                </SelectTrigger>
                <SelectContent>
                  {stores.map((s) => (
                    <SelectItem key={s.id} value={s.id}>
                      {s.name_ar}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {fieldErrors?.store_id && <p className="text-xs font-medium text-destructive">{fieldErrors.store_id[0]}</p>}
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="quantity_delta">فرق الكمية (+/-)</Label>
              <Input id="quantity_delta" name="quantity_delta" type="text" inputMode="decimal" dir="ltr" placeholder="-2.5" required disabled={isPending} />
              {fieldErrors?.quantity_delta && <p className="text-xs font-medium text-destructive">{fieldErrors.quantity_delta[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="adjust_business_date">التاريخ</Label>
              <Input id="adjust_business_date" name="business_date" type="date" dir="ltr" defaultValue={new Date().toISOString().slice(0, 10)} required disabled={isPending} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="reason">سبب التصحيح</Label>
            <Textarea id="reason" name="reason" required disabled={isPending} rows={2} />
            {fieldErrors?.reason && <p className="text-xs font-medium text-destructive">{fieldErrors.reason[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="adjust_reference">مرجع (اختياري)</Label>
            <Input id="adjust_reference" name="reference" disabled={isPending} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending || !itemId || !storeId}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تسجيل التصحيح
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

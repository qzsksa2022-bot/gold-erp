"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, PackagePlus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { receiveInventoryStockAction } from "../actions";

type Lookup = { id: string; name_ar: string; sku?: string };

/** Receive-stock dialog — records a positive movement via receive_inventory_stock() (migration 0229), gated on inventory.receive. */
export function InventoryReceiveStockDialog({ items, stores }: { items: Lookup[]; stores: Lookup[] }) {
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
      const result = await receiveInventoryStockAction({
        item_id: itemId,
        store_id: storeId,
        quantity: String(formData.get("quantity") ?? ""),
        business_date: String(formData.get("business_date") ?? ""),
        reference: formData.get("reference") ? String(formData.get("reference")) : undefined,
        notes: formData.get("notes") ? String(formData.get("notes")) : undefined,
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
        <Button variant="accent">
          <PackagePlus className="size-4" />
          استلام مخزون
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تسجيل استلام مخزون</DialogTitle>
          <DialogDescription>يزيد هذا الرصيد المتاح للصنف في المتجر المحدد. الكمية يجب أن تكون رقمًا موجبًا.</DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="receive_item_id">الصنف</Label>
              <Select value={itemId} onValueChange={setItemId} disabled={isPending}>
                <SelectTrigger id="receive_item_id">
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
              <Label htmlFor="receive_store_id">المتجر</Label>
              <Select value={storeId} onValueChange={setStoreId} disabled={isPending}>
                <SelectTrigger id="receive_store_id">
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
              <Label htmlFor="quantity">الكمية</Label>
              <Input id="quantity" name="quantity" type="text" inputMode="decimal" dir="ltr" required disabled={isPending} />
              {fieldErrors?.quantity && <p className="text-xs font-medium text-destructive">{fieldErrors.quantity[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="business_date">التاريخ</Label>
              <Input id="business_date" name="business_date" type="date" dir="ltr" defaultValue={new Date().toISOString().slice(0, 10)} required disabled={isPending} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="reference">مرجع (اختياري)</Label>
            <Input id="reference" name="reference" disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="notes">ملاحظات (اختياري)</Label>
            <Input id="notes" name="notes" disabled={isPending} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending || !itemId || !storeId}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تسجيل الاستلام
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

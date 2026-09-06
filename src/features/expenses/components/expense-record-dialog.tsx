"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Receipt } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { recordStoreExpenseAction } from "../actions";
import { isClosedDayError } from "../schema";

type Lookup = { id: string; name_ar: string };
type CategoryLookup = { id: string; code: string; name_ar: string };

/**
 * Records an operating expense via record_store_expense() (migration 0235),
 * gated on expenses.create. The amount is submitted as a STRING and never
 * passed through Number() — the server stores and returns it.
 *
 * `closed_day_reason` is only revealed after the server has actually said the
 * chosen date falls in a closed day, so the field can never be used to
 * pre-emptively bypass the daily-close guard (which additionally requires
 * expenses.process_closed_day, enforced in the RPC).
 */
export function ExpenseRecordDialog({ stores, categories }: { stores: Lookup[]; categories: CategoryLookup[] }) {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [storeId, setStoreId] = useState("");
  const [categoryId, setCategoryId] = useState("");
  const [needsClosedDayReason, setNeedsClosedDayReason] = useState(false);

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await recordStoreExpenseAction({
        store_id: storeId,
        expense_category_id: categoryId,
        amount: String(formData.get("amount") ?? ""),
        business_date: String(formData.get("business_date") ?? ""),
        description: formData.get("description") ? String(formData.get("description")) : undefined,
        closed_day_reason: formData.get("closed_day_reason") ? String(formData.get("closed_day_reason")) : undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم الحفظ بنجاح");
        setOpen(false);
        formRef.current?.reset();
        setStoreId("");
        setCategoryId("");
        setNeedsClosedDayReason(false);
      } else {
        toast.error(result.error);
        setFieldErrors(result.fieldErrors);
        if (isClosedDayError(result.error)) setNeedsClosedDayReason(true);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button>
          <Receipt className="size-4" />
          تسجيل مصروف
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تسجيل مصروف تشغيلي</DialogTitle>
          <DialogDescription>يُسجَّل المبلغ المدفوع إجمالًا. لا يمكن تعديل أو حذف مصروف بعد تسجيله — التصحيح يتم بحركة عكس مؤرَّخة.</DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="expense_store_id">الفرع</Label>
              <Select value={storeId} onValueChange={setStoreId} disabled={isPending}>
                <SelectTrigger id="expense_store_id">
                  <SelectValue placeholder="اختر الفرع" />
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
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="expense_category_id">التصنيف</Label>
              <Select value={categoryId} onValueChange={setCategoryId} disabled={isPending}>
                <SelectTrigger id="expense_category_id">
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
              {fieldErrors?.expense_category_id && <p className="text-xs font-medium text-destructive">{fieldErrors.expense_category_id[0]}</p>}
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="amount">المبلغ</Label>
              <Input id="amount" name="amount" type="text" inputMode="decimal" dir="ltr" placeholder="1500.00" required disabled={isPending} />
              {fieldErrors?.amount && <p className="text-xs font-medium text-destructive">{fieldErrors.amount[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="expense_business_date">تاريخ المصروف</Label>
              <Input
                id="expense_business_date"
                name="business_date"
                type="date"
                dir="ltr"
                defaultValue={new Date().toISOString().slice(0, 10)}
                required
                disabled={isPending}
              />
              {fieldErrors?.business_date && <p className="text-xs font-medium text-destructive">{fieldErrors.business_date[0]}</p>}
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="description">الوصف (اختياري)</Label>
            <Textarea id="description" name="description" rows={2} disabled={isPending} />
          </div>

          {needsClosedDayReason && (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="closed_day_reason">سبب التسجيل في يوم مقفل</Label>
              <Textarea id="closed_day_reason" name="closed_day_reason" rows={2} required disabled={isPending} />
              <p className="text-xs text-muted-foreground">التاريخ المحدد يقع في يوم مقفل — يتطلب صلاحية خاصة وسببًا صريحًا.</p>
            </div>
          )}

          <DialogFooter>
            <Button type="submit" disabled={isPending || !storeId || !categoryId}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تسجيل المصروف
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

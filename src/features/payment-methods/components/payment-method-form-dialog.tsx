"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
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
import { createPaymentMethodAction, updatePaymentMethodAction } from "../actions";
import { FEE_MODEL_LABELS_AR, REFUND_POLICY_LABELS_AR } from "../labels";
import type { Database } from "@/types/database";

type PaymentMethod = Database["public"]["Tables"]["payment_methods"]["Row"];

export function PaymentMethodFormDialog({ method }: { method?: PaymentMethod }) {
  const isEdit = Boolean(method);
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [supportsRefunds, setSupportsRefunds] = useState(method?.supports_refunds ?? true);

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    if (supportsRefunds) formData.set("supports_refunds", "on");
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = isEdit
        ? await updatePaymentMethodAction(method!.id, null, formData)
        : await createPaymentMethodAction(null, formData);

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
          <Button variant="ghost" size="icon" aria-label="تعديل طريقة الدفع">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant="accent">
            <Plus className="size-4" />
            إضافة طريقة دفع
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل طريقة الدفع" : "إضافة طريقة دفع جديدة"}</DialogTitle>
          <DialogDescription>
            {isEdit ? "تحديث بيانات طريقة الدفع — العمولة تُدار من إصدارات منفصلة." : "أدخل بيانات طريقة الدفع الجديدة."}
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          {!isEdit && (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="key">المفتاح (إنجليزي، بلا مسافات)</Label>
              <Input id="key" name="key" placeholder="apple_pay" required dir="ltr" disabled={isPending} />
              {fieldErrors?.key && <p className="text-xs font-medium text-destructive">{fieldErrors.key[0]}</p>}
            </div>
          )}

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_ar">الاسم بالعربية</Label>
            <Input id="name_ar" name="name_ar" defaultValue={method?.name_ar} required disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_en">الاسم بالإنجليزية (اختياري)</Label>
            <Input id="name_en" name="name_en" defaultValue={method?.name_en ?? ""} disabled={isPending} />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label>شكل العمولة</Label>
              <Select name="fee_model" defaultValue={method?.fee_model ?? "percentage"}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {Object.entries(FEE_MODEL_LABELS_AR).map(([value, label]) => (
                    <SelectItem key={value} value={value}>
                      {label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="flex flex-col gap-1.5">
              <Label>سياسة استرجاع العمولة</Label>
              <Select name="refund_fee_policy" defaultValue={method?.refund_fee_policy ?? "manual"}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {Object.entries(REFUND_POLICY_LABELS_AR).map(([value, label]) => (
                    <SelectItem key={value} value={value}>
                      {label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="flex items-center justify-between rounded-lg border border-border p-3">
            <Label htmlFor="supports_refunds" className="cursor-pointer">
              تدعم الاسترجاع
            </Label>
            <Switch id="supports_refunds" checked={supportsRefunds} onCheckedChange={setSupportsRefunds} disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="sort_order">ترتيب العرض</Label>
            <Input id="sort_order" name="sort_order" type="number" min="0" defaultValue={method?.sort_order ?? 0} disabled={isPending} />
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              {isEdit ? "حفظ التعديلات" : "إضافة طريقة الدفع"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

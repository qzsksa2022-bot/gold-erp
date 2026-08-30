"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Pencil, Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { createCollectionChannelAction, updateCollectionChannelAction } from "../actions";
import type { Database } from "@/types/database";

type Channel = Database["public"]["Tables"]["collection_channels"]["Row"];

export function CollectionChannelFormDialog({ channel }: { channel?: Channel }) {
  const isEdit = Boolean(channel);
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = isEdit
        ? await updateCollectionChannelAction(channel!.id, null, formData)
        : await createCollectionChannelAction(null, formData);

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
          <Button variant="ghost" size="icon" aria-label="تعديل قناة التحصيل">
            <Pencil className="size-4" />
          </Button>
        ) : (
          <Button variant="accent">
            <Plus className="size-4" />
            إضافة قناة تحصيل
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isEdit ? "تعديل قناة تحصيل" : "إضافة قناة تحصيل جديدة"}</DialogTitle>
          <DialogDescription>
            {isEdit ? "تحديث بيانات هذه القناة." : "قناة التحصيل مستقلة عن طريقة الدفع — تُسجَّل كل عملية بيع بكليهما معًا لاحقًا."}
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          {!isEdit && (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="key">المفتاح (إنجليزي، بلا مسافات)</Label>
              <Input id="key" name="key" placeholder="pos_terminal" required dir="ltr" disabled={isPending} />
              {fieldErrors?.key && <p className="text-xs font-medium text-destructive">{fieldErrors.key[0]}</p>}
            </div>
          )}

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="name_ar">الاسم بالعربية</Label>
            <Input id="name_ar" name="name_ar" defaultValue={channel?.name_ar} required disabled={isPending} />
            {fieldErrors?.name_ar && <p className="text-xs font-medium text-destructive">{fieldErrors.name_ar[0]}</p>}
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="name_en">الاسم بالإنجليزية (اختياري)</Label>
              <Input id="name_en" name="name_en" defaultValue={channel?.name_en ?? ""} disabled={isPending} />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="sort_order">ترتيب العرض</Label>
              <Input
                id="sort_order"
                name="sort_order"
                type="number"
                min="0"
                defaultValue={channel?.sort_order ?? 0}
                disabled={isPending}
              />
            </div>
          </div>

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              {isEdit ? "حفظ التعديلات" : "إضافة القناة"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

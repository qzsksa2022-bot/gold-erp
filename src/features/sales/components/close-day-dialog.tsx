"use client";

import { useState, useTransition } from "react";
import { Lock } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Input } from "@/components/ui/input";
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
import { riyadhTodayIsoDate } from "@/lib/date";
import { closeSalesDayAction } from "../actions";
import type { Database } from "@/types/database";

type Store = Database["public"]["Tables"]["stores"]["Row"];

/** Daily Close (spec §19) — no reopen/delete path exists anywhere in the app, by design. */
export function CloseDayDialog({ stores }: { stores: Store[] }) {
  const [open, setOpen] = useState(false);
  const [storeId, setStoreId] = useState("");
  const [businessDate, setBusinessDate] = useState(riyadhTodayIsoDate());
  const [notes, setNotes] = useState("");
  const [isPending, startTransition] = useTransition();

  function handleClose() {
    if (!storeId) {
      toast.error("اختر المتجر أولًا");
      return;
    }
    startTransition(async () => {
      const result = await closeSalesDayAction({ store_id: storeId, business_date: businessDate, notes: notes || undefined });
      if (result.success) {
        toast.success(result.message ?? "تم إغلاق اليوم بنجاح");
        setOpen(false);
        setNotes("");
      } else {
        toast.error(result.error);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline">
          <Lock className="size-4" />
          إغلاق يوم
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إغلاق يوم مبيعات</DialogTitle>
          <DialogDescription>
            بعد الإغلاق، لا يمكن إنشاء أو تعديل عمليات بيع لهذا اليوم في هذا المتجر إلا لصاحب صلاحية خاصة مع سبب إلزامي. لا يوجد
            إعادة فتح لليوم في هذا الإصدار.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label>المتجر</Label>
            <Select value={storeId} onValueChange={setStoreId} disabled={isPending}>
              <SelectTrigger>
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
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>تاريخ العمل</Label>
            <Input type="date" dir="ltr" value={businessDate} onChange={(e) => setBusinessDate(e.target.value)} disabled={isPending} max={riyadhTodayIsoDate()} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>ملاحظات (اختياري)</Label>
            <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={isPending}>
            إلغاء
          </Button>
          <Button variant="accent" onClick={handleClose} disabled={isPending}>
            تأكيد الإغلاق
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

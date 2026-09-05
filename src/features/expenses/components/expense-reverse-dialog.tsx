"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Undo2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { reverseStoreExpenseAction } from "../actions";
import { isClosedDayError } from "../schema";

/**
 * The ONLY correction path for a posted expense — records a dated reversal
 * entry via reverse_store_expense() (migration 0235), gated on
 * expenses.reverse. A posted expense is never updated or deleted (0234
 * rejects both at trigger level).
 *
 * The reversal carries its OWN business date (§85 Event Date), which is why
 * the date is an explicit input rather than inherited from the original.
 */
export function ExpenseReverseDialog({
  expenseId,
  expenseNumber,
  amount,
}: {
  expenseId: string;
  expenseNumber: string;
  amount: string;
}) {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [needsClosedDayReason, setNeedsClosedDayReason] = useState(false);

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await reverseStoreExpenseAction({
        expense_id: expenseId,
        reason: String(formData.get("reason") ?? ""),
        business_date: String(formData.get("business_date") ?? ""),
        closed_day_reason: formData.get("closed_day_reason") ? String(formData.get("closed_day_reason")) : undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم العكس بنجاح");
        setOpen(false);
        formRef.current?.reset();
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
        <Button variant="outline" size="sm">
          <Undo2 className="size-4" />
          عكس
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>عكس المصروف {expenseNumber}</DialogTitle>
          <DialogDescription>
            سيُسجَّل قيد عكس بمبلغ سالب ({amount}) بتاريخه الخاص — لن يُعدَّل أو يُحذف المصروف الأصلي. لا يمكن عكس المصروف أكثر من مرة.
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor={`reverse_date_${expenseId}`}>تاريخ العكس</Label>
            <Input
              id={`reverse_date_${expenseId}`}
              name="business_date"
              type="date"
              dir="ltr"
              defaultValue={new Date().toISOString().slice(0, 10)}
              required
              disabled={isPending}
            />
            {fieldErrors?.business_date && <p className="text-xs font-medium text-destructive">{fieldErrors.business_date[0]}</p>}
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor={`reverse_reason_${expenseId}`}>سبب العكس</Label>
            <Textarea id={`reverse_reason_${expenseId}`} name="reason" rows={2} required disabled={isPending} />
            {fieldErrors?.reason && <p className="text-xs font-medium text-destructive">{fieldErrors.reason[0]}</p>}
          </div>

          {needsClosedDayReason && (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={`reverse_closed_${expenseId}`}>سبب العكس في يوم مقفل</Label>
              <Textarea id={`reverse_closed_${expenseId}`} name="closed_day_reason" rows={2} required disabled={isPending} />
              <p className="text-xs text-muted-foreground">تاريخ العكس يقع في يوم مقفل — يتطلب صلاحية خاصة وسببًا صريحًا.</p>
            </div>
          )}

          <DialogFooter>
            <Button type="submit" variant="destructive" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تأكيد العكس
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

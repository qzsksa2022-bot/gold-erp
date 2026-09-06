"use client";

import { useRef, useState, useTransition } from "react";
import { Loader2, Undo2, HandCoins } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { reversePurchaseInvoiceAction, recordSupplierPaymentAction, reverseSupplierPaymentAction } from "../actions";
import { isClosedDayError, PAYMENT_MODES, PAYMENT_MODE_LABELS_AR, type PaymentMode } from "../schema";

/**
 * Reverses a posted purchase invoice via reverse_purchase_invoice()
 * (migration 0239), gated on purchases.reverse.
 *
 * The reversal carries its OWN business date (§85 Event Date) — it is a new
 * dated document, never an edit of the original. It also returns the invoice's
 * quantities out of stock, in the same transaction.
 */
export function PurchaseReverseDialog({
  invoiceId,
  purchaseNumber,
  grossTotal,
  hasUnreversedPayment,
}: {
  invoiceId: string;
  purchaseNumber: string;
  grossTotal: string;
  hasUnreversedPayment: boolean;
}) {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [needsClosedDayReason, setNeedsClosedDayReason] = useState(false);

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);

    startTransition(async () => {
      const result = await reversePurchaseInvoiceAction({
        invoice_id: invoiceId,
        reason: String(formData.get("reason") ?? ""),
        business_date: String(formData.get("business_date") ?? ""),
        closed_day_reason: formData.get("closed_day_reason") ? String(formData.get("closed_day_reason")) : undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم العكس");
        setOpen(false);
        formRef.current?.reset();
        setNeedsClosedDayReason(false);
      } else {
        toast.error(result.error);
        if (isClosedDayError(result.error)) setNeedsClosedDayReason(true);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <Undo2 className="size-4" />
          عكس الفاتورة
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>عكس فاتورة الشراء {purchaseNumber}</DialogTitle>
          <DialogDescription>
            يُنشأ مستند عكس مؤرَّخ بقيمة {grossTotal}- ويُعاد إخراج كميات الفاتورة من المخزون. لا تُعدَّل الفاتورة الأصلية ولا تُحذف.
          </DialogDescription>
        </DialogHeader>

        {hasUnreversedPayment ? (
          // The server refuses this outright; saying so here spares the
          // operator a failed attempt and names the required order of steps.
          <p className="rounded-lg border border-destructive/40 bg-destructive/5 p-3 text-sm text-destructive">
            لا يمكن عكس هذه الفاتورة بينما توجد دفعة غير معكوسة مرتبطة بها. اعكس الدفعات أولًا ثم أعد المحاولة.
          </p>
        ) : (
          <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={`rev_date_${invoiceId}`}>تاريخ العكس</Label>
              <Input
                id={`rev_date_${invoiceId}`}
                name="business_date"
                type="date"
                dir="ltr"
                defaultValue={new Date().toISOString().slice(0, 10)}
                required
                disabled={isPending}
              />
              <p className="text-xs text-muted-foreground">حركة العكس تحمل تاريخها الخاص، وليس تاريخ الفاتورة الأصلية.</p>
            </div>

            <div className="flex flex-col gap-1.5">
              <Label htmlFor={`rev_reason_${invoiceId}`}>سبب العكس</Label>
              <Textarea id={`rev_reason_${invoiceId}`} name="reason" rows={2} required disabled={isPending} />
            </div>

            {needsClosedDayReason && (
              <div className="flex flex-col gap-1.5">
                <Label htmlFor={`rev_closed_${invoiceId}`}>سبب العكس في يوم مقفل</Label>
                <Textarea id={`rev_closed_${invoiceId}`} name="closed_day_reason" rows={2} required disabled={isPending} />
                <p className="text-xs text-muted-foreground">التاريخ المحدد يقع في يوم مقفل — يتطلب صلاحية خاصة وسببًا صريحًا.</p>
              </div>
            )}

            <DialogFooter>
              <Button type="submit" variant="destructive" disabled={isPending}>
                {isPending && <Loader2 className="size-4 animate-spin" />}
                تأكيد العكس
              </Button>
            </DialogFooter>
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
}

/**
 * Records a (possibly partial) supplier payment via record_supplier_payment()
 * (migration 0239), gated on purchases.record_payment.
 *
 * The amount is submitted as a STRING and never passed through Number(). The
 * remaining balance shown here is a snapshot: the server takes a row lock on
 * the invoice and recomputes it from the ledger, so two operators paying at
 * once can never jointly exceed the invoice.
 */
export function SupplierPaymentDialog({
  invoiceId,
  purchaseNumber,
  outstanding,
}: {
  invoiceId: string;
  purchaseNumber: string;
  outstanding: string;
}) {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [paymentMode, setPaymentMode] = useState<PaymentMode>("cash");
  const [needsClosedDayReason, setNeedsClosedDayReason] = useState(false);

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await recordSupplierPaymentAction({
        invoice_id: invoiceId,
        amount: String(formData.get("amount") ?? ""),
        payment_mode: paymentMode,
        business_date: String(formData.get("business_date") ?? ""),
        payment_reference: formData.get("payment_reference") ? String(formData.get("payment_reference")) : undefined,
        notes: formData.get("notes") ? String(formData.get("notes")) : undefined,
        closed_day_reason: formData.get("closed_day_reason") ? String(formData.get("closed_day_reason")) : undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم تسجيل الدفعة");
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
        <Button size="sm">
          <HandCoins className="size-4" />
          تسجيل دفعة
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تسجيل دفعة للفاتورة {purchaseNumber}</DialogTitle>
          <DialogDescription>
            المتبقي حاليًا: {outstanding}. يمكن تسجيل دفعات جزئية متعددة. لا تُعدَّل الدفعة بعد تسجيلها — التصحيح يتم بحركة عكس مؤرَّخة.
          </DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={`pay_amount_${invoiceId}`}>المبلغ</Label>
              <Input id={`pay_amount_${invoiceId}`} name="amount" inputMode="decimal" dir="ltr" required disabled={isPending} />
              {fieldErrors?.amount && <p className="text-xs font-medium text-destructive">{fieldErrors.amount[0]}</p>}
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={`pay_mode_${invoiceId}`}>طريقة الدفع</Label>
              <Select value={paymentMode} onValueChange={(v) => setPaymentMode(v as PaymentMode)} disabled={isPending}>
                <SelectTrigger id={`pay_mode_${invoiceId}`}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {PAYMENT_MODES.map((m) => (
                    <SelectItem key={m} value={m}>
                      {PAYMENT_MODE_LABELS_AR[m]}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={`pay_date_${invoiceId}`}>تاريخ الدفعة</Label>
              <Input
                id={`pay_date_${invoiceId}`}
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
              <Label htmlFor={`pay_ref_${invoiceId}`}>المرجع (اختياري)</Label>
              <Input id={`pay_ref_${invoiceId}`} name="payment_reference" dir="ltr" disabled={isPending} />
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor={`pay_notes_${invoiceId}`}>ملاحظات (اختياري)</Label>
            <Textarea id={`pay_notes_${invoiceId}`} name="notes" rows={2} disabled={isPending} />
          </div>

          {needsClosedDayReason && (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={`pay_closed_${invoiceId}`}>سبب التسجيل في يوم مقفل</Label>
              <Textarea id={`pay_closed_${invoiceId}`} name="closed_day_reason" rows={2} required disabled={isPending} />
              <p className="text-xs text-muted-foreground">التاريخ المحدد يقع في يوم مقفل — يتطلب صلاحية خاصة وسببًا صريحًا.</p>
            </div>
          )}

          <DialogFooter>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              تسجيل الدفعة
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

/** Reverses a supplier payment via reverse_supplier_payment() (migration 0239), gated on purchases.reverse_payment. The reversal carries its OWN business date and restores the outstanding balance exactly. */
export function SupplierPaymentReverseDialog({ paymentId, paymentNumber, amount }: { paymentId: string; paymentNumber: string; amount: string }) {
  const [open, setOpen] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const [isPending, startTransition] = useTransition();
  const [needsClosedDayReason, setNeedsClosedDayReason] = useState(false);

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);

    startTransition(async () => {
      const result = await reverseSupplierPaymentAction({
        payment_id: paymentId,
        reason: String(formData.get("reason") ?? ""),
        business_date: String(formData.get("business_date") ?? ""),
        closed_day_reason: formData.get("closed_day_reason") ? String(formData.get("closed_day_reason")) : undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم عكس الدفعة");
        setOpen(false);
        formRef.current?.reset();
        setNeedsClosedDayReason(false);
      } else {
        toast.error(result.error);
        if (isClosedDayError(result.error)) setNeedsClosedDayReason(true);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="sm">
          <Undo2 className="size-4" />
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>عكس الدفعة {paymentNumber}</DialogTitle>
          <DialogDescription>تُنشأ حركة عكس مؤرَّخة بقيمة {amount}- ويعود المبلغ إلى رصيد المستحق للمورّد.</DialogDescription>
        </DialogHeader>

        <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor={`payrev_date_${paymentId}`}>تاريخ العكس</Label>
            <Input
              id={`payrev_date_${paymentId}`}
              name="business_date"
              type="date"
              dir="ltr"
              defaultValue={new Date().toISOString().slice(0, 10)}
              required
              disabled={isPending}
            />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor={`payrev_reason_${paymentId}`}>سبب العكس</Label>
            <Textarea id={`payrev_reason_${paymentId}`} name="reason" rows={2} required disabled={isPending} />
          </div>

          {needsClosedDayReason && (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={`payrev_closed_${paymentId}`}>سبب العكس في يوم مقفل</Label>
              <Textarea id={`payrev_closed_${paymentId}`} name="closed_day_reason" rows={2} required disabled={isPending} />
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

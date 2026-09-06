"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Plus, Trash2, AlertTriangle } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { postPurchaseInvoiceAction } from "../actions";
import { isClosedDayError, sumMoney, normalizeMoney, TAX_TREATMENTS, TAX_TREATMENT_LABELS_AR, type TaxTreatment } from "../schema";
import { ROUTES } from "@/lib/constants";

type Lookup = { id: string; name_ar: string };
type SupplierLookup = { id: string; code: string; name_ar: string };
type ItemLookup = { id: string; sku: string; name_ar: string };

interface DraftLine {
  key: string;
  inventory_item_id: string;
  quantity: string;
  unit_net_cost: string;
  tax_treatment: TaxTreatment;
  tax_rate_percent: string;
  net_amount: string;
  vat_amount: string;
  gross_amount: string;
}

function emptyLine(): DraftLine {
  return {
    key: Math.random().toString(36).slice(2),
    inventory_item_id: "",
    quantity: "",
    unit_net_cost: "",
    tax_treatment: "standard",
    tax_rate_percent: "15",
    net_amount: "",
    vat_amount: "",
    gross_amount: "",
  };
}

/**
 * Posts a purchase invoice via post_purchase_invoice() (migration 0239), gated
 * on purchases.create.
 *
 * Every amount is entered and submitted as a STRING and never passed through
 * Number() or parseFloat(). The running totals shown below are computed with
 * exact integer-cent arithmetic (`sumMoney`), NOT floating point — and they
 * are only a preview: the authoritative validation happens server-side, where
 * the header must equal the sum of the lines exactly before anything is
 * written.
 *
 * Amounts are entered as the SUPPLIER'S document states them. Nothing here
 * derives VAT from the rate or rounds on the operator's behalf: the supplier's
 * paper is the source of truth, and a discrepancy is something a human must
 * see, not something software should quietly smooth over.
 *
 * `closed_day_reason` is only revealed after the server has actually said the
 * chosen date falls in a closed day, so the field can never be used to
 * pre-emptively bypass the daily-close guard (which additionally requires
 * purchases.process_closed_day, enforced in the RPC).
 */
export function PurchaseInvoiceForm({ stores, suppliers, items }: { stores: Lookup[]; suppliers: SupplierLookup[]; items: ItemLookup[] }) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [fieldErrors, setFieldErrors] = useState<Record<string, string[]> | undefined>();
  const [needsClosedDayReason, setNeedsClosedDayReason] = useState(false);

  const [supplierId, setSupplierId] = useState("");
  const [storeId, setStoreId] = useState("");
  const [businessDate, setBusinessDate] = useState(new Date().toISOString().slice(0, 10));
  const [supplierInvoiceNumber, setSupplierInvoiceNumber] = useState("");
  const [supplierInvoiceDate, setSupplierInvoiceDate] = useState("");
  const [notes, setNotes] = useState("");
  const [closedDayReason, setClosedDayReason] = useState("");
  const [lines, setLines] = useState<DraftLine[]>([emptyLine()]);

  const totals = useMemo(() => {
    let net = "0";
    let vat = "0";
    let gross = "0";
    for (const l of lines) {
      if (l.net_amount) net = sumMoney(net, l.net_amount);
      if (l.vat_amount) vat = sumMoney(vat, l.vat_amount);
      if (l.gross_amount) gross = sumMoney(gross, l.gross_amount);
    }
    return { net, vat, gross };
  }, [lines]);

  /** Lines whose own arithmetic does not hold — surfaced before submitting, never silently corrected. */
  const inconsistentLines = useMemo(
    () =>
      lines
        .map((l, i) => ({ l, i }))
        .filter(({ l }) => l.net_amount && l.gross_amount && sumMoney(l.net_amount, l.vat_amount || "0") !== normalizeMoney(l.gross_amount))
        .map(({ i }) => i + 1),
    [lines],
  );

  function updateLine(key: string, patch: Partial<DraftLine>) {
    setLines((prev) =>
      prev.map((l) => {
        if (l.key !== key) return l;
        const next = { ...l, ...patch };
        // Switching to a non-standard treatment clears VAT and the rate: such
        // a line may not carry either, and the server refuses one that does.
        if (patch.tax_treatment && patch.tax_treatment !== "standard") {
          next.vat_amount = "0";
          next.tax_rate_percent = "0";
        }
        return next;
      }),
    );
  }

  function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setFieldErrors(undefined);

    startTransition(async () => {
      const result = await postPurchaseInvoiceAction({
        supplier_id: supplierId,
        store_id: storeId,
        business_date: businessDate,
        supplier_invoice_number: supplierInvoiceNumber || undefined,
        supplier_invoice_date: supplierInvoiceDate || undefined,
        lines: lines.map((l) => ({
          inventory_item_id: l.inventory_item_id,
          quantity: l.quantity,
          unit_net_cost: l.unit_net_cost,
          tax_treatment: l.tax_treatment,
          tax_rate_percent: l.tax_rate_percent || "0",
          net_amount: l.net_amount,
          vat_amount: l.vat_amount || "0",
          gross_amount: l.gross_amount,
        })),
        net_total: totals.net,
        vat_total: totals.vat,
        gross_total: totals.gross,
        notes: notes || undefined,
        closed_day_reason: closedDayReason || undefined,
      });

      if (result.success) {
        toast.success(result.message ?? "تم الترحيل بنجاح");
        router.push(`${ROUTES.purchases}/${result.data.id}`);
      } else {
        toast.error(result.error);
        setFieldErrors(result.fieldErrors);
        if (isClosedDayError(result.error)) setNeedsClosedDayReason(true);
      }
    });
  }

  const canSubmit =
    !isPending &&
    supplierId !== "" &&
    storeId !== "" &&
    lines.length > 0 &&
    lines.every((l) => l.inventory_item_id && l.quantity && l.unit_net_cost && l.net_amount && l.gross_amount) &&
    inconsistentLines.length === 0;

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-6">
      {/* Decision 5 — stated where the operator will actually read it. This is
          an honest warning, not a structural guarantee: nothing in the system
          can stop someone from ALSO typing this purchase into the expenses
          screen by hand. The two ledgers are separate by construction; the
          duplicate-entry risk is human, and is named as such. */}
      <div className="flex gap-3 rounded-xl border border-warning/40 bg-warning/5 p-4">
        <AlertTriangle className="mt-0.5 size-5 shrink-0 text-warning" />
        <div className="text-sm">
          <p className="font-medium">شراء المخزون ليس مصروفًا تشغيليًا</p>
          <p className="mt-1 text-muted-foreground">
            هذه الفاتورة تسجَّل كاقتناء أصل (بضاعة)، ولا تدخل في مصروفات الفروع ولا في صافي العائد التشغيلي ولا في تكلفة البضاعة المباعة. لا تُسجّل هذه
            الفاتورة مرة أخرى في شاشة المصروفات — النظام لا يمنع ذلك تقنيًا، والازدواج يقع على مسؤولية المُدخِل.
          </p>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="pur_supplier">المورّد</Label>
          <Select value={supplierId} onValueChange={setSupplierId} disabled={isPending}>
            <SelectTrigger id="pur_supplier">
              <SelectValue placeholder="اختر المورّد" />
            </SelectTrigger>
            <SelectContent>
              {suppliers.map((s) => (
                <SelectItem key={s.id} value={s.id}>
                  {s.name_ar}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          {fieldErrors?.supplier_id && <p className="text-xs font-medium text-destructive">{fieldErrors.supplier_id[0]}</p>}
        </div>

        <div className="flex flex-col gap-1.5">
          <Label htmlFor="pur_store">الفرع المستلِم</Label>
          <Select value={storeId} onValueChange={setStoreId} disabled={isPending}>
            <SelectTrigger id="pur_store">
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
          <Label htmlFor="pur_business_date">تاريخ الترحيل</Label>
          <Input
            id="pur_business_date"
            type="date"
            dir="ltr"
            value={businessDate}
            onChange={(e) => setBusinessDate(e.target.value)}
            required
            disabled={isPending}
          />
          {fieldErrors?.business_date && <p className="text-xs font-medium text-destructive">{fieldErrors.business_date[0]}</p>}
        </div>
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="pur_sup_inv_no">رقم فاتورة المورّد (اختياري)</Label>
          <Input
            id="pur_sup_inv_no"
            dir="ltr"
            value={supplierInvoiceNumber}
            onChange={(e) => setSupplierInvoiceNumber(e.target.value)}
            disabled={isPending}
          />
          <p className="text-xs text-muted-foreground">لا يمكن تكرار نفس الرقم لنفس المورّد.</p>
        </div>
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="pur_sup_inv_date">تاريخ فاتورة المورّد (اختياري)</Label>
          <Input
            id="pur_sup_inv_date"
            type="date"
            dir="ltr"
            value={supplierInvoiceDate}
            onChange={(e) => setSupplierInvoiceDate(e.target.value)}
            disabled={isPending}
          />
        </div>
      </div>

      <div className="rounded-xl border border-border bg-card">
        <div className="flex items-center justify-between border-b border-border p-4">
          <div>
            <p className="font-medium">بنود الفاتورة</p>
            <p className="text-xs text-muted-foreground">تُدخل المبالغ كما وردت في فاتورة المورّد بالضبط — لا يُعاد احتساب الضريبة ولا يُقرَّب أي مبلغ.</p>
          </div>
          <Button type="button" variant="outline" onClick={() => setLines((p) => [...p, emptyLine()])} disabled={isPending}>
            <Plus className="size-4" />
            إضافة بند
          </Button>
        </div>

        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>الصنف</TableHead>
              <TableHead>الكمية</TableHead>
              <TableHead>تكلفة الوحدة</TableHead>
              <TableHead>المعالجة الضريبية</TableHead>
              <TableHead>النسبة %</TableHead>
              <TableHead>الصافي</TableHead>
              <TableHead>الضريبة</TableHead>
              <TableHead>الإجمالي</TableHead>
              <TableHead />
            </TableRow>
          </TableHeader>
          <TableBody>
            {lines.map((line, index) => (
              <TableRow key={line.key}>
                <TableCell className="min-w-[180px]">
                  <Select value={line.inventory_item_id} onValueChange={(v) => updateLine(line.key, { inventory_item_id: v })} disabled={isPending}>
                    <SelectTrigger aria-label={`صنف البند ${index + 1}`}>
                      <SelectValue placeholder="اختر الصنف" />
                    </SelectTrigger>
                    <SelectContent>
                      {items.map((it) => (
                        <SelectItem key={it.id} value={it.id}>
                          {it.name_ar} ({it.sku})
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </TableCell>
                <TableCell>
                  <Input
                    aria-label={`كمية البند ${index + 1}`}
                    inputMode="decimal"
                    dir="ltr"
                    className="w-24"
                    value={line.quantity}
                    onChange={(e) => updateLine(line.key, { quantity: e.target.value })}
                    disabled={isPending}
                  />
                </TableCell>
                <TableCell>
                  <Input
                    aria-label={`تكلفة وحدة البند ${index + 1}`}
                    inputMode="decimal"
                    dir="ltr"
                    className="w-24"
                    value={line.unit_net_cost}
                    onChange={(e) => updateLine(line.key, { unit_net_cost: e.target.value })}
                    disabled={isPending}
                  />
                </TableCell>
                <TableCell className="min-w-[160px]">
                  <Select
                    value={line.tax_treatment}
                    onValueChange={(v) => updateLine(line.key, { tax_treatment: v as TaxTreatment })}
                    disabled={isPending}
                  >
                    <SelectTrigger aria-label={`المعالجة الضريبية للبند ${index + 1}`}>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {TAX_TREATMENTS.map((t) => (
                        <SelectItem key={t} value={t}>
                          {TAX_TREATMENT_LABELS_AR[t]}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </TableCell>
                <TableCell>
                  <Input
                    aria-label={`نسبة ضريبة البند ${index + 1}`}
                    inputMode="decimal"
                    dir="ltr"
                    className="w-20"
                    value={line.tax_rate_percent}
                    onChange={(e) => updateLine(line.key, { tax_rate_percent: e.target.value })}
                    disabled={isPending || line.tax_treatment !== "standard"}
                  />
                </TableCell>
                <TableCell>
                  <Input
                    aria-label={`صافي البند ${index + 1}`}
                    inputMode="decimal"
                    dir="ltr"
                    className="w-28"
                    value={line.net_amount}
                    onChange={(e) => updateLine(line.key, { net_amount: e.target.value })}
                    disabled={isPending}
                  />
                </TableCell>
                <TableCell>
                  <Input
                    aria-label={`ضريبة البند ${index + 1}`}
                    inputMode="decimal"
                    dir="ltr"
                    className="w-24"
                    value={line.vat_amount}
                    onChange={(e) => updateLine(line.key, { vat_amount: e.target.value })}
                    disabled={isPending || line.tax_treatment !== "standard"}
                  />
                </TableCell>
                <TableCell>
                  <Input
                    aria-label={`إجمالي البند ${index + 1}`}
                    inputMode="decimal"
                    dir="ltr"
                    className="w-28"
                    value={line.gross_amount}
                    onChange={(e) => updateLine(line.key, { gross_amount: e.target.value })}
                    disabled={isPending}
                  />
                </TableCell>
                <TableCell>
                  <Button
                    type="button"
                    variant="ghost"
                    size="sm"
                    aria-label={`حذف البند ${index + 1}`}
                    onClick={() => setLines((p) => (p.length > 1 ? p.filter((x) => x.key !== line.key) : p))}
                    disabled={isPending || lines.length === 1}
                  >
                    <Trash2 className="size-4" />
                  </Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      {inconsistentLines.length > 0 && (
        <p className="text-sm font-medium text-destructive">
          البنود التالية إجماليها لا يساوي الصافي + الضريبة: {inconsistentLines.join("، ")}. راجع فاتورة المورّد.
        </p>
      )}

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">إجمالي الصافي</p>
          <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
            {totals.net}
          </p>
        </div>
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">إجمالي الضريبة كما وردت</p>
          <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
            {totals.vat}
          </p>
        </div>
        <div className="rounded-xl border border-accent/30 bg-accent/5 p-4">
          <p className="text-xs text-muted-foreground">الإجمالي (يحدّد الالتزام تجاه المورّد)</p>
          <p className="mt-1 font-mono text-lg font-semibold text-accent" dir="ltr">
            {totals.gross}
          </p>
        </div>
      </div>

      <div className="flex flex-col gap-1.5">
        <Label htmlFor="pur_notes">ملاحظات (اختياري)</Label>
        <Textarea id="pur_notes" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} />
      </div>

      {needsClosedDayReason && (
        <div className="flex flex-col gap-1.5">
          <Label htmlFor="pur_closed_day_reason">سبب الترحيل في يوم مقفل</Label>
          <Textarea
            id="pur_closed_day_reason"
            rows={2}
            value={closedDayReason}
            onChange={(e) => setClosedDayReason(e.target.value)}
            required
            disabled={isPending}
          />
          <p className="text-xs text-muted-foreground">التاريخ المحدد يقع في يوم مقفل — يتطلب صلاحية خاصة وسببًا صريحًا.</p>
        </div>
      )}

      <div className="flex justify-end">
        <Button type="submit" disabled={!canSubmit}>
          {isPending && <Loader2 className="size-4 animate-spin" />}
          ترحيل الفاتورة وإدخال الكميات للمخزون
        </Button>
      </div>
    </form>
  );
}

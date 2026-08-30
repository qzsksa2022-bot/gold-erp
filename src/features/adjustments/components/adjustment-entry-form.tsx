"use client";

import { useState, useTransition, useCallback } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Calculator } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";
import { riyadhTodayIsoDate, formatRiyadhDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { isNonNegativeDecimal, isPositiveDecimal } from "@/lib/decimal";
import { createAdjustmentAction, updateAdjustmentAction, setAdjustmentCostAction, previewAdjustmentAction } from "../actions";
import { isClosedDayError } from "../schema";

type Lookup = { id: string; name_ar: string };
type TypeLookup = { id: string; code: string; name_ar: string };
type PaymentLookup = { id: string; key: string; name_ar: string };

type OrderInfo = { sales_order_id: string; order_number: string; sale_date: string; store_name: string | null; customer_name: string | null; original_invoice_amount: string };

type ExistingAdjustment = {
  id: string;
  row_version: number;
  adjustment_type_id: string;
  processing_store_id: string;
  adjustment_date: string;
  payment_method_id: string | null;
  collection_channel_id: string | null;
  payment_reference: string | null;
  participates_in_settlement: boolean;
  customer_charge: string;
  has_direct_cost: boolean;
  direct_cost: string | null;
  notes: string | null;
};

/** True when `value` parses as a valid Decimal exactly equal to zero — used to switch the whole form into "free service" mode (Patch 6.1 items 9/10/28). Empty/invalid input is treated as NOT free (payment fields stay required until a real charge is entered). */
function isZeroCharge(value: string): boolean {
  return isNonNegativeDecimal(value) && !isPositiveDecimal(value);
}

/**
 * Create/Edit form for a Service/Adjustment — §36 (create) / §16 (edit,
 * pending-only). Every financial value stays a string end-to-end (never
 * Number()). The preview panel calls preview_sales_order_adjustment() v2
 * (0155) on blur of the relevant fields — purely informational; the DB
 * authoritatively recomputes everything at approval time (0148) and never
 * trusts this preview.
 *
 * Patch 6.1: direct_cost is now permission-gated (canManageCost, item 1D/4)
 * — a create-only actor never sees the field at all, matching the server's
 * own rejection of p_direct_cost without adjustments.manage_cost (0146). In
 * edit mode direct_cost is no longer part of the general update at all
 * (0147 dropped the parameter) — a separate "manage cost" card below uses
 * the dedicated set_pending_sales_order_adjustment_direct_cost() RPC (0145,
 * item 2) instead, with its own row_version tracking so a save there never
 * goes stale relative to the surrounding form. Zero-charge (free service)
 * mode hides/disables payment method, collection channel, payment
 * reference, and forces participates_in_settlement to false (items 9/10).
 *
 * Hotfix 6.1.1 items 3/4: crossing the paid<->free boundary (via
 * handleCustomerChargeChange below) actively CLEARS payment_method_id/
 * collection_channel_id/payment_reference/participates_in_settlement state
 * — never merely hides the fields while leaving stale values underneath, and
 * never silently restores a previously-typed value when charge goes back to
 * paid. participates_in_settlement is genuinely tri-state (boolean |
 * undefined) for a PAID adjustment — undefined ("not yet chosen") blocks
 * submit (canSubmit below) until the user explicitly picks true/false; it is
 * reset to undefined on every free->paid crossing so a fresh explicit choice
 * is always required, and forced to false (not undefined — an explicit,
 * spec-mandated rule, not a silent default) for a free service.
 */
export function AdjustmentEntryForm({
  order,
  stores,
  types,
  paymentMethods,
  collectionChannels,
  mode,
  existing,
  canManageCost,
}: {
  order: OrderInfo;
  stores: Lookup[];
  types: TypeLookup[];
  paymentMethods: PaymentLookup[];
  collectionChannels: PaymentLookup[];
  mode: "create" | "edit";
  existing?: ExistingAdjustment;
  canManageCost: boolean;
}) {
  const router = useRouter();
  const [typeId, setTypeId] = useState(existing?.adjustment_type_id ?? "");
  const [storeId, setStoreId] = useState(existing?.processing_store_id ?? "");
  const [date, setDate] = useState(existing?.adjustment_date ?? riyadhTodayIsoDate());
  const [paymentMethodId, setPaymentMethodId] = useState(existing?.payment_method_id ?? "");
  const [channelId, setChannelId] = useState(existing?.collection_channel_id ?? "");
  const [paymentReference, setPaymentReference] = useState(existing?.payment_reference ?? "");
  // Hotfix 6.1.1 item 4 — genuinely tri-state: undefined means "not yet
  // explicitly chosen" and blocks submit for a PAID adjustment (canSubmit
  // below); never silently defaults to false for a paid record. An existing
  // PENDING record being edited already carries a real explicit historical
  // choice (true/false), so it initializes from that, not undefined.
  const [participatesInSettlement, setParticipatesInSettlement] = useState<boolean | undefined>(existing?.participates_in_settlement);
  const [customerCharge, setCustomerChargeState] = useState(existing?.customer_charge ?? "");
  const [directCost, setDirectCost] = useState(existing?.direct_cost ?? "");
  const [notes, setNotes] = useState(existing?.notes ?? "");
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [isPending, startTransition] = useTransition();

  const isFree = isZeroCharge(customerCharge);

  // Hotfix 6.1.1 item 3 — the single point where customer_charge changes.
  // Crossing the paid<->free boundary actively CLEARS the payment state
  // (never just hides it while it lingers underneath): a paid->free
  // transition wipes payment_method_id/collection_channel_id/
  // payment_reference and forces participates_in_settlement to false; a
  // free->paid transition ALSO clears them (so nothing stale can possibly
  // reappear) and resets participates_in_settlement to undefined, forcing
  // the user to explicitly re-choose (item 4) rather than silently reusing
  // whatever was picked before the last free excursion.
  function handleCustomerChargeChange(nextValue: string) {
    const wasFree = isZeroCharge(customerCharge);
    const willBeFree = isZeroCharge(nextValue);
    setCustomerChargeState(nextValue);
    if (wasFree !== willBeFree) {
      setPaymentMethodId("");
      setChannelId("");
      setPaymentReference("");
      setParticipatesInSettlement(willBeFree ? false : undefined);
    }
  }

  // Shared row_version across the main form AND the separate "manage cost"
  // card below (both mutate the same record) — always updated from
  // whichever mutation last succeeded, so neither ever submits a stale
  // version against the other's write.
  const [rowVersion, setRowVersion] = useState(existing?.row_version ?? 0);
  const [hasDirectCost, setHasDirectCost] = useState(existing?.has_direct_cost ?? false);

  const [preview, setPreview] = useState<{
    fee_found: boolean;
    payment_fee_amount: string | null;
    gross_adjustment_profit: string | null;
    net_adjustment_profit: string | null;
  } | null>(null);
  const [isPreviewPending, startPreviewTransition] = useTransition();

  // Deliberately NOT auto-run on mount (even in edit mode, where fields are
  // pre-filled) — runs only in response to an explicit user interaction
  // (onBlur / onValueChange below), so this stays a plain event handler
  // rather than an effect that calls setState on render. Accepts optional
  // overrides so a Select's onValueChange (which updates state
  // asynchronously) can preview with the JUST-picked value instead of a
  // stale closure over the previous paymentMethodId. A zero-charge preview
  // needs no payment method at all (items 9/10) — preview_sales_order_
  // adjustment() v2 (0155) resolves fee=0.00 unconditionally for it.
  const runPreview = useCallback(
    (overrides?: { paymentMethodId?: string }) => {
      const effectivePaymentMethodId = overrides?.paymentMethodId ?? paymentMethodId;
      const chargeIsFree = isZeroCharge(customerCharge);
      if ((!effectivePaymentMethodId && !chargeIsFree) || !customerCharge) {
        setPreview(null);
        return;
      }
      startPreviewTransition(async () => {
        const result = await previewAdjustmentAction({
          paymentMethodId: chargeIsFree ? undefined : effectivePaymentMethodId,
          customerCharge,
          directCost: directCost || undefined,
          adjustmentDate: date || undefined,
        });
        setPreview(result.success ? result.data : null);
      });
    },
    [paymentMethodId, customerCharge, directCost, date],
  );

  function submit(closedDayReason?: string) {
    // canSubmit (below) already requires participatesInSettlement !==
    // undefined for a paid (non-free) adjustment before the submit button
    // is even enabled — so `?? false` here is unreachable dead-code
    // narrowing for TypeScript only, never a real silent default (item 4).
    // For a free adjustment it is unconditionally forced to false above in
    // handleCustomerChargeChange, so it is never undefined there either.
    const explicitParticipatesInSettlement = isFree ? false : (participatesInSettlement ?? false);
    startTransition(async () => {
      const result =
        mode === "create"
          ? await createAdjustmentAction({
              sales_order_id: order.sales_order_id,
              adjustment_type_id: typeId,
              processing_store_id: storeId,
              adjustment_date: date,
              payment_method_id: isFree ? undefined : paymentMethodId,
              collection_channel_id: isFree ? undefined : channelId,
              payment_reference: isFree ? undefined : paymentReference || undefined,
              participates_in_settlement: explicitParticipatesInSettlement,
              customer_charge: customerCharge,
              direct_cost: canManageCost ? directCost || undefined : undefined,
              notes: notes || undefined,
              closed_day_reason: closedDayReason,
            })
          : await updateAdjustmentAction({
              id: existing!.id,
              row_version: rowVersion,
              adjustment_type_id: typeId,
              processing_store_id: storeId,
              adjustment_date: date,
              payment_method_id: isFree ? undefined : paymentMethodId,
              collection_channel_id: isFree ? undefined : channelId,
              payment_reference: isFree ? undefined : paymentReference || undefined,
              participates_in_settlement: explicitParticipatesInSettlement,
              customer_charge: customerCharge,
              notes: notes || undefined,
              closed_day_reason: closedDayReason,
            });

      if (result.success) {
        toast.success(result.message ?? "تم الحفظ بنجاح");
        setPendingCloseReason(false);
        if (mode === "create") {
          // Patch 6.1 item 23 — redirect to the EDIT page (the narrow,
          // adjustments.create-alone getter), never the detail page (which
          // requires adjustments.view) — a create-only actor must be able
          // to land somewhere that doesn't immediately deny them.
          router.push(`${ROUTES.adjustments}/${(result.data as { id: string }).id}/edit`);
        } else {
          setRowVersion((result.data as { row_version: number }).row_version);
        }
        router.refresh();
        return;
      }

      if (!closedDayReason && isClosedDayError(result.error)) {
        setPendingCloseReason(true);
        return;
      }

      toast.error(result.error);
    });
  }

  // Hotfix 6.1.1 item 4 — a PAID adjustment additionally requires an
  // EXPLICIT participates_in_settlement choice (not undefined) before
  // submit is enabled at all — no silent inference, no default.
  const canSubmit = Boolean(
    typeId && storeId && date && customerCharge.trim() && (isFree || (paymentMethodId && channelId && participatesInSettlement !== undefined)),
  );

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
      <div className="flex flex-col gap-4 lg:col-span-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">عملية البيع المرتبطة</CardTitle>
          </CardHeader>
          <CardContent className="grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
            <Row label="رقم عملية البيع" value={order.order_number} dir="ltr" />
            <Row label="تاريخ البيع" value={formatRiyadhDate(order.sale_date)} />
            <Row label="المتجر" value={order.store_name ?? "—"} />
            <Row label="العميل" value={order.customer_name ?? "—"} />
            <Row label="قيمة الفاتورة الأصلية" value={order.original_invoice_amount} dir="ltr" emphasize />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-base">بيانات التعديل/الخدمة</CardTitle>
          </CardHeader>
          <CardContent className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div className="flex flex-col gap-1.5">
              <Label>نوع التعديل/الخدمة</Label>
              <Select value={typeId} onValueChange={setTypeId} disabled={isPending}>
                <SelectTrigger>
                  <SelectValue placeholder="اختر النوع" />
                </SelectTrigger>
                <SelectContent>
                  {types.map((t) => (
                    <SelectItem key={t.id} value={t.id}>
                      {t.name_ar}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>المتجر المُعالِج</Label>
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
              <Label>تاريخ التعديل/الخدمة</Label>
              <Input type="date" dir="ltr" value={date} onChange={(e) => setDate(e.target.value)} onBlur={() => runPreview()} disabled={isPending} />
            </div>

            <div className="flex flex-col gap-1.5">
              <Label>قيمة تحصيل العميل</Label>
              <Input type="number" step="0.01" min="0" dir="ltr" value={customerCharge} onChange={(e) => handleCustomerChargeChange(e.target.value)} onBlur={() => runPreview()} disabled={isPending} />
              {isFree && <p className="text-xs text-muted-foreground">قيمة تحصيل = صفر → خدمة مجانية: لا طريقة دفع ولا قناة تحصيل ولا مشاركة في التسوية (البنود 9/10).</p>}
            </div>

            {!isFree && (
              <>
                <div className="flex flex-col gap-1.5">
                  <Label>طريقة الدفع</Label>
                  <Select
                    value={paymentMethodId}
                    onValueChange={(v) => {
                      setPaymentMethodId(v);
                      runPreview({ paymentMethodId: v });
                    }}
                    disabled={isPending}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="اختر طريقة الدفع" />
                    </SelectTrigger>
                    <SelectContent>
                      {paymentMethods.map((p) => (
                        <SelectItem key={p.id} value={p.id}>
                          {p.name_ar}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>

                <div className="flex flex-col gap-1.5">
                  <Label>قناة التحصيل</Label>
                  <Select value={channelId} onValueChange={setChannelId} disabled={isPending}>
                    <SelectTrigger>
                      <SelectValue placeholder="اختر قناة التحصيل" />
                    </SelectTrigger>
                    <SelectContent>
                      {collectionChannels.map((c) => (
                        <SelectItem key={c.id} value={c.id}>
                          {c.name_ar}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>

                <div className="flex flex-col gap-1.5">
                  <Label>مرجع الدفع (اختياري)</Label>
                  <Input dir="ltr" value={paymentReference} onChange={(e) => setPaymentReference(e.target.value)} disabled={isPending} maxLength={200} />
                </div>

                <div className="flex flex-col gap-1.5">
                  <Label>المشاركة في التسوية</Label>
                  {/* Hotfix 6.1.1 item 4 — tri-state, no default: the user
                      must explicitly pick "يشارك"/"لا يشارك" before submit is
                      enabled (canSubmit below) — there is no pre-selected
                      option here on purpose. */}
                  <Select
                    value={participatesInSettlement === undefined ? "unset" : String(participatesInSettlement)}
                    onValueChange={(v) => setParticipatesInSettlement(v === "unset" ? undefined : v === "true")}
                    disabled={isPending}
                  >
                    <SelectTrigger>
                      <SelectValue placeholder="اختر" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="unset">-- اختر --</SelectItem>
                      <SelectItem value="true">يشارك في التسوية</SelectItem>
                      <SelectItem value="false">لا يشارك في التسوية</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              </>
            )}

            {mode === "create" && canManageCost && (
              <div className="flex flex-col gap-1.5">
                <Label>التكلفة المباشرة (اختياري الآن — إلزامية عند الاعتماد)</Label>
                <Input type="number" step="0.01" min="0" dir="ltr" value={directCost} onChange={(e) => setDirectCost(e.target.value)} onBlur={() => runPreview()} disabled={isPending} />
              </div>
            )}
            {mode === "create" && !canManageCost && (
              <p className="rounded-md border border-border bg-muted/40 p-2 text-xs text-muted-foreground sm:col-span-2">
                لا تملك صلاحية إدخال التكلفة المباشرة (adjustments.manage_cost) — يمكنك إنشاء التعديل/الخدمة بلا تكلفة الآن، ويقوم من يملكها بإدخالها لاحقًا قبل الاعتماد.
              </p>
            )}

            <div className="flex flex-col gap-1.5 sm:col-span-2">
              <Label>ملاحظات (اختياري)</Label>
              <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
            </div>
          </CardContent>
        </Card>

        {mode === "edit" && (
          <AdjustmentCostCard
            adjustmentId={existing!.id}
            rowVersion={rowVersion}
            hasDirectCost={hasDirectCost}
            initialDirectCost={existing?.direct_cost ?? ""}
            canManageCost={canManageCost}
            onSaved={(newRowVersion, newDirectCost) => {
              setRowVersion(newRowVersion);
              setHasDirectCost(true);
              setDirectCost(newDirectCost);
            }}
          />
        )}
      </div>

      <div className="flex flex-col gap-4">
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base">
              <Calculator className="size-4" />
              معاينة (غير نهائية)
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-2 text-sm">
            {isPreviewPending && <Loader2 className="size-4 animate-spin text-muted-foreground" />}
            {!isPreviewPending && !preview && <p className="text-xs text-muted-foreground">أدخل طريقة الدفع وقيمة تحصيل العميل لعرض المعاينة.</p>}
            {!isPreviewPending && preview && !preview.fee_found && <p className="text-xs text-warning">لا يوجد إعداد عمولة معتمد لطريقة الدفع هذه بهذا التاريخ.</p>}
            {!isPreviewPending && preview && preview.fee_found && (
              <>
                {preview.payment_fee_amount !== null && <Row label="عمولة الدفع" value={preview.payment_fee_amount} dir="ltr" />}
                {preview.gross_adjustment_profit !== null && <Row label="الربح الإجمالي" value={preview.gross_adjustment_profit} dir="ltr" />}
                {preview.net_adjustment_profit !== null && <Row label="صافي الربح" value={preview.net_adjustment_profit} dir="ltr" emphasize />}
                {preview.payment_fee_amount === null && <p className="text-xs text-muted-foreground">تفاصيل الربح غير متاحة لصلاحياتك.</p>}
              </>
            )}
            <p className="mt-1 text-xs text-muted-foreground">هذه معاينة تقديرية فقط — يعيد النظام احتساب المبالغ نهائيًا عند الاعتماد.</p>
          </CardContent>
        </Card>

        <Button variant="accent" size="lg" onClick={() => submit()} disabled={isPending || !canSubmit}>
          {isPending && <Loader2 className="size-4 animate-spin" />}
          {mode === "create" ? "إنشاء التعديل/الخدمة" : "حفظ التعديلات"}
        </Button>
      </div>

      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason) => submit(reason)} />
    </div>
  );
}

function Row({ label, value, dir, emphasize }: { label: string; value: string; dir?: "ltr" | "rtl"; emphasize?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-2">
      <span className="text-muted-foreground">{label}</span>
      <span className={emphasize ? "font-bold" : "font-medium"} dir={dir}>
        {value}
      </span>
    </div>
  );
}

/**
 * Patch 6.1 item 2/4 — a SEPARATE card for setting/correcting a PENDING
 * record's direct_cost, only rendered on the edit page and only when the
 * current actor holds adjustments.manage_cost. Uses the dedicated set_
 * pending_sales_order_adjustment_direct_cost() RPC (0145), never the
 * general update — 0147 dropped direct_cost from that RPC entirely. Reports
 * the fresh row_version back up so the surrounding form's own save never
 * submits a version this card's own write has already bumped.
 */
function AdjustmentCostCard({
  adjustmentId,
  rowVersion,
  hasDirectCost,
  initialDirectCost,
  canManageCost,
  onSaved,
}: {
  adjustmentId: string;
  rowVersion: number;
  hasDirectCost: boolean;
  initialDirectCost: string;
  canManageCost: boolean;
  onSaved: (rowVersion: number, directCost: string) => void;
}) {
  const [value, setValue] = useState(initialDirectCost);
  const [isPending, startTransition] = useTransition();

  if (!canManageCost) {
    return (
      <Card>
        <CardHeader>
          <CardTitle className="text-base">التكلفة المباشرة</CardTitle>
        </CardHeader>
        <CardContent className="text-sm text-muted-foreground">
          {hasDirectCost ? "تم إدخال التكلفة المباشرة لهذا التعديل/الخدمة." : "لم تُدخَل التكلفة المباشرة بعد — لا تملك صلاحية إدارتها (adjustments.manage_cost)."}
        </CardContent>
      </Card>
    );
  }

  function submit() {
    startTransition(async () => {
      const result = await setAdjustmentCostAction({ id: adjustmentId, row_version: rowVersion, direct_cost: value.trim() });
      if (result.success) {
        toast.success(result.message ?? "تم حفظ التكلفة المباشرة");
        onSaved(result.data.row_version, result.data.direct_cost);
      } else {
        toast.error(result.error);
      }
    });
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">التكلفة المباشرة</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        <p className="text-xs text-muted-foreground">إلزامية عند الاعتماد، حتى لخدمة مجانية بقيمة تحصيل صفر — المسار الوحيد المعتمد لإدخالها/تصحيحها أثناء الانتظار.</p>
        <div className="flex flex-col gap-1.5">
          <Label>التكلفة المباشرة</Label>
          <Input type="number" step="0.01" min="0" dir="ltr" value={value} onChange={(e) => setValue(e.target.value)} disabled={isPending} />
        </div>
        <Button variant="outline" onClick={submit} disabled={isPending || !value.trim()}>
          {isPending && <Loader2 className="size-4 animate-spin" />}
          حفظ التكلفة المباشرة
        </Button>
      </CardContent>
    </Card>
  );
}

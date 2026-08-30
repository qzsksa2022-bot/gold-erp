"use client";

import { Fragment, useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { usePermissions } from "@/lib/permissions/context";
import { ROUTES } from "@/lib/constants";
import { riyadhTodayIsoDate, formatRiyadhDate } from "@/lib/date";
import { createSalesReturnAction, previewSalesReturnAction, updatePendingSalesReturnAction } from "../actions";
import {
  RETURN_SCENARIOS,
  RETURN_SCENARIO_LABELS_AR,
  COLLECTION_STATES,
  COLLECTION_STATE_LABELS_AR,
  RETURN_ITEM_CONDITIONS,
  RETURN_ITEM_CONDITION_LABELS_AR,
  isClosedDayError,
  isVersionConflictError,
} from "../schema";
import { ClosedDayReasonDialog } from "@/features/sales/components/closed-day-reason-dialog";
import type { SalesReturnItemCondition } from "@/types/database";

// Patch 4.2 (Section 7) — narrowed to the {id, name_ar} shape the new
// returns_operable_store_lookups()/returns_visible_store_lookups() RPCs
// return (migration 0105), replacing the old full stores.Row shape that
// implicitly assumed a direct `stores` table read.
type Store = { id: string; name_ar: string };

export type ReturnableItem = {
  id: string;
  line_no: number;
  category_name_ar_snapshot: string;
  karat_code_snapshot: string;
  karat_name_ar_snapshot: string;
  weight_grams: string;
  sale_price: string;
  returnable: boolean;
  gross_profit?: string;
};

export type ReturnableOrder = {
  sales_order_id: string;
  order_number: string;
  store_id: string;
  store_name: string | null;
  sale_date: string;
  row_version: number;
  customer_name: string | null;
  customer_phone: string | null;
  payment_method_id: string;
  order_state: "full" | "partial" | "not_returned";
  items: ReturnableItem[];
  existing_returns: { id: string; return_number: string; status: string; created_at: string }[];
};

export type ExistingReturnItem = {
  id: string;
  sales_order_item_id: string;
  condition?: SalesReturnItemCondition;
  item_return_reason?: string | null;
  item_notes?: string | null;
};

export type ExistingReturn = {
  id: string;
  processed_store_id: string;
  return_date: string;
  scenario: string;
  scenario_notes: string | null;
  collection_state?: string;
  approved_refund_amount?: string | null;
  non_shipping_deduction_amount?: string | null;
  deduction_reason?: string | null;
  refund_difference_reason?: string | null;
  row_version: number;
  items: ExistingReturnItem[];
};

type PreviewResult = {
  returned_original_sale_amount?: string;
  sales_revenue_reversal_amount?: string;
  suggested_approved_refund_amount?: string;
  estimated_payment_fee_reversal_amount?: string;
  recovered_original_cost_amount?: string;
  estimated_net_sales_profit_adjustment?: string;
  // Patch 4.2 (Section 5) — preview_sales_return() (0100) now echoes back
  // whatever approved_refund_amount the caller actually supplied, plus the
  // resulting variance vs. the revenue reversal — never a value Preview
  // invented itself. Used to show "you entered X, expected variance Y"
  // instead of silently overwriting a manually-entered figure.
  approved_refund_amount?: string | null;
  refund_variance?: string | null;
};

export function ReturnEntryForm({
  mode,
  order,
  stores,
  existingReturn,
}: {
  mode: "create" | "edit";
  order: ReturnableOrder;
  stores: Store[];
  existingReturn?: ExistingReturn;
}) {
  const router = useRouter();
  const { can } = usePermissions();
  const canViewProfit = can("sales.view_profit");
  const isEdit = mode === "edit";

  const [processedStoreId, setProcessedStoreId] = useState(existingReturn?.processed_store_id ?? (stores.some((s) => s.id === order.store_id) ? order.store_id : ""));
  const [returnDate, setReturnDate] = useState(existingReturn?.return_date ?? riyadhTodayIsoDate());
  const [scenario, setScenario] = useState(existingReturn?.scenario ?? "");
  const [scenarioNotes, setScenarioNotes] = useState(existingReturn?.scenario_notes ?? "");
  const [selectedIds, setSelectedIds] = useState<Set<string>>(
    new Set(existingReturn ? existingReturn.items.map((it) => it.sales_order_item_id) : []),
  );
  const [conditions, setConditions] = useState<Record<string, SalesReturnItemCondition>>(() => {
    const map: Record<string, SalesReturnItemCondition> = {};
    existingReturn?.items.forEach((it) => {
      map[it.sales_order_item_id] = it.condition ?? "unknown";
    });
    return map;
  });
  // Patch 4.2 (Section 8) — per-item Return Reason/Notes, previously
  // captured by create_sales_return()/DB (condition, item_return_reason,
  // item_notes are all on sales_return_items already) but never surfaced by
  // this form. Edit mode reloads existing values the same way `conditions`
  // does above.
  const [itemReasons, setItemReasons] = useState<Record<string, string>>(() => {
    const map: Record<string, string> = {};
    existingReturn?.items.forEach((it) => {
      if (it.item_return_reason) map[it.sales_order_item_id] = it.item_return_reason;
    });
    return map;
  });
  const [itemNotes, setItemNotes] = useState<Record<string, string>>(() => {
    const map: Record<string, string> = {};
    existingReturn?.items.forEach((it) => {
      if (it.item_notes) map[it.sales_order_item_id] = it.item_notes;
    });
    return map;
  });
  // Compact-by-default — Reason/Notes only render once a row is expanded, to
  // avoid cluttering the item table for the common case where neither is
  // needed.
  const [expandedItemIds, setExpandedItemIds] = useState<Set<string>>(new Set());

  const [collectionState, setCollectionState] = useState(existingReturn?.collection_state ?? "");
  const [deductionAmount, setDeductionAmount] = useState(existingReturn?.non_shipping_deduction_amount ?? "0");
  const [deductionReason, setDeductionReason] = useState(existingReturn?.deduction_reason ?? "");
  const [approvedRefundAmount, setApprovedRefundAmount] = useState(existingReturn?.approved_refund_amount ?? "");
  const [refundDifferenceReason, setRefundDifferenceReason] = useState(existingReturn?.refund_difference_reason ?? "");
  const [refundTouched, setRefundTouched] = useState(!!existingReturn);

  const [preview, setPreview] = useState<PreviewResult | null>(null);
  const [isPending, startTransition] = useTransition();
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  const [versionConflict, setVersionConflict] = useState(false);

  function isSelectable(item: ReturnableItem) {
    return item.returnable || selectedIds.has(item.id);
  }

  function toggleItem(id: string) {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
    setConditions((prev) => (prev[id] ? prev : { ...prev, [id]: "unknown" }));
  }

  function itemsPayload() {
    return Array.from(selectedIds).map((id) => ({
      sales_order_item_id: id,
      condition: conditions[id] ?? ("unknown" as SalesReturnItemCondition),
      item_return_reason: itemReasons[id]?.trim() || undefined,
      item_notes: itemNotes[id]?.trim() || undefined,
    }));
  }

  function toggleExpanded(id: string) {
    setExpandedItemIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  // customer_never_received + not_collected suggests approved_refund=0 —
  // the UI nudges this default (applied at the moment either input changes,
  // not via an effect), but the DB (not this suggestion) is the real
  // enforcement (Section 2/15).
  function handleScenarioChange(value: string) {
    setScenario(value);
    if (!refundTouched && value === "customer_never_received" && collectionState === "not_collected") {
      setApprovedRefundAmount("0");
    }
  }

  function handleCollectionStateChange(value: string) {
    setCollectionState(value);
    if (!refundTouched && scenario === "customer_never_received" && value === "not_collected") {
      setApprovedRefundAmount("0");
    }
  }

  // Debounced live Preview (mirrors SalesEntryForm's own pattern) — a UX
  // convenience only, using the SAME financial helper approval uses
  // (Section 16). Not the Source of Truth — approval recomputes fully.
  useEffect(() => {
    const handle = setTimeout(() => {
      if (selectedIds.size === 0) {
        setPreview(null);
        return;
      }
      previewSalesReturnAction({
        sales_order_id: order.sales_order_id,
        items: itemsPayload(),
        scenario: (scenario || undefined) as never,
        collection_state: (collectionState || undefined) as never,
        non_shipping_deduction_amount: deductionAmount || "0",
        deduction_reason: deductionReason || undefined,
        approved_refund_amount: approvedRefundAmount || undefined,
        refund_difference_reason: refundDifferenceReason || undefined,
      }).then((result) => {
        setPreview(result.success ? (result.data as PreviewResult) : null);
        if (result.success && !refundTouched) {
          const suggested = (result.data as PreviewResult).suggested_approved_refund_amount;
          // React bails out of a re-render when setState receives a value
          // === the current state, so setting an unchanged suggestion here
          // is safe even with approvedRefundAmount itself listed as a
          // dependency below — this cannot loop.
          if (suggested) setApprovedRefundAmount(suggested);
        }
      });
    }, 400);

    return () => clearTimeout(handle);
    // Patch 4.2 (Section 5) — `scenario` now feeds the preview (customer_
    // never_received suggestion rule), and `approvedRefundAmount`/
    // `refundDifferenceReason` are now real dependencies (previously a stale-
    // closure bug: a manual approvedRefundAmount edit didn't retrigger
    // Preview, so its echoed approved_refund_amount/refund_variance could
    // silently go stale).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    selectedIds,
    conditions,
    itemReasons,
    itemNotes,
    scenario,
    collectionState,
    deductionAmount,
    deductionReason,
    approvedRefundAmount,
    refundDifferenceReason,
    order.sales_order_id,
  ]);

  function submit(closedDayReason?: string) {
    if (versionConflict) return;
    if (!scenario) {
      toast.error("اختر سيناريو المرتجع");
      return;
    }
    if (selectedIds.size === 0) {
      toast.error("اختر بندًا واحدًا على الأقل للإرجاع");
      return;
    }
    if (!isEdit && !processedStoreId) {
      toast.error("اختر المتجر الذي يتم فيه معالجة المرتجع");
      return;
    }
    if (!collectionState) {
      toast.error("اختر حالة تحصيل المبلغ الأصلي");
      return;
    }
    if (!approvedRefundAmount) {
      toast.error("أدخل قيمة الاسترداد المعتمد");
      return;
    }

    startTransition(async () => {
      const result = isEdit
        ? await updatePendingSalesReturnAction({
            return_id: existingReturn!.id,
            row_version: existingReturn!.row_version,
            scenario: scenario as (typeof RETURN_SCENARIOS)[number],
            items: itemsPayload(),
            collection_state: collectionState as (typeof COLLECTION_STATES)[number],
            approved_refund_amount: approvedRefundAmount,
            non_shipping_deduction_amount: deductionAmount || "0",
            deduction_reason: deductionReason || undefined,
            refund_difference_reason: refundDifferenceReason || undefined,
            scenario_notes: scenarioNotes || undefined,
            closed_day_reason: closedDayReason,
          })
        : await createSalesReturnAction({
            sales_order_id: order.sales_order_id,
            processed_store_id: processedStoreId,
            return_date: returnDate,
            scenario: scenario as (typeof RETURN_SCENARIOS)[number],
            items: itemsPayload(),
            expected_sale_version: order.row_version,
            collection_state: collectionState as (typeof COLLECTION_STATES)[number],
            approved_refund_amount: approvedRefundAmount,
            non_shipping_deduction_amount: deductionAmount || "0",
            deduction_reason: deductionReason || undefined,
            refund_difference_reason: refundDifferenceReason || undefined,
            scenario_notes: scenarioNotes || undefined,
            closed_day_reason: closedDayReason,
          });

      if (result.success) {
        toast.success(result.message ?? "تم الحفظ بنجاح");
        setPendingCloseReason(false);
        router.push(`${ROUTES.returns}/${result.data.id}`);
        return;
      }

      if (!closedDayReason && isClosedDayError(result.error)) {
        setPendingCloseReason(true);
        return;
      }

      if (isEdit && isVersionConflictError(result.error)) {
        setVersionConflict(true);
      }

      toast.error(result.error);
    });
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    submit();
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      {versionConflict && (
        <div className="flex flex-col gap-2 rounded-lg border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive sm:flex-row sm:items-center sm:justify-between">
          <span>تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الحفظ.</span>
          <Button type="button" variant="outline" size="sm" onClick={() => router.refresh()}>
            تحديث الصفحة
          </Button>
        </div>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">بيانات عملية البيع</CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-1 gap-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
          <Info label="رقم العملية" value={order.order_number} dir="ltr" mono />
          <Info label="تاريخ البيع" value={formatRiyadhDate(order.sale_date)} />
          <Info label="المتجر الأصلي" value={order.store_name ?? "—"} />
          <Info label="العميل" value={order.customer_name ?? "—"} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">بيانات المرتجع</CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div className="flex flex-col gap-1.5">
            <Label>المتجر المعالِج للمرتجع</Label>
            <Select value={processedStoreId} onValueChange={setProcessedStoreId} disabled={isPending || isEdit}>
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
            <Label>تاريخ المرتجع</Label>
            <Input
              type="date"
              dir="ltr"
              value={returnDate}
              onChange={(e) => setReturnDate(e.target.value)}
              disabled={isPending || isEdit}
              min={order.sale_date}
              max={riyadhTodayIsoDate()}
              required
            />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>سيناريو المرتجع</Label>
            <Select value={scenario} onValueChange={handleScenarioChange} disabled={isPending}>
              <SelectTrigger>
                <SelectValue placeholder="اختر السيناريو" />
              </SelectTrigger>
              <SelectContent>
                {RETURN_SCENARIOS.map((s) => (
                  <SelectItem key={s} value={s}>
                    {RETURN_SCENARIO_LABELS_AR[s]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>حالة تحصيل المبلغ الأصلي</Label>
            <Select value={collectionState} onValueChange={handleCollectionStateChange} disabled={isPending}>
              <SelectTrigger>
                <SelectValue placeholder="اختر الحالة" />
              </SelectTrigger>
              <SelectContent>
                {COLLECTION_STATES.map((s) => (
                  <SelectItem key={s} value={s}>
                    {COLLECTION_STATE_LABELS_AR[s]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5 sm:col-span-2 lg:col-span-3">
            <Label>ملاحظات السيناريو{scenario === "other" ? " (مطلوبة)" : " (اختياري)"}</Label>
            <Textarea value={scenarioNotes} onChange={(e) => setScenarioNotes(e.target.value)} disabled={isPending} rows={2} />
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">الاستقطاع والاسترداد المعتمد</CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div className="flex flex-col gap-1.5">
            <Label>قيمة الاستقطاع (غير متعلقة بالشحن)</Label>
            <Input dir="ltr" value={deductionAmount} onChange={(e) => setDeductionAmount(e.target.value)} disabled={isPending} inputMode="decimal" />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>سبب الاستقطاع{deductionAmount && deductionAmount !== "0" ? " (مطلوب)" : " (اختياري)"}</Label>
            <Input value={deductionReason} onChange={(e) => setDeductionReason(e.target.value)} disabled={isPending} />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>قيمة الاسترداد المعتمد</Label>
            <Input
              dir="ltr"
              value={approvedRefundAmount}
              onChange={(e) => {
                setApprovedRefundAmount(e.target.value);
                setRefundTouched(true);
              }}
              disabled={isPending}
              inputMode="decimal"
            />
          </div>
          <div className="flex flex-col gap-1.5">
            <Label>سبب الفرق (إن اختلف الاسترداد المعتمد عن صافي عكس الإيراد)</Label>
            <Input value={refundDifferenceReason} onChange={(e) => setRefundDifferenceReason(e.target.value)} disabled={isPending} />
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">اختر البنود المراد إرجاعها</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-10"></TableHead>
                <TableHead className="w-10">#</TableHead>
                <TableHead>التصنيف</TableHead>
                <TableHead>العيار</TableHead>
                <TableHead>الوزن</TableHead>
                <TableHead>سعر البيع</TableHead>
                {canViewProfit && <TableHead>الربح</TableHead>}
                <TableHead>حالة الصنف المرتجع</TableHead>
                <TableHead></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {order.items.map((item) => {
                const selectable = isSelectable(item);
                const checked = selectedIds.has(item.id);
                const expanded = expandedItemIds.has(item.id);
                const hasReasonOrNotes = !!itemReasons[item.id] || !!itemNotes[item.id];
                return (
                  <Fragment key={item.id}>
                    <TableRow className={!selectable ? "opacity-50" : undefined}>
                      <TableCell>
                        <input
                          type="checkbox"
                          checked={checked}
                          disabled={isPending || !selectable}
                          onChange={() => toggleItem(item.id)}
                          className="size-4 accent-accent"
                        />
                      </TableCell>
                      <TableCell className="text-xs text-muted-foreground">{item.line_no}</TableCell>
                      <TableCell>{item.category_name_ar_snapshot}</TableCell>
                      <TableCell>{item.karat_name_ar_snapshot}</TableCell>
                      <TableCell dir="ltr">{item.weight_grams}</TableCell>
                      <TableCell className="font-medium" dir="ltr">
                        {item.sale_price}
                      </TableCell>
                      {canViewProfit && (
                        <TableCell dir="ltr" className="text-muted-foreground">
                          {item.gross_profit ?? "—"}
                        </TableCell>
                      )}
                      <TableCell>
                        {checked ? (
                          <div className="flex items-center gap-2">
                            <Select
                              value={conditions[item.id] ?? "unknown"}
                              onValueChange={(v) => setConditions((prev) => ({ ...prev, [item.id]: v as SalesReturnItemCondition }))}
                              disabled={isPending}
                            >
                              <SelectTrigger className="h-8 w-40">
                                <SelectValue />
                              </SelectTrigger>
                              <SelectContent>
                                {RETURN_ITEM_CONDITIONS.map((c) => (
                                  <SelectItem key={c} value={c}>
                                    {RETURN_ITEM_CONDITION_LABELS_AR[c]}
                                  </SelectItem>
                                ))}
                              </SelectContent>
                            </Select>
                            <Button
                              type="button"
                              variant="ghost"
                              size="sm"
                              className={hasReasonOrNotes ? "text-accent" : "text-muted-foreground"}
                              onClick={() => toggleExpanded(item.id)}
                            >
                              {expanded ? "إخفاء التفاصيل" : hasReasonOrNotes ? "تفاصيل ●" : "تفاصيل"}
                            </Button>
                          </div>
                        ) : (
                          "—"
                        )}
                      </TableCell>
                      <TableCell>{!selectable && <Badge variant="warning">غير قابل للإرجاع</Badge>}</TableCell>
                    </TableRow>
                    {checked && expanded && (
                      <TableRow key={`${item.id}-details`}>
                        <TableCell colSpan={canViewProfit ? 9 : 8} className="bg-muted/30">
                          <div className="grid grid-cols-1 gap-3 py-2 sm:grid-cols-2">
                            <div className="flex flex-col gap-1.5">
                              <Label className="text-xs">سبب إرجاع الصنف (اختياري)</Label>
                              <Input
                                value={itemReasons[item.id] ?? ""}
                                onChange={(e) => setItemReasons((prev) => ({ ...prev, [item.id]: e.target.value }))}
                                disabled={isPending}
                              />
                            </div>
                            <div className="flex flex-col gap-1.5">
                              <Label className="text-xs">ملاحظات على الصنف (اختياري)</Label>
                              <Input
                                value={itemNotes[item.id] ?? ""}
                                onChange={(e) => setItemNotes((prev) => ({ ...prev, [item.id]: e.target.value }))}
                                disabled={isPending}
                              />
                            </div>
                          </div>
                        </TableCell>
                      </TableRow>
                    )}
                  </Fragment>
                );
              })}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Card>
        <CardContent className="flex flex-col gap-4 pt-6">
          <div className="grid grid-cols-2 gap-4 text-sm sm:grid-cols-3 lg:grid-cols-5">
            <PreviewStat label="مبلغ البيع الأصلي المرتجع" value={preview?.returned_original_sale_amount} />
            <PreviewStat label="عكس الإيراد" value={preview?.sales_revenue_reversal_amount} big />
            <PreviewStat label="الاسترداد المقترَح" value={preview?.suggested_approved_refund_amount} />
            {refundTouched && preview?.refund_variance !== undefined && preview?.refund_variance !== null && (
              <PreviewStat label="الفارق عن صافي عكس الإيراد" value={preview?.refund_variance} />
            )}
            <PreviewStat label="استرداد العمولة (تقديري)" value={preview?.estimated_payment_fee_reversal_amount} />
            {canViewProfit && <PreviewStat label="التكلفة المستردة" value={preview?.recovered_original_cost_amount} />}
            {canViewProfit && <PreviewStat label="أثر صافي الربح (تقديري)" value={preview?.estimated_net_sales_profit_adjustment} />}
          </div>
          <div className="flex justify-end">
            <Button type="submit" variant="accent" size="lg" disabled={isPending}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              {isEdit ? "حفظ التعديلات" : "إنشاء المرتجع"}
            </Button>
          </div>
        </CardContent>
      </Card>

      <ClosedDayReasonDialog open={pendingCloseReason} onOpenChange={setPendingCloseReason} isPending={isPending} onConfirm={(reason) => submit(reason)} />
    </form>
  );
}

function Info({ label, value, dir, mono }: { label: string; value: string; dir?: "ltr" | "rtl"; mono?: boolean }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-xs text-muted-foreground">{label}</span>
      <span className={mono ? "font-mono" : "font-medium"} dir={dir}>
        {value}
      </span>
    </div>
  );
}

function PreviewStat({ label, value, big }: { label: string; value?: string; big?: boolean }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-xs text-muted-foreground">{label}</span>
      <span className={big ? "text-xl font-bold" : "font-medium"} dir="ltr">
        {value ?? "—"}
      </span>
    </div>
  );
}

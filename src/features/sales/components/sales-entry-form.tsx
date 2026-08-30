"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Plus, Trash2, Loader2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { usePermissions } from "@/lib/permissions/context";
import { ROUTES } from "@/lib/constants";
import { riyadhTodayIsoDate } from "@/lib/date";
import { toDecimal, toFixedString, Decimal } from "@/lib/decimal";
import { createSalesOrderAction, previewSalesOrderAction, previewUpdateSalesOrderAction, updateSalesOrderAction } from "../actions";
import { isClosedDayError, isVersionConflictError } from "../schema";
import { ClosedDayReasonDialog } from "./closed-day-reason-dialog";
import type { Database } from "@/types/database";

type Karat = Database["public"]["Tables"]["karats"]["Row"];
type Category = Database["public"]["Tables"]["product_categories"]["Row"];
type Channel = Database["public"]["Tables"]["collection_channels"]["Row"];
type PaymentMethod = Database["public"]["Tables"]["payment_methods"]["Row"];
type Store = Database["public"]["Tables"]["stores"]["Row"];

// Patch 3.2 item 6 — a normalized Select option shared by both the New Sale
// form's active-only lookups (getSalesFormLookups(), mapped down from the
// full Karat/Category/Channel/PaymentMethod rows) and the Edit form's
// historical-inclusive lookups (sales_order_edit_lookups(), migration
// 0080). `is_historical` is only ever set on an Edit-mode option, and is
// never true for anything OTHER than the order's own current value — the
// server itself controls that set, this component never invents one.
type LookupOption = { id: string; name_ar: string; code?: string; is_historical?: boolean };

function optionLabel(opt: LookupOption): string {
  return opt.is_historical ? `${opt.name_ar} (غير نشط - تاريخي)` : opt.name_ar;
}

type ItemRow = {
  key: string;
  // Patch 3.1 item 1/9 — the existing DB row's id, present only for an
  // item loaded from an existingOrder (i.e. being edited/kept), absent for
  // a brand-new item added in this session. `key` (a local-only React key)
  // must never be confused with this: `key` is regenerated every render
  // session and never sent to the server; `id` is the stable server
  // identity and is exactly what buildPayload() forwards so
  // update_sales_order() can tell "keep/edit this row" apart from "insert a
  // new row" and soft-remove anything dropped from the payload.
  id?: string;
  category_id: string;
  karat_id: string;
  weight_grams: string;
  sale_price: string;
  item_name: string;
  description: string;
};

function emptyItem(): ItemRow {
  return { key: crypto.randomUUID(), category_id: "", karat_id: "", weight_grams: "", sale_price: "", item_name: "", description: "" };
}

type PreviewItem = {
  line_no: number;
  total_cost?: string;
  gross_profit?: string;
};

type PreviewResult = {
  subtotal?: string;
  gross_profit?: string;
  payment_fee_amount?: string;
  net_sales_profit?: string;
  items?: PreviewItem[];
};

type ExistingOrderItem = {
  id: string;
  category_id: string;
  karat_id: string;
  weight_grams: string;
  sale_price: string;
  item_name: string | null;
  description: string | null;
};

type ExistingOrder = {
  id: string;
  order_number: string;
  store_id: string;
  // Patch 3.2 item 8 — resolved server-side by get_sales_order() (0079);
  // the store field is disabled/read-only in Edit mode regardless, so this
  // is display-only and needs no separate lookup query.
  store_name: string | null;
  sale_date: string;
  payment_method_id: string;
  collection_channel_id: string;
  customer_name: string | null;
  customer_phone: string | null;
  notes: string | null;
  is_day_closed: boolean;
  // Patch 3.2 item 2 — optimistic-concurrency token loaded with the order;
  // submitted back as p_expected_version on every Preview/Save. Never
  // fabricated client-side, and never silently bumped after a Conflict —
  // only a fresh reload (see the conflict banner below) advances it.
  row_version: number;
  items: ExistingOrderItem[];
};

// Patch 3.2 item 6 — historical-inclusive option set for the Edit form,
// from sales_order_edit_lookups() (migration 0080) via
// getSalesOrderEditLookups(). Required when isEdit, unused otherwise.
type EditLookups = {
  categories: LookupOption[];
  karats: LookupOption[];
  paymentMethods: LookupOption[];
  collectionChannels: LookupOption[];
};

export function SalesEntryForm({
  lookups,
  editLookups,
  existingOrder,
}: {
  // Active-only lookups for the New Sale form (getSalesFormLookups()).
  // Optional because the Edit form uses editLookups instead.
  lookups?: { karats: Karat[]; categories: Category[]; collectionChannels: Channel[]; paymentMethods: PaymentMethod[]; operableStores: Store[] };
  editLookups?: EditLookups;
  existingOrder?: ExistingOrder;
}) {
  const router = useRouter();
  const { can } = usePermissions();
  const canViewProfit = can("sales.view_profit");
  const isEdit = Boolean(existingOrder);

  const [storeId, setStoreId] = useState(existingOrder?.store_id ?? "");
  const [saleDate, setSaleDate] = useState(existingOrder?.sale_date ?? riyadhTodayIsoDate());
  const [paymentMethodId, setPaymentMethodId] = useState(existingOrder?.payment_method_id ?? "");
  const [collectionChannelId, setCollectionChannelId] = useState(existingOrder?.collection_channel_id ?? "");
  const [customerName, setCustomerName] = useState(existingOrder?.customer_name ?? "");
  const [customerPhone, setCustomerPhone] = useState(existingOrder?.customer_phone ?? "");
  const [notes, setNotes] = useState(existingOrder?.notes ?? "");

  // Patch 3.2 item 6 — normalized option lists the four reference Selects
  // below actually render: the Edit form's historical-inclusive set when
  // editing, the New Sale form's active-only set (mapped down to the same
  // shape) otherwise. The server (sales_order_edit_lookups()/
  // update_sales_order()) is the real authority on what is selectable —
  // this component only ever renders what it was handed.
  const categoryOptions: LookupOption[] = isEdit ? (editLookups?.categories ?? []) : (lookups?.categories ?? []).map((c) => ({ id: c.id, name_ar: c.name_ar }));
  const karatOptions: LookupOption[] = isEdit ? (editLookups?.karats ?? []) : (lookups?.karats ?? []).map((k) => ({ id: k.id, name_ar: k.name_ar }));
  const paymentMethodOptions: LookupOption[] = isEdit
    ? (editLookups?.paymentMethods ?? [])
    : (lookups?.paymentMethods ?? []).map((m) => ({ id: m.id, name_ar: m.name_ar }));
  const collectionChannelOptions: LookupOption[] = isEdit
    ? (editLookups?.collectionChannels ?? [])
    : (lookups?.collectionChannels ?? []).map((c) => ({ id: c.id, name_ar: c.name_ar }));
  const storeOptions: LookupOption[] = isEdit
    ? [{ id: existingOrder!.store_id, name_ar: existingOrder!.store_name ?? "—" }]
    : (lookups?.operableStores ?? []).map((s) => ({ id: s.id, name_ar: s.name_ar }));
  const [items, setItems] = useState<ItemRow[]>(
    existingOrder && existingOrder.items.length > 0
      ? existingOrder.items.map((it) => ({
          key: crypto.randomUUID(),
          id: it.id,
          category_id: it.category_id,
          karat_id: it.karat_id,
          weight_grams: it.weight_grams,
          sale_price: it.sale_price,
          item_name: it.item_name ?? "",
          description: it.description ?? "",
        }))
      : [emptyItem()],
  );

  const [preview, setPreview] = useState<PreviewResult | null>(null);
  const [isPending, startTransition] = useTransition();
  const [pendingCloseReason, setPendingCloseReason] = useState(false);
  // Patch 3.2 item 2/5 — set on a Conflict response from Save (or surfaced
  // by the Edit preview). Never cleared by silently resubmitting the same
  // payload -- only a real reload (router.refresh(), re-fetching the
  // current row_version) may clear it.
  const [versionConflict, setVersionConflict] = useState(false);

  // Debounced live Preview (spec §17) — a UX convenience only, never the
  // source of truth. Fires whenever any financial input changes. In Edit
  // mode this calls previewUpdateSalesOrderAction (Patch 3.2 item 5),
  // which mirrors update_sales_order()'s own unchanged-vs-recalculated
  // decision tree, so the preview matches exactly what Save will produce
  // -- previewSalesOrderAction (Create's preview) treats every item as
  // brand-new and would drift from Save's actual result on an edit.
  useEffect(() => {
    const handle = setTimeout(() => {
      const validItems = items.filter((it) => it.category_id && it.karat_id && it.weight_grams && it.sale_price);
      if (!paymentMethodId || !collectionChannelId || validItems.length === 0 || (!isEdit && (!storeId || !saleDate))) {
        setPreview(null);
        return;
      }

      const itemsPayload = validItems.map((it) => ({
        ...(it.id ? { id: it.id } : {}),
        category_id: it.category_id,
        karat_id: it.karat_id,
        weight_grams: it.weight_grams,
        sale_price: it.sale_price,
      }));

      const previewPromise = isEdit
        ? previewUpdateSalesOrderAction({
            order_id: existingOrder!.id,
            row_version: existingOrder!.row_version,
            payment_method_id: paymentMethodId,
            collection_channel_id: collectionChannelId,
            customer_name: customerName || undefined,
            customer_phone: customerPhone || undefined,
            notes: notes || undefined,
            items: itemsPayload,
          })
        : previewSalesOrderAction({
            store_id: storeId,
            sale_date: saleDate,
            payment_method_id: paymentMethodId,
            collection_channel_id: collectionChannelId,
            items: itemsPayload,
          });

      previewPromise.then((result) => {
        if (result.success) {
          setPreview(result.data as PreviewResult);
        } else {
          setPreview(null);
          if (isEdit && isVersionConflictError(result.error)) setVersionConflict(true);
        }
      });
    }, 400);

    return () => clearTimeout(handle);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [storeId, saleDate, paymentMethodId, collectionChannelId, customerName, customerPhone, notes, JSON.stringify(items)]);

  // Hotfix 3.2.1 item 1 — a Conflict banner (and every other piece of this
  // form's local state: items/paymentMethodId/collectionChannelId/customer
  // fields/notes) is NEVER reset in place by an effect or a render-time
  // state adjustment keyed on existingOrder.row_version. An earlier version
  // of this component tried exactly that (clearing only `versionConflict`
  // when row_version changed) and it was insufficient: router.refresh()
  // hands this already-mounted client component a fresh `existingOrder`
  // prop WITHOUT unmounting it, so every other local field (most
  // importantly each item's weight_grams/sale_price) stayed stale — a user
  // could reload after a Conflict, see the banner disappear, and still Save
  // the OTHER user's just-committed edit right over again with old values,
  // silently defeating the entire point of optimistic concurrency. The
  // fix lives one level up, in the Edit page (src/app/(app)/sales/[id]/
  // edit/page.tsx): `<SalesEntryForm key={order.row_version} .../>`. A
  // changed `key` forces React to unmount this ENTIRE component instance
  // and mount a brand-new one on reload, so every `useState` above
  // (including versionConflict) is re-initialized from the fresh
  // existingOrder with no exceptions and no partial resets to maintain here.
  // See tests/sales-entry-form-conflict-reload.test.tsx for the regression
  // test proving this.

  // Display-only fallback subtotal, shown until the server Preview (the
  // real source of truth) arrives — Decimal, never Number()/parseFloat(),
  // per spec item 9 (this exact line was the JS-float usage the item
  // flagged: Number(it.sale_price) silently coerces invalid/empty input to
  // NaN instead of failing loudly, and accumulates IEEE-754 rounding error
  // across items — see src/lib/decimal.ts).
  const subtotal = useMemo(() => {
    return items.reduce((sum, it) => {
      try {
        return sum.plus(toDecimal(it.sale_price || "0"));
      } catch {
        return sum;
      }
    }, new Decimal(0));
  }, [items]);

  function updateItem(key: string, patch: Partial<ItemRow>) {
    setItems((prev) => prev.map((it) => (it.key === key ? { ...it, ...patch } : it)));
  }

  function addItem() {
    setItems((prev) => [...prev, emptyItem()]);
  }

  function removeItem(key: string) {
    setItems((prev) => (prev.length > 1 ? prev.filter((it) => it.key !== key) : prev));
  }

  function buildPayload(closedDayReason?: string) {
    return {
      payment_method_id: paymentMethodId,
      collection_channel_id: collectionChannelId,
      customer_name: customerName || undefined,
      customer_phone: customerPhone || undefined,
      notes: notes || undefined,
      items: items.map((it) => ({
        // Stable identity (spec item 1/9): forward the existing row's id
        // when editing/keeping it; omit for a brand-new row. Any existing
        // item whose id is NOT present here gets soft-removed server-side.
        ...(it.id ? { id: it.id } : {}),
        category_id: it.category_id,
        karat_id: it.karat_id,
        weight_grams: it.weight_grams,
        sale_price: it.sale_price,
        item_name: it.item_name || undefined,
        description: it.description || undefined,
      })),
      closed_day_reason: closedDayReason,
    };
  }

  function submit(closedDayReason?: string) {
    // Patch 3.2 item 2 — a Conflict is never auto-resolved: the user must
    // explicitly reload (which re-fetches the current row_version) before
    // Save is attempted again with the same payload.
    if (versionConflict) return;

    startTransition(async () => {
      const result = isEdit
        ? await updateSalesOrderAction({ order_id: existingOrder!.id, row_version: existingOrder!.row_version, ...buildPayload(closedDayReason) })
        : await createSalesOrderAction({ store_id: storeId, sale_date: saleDate, ...buildPayload(closedDayReason) });

      if (result.success) {
        toast.success(result.message ?? "تم الحفظ بنجاح");
        setPendingCloseReason(false);
        router.push(`${ROUTES.sales}/${result.data.id}`);
        return;
      }

      if (!closedDayReason && isClosedDayError(result.error)) {
        setPendingCloseReason(true);
        return;
      }

      // Patch 3.2 item 2 — a stale row_version: show the exact Arabic
      // Conflict message and require a reload, never a silent resubmit of
      // the same payload (see the `if (versionConflict) return;` guard
      // above and the banner/reload button rendered below).
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

  const dayClosedNotice = existingOrder?.is_day_closed;

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      {dayClosedNotice && (
        <div className="rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-warning-foreground">
          هذا اليوم مغلق لهذا المتجر — سيُطلب منك سبب لحفظ أي تعديل.
        </div>
      )}

      {versionConflict && (
        <div className="flex flex-col gap-2 rounded-lg border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive sm:flex-row sm:items-center sm:justify-between">
          <span>تم تعديل عملية البيع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الحفظ.</span>
          <Button type="button" variant="outline" size="sm" onClick={() => router.refresh()}>
            تحديث الصفحة
          </Button>
        </div>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">بيانات العملية</CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div className="flex flex-col gap-1.5">
            <Label>المتجر</Label>
            <Select value={storeId} onValueChange={setStoreId} disabled={isPending || isEdit}>
              <SelectTrigger autoFocus={!isEdit}>
                <SelectValue placeholder="اختر المتجر" />
              </SelectTrigger>
              <SelectContent>
                {storeOptions.map((s) => (
                  <SelectItem key={s.id} value={s.id}>
                    {s.name_ar}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>تاريخ البيع</Label>
            <Input type="date" value={saleDate} onChange={(e) => setSaleDate(e.target.value)} disabled={isPending || isEdit} required dir="ltr" />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>طريقة الدفع</Label>
            <Select value={paymentMethodId} onValueChange={setPaymentMethodId} disabled={isPending}>
              <SelectTrigger>
                <SelectValue placeholder="اختر طريقة الدفع" />
              </SelectTrigger>
              <SelectContent>
                {paymentMethodOptions.map((m) => (
                  <SelectItem key={m.id} value={m.id}>
                    {optionLabel(m)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>قناة التحصيل</Label>
            <Select value={collectionChannelId} onValueChange={setCollectionChannelId} disabled={isPending}>
              <SelectTrigger>
                <SelectValue placeholder="اختر قناة التحصيل" />
              </SelectTrigger>
              <SelectContent>
                {collectionChannelOptions.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {optionLabel(c)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>اسم العميل (اختياري)</Label>
            <Input value={customerName} onChange={(e) => setCustomerName(e.target.value)} disabled={isPending} />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label>جوال العميل (اختياري)</Label>
            <Input value={customerPhone} onChange={(e) => setCustomerPhone(e.target.value)} disabled={isPending} dir="ltr" />
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle className="text-base">البنود</CardTitle>
          <Button type="button" variant="outline" size="sm" onClick={addItem} disabled={isPending}>
            <Plus className="size-4" />
            إضافة بند
          </Button>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-0 sm:p-4">
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-12">#</TableHead>
                  <TableHead>التصنيف</TableHead>
                  <TableHead>العيار</TableHead>
                  <TableHead className="w-28">الوزن (جم)</TableHead>
                  <TableHead className="w-32">سعر البيع</TableHead>
                  {canViewProfit && <TableHead className="w-28">التكلفة</TableHead>}
                  {canViewProfit && <TableHead className="w-28">الربح</TableHead>}
                  <TableHead className="w-10"></TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {items.map((item, idx) => {
                  const previewItem = preview?.items?.[idx];
                  return (
                    <TableRow key={item.key}>
                      <TableCell className="text-xs text-muted-foreground">{idx + 1}</TableCell>
                      <TableCell className="min-w-40">
                        <Select value={item.category_id} onValueChange={(v) => updateItem(item.key, { category_id: v })} disabled={isPending}>
                          <SelectTrigger className="h-9">
                            <SelectValue placeholder="التصنيف" />
                          </SelectTrigger>
                          <SelectContent>
                            {categoryOptions.map((c) => (
                              <SelectItem key={c.id} value={c.id}>
                                {optionLabel(c)}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </TableCell>
                      <TableCell className="min-w-32">
                        <Select value={item.karat_id} onValueChange={(v) => updateItem(item.key, { karat_id: v })} disabled={isPending}>
                          <SelectTrigger className="h-9">
                            <SelectValue placeholder="العيار" />
                          </SelectTrigger>
                          <SelectContent>
                            {karatOptions.map((k) => (
                              <SelectItem key={k.id} value={k.id}>
                                {optionLabel(k)}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </TableCell>
                      <TableCell>
                        <Input
                          type="number"
                          step="0.0001"
                          min="0"
                          dir="ltr"
                          className="h-9"
                          value={item.weight_grams}
                          onChange={(e) => updateItem(item.key, { weight_grams: e.target.value })}
                          disabled={isPending}
                        />
                      </TableCell>
                      <TableCell>
                        <Input
                          type="number"
                          step="0.01"
                          min="0"
                          dir="ltr"
                          className="h-9"
                          value={item.sale_price}
                          onChange={(e) => updateItem(item.key, { sale_price: e.target.value })}
                          disabled={isPending}
                        />
                      </TableCell>
                      {canViewProfit && (
                        <TableCell className="text-sm text-muted-foreground" dir="ltr">
                          {previewItem?.total_cost ?? "—"}
                        </TableCell>
                      )}
                      {canViewProfit && (
                        <TableCell className="text-sm font-medium" dir="ltr">
                          {previewItem?.gross_profit ?? "—"}
                        </TableCell>
                      )}
                      <TableCell>
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          className="size-8 text-destructive"
                          onClick={() => removeItem(item.key)}
                          disabled={isPending || items.length <= 1}
                        >
                          <Trash2 className="size-4" />
                        </Button>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          </div>
        </CardContent>
      </Card>

      <div className="flex flex-col gap-1.5">
        <Label>ملاحظات (اختياري)</Label>
        <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} disabled={isPending} rows={2} />
      </div>

      <Card>
        <CardContent className="flex flex-col gap-2 pt-6 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex flex-col gap-1">
            <span className="text-sm text-muted-foreground">إجمالي العملية</span>
            <span className="text-2xl font-bold" dir="ltr">
              {(preview?.subtotal ?? toFixedString(subtotal)) + " ر.س"}
            </span>
          </div>
          {canViewProfit && preview && (
            <div className="grid grid-cols-3 gap-4 text-sm">
              <div>
                <div className="text-muted-foreground">الربح الإجمالي</div>
                <div className="font-medium" dir="ltr">
                  {preview.gross_profit ?? "—"}
                </div>
              </div>
              <div>
                <div className="text-muted-foreground">عمولة الدفع</div>
                <div className="font-medium" dir="ltr">
                  {preview.payment_fee_amount ?? "—"}
                </div>
              </div>
              <div>
                <div className="text-muted-foreground">صافي ربح المبيعات</div>
                <div className="font-medium" dir="ltr">
                  {preview.net_sales_profit ?? "—"}
                </div>
              </div>
            </div>
          )}
          <Button type="submit" variant="accent" size="lg" disabled={isPending}>
            {isPending && <Loader2 className="size-4 animate-spin" />}
            حفظ عملية البيع
          </Button>
        </CardContent>
      </Card>

      <ClosedDayReasonDialog
        open={pendingCloseReason}
        onOpenChange={setPendingCloseReason}
        isPending={isPending}
        onConfirm={(reason) => submit(reason)}
      />
    </form>
  );
}

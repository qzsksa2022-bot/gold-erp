import Link from "next/link";
import { notFound } from "next/navigation";
import { Pencil, Undo2, Wrench, Plus } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getSalesOrderDetail } from "@/features/sales/queries";
import { getAdjustmentSummaryForOrder, listAdjustmentsForOrder } from "@/features/adjustments/queries";
import { ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR } from "@/features/adjustments/schema";
import { PageHeader } from "@/components/shared/page-header";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Can } from "@/lib/permissions/context";
import { formatRiyadhDate, formatRiyadhDateTime } from "@/lib/date";
import { ROUTES } from "@/lib/constants";

type ItemDetail = {
  id: string;
  line_no: number;
  category_name_ar_snapshot: string;
  karat_name_ar_snapshot: string;
  weight_grams: string;
  sale_price: string;
  description: string | null;
  total_cost?: string;
  gross_profit?: string;
};

type OrderDetail = {
  id: string;
  order_number: string;
  store_id: string;
  // Resolved server-side by get_sales_order() -- salesperson_name since
  // migration 0070, store_name/payment_method_name/collection_channel_name
  // since 0079 (Patch 3.2 item 8) -- read these directly rather than
  // querying stores/profiles/payment_methods/collection_channels, which
  // would require the caller to hold those tables' own `.view` permission
  // (spec item 11 / item 8).
  store_name: string | null;
  sale_date: string;
  sold_at: string;
  salesperson_id: string;
  salesperson_name: string | null;
  payment_method_id: string;
  payment_method_name: string | null;
  collection_channel_id: string;
  collection_channel_name: string | null;
  customer_name: string | null;
  customer_phone: string | null;
  notes: string | null;
  subtotal: string;
  is_day_closed: boolean;
  created_at: string;
  items: ItemDetail[];
  gross_profit?: string;
  payment_fee_amount?: string;
  net_sales_profit?: string;
};

export default async function SaleDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const session = await requirePermission("sales.view");
  const { id } = await params;

  let order: OrderDetail;
  try {
    order = (await getSalesOrderDetail(id)) as unknown as OrderDetail;
  } catch {
    notFound();
  }

  const canViewProfit = order.gross_profit !== undefined;

  // Phase 6 (§2/§40/§41) — الخدمات والتعديلات: fully independent from this
  // page's own Returns/Shipping-agnostic profit block above. The summary
  // widget (Original Invoice + Effective Approved Adjustments = Total
  // Including Adjustments) is gated on adjustments.view OR sales.view
  // server-side (0142), so it always resolves here; the per-record list
  // additionally needs adjustments.view.
  const canViewAdjustments = session.isSuperAdmin || sessionHasPermission(session, "adjustments.view");
  const [adjustmentSummary, adjustments] = await Promise.all([
    getAdjustmentSummaryForOrder(id),
    canViewAdjustments ? listAdjustmentsForOrder(id) : Promise.resolve([]),
  ]);

  return (
    <div>
      <PageHeader
        title={order.order_number}
        description={`${formatRiyadhDate(order.sale_date)} — ${order.store_name ?? "—"}`}
        actions={
          <div className="flex items-center gap-2">
            <Can permission="adjustments.create">
              <Button asChild variant="outline">
                <Link href={`${ROUTES.adjustmentsNew}?sales_order_id=${order.id}&order_number=${encodeURIComponent(order.order_number)}`}>
                  <Wrench className="size-4" />
                  تعديل/خدمة جديد
                </Link>
              </Button>
            </Can>
            <Can permission="returns.create">
              <Button asChild variant="outline">
                <Link href={`${ROUTES.returnsNew}?sales_order_id=${order.id}`}>
                  <Undo2 className="size-4" />
                  بدء مرتجع
                </Link>
              </Button>
            </Can>
            <Can permission="sales.edit">
              <Button asChild variant="outline">
                <Link href={`${ROUTES.sales}/${order.id}/edit`}>
                  <Pencil className="size-4" />
                  تعديل
                </Link>
              </Button>
            </Can>
          </div>
        }
      />

      {order.is_day_closed && (
        <div className="mb-4">
          <Badge variant="warning">اليوم مغلق</Badge>
        </div>
      )}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader>
            <CardTitle className="text-base">البنود</CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-10">#</TableHead>
                  <TableHead>التصنيف</TableHead>
                  <TableHead>العيار</TableHead>
                  <TableHead>الوزن</TableHead>
                  <TableHead>سعر البيع</TableHead>
                  {canViewProfit && <TableHead>التكلفة</TableHead>}
                  {canViewProfit && <TableHead>الربح</TableHead>}
                </TableRow>
              </TableHeader>
              <TableBody>
                {order.items.map((item) => (
                  <TableRow key={item.id}>
                    <TableCell className="text-xs text-muted-foreground">{item.line_no}</TableCell>
                    <TableCell>{item.category_name_ar_snapshot}</TableCell>
                    <TableCell>{item.karat_name_ar_snapshot}</TableCell>
                    <TableCell dir="ltr">{item.weight_grams}</TableCell>
                    <TableCell className="font-medium" dir="ltr">
                      {item.sale_price}
                    </TableCell>
                    {canViewProfit && (
                      <TableCell dir="ltr" className="text-muted-foreground">
                        {item.total_cost ?? "—"}
                      </TableCell>
                    )}
                    {canViewProfit && (
                      <TableCell dir="ltr" className="font-medium">
                        {item.gross_profit ?? "—"}
                      </TableCell>
                    )}
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>

        <div className="flex flex-col gap-4">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">بيانات العملية</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-2 text-sm">
              <Row label="الموظف" value={order.salesperson_name ?? "—"} />
              <Row label="طريقة الدفع" value={order.payment_method_name ?? "—"} />
              <Row label="قناة التحصيل" value={order.collection_channel_name ?? "—"} />
              <Row label="العميل" value={order.customer_name ?? "—"} />
              <Row label="جوال العميل" value={order.customer_phone ?? "—"} />
              <Row label="تاريخ الإنشاء" value={formatRiyadhDateTime(order.created_at)} />
              {order.notes && <Row label="ملاحظات" value={order.notes} />}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">الملخص المالي</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-2 text-sm">
              <Row label="الإجمالي (Subtotal)" value={order.subtotal} dir="ltr" />
              {canViewProfit && <Row label="الربح الإجمالي" value={order.gross_profit ?? "—"} dir="ltr" />}
              {canViewProfit && <Row label="عمولة الدفع" value={order.payment_fee_amount ?? "—"} dir="ltr" />}
              {canViewProfit && <Row label="صافي ربح المبيعات" value={order.net_sales_profit ?? "—"} dir="ltr" emphasize />}
            </CardContent>
          </Card>

          {/* Phase 6 (§2/§41) — الخدمات والتعديلات: عرض ضيّق ومستقل تمامًا
              عن حساب ربح المبيعات أعلاه. الفاتورة الأصلية لا تتغير أبدًا؛
              هذا فقط مجموع تحصيل العميل للتعديلات المعتمدة غير المعكوسة. */}
          {adjustmentSummary && (
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2 text-base">
                  <Wrench className="size-4" />
                  الخدمات والتعديلات
                </CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-2 text-sm">
                <Row label="الفاتورة الأصلية" value={adjustmentSummary.original_invoice_amount} dir="ltr" />
                <Row label="إجمالي التعديلات المعتمدة الفعّالة" value={adjustmentSummary.approved_effective_adjustments_charge_total} dir="ltr" />
                <Row label="الإجمالي شاملاً التعديلات" value={adjustmentSummary.total_including_adjustments} dir="ltr" emphasize />

                {canViewAdjustments && adjustments.length > 0 && (
                  <div className="mt-2 flex flex-col divide-y divide-border border-t border-border pt-2">
                    {adjustments.map((a) => (
                      <Link key={a.id} href={`${ROUTES.adjustments}/${a.id}`} className="flex items-center justify-between gap-2 py-2 text-xs hover:bg-muted/40">
                        <div className="flex flex-col gap-0.5">
                          <span className="font-mono text-accent" dir="ltr">
                            {a.adjustment_number}
                          </span>
                          <span className="text-muted-foreground">{a.adjustment_type_name_ar}</span>
                        </div>
                        <div className="flex flex-col items-end gap-0.5">
                          <span dir="ltr" className="font-medium">
                            {a.customer_charge}
                          </span>
                          <Badge variant="outline">{ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR[a.effective_status as keyof typeof ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR] ?? a.effective_status}</Badge>
                        </div>
                      </Link>
                    ))}
                  </div>
                )}

                <Can permission="adjustments.create">
                  <Button asChild variant="outline" size="sm" className="mt-1">
                    <Link href={`${ROUTES.adjustmentsNew}?sales_order_id=${order.id}&order_number=${encodeURIComponent(order.order_number)}`}>
                      <Plus className="size-4" />
                      تعديل/خدمة جديد
                    </Link>
                  </Button>
                </Can>
              </CardContent>
            </Card>
          )}
        </div>
      </div>
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

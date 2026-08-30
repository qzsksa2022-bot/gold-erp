import Link from "next/link";
import { notFound } from "next/navigation";
import { Pencil } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getSalesReturnDetail, getReturnsRefundMethodLookups } from "@/features/returns/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Can } from "@/lib/permissions/context";
import { ReturnLifecycleActions } from "@/features/returns/components/return-lifecycle-actions";
import { RefundEventsPanel, type ReconciliationHistoryEvent } from "@/features/returns/components/refund-events-panel";
import {
  RETURN_SCENARIO_LABELS_AR,
  RETURN_STATUS_LABELS_AR,
  COLLECTION_STATE_LABELS_AR,
  RETURN_ITEM_CONDITION_LABELS_AR,
} from "@/features/returns/schema";
import { formatRiyadhDate, formatRiyadhDateTime } from "@/lib/date";
import { ROUTES } from "@/lib/constants";

const STATUS_BADGE_VARIANT: Record<string, "warning" | "success" | "destructive" | "secondary"> = {
  pending: "warning",
  approved: "success",
  rejected: "destructive",
  reversed: "secondary",
};

type ReturnItemDetail = {
  id: string;
  sales_order_item_id: string;
  line_no: number;
  status: "active" | "removed";
  is_effective: boolean;
  condition: string | null;
  item_return_reason: string | null;
  item_notes: string | null;
  category_name_ar_snapshot: string;
  karat_name_ar_snapshot: string;
  weight_grams: string;
  sale_price: string;
  total_cost?: string;
  gross_profit?: string;
};

type RefundEventDetail = {
  id: string;
  amount: string;
  refund_method_id: string;
  // Hotfix 4.2.1 (Sections 6/17, migration 0106/0107/0111).
  refund_method_name_snapshot?: string | null;
  reference?: string | null;
  refund_business_date?: string | null;
  refunded_at: string;
  notes: string | null;
  status: "active" | "reversed";
  reversed_at: string | null;
  reversal_business_date?: string | null;
  reversal_reason: string | null;
};

type ReturnDetail = {
  id: string;
  return_number: string;
  sales_order_id: string;
  order_number: string;
  original_store_id: string;
  original_store_name: string | null;
  sale_date: string;
  processed_store_id: string;
  store_name: string | null;
  return_date: string;
  customer_name: string | null;
  customer_phone: string | null;
  scenario: string;
  scenario_notes: string | null;
  collection_state: string | null;
  status: "pending" | "approved" | "rejected" | "reversed";
  row_version: number;
  payment_method_id: string;
  payment_method_name: string | null;
  source_sale_row_version: number | null;
  // Patch 4.2 (Section 1) — a legacy-upgrade guard, independent from (and
  // stricter than) source_sale_row_version above: true means this Pending
  // return's item snapshots cannot be trusted without an explicit refresh,
  // even though the row_version comparison happens to match. Not profit-
  // gated (0104) so the UI can show it before approval is even attempted.
  requires_sale_refresh: boolean;
  approved_at: string | null;
  rejected_at: string | null;
  rejection_reason: string | null;
  reversed_at: string | null;
  reversal_reason: string | null;
  reversal_business_date: string | null;
  returned_original_sale_amount: string | null;
  non_shipping_deduction_amount: string | null;
  deduction_reason: string | null;
  sales_revenue_reversal_amount: string | null;
  approved_refund_amount: string | null;
  refund_difference_reason: string | null;
  actual_refunded_total: string;
  refund_variance: string;
  refund_reconciliation_state: string;
  refund_finalized_at: string | null;
  refund_finalized_by: string | null;
  refund_final_variance_reason: string | null;
  refund_fee_policy_snapshot: string | null;
  created_at: string;
  updated_at: string;
  items: ReturnItemDetail[];
  refund_events: RefundEventDetail[];
  // Patch 4.2 (Section 4) — full finalize/reopen transition history, oldest
  // first, never profit-gated (0104).
  reconciliation_history: ReconciliationHistoryEvent[];
  recovered_original_cost_amount?: string;
  gross_profit_reversal_amount?: string;
  payment_fee_reversal_amount?: string;
  // Hotfix 4.2.1 (Section 13, migration 0111) — profit-gated, alongside
  // payment_fee_reversal_amount. 1 = old item-value-basis engine; 2 = new
  // approved-refund-amount-basis engine (migration 0109).
  payment_fee_reversal_calculation_version?: number | null;
  net_sales_profit_adjustment?: string;
  adjusted_order_net_sales_profit?: string;
  net_profit_reversal_amount?: string;
};

export default async function ReturnDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const session = await requirePermission("returns.view");
  const { id } = await params;

  let ret: ReturnDetail;
  try {
    ret = (await getSalesReturnDetail(id)) as unknown as ReturnDetail;
  } catch {
    notFound();
  }

  const canViewProfit = ret.gross_profit_reversal_amount !== undefined;
  // Patch 4.2 (Section 7) — refund methods are only fetched (and only
  // requested from the DB, which itself gates on returns.record_refund) when
  // the viewer actually holds that permission. Previously this page called
  // getReturnsFormLookups() unconditionally, which meant a returns.view-only
  // user could fail to load this page at all if they lacked payment_methods.
  // view — now a returns.view-only user simply gets an empty refundMethods
  // list (RecordRefundDialog/FinalizeRefundDialog/ReopenReconciliationDialog
  // are already gated by <Can permission="returns.record_refund"> and won't
  // render for them anyway).
  const refundMethods = sessionHasPermission(session, "returns.record_refund") ? await getReturnsRefundMethodLookups() : [];

  return (
    <div>
      <PageHeader
        title={ret.return_number}
        description={`${formatRiyadhDate(ret.return_date)} — ${ret.store_name ?? "—"} — عملية البيع ${ret.order_number}`}
        actions={
          <div className="flex items-center gap-2">
            {ret.status === "pending" && (
              <Can permission="returns.create">
                <Button asChild variant="outline">
                  <Link href={`${ROUTES.returns}/${ret.id}/edit`}>
                    <Pencil className="size-4" />
                    تعديل
                  </Link>
                </Button>
              </Can>
            )}
            <ReturnLifecycleActions returnId={ret.id} returnNumber={ret.return_number} status={ret.status} rowVersion={ret.row_version} />
          </div>
        }
      />

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <Badge variant={STATUS_BADGE_VARIANT[ret.status] ?? "secondary"}>{RETURN_STATUS_LABELS_AR[ret.status]}</Badge>
        <Badge variant="outline">{RETURN_SCENARIO_LABELS_AR[ret.scenario as keyof typeof RETURN_SCENARIO_LABELS_AR] ?? ret.scenario}</Badge>
      </div>

      {ret.status === "pending" && ret.requires_sale_refresh && (
        <div className="mb-4 rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-warning-foreground">
          بيانات عملية البيع لهذا المرتجع قد تكون قديمة (مرتجع قديم من قبل هذا التحديث) — يجب تحديث بيانات المرتجع من عملية البيع قبل اعتماده.
        </div>
      )}

      {ret.status === "rejected" && ret.rejection_reason && (
        <div className="mb-4 rounded-lg border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive">سبب الرفض: {ret.rejection_reason}</div>
      )}
      {ret.status === "reversed" && ret.reversal_reason && (
        <div className="mb-4 rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-warning-foreground">سبب التراجع: {ret.reversal_reason}</div>
      )}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader>
            <CardTitle className="text-base">البنود المرتجعة</CardTitle>
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
                  <TableHead>حالة القطعة</TableHead>
                  {canViewProfit && <TableHead>التكلفة</TableHead>}
                  {canViewProfit && <TableHead>الربح</TableHead>}
                </TableRow>
              </TableHeader>
              <TableBody>
                {ret.items.map((item) => (
                  <TableRow key={item.id} className={item.status === "removed" ? "opacity-60" : undefined}>
                    <TableCell className="text-xs text-muted-foreground">{item.line_no}</TableCell>
                    <TableCell>{item.category_name_ar_snapshot}</TableCell>
                    <TableCell>{item.karat_name_ar_snapshot}</TableCell>
                    <TableCell dir="ltr">{item.weight_grams}</TableCell>
                    <TableCell className="font-medium" dir="ltr">
                      {item.sale_price}
                    </TableCell>
                    <TableCell className="text-xs">
                      <div className="flex flex-col gap-0.5">
                        <span>{RETURN_ITEM_CONDITION_LABELS_AR[item.condition as keyof typeof RETURN_ITEM_CONDITION_LABELS_AR] ?? item.condition ?? "—"}</span>
                        {item.status === "removed" && <span className="text-muted-foreground">تمت إزالته من القائمة</span>}
                        {item.item_return_reason && <span className="text-muted-foreground">سبب الإرجاع: {item.item_return_reason}</span>}
                        {item.item_notes && <span className="text-muted-foreground">ملاحظات: {item.item_notes}</span>}
                      </div>
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
              <CardTitle className="text-base">بيانات المرتجع</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-2 text-sm">
              <Row label="عملية البيع" value={ret.order_number} dir="ltr" />
              <Row label="متجر البيع الأصلي" value={ret.original_store_name ?? "—"} />
              <Row label="تاريخ البيع" value={formatRiyadhDate(ret.sale_date)} />
              <Row label="طريقة الدفع" value={ret.payment_method_name ?? "—"} />
              <Row label="العميل" value={ret.customer_name ?? "—"} />
              <Row label="جوال العميل" value={ret.customer_phone ?? "—"} />
              <Row label="حالة التحصيل" value={COLLECTION_STATE_LABELS_AR[ret.collection_state as keyof typeof COLLECTION_STATE_LABELS_AR] ?? ret.collection_state ?? "—"} />
              <Row label="تاريخ الإنشاء" value={formatRiyadhDateTime(ret.created_at)} />
              {ret.scenario_notes && <Row label="ملاحظات السيناريو" value={ret.scenario_notes} />}
              {ret.approved_at && <Row label="تاريخ الاعتماد" value={formatRiyadhDateTime(ret.approved_at)} />}
              {ret.reversed_at && <Row label="تاريخ التراجع" value={formatRiyadhDateTime(ret.reversed_at)} />}
              {ret.reversal_business_date && <Row label="تاريخ عملية التراجع" value={formatRiyadhDate(ret.reversal_business_date)} />}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">الملخص المالي</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-2 text-sm">
              <Row label="قيمة البيع الأصلية المرتجعة" value={ret.returned_original_sale_amount ?? "—"} dir="ltr" />
              {ret.non_shipping_deduction_amount && ret.non_shipping_deduction_amount !== "0.00" && (
                <Row label="خصم غير متعلق بالشحن" value={ret.non_shipping_deduction_amount} dir="ltr" />
              )}
              {ret.deduction_reason && <Row label="سبب الخصم" value={ret.deduction_reason} />}
              <Row label="رد المبيعات" value={ret.sales_revenue_reversal_amount ?? "—"} dir="ltr" emphasize />
              {canViewProfit && <Row label="الربح المرتجع" value={ret.gross_profit_reversal_amount ?? "—"} dir="ltr" />}
              {canViewProfit && <Row label="التكلفة الأصلية المستردة" value={ret.recovered_original_cost_amount ?? "—"} dir="ltr" />}
              {canViewProfit && <Row label="استرداد العمولة" value={ret.payment_fee_reversal_amount ?? "—"} dir="ltr" />}
              {canViewProfit && ret.payment_fee_reversal_calculation_version != null && (
                <Row
                  label="إصدار احتساب استرداد العمولة"
                  value={ret.payment_fee_reversal_calculation_version === 2 ? "2 (أساس الاسترداد المعتمد)" : "1 (قديم — أساس قيمة البند)"}
                  dir="ltr"
                />
              )}
              {canViewProfit && <Row label="صافي الربح المرتجع" value={ret.net_profit_reversal_amount ?? "—"} dir="ltr" emphasize />}
              {canViewProfit && <Row label="أثر صافي ربح المرتجع" value={ret.net_sales_profit_adjustment ?? "—"} dir="ltr" />}
              {canViewProfit && <Row label="صافي ربح عملية البيع بعد التعديل" value={ret.adjusted_order_net_sales_profit ?? "—"} dir="ltr" emphasize />}
              {ret.refund_difference_reason && <Row label="سبب فرق الاسترداد" value={ret.refund_difference_reason} />}
              {ret.refund_fee_policy_snapshot && <Row label="سياسة استرداد العمولة" value={ret.refund_fee_policy_snapshot} dir="ltr" />}
            </CardContent>
          </Card>
        </div>
      </div>

      <div className="mt-4">
        <RefundEventsPanel
          returnId={ret.id}
          returnStatus={ret.status}
          rowVersion={ret.row_version}
          refundEvents={ret.refund_events}
          refundMethods={refundMethods}
          approvedRefundAmount={ret.approved_refund_amount}
          actualRefundedTotal={ret.actual_refunded_total}
          refundReconciliationState={ret.refund_reconciliation_state}
          refundFinalizedAt={ret.refund_finalized_at}
          refundFinalVarianceReason={ret.refund_final_variance_reason}
          reconciliationHistory={ret.reconciliation_history}
        />
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

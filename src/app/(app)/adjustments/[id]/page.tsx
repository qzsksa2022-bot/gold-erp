import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/permissions/guard";
import { getAdjustmentDetail } from "@/features/adjustments/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { AdjustmentLifecycleActions } from "@/features/adjustments/components/adjustment-lifecycle-actions";
import { ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR } from "@/features/adjustments/schema";
import { formatRiyadhDate, formatRiyadhDateTime } from "@/lib/date";
import { ROUTES } from "@/lib/constants";

const STATUS_BADGE_VARIANT: Record<string, "warning" | "success" | "destructive" | "secondary"> = {
  pending: "warning",
  approved: "success",
  rejected: "destructive",
  reversed: "secondary",
};

// Patch 6.1 (migration 0151) — get_sales_order_adjustment() v2 shape, v4
// (migration 0160, Hotfix 6.1.1 items 6/7). direct_cost/payment_fee_amount/
// gross_adjustment_profit/net_adjustment_profit no longer exist as flat
// fields — replaced by the original_* (immutable approved snapshot, or —
// for direct_cost ALONE — visible while pending to a manage_cost holder,
// item 3) / effective_* (current financial effect: 0.00 once reversed,
// NULL while pending/rejected, item 19) split. payment_method_id/
// collection_channel_id/payment_reference can now be null (a genuinely free
// service, items 9/10/11). has_direct_cost is a NEW, always-visible
// operational boolean that never discloses the amount. calculation_version
// (Hotfix 6.1.1 item 7) is plain operational metadata, NOT sales.view_
// profit-gated. reversal_*_impact (Hotfix 6.1.1 item 6) are the 5 signed
// reversal-impact figures, sales.view_profit-gated, null when there is no
// reversal — surfaced explicitly below instead of leaving the user to infer
// them from "effective is now 0.00".
type AdjustmentDetail = {
  id: string;
  adjustment_number: string;
  sales_order_id: string;
  order_number: string;
  original_sale_store_id: string;
  original_sale_store_name: string;
  adjustment_type_id: string;
  adjustment_type_code: string;
  adjustment_type_name_ar: string;
  processing_store_id: string;
  processing_store_name: string;
  adjustment_date: string;
  payment_method_id: string | null;
  payment_method_name: string | null;
  collection_channel_id: string | null;
  collection_channel_name: string | null;
  payment_reference: string | null;
  participates_in_settlement: boolean;
  customer_charge: string;
  has_direct_cost: boolean;
  calculation_version: number | null;
  original_direct_cost: string | null;
  original_payment_fee_amount: string | null;
  original_gross_adjustment_profit: string | null;
  original_net_adjustment_profit: string | null;
  effective_customer_charge: string | null;
  effective_direct_cost: string | null;
  effective_payment_fee_amount: string | null;
  effective_gross_adjustment_profit: string | null;
  effective_net_adjustment_profit: string | null;
  reversal_customer_charge_impact: string | null;
  reversal_direct_cost_impact: string | null;
  reversal_payment_fee_impact: string | null;
  reversal_gross_profit_impact: string | null;
  reversal_net_profit_impact: string | null;
  status: string;
  effective_status: string;
  rejection_reason: string | null;
  notes: string | null;
  row_version: number;
  reversal_business_date: string | null;
  reversal_reason: string | null;
  created_at: string;
  approved_at: string | null;
  rejected_at: string | null;
};

export default async function AdjustmentDetailPage({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission("adjustments.view");
  const { id } = await params;

  let adj: AdjustmentDetail;
  try {
    adj = (await getAdjustmentDetail(id)) as unknown as AdjustmentDetail;
  } catch {
    notFound();
  }

  // original_payment_fee_amount is NEVER exposed via the manage_cost
  // pending-cost exception (item 3) — only sales.view_profit reveals it —
  // so its non-null-ness is a reliable signal for "this actor can see the
  // real financial picture", distinct from has_direct_cost/original_direct_
  // cost (which a manage_cost holder sees while pending regardless).
  const canViewProfit = adj.original_payment_fee_amount !== null;
  const canViewCostAmount = adj.original_direct_cost !== null;
  const isFreeService = !adj.payment_method_id;

  return (
    <div>
      <PageHeader
        title={adj.adjustment_number}
        description={`${formatRiyadhDate(adj.adjustment_date)} — ${adj.processing_store_name} — عملية البيع ${adj.order_number}`}
        actions={<AdjustmentLifecycleActions adjustmentId={adj.id} adjustmentNumber={adj.adjustment_number} effectiveStatus={adj.effective_status} rowVersion={adj.row_version} hasDirectCost={adj.has_direct_cost} />}
      />

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <Badge variant={STATUS_BADGE_VARIANT[adj.effective_status] ?? "secondary"}>
          {ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR[adj.effective_status as keyof typeof ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR] ?? adj.effective_status}
        </Badge>
        {isFreeService && <Badge variant="outline">خدمة مجانية</Badge>}
        {!isFreeService && adj.participates_in_settlement && <Badge variant="outline">ضمن التسوية</Badge>}
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="flex flex-col gap-4 lg:col-span-2">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">بيانات التعديل/الخدمة</CardTitle>
            </CardHeader>
            <CardContent className="grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
              <Row label="عملية البيع" value={adj.order_number} dir="ltr" href={`${ROUTES.sales}/${adj.sales_order_id}`} />
              <Row label="متجر عملية البيع الأصلية" value={adj.original_sale_store_name} />
              <Row label="النوع" value={adj.adjustment_type_name_ar} />
              <Row label="المتجر المُعالِج" value={adj.processing_store_name} />
              {isFreeService ? (
                <Row label="طريقة الدفع" value="لا يوجد — خدمة مجانية" />
              ) : (
                <>
                  <Row label="طريقة الدفع" value={adj.payment_method_name ?? "—"} />
                  <Row label="قناة التحصيل" value={adj.collection_channel_name ?? "—"} />
                  {adj.payment_reference && <Row label="مرجع الدفع" value={adj.payment_reference} dir="ltr" />}
                  <Row label="ضمن التسوية" value={adj.participates_in_settlement ? "نعم" : "لا"} />
                </>
              )}
              {adj.notes && <Row label="ملاحظات" value={adj.notes} />}
              {adj.rejection_reason && <Row label="سبب الرفض" value={adj.rejection_reason} />}
              <Row label="تاريخ الإنشاء" value={formatRiyadhDateTime(adj.created_at)} />
              {adj.approved_at && <Row label="تاريخ الاعتماد" value={formatRiyadhDateTime(adj.approved_at)} />}
              {adj.rejected_at && <Row label="تاريخ الرفض" value={formatRiyadhDateTime(adj.rejected_at)} />}
              {/* Hotfix 6.1.1 item 7 — operational metadata only, never a money figure; not profit-gated. */}
              {adj.calculation_version !== null && <Row label="نسخة محرك الحساب" value={String(adj.calculation_version)} dir="ltr" />}
            </CardContent>
          </Card>

          {adj.effective_status === "reversed" && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">العكس الإداري</CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-2 text-sm">
                <p className="text-xs text-muted-foreground">
                  هذا سجل تصحيح إداري — وليس استرداد للعميل. القيم المالية الأصلية أعلاه تبقى محفوظة كما اعتُمدت في {formatRiyadhDate(adj.adjustment_date)}؛ أثر العكس مسجَّل بتاريخ منفصل أدناه، وأصبح الأثر المالي الحالي صفرًا.
                </p>
                <Row label="تاريخ العكس" value={adj.reversal_business_date ? formatRiyadhDate(adj.reversal_business_date) : "—"} />
                {adj.reversal_reason && <Row label="سبب العكس" value={adj.reversal_reason} />}
              </CardContent>
            </Card>
          )}
        </div>

        <div className="flex flex-col gap-4">
          {/* Customer-facing charge — never profit-gated (§29, same precedent as Shipping's customer_shipping_charge). */}
          <Card>
            <CardHeader>
              <CardTitle className="text-base">تحصيل العميل</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-2 text-sm">
              <Row label="قيمة تحصيل العميل" value={adj.customer_charge} dir="ltr" emphasize />
              <Row label="يحمل تكلفة مباشرة" value={adj.has_direct_cost ? "نعم" : "لا"} />
            </CardContent>
          </Card>

          {(canViewProfit || canViewCostAmount) && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">اللقطة الأصلية عند الاعتماد (منفصلة عن ربح المبيعات)</CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-2 text-sm">
                <Row label="التكلفة المباشرة" value={adj.original_direct_cost ?? "لم تُدخَل بعد"} dir="ltr" />
                {canViewProfit && (
                  <>
                    <Row label="عمولة الدفع" value={adj.original_payment_fee_amount ?? "—"} dir="ltr" />
                    <Row label="الربح الإجمالي" value={adj.original_gross_adjustment_profit ?? "—"} dir="ltr" />
                    <Row label="صافي الربح" value={adj.original_net_adjustment_profit ?? "—"} dir="ltr" emphasize />
                  </>
                )}
              </CardContent>
            </Card>
          )}

          {canViewProfit && adj.status === "approved" && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">الأثر المالي الحالي (الفعلي)</CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-2 text-sm">
                <p className="text-xs text-muted-foreground">{adj.effective_status === "reversed" ? "صفر — تم عكس هذا السجل إداريًا." : "لا يزال هذا السجل ساري الأثر المالي كما اعتُمد."}</p>
                <Row label="صافي الربح الفعلي" value={adj.effective_net_adjustment_profit ?? "—"} dir="ltr" emphasize />
              </CardContent>
            </Card>
          )}

          {/* Hotfix 6.1.1 item 6 — a reversed record's financial story must
              never be left for the user to infer from "effective is now
              0.00". This card makes the arithmetic explicit: the original
              approved figure, the signed reversal impact that cancelled it
              out, and the resulting (always-zero) effective figure. */}
          {canViewProfit && adj.effective_status === "reversed" && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">أثر العكس المالي</CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-2 text-sm">
                <Row label="صافي الربح الأصلي" value={adj.original_net_adjustment_profit ?? "—"} dir="ltr" />
                <Row label="أثر العكس على صافي الربح" value={adj.reversal_net_profit_impact ?? "—"} dir="ltr" />
                <Row label="صافي الربح الفعلي بعد العكس" value={adj.effective_net_adjustment_profit ?? "—"} dir="ltr" emphasize />
                <div className="my-1 border-t border-border" />
                <Row label="التكلفة المباشرة (أصلي / أثر العكس)" value={`${adj.original_direct_cost ?? "—"} / ${adj.reversal_direct_cost_impact ?? "—"}`} dir="ltr" />
                <Row label="عمولة الدفع (أصلي / أثر العكس)" value={`${adj.original_payment_fee_amount ?? "—"} / ${adj.reversal_payment_fee_impact ?? "—"}`} dir="ltr" />
                <Row label="الربح الإجمالي (أصلي / أثر العكس)" value={`${adj.original_gross_adjustment_profit ?? "—"} / ${adj.reversal_gross_profit_impact ?? "—"}`} dir="ltr" />
              </CardContent>
            </Card>
          )}
        </div>
      </div>
    </div>
  );
}

function Row({ label, value, dir, emphasize, href }: { label: string; value: string; dir?: "ltr" | "rtl"; emphasize?: boolean; href?: string }) {
  return (
    <div className="flex items-center justify-between gap-2">
      <span className="text-muted-foreground">{label}</span>
      {href ? (
        <Link href={href} className={`text-accent hover:underline ${emphasize ? "font-bold" : "font-medium"}`} dir={dir}>
          {value}
        </Link>
      ) : (
        <span className={emphasize ? "font-bold" : "font-medium"} dir={dir}>
          {value}
        </span>
      )}
    </div>
  );
}

import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/permissions/guard";
import { getShipmentDetail } from "@/features/shipping/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { ShipmentStatusActions } from "@/features/shipping/components/shipment-status-actions";
import { ShipmentFinancialActions } from "@/features/shipping/components/shipment-financial-actions";
import { ShipmentCodStateAction } from "@/features/shipping/components/shipment-cod-state-action";
import { SHIPMENT_STATUS_LABELS_AR, SHIPMENT_DIRECTION_LABELS_AR, SHIPMENT_FULFILLMENT_TYPE_LABELS_AR, COD_COLLECTION_STATE_LABELS_AR } from "@/features/shipping/schema";
import { formatRiyadhDate, formatRiyadhDateTime } from "@/lib/date";

const STATUS_BADGE_VARIANT: Record<string, "warning" | "success" | "destructive" | "secondary"> = {
  created: "secondary",
  ready_for_pickup: "secondary",
  picked_up: "warning",
  in_transit: "warning",
  out_for_delivery: "warning",
  delivered: "success",
  delivery_failed: "destructive",
  customer_refused: "destructive",
  customer_never_received: "destructive",
  returned_to_store: "secondary",
  cancelled: "destructive",
};

type StatusEvent = {
  id: string;
  status: string;
  event_business_date: string;
  event_at: string;
  notes: string | null;
  is_correction: boolean;
  external_reference: string | null;
  created_at: string;
};

type CodEvent = {
  id: string;
  state: string;
  business_date: string;
  reference: string | null;
  reason: string | null;
  created_at: string;
};

type FinancialEvent = {
  id: string;
  event_type: "actual_cost_recorded" | "actual_cost_correction" | "customer_charge_correction";
  amount: string;
  business_date: string;
  reference: string | null;
  reason: string | null;
  created_at: string;
};

type ShipmentDetail = {
  id: string;
  shipment_number: string;
  sales_order_id: string;
  order_number: string | null;
  sales_return_id: string | null;
  return_number: string | null;
  store_id: string;
  store_name: string | null;
  original_sale_store_id?: string | null;
  original_sale_store_name?: string | null;
  carrier_id: string;
  carrier_code: string | null;
  carrier_name: string | null;
  shipping_zone_id: string;
  zone_code: string | null;
  zone_name: string | null;
  direction: "outbound" | "return";
  fulfillment_type: string;
  tracking_number: string | null;
  external_reference: string | null;
  customer_name: string | null;
  customer_phone: string | null;
  recipient_address: string | null;
  shipment_date: string;
  is_cod: boolean;
  cod_collection_state: string;
  cod_timeline: CodEvent[];
  current_status: string;
  notes: string | null;
  row_version: number;
  created_at: string;
  updated_at: string;
  status_timeline: StatusEvent[];
  // Always visible (Patch 5.1 item 10/23) — never profit-gated.
  customer_shipping_charge: string;
  effective_customer_shipping_charge: string;
  has_actual_carrier_cost: boolean;
  customer_return_shipping_fee_version_id?: string | null;
  customer_return_shipping_fee_standard_amount?: string | null;
  customer_return_shipping_charge_is_override?: boolean;
  customer_return_shipping_charge_override_reason?: string | null;
  // Profit-gated — entirely absent without sales.view_profit.
  expected_carrier_cost?: string;
  expected_carrier_cost_is_manual?: boolean;
  expected_carrier_cost_manual_reason?: string | null;
  actual_carrier_cost?: string | null;
  net_shipping_expected?: string;
  net_shipping_actual?: string | null;
  cod_expected_amount?: string | null;
  financial_events?: FinancialEvent[];
};

const FINANCIAL_EVENT_LABELS_AR: Record<string, string> = {
  actual_cost_recorded: "تسجيل التكلفة الفعلية",
  actual_cost_correction: "تصحيح التكلفة الفعلية",
  customer_charge_correction: "تصحيح رسوم الشحن على العميل",
};

export default async function ShipmentDetailPage({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission("shipments.view");
  const { id } = await params;

  let shipment: ShipmentDetail;
  try {
    shipment = (await getShipmentDetail(id)) as unknown as ShipmentDetail;
  } catch {
    notFound();
  }

  const canViewProfit = shipment.net_shipping_expected !== undefined;
  // Patch 5.1 item 23 — the operational fact comes from the DB directly
  // now (has_actual_carrier_cost is always present), never inferred from
  // the profit-gated actual_carrier_cost value (which is always absent for
  // a shipments.manage_cost actor without sales.view_profit, and would
  // otherwise always read as "no cost recorded" regardless of reality).
  const hasActualCost = shipment.has_actual_carrier_cost;

  return (
    <div>
      <PageHeader
        title={shipment.shipment_number}
        description={`${formatRiyadhDate(shipment.shipment_date)} — ${shipment.store_name ?? "—"} — عملية البيع ${shipment.order_number ?? "—"}`}
        actions={<ShipmentStatusActions shipmentId={shipment.id} currentStatus={shipment.current_status} rowVersion={shipment.row_version} />}
      />

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <Badge variant={STATUS_BADGE_VARIANT[shipment.current_status] ?? "secondary"}>
          {SHIPMENT_STATUS_LABELS_AR[shipment.current_status as keyof typeof SHIPMENT_STATUS_LABELS_AR] ?? shipment.current_status}
        </Badge>
        <Badge variant="outline">{SHIPMENT_DIRECTION_LABELS_AR[shipment.direction]}</Badge>
        {shipment.is_cod && <Badge variant="outline">دفع عند الاستلام (COD) — {COD_COLLECTION_STATE_LABELS_AR[shipment.cod_collection_state as keyof typeof COD_COLLECTION_STATE_LABELS_AR] ?? shipment.cod_collection_state}</Badge>}
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="flex flex-col gap-4 lg:col-span-2">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">بيانات الشحنة</CardTitle>
            </CardHeader>
            <CardContent className="grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
              <Row label="عملية البيع" value={shipment.order_number ?? "—"} dir="ltr" />
              {shipment.return_number && <Row label="المرتجع المرتبط" value={shipment.return_number} dir="ltr" />}
              <Row label="المتجر المعالِج للشحنة" value={shipment.store_name ?? "—"} />
              {shipment.original_sale_store_name && shipment.original_sale_store_id !== shipment.store_id && (
                <Row label="متجر عملية البيع الأصلية" value={shipment.original_sale_store_name} />
              )}
              <Row label="شركة الشحن" value={shipment.carrier_name ?? "—"} />
              <Row label="المنطقة" value={shipment.zone_name ?? "—"} />
              <Row label="نوع التنفيذ" value={SHIPMENT_FULFILLMENT_TYPE_LABELS_AR[shipment.fulfillment_type as keyof typeof SHIPMENT_FULFILLMENT_TYPE_LABELS_AR] ?? shipment.fulfillment_type} />
              <Row label="رقم التتبع" value={shipment.tracking_number ?? "—"} dir="ltr" />
              <Row label="مرجع خارجي" value={shipment.external_reference ?? "—"} dir="ltr" />
              <Row label="العميل" value={shipment.customer_name ?? "—"} />
              <Row label="هاتف العميل" value={shipment.customer_phone ?? "—"} dir="ltr" />
              {shipment.recipient_address && <Row label="عنوان الاستلام" value={shipment.recipient_address} />}
              {shipment.notes && <Row label="ملاحظات" value={shipment.notes} />}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">السجل الزمني للحالة</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-3">
              {shipment.status_timeline.map((event) => (
                <div key={event.id} className="flex items-start justify-between gap-3 border-b border-border pb-3 last:border-0 last:pb-0">
                  <div className="flex flex-col gap-0.5">
                    <div className="flex items-center gap-2">
                      <span className="text-sm font-medium">{SHIPMENT_STATUS_LABELS_AR[event.status as keyof typeof SHIPMENT_STATUS_LABELS_AR] ?? event.status}</span>
                      {event.is_correction && <Badge variant="outline">تصحيح</Badge>}
                    </div>
                    {event.notes && <span className="text-xs text-muted-foreground">{event.notes}</span>}
                  </div>
                  <div className="flex flex-col items-end gap-0.5 text-xs text-muted-foreground">
                    <span>{formatRiyadhDate(event.event_business_date)}</span>
                    <span dir="ltr">{formatRiyadhDateTime(event.created_at)}</span>
                  </div>
                </div>
              ))}
            </CardContent>
          </Card>

          {canViewProfit && shipment.financial_events && shipment.financial_events.length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">السجل المالي (تكلفة فعلية / تصحيحات)</CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-3">
                {shipment.financial_events.map((event) => (
                  <div key={event.id} className="flex items-start justify-between gap-3 border-b border-border pb-3 last:border-0 last:pb-0">
                    <div className="flex flex-col gap-0.5">
                      <span className="text-sm font-medium">{FINANCIAL_EVENT_LABELS_AR[event.event_type] ?? event.event_type}</span>
                      {event.reason && <span className="text-xs text-muted-foreground">السبب: {event.reason}</span>}
                      {event.reference && <span className="text-xs text-muted-foreground">مرجع: {event.reference}</span>}
                    </div>
                    <div className="flex flex-col items-end gap-0.5 text-xs">
                      <span className="font-medium" dir="ltr">
                        {event.amount}
                      </span>
                      <span className="text-muted-foreground">{formatRiyadhDate(event.business_date)}</span>
                    </div>
                  </div>
                ))}
              </CardContent>
            </Card>
          )}
        </div>

        <div className="flex flex-col gap-4">
          {/* Patch 5.1 item 10 — customer_shipping_charge is NEVER
              profit-secret; visible to any shipments.view actor. */}
          <Card>
            <CardHeader>
              <CardTitle className="text-base">رسوم الشحن على العميل</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-col gap-2 text-sm">
              <Row label="رسوم الشحن على العميل (عند الإنشاء)" value={shipment.customer_shipping_charge} dir="ltr" />
              {shipment.effective_customer_shipping_charge !== shipment.customer_shipping_charge && (
                <Row label="رسوم الشحن الحالية (بعد التصحيح)" value={shipment.effective_customer_shipping_charge} dir="ltr" emphasize />
              )}
              {shipment.direction === "return" && (
                <>
                  <Row
                    label="الرسوم القياسية المعتمدة للمنطقة وقت الإنشاء"
                    value={shipment.customer_return_shipping_fee_standard_amount ?? "لا يوجد إعداد معتمد"}
                    dir="ltr"
                  />
                  <Row label="تجاوز الرسوم القياسية" value={shipment.customer_return_shipping_charge_is_override ? "نعم" : "لا"} />
                  {shipment.customer_return_shipping_charge_is_override && shipment.customer_return_shipping_charge_override_reason && (
                    <Row label="سبب التجاوز" value={shipment.customer_return_shipping_charge_override_reason} />
                  )}
                </>
              )}
            </CardContent>
          </Card>

          {canViewProfit && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">الملخص المالي للشحن (منفصل عن ربح المبيعات)</CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-2 text-sm">
                <Row label="التكلفة المتوقعة لشركة الشحن" value={shipment.expected_carrier_cost ?? "—"} dir="ltr" />
                {shipment.expected_carrier_cost_is_manual && <Row label="سبب الإدخال اليدوي" value={shipment.expected_carrier_cost_manual_reason ?? "—"} />}
                <Row label="صافي الشحن المتوقع" value={shipment.net_shipping_expected ?? "—"} dir="ltr" emphasize />
                <Row label="التكلفة الفعلية لشركة الشحن" value={shipment.actual_carrier_cost ?? "لم تُسجَّل بعد"} dir="ltr" />
                <Row label="صافي الشحن الفعلي" value={shipment.net_shipping_actual ?? "—"} dir="ltr" emphasize />
                {shipment.is_cod && <Row label="المبلغ المتوقع تحصيله (COD)" value={shipment.cod_expected_amount ?? "—"} dir="ltr" />}
              </CardContent>
            </Card>
          )}

          <Card>
            <CardHeader>
              <CardTitle className="text-base">إجراءات مالية</CardTitle>
            </CardHeader>
            <CardContent>
              <ShipmentFinancialActions
                shipmentId={shipment.id}
                rowVersion={shipment.row_version}
                hasActualCost={hasActualCost}
                currentActualCost={shipment.actual_carrier_cost ?? null}
                currentCustomerCharge={shipment.effective_customer_shipping_charge ?? shipment.customer_shipping_charge}
              />
            </CardContent>
          </Card>

          {/* Patch 5.1 item 13/14/27 — COD collection-state workflow, purely
              operational (never profit-gated). */}
          {shipment.is_cod && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">تحصيل الدفع عند الاستلام (COD)</CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-3">
                <ShipmentCodStateAction
                  shipmentId={shipment.id}
                  rowVersion={shipment.row_version}
                  currentState={shipment.cod_collection_state}
                  suggestedNotCollected={["customer_never_received", "returned_to_store"].includes(shipment.current_status)}
                />
                {shipment.cod_timeline.length > 0 && (
                  <div className="flex flex-col gap-2 border-t border-border pt-3">
                    {shipment.cod_timeline.map((event) => (
                      <div key={event.id} className="flex items-start justify-between gap-3 text-xs">
                        <div className="flex flex-col gap-0.5">
                          <span className="font-medium">{COD_COLLECTION_STATE_LABELS_AR[event.state as keyof typeof COD_COLLECTION_STATE_LABELS_AR] ?? event.state}</span>
                          {event.reason && <span className="text-muted-foreground">{event.reason}</span>}
                          {event.reference && (
                            <span dir="ltr" className="text-muted-foreground">
                              {event.reference}
                            </span>
                          )}
                        </div>
                        <span className="text-muted-foreground">{formatRiyadhDate(event.business_date)}</span>
                      </div>
                    ))}
                  </div>
                )}
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

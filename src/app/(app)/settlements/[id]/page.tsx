import { notFound } from "next/navigation";
import { requireAnyPermission } from "@/lib/permissions/guard";
import { getSettlementBatchDetail, getDraftSettlementBatchForEdit, getSettlementRouteLookups, getSettlementCreateStoreLookups } from "@/features/settlements/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { SettlementDraftWorkspace } from "@/features/settlements/components/settlement-draft-workspace";
import { SettlementBankMovementsPanel } from "@/features/settlements/components/settlement-bank-movements-panel";
import { SettlementLifecycleActions } from "@/features/settlements/components/settlement-lifecycle-actions";
import { SETTLEMENT_BATCH_STATUS_LABELS_AR, SOURCE_KIND_LABELS_AR } from "@/features/settlements/schema";
import { formatRiyadhDate, formatRiyadhDateTime } from "@/lib/date";

const STATUS_BADGE_VARIANT: Record<string, "warning" | "success" | "destructive" | "secondary" | "accent"> = {
  draft: "secondary",
  finalized: "accent",
  reconciled: "success",
  cancelled: "destructive",
};

type SettlementBatchLine = {
  id: string;
  source_kind: string;
  source_number: string;
  source_business_date: string;
  primary_store_name: string;
  secondary_store_name: string | null;
  gross_collection_impact: string;
  provider_fee_impact: string;
  expected_settlement_impact: string;
  provider_fee_source: string;
};

type BankMovement = {
  id: string;
  movement_business_date: string;
  amount: string;
  bank_reference: string | null;
  notes: string | null;
  reversed: boolean;
  reversal_amount_impact: string | null;
};

export default async function SettlementBatchDetailPage({ params }: { params: Promise<{ id: string }> }) {
  // Patch 7.1 §7 (migration 0186) — a settlements.create-only actor (no
  // settlements.view) can reach ONLY their own draft, via the narrow
  // get_draft_settlement_batch_for_edit() getter below; a settlements.view
  // holder can reach any batch (draft or not) as before via
  // get_settlement_batch().
  const session = await requireAnyPermission(["settlements.view", "settlements.create"]);
  const { id } = await params;
  const hasView = session.isSuperAdmin || session.permissions.has("settlements.view");

  if (!hasView) {
    let draft: Awaited<ReturnType<typeof getDraftSettlementBatchForEdit>>;
    try {
      draft = await getDraftSettlementBatchForEdit(id);
    } catch {
      notFound();
    }

    const [routes, stores] = await Promise.all([getSettlementRouteLookups(), getSettlementCreateStoreLookups()]);

    return (
      <div>
        <PageHeader title={draft.settlement_number} description={`مسودة — ${draft.route_name_ar}`} actions={<Badge variant="secondary">{SETTLEMENT_BATCH_STATUS_LABELS_AR.draft}</Badge>} />
        <SettlementDraftWorkspace
          batch={{
            id: draft.id,
            settlement_number: draft.settlement_number,
            settlement_route_id: draft.settlement_route_id,
            route_kind: draft.route_kind,
            settlement_date: draft.settlement_date,
            provider_statement_reference: draft.provider_statement_reference,
            notes: draft.notes,
            row_version: draft.row_version,
          }}
          routes={routes}
          stores={stores}
        />
      </div>
    );
  }

  let batch: Awaited<ReturnType<typeof getSettlementBatchDetail>>;
  try {
    batch = await getSettlementBatchDetail(id);
  } catch {
    notFound();
  }

  const canViewFinancials = session.isSuperAdmin || session.permissions.has("settlements.view_financials");
  const canCreate = session.isSuperAdmin || session.permissions.has("settlements.create");
  const canRecordBankMovement = session.isSuperAdmin || session.permissions.has("settlements.record_bank_movement");

  const statusBadge = (
    <Badge variant={STATUS_BADGE_VARIANT[batch.effective_status] ?? "secondary"}>
      {SETTLEMENT_BATCH_STATUS_LABELS_AR[batch.effective_status as keyof typeof SETTLEMENT_BATCH_STATUS_LABELS_AR] ?? batch.effective_status}
    </Badge>
  );

  if (batch.status === "draft") {
    let routes: Awaited<ReturnType<typeof getSettlementRouteLookups>> = [];
    let stores: Awaited<ReturnType<typeof getSettlementCreateStoreLookups>> = [];
    if (canCreate) {
      [routes, stores] = await Promise.all([getSettlementRouteLookups(), getSettlementCreateStoreLookups()]);
    }

    return (
      <div>
        <PageHeader title={batch.settlement_number} description={`مسودة — ${batch.route_name_ar}`} actions={statusBadge} />
        {canCreate ? (
          <SettlementDraftWorkspace
            batch={{
              id: batch.id,
              settlement_number: batch.settlement_number,
              settlement_route_id: batch.settlement_route_id,
              route_kind: batch.route_kind,
              settlement_date: batch.settlement_date,
              provider_statement_reference: batch.provider_statement_reference,
              notes: batch.notes,
              row_version: batch.row_version,
            }}
            routes={routes}
            stores={stores}
          />
        ) : (
          <p className="text-sm text-muted-foreground">لا تملك صلاحية إكمال هذه المسودة (settlements.create).</p>
        )}
      </div>
    );
  }

  const lines = (batch.lines ?? []) as SettlementBatchLine[];
  const movements = (batch.bank_movements ?? []) as BankMovement[];
  const isCancelled = batch.effective_status === "cancelled";

  return (
    <div>
      <PageHeader
        title={batch.settlement_number}
        description={`${formatRiyadhDate(batch.settlement_date)} — ${batch.route_name_ar}`}
        actions={
          <div className="flex items-center gap-2">
            {statusBadge}
            <SettlementLifecycleActions batchId={batch.id} settlementNumber={batch.settlement_number} effectiveStatus={batch.effective_status} rowVersion={batch.row_version} />
          </div>
        }
      />

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="flex flex-col gap-4 lg:col-span-2">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">بيانات دفعة التسوية</CardTitle>
            </CardHeader>
            <CardContent className="grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
              <Row label="مسار التسوية" value={batch.route_name_ar} />
              {batch.payment_method_name && <Row label="طريقة الدفع" value={batch.payment_method_name} />}
              {batch.collection_channel_name && <Row label="قناة التحصيل" value={batch.collection_channel_name} />}
              {batch.shipping_carrier_name && <Row label="شركة الشحن" value={batch.shipping_carrier_name} />}
              {batch.provider_statement_reference && <Row label="مرجع الكشف" value={batch.provider_statement_reference} dir="ltr" />}
              {batch.notes && <Row label="ملاحظات" value={batch.notes} />}
              {batch.finalized_at && <Row label="تاريخ الاعتماد" value={formatRiyadhDateTime(batch.finalized_at)} />}
              {batch.finalized_by_name && <Row label="اعتمدها" value={batch.finalized_by_name} />}
              {batch.reconciled_at && <Row label="تاريخ المطابقة" value={formatRiyadhDateTime(batch.reconciled_at)} />}
              {batch.reconciled_by_name && <Row label="طابقها" value={batch.reconciled_by_name} />}
              {batch.variance_reason && <Row label="سبب فرق المطابقة" value={batch.variance_reason} />}
              {isCancelled && (
                <>
                  {batch.cancelled_at && <Row label="تاريخ الإلغاء" value={formatRiyadhDateTime(batch.cancelled_at)} />}
                  {batch.cancelled_by_name && <Row label="ألغاها" value={batch.cancelled_by_name} />}
                  {batch.cancellation_reason && <Row label="سبب الإلغاء" value={batch.cancellation_reason} />}
                </>
              )}
              {batch.is_batch_fee_override && batch.override_reason && <Row label="سبب تجاوز رسوم الدفعة" value={batch.override_reason} />}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">سطور الدفعة ({lines.length})</CardTitle>
            </CardHeader>
            <CardContent className="p-0">
              {lines.length === 0 ? (
                <p className="p-4 text-sm text-muted-foreground">{canViewFinancials ? "لا توجد سطور مرئية لك ضمن نطاق متاجرك." : "تفاصيل السطور تتطلب صلاحية عرض الماليات (settlements.view_financials)."}</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>المصدر</TableHead>
                      <TableHead className="hidden sm:table-cell">التاريخ</TableHead>
                      <TableHead className="hidden md:table-cell">المتجر</TableHead>
                      <TableHead>الإجمالي</TableHead>
                      <TableHead>العمولة</TableHead>
                      <TableHead>المتوقع</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {lines.map((line) => (
                      <TableRow key={line.id}>
                        <TableCell className="text-sm">
                          <div className="flex flex-col">
                            <span className="font-mono text-xs text-muted-foreground" dir="ltr">
                              {line.source_number}
                            </span>
                            <span className="text-xs">{SOURCE_KIND_LABELS_AR[line.source_kind] ?? line.source_kind}</span>
                          </div>
                        </TableCell>
                        <TableCell className="hidden text-sm text-muted-foreground sm:table-cell">{formatRiyadhDate(line.source_business_date)}</TableCell>
                        <TableCell className="hidden text-sm md:table-cell">
                          {line.primary_store_name}
                          {line.secondary_store_name ? ` / ${line.secondary_store_name}` : ""}
                        </TableCell>
                        <TableCell className="text-sm font-medium" dir="ltr">
                          {line.gross_collection_impact}
                        </TableCell>
                        <TableCell className="text-sm font-medium" dir="ltr">
                          {line.provider_fee_impact}
                        </TableCell>
                        <TableCell className="text-sm font-medium" dir="ltr">
                          {line.expected_settlement_impact}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>

          {batch.effective_status !== "draft" && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">الحركات البنكية</CardTitle>
              </CardHeader>
              <CardContent>
                {canViewFinancials ? (
                  <SettlementBankMovementsPanel settlementBatchId={batch.id} movements={movements} hasPermission={canRecordBankMovement} effectiveStatus={batch.effective_status} />
                ) : (
                  <p className="text-sm text-muted-foreground">تتطلب صلاحية عرض الماليات (settlements.view_financials).</p>
                )}
              </CardContent>
            </Card>
          )}
        </div>

        <div className="flex flex-col gap-4">
          {canViewFinancials && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">الملخص المالي</CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-4 text-sm">
                {/*
                  Patch 7.1 §26 (migration 0191) — the "original"/"historical"
                  figures below are the PERMANENT historical facts (never
                  zeroed by cancellation); the "effective" figures are the
                  batch's CURRENT contribution (0.00 once cancelled). Both are
                  always shown, clearly labeled, so a cancelled batch's real
                  history stays visible while its zero forward-looking
                  contribution is equally explicit — never just one set of
                  numbers.
                */}
                <div className="flex flex-col gap-2">
                  <p className="text-xs font-semibold text-muted-foreground">الأصلي (تاريخي)</p>
                  <Row label="إجمالي المصادر" value={batch.original_gross_source_impact ?? "—"} dir="ltr" />
                  <Row label="عمولة المزوّد/الناقل" value={batch.original_provider_fee_impact ?? "—"} dir="ltr" />
                  <Row label="المتوقع قبل رسوم الدفعة" value={batch.original_expected_before_batch_fee ?? "—"} dir="ltr" />
                  <Row label={batch.is_batch_fee_override ? "رسوم الدفعة (تجاوز)" : "رسوم الدفعة"} value={batch.original_batch_fee ?? "—"} dir="ltr" />
                  {batch.is_batch_fee_override && <Row label="رسوم الدفعة الافتراضية (قبل التجاوز)" value={batch.configured_batch_fee ?? "—"} dir="ltr" />}
                  <Row label="المتوقع بنكيًا" value={batch.original_expected_bank_settlement ?? "—"} dir="ltr" emphasize />
                  <div className="my-1 border-t border-border" />
                  <Row label="الفعلي البنكي" value={batch.historical_actual_bank_movement ?? "—"} dir="ltr" />
                  <Row label="الفرق" value={batch.original_variance ?? "—"} dir="ltr" emphasize />
                </div>

                <div className="flex flex-col gap-2 rounded-md border border-border p-3">
                  <p className="text-xs font-semibold text-muted-foreground">
                    الفعلي الحالي {isCancelled && <span className="font-normal text-destructive">(الدفعة ملغاة — لا تساهم بشيء حاليًا)</span>}
                  </p>
                  <Row label="المتوقع بنكيًا" value={batch.effective_expected_settlement_contribution ?? "—"} dir="ltr" emphasize />
                  <Row label="الفعلي البنكي" value={batch.effective_actual_settlement_contribution ?? "—"} dir="ltr" />
                  <Row label="الفرق" value={batch.effective_variance_contribution ?? "—"} dir="ltr" emphasize />
                </div>
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

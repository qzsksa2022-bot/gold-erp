import "server-only";

import type { ReportColumnConfig } from "@/features/reports/components/report-table";
import type { SummaryFieldConfig } from "@/features/reports/components/report-summary-cards";
import { COD_STATE_LABELS_AR } from "./report-registry";

/**
 * Hotfix 8.1.1 §1/§46 — Basis-aware / Multi-section Report Presentation
 * Resolver.
 *
 * Patch 8.1 added Dual Basis (Returns/Shipping/COD) and a genuine
 * multi-section shape (Payment Methods: Sales / Actual Refund Cash /
 * Settlements) to the underlying report RPCs — but `report-registry.ts`'s
 * `TABLE_REPORTS` still described each report as ONE static, flat
 * `{columns, summaryFields, rowKey}` triple, so a basis switch or a
 * permission-gated section could silently show the WRONG columns against
 * the WRONG field names (near-empty or garbled tables), because a single
 * static schema cannot describe a report whose actual shape depends on
 * `envelope.basis` or on which top-level keys the RPC happened to include
 * (§79 true key-absence = "this section is not visible to this actor").
 *
 * `resolveReportSections(slug, envelope, fallbackDef?)` is the ONE place
 * that turns a raw RPC envelope into the list of sections to actually
 * render — each section carrying ITS OWN `columns`/`summaryFields`/`rowKey`
 * plus the already-extracted `rows`/`summary` data for that section. This
 * function is PURE and has no permission logic of its own: money-column
 * visibility is still driven entirely by `ReportColumnConfig.permission`
 * (screen: `ReportTable`'s own `c.key in rows[0]` check; export: the route
 * handler filtering `section.columns` by `sessionHasPermission`, exactly
 * the existing convention) and WHICH SECTIONS EXIST AT ALL is driven
 * entirely by which top-level keys the envelope actually carries (§79) —
 * this resolver just reads that shape, it never re-implements a permission
 * check.
 *
 * §5: the on-screen pages, the PDF renderer, and the Excel renderer all
 * call this SAME function with the SAME envelope — one resolver feeds all
 * three, so a basis/section's columns, labels, and redaction can never
 * diverge between what the screen shows and what an export file contains.
 */

export interface ReportSectionDefinition {
  /** Stable key for this section within one report (e.g. "sales", "refund", "settlement", "business_effect", "current_effective"). */
  key: string;
  /** Section heading — rendered only when a report resolves to MORE than one section (a single-section report's own page title already says this). */
  titleAr: string;
  columns: ReportColumnConfig[];
  summaryFields: SummaryFieldConfig[];
  rowKey: string;
  rows: Record<string, unknown>[];
  summary: Record<string, unknown>;
  /**
   * True for a section whose rows are NOT paginated by the RPC (every
   * secondary section returned by a multi-section report — e.g. Payment
   * Methods' `refund_rows`/`settlement_rows`, COD's `settlement_rows` —
   * always returns its COMPLETE matching set, never `p_limit`/`p_offset`
   * scoped). Only the primary section (`false`/absent) is paginated and
   * needs a `<Pagination>` footer or an export-integrity row-count check.
   */
  unpaginated?: boolean;
}

export type ReportEnvelopeLike = Record<string, unknown>;

function asRows(envelope: ReportEnvelopeLike, key: string): Record<string, unknown>[] {
  return (envelope[key] as Record<string, unknown>[] | undefined) ?? [];
}

function asSummary(envelope: ReportEnvelopeLike, key: string): Record<string, unknown> {
  return (envelope[key] as Record<string, unknown> | undefined) ?? {};
}

// ---------------------------------------------------------------------------
// Returns (§2/§36) — business_effect vs actual_cash. Field names below are
// read verbatim from the corresponding RPC branch (0208/0219) — never
// guessed/reused across bases.
// ---------------------------------------------------------------------------
export const RETURNS_MOVEMENT_TYPE_LABELS_AR: Record<string, string> = { approved: "اعتماد", reversed: "عكس" };
export const RETURNS_ACTUAL_CASH_MOVEMENT_TYPE_LABELS_AR: Record<string, string> = {
  actual_refund: "استرداد فعلي",
  actual_refund_reversal: "عكس استرداد فعلي",
};
export const RETURNS_SCENARIO_LABELS_AR: Record<string, string> = {
  defective_product: "منتج معيب",
  customer_changed_mind: "تغيير رأي العميل",
  wrong_item_delivered: "صنف خاطئ",
  customer_never_received: "لم يستلم العميل",
  other: "أخرى",
};
export const REFUND_RECONCILIATION_STATE_LABELS_AR: Record<string, string> = {
  not_applicable: "لا ينطبق",
  pending: "بانتظار التسوية",
  finalized_matched: "مُسوّى ومطابق",
  finalized_with_variance: "مُسوّى بفارق",
};

/** §2 — business_effect columns: the SQL row shape carries `refund_effect` (never `refund_effect` mislabeled as cash), `payment_method_name`/`collection_channel_name` (the ORIGINAL sale's), `revenue_effect`/`net_profit_effect` (profit-gated), `refund_reconciliation_state`. Label reads "أثر مبلغ الاسترداد المعتمد" — never "Actual Cash" (§2's explicit requirement). */
const RETURNS_BUSINESS_EFFECT_COLUMNS: ReportColumnConfig[] = [
  { key: "return_number", label: "رقم المرتجع", format: "text" },
  { key: "order_number", label: "رقم الطلب", format: "text", hiddenOnSmall: true },
  { key: "movement_date", label: "التاريخ", format: "date" },
  { key: "movement_type", label: "نوع الحركة", format: "badge", labelMap: RETURNS_MOVEMENT_TYPE_LABELS_AR, badgeVariant: (v) => (v === "approved" ? "success" : "destructive") },
  { key: "store_name", label: "المتجر", format: "text", hiddenOnSmall: true },
  { key: "scenario", label: "السبب", format: "text", labelMap: RETURNS_SCENARIO_LABELS_AR, hiddenOnSmall: true },
  { key: "payment_method_name", label: "طريقة الدفع الأصلية", format: "text", hiddenOnSmall: true },
  { key: "collection_channel_name", label: "قناة التحصيل الأصلية", format: "text", hiddenOnSmall: true },
  { key: "refund_effect", label: "أثر مبلغ الاسترداد المعتمد", format: "money" },
  { key: "revenue_effect", label: "أثر الإيراد", format: "money", permission: "sales.view_profit", hiddenOnSmall: true },
  { key: "net_profit_effect", label: "أثر صافي الربح", format: "money", permission: "sales.view_profit" },
  { key: "refund_reconciliation_state", label: "حالة تسوية الاسترداد", format: "badge", labelMap: REFUND_RECONCILIATION_STATE_LABELS_AR, hiddenOnSmall: true },
];
const RETURNS_BUSINESS_EFFECT_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "movements_count", label: "عدد الحركات", format: "int" },
  { key: "approved_count", label: "حركات اعتماد", format: "int" },
  { key: "reversed_count", label: "حركات عكس", format: "int" },
  { key: "refund_effect", label: "أثر مبلغ الاسترداد المعتمد", format: "money" },
  { key: "revenue_effect", label: "أثر الإيراد", format: "money", permission: "sales.view_profit" },
  { key: "net_profit_effect", label: "أثر صافي الربح", format: "money", emphasize: true, permission: "sales.view_profit" },
];

/** §2 — actual_cash columns: SQL row shape carries `movement_type` in ('actual_refund'|'actual_refund_reversal'), `refund_method_name` (the EVENT'S own method, never the sale's), `cash_effect`, `refund_reconciliation_state`. No sales.view_profit gating (matches get_return_detail() precedent). */
const RETURNS_ACTUAL_CASH_COLUMNS: ReportColumnConfig[] = [
  { key: "return_number", label: "رقم المرتجع", format: "text" },
  { key: "order_number", label: "رقم الطلب", format: "text", hiddenOnSmall: true },
  { key: "movement_date", label: "التاريخ", format: "date" },
  {
    key: "movement_type",
    label: "نوع الحركة",
    format: "badge",
    labelMap: RETURNS_ACTUAL_CASH_MOVEMENT_TYPE_LABELS_AR,
    badgeVariant: (v) => (v === "actual_refund" ? "success" : "destructive"),
  },
  { key: "store_name", label: "المتجر", format: "text", hiddenOnSmall: true },
  { key: "refund_method_name", label: "طريقة الاسترداد الفعلية", format: "text" },
  { key: "cash_effect", label: "الأثر النقدي الفعلي", format: "money" },
  { key: "refund_reconciliation_state", label: "حالة تسوية الاسترداد", format: "badge", labelMap: REFUND_RECONCILIATION_STATE_LABELS_AR, hiddenOnSmall: true },
];
const RETURNS_ACTUAL_CASH_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "movements_count", label: "عدد الحركات", format: "int" },
  { key: "refund_events_count", label: "عدد عمليات الاسترداد الفعلي", format: "int" },
  { key: "reversal_events_count", label: "عدد عكوس الاسترداد", format: "int" },
  { key: "cash_effect", label: "صافي الأثر النقدي الفعلي", format: "money", emphasize: true },
];

function resolveReturnsSections(envelope: ReportEnvelopeLike): ReportSectionDefinition[] {
  const basis = (envelope.basis as string | undefined) ?? "business_effect";
  const rows = asRows(envelope, "rows");
  const summary = asSummary(envelope, "summary");
  if (basis === "actual_cash") {
    return [{ key: "actual_cash", titleAr: "التدفق النقدي الفعلي", columns: RETURNS_ACTUAL_CASH_COLUMNS, summaryFields: RETURNS_ACTUAL_CASH_SUMMARY_FIELDS, rowKey: "__row_index__", rows, summary }];
  }
  return [{ key: "business_effect", titleAr: "الأثر التجاري المعتمد", columns: RETURNS_BUSINESS_EFFECT_COLUMNS, summaryFields: RETURNS_BUSINESS_EFFECT_SUMMARY_FIELDS, rowKey: "__row_index__", rows, summary }];
}

// ---------------------------------------------------------------------------
// Shipping (§3) — current_effective vs movements_during_period.
// ---------------------------------------------------------------------------
export const SHIPPING_STATUS_LABELS_AR: Record<string, string> = {
  created: "تم الإنشاء",
  ready_for_pickup: "جاهز للاستلام",
  picked_up: "تم الاستلام",
  in_transit: "في الطريق",
  out_for_delivery: "قيد التوصيل",
  delivered: "تم التسليم",
  delivery_failed: "فشل التسليم",
  customer_refused: "رفض العميل",
  customer_never_received: "لم يستلم العميل",
  returned_to_store: "أعيد للمتجر",
  cancelled: "ملغى",
};
const SHIPPING_MOVEMENT_TYPE_LABELS_AR: Record<string, string> = {
  initial: "تسجيل أولي",
  actual_cost_recorded: "تسجيل التكلفة الفعلية",
  actual_cost_correction: "تصحيح التكلفة الفعلية",
  customer_charge_correction: "تصحيح رسوم العميل",
};

/** §3 current_effective — unchanged shape from Patch 8.1/original: shipment_number/order_number/shipment_date/store/carrier/status/customer_shipping_charge/actual_carrier_cost/net_shipping_result. */
const SHIPPING_CURRENT_COLUMNS: ReportColumnConfig[] = [
  { key: "shipment_number", label: "رقم الشحنة", format: "text" },
  { key: "order_number", label: "رقم الطلب", format: "text", hiddenOnSmall: true },
  { key: "shipment_date", label: "التاريخ", format: "date" },
  { key: "store_name", label: "المتجر", format: "text", hiddenOnSmall: true },
  { key: "carrier_name", label: "الناقل", format: "text", hiddenOnSmall: true },
  {
    key: "current_status",
    label: "الحالة",
    format: "badge",
    labelMap: SHIPPING_STATUS_LABELS_AR,
    badgeVariant: (v) => (v === "delivered" ? "success" : v === "cancelled" || v === "delivery_failed" ? "destructive" : "secondary"),
  },
  { key: "customer_shipping_charge", label: "رسوم العميل", format: "money" },
  { key: "actual_carrier_cost", label: "تكلفة الناقل الفعلية الحالية", format: "money", permission: "sales.view_profit", hiddenOnSmall: true },
  { key: "net_shipping_result", label: "صافي نتيجة الشحن الحالية", format: "money", permission: "sales.view_profit" },
];
const SHIPPING_CURRENT_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "shipments_count", label: "عدد الشحنات", format: "int" },
  { key: "customer_shipping_charge", label: "رسوم العملاء", format: "money" },
  { key: "actual_carrier_cost", label: "تكلفة الناقل الفعلية الحالية", format: "money", permission: "sales.view_profit" },
  { key: "net_shipping_result", label: "صافي نتيجة الشحن الحالية", format: "money", emphasize: true, permission: "sales.view_profit" },
];

/** §3 movements_during_period — SQL row shape carries movement_date/movement_type/customer_charge_effect/carrier_cost_effect/net_shipping_effect. Label "أثر تكلفة الناقل" — never "تكلفة الناقل الفعلية" for this basis (§3's explicit requirement). */
const SHIPPING_MOVEMENTS_COLUMNS: ReportColumnConfig[] = [
  { key: "shipment_number", label: "رقم الشحنة", format: "text" },
  { key: "order_number", label: "رقم الطلب", format: "text", hiddenOnSmall: true },
  { key: "movement_date", label: "التاريخ", format: "date" },
  { key: "movement_type", label: "نوع الحركة", format: "text", labelMap: SHIPPING_MOVEMENT_TYPE_LABELS_AR, hiddenOnSmall: true },
  { key: "store_name", label: "المتجر", format: "text", hiddenOnSmall: true },
  { key: "carrier_name", label: "الناقل", format: "text", hiddenOnSmall: true },
  { key: "customer_charge_effect", label: "أثر رسوم العميل", format: "money" },
  { key: "carrier_cost_effect", label: "أثر تكلفة الناقل", format: "money", permission: "sales.view_profit" },
  { key: "net_shipping_effect", label: "صافي الأثر", format: "money", permission: "sales.view_profit" },
];
const SHIPPING_MOVEMENTS_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "movements_count", label: "عدد الحركات", format: "int" },
  { key: "initial_count", label: "حركات التسجيل الأولي", format: "int" },
  { key: "customer_charge_effect", label: "أثر رسوم العملاء", format: "money" },
  { key: "carrier_cost_effect", label: "أثر تكلفة الناقل", format: "money", permission: "sales.view_profit" },
  { key: "net_shipping_effect", label: "صافي الأثر", format: "money", emphasize: true, permission: "sales.view_profit" },
];

function resolveShippingSections(envelope: ReportEnvelopeLike): ReportSectionDefinition[] {
  const basis = (envelope.basis as string | undefined) ?? "current_effective";
  const rows = asRows(envelope, "rows");
  const summary = asSummary(envelope, "summary");
  if (basis === "movements_during_period") {
    return [{ key: "movements_during_period", titleAr: "الحركات خلال الفترة", columns: SHIPPING_MOVEMENTS_COLUMNS, summaryFields: SHIPPING_MOVEMENTS_SUMMARY_FIELDS, rowKey: "__row_index__", rows, summary }];
  }
  return [{ key: "current_effective", titleAr: "الحالة الفعلية الحالية", columns: SHIPPING_CURRENT_COLUMNS, summaryFields: SHIPPING_CURRENT_SUMMARY_FIELDS, rowKey: "shipment_id", rows, summary }];
}

// ---------------------------------------------------------------------------
// COD (§4) — current_effective vs collection_transitions, plus an optional
// Settlement section (cod_carrier routes only, §31).
// ---------------------------------------------------------------------------
const COD_CURRENT_COLUMNS: ReportColumnConfig[] = [
  { key: "shipment_number", label: "رقم الشحنة", format: "text" },
  { key: "order_number", label: "رقم الطلب", format: "text", hiddenOnSmall: true },
  { key: "shipment_date", label: "التاريخ", format: "date" },
  { key: "store_name", label: "المتجر", format: "text", hiddenOnSmall: true },
  {
    key: "cod_collection_state",
    label: "حالة التحصيل",
    format: "badge",
    labelMap: COD_STATE_LABELS_AR,
    badgeVariant: (v) => (v === "collected" ? "success" : v === "not_collected" ? "destructive" : "warning"),
  },
  { key: "cod_expected_amount", label: "المبلغ المتوقع", format: "money", permission: "sales.view_profit" },
  { key: "effective_cod_receivable", label: "المستحق التحصيل الحالي (غير محصّل)", format: "money", permission: "sales.view_profit", hiddenOnSmall: true },
];
const COD_CURRENT_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "shipments_count", label: "عدد الشحنات", format: "int" },
  { key: "collected_count", label: "تم تحصيلها", format: "int" },
  { key: "not_collected_count", label: "لم تُحصّل", format: "int" },
  { key: "pending_count", label: "قيد الانتظار", format: "int" },
  { key: "cod_expected_amount", label: "إجمالي المتوقع", format: "money", permission: "sales.view_profit" },
  { key: "cod_collected_amount", label: "إجمالي المحصّل", format: "money", permission: "sales.view_profit" },
  { key: "effective_cod_receivable", label: "إجمالي المستحق الحالي (غير محصّل)", format: "money", emphasize: true, permission: "sales.view_profit" },
];

/** §4 collection_transitions — SQL row shape carries movement_date/transition_state/reference/cod_effect. */
const COD_TRANSITIONS_COLUMNS: ReportColumnConfig[] = [
  { key: "shipment_number", label: "رقم الشحنة", format: "text" },
  { key: "order_number", label: "رقم الطلب", format: "text", hiddenOnSmall: true },
  { key: "movement_date", label: "التاريخ", format: "date" },
  {
    key: "transition_state",
    label: "الحالة بعد الحركة",
    format: "badge",
    labelMap: COD_STATE_LABELS_AR,
    badgeVariant: (v) => (v === "collected" ? "success" : v === "not_collected" ? "destructive" : "warning"),
  },
  { key: "store_name", label: "المتجر", format: "text", hiddenOnSmall: true },
  { key: "reference", label: "المرجع", format: "text", hiddenOnSmall: true },
  { key: "cod_effect", label: "أثر التحصيل", format: "money", permission: "sales.view_profit" },
];
const COD_TRANSITIONS_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "movements_count", label: "عدد الحركات", format: "int" },
  { key: "shipments_count", label: "عدد الشحنات", format: "int" },
  { key: "cod_collections", label: "إجمالي التحصيل", format: "money", permission: "sales.view_profit" },
  { key: "cod_reversals", label: "إجمالي عكس التحصيل", format: "money", permission: "sales.view_profit" },
  { key: "net_cod_collection_effect", label: "صافي أثر التحصيل", format: "money", emphasize: true, permission: "sales.view_profit" },
];

const COD_SETTLEMENT_COLUMNS: ReportColumnConfig[] = [
  { key: "route_name", label: "المسار", format: "text" },
  { key: "carrier_name", label: "الناقل", format: "text", hiddenOnSmall: true },
  { key: "batches_count", label: "عدد الدفعات", format: "int" },
  { key: "expected", label: "المتوقع", format: "money" },
  { key: "actual", label: "الفعلي", format: "money" },
  { key: "variance", label: "الفرق", format: "money" },
];
const COD_SETTLEMENT_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "settlement_routes_count", label: "عدد المسارات", format: "int" },
  { key: "settlement_batches_count", label: "عدد الدفعات", format: "int" },
  { key: "settlement_expected", label: "إجمالي المتوقع", format: "money" },
  { key: "settlement_actual", label: "إجمالي الفعلي", format: "money" },
  { key: "settlement_variance", label: "إجمالي الفرق", format: "money", emphasize: true },
];

function resolveCodSections(envelope: ReportEnvelopeLike): ReportSectionDefinition[] {
  const basis = (envelope.basis as string | undefined) ?? "current_effective";
  const rows = asRows(envelope, "rows");
  const summary = asSummary(envelope, "summary");
  const sections: ReportSectionDefinition[] =
    basis === "collection_transitions"
      ? [{ key: "collection_transitions", titleAr: "حركات التحصيل الفعلية", columns: COD_TRANSITIONS_COLUMNS, summaryFields: COD_TRANSITIONS_SUMMARY_FIELDS, rowKey: "__row_index__", rows, summary }]
      : [{ key: "current_effective", titleAr: "الحالة الفعلية الحالية", columns: COD_CURRENT_COLUMNS, summaryFields: COD_CURRENT_SUMMARY_FIELDS, rowKey: "shipment_id", rows, summary }];

  if ("settlement_rows" in envelope && "settlement_summary" in envelope) {
    sections.push({
      key: "settlement",
      titleAr: "تسوية الناقل البنكية",
      columns: COD_SETTLEMENT_COLUMNS,
      summaryFields: COD_SETTLEMENT_SUMMARY_FIELDS,
      rowKey: "settlement_route_id",
      rows: asRows(envelope, "settlement_rows"),
      summary: asSummary(envelope, "settlement_summary"),
      unpaginated: true,
    });
  }
  return sections;
}

// ---------------------------------------------------------------------------
// Payment Methods (§6-10) — genuine multi-section: Sales / Actual Refund
// Cash / Settlements, EACH independently present-or-absent per §79.
// ---------------------------------------------------------------------------
const PAYMENT_SALES_COLUMNS: ReportColumnConfig[] = [
  // §7 — Payment Method ALONE is never shown; the row identity is the
  // Method+Channel PAIR, composed here from the two RPC fields into one
  // never-null display string ("Mada — بدون قناة تحصيل" when the sale
  // carried no collection channel, §7's own example).
  { key: "payment_channel_pair_label", label: "طريقة الدفع — قناة التحصيل", format: "text" },
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "revenue", label: "الإيراد", format: "money" },
  { key: "payment_fees", label: "رسوم الدفع", format: "money", hiddenOnSmall: true, permission: "sales.view_profit" },
  { key: "net_sales_profit", label: "صافي الربح", format: "money", permission: "sales.view_profit" },
];
const PAYMENT_SALES_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "payment_method_pairs_count", label: "عدد أزواج (طريقة/قناة)", format: "int" },
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "revenue", label: "إجمالي الإيراد", format: "money" },
  { key: "net_sales_profit", label: "صافي الربح", format: "money", emphasize: true, permission: "sales.view_profit" },
];

const PAYMENT_REFUND_COLUMNS: ReportColumnConfig[] = [
  { key: "refund_method_name", label: "طريقة الاسترداد الفعلية", format: "text" },
  { key: "events_count", label: "عدد العمليات", format: "int" },
  { key: "actual_refunded_cash", label: "صافي النقد المسترد فعليًا", format: "money" },
];
const PAYMENT_REFUND_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "refund_methods_count", label: "عدد طرق الاسترداد", format: "int" },
  { key: "refund_events_count", label: "عدد عمليات الاسترداد", format: "int" },
  { key: "actual_refunded_cash", label: "صافي النقد المسترد فعليًا", format: "money", emphasize: true },
];

const PAYMENT_SETTLEMENT_COLUMNS: ReportColumnConfig[] = [
  { key: "route_name", label: "المسار", format: "text" },
  { key: "payment_method_name", label: "طريقة الدفع", format: "text", hiddenOnSmall: true },
  { key: "collection_channel_name", label: "قناة التحصيل", format: "text", hiddenOnSmall: true },
  { key: "batches_count", label: "عدد الدفعات", format: "int" },
  { key: "expected", label: "المتوقع", format: "money" },
  { key: "actual", label: "الفعلي", format: "money" },
  { key: "variance", label: "الفرق", format: "money" },
];
const PAYMENT_SETTLEMENT_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "settlement_routes_count", label: "عدد المسارات", format: "int" },
  { key: "settlement_batches_count", label: "عدد الدفعات", format: "int" },
  { key: "settlement_expected", label: "إجمالي المتوقع", format: "money" },
  { key: "settlement_actual", label: "إجمالي الفعلي", format: "money" },
  { key: "settlement_variance", label: "إجمالي الفرق", format: "money", emphasize: true },
];

function resolvePaymentMethodsSections(envelope: ReportEnvelopeLike): ReportSectionDefinition[] {
  const sections: ReportSectionDefinition[] = [];

  // §9 — envelope typing/rendering must be Section-safe: each block below
  // is entered ONLY when BOTH of that section's own keys are genuinely
  // present (§79) — never assumed, never defaulted to an empty object that
  // would render a valid-looking-but-wrong empty section.
  if ("rows" in envelope && "summary" in envelope) {
    const rows = asRows(envelope, "rows").map((r) => ({
      ...r,
      payment_channel_pair_label: `${String(r.payment_method_name ?? "")} — ${r.collection_channel_name ? String(r.collection_channel_name) : "بدون قناة تحصيل"}`,
    }));
    sections.push({ key: "sales", titleAr: "المبيعات (التحصيل الأصلي)", columns: PAYMENT_SALES_COLUMNS, summaryFields: PAYMENT_SALES_SUMMARY_FIELDS, rowKey: "payment_channel_pair_label", rows, summary: asSummary(envelope, "summary") });
  }
  if ("refund_rows" in envelope && "refund_summary" in envelope) {
    sections.push({
      key: "refund",
      titleAr: "الاسترداد النقدي الفعلي",
      columns: PAYMENT_REFUND_COLUMNS,
      summaryFields: PAYMENT_REFUND_SUMMARY_FIELDS,
      rowKey: "refund_method_id",
      rows: asRows(envelope, "refund_rows"),
      summary: asSummary(envelope, "refund_summary"),
      unpaginated: true,
    });
  }
  if ("settlement_rows" in envelope && "settlement_summary" in envelope) {
    sections.push({
      key: "settlement",
      titleAr: "التسويات البنكية",
      columns: PAYMENT_SETTLEMENT_COLUMNS,
      summaryFields: PAYMENT_SETTLEMENT_SUMMARY_FIELDS,
      rowKey: "settlement_route_id",
      rows: asRows(envelope, "settlement_rows"),
      summary: asSummary(envelope, "settlement_summary"),
      unpaginated: true,
    });
  }
  return sections;
}

// ---------------------------------------------------------------------------
// Dispatcher.
// ---------------------------------------------------------------------------
export interface FallbackSectionDef {
  titleAr: string;
  columns: ReportColumnConfig[];
  summaryFields: SummaryFieldConfig[];
  rowKey: string;
}

/**
 * Resolves a report's raw RPC envelope into the ordered list of sections to
 * render — screen, PDF, and Excel all call this SAME function (§5). For a
 * report with no basis/multi-section shape at all, pass `fallbackDef`
 * (normally `TABLE_REPORTS[slug]` itself) to get a single "default" section
 * built from that report's own static columns — this keeps single-shape
 * reports (Sales/Items/Categories/Karats/Employees/Collection Channels/
 * Settlements) working exactly as before, with zero special-casing here.
 */
export function resolveReportSections(slug: string, envelope: ReportEnvelopeLike, fallbackDef?: FallbackSectionDef): ReportSectionDefinition[] {
  switch (slug) {
    case "payment-methods":
      return resolvePaymentMethodsSections(envelope);
    case "returns":
      return resolveReturnsSections(envelope);
    case "shipping":
      return resolveShippingSections(envelope);
    case "cod":
      return resolveCodSections(envelope);
    default:
      if (!fallbackDef) return [];
      return [
        {
          key: "default",
          titleAr: fallbackDef.titleAr,
          columns: fallbackDef.columns,
          summaryFields: fallbackDef.summaryFields,
          rowKey: fallbackDef.rowKey,
          rows: asRows(envelope, "rows"),
          summary: asSummary(envelope, "summary"),
        },
      ];
  }
}

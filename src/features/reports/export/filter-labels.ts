import "server-only";

import {
  getReportCategories,
  getReportKarats,
  getReportPaymentMethods,
  getReportCollectionChannels,
  getReportShippingCarriers,
  getReportShippingZones,
  getReportAdjustmentTypes,
  getReportSettlementRoutes,
  getReportEmployees,
} from "@/features/reports/queries";
import {
  RETURNS_SCENARIO_LABELS_AR,
  RETURNS_STATUS_LABELS_AR,
  MOVEMENT_TYPE_LABELS_AR,
  SHIPPING_STATUS_LABELS_AR,
  COD_STATE_LABELS_AR,
  SETTLEMENT_STATUS_LABELS_AR,
  SETTLEMENT_EFFECTIVE_STATUS_LABELS_AR,
  ROUTE_KIND_LABELS_AR,
  REFUND_RECONCILIATION_STATE_LABELS_AR,
} from "./report-registry";
import { BASIS_LABELS_AR } from "@/features/reports/components/report-basis-badge";

/**
 * Hotfix 8.1.1 §22 — Filter Metadata. Every active filter appears in export
 * metadata with a human-readable label, never a raw UUID when a label can
 * be resolved — using only the SAME narrow report lookups every filter
 * dropdown already fetches (no new RPCs, per §22's own instruction).
 */

const DIRECTION_LABELS_AR: Record<string, string> = { outbound: "صادر", return: "مرتجع" };
const BOOLEAN_LABELS_AR: Record<string, string> = { true: "نعم", false: "لا" };
const STATUS_LABELS_AR: Record<string, string> = { ...RETURNS_STATUS_LABELS_AR, ...SETTLEMENT_STATUS_LABELS_AR };

/** Arabic label for each raw filter KEY (never the value) — shown as "<key label>: <value label>". */
const FILTER_KEY_LABELS_AR: Record<string, string> = {
  employee_id: "الموظف",
  category_id: "الفئة",
  karat_id: "العيار",
  parent_id: "الفئة الرئيسية",
  payment_method_id: "طريقة الدفع",
  collection_channel_id: "قناة التحصيل",
  scenario: "السبب",
  status: "الحالة",
  basis: "أساس العرض",
  refund_method_id: "طريقة الاسترداد الفعلية",
  salesperson_id: "موظف المبيعات",
  original_sale_date_from: "تاريخ البيع الأصلي من",
  original_sale_date_to: "تاريخ البيع الأصلي إلى",
  refund_reconciliation_state: "حالة تسوية الاسترداد",
  carrier_id: "الناقل",
  shipping_zone_id: "المنطقة",
  direction: "الاتجاه",
  current_status: "الحالة",
  is_cod: "دفع عند الاستلام؟",
  cod_collection_state: "حالة التحصيل",
  adjustment_type_id: "نوع الخدمة",
  original_sale_store_id: "متجر البيع الأصلي",
  processing_store_id: "متجر المعالجة",
  participates_in_settlement: "يشارك في التسوية؟",
  movement_type: "نوع الحركة",
  created_by: "أنشئ بواسطة",
  approved_by: "اعتُمد بواسطة",
  settlement_route_id: "المسار",
  route_kind: "نوع المسار",
  shipping_carrier_id: "الناقل",
  effective_status: "الحالة الفعلية",
  has_variance: "به فروقات؟",
  provider_statement_reference: "مرجع كشف المزوّد",
};

/** Filter keys already rendered elsewhere in export metadata (date range, store scope, search box, pagination/sort plumbing) — never duplicated here. */
const SKIP_KEYS = new Set(["date_from", "date_to", "store_ids", "store_id", "page", "limit", "sort", "search"]);

export async function resolveFilterLabels(filters: Record<string, unknown>, storeLabelMap: Map<string, string>, slug?: string): Promise<string[]> {
  const activeKeys = Object.keys(filters).filter((k) => !SKIP_KEYS.has(k) && filters[k] !== undefined && filters[k] !== null && filters[k] !== "");
  if (activeKeys.length === 0) return [];

  const [categories, karats, paymentMethods, channels, carriers, zones, adjustmentTypes, settlementRoutes, employees] = await Promise.all([
    getReportCategories(),
    getReportKarats(),
    getReportPaymentMethods(),
    getReportCollectionChannels(),
    getReportShippingCarriers(),
    getReportShippingZones(),
    getReportAdjustmentTypes(),
    getReportSettlementRoutes(),
    getReportEmployees(),
  ]);

  const idMaps: Record<string, Map<string, string>> = {
    category_id: new Map(categories.map((c: { id: string; name_ar: string }) => [c.id, c.name_ar])),
    parent_id: new Map(categories.map((c: { id: string; name_ar: string }) => [c.id, c.name_ar])),
    karat_id: new Map(karats.map((k: { id: string; name_ar: string }) => [k.id, k.name_ar])),
    payment_method_id: new Map(paymentMethods.map((p: { id: string; name_ar: string }) => [p.id, p.name_ar])),
    refund_method_id: new Map(paymentMethods.map((p: { id: string; name_ar: string }) => [p.id, p.name_ar])),
    collection_channel_id: new Map(channels.map((c: { id: string; name_ar: string }) => [c.id, c.name_ar])),
    carrier_id: new Map(carriers.map((c: { id: string; name_ar: string }) => [c.id, c.name_ar])),
    shipping_carrier_id: new Map(carriers.map((c: { id: string; name_ar: string }) => [c.id, c.name_ar])),
    shipping_zone_id: new Map(zones.map((z: { id: string; name_ar: string }) => [z.id, z.name_ar])),
    adjustment_type_id: new Map(adjustmentTypes.map((t: { id: string; name_ar: string }) => [t.id, t.name_ar])),
    settlement_route_id: new Map(settlementRoutes.map((r: { id: string; name_ar: string }) => [r.id, r.name_ar])),
    employee_id: new Map(employees.map((e: { id: string; full_name: string }) => [e.id, e.full_name])),
    salesperson_id: new Map(employees.map((e: { id: string; full_name: string }) => [e.id, e.full_name])),
    created_by: new Map(employees.map((e: { id: string; full_name: string }) => [e.id, e.full_name])),
    approved_by: new Map(employees.map((e: { id: string; full_name: string }) => [e.id, e.full_name])),
    original_sale_store_id: storeLabelMap,
    processing_store_id: storeLabelMap,
  };

  const enumMaps: Record<string, Record<string, string>> = {
    scenario: RETURNS_SCENARIO_LABELS_AR,
    status: STATUS_LABELS_AR,
    basis: BASIS_LABELS_AR,
    direction: DIRECTION_LABELS_AR,
    current_status: SHIPPING_STATUS_LABELS_AR,
    cod_collection_state: COD_STATE_LABELS_AR,
    refund_reconciliation_state: REFUND_RECONCILIATION_STATE_LABELS_AR,
    effective_status: SETTLEMENT_EFFECTIVE_STATUS_LABELS_AR,
    route_kind: ROUTE_KIND_LABELS_AR,
    movement_type: MOVEMENT_TYPE_LABELS_AR,
    is_cod: BOOLEAN_LABELS_AR,
    has_variance: BOOLEAN_LABELS_AR,
    participates_in_settlement: BOOLEAN_LABELS_AR,
  };

  const lines: string[] = [];
  for (const key of activeKeys) {
    // Hotfix 8.1.2 §28-30 — the Returns report's payment_method_id
    // (business_effect basis: the original sale's own payment method) and
    // refund_method_id (actual_cash basis: the refund EVENT's own method,
    // 0219 §36) are mutually exclusive by BASIS, never both meaningful at
    // once. The filter bar now clears the stale one on a basis switch, but
    // export metadata must not trust that alone (a bookmarked/hand-built
    // URL could still carry both) — skip whichever one the current basis
    // does not actually apply to, so the export never shows a filter line
    // that had no effect on the data it's describing. Scoped to slug ===
    // "returns" only -- refund_method_id is ALSO a Payment Methods report
    // filter (its Refund Cash section, no basis concept at all), where it
    // must never be suppressed.
    if (slug === "returns" && isReturnsBasisIrrelevant(filters, key)) continue;
    const raw = String(filters[key]);
    const label = FILTER_KEY_LABELS_AR[key] ?? key;
    const resolved = enumMaps[key]?.[raw] ?? idMaps[key]?.get(raw) ?? raw;
    lines.push(`${label}: ${resolved}`);
  }
  return lines;
}

function isReturnsBasisIrrelevant(filters: Record<string, unknown>, key: string): boolean {
  if (key !== "payment_method_id" && key !== "refund_method_id") return false;
  const basis = filters.basis;
  if (key === "payment_method_id") return basis === "actual_cash";
  return basis !== "actual_cash"; // key === "refund_method_id"
}

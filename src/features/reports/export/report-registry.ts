import "server-only";

import type { ReportColumnConfig } from "@/features/reports/components/report-table";
import type { SummaryFieldConfig } from "@/features/reports/components/report-summary-cards";
import type { PermissionKey } from "@/lib/permissions/constants";
import type { ReportEnvelope, PaymentMethodsReportEnvelope } from "@/features/reports/queries";
// Phase 10 — the expenses report reuses the SAME list_store_expenses() engine
// the screen uses (§39 Single Reporting Engine): one aggregation, one source
// of truth, no parallel export-only query.
import { getStoreExpenses } from "@/features/expenses/queries";
import {
  getSalesReport,
  getItemsReport,
  getCategoriesReport,
  getKaratsReport,
  getEmployeesReport,
  getPaymentMethodsReport,
  getCollectionChannelsReport,
  getReturnsReport,
  getShippingReport,
  getCodReport,
  getAdjustmentsReport,
  getSettlementsReport,
} from "@/features/reports/queries";

/**
 * Phase 8 §39 — Single Reporting Engine.
 *
 * This module is the ONE place every table-style report's column list and
 * summary-card field list are defined. Each report page under
 * `src/app/(app)/reports/<slug>/page.tsx` imports its `COLUMNS`/summary
 * `fields` from here for on-screen rendering, and the PDF/Excel export
 * generators (`export/pdf.ts`, `export/excel.ts`) import the SAME arrays.
 * Screen, PDF, and Excel are therefore guaranteed to show the same columns,
 * the same Arabic labels, and the same money/weight/int formatting rules —
 * there is no second, divergent definition anywhere for a table report.
 *
 * The four periodic Management Reports (daily/weekly/monthly/yearly) don't
 * fit this table shape (they render `KpiSection`s over a
 * `get_dashboard_summary()`-shaped object) — those are defined separately in
 * `management-registry.ts` and share the exact same `KpiFieldConfig` arrays
 * already used by their screen pages.
 */

export const RETURNS_SCENARIO_LABELS_AR: Record<string, string> = {
  defective_product: "منتج معيب",
  customer_changed_mind: "تغيير رأي العميل",
  wrong_item_delivered: "صنف خاطئ",
  customer_never_received: "لم يستلم العميل",
  other: "أخرى",
};

export const RETURNS_STATUS_LABELS_AR: Record<string, string> = { approved: "معتمد", reversed: "معكوس" };

/** Patch 8.1 §26-29/§39-42 — `refund_reconciliation_state` is a CURRENT operational indicator (never a business date), same CASE formula as `get_return_detail()` (0098). */
export const REFUND_RECONCILIATION_STATE_LABELS_AR: Record<string, string> = {
  not_applicable: "لا ينطبق",
  pending: "بانتظار التسوية",
  finalized_matched: "مُسوّى ومطابق",
  finalized_with_variance: "مُسوّى بفارق",
};

export const MOVEMENT_TYPE_LABELS_AR: Record<string, string> = { approved: "اعتماد", reversed: "عكس" };

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

export const COD_STATE_LABELS_AR: Record<string, string> = {
  expected: "متوقع",
  collected: "تم التحصيل",
  not_collected: "لم يُحصّل",
  unknown: "غير معروف",
};

export const SETTLEMENT_STATUS_LABELS_AR: Record<string, string> = { finalized: "مُعتمدة", reconciled: "مُسوّاة" };

/** Patch 8.1 §41 — `effective_status` is the correct, WORKING "Cancelled" filter value (computed server-side; raw `status` can never literally be 'cancelled', 0172's CHECK constraint). Hotfix 8.1.1 §28-31 — 'draft' is now a genuinely working value too (0218 fixed the base population to actually admit draft-status batches when explicitly requested; a draft batch contributes zero to the financial ledger, by construction). */
export const SETTLEMENT_EFFECTIVE_STATUS_LABELS_AR: Record<string, string> = { draft: "مسودة", finalized: "مُعتمدة", reconciled: "مُسوّاة", cancelled: "ملغاة" };

/** Patch 8.1 §41 — `route_kind`, read from the batch's own `route_kind_snapshot` (0172). */
export const ROUTE_KIND_LABELS_AR: Record<string, string> = { payment_collection: "تحصيل مدفوعات", cod_carrier: "ناقل الدفع عند الاستلام" };

export interface TableReportDefinition {
  slug: string;
  titleAr: string;
  descriptionAr: string;
  columns: ReportColumnConfig[];
  summaryFields: SummaryFieldConfig[];
  rowKey: string;
  /** Domain permission gating the underlying data (mirrors the page's own gate; the RPC re-enforces this regardless). */
  domainPermission: PermissionKey;
  /** True for reports whose envelope carries a top-level `basis` (Current Effective vs Movements-during-Period, §83). */
  hasBasis?: boolean;
  /** True for the dual-basis Settlements report (`row_basis`/`summary_basis` instead of a single `basis`). */
  hasDualBasis?: boolean;
  /** Extra report-specific filter keys read verbatim (as strings) from the URL query string (same keys `ReportFilterBar`'s `selects`/`textFilters` write). */
  extraFilterKeys: string[];
  /** Patch 8.1 §39-42 — a subset of `extraFilterKeys` that are genuinely BOOLEAN-typed RPC parameters (e.g. Settlements' `has_variance`, Shipping's `is_cod`) — the export route parses these via `typedBooleanFilter` instead of passing the raw "true"/"false" string through untyped. */
  booleanFilterKeys?: string[];
  /**
   * Fetches the export dataset — literally the SAME wrapper function the
   * screen page calls (§39: identical dataset for Screen/PDF/Excel, not
   * just identical column labels). `filters` is built generically by the
   * export route handler from raw URL search params using the same
   * date_from/date_to/store_id/search/sort/page + `extraFilterKeys`
   * convention every report page already follows.
   */
  // Hotfix 8.1.2 §24-25 — Payment Methods' envelope is NOT a single-schema
  // ReportEnvelope (total_count/summary/rows are conditionally ABSENT,
  // §79) — the union covers it without weakening every other report's
  // still-strict ReportEnvelope return type. The export route handler
  // immediately narrows this to `Record<string, unknown>` anyway (its own
  // §11/§13/§60 integrity guard already handles an absent total_count via
  // `typeof totalCount === "number"`), so this union only needs to satisfy
  // the type checker at the call site, not add new runtime behavior.
  fetch: (filters: ReportBaseFiltersLike) => Promise<ReportEnvelope> | Promise<PaymentMethodsReportEnvelope>;
}

/** Loosely-typed filters object built generically by the export route handler; each `fetch` above narrows it to its own filter interface at the call site (every report-specific filter is an optional string, matching every `*ReportFilters` interface in queries.ts). */
export interface ReportBaseFiltersLike {
  date_from: string;
  date_to: string;
  store_ids?: string[];
  search?: string;
  sort?: string;
  page: number;
  [extraKey: string]: unknown;
}

export const SALES_COLUMNS: ReportColumnConfig[] = [
  { key: "order_number", label: "رقم الطلب", format: "text" },
  { key: "sale_date", label: "التاريخ", format: "date" },
  { key: "store_name", label: "المتجر", format: "text" },
  { key: "employee_name", label: "الموظف", format: "text", hiddenOnSmall: true },
  { key: "payment_method_name", label: "طريقة الدفع", format: "text", hiddenOnSmall: true },
  { key: "items_count", label: "عدد الأصناف", format: "int", hiddenOnSmall: true },
  { key: "weight_grams", label: "الوزن", format: "weight", hiddenOnSmall: true },
  { key: "sales_revenue", label: "الإيراد", format: "money" },
  // Hotfix 8.1.1 §37-38 — the old ambiguous single `net_sales_profit` column
  // is replaced by two EXPLICITLY labeled figures (0210 added both,
  // additively, alongside net_sales_profit which is kept only for backward
  // compatibility and no longer surfaced here): the sale's own immutable
  // original profit, and the CURRENT effective profit after any
  // currently-approved Return's impact against this sale (Sale Cohort
  // basis, §34 — never the Dashboard's Event-Period basis). Never label the
  // original figure as if it were the effective one (§38's own warning).
  { key: "original_net_sales_profit", label: "صافي الربح — تعاقد البيع (الأصلي)", format: "money", permission: "sales.view_profit", hiddenOnSmall: true },
  { key: "effective_net_sales_profit", label: "صافي الربح الفعلي (بعد أثر المرتجعات الحالي)", format: "money", permission: "sales.view_profit" },
];
export const SALES_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "items_count", label: "عدد الأصناف", format: "int" },
  { key: "weight_grams", label: "إجمالي الوزن", format: "weight" },
  { key: "sales_revenue", label: "إجمالي الإيراد", format: "money" },
  { key: "average_order_value", label: "متوسط قيمة الطلب", format: "money" },
  { key: "original_net_sales_profit", label: "صافي الربح — تعاقد البيع (الأصلي)", format: "money", permission: "sales.view_profit" },
  { key: "effective_return_net_profit_adjustment", label: "أثر المرتجعات الحالي على الربح", format: "money", permission: "sales.view_profit" },
  { key: "effective_net_sales_profit", label: "صافي الربح الفعلي (بعد أثر المرتجعات الحالي)", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const ITEMS_COLUMNS: ReportColumnConfig[] = [
  { key: "item_name", label: "الصنف", format: "text" },
  { key: "sku", label: "SKU", format: "text", hiddenOnSmall: true },
  { key: "category_label", label: "الفئة", format: "text", hiddenOnSmall: true },
  { key: "karat_label", label: "العيار", format: "text", hiddenOnSmall: true },
  { key: "units_sold", label: "الكمية المباعة", format: "int" },
  { key: "weight_grams", label: "الوزن", format: "weight" },
  { key: "revenue", label: "الإيراد", format: "money" },
  { key: "gross_profit", label: "إجمالي الربح", format: "money", permission: "sales.view_profit" },
];
export const ITEMS_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "items_count", label: "عدد الأصناف المختلفة", format: "int" },
  { key: "units_sold", label: "الكمية المباعة", format: "int" },
  { key: "weight_grams", label: "إجمالي الوزن", format: "weight" },
  { key: "revenue", label: "إجمالي الإيراد", format: "money" },
  { key: "gross_profit", label: "إجمالي الربح", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const CATEGORIES_COLUMNS: ReportColumnConfig[] = [
  { key: "category_label", label: "الفئة", format: "text" },
  { key: "category_code", label: "الرمز", format: "text", hiddenOnSmall: true },
  // Hotfix 8.1.1 §41-42 — category hierarchy (0211's parent_id chain, wired
  // in now): the immediate parent's label and this category's depth in the
  // tree, alongside the existing p_parent_id drill-down filter below.
  { key: "parent_category_label", label: "الفئة الأصل", format: "text", hiddenOnSmall: true },
  { key: "category_depth", label: "المستوى", format: "int", hiddenOnSmall: true },
  { key: "orders_count", label: "عدد الطلبات", format: "int", hiddenOnSmall: true },
  { key: "items_count", label: "عدد الأصناف", format: "int" },
  { key: "weight_grams", label: "الوزن", format: "weight" },
  { key: "revenue", label: "الإيراد", format: "money" },
  { key: "gross_profit", label: "إجمالي الربح", format: "money", permission: "sales.view_profit" },
];
export const CATEGORIES_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "categories_count", label: "عدد الفئات", format: "int" },
  { key: "items_count", label: "عدد الأصناف", format: "int" },
  { key: "weight_grams", label: "إجمالي الوزن", format: "weight" },
  { key: "revenue", label: "إجمالي الإيراد", format: "money" },
  { key: "gross_profit", label: "إجمالي الربح", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const KARATS_COLUMNS: ReportColumnConfig[] = [
  { key: "karat_label", label: "العيار", format: "text" },
  { key: "karat_code", label: "الرمز", format: "text", hiddenOnSmall: true },
  { key: "orders_count", label: "عدد الطلبات", format: "int", hiddenOnSmall: true },
  { key: "items_count", label: "عدد الأصناف", format: "int" },
  { key: "weight_grams", label: "الوزن", format: "weight" },
  { key: "revenue", label: "الإيراد", format: "money" },
  { key: "gross_profit", label: "إجمالي الربح", format: "money", permission: "sales.view_profit" },
];
export const KARATS_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "karats_count", label: "عدد العيارات", format: "int" },
  { key: "items_count", label: "عدد الأصناف", format: "int" },
  { key: "weight_grams", label: "إجمالي الوزن", format: "weight" },
  { key: "revenue", label: "إجمالي الإيراد", format: "money" },
  { key: "gross_profit", label: "إجمالي الربح", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const EMPLOYEES_COLUMNS: ReportColumnConfig[] = [
  { key: "employee_name", label: "الموظف", format: "text" },
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "items_count", label: "عدد الأصناف", format: "int", hiddenOnSmall: true },
  { key: "weight_grams", label: "الوزن", format: "weight", hiddenOnSmall: true },
  { key: "revenue", label: "الإيراد", format: "money" },
  // Hotfix 8.1.1 §39-40 — returns attribution, strictly by the salesperson's
  // OWN Sales Cohort (0210, never a return's approver/creator, §40).
  // returns_count is operational (no permission gate); the value/profit
  // fields require sales.view_profit like every other money figure here.
  { key: "returns_count", label: "عدد المرتجعات", format: "int", hiddenOnSmall: true },
  { key: "returned_value_effective", label: "قيمة المرتجعات الفعلية الحالية", format: "money", permission: "sales.view_profit", hiddenOnSmall: true },
  { key: "effective_net_sales_profit", label: "صافي الربح الفعلي", format: "money", permission: "sales.view_profit" },
];
export const EMPLOYEES_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "employees_count", label: "عدد الموظفين", format: "int" },
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "revenue", label: "إجمالي الإيراد", format: "money" },
  { key: "average_order_value", label: "متوسط قيمة الطلب", format: "money" },
  { key: "returns_count", label: "عدد المرتجعات", format: "int" },
  { key: "returned_value_effective", label: "قيمة المرتجعات الفعلية الحالية", format: "money", permission: "sales.view_profit" },
  { key: "effective_net_sales_profit", label: "صافي الربح الفعلي", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const PAYMENT_METHODS_COLUMNS: ReportColumnConfig[] = [
  { key: "payment_method_name", label: "طريقة الدفع", format: "text" },
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "revenue", label: "الإيراد", format: "money" },
  { key: "payment_fees", label: "رسوم الدفع", format: "money", hiddenOnSmall: true, permission: "sales.view_profit" },
  { key: "net_sales_profit", label: "صافي الربح", format: "money", permission: "sales.view_profit" },
];
export const PAYMENT_METHODS_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "payment_methods_count", label: "عدد طرق الدفع", format: "int" },
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "revenue", label: "إجمالي الإيراد", format: "money" },
  { key: "net_sales_profit", label: "صافي الربح", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const COLLECTION_CHANNELS_COLUMNS: ReportColumnConfig[] = [
  { key: "collection_channel_name", label: "قناة التحصيل", format: "text" },
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "revenue", label: "الإيراد", format: "money" },
  { key: "net_sales_profit", label: "صافي الربح", format: "money", permission: "sales.view_profit" },
];
export const COLLECTION_CHANNELS_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "collection_channels_count", label: "عدد القنوات", format: "int" },
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "revenue", label: "إجمالي الإيراد", format: "money" },
  { key: "net_sales_profit", label: "صافي الربح", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const RETURNS_COLUMNS: ReportColumnConfig[] = [
  { key: "return_number", label: "رقم المرتجع", format: "text" },
  { key: "order_number", label: "رقم الطلب", format: "text", hiddenOnSmall: true },
  { key: "movement_date", label: "التاريخ", format: "date" },
  { key: "movement_type", label: "نوع الحركة", format: "badge", labelMap: MOVEMENT_TYPE_LABELS_AR, badgeVariant: (v) => (v === "approved" ? "success" : "destructive") },
  { key: "store_name", label: "المتجر", format: "text", hiddenOnSmall: true },
  { key: "scenario", label: "السبب", format: "text", labelMap: RETURNS_SCENARIO_LABELS_AR, hiddenOnSmall: true },
  { key: "refund_effect", label: "أثر الاسترداد", format: "money" },
  { key: "net_profit_effect", label: "أثر صافي الربح", format: "money", permission: "sales.view_profit" },
];
export const RETURNS_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "movements_count", label: "عدد الحركات", format: "int" },
  { key: "approved_count", label: "حركات اعتماد", format: "int" },
  { key: "reversed_count", label: "حركات عكس", format: "int" },
  { key: "refund_effect", label: "أثر الاسترداد", format: "money" },
  { key: "revenue_effect", label: "أثر الإيراد", format: "money", permission: "sales.view_profit" },
  { key: "net_profit_effect", label: "أثر صافي الربح", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const SHIPPING_COLUMNS: ReportColumnConfig[] = [
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
  { key: "net_shipping_result", label: "صافي نتيجة الشحن", format: "money", permission: "sales.view_profit" },
];
export const SHIPPING_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "shipments_count", label: "عدد الشحنات", format: "int" },
  { key: "customer_shipping_charge", label: "رسوم العملاء", format: "money" },
  { key: "actual_carrier_cost", label: "تكلفة الناقل الفعلية", format: "money", permission: "sales.view_profit" },
  { key: "net_shipping_result", label: "صافي نتيجة الشحن", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const COD_COLUMNS: ReportColumnConfig[] = [
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
];
export const COD_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "shipments_count", label: "عدد الشحنات", format: "int" },
  { key: "collected_count", label: "تم تحصيلها", format: "int" },
  { key: "not_collected_count", label: "لم تُحصّل", format: "int" },
  { key: "pending_count", label: "قيد الانتظار", format: "int" },
  { key: "cod_expected_amount", label: "إجمالي المتوقع", format: "money", permission: "sales.view_profit" },
  { key: "cod_collected_amount", label: "إجمالي المحصّل", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const ADJUSTMENTS_COLUMNS: ReportColumnConfig[] = [
  { key: "adjustment_number", label: "رقم التعديل", format: "text" },
  { key: "order_number", label: "رقم الطلب", format: "text", hiddenOnSmall: true },
  { key: "movement_date", label: "التاريخ", format: "date" },
  { key: "movement_type", label: "نوع الحركة", format: "badge", labelMap: MOVEMENT_TYPE_LABELS_AR, badgeVariant: (v) => (v === "approved" ? "success" : "destructive") },
  { key: "store_name", label: "المتجر", format: "text", hiddenOnSmall: true },
  { key: "adjustment_type_label", label: "نوع الخدمة", format: "text", hiddenOnSmall: true },
  { key: "customer_charge_effect", label: "أثر رسوم العميل", format: "money" },
  { key: "net_profit_effect", label: "أثر صافي الربح", format: "money", permission: "sales.view_profit" },
];
export const ADJUSTMENTS_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "movements_count", label: "عدد الحركات", format: "int" },
  { key: "approved_count", label: "حركات اعتماد", format: "int" },
  { key: "reversed_count", label: "حركات عكس", format: "int" },
  { key: "customer_charge_effect", label: "أثر رسوم العميل", format: "money" },
  { key: "gross_profit_effect", label: "أثر إجمالي الربح", format: "money", permission: "sales.view_profit" },
  { key: "net_profit_effect", label: "أثر صافي الربح", format: "money", emphasize: true, permission: "sales.view_profit" },
];

export const SETTLEMENTS_COLUMNS: ReportColumnConfig[] = [
  { key: "settlement_number", label: "رقم الدفعة", format: "text" },
  { key: "route_name", label: "المسار", format: "text" },
  { key: "settlement_date", label: "التاريخ", format: "date" },
  // Hotfix 8.1.2 §40 — was `status`/SETTLEMENT_STATUS_LABELS_AR, which has
  // NO Arabic label at all for 'draft' (only finalized/reconciled) — a
  // draft batch (p_effective_status='draft', 0218/0220) rendered with an
  // unmapped raw English value. `effective_status` (already computed by the
  // RPC, `case when is_cancelled then 'cancelled' else status end`) covers
  // all four real states and is the SAME field the Effective Status filter
  // itself already matches against.
  { key: "effective_status", label: "الحالة الفعلية", format: "badge", labelMap: SETTLEMENT_EFFECTIVE_STATUS_LABELS_AR, badgeVariant: (v) => (v === "reconciled" ? "success" : v === "cancelled" ? "destructive" : v === "draft" ? "secondary" : "accent") },
  { key: "is_cancelled", label: "ملغاة؟", format: "badge", labelMap: { true: "ملغاة", false: "سارية" }, badgeVariant: (v) => (v === true || v === "true" ? "destructive" : "secondary") },
  { key: "expected_bank_settlement", label: "المتوقع", format: "money", hiddenOnSmall: true, permission: "settlements.view_financials" },
  { key: "live_actual", label: "الفعلي الحالي", format: "money", permission: "settlements.view_financials" },
  { key: "live_variance", label: "الفرق", format: "money", permission: "settlements.view_financials" },
];
export const SETTLEMENTS_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "batches_count", label: "عدد الدفعات", format: "int" },
  { key: "cancelled_count", label: "الدفعات الملغاة", format: "int" },
  { key: "variance_count", label: "دفعات بها فروقات", format: "int", permission: "settlements.view_financials" },
  { key: "expected", label: "المتوقع بنكيًا", format: "money", permission: "settlements.view_financials" },
  { key: "actual", label: "الفعلي البنكي", format: "money", permission: "settlements.view_financials" },
  { key: "variance", label: "الفرق", format: "money", emphasize: true, permission: "settlements.view_financials" },
];

// Phase 10 — Store Expenses. Every monetary column is TEXT straight from
// list_store_expenses() (0235); `amount` is signed, so a reversal row renders
// negative and the summary's operating_expenses_total is already net.
export const EXPENSES_COLUMNS: ReportColumnConfig[] = [
  { key: "expense_number", label: "رقم المصروف", format: "text" },
  { key: "business_date", label: "التاريخ", format: "date" },
  { key: "store_name", label: "الفرع", format: "text" },
  { key: "category_name", label: "التصنيف", format: "text" },
  { key: "entry_kind", label: "نوع الحركة", format: "text" },
  { key: "amount", label: "المبلغ", format: "money" },
  { key: "description", label: "الوصف", format: "text", hiddenOnSmall: true },
];
export const EXPENSES_SUMMARY_FIELDS: SummaryFieldConfig[] = [
  { key: "entries_count", label: "عدد الحركات", format: "int" },
  { key: "gross_expenses_total", label: "إجمالي المصروفات", format: "money" },
  { key: "reversals_total", label: "إجمالي العكوسات", format: "money" },
  { key: "operating_expenses_total", label: "صافي المصروفات التشغيلية", format: "money", emphasize: true },
];

export const TABLE_REPORTS: Record<string, TableReportDefinition> = {
  sales: {
    slug: "sales",
    titleAr: "تقرير المبيعات",
    descriptionAr: "تفاصيل طلبات البيع خلال الفترة المحددة — القيم المالية مقروءة مباشرة من بيانات الطلب المخزّنة، دون إعادة احتساب.",
    columns: SALES_COLUMNS,
    summaryFields: SALES_SUMMARY_FIELDS,
    rowKey: "order_id",
    domainPermission: "sales.view",
    extraFilterKeys: ["employee_id", "category_id", "karat_id", "payment_method_id", "collection_channel_id"],
    fetch: (f) => getSalesReport(f as Parameters<typeof getSalesReport>[0]),
  },
  items: {
    slug: "items",
    titleAr: "تقرير الأصناف",
    descriptionAr: "ترتيب الأصناف المباعة خلال الفترة حسب الإيراد والوزن — مجمّعة حسب الفئة والعيار والاسم/الرمز.",
    columns: ITEMS_COLUMNS,
    summaryFields: ITEMS_SUMMARY_FIELDS,
    rowKey: "__row_index__",
    domainPermission: "sales.view",
    // Hotfix 8.1.2 §34-36 — salesperson_id added.
    extraFilterKeys: ["category_id", "karat_id", "salesperson_id"],
    fetch: (f) => getItemsReport(f as Parameters<typeof getItemsReport>[0]),
  },
  categories: {
    slug: "categories",
    titleAr: "تقرير الفئات",
    descriptionAr: "أداء المبيعات مجمّعًا حسب فئة المنتج خلال الفترة.",
    columns: CATEGORIES_COLUMNS,
    summaryFields: CATEGORIES_SUMMARY_FIELDS,
    rowKey: "category_id",
    domainPermission: "sales.view",
    // Hotfix 8.1.1 §41-42 — parent_id drill-down filter (0211).
    extraFilterKeys: ["karat_id", "parent_id"],
    fetch: (f) => getCategoriesReport(f as Parameters<typeof getCategoriesReport>[0]),
  },
  karats: {
    slug: "karats",
    titleAr: "تقرير العيارات",
    descriptionAr: "أداء المبيعات مجمّعًا حسب عيار الذهب خلال الفترة.",
    columns: KARATS_COLUMNS,
    summaryFields: KARATS_SUMMARY_FIELDS,
    rowKey: "karat_id",
    domainPermission: "sales.view",
    extraFilterKeys: ["category_id"],
    fetch: (f) => getKaratsReport(f as Parameters<typeof getKaratsReport>[0]),
  },
  employees: {
    slug: "employees",
    titleAr: "تقرير الموظفين",
    descriptionAr: "أداء المبيعات لكل موظف بيع خلال الفترة.",
    columns: EMPLOYEES_COLUMNS,
    summaryFields: EMPLOYEES_SUMMARY_FIELDS,
    rowKey: "employee_id",
    domainPermission: "sales.view",
    extraFilterKeys: [],
    fetch: (f) => getEmployeesReport(f),
  },
  "payment-methods": {
    slug: "payment-methods",
    titleAr: "تقرير طرق الدفع",
    descriptionAr: "توزيع المبيعات خلال الفترة حسب طريقة الدفع — تقرير متعدد الأقسام: المبيعات، الاسترداد النقدي الفعلي، والتسويات البنكية، كل قسم بصلاحيته الخاصة.",
    columns: PAYMENT_METHODS_COLUMNS,
    summaryFields: PAYMENT_METHODS_SUMMARY_FIELDS,
    rowKey: "payment_method_id",
    // Hotfix 8.1.1 §8 CRITICAL — the RPC (0207) is deliberately designed so
    // the BASE gate is reports.view alone; each of the three sections
    // (Sales/Refund Cash/Settlements) is independently gated INSIDE the SQL
    // by its own domain permission (sales.view / returns.view /
    // settlements.view+settlements.view_financials) via true key-absence
    // (§79). The previous `domainPermission: "sales.view"` here contradicted
    // that — it made the page/export 403 for an actor with e.g.
    // returns.view alone, who the RPC itself was already designed to let
    // see the Refund Cash section. Fixed to the RPC's own actual base gate.
    domainPermission: "reports.view",
    // Hotfix 8.1.3 §B2 — `payment_method_id` (the SALE's own / the
    // settlement route's own payment method, 0225's `p_payment_method_id`,
    // distinct from the Actual Refund Cash section's `refund_method_id`) is
    // offered by the screen's own filter bar and forwarded verbatim by the
    // export buttons, but was missing here — so the export silently dropped
    // it and produced a DIFFERENT dataset from the screen it was exported
    // from (§39/§44 export/screen parity). Every key listed here is what
    // route.ts copies out of the query string into the RPC filters.
    extraFilterKeys: ["payment_method_id", "refund_method_id", "collection_channel_id"],
    fetch: (f) => getPaymentMethodsReport(f),
  },
  "collection-channels": {
    slug: "collection-channels",
    titleAr: "تقرير قنوات التحصيل",
    descriptionAr: "توزيع المبيعات خلال الفترة حسب قناة التحصيل.",
    columns: COLLECTION_CHANNELS_COLUMNS,
    summaryFields: COLLECTION_CHANNELS_SUMMARY_FIELDS,
    rowKey: "collection_channel_id",
    domainPermission: "sales.view",
    extraFilterKeys: [],
    fetch: (f) => getCollectionChannelsReport(f),
  },
  returns: {
    slug: "returns",
    titleAr: "تقرير المرتجعات",
    descriptionAr: "سجل حركات المرتجعات (اعتماد وعكس) خلال الفترة — كل حركة بتاريخها الفعلي الخاص، وليس تاريخ إنشاء السجل.",
    columns: RETURNS_COLUMNS,
    summaryFields: RETURNS_SUMMARY_FIELDS,
    rowKey: "__row_index__",
    domainPermission: "returns.view",
    hasBasis: true,
    extraFilterKeys: [
      "scenario",
      "status",
      "payment_method_id",
      "collection_channel_id",
      "basis",
      "refund_method_id",
      "salesperson_id",
      "original_sale_date_from",
      "original_sale_date_to",
      "refund_reconciliation_state",
    ],
    fetch: (f) => getReturnsReport(f as Parameters<typeof getReturnsReport>[0]),
  },
  shipping: {
    slug: "shipping",
    titleAr: "تقرير الشحن",
    descriptionAr: "تفاصيل الشحنات وتكاليف الناقل خلال الفترة.",
    columns: SHIPPING_COLUMNS,
    summaryFields: SHIPPING_SUMMARY_FIELDS,
    rowKey: "shipment_id",
    domainPermission: "shipments.view",
    hasBasis: true,
    extraFilterKeys: ["carrier_id", "current_status", "shipping_zone_id", "direction", "is_cod", "basis"],
    booleanFilterKeys: ["is_cod"],
    fetch: (f) => getShippingReport(f as Parameters<typeof getShippingReport>[0]),
  },
  cod: {
    slug: "cod",
    titleAr: "تقرير الدفع عند الاستلام",
    descriptionAr: "حالة تحصيل شحنات الدفع عند الاستلام (COD) خلال الفترة.",
    columns: COD_COLUMNS,
    summaryFields: COD_SUMMARY_FIELDS,
    rowKey: "shipment_id",
    domainPermission: "shipments.view",
    hasBasis: true,
    extraFilterKeys: ["cod_collection_state", "basis"],
    fetch: (f) => getCodReport(f as Parameters<typeof getCodReport>[0]),
  },
  adjustments: {
    slug: "adjustments",
    titleAr: "تقرير التعديلات والخدمات",
    descriptionAr: "سجل حركات التعديلات (اعتماد وعكس) خلال الفترة.",
    columns: ADJUSTMENTS_COLUMNS,
    summaryFields: ADJUSTMENTS_SUMMARY_FIELDS,
    rowKey: "__row_index__",
    domainPermission: "adjustments.view",
    hasBasis: true,
    // Hotfix 8.1.1 §32-35 — complete filter set (0215): original sale store
    // vs. processing store are independent (§33, never OR-merged);
    // participates_in_settlement is a real end-to-end typed boolean (§34,
    // hence listed in booleanFilterKeys below so `false` is never dropped).
    extraFilterKeys: [
      "adjustment_type_id",
      "original_sale_store_id",
      "processing_store_id",
      "payment_method_id",
      "collection_channel_id",
      "participates_in_settlement",
      "movement_type",
      "created_by",
      "approved_by",
    ],
    booleanFilterKeys: ["participates_in_settlement"],
    fetch: (f) => getAdjustmentsReport(f as Parameters<typeof getAdjustmentsReport>[0]),
  },
  expenses: {
    slug: "expenses",
    titleAr: "تقرير مصروفات الفروع",
    descriptionAr: "المصروفات التشغيلية المسجَّلة خلال الفترة لكل فرع وتصنيف — سجل إضافي فقط، وحركات العكس تظهر بمبالغ سالبة تُصافي أصلها.",
    columns: EXPENSES_COLUMNS,
    summaryFields: EXPENSES_SUMMARY_FIELDS,
    rowKey: "id",
    domainPermission: "expenses.view",
    extraFilterKeys: ["expense_category_id", "entry_kind"],
    // getStoreExpenses() returns a precisely-typed StoreExpensesEnvelope for
    // the screen; the export pipeline consumes the generic ReportEnvelope
    // shape (Record<string, unknown> rows, since it renders columns by key).
    // The two are structurally identical — this cast is the boundary between
    // the strict read model and the generic renderer, nothing more.
    fetch: async (f) => (await getStoreExpenses(f as Parameters<typeof getStoreExpenses>[0])) as unknown as ReportEnvelope,
  },
  settlements: {
    slug: "settlements",
    titleAr: "تقرير التسويات البنكية",
    descriptionAr: "دفعات التسوية خلال الفترة — المتوقع مقابل الفعلي البنكي والفرق، مستقلة تمامًا عن حساب ربح المبيعات.",
    columns: SETTLEMENTS_COLUMNS,
    summaryFields: SETTLEMENTS_SUMMARY_FIELDS,
    rowKey: "settlement_batch_id",
    domainPermission: "settlements.view",
    hasDualBasis: true,
    extraFilterKeys: [
      "settlement_route_id",
      "status",
      "route_kind",
      "payment_method_id",
      "collection_channel_id",
      "shipping_carrier_id",
      "effective_status",
      "has_variance",
      "provider_statement_reference",
    ],
    booleanFilterKeys: ["has_variance"],
    fetch: (f) => getSettlementsReport(f as Parameters<typeof getSettlementsReport>[0]),
  },
};

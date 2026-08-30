import "server-only";

import type { KpiFieldConfig } from "@/features/dashboard/components/kpi-section";
import type { PermissionKey } from "@/lib/permissions/constants";
import { getDailyManagementReport, getWeeklyManagementReport, getMonthlyManagementReport, getYearlyManagementReport } from "@/features/reports/queries";

/**
 * Phase 8 §34-§37/§39 — the four periodic Management Reports share ONE set
 * of KPI section field definitions (Sales/Returns/Shipping/Adjustments/
 * Settlements), reused verbatim by the daily/weekly/monthly/yearly screen
 * pages (`KpiSection`) AND by the PDF/Excel management-report export
 * generator, exactly like `report-registry.ts` does for the 12 table
 * reports.
 */
export const MANAGEMENT_SALES_FIELDS: KpiFieldConfig[] = [
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "sales_revenue", label: "الإيراد", format: "money" },
  { key: "effective_net_sales_profit", label: "صافي الربح الفعلي", format: "money" },
];
export const MANAGEMENT_RETURNS_FIELDS: KpiFieldConfig[] = [
  { key: "returns_count", label: "عدد المرتجعات", format: "int", invertColor: true },
  { key: "return_financial_impact", label: "الأثر المالي", format: "money" },
];
export const MANAGEMENT_SHIPPING_FIELDS: KpiFieldConfig[] = [
  { key: "shipments_count", label: "عدد الشحنات", format: "int" },
  { key: "net_shipping_result", label: "صافي نتيجة الشحن", format: "money" },
];
export const MANAGEMENT_ADJUSTMENTS_FIELDS: KpiFieldConfig[] = [
  { key: "adjustments_count", label: "عدد التعديلات", format: "int" },
  { key: "net_adjustments_result", label: "صافي الربح", format: "money" },
];
export const MANAGEMENT_SETTLEMENTS_FIELDS: KpiFieldConfig[] = [
  { key: "batches_count", label: "عدد الدفعات", format: "int" },
  { key: "expected", label: "المتوقع", format: "money" },
  { key: "actual", label: "الفعلي", format: "money" },
];

/** Net Operating Return formula components (§18/§20) — shared by `NetOperatingReturnCard` (screen) and the management-report PDF/Excel export. */
export const MANAGEMENT_NOR_FIELDS: { key: string; label: string }[] = [
  { key: "effective_net_sales_profit", label: "صافي ربح المبيعات الفعلي" },
  { key: "net_shipping_result", label: "صافي نتيجة الشحن" },
  { key: "net_adjustments_result", label: "صافي ربح التعديلات الفعلي" },
];

export interface ManagementSectionDefinition {
  key: "sales" | "returns" | "shipping" | "adjustments" | "settlements";
  titleAr: string;
  fields: KpiFieldConfig[];
}

export const MANAGEMENT_SECTIONS: ManagementSectionDefinition[] = [
  { key: "sales", titleAr: "المبيعات", fields: MANAGEMENT_SALES_FIELDS },
  { key: "returns", titleAr: "المرتجعات", fields: MANAGEMENT_RETURNS_FIELDS },
  { key: "shipping", titleAr: "الشحن", fields: MANAGEMENT_SHIPPING_FIELDS },
  { key: "adjustments", titleAr: "التعديلات", fields: MANAGEMENT_ADJUSTMENTS_FIELDS },
  { key: "settlements", titleAr: "التسويات", fields: MANAGEMENT_SETTLEMENTS_FIELDS },
];

export interface ManagementReportDefinition {
  slug: string;
  titleAr: string;
  domainPermission: PermissionKey;
  fetch: (dateOrRef: string | undefined, storeIds: string[] | undefined, extra?: { year?: number; month?: number }) => Promise<Record<string, unknown>>;
}

/**
 * Hotfix 8.1.2 §6-15 — the day/month breakdown array Weekly/Monthly/Yearly
 * Management Reports now carry (`breakdown`, 0222), sourced verbatim from
 * `get_dashboard_trends()` (0205) — same key set, same true-key-absence
 * redaction contract (§79) as every other report column. Shared by the
 * screen breakdown table (`ManagementBreakdownTable`) AND the PDF/Excel
 * management-report export generators, exactly like `MANAGEMENT_SECTIONS`
 * above.
 */
export const MANAGEMENT_BREAKDOWN_COLUMNS: { key: string; label: string; format: "money" | "int" }[] = [
  { key: "orders_count", label: "عدد الطلبات", format: "int" },
  { key: "sales_revenue", label: "إيراد المبيعات", format: "money" },
  { key: "effective_net_sales_profit", label: "صافي ربح المبيعات الفعلي", format: "money" },
  { key: "returns_count", label: "عدد المرتجعات", format: "int" },
  { key: "net_shipping_result", label: "صافي نتيجة الشحن", format: "money" },
  { key: "net_adjustments_result", label: "صافي نتيجة التعديلات", format: "money" },
  { key: "settlement_variance", label: "فرق التسوية البنكية", format: "money" },
  { key: "net_operating_return", label: "صافي العائد التشغيلي", format: "money" },
];

/** `breakdown_granularity` (0222) — either "day" (Weekly/Monthly) or "month" (Yearly). */
export const MANAGEMENT_BREAKDOWN_GRANULARITY_LABELS_AR: Record<string, string> = {
  day: "اليوم",
  week: "الأسبوع",
  month: "الشهر",
};

/**
 * Hotfix 8.1.2 §1/§41 — `period_preset` (0221/0222's
 * `get_dashboard_summary_with_comparison()` envelope key), used on-screen
 * and in exports to explain WHICH calendar-aware previous range a report's
 * comparison figures reflect.
 */
export const PERIOD_PRESET_LABELS_AR: Record<string, string> = {
  daily: "مقارنة بيوم مساوٍ في الطول قبله مباشرة",
  weekly: "مقارنة بكامل الأسبوع (السبت-الجمعة) السابق",
  monthly: "مقارنة بكامل الشهر الميلادي السابق",
  yearly: "مقارنة بكامل السنة الميلادية السابقة",
};

export const MANAGEMENT_REPORTS: Record<string, ManagementReportDefinition> = {
  daily: {
    slug: "daily",
    titleAr: "التقرير اليومي",
    domainPermission: "reports.view",
    fetch: (date, storeIds) => getDailyManagementReport(date, storeIds),
  },
  weekly: {
    slug: "weekly",
    titleAr: "التقرير الأسبوعي",
    domainPermission: "reports.view",
    fetch: (referenceDate, storeIds) => getWeeklyManagementReport(referenceDate, storeIds),
  },
  monthly: {
    slug: "monthly",
    titleAr: "التقرير الشهري",
    domainPermission: "reports.view",
    fetch: (_unused, storeIds, extra) => getMonthlyManagementReport(extra?.year, extra?.month, storeIds),
  },
  yearly: {
    slug: "yearly",
    titleAr: "التقرير السنوي",
    domainPermission: "reports.view",
    fetch: (_unused, storeIds, extra) => getYearlyManagementReport(extra?.year, storeIds),
  },
};

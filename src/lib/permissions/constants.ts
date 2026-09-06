/**
 * Compile-time mirror of the `permissions` catalog seeded in
 * supabase/seed.sql. Keep this array in sync with that file whenever a
 * permission is added — it exists purely to give TypeScript a literal union
 * type (PermissionKey) so `requirePermission("stroes.create")` (typo) is a
 * compile error instead of a silent always-false runtime check.
 *
 * Human-readable labels, categories, and descriptions are NOT duplicated
 * here — the Roles & Permissions UI reads those from the `permissions`
 * table at runtime (single source of truth for display copy).
 */
export const PERMISSION_KEYS = [
  "dashboard.view",
  "dashboard.view_financials",

  "stores.view",
  "stores.create",
  "stores.edit",
  "stores.disable",

  "users.view",
  "users.create",
  "users.edit",
  "users.disable",
  "users.manage_permissions",
  "users.manage_store_access",

  "reports.view",
  "reports.export_pdf",
  "reports.export_excel",

  "gold_prices.view",
  "gold_prices.edit",

  // Phase 2 (Financial Master Data, migrations 0040-0046, supabase/seed.sql)
  "karats.view",
  "karats.manage",
  "manufacturing_fees.view",
  "manufacturing_fees.manage",
  "categories.view",
  "categories.manage",
  "payment_methods.view",
  "payment_methods.manage",
  "collection_channels.view",
  "collection_channels.manage",

  // Phase 3 (Sales Core, migration 0058) — VAT rate versioning
  "vat_rates.view",
  "vat_rates.manage",

  "sales.view",
  "sales.create",
  "sales.edit",
  "sales.edit_closed_day",
  "sales.view_profit",
  // Phase 3 (Sales Core, migration 0060) — Daily Close
  "sales.close_day",

  "returns.view",
  "returns.create",
  "returns.approve",
  // Phase 4 (Returns Core, migration 0082)
  "returns.reverse",
  "returns.record_refund",
  "returns.process_closed_day",

  "settlements.view",
  "settlements.manage",
  // Phase 7 (Settlements Core, migration 0167)
  "settlements.view_financials",
  "settlements.create",
  "settlements.finalize",
  "settlements.record_bank_movement",
  "settlements.reconcile",
  "settlements.reconcile_variance",
  "settlements.cancel",
  "settlements.override_batch_fee",
  "settlements.process_closed_day",
  "settlements.manage_routes",

  "shipments.view",
  "shipments.create",
  "shipments.update_status",
  // Phase 5 (Shipping Core, migration 0113)
  "shipments.manage_cost",
  "shipments.correct_status",
  "shipments.process_closed_day",
  "shipping_rates.view",
  "shipping_rates.manage",

  "adjustments.view",
  "adjustments.create",
  "adjustments.approve",
  // Phase 6 (Services / Adjustments Core, migration 0133)
  "adjustments.manage_cost",
  "adjustments.reverse",
  "adjustments.process_closed_day",
  "adjustments.manage_types",

  // Phase 9 (Inventory Core, migration 0227)
  "inventory.view",
  "inventory.receive",
  "inventory.adjust",

  // Phase 10 (Store Expenses Core, migration 0233)
  "expenses.view",
  "expenses.create",
  "expenses.reverse",
  "expenses.manage_categories",
  "expenses.process_closed_day",

  // Phase 11 (Purchases & Suppliers Core, migration 0237)
  "purchases.view",
  "purchases.create",
  "purchases.reverse",
  "purchases.record_payment",
  "purchases.reverse_payment",
  "purchases.manage_suppliers",
  "purchases.process_closed_day",

  "audit_logs.view",

  "settings.manage",
  "backups.manage",
] as const;

export type PermissionKey = (typeof PERMISSION_KEYS)[number];

export const PERMISSION_CATEGORY_LABELS_AR: Record<string, string> = {
  dashboard: "لوحة التحكم",
  stores: "المتاجر",
  users: "المستخدمون والصلاحيات",
  reports: "التقارير",
  gold_prices: "أسعار الذهب",
  financial_master_data: "البيانات المالية الأساسية",
  sales: "المبيعات",
  returns: "المرتجعات",
  settlements: "التسويات",
  shipments: "الشحنات",
  shipping_rates: "تسعير الشحن",
  adjustments: "التعديلات والخدمات",
  inventory: "المخزون",
  audit_logs: "سجل الأحداث",
  system: "النظام",
};

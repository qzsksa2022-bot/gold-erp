/**
 * Application-wide constants.
 *
 * NOTE: Branding values here are *fallback defaults only*. The source of
 * truth for tenant-editable branding (system name, logo, accent color...)
 * is the `system_settings` table (see `src/features/settings`). Never
 * hardcode branding deeper in the component tree — always read it from the
 * settings layer so a future change in Settings propagates everywhere.
 */

export const APP_DEFAULTS = {
  nameAr: "نظام إدارة المبيعات والربحية",
  nameEn: "Gold Sales & Profitability System",
  currency: "SAR" as const,
  currencySymbolAr: "ر.س",
  timezone: "Asia/Riyadh" as const,
  locale: "ar-SA" as const,
} as const;

/** Central place for route paths used across the app (avoid magic strings). */
export const ROUTES = {
  login: "/login",
  dashboard: "/dashboard",
  stores: "/stores",
  users: "/users",
  auditLog: "/audit-log",
  settings: "/settings",
  sales: "/sales",
  salesNew: "/sales/new",
  returns: "/returns",
  returnsNew: "/returns/new",
  shipments: "/shipments",
  shipmentsNew: "/shipments/new",
  adjustments: "/adjustments",
  adjustmentsNew: "/adjustments/new",
  settlements: "/settlements",
  settlementsNew: "/settlements/new",
  // Phase 9 — Inventory Core.
  inventory: "/inventory",
  inventoryItems: "/inventory/items",
  inventoryMovements: "/inventory/movements",
  // Phase 10 — Store Expenses Core.
  expenses: "/expenses",
  expenseCategories: "/master-data/expense-categories",
  // Phase 11 — Purchases & Suppliers Core.
  purchases: "/purchases",
  purchasesNew: "/purchases/new",
  purchasesOutstanding: "/purchases/outstanding",
  suppliers: "/master-data/suppliers",
  reports: "/reports",
  // Phase 8 — Reports, Dashboard & Exports (§21-§37, migrations 0201-0204).
  reportsSales: "/reports/sales",
  reportsItems: "/reports/items",
  reportsCategories: "/reports/categories",
  reportsKarats: "/reports/karats",
  reportsEmployees: "/reports/employees",
  reportsPaymentMethods: "/reports/payment-methods",
  reportsCollectionChannels: "/reports/collection-channels",
  reportsReturns: "/reports/returns",
  reportsShipping: "/reports/shipping",
  reportsCod: "/reports/cod",
  reportsAdjustments: "/reports/adjustments",
  reportsSettlements: "/reports/settlements",
  reportsDaily: "/reports/daily",
  reportsWeekly: "/reports/weekly",
  reportsMonthly: "/reports/monthly",
  reportsYearly: "/reports/yearly",
  goldPrices: "/gold-prices",
  // Phase 2 — Financial Master Data (migrations 0040-0046)
  masterData: "/master-data",
  masterDataKarats: "/master-data/karats",
  masterDataVatRates: "/master-data/vat-rates",
  masterDataManufacturingFees: "/master-data/manufacturing-fees",
  masterDataCategories: "/master-data/categories",
  masterDataPaymentMethods: "/master-data/payment-methods",
  masterDataCollectionChannels: "/master-data/collection-channels",
  // Patch 5.1 items 19/20 — Shipping Rate/Carrier/Zone Admin UI.
  masterDataShippingRates: "/master-data/shipping-rates",
  // Phase 6 — Services / Adjustments Core, adjustment_types admin.
  masterDataAdjustmentTypes: "/master-data/adjustment-types",
  // Phase 7 — Settlements Core, settlement_routes admin.
  masterDataSettlementRoutes: "/master-data/settlement-routes",
} as const;

export const PAGE_SIZE_DEFAULT = 20;
export const PAGE_SIZE_OPTIONS = [10, 20, 50, 100] as const;

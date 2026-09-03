import type { LucideIcon } from "lucide-react";
import {
  LayoutDashboard,
  ShoppingCart,
  Undo2,
  Truck,
  Wrench,
  HandCoins,
  FileBarChart2,
  Coins,
  Store,
  Users,
  ScrollText,
  Settings,
  LibraryBig,
  Boxes,
} from "lucide-react";
import type { PermissionKey } from "@/lib/permissions/constants";
import { ROUTES } from "@/lib/constants";

export type NavItem = {
  label: string;
  href: string;
  icon: LucideIcon;
  /** Exactly one of `permission`/`anyOf` is set. `anyOf` is for a hub item whose sub-pages are each gated by a different permission (e.g. Master Data) — visible if the user holds ANY of them. */
  permission?: PermissionKey;
  anyOf?: PermissionKey[];
  comingSoon?: boolean;
};

/**
 * Single source of truth for the primary navigation — consumed by both the
 * desktop Sidebar and the mobile drawer, so the two never drift apart.
 * `comingSoon` items still enforce their permission (only shown to users
 * who WILL be able to use the feature once built) but render the
 * lightweight "قريبًا" placeholder page instead of 404.
 */
export const NAV_ITEMS: NavItem[] = [
  { label: "الرئيسية", href: ROUTES.dashboard, icon: LayoutDashboard, permission: "dashboard.view" },
  { label: "المبيعات", href: ROUTES.sales, icon: ShoppingCart, permission: "sales.view" },
  { label: "المرتجعات", href: ROUTES.returns, icon: Undo2, permission: "returns.view" },
  { label: "الشحنات", href: ROUTES.shipments, icon: Truck, permission: "shipments.view", comingSoon: true },
  { label: "التعديلات والخدمات", href: ROUTES.adjustments, icon: Wrench, permission: "adjustments.view" },
  { label: "التسويات", href: ROUTES.settlements, icon: HandCoins, permission: "settlements.view" },
  { label: "المخزون", href: ROUTES.inventory, icon: Boxes, permission: "inventory.view" },
  { label: "التقارير", href: ROUTES.reports, icon: FileBarChart2, permission: "reports.view" },
  { label: "أسعار الذهب", href: ROUTES.goldPrices, icon: Coins, permission: "gold_prices.view" },
  {
    label: "البيانات الأساسية",
    href: ROUTES.masterData,
    icon: LibraryBig,
    anyOf: [
      "karats.view",
      "manufacturing_fees.view",
      "categories.view",
      "payment_methods.view",
      "collection_channels.view",
      "shipping_rates.view",
      "adjustments.manage_types",
      "settlements.manage_routes",
    ],
  },
  { label: "المتاجر", href: ROUTES.stores, icon: Store, permission: "stores.view" },
  { label: "المستخدمون والصلاحيات", href: ROUTES.users, icon: Users, permission: "users.view" },
  { label: "سجل الأحداث", href: ROUTES.auditLog, icon: ScrollText, permission: "audit_logs.view" },
  { label: "الإعدادات", href: ROUTES.settings, icon: Settings, permission: "settings.manage" },
];

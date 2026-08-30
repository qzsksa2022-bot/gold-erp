import Link from "next/link";
import type { LucideIcon } from "lucide-react";
import {
  ShoppingCart,
  Package,
  LibraryBig,
  Gem,
  Users,
  CreditCard,
  Share2,
  Undo2,
  Truck,
  Banknote,
  Wrench,
  HandCoins,
  CalendarDays,
  CalendarRange,
  Calendar,
  CalendarClock,
} from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { PageHeader } from "@/components/shared/page-header";
import { ROUTES } from "@/lib/constants";
import type { PermissionKey } from "@/lib/permissions/constants";
import { sessionHasPermission } from "@/lib/permissions/session";

interface ReportCardConfig {
  href: string;
  title: string;
  description: string;
  icon: LucideIcon;
  /** Single-permission gate — the common case (one section, one permission). */
  permission?: PermissionKey;
  /**
   * Hotfix 8.1.2 §26-27 — OR-of-AND-groups gate for a card whose target
   * report has multiple INDEPENDENTLY-gated sections (e.g. Payment
   * Methods: Sales/sales.view, Actual Refund Cash/returns.view,
   * Settlements/settlement.view) and must stay visible to an actor holding
   * ANY one of them — not just whichever permission happens to gate the
   * first section. Each inner array is an AND-group (every permission in
   * it must hold); the outer array is OR (any one group is enough). Takes
   * precedence over `permission` when both are set.
   */
  anyOf?: PermissionKey[][];
}

function cardVisible(session: Parameters<typeof sessionHasPermission>[0], card: ReportCardConfig): boolean {
  if (card.anyOf) return card.anyOf.some((group) => group.every((p) => sessionHasPermission(session, p)));
  return card.permission ? sessionHasPermission(session, card.permission) : true;
}

interface ReportGroupConfig {
  title: string;
  cards: ReportCardConfig[];
}

const REPORT_GROUPS: ReportGroupConfig[] = [
  {
    title: "المبيعات",
    cards: [
      { href: ROUTES.reportsSales, title: "تقرير المبيعات", description: "تفاصيل طلبات البيع مع الفلاتر والإجماليات.", icon: ShoppingCart, permission: "sales.view" },
      { href: ROUTES.reportsItems, title: "تقرير الأصناف", description: "ترتيب الأصناف المباعة حسب الإيراد والوزن.", icon: Package, permission: "sales.view" },
      { href: ROUTES.reportsCategories, title: "تقرير الفئات", description: "أداء المبيعات مجمّعًا حسب فئة المنتج.", icon: LibraryBig, permission: "sales.view" },
      { href: ROUTES.reportsKarats, title: "تقرير العيارات", description: "أداء المبيعات مجمّعًا حسب عيار الذهب.", icon: Gem, permission: "sales.view" },
      { href: ROUTES.reportsEmployees, title: "تقرير الموظفين", description: "أداء المبيعات لكل موظف بيع.", icon: Users, permission: "sales.view" },
      {
        // Hotfix 8.1.2 §26-27 — visible to ANY of the report's three
        // independently-gated sections (Sales/Refund Cash/Settlements),
        // not just the Sales one — an actor with only returns.view (say)
        // can still open this report and see its Refund Cash section.
        href: ROUTES.reportsPaymentMethods,
        title: "تقرير طرق الدفع",
        description: "توزيع المبيعات والاسترداد الفعلي والتسويات البنكية حسب طريقة الدفع.",
        icon: CreditCard,
        anyOf: [["sales.view"], ["returns.view"], ["settlements.view"]],
      },
      { href: ROUTES.reportsCollectionChannels, title: "تقرير قنوات التحصيل", description: "توزيع المبيعات حسب قناة التحصيل.", icon: Share2, permission: "sales.view" },
    ],
  },
  {
    title: "المرتجعات والشحن",
    cards: [
      { href: ROUTES.reportsReturns, title: "تقرير المرتجعات", description: "سجل حركات المرتجعات (اعتماد وعكس) خلال الفترة.", icon: Undo2, permission: "returns.view" },
      { href: ROUTES.reportsShipping, title: "تقرير الشحن", description: "تفاصيل الشحنات وتكاليف الناقل.", icon: Truck, permission: "shipments.view" },
      { href: ROUTES.reportsCod, title: "تقرير الدفع عند الاستلام", description: "حالة تحصيل شحنات الدفع عند الاستلام.", icon: Banknote, permission: "shipments.view" },
    ],
  },
  {
    title: "التعديلات والتسويات",
    cards: [
      { href: ROUTES.reportsAdjustments, title: "تقرير التعديلات والخدمات", description: "سجل حركات التعديلات (اعتماد وعكس) خلال الفترة.", icon: Wrench, permission: "adjustments.view" },
      { href: ROUTES.reportsSettlements, title: "تقرير التسويات البنكية", description: "دفعات التسوية مع المتوقع والفعلي والفرق.", icon: HandCoins, permission: "settlements.view" },
    ],
  },
  {
    title: "التقارير الدورية",
    cards: [
      { href: ROUTES.reportsDaily, title: "التقرير اليومي", description: "ملخص إداري شامل ليوم عمل واحد.", icon: CalendarDays, permission: "reports.view" },
      { href: ROUTES.reportsWeekly, title: "التقرير الأسبوعي", description: "ملخص إداري شامل لأسبوع (السبت–الجمعة).", icon: CalendarRange, permission: "reports.view" },
      { href: ROUTES.reportsMonthly, title: "التقرير الشهري", description: "ملخص إداري شامل لشهر ميلادي كامل.", icon: Calendar, permission: "reports.view" },
      { href: ROUTES.reportsYearly, title: "التقرير السنوي", description: "ملخص إداري شامل لسنة كاملة.", icon: CalendarClock, permission: "reports.view" },
    ],
  },
];

export default async function ReportsPage() {
  const session = await requirePermission("reports.view");

  const visibleGroups = REPORT_GROUPS.map((group) => ({
    ...group,
    cards: group.cards.filter((card) => cardVisible(session, card)),
  })).filter((group) => group.cards.length > 0);

  return (
    <div>
      <PageHeader title="التقارير" description="طبقة الذكاء الإداري — تقارير مالية وتشغيلية مبنية على بيانات المصدر المعتمدة، دون أي إعادة احتساب." />

      {visibleGroups.map((group) => (
        <div key={group.title} className="mb-8">
          <h2 className="mb-3 text-sm font-semibold text-muted-foreground">{group.title}</h2>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {group.cards.map((card) => (
              <Link
                key={card.href}
                href={card.href}
                className="group flex items-start gap-3 rounded-xl border border-border bg-card p-4 transition-colors hover:border-accent/40 hover:bg-accent/5"
              >
                <div className="flex size-10 shrink-0 items-center justify-center rounded-lg bg-secondary text-muted-foreground group-hover:bg-accent/15 group-hover:text-accent">
                  <card.icon className="size-5" />
                </div>
                <div>
                  <p className="text-sm font-semibold">{card.title}</p>
                  <p className="mt-0.5 text-xs text-muted-foreground">{card.description}</p>
                </div>
              </Link>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

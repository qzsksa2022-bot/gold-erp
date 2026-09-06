import { AlertTriangle } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { getDashboardStats, getDashboardSummaryWithExpenses, getDashboardTrends } from "@/features/dashboard/queries";
import { getReportVisibleStores } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { StatCard } from "@/features/dashboard/components/stat-card";
import { RecentActivity } from "@/features/dashboard/components/recent-activity";
import { QuickActions } from "@/features/dashboard/components/quick-actions";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { KpiSection } from "@/features/dashboard/components/kpi-section";
import { NetOperatingReturnCard } from "@/features/dashboard/components/net-operating-return-card";
import { TrendChart, type TrendValueFormat } from "@/features/dashboard/components/trend-chart";
import { PeriodPresets } from "@/features/dashboard/components/period-presets";
import { resolveDashboardPeriodPreset } from "@/features/dashboard/period-presets";
import { riyadhTodayIsoDate } from "@/lib/date";
import { Users, Store, CheckCircle2 } from "lucide-react";

/**
 * Hotfix 8.1.3 §4 — the Dashboard's default range. Month start → today is
 * byte-for-byte `buildPresets()`'s own `this_month` from/to, which is
 * exactly what makes `resolveDashboardPeriodPreset()` resolve the
 * no-query-params case to `this_month` (and therefore compare against the
 * FULL previous calendar month) rather than to `custom`.
 */
function currentMonthStart(): string {
  const today = riyadhTodayIsoDate();
  return `${today.slice(0, 7)}-01`;
}

/**
 * Patch 8.1 §43-46 — Dashboard Trend Set. get_dashboard_trends() (0205)
 * already computes every one of these per bucket, permission-gated
 * key-by-key (§79) exactly like KpiSection's own fields — but only
 * `net_operating_return` was ever rendered. `TrendChart` itself already
 * self-hides via `!(valueKey in buckets[0])`, so listing every metric here
 * unconditionally is safe: a viewer without e.g. sales.view_profit simply
 * never sees the `effective_net_sales_profit` chart, the same true-absence
 * contract as everywhere else in Reports/Dashboard.
 */
const SECONDARY_TREND_METRICS: { key: string; title: string; format: TrendValueFormat }[] = [
  { key: "sales_revenue", title: "اتجاه إيرادات المبيعات", format: "money" },
  { key: "effective_net_sales_profit", title: "اتجاه صافي ربح المبيعات (الفعلي)", format: "money" },
  { key: "orders_count", title: "اتجاه عدد الطلبات", format: "int" },
  { key: "returns_count", title: "اتجاه عدد المرتجعات", format: "int" },
  { key: "net_shipping_result", title: "اتجاه صافي نتيجة الشحن", format: "money" },
  { key: "net_adjustments_result", title: "اتجاه صافي ربح التعديلات", format: "money" },
  { key: "settlement_variance", title: "اتجاه فروقات التسويات البنكية", format: "money" },
];

export default async function DashboardPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requirePermission("dashboard.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");

  const dateFrom = str("date_from") || currentMonthStart();
  const dateTo = str("date_to") || riyadhTodayIsoDate();
  const storeId = str("store_id") || undefined;
  // Hotfix 8.1.3 §2-4 — never the raw `period_preset` query param: a known
  // preset key (written by the quick-period buttons) passes through, an
  // absent one (a manual date edit CLEARS it, §3) is re-derived from the
  // range itself, and an unknown/hand-crafted one is re-derived too.
  const periodPreset = resolveDashboardPeriodPreset(str("period_preset") || undefined, dateFrom, dateTo);

  const [stats, summary, trends, stores] = await Promise.all([
    getDashboardStats(),
    // Hotfix 8.1.3 §1 — the CALENDAR-AWARE wrapper (0221): "This Month" must
    // compare against the full previous calendar month, not the preceding
    // equal-length window.
    // Phase 10 — now reached through get_dashboard_summary_with_expenses()
    // (0236), which calls that same wrapper and only ADDS the expenses section
    // and the explicit before/after-expenses triad. `net_operating_return`
    // itself is carried through unchanged.
    getDashboardSummaryWithExpenses(dateFrom, dateTo, periodPreset, storeId ? [storeId] : undefined),
    getDashboardTrends(dateFrom, dateTo, storeId ? [storeId] : undefined),
    getReportVisibleStores(),
  ]);

  const sales = summary.sales as Record<string, unknown> | undefined;
  const returns = summary.returns as Record<string, unknown> | undefined;
  const shipping = summary.shipping as Record<string, unknown> | undefined;
  const adjustments = summary.adjustments as Record<string, unknown> | undefined;
  const settlements = summary.settlements as Record<string, unknown> | undefined;
  const nor = summary.net_operating_return as Record<string, unknown> | undefined;
  const granularityLabel = trends.granularity === "day" ? "يومي" : trends.granularity === "week" ? "أسبوعي" : "شهري";
  const containsOpenDay = summary.contains_open_business_day === true;

  return (
    <div>
      <PageHeader title="الرئيسية" description="الملخص التنفيذي — نظرة شاملة على الأداء المالي والتشغيلي للفترة المحددة." />

      <PeriodPresets dateFrom={dateFrom} dateTo={dateTo} periodPreset={periodPreset} />
      {/* Hotfix 8.1.3 §3 — editing a date by hand must not leave the
          previously-clicked preset behind in the URL: it would keep claiming
          a calendar unit the range no longer covers. */}
      <ReportFilterBar dateFrom={dateFrom} dateTo={dateTo} storeId={storeId} stores={stores} showSearch={false} dateChangeClearKeys={["period_preset"]} />

      {containsOpenDay && (
        <div className="mb-4 flex items-center gap-2 rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-xs text-warning">
          <AlertTriangle className="size-3.5 shrink-0" />
          <span>الفترة المحددة تتضمن يوم عمل واحدًا أو أكثر لم يُغلق بعد — قد تتغير الأرقام لاحقًا.</span>
        </div>
      )}

      <NetOperatingReturnCard nor={nor} />

      <KpiSection
        title="المبيعات"
        section={sales}
        fields={[
          { key: "orders_count", label: "عدد الطلبات", format: "int" },
          { key: "sales_revenue", label: "إيرادات المبيعات", format: "money" },
          { key: "gross_profit", label: "إجمالي الربح", format: "money" },
          { key: "net_sales_profit_original", label: "صافي ربح المبيعات (الأصلي)", format: "money" },
          { key: "effective_net_sales_profit", label: "صافي ربح المبيعات (الفعلي)", format: "money" },
          { key: "payment_fees", label: "رسوم الدفع", format: "money", invertColor: true },
        ]}
      />

      <KpiSection
        title="المرتجعات"
        section={returns}
        fields={[
          { key: "returns_count", label: "عدد المرتجعات", format: "int", invertColor: true },
          { key: "return_financial_impact", label: "الأثر المالي للمرتجعات", format: "money" },
          { key: "actual_refunded_cash", label: "المبالغ المستردة فعليًا", format: "money", invertColor: true },
        ]}
      />

      <KpiSection
        title="الشحن"
        section={shipping}
        fields={[
          { key: "shipments_count", label: "عدد الشحنات", format: "int" },
          { key: "customer_shipping_charges", label: "رسوم الشحن من العميل", format: "money" },
          { key: "carrier_cost_effect", label: "أثر تكلفة الناقل", format: "money", invertColor: true },
          { key: "net_shipping_result", label: "صافي نتيجة الشحن", format: "money" },
        ]}
      />

      <KpiSection
        title="التعديلات والخدمات"
        section={adjustments}
        fields={[
          { key: "adjustments_count", label: "عدد التعديلات", format: "int" },
          { key: "customer_charges", label: "رسوم العميل", format: "money" },
          { key: "direct_costs", label: "التكلفة المباشرة", format: "money", invertColor: true },
          { key: "net_adjustments_result", label: "صافي ربح التعديلات", format: "money" },
        ]}
      />

      <KpiSection
        title="التسويات البنكية"
        section={settlements}
        fields={[
          { key: "batches_count", label: "عدد دفعات التسوية", format: "int" },
          { key: "cancelled_count", label: "الدفعات الملغاة", format: "int", invertColor: true },
          { key: "variance_count", label: "دفعات بها فروقات", format: "int", invertColor: true },
          { key: "expected", label: "المتوقع بنكيًا", format: "money" },
          { key: "actual", label: "الفعلي البنكي", format: "money" },
          { key: "variance", label: "الفرق", format: "money" },
        ]}
      />

      <TrendChart buckets={trends.buckets as never} format="money" title={`اتجاه صافي العائد التشغيلي (${granularityLabel})`} />

      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2">
        {SECONDARY_TREND_METRICS.map((m) => (
          <TrendChart key={m.key} buckets={trends.buckets as never} valueKey={m.key} format={m.format} title={`${m.title} (${granularityLabel})`} />
        ))}
      </div>

      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard label="المستخدمون النشطون" value={stats.activeUsersCount} icon={Users} />
        <StatCard label="إجمالي المتاجر" value={stats.totalStoresCount} icon={Store} />
        <StatCard label="المتاجر النشطة" value={stats.activeStoresCount} icon={CheckCircle2} />
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <div className="lg:col-span-2">
          <RecentActivity items={stats.recentActivity} />
        </div>
        <QuickActions />
      </div>
    </div>
  );
}

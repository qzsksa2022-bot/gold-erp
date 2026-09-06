import "server-only";

import { createClient } from "@/lib/supabase/server";

/**
 * Phase 8 §12-§20 — Executive Summary. get_dashboard_summary() (migration
 * 0200) returns ONE atomic jsonb payload built from a single MVCC snapshot
 * (§92): current-period figures, previous-period comparison figures,
 * per-KPI diff/pct via the Comparison Engine, and the Net Operating Return
 * formula (§18). A section/field is simply ABSENT (never `null`) when the
 * caller lacks the permission that would reveal it (§79) — component code
 * must check `"field" in section`, not `section.field == null`.
 */
export async function getDashboardSummary(dateFrom: string, dateTo: string, storeIds?: string[]) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_dashboard_summary", {
    p_date_from: dateFrom,
    p_date_to: dateTo,
    p_store_ids: storeIds ?? null,
  });
  if (error) throw error;
  return data as unknown as Record<string, unknown>;
}

/**
 * Hotfix 8.1.2 §1-5 / Hotfix 8.1.3 §1 — the CALENDAR-AWARE Dashboard
 * summary. `get_dashboard_summary_with_comparison()` (migration 0221) calls
 * the canonical `get_dashboard_summary()` above exactly twice inside ONE
 * MVCC snapshot — for the caller's own range, and for the previous range
 * `report_calendar_comparison_period(p_period_preset, ...)` resolves — so a
 * `this_week`/`this_month`/`this_year` view compares against the FULL
 * previous Riyadh week / calendar month / calendar year rather than the
 * generic "immediately preceding equal-length range" `get_dashboard_summary()`
 * alone can offer.
 *
 * Returns the same jsonb shape as `getDashboardSummary()` (identical domain
 * sub-objects, identical §79 true key-absence — the wrapper only ever
 * rewrites `previous_<field>`/`<field>_change`/`<field>_pct_change` keys
 * that were ALREADY present) plus the `date_from`/`date_to`/`period_preset`/
 * `previous_date_from`/`previous_date_to`/`comparison_mode` envelope keys.
 *
 * `periodPreset` is resolved by `resolveDashboardPeriodPreset()`
 * (@/features/dashboard/period-presets) from the URL, never read raw — see
 * that function for the §2-4 rules.
 */
export async function getDashboardSummaryWithComparison(dateFrom: string, dateTo: string, periodPreset?: string, storeIds?: string[]) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_dashboard_summary_with_comparison", {
    p_date_from: dateFrom,
    p_date_to: dateTo,
    p_period_preset: periodPreset ?? null,
    p_store_ids: storeIds ?? null,
  });
  if (error) throw error;
  return data as unknown as Record<string, unknown>;
}

/**
 * Phase 10 — the EXPENSE-AWARE Dashboard summary.
 * `get_dashboard_summary_with_expenses()` (migration 0236) calls the
 * calendar-aware wrapper above and only ADDS to its result:
 *
 *   * an `expenses` section (gated on expenses.view, §79 true key-absence), and
 *   * inside `net_operating_return`, the explicit triad
 *     `operating_contribution_before_expenses` /
 *     `operating_expenses_total` / `net_operating_result_after_expenses`.
 *
 * The legacy `net_operating_return` key is carried through byte-for-byte
 * unchanged — it always meant "contribution BEFORE operating expenses" and
 * still does, so no historical figure or existing caller changes meaning.
 */
export async function getDashboardSummaryWithExpenses(dateFrom: string, dateTo: string, periodPreset?: string, storeIds?: string[]) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_dashboard_summary_with_expenses", {
    p_date_from: dateFrom,
    p_date_to: dateTo,
    p_period_preset: periodPreset ?? null,
    p_store_ids: storeIds ?? null,
  });
  if (error) throw error;
  return data as unknown as Record<string, unknown>;
}

/**
 * Phase 8 §19/§73 — Trend charts. get_dashboard_trends() (migration 0200)
 * returns `{ granularity, date_from, date_to, buckets: [...] }`, every
 * bucket zero-filled (no missing chart points) at the auto-derived
 * granularity (day/week/month, report_trend_granularity() in 0199) unless
 * `granularity` is passed explicitly.
 */
export async function getDashboardTrends(dateFrom: string, dateTo: string, storeIds?: string[], granularity?: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_dashboard_trends", {
    p_date_from: dateFrom,
    p_date_to: dateTo,
    p_store_ids: storeIds ?? null,
    p_granularity: granularity ?? null,
  });
  if (error) throw error;
  return data as unknown as { granularity: string; date_from: string; date_to: string; buckets: Record<string, unknown>[] };
}

export async function getDashboardStats() {
  const supabase = await createClient();

  const [activeUsers, totalStores, activeStores, recentLogs] = await Promise.all([
    supabase.from("profiles").select("id", { count: "exact", head: true }).eq("status", "active"),
    supabase.from("stores").select("id", { count: "exact", head: true }),
    supabase.from("stores").select("id", { count: "exact", head: true }).eq("status", "active"),
    supabase
      .from("audit_logs")
      .select("id, action, entity_type, created_at, user_id")
      .order("created_at", { ascending: false })
      .limit(8),
  ]);

  const userIds = [...new Set((recentLogs.data ?? []).map((l) => l.user_id).filter(Boolean))] as string[];
  const { data: profiles } = userIds.length
    ? await supabase.from("profiles").select("id, full_name").in("id", userIds)
    : { data: [] };
  const profileMap = new Map((profiles ?? []).map((p) => [p.id, p.full_name]));

  return {
    activeUsersCount: activeUsers.count ?? 0,
    totalStoresCount: totalStores.count ?? 0,
    activeStoresCount: activeStores.count ?? 0,
    recentActivity: (recentLogs.data ?? []).map((log) => ({
      ...log,
      actorName: log.user_id ? (profileMap.get(log.user_id) ?? "مستخدم محذوف") : "النظام",
    })),
  };
}

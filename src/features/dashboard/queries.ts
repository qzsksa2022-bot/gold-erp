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

import "server-only";

import { createClient } from "@/lib/supabase/server";

export type AuditLogFilters = {
  q?: string;
  userId?: string;
  action?: string;
  entityType?: string;
  dateFrom?: string;
  dateTo?: string;
  page: number;
  pageSize: number;
};

export async function listAuditLogs({ q, userId, action, entityType, dateFrom, dateTo, page, pageSize }: AuditLogFilters) {
  const supabase = await createClient();

  let query = supabase.from("audit_logs").select("*", { count: "exact" }).order("created_at", { ascending: false });

  if (userId) query = query.eq("user_id", userId);
  if (action) query = query.eq("action", action);
  if (entityType) query = query.eq("entity_type", entityType);
  if (dateFrom) query = query.gte("created_at", dateFrom);
  if (dateTo) query = query.lte("created_at", dateTo);
  if (q) query = query.or(`reason.ilike.%${q}%,action.ilike.%${q}%`);

  const from = (page - 1) * pageSize;
  const { data, error, count } = await query.range(from, from + pageSize - 1);
  if (error) throw error;

  const userIds = [...new Set((data ?? []).map((r) => r.user_id).filter(Boolean))] as string[];
  const { data: profiles } = userIds.length
    ? await supabase.from("profiles").select("id, full_name, email").in("id", userIds)
    : { data: [] };
  const profileMap = new Map((profiles ?? []).map((p) => [p.id, p]));

  const logs = (data ?? []).map((row) => ({
    ...row,
    actor: row.user_id ? (profileMap.get(row.user_id) ?? null) : null,
  }));

  return { logs, total: count ?? 0 };
}

/** Distinct users who have at least one audit entry, for the actor filter dropdown. */
export async function listAuditActors() {
  const supabase = await createClient();
  const { data, error } = await supabase.from("profiles").select("id, full_name").order("full_name");
  if (error) throw error;
  return data ?? [];
}

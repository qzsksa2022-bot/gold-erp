import "server-only";

import { createClient } from "@/lib/supabase/server";
import { riyadhTodayIsoDate } from "@/lib/date";
import type { Database } from "@/types/database";

type FeeVersion = Database["public"]["Tables"]["manufacturing_fee_versions"]["Row"];

/**
 * One row per karat, with CURRENT and UPCOMING resolved separately (fix for
 * Financial Integrity Patch 2.1 item 8 — the previous version of this query
 * only fetched "the open row" and the UI presented it as "current" even
 * when its effective_from was still in the future, i.e. a scheduled rate
 * nobody is actually being charged yet). A karat can have at most one
 * "open" version (effective_to IS NULL, status='active', see 0042) at any
 * time, but that open version is either:
 *   - already effective (effective_from <= today) -> it IS current, no
 *     separate upcoming version exists, or
 *   - not yet effective (effective_from > today) -> it is UPCOMING, and the
 *     true current value is whichever OTHER (now 'ended') row's date range
 *     actually covers today.
 * Fetching every non-cancelled version per karat (a small, bounded table)
 * and resolving both in JS avoids an N+1 RPC call per karat while staying
 * exactly consistent with manufacturing_fee_for_karat_on_date()'s own
 * resolution logic (status <> 'cancelled', effective_from <= date <=
 * effective_to-or-open).
 */
export async function listManufacturingFeeOverview() {
  const supabase = await createClient();
  const today = riyadhTodayIsoDate();

  const [{ data: karats, error: karatsError }, { data: versions, error: versionsError }] = await Promise.all([
    supabase.from("karats").select("*").order("sort_order"),
    supabase.from("manufacturing_fee_versions").select("*").neq("status", "cancelled").order("effective_from", { ascending: false }),
  ]);

  if (karatsError) throw karatsError;
  if (versionsError) throw versionsError;

  const versionsByKarat = new Map<string, FeeVersion[]>();
  for (const v of versions ?? []) {
    const list = versionsByKarat.get(v.karat_id) ?? [];
    list.push(v);
    versionsByKarat.set(v.karat_id, list);
  }

  return (karats ?? []).map((karat) => {
    const rows = versionsByKarat.get(karat.id) ?? [];
    const openVersion = rows.find((v) => v.effective_to === null && v.status === "active") ?? null;
    const currentVersion = rows.find((v) => v.effective_from <= today && (v.effective_to === null || v.effective_to >= today)) ?? null;
    const upcomingVersion = openVersion && openVersion.effective_from > today ? openVersion : null;

    return { karat, currentVersion, upcomingVersion };
  });
}

export async function listManufacturingFeeHistory(karatId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("manufacturing_fee_versions")
    .select("*")
    .eq("karat_id", karatId)
    .order("effective_from", { ascending: false });
  if (error) throw error;
  return data ?? [];
}

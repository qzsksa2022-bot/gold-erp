import "server-only";

import { createClient } from "@/lib/supabase/server";

// Matches the established pattern in src/features/audit-log/queries.ts:
// fetch the base rows, then a second batched query for the related
// profiles/karats and merge in JS — rather than a PostgREST embedded
// select. This project's hand-maintained src/types/database.ts carries
// `Relationships: []` on every table (see that file's header comment), so
// an embedded select loses type information (SelectQueryError) even though
// it works at runtime; the two-query approach stays fully typed everywhere.

/**
 * Today's-entry-form data: every ACTIVE karat, left-joined with whatever
 * price row already exists for `date` (null if not entered yet). Ordered
 * to match the karat management page (sort_order).
 */
export async function getPriceEntryRowsForDate(date: string) {
  const supabase = await createClient();

  const [{ data: karats, error: karatsError }, { data: prices, error: pricesError }] = await Promise.all([
    supabase.rpc("active_karats"),
    supabase.from("daily_gold_prices").select("*").eq("price_date", date),
  ]);

  if (karatsError) throw karatsError;
  if (pricesError) throw pricesError;

  const editorIds = [...new Set((prices ?? []).map((p) => p.updated_by).filter(Boolean))] as string[];
  const { data: editors } = editorIds.length
    ? await supabase.from("profiles").select("id, full_name").in("id", editorIds)
    : { data: [] };
  const editorMap = new Map((editors ?? []).map((e) => [e.id, e]));

  const priceByKarat = new Map(
    (prices ?? []).map((p) => [p.karat_id, { ...p, updated_by_profile: p.updated_by ? (editorMap.get(p.updated_by) ?? null) : null }]),
  );

  return (karats ?? []).map((karat) => ({
    karat,
    price: priceByKarat.get(karat.id) ?? null,
  }));
}

export type PriceHistoryFilters = {
  karatId?: string;
  dateFrom?: string;
  dateTo?: string;
  page: number;
  pageSize: number;
};

export async function listPriceHistory({ karatId, dateFrom, dateTo, page, pageSize }: PriceHistoryFilters) {
  const supabase = await createClient();

  let query = supabase.from("daily_gold_prices").select("*", { count: "exact" }).order("price_date", { ascending: false }).order("created_at", { ascending: false });

  if (karatId) query = query.eq("karat_id", karatId);
  if (dateFrom) query = query.gte("price_date", dateFrom);
  if (dateTo) query = query.lte("price_date", dateTo);

  const from = (page - 1) * pageSize;
  const { data, error, count } = await query.range(from, from + pageSize - 1);
  if (error) throw error;

  const rows = data ?? [];
  const karatIds = [...new Set(rows.map((r) => r.karat_id))];
  const editorIds = [...new Set(rows.map((r) => r.updated_by).filter(Boolean))] as string[];

  const [{ data: karats }, { data: editors }] = await Promise.all([
    karatIds.length ? supabase.from("karats").select("id, code, name_ar").in("id", karatIds) : Promise.resolve({ data: [] }),
    editorIds.length ? supabase.from("profiles").select("id, full_name").in("id", editorIds) : Promise.resolve({ data: [] }),
  ]);
  const karatMap = new Map((karats ?? []).map((k) => [k.id, k]));
  const editorMap = new Map((editors ?? []).map((e) => [e.id, e]));

  return {
    rows: rows.map((row) => ({
      ...row,
      karat: karatMap.get(row.karat_id) ?? null,
      updated_by_profile: row.updated_by ? (editorMap.get(row.updated_by) ?? null) : null,
    })),
    total: count ?? 0,
  };
}

/** Discoverability hook (spec §3) — active karats with no price row for `date`. */
export async function getMissingPricesForDate(date: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("gold_prices_missing_for_date", { p_date: date });
  if (error) throw error;
  return data ?? [];
}

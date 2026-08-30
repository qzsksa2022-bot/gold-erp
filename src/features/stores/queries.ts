import "server-only";

import { createClient } from "@/lib/supabase/server";
import type { StoreStatus } from "@/types/database";

export type StoreListFilters = {
  q?: string;
  status?: StoreStatus | "all";
  page: number;
  pageSize: number;
};

export async function listStores({ q, status = "all", page, pageSize }: StoreListFilters) {
  const supabase = await createClient();

  let query = supabase.from("stores").select("*", { count: "exact" }).order("created_at", { ascending: false });

  if (q) {
    query = query.or(`name_ar.ilike.%${q}%,name_en.ilike.%${q}%,code.ilike.%${q}%`);
  }
  if (status !== "all") {
    query = query.eq("status", status);
  }

  const from = (page - 1) * pageSize;
  const { data, error, count } = await query.range(from, from + pageSize - 1);

  if (error) throw error;
  return { stores: data ?? [], total: count ?? 0 };
}

export async function getStoreById(id: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.from("stores").select("*").eq("id", id).single();
  if (error) return null;
  return data;
}

/** Active stores for select inputs (e.g. assigning a user's default store). */
export async function listActiveStoresForSelect() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("stores")
    .select("id, code, name_ar")
    .eq("status", "active")
    .order("name_ar");
  if (error) throw error;
  return data ?? [];
}

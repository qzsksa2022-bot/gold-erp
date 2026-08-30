import "server-only";

import { createClient } from "@/lib/supabase/server";

/** Full karat list (rarely more than a handful of rows — no pagination needed), for the management page. */
export async function listKarats() {
  const supabase = await createClient();
  const { data, error } = await supabase.from("karats").select("*").order("sort_order").order("code");
  if (error) throw error;
  return data ?? [];
}

/** Active karats only, for select inputs elsewhere (gold prices entry, manufacturing fee form, ...). */
export async function listActiveKarats() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("active_karats");
  if (error) throw error;
  return data ?? [];
}

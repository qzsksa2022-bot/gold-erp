import "server-only";

import { createClient } from "@/lib/supabase/server";

/** Full flat list (every status), for the management page — the tree is built client-side from parent_id. */
export async function listCategoriesFlat() {
  const supabase = await createClient();
  const { data, error } = await supabase.from("product_categories").select("*").order("sort_order").order("name_ar");
  if (error) throw error;
  return data ?? [];
}

import "server-only";

import { createClient } from "@/lib/supabase/server";

export async function listCollectionChannels() {
  const supabase = await createClient();
  const { data, error } = await supabase.from("collection_channels").select("*").order("sort_order").order("name_ar");
  if (error) throw error;
  return data ?? [];
}

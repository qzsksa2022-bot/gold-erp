import "server-only";

import { createClient } from "@/lib/supabase/server";
import { riyadhTodayIsoDate } from "@/lib/date";
import type { Database } from "@/types/database";

type FeeVersion = Database["public"]["Tables"]["payment_method_fee_versions"]["Row"];

/**
 * Every payment method with CURRENT and UPCOMING fee versions resolved
 * separately (Financial Integrity Patch 2.1 item 8 — mirrors
 * listManufacturingFeeOverview()'s fix exactly; see that function's comment
 * for the full reasoning). COD deliberately may have neither (no fee
 * version configured at all, see supabase/seed.sql/0049) — both fields are
 * simply null in that case, never a fabricated value.
 */
export async function listPaymentMethodsOverview() {
  const supabase = await createClient();
  const today = riyadhTodayIsoDate();

  const [{ data: methods, error: methodsError }, { data: versions, error: versionsError }] = await Promise.all([
    supabase.from("payment_methods").select("*").order("sort_order"),
    supabase.from("payment_method_fee_versions").select("*").neq("status", "cancelled").order("effective_from", { ascending: false }),
  ]);

  if (methodsError) throw methodsError;
  if (versionsError) throw versionsError;

  const versionsByMethod = new Map<string, FeeVersion[]>();
  for (const v of versions ?? []) {
    const list = versionsByMethod.get(v.payment_method_id) ?? [];
    list.push(v);
    versionsByMethod.set(v.payment_method_id, list);
  }

  return (methods ?? []).map((method) => {
    const rows = versionsByMethod.get(method.id) ?? [];
    const openVersion = rows.find((v) => v.effective_to === null && v.status === "active") ?? null;
    const currentVersion = rows.find((v) => v.effective_from <= today && (v.effective_to === null || v.effective_to >= today)) ?? null;
    const upcomingVersion = openVersion && openVersion.effective_from > today ? openVersion : null;

    return { method, currentVersion, upcomingVersion };
  });
}

export async function listPaymentMethodFeeHistory(paymentMethodId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("payment_method_fee_versions")
    .select("*")
    .eq("payment_method_id", paymentMethodId)
    .order("effective_from", { ascending: false });
  if (error) throw error;
  return data ?? [];
}

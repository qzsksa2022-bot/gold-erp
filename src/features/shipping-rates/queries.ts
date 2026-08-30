import "server-only";

import { createClient } from "@/lib/supabase/server";
import { riyadhTodayIsoDate } from "@/lib/date";
import type { Database } from "@/types/database";

type Carrier = Database["public"]["Tables"]["shipping_carriers"]["Row"];
type Zone = Database["public"]["Tables"]["shipping_zones"]["Row"];

// Hotfix 5.1.1 item 5 — these two types now come from the text-safe RPCs
// (list_shipping_carrier_rate_versions_safe()/list_customer_return_
// shipping_fee_versions_safe(), migration 0132) rather than the raw table
// Row types: base_cost/fee_amount are `string` here (::text at the RPC
// boundary), never a raw NUMERIC->JS number read via `.select("*")`.
type CarrierRateVersion = Database["public"]["Functions"]["list_shipping_carrier_rate_versions_safe"]["Returns"][number];
type ReturnFeeVersion = Database["public"]["Functions"]["list_customer_return_shipping_fee_versions_safe"]["Returns"][number];

/** Every carrier (active + disabled) — the admin page shows disabled ones too, unlike shipments_carrier_lookups()/shipments_filter_carrier_lookups(). */
export async function listShippingCarriers() {
  const supabase = await createClient();
  const { data, error } = await supabase.from("shipping_carriers").select("*").order("name_ar");
  if (error) throw error;
  return data ?? [];
}

/** Every zone (active + disabled). */
export async function listShippingZones() {
  const supabase = await createClient();
  const { data, error } = await supabase.from("shipping_zones").select("*").order("sort_order").order("name_ar");
  if (error) throw error;
  return data ?? [];
}

/**
 * One row per (carrier, zone, direction) combination that has ever had a
 * rate version, with CURRENT and UPCOMING resolved separately — same
 * "never present a future version as current" fix already applied to
 * listManufacturingFeeOverview() (Financial Integrity Patch 2.1 item 8).
 * Fetches every non-cancelled version (a small, bounded table) and resolves
 * in JS rather than one RPC call per combination.
 */
export async function listShippingCarrierRateOverview() {
  const supabase = await createClient();
  const today = riyadhTodayIsoDate();

  // Hotfix 5.1.1 item 5 — text-safe RPC (migration 0132) instead of a raw
  // `.from(...).select("*")` read; base_cost arrives ::text. The RPC
  // returns every version (RLS-equivalent row set, including cancelled) —
  // the "non-cancelled" filter now happens here in JS, and the ordering
  // matches the RPC's own `order by effective_from desc`.
  const { data: allVersions, error } = await supabase.rpc("list_shipping_carrier_rate_versions_safe");
  if (error) throw error;
  const versions = (allVersions ?? []).filter((v) => v.status !== "cancelled");

  const byKey = new Map<string, CarrierRateVersion[]>();
  for (const v of versions) {
    const key = `${v.carrier_id}::${v.shipping_zone_id}::${v.direction}`;
    const list = byKey.get(key) ?? [];
    list.push(v);
    byKey.set(key, list);
  }

  return Array.from(byKey.entries()).map(([key, rows]) => {
    const [carrier_id, shipping_zone_id, direction] = key.split("::");
    const openVersion = rows.find((v) => v.effective_to === null && v.status === "active") ?? null;
    const currentVersion = rows.find((v) => v.effective_from <= today && (v.effective_to === null || v.effective_to >= today)) ?? null;
    const upcomingVersion = openVersion && openVersion.effective_from > today ? openVersion : null;

    return { carrier_id, shipping_zone_id, direction: direction as CarrierRateVersion["direction"], currentVersion, upcomingVersion, history: rows };
  });
}

export async function listShippingCarrierRateHistory(carrierId: string, shippingZoneId: string, direction: CarrierRateVersion["direction"]) {
  const supabase = await createClient();
  // Hotfix 5.1.1 item 5 — same text-safe RPC as listShippingCarrierRateOverview();
  // the (carrier, zone, direction) filter now happens in JS since the RPC
  // takes no arguments (it returns the same RLS-visible row set either way).
  const { data, error } = await supabase.rpc("list_shipping_carrier_rate_versions_safe");
  if (error) throw error;
  return (data ?? []).filter((v) => v.carrier_id === carrierId && v.shipping_zone_id === shippingZoneId && v.direction === direction);
}

/** Same current/upcoming resolution as listShippingCarrierRateOverview(), but for customer_return_shipping_fee_versions (keyed by zone only, no carrier/direction). */
export async function listCustomerReturnShippingFeeOverview() {
  const supabase = await createClient();
  const today = riyadhTodayIsoDate();

  // Hotfix 5.1.1 item 5 — text-safe RPC (migration 0132) instead of a raw
  // `.from(...).select("*")` read; fee_amount arrives ::text.
  const { data: allVersions, error } = await supabase.rpc("list_customer_return_shipping_fee_versions_safe");
  if (error) throw error;
  const versions = (allVersions ?? []).filter((v) => v.status !== "cancelled");

  const byZone = new Map<string, ReturnFeeVersion[]>();
  for (const v of versions) {
    const list = byZone.get(v.shipping_zone_id) ?? [];
    list.push(v);
    byZone.set(v.shipping_zone_id, list);
  }

  return Array.from(byZone.entries()).map(([shipping_zone_id, rows]) => {
    const openVersion = rows.find((v) => v.effective_to === null && v.status === "active") ?? null;
    const currentVersion = rows.find((v) => v.effective_from <= today && (v.effective_to === null || v.effective_to >= today)) ?? null;
    const upcomingVersion = openVersion && openVersion.effective_from > today ? openVersion : null;

    return { shipping_zone_id, currentVersion, upcomingVersion, history: rows };
  });
}

export type { Carrier, Zone };

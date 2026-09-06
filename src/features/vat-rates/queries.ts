import "server-only";

import { createClient } from "@/lib/supabase/server";
import { riyadhTodayIsoDate } from "@/lib/date";
import type { Database } from "@/types/database";

export type VatRateVersion = Database["public"]["Tables"]["vat_rate_versions"]["Row"];

/**
 * Hotfix 10.1.0 — VAT rate overview, resolved exactly the way
 * listManufacturingFeeOverview() resolves its own versions.
 *
 * VAT differs from manufacturing/payment fees in one way only: it is a
 * SINGLE, system-wide, store-independent rate (0058's header says so
 * explicitly — its exclusion constraint has no partition column), so there is
 * one timeline rather than one per karat/payment method.
 *
 * CURRENT and UPCOMING are resolved separately for the same reason Financial
 * Integrity Patch 2.1 item 8 forced that split elsewhere: the single "open"
 * version (effective_to IS NULL, status='active') is either already effective
 * — in which case it IS current — or still in the future, in which case it is
 * UPCOMING and the true current value is whichever other row's date range
 * actually covers today. Presenting a scheduled rate as the live one would
 * misstate the tax being charged right now.
 *
 * Resolution matches vat_rate_for_date() (0058) exactly: status <> 'cancelled'
 * and effective_from <= date <= effective_to-or-open.
 */
export async function listVatRateOverview(): Promise<{
  currentVersion: VatRateVersion | null;
  upcomingVersion: VatRateVersion | null;
  history: VatRateVersion[];
}> {
  const supabase = await createClient();
  const today = riyadhTodayIsoDate();

  const { data, error } = await supabase
    .from("vat_rate_versions")
    .select("*")
    .order("effective_from", { ascending: false });

  if (error) throw error;

  const all = data ?? [];
  const live = all.filter((v) => v.status !== "cancelled");

  const openVersion = live.find((v) => v.effective_to === null && v.status === "active") ?? null;
  const currentVersion = live.find((v) => v.effective_from <= today && (v.effective_to === null || v.effective_to >= today)) ?? null;
  const upcomingVersion = openVersion && openVersion.effective_from > today ? openVersion : null;

  // History keeps cancelled rows too — the audit trail of what was scheduled
  // and withdrawn is part of what this page exists to show.
  return { currentVersion, upcomingVersion, history: all };
}

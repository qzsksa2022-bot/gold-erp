import "server-only";

import { cache } from "react";
import { createClient } from "@/lib/supabase/server";
import { APP_DEFAULTS } from "@/lib/constants";
import type { AppearanceSettings, GeneralSettings, PublicBranding, SecuritySettings } from "./types";

/**
 * Reads the 'general' + 'appearance' settings categories, which are
 * readable pre-login (see the system_settings_select_public RLS policy) so
 * the login screen itself can show the tenant's real name/logo/accent
 * instead of a hardcoded placeholder. Falls back to APP_DEFAULTS for any
 * key that hasn't been set yet (fresh install, before an admin visits
 * Settings).
 */
export const getPublicBranding = cache(async (): Promise<PublicBranding> => {
  const supabase = await createClient();
  const { data } = await supabase.from("system_settings").select("key, value").in("category", ["general", "appearance"]);

  const map = new Map((data ?? []).map((row) => [row.key, row.value]));

  return {
    system_name_ar: (map.get("system_name_ar") as string) ?? APP_DEFAULTS.nameAr,
    system_name_en: (map.get("system_name_en") as string) ?? APP_DEFAULTS.nameEn,
    logo_url: (map.get("logo_url") as string | null) ?? null,
    accent_color: (map.get("accent_color") as string) ?? "#A9812E",
    font_family: (map.get("font_family") as string | null) ?? null,
  };
});

/** Full settings read for the Settings pages (requires settings.manage via RLS). */
export async function getAllSettings() {
  const supabase = await createClient();
  const { data, error } = await supabase.from("system_settings").select("*").order("category");
  if (error) throw error;

  const byCategory = new Map<string, Map<string, unknown>>();
  for (const row of data ?? []) {
    if (!byCategory.has(row.category)) byCategory.set(row.category, new Map());
    byCategory.get(row.category)!.set(row.key, row.value);
  }

  const general: GeneralSettings = {
    system_name_ar: (byCategory.get("general")?.get("system_name_ar") as string) ?? APP_DEFAULTS.nameAr,
    system_name_en: (byCategory.get("general")?.get("system_name_en") as string) ?? APP_DEFAULTS.nameEn,
    currency: (byCategory.get("general")?.get("currency") as string) ?? APP_DEFAULTS.currency,
    timezone: (byCategory.get("general")?.get("timezone") as string) ?? APP_DEFAULTS.timezone,
  };

  const appearance: AppearanceSettings = {
    logo_url: (byCategory.get("appearance")?.get("logo_url") as string | null) ?? null,
    accent_color: (byCategory.get("appearance")?.get("accent_color") as string) ?? "#A9812E",
    font_family: (byCategory.get("appearance")?.get("font_family") as string | null) ?? null,
  };

  const security: SecuritySettings = {
    two_factor_enabled: (byCategory.get("security")?.get("two_factor_enabled") as boolean) ?? false,
    session_timeout_minutes: (byCategory.get("security")?.get("session_timeout_minutes") as number) ?? 480,
  };

  return { general, appearance, security };
}

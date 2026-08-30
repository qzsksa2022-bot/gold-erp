export type GeneralSettings = {
  system_name_ar: string;
  system_name_en: string;
  currency: string;
  timezone: string;
};

export type AppearanceSettings = {
  logo_url: string | null;
  accent_color: string;
  font_family: string | null;
};

export type SecuritySettings = {
  two_factor_enabled: boolean;
  session_timeout_minutes: number;
};

export type PublicBranding = Pick<GeneralSettings, "system_name_ar" | "system_name_en"> &
  Pick<AppearanceSettings, "logo_url" | "accent_color" | "font_family">;

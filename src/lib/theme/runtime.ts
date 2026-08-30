import type { PublicBranding } from "@/features/settings/types";

/**
 * Turns the tenant's Appearance settings into a CSS custom-property
 * override applied on <html style={...}> (see src/app/layout.tsx). This is
 * the ONE place runtime branding turns into CSS — every component below it
 * just consumes `--color-accent` etc. via Tailwind's `accent`/`ring`
 * utilities, so changing the accent color in Settings updates the entire
 * app with no per-component code changes.
 *
 * Only accent color + font are runtime-overridable in this phase (matches
 * what the Settings → Appearance form exposes). Logo is rendered directly
 * (an <img src>), not a CSS variable.
 */
export function buildThemeStyle(branding: Pick<PublicBranding, "accent_color" | "font_family">): React.CSSProperties {
  const style: Record<string, string> = {};

  if (branding.accent_color) {
    style["--accent"] = branding.accent_color;
    style["--ring"] = branding.accent_color;
  }

  if (branding.font_family) {
    style["--font-app-sans"] =
      `"${branding.font_family}", "IBM Plex Sans Arabic", "Tajawal", "Segoe UI", system-ui, sans-serif`;
  }

  return style as React.CSSProperties;
}

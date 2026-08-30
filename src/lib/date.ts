import { formatInTimeZone, toZonedTime } from "date-fns-tz";
import { APP_DEFAULTS } from "@/lib/constants";

/**
 * Timezone standard for this app:
 *  - Postgres columns are `timestamptz` (stored internally as UTC, the
 *    Postgres-recommended way — see every `created_at`/`updated_at` column
 *    in supabase/migrations).
 *  - We NEVER store or reason about "local" naive timestamps.
 *  - Display to the user always converts to Asia/Riyadh (UTC+3, no DST) via
 *    the helpers below. Never call `.toLocaleString()`/`new Date().toString()`
 *    directly in a component — go through these so formatting stays
 *    consistent app-wide and is trivial to make locale-configurable later.
 */
export const APP_TIMEZONE = APP_DEFAULTS.timezone;

export function formatRiyadhDateTime(date: string | Date): string {
  return formatInTimeZone(date, APP_TIMEZONE, "yyyy/MM/dd HH:mm");
}

export function formatRiyadhDate(date: string | Date): string {
  return formatInTimeZone(date, APP_TIMEZONE, "yyyy/MM/dd");
}

export function formatRiyadhTime(date: string | Date): string {
  return formatInTimeZone(date, APP_TIMEZONE, "HH:mm");
}

/** Riyadh "today" as a Date, useful for default filter ranges. */
export function riyadhNow(): Date {
  return toZonedTime(new Date(), APP_TIMEZONE);
}

/** Riyadh "today" as a `yyyy-MM-dd` string — the shape a Postgres `date` column and an `<input type="date">` both expect. */
export function riyadhTodayIsoDate(): string {
  return formatInTimeZone(new Date(), APP_TIMEZONE, "yyyy-MM-dd");
}

/** Relative-ish, human Arabic label for recent timestamps (dashboard feed). */
export function formatRelativeArabic(date: string | Date): string {
  const then = typeof date === "string" ? new Date(date) : date;
  const diffMs = Date.now() - then.getTime();
  const diffMin = Math.round(diffMs / 60000);

  if (diffMin < 1) return "الآن";
  if (diffMin < 60) return `منذ ${diffMin} ${diffMin === 1 ? "دقيقة" : "دقائق"}`;
  const diffHours = Math.round(diffMin / 60);
  if (diffHours < 24) return `منذ ${diffHours} ${diffHours === 1 ? "ساعة" : "ساعات"}`;
  const diffDays = Math.round(diffHours / 24);
  if (diffDays < 30) return `منذ ${diffDays} ${diffDays === 1 ? "يوم" : "أيام"}`;
  return formatRiyadhDate(then);
}

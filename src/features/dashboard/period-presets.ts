import { riyadhNow } from "@/lib/date";

/**
 * Patch 8.1 §43-46 / Hotfix 8.1.3 §1 — the Dashboard's quick-period preset
 * definitions, as PURE date arithmetic with no React/`next/navigation`
 * dependency at all.
 *
 * Split out of `components/period-presets.tsx` (which is `"use client"`)
 * deliberately: Hotfix 8.1.3 §1-4 makes the Dashboard SERVER component
 * resolve the `period_preset` it hands
 * `get_dashboard_summary_with_comparison()` (0221) from these very same
 * definitions, and every export of a `"use client"` module is a client
 * REFERENCE when imported from a Server Component — calling one server-side
 * throws. Keeping the arithmetic in this plain module lets the client
 * button strip and the server page share ONE definition of what
 * "this_month" means, instead of each carrying its own copy (exactly the
 * client/server-disagreement class of bug 0221's own header warns about).
 */

export function ymd(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

export interface PeriodPreset {
  key: string;
  label: string;
  from: string;
  to: string;
}

/**
 * Patch 8.1 §43-46 — Dashboard period presets. `riyadhNow()` (@/lib/date)
 * returns a Date whose LOCAL getters already read as Riyadh wall-clock time
 * (date-fns-tz's `toZonedTime` contract) — every boundary below is built
 * from plain `Date` day/month/year arithmetic on that value, never a second,
 * independent timezone conversion. "This week" mirrors the SQL side's own
 * Riyadh Week Contract EXACTLY (`riyadh_week_start()`, 0199: Saturday→Friday,
 * `p_date - ((dow + 1) % 7)` where `dow` is JS/Postgres's shared 0=Sunday..
 * 6=Saturday convention) so a Dashboard preset and a report's own default
 * range never silently disagree about what "this week" means.
 */
/**
 * Pure and independently testable (§43-46) — accepts an optional `now`
 * override (a Date whose LOCAL getters already read as Riyadh wall-clock
 * time, the same contract `riyadhNow()` provides) so tests can pin "today"
 * without mocking the system clock or Next.js navigation hooks.
 */
export function buildPresets(now: Date = riyadhNow()): PeriodPreset[] {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const todayStr = ymd(today);

  const yesterday = new Date(today);
  yesterday.setDate(yesterday.getDate() - 1);

  const last7Start = new Date(today);
  last7Start.setDate(last7Start.getDate() - 6);

  const last30Start = new Date(today);
  last30Start.setDate(last30Start.getDate() - 29);

  const daysSinceRiyadhWeekStart = (today.getDay() + 1) % 7; // Sat=0 .. Fri=6, matching riyadh_week_start() (0199).
  const weekStart = new Date(today);
  weekStart.setDate(weekStart.getDate() - daysSinceRiyadhWeekStart);

  const monthStart = new Date(today.getFullYear(), today.getMonth(), 1);

  const prevMonthStart = new Date(today.getFullYear(), today.getMonth() - 1, 1);
  const prevMonthEnd = new Date(today.getFullYear(), today.getMonth(), 0);

  const yearStart = new Date(today.getFullYear(), 0, 1);

  // Hotfix 8.1.1 §45 — "last_week": the previous FULL Riyadh week (Saturday
  // -> Friday, same riyadh_week_start() contract as "this_week" above) —
  // i.e. exactly 7 days ending the day before this week's own start.
  const lastWeekEnd = new Date(weekStart);
  lastWeekEnd.setDate(lastWeekEnd.getDate() - 1);
  const lastWeekStart = new Date(lastWeekEnd);
  lastWeekStart.setDate(lastWeekStart.getDate() - 6);

  // Hotfix 8.1.1 §45 — "last_year": the previous full calendar year,
  // January 1 -> December 31.
  const lastYearStart = new Date(today.getFullYear() - 1, 0, 1);
  const lastYearEnd = new Date(today.getFullYear() - 1, 11, 31);

  return [
    { key: "today", label: "اليوم", from: todayStr, to: todayStr },
    { key: "yesterday", label: "أمس", from: ymd(yesterday), to: ymd(yesterday) },
    { key: "last7", label: "آخر 7 أيام", from: ymd(last7Start), to: todayStr },
    { key: "last30", label: "آخر 30 يومًا", from: ymd(last30Start), to: todayStr },
    { key: "this_week", label: "هذا الأسبوع", from: ymd(weekStart), to: todayStr },
    { key: "last_week", label: "الأسبوع الماضي", from: ymd(lastWeekStart), to: ymd(lastWeekEnd) },
    { key: "this_month", label: "هذا الشهر", from: ymd(monthStart), to: todayStr },
    { key: "last_month", label: "الشهر الماضي", from: ymd(prevMonthStart), to: ymd(prevMonthEnd) },
    { key: "this_year", label: "هذه السنة", from: ymd(yearStart), to: todayStr },
    { key: "last_year", label: "السنة الماضية", from: ymd(lastYearStart), to: ymd(lastYearEnd) },
  ];
}

/**
 * Hotfix 8.1.3 §3 — the explicit "no calendar unit to align to" preset key.
 * `report_calendar_comparison_period()` (0221) lists `custom` by name in its
 * `else` branch: the immediately-preceding EQUAL-LENGTH range, which is the
 * correct comparison for a hand-picked range that is not a calendar unit.
 */
export const CUSTOM_PERIOD_PRESET = "custom";

/**
 * Hotfix 8.1.3 §4 — preference order used ONLY when a preset is being
 * DERIVED from a range rather than declared by a button.
 *
 * Two presets can describe the exact same range by coincidence: on the 30th
 * of a month `last30` is month-start→today, byte-for-byte identical to
 * `this_month` (and `last7` collides with `this_week` on a Friday, `last30`
 * with `this_year` on January 30th, and so on). §4 requires the default
 * month-start→today range to resolve to `this_month`, so on a tie the
 * CALENDAR units win — they are exactly the presets
 * `report_calendar_comparison_period()` (0221) has a real calendar branch
 * for, while `last7`/`last30` fall into its generic equal-length `else`
 * branch. A deliberately-clicked "آخر 30 يومًا" is unaffected: its own key
 * is written into the URL (§2) and, while its dates still match that preset,
 * is accepted before derivation.
 */
const DERIVATION_PRIORITY = ["this_month", "last_month", "this_year", "last_year", "this_week", "last_week"];

/**
 * Hotfix 8.1.3 §2-4 — resolves the `p_period_preset` argument the Dashboard
 * hands `get_dashboard_summary_with_comparison()` (0221), from the URL as it
 * actually is right now:
 *
 *  - §2 — a quick-period button writes its OWN key into `period_preset`
 *    alongside `date_from`/`date_to`; a known key is accepted only while
 *    those dates still match that preset's own range. This prevents a stale
 *    or hand-edited URL from claiming a calendar unit that its dates no
 *    longer represent.
 *  - §3 — editing `date_from`/`date_to` by hand DELETES `period_preset`
 *    from the URL (`ReportFilterBar`'s `dateChangeClearKeys`). As a second
 *    line of defense, even a known-but-stale preset is re-derived from the
 *    range rather than forwarded verbatim. An exact range match wins;
 *    otherwise the result is `custom`.
 *  - §4 — the DEFAULT range (month start → today, the page's own fallback
 *    when the URL carries no dates at all) is byte-for-byte `this_month`'s
 *    own from/to, so it resolves to `this_month` through that same range
 *    match — the default Dashboard view compares against the full previous
 *    calendar month, never a 30-ish-day equal-length window.
 *
 * An UNKNOWN/hand-crafted preset key is also re-derived from the range.
 */
export function resolveDashboardPeriodPreset(presetParam: string | undefined, dateFrom: string, dateTo: string, now: Date = riyadhNow()): string {
  const presets = buildPresets(now);
  const declaredPreset = presetParam ? presets.find((p) => p.key === presetParam) : undefined;
  if (declaredPreset && declaredPreset.from === dateFrom && declaredPreset.to === dateTo) return declaredPreset.key;

  const matches = presets.filter((p) => p.from === dateFrom && p.to === dateTo);
  if (matches.length === 0) return CUSTOM_PERIOD_PRESET;
  const preferred = DERIVATION_PRIORITY.find((key) => matches.some((p) => p.key === key));
  return preferred ?? matches[0].key;
}

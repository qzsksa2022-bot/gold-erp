"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useTransition } from "react";
import { riyadhNow } from "@/lib/date";
import { cn } from "@/lib/utils";

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

export function PeriodPresets({ dateFrom, dateTo }: { dateFrom?: string; dateTo?: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [, startTransition] = useTransition();
  const presets = buildPresets();

  function apply(from: string, to: string) {
    const params = new URLSearchParams(searchParams.toString());
    params.set("date_from", from);
    params.set("date_to", to);
    startTransition(() => router.push(`${pathname}?${params.toString()}`));
  }

  return (
    <div className="mb-4 flex flex-wrap gap-2" role="group" aria-label="فترات سريعة">
      {presets.map((p) => {
        const isActive = p.from === dateFrom && p.to === dateTo;
        return (
          <button
            key={p.key}
            type="button"
            onClick={() => apply(p.from, p.to)}
            className={cn(
              "rounded-full border px-3 py-1 text-xs font-medium transition-colors",
              isActive ? "border-accent bg-accent/10 text-accent" : "border-border bg-card text-muted-foreground hover:bg-muted/50",
            )}
          >
            {p.label}
          </button>
        );
      })}
    </div>
  );
}

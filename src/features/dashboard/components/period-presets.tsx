"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useTransition } from "react";
import { buildPresets, type PeriodPreset } from "@/features/dashboard/period-presets";
import { cn } from "@/lib/utils";

/**
 * Patch 8.1 §43-46 — the Dashboard's quick-period button strip. The preset
 * ARITHMETIC itself now lives in `@/features/dashboard/period-presets` (a
 * plain, non-`"use client"` module) so the Dashboard server page can resolve
 * the SAME preset keys without importing across the client boundary — see
 * that file's header for why.
 *
 * Hotfix 8.1.3 §2 — a button now also writes its own `period_preset` key
 * into the URL, which the page forwards to
 * `get_dashboard_summary_with_comparison()` (0221) as `p_period_preset`.
 * Without it, "This Week"/"This Month"/"This Year" would silently fall into
 * that function's generic equal-length-preceding branch — the exact §1 bug
 * 0221 exists to fix, just moved into the client.
 */
export function PeriodPresets({ dateFrom, dateTo, periodPreset }: { dateFrom?: string; dateTo?: string; periodPreset?: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [, startTransition] = useTransition();
  const presets = buildPresets();

  function apply(preset: PeriodPreset) {
    const params = new URLSearchParams(searchParams.toString());
    params.set("date_from", preset.from);
    params.set("date_to", preset.to);
    params.set("period_preset", preset.key);
    startTransition(() => router.push(`${pathname}?${params.toString()}`));
  }

  return (
    <div className="mb-4 flex flex-wrap gap-2" role="group" aria-label="فترات سريعة">
      {presets.map((p) => {
        // Hotfix 8.1.3 §2-3 — the page always hands down an already-RESOLVED
        // preset (never the raw URL value), so highlight by that key when it
        // is available: a manually-edited range resolves to `custom` and
        // correctly highlights NOTHING, instead of a button whose from/to
        // happens to still coincide. The from/to fallback keeps this
        // component usable on its own (and matches its pre-8.1.3 behavior).
        const isActive = periodPreset ? periodPreset === p.key : p.from === dateFrom && p.to === dateTo;
        return (
          <button
            key={p.key}
            type="button"
            onClick={() => apply(p)}
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

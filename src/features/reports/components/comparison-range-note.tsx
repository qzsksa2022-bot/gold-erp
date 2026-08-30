import { CalendarClock } from "lucide-react";
import { formatRiyadhDate } from "@/lib/date";
import { PERIOD_PRESET_LABELS_AR } from "@/features/reports/export/management-registry";

/**
 * Hotfix 8.1.2 §1/§41 — explicit on-screen indicator of the calendar-aware
 * comparison range every Management Report now compares against
 * (get_dashboard_summary_with_comparison(), 0221/0222) — e.g. "Weekly"
 * compares to the FULL previous Riyadh week, never an equal-length slice
 * of days. Renders nothing when the report never went through the
 * comparison wrapper (no previous_date_from/previous_date_to pair at all),
 * matching every other report component's true-key-absence handling (§79).
 */
export function ComparisonRangeNote({
  previousDateFrom,
  previousDateTo,
  periodPreset,
}: {
  previousDateFrom: unknown;
  previousDateTo: unknown;
  periodPreset: unknown;
}) {
  if (typeof previousDateFrom !== "string" || typeof previousDateTo !== "string") return null;
  const presetLabel = typeof periodPreset === "string" ? PERIOD_PRESET_LABELS_AR[periodPreset] : undefined;

  return (
    <div className="mb-4 flex items-start gap-2 rounded-lg border border-border bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
      <CalendarClock className="mt-0.5 size-3.5 shrink-0" />
      <p>
        {presetLabel ? `${presetLabel} — ` : ""}
        الفترة السابقة للمقارنة: من {formatRiyadhDate(previousDateFrom)} إلى {formatRiyadhDate(previousDateTo)}
      </p>
    </div>
  );
}

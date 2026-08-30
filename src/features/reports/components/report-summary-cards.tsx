import { formatSAR, formatGrams } from "@/lib/money";
import type { PermissionKey } from "@/lib/permissions/constants";

export type SummaryFieldFormat = "money" | "weight" | "int" | "text";

export interface SummaryFieldConfig {
  key: string;
  label: string;
  format: SummaryFieldFormat;
  /** Emphasize this card (e.g. Net Operating Return, Net Sales Profit). */
  emphasize?: boolean;
  /**
   * Patch 8.1 §15/§16/§61/§62 — same purpose as `ReportColumnConfig.permission`
   * (see that type's doc comment): lets the export route drop a forbidden
   * summary field's card/row entirely from PDF/Excel, never a blank value.
   * The screen-side `SummaryCards`/`drawSummaryGrid` path is already safe
   * (filters by `f.key in summary`) — this only matters for export.
   */
  permission?: PermissionKey;
}

function formatValue(raw: unknown, format: SummaryFieldFormat): string {
  if (raw === null || raw === undefined) return "—";
  switch (format) {
    case "money":
      return formatSAR(raw as string | number);
    case "weight":
      return formatGrams(raw as string | number);
    case "int":
      // no-float-ok: a count, never money/weight/percent — single-shot Intl.NumberFormat argument, not used in further arithmetic (§21).
      return new Intl.NumberFormat("ar-SA").format(Number(raw));
    default:
      return String(raw);
  }
}

/**
 * Renders a grid of KPI cards from a report `summary` object (§21-§37) —
 * only fields ACTUALLY PRESENT in `summary` are rendered (§79 true
 * key-absence: a redacted financial field is not in the object at all, so
 * it is simply skipped here rather than shown as "—", which would imply
 * "zero" instead of "hidden").
 */
export function ReportSummaryCards({ summary, fields }: { summary: Record<string, unknown>; fields: SummaryFieldConfig[] }) {
  const visible = fields.filter((f) => f.key in summary);
  if (visible.length === 0) return null;

  return (
    <div className="mb-4 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
      {visible.map((f) => (
        <div
          key={f.key}
          className={
            f.emphasize
              ? "rounded-xl border border-accent/30 bg-accent/5 p-4"
              : "rounded-xl border border-border bg-card p-4"
          }
        >
          <p className="text-xs text-muted-foreground">{f.label}</p>
          <p className={f.emphasize ? "mt-1 text-lg font-bold" : "mt-1 text-lg font-semibold"} dir="ltr">
            {formatValue(summary[f.key], f.format)}
          </p>
        </div>
      ))}
    </div>
  );
}

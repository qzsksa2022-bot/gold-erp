import { ArrowDownRight, ArrowUpRight, Minus } from "lucide-react";
import { formatSAR } from "@/lib/money";
import { decimalSign, decimalAbsFixed } from "@/lib/decimal";
import { cn } from "@/lib/utils";

export interface KpiFieldConfig {
  key: string;
  label: string;
  format: "money" | "int";
  /** For a cost/negative-is-good metric, invert the up/down color coding. */
  invertColor?: boolean;
}

function formatValue(raw: unknown, format: "money" | "int"): string {
  if (raw === null || raw === undefined) return "—";
  // no-float-ok: "int" is a count, never money/weight/percent — single-shot Intl.NumberFormat argument, not used in further arithmetic (§21).
  return format === "money" ? formatSAR(raw as string | number) : new Intl.NumberFormat("ar-SA").format(Number(raw));
}

// Patch 8.1 §19 — sign/magnitude via Decimal (`decimalSign`/
// `decimalAbsFixed` in @/lib/decimal), never `Number(raw)` fed into a
// `>`/`===` comparison. `pct` is the raw TEXT percent value straight off
// the RPC (or null when the comparison period had no data) — this
// component is the one place it gets converted at all, and only via
// Decimal, never a bare `Number()`.
function ChangeIndicator({ pct, invert }: { pct: string | number | null; invert?: boolean }) {
  let sign: -1 | 0 | 1;
  if (pct === null) return <span className="text-xs text-muted-foreground">لا توجد بيانات مقارنة</span>;
  try {
    sign = decimalSign(pct);
  } catch {
    return <span className="text-xs text-muted-foreground">لا توجد بيانات مقارنة</span>;
  }
  const isUp = sign > 0;
  const isFlat = sign === 0;
  const goodColor = invert ? !isUp : isUp;
  const colorClass = isFlat ? "text-muted-foreground" : goodColor ? "text-success" : "text-destructive";
  const Icon = isFlat ? Minus : isUp ? ArrowUpRight : ArrowDownRight;
  return (
    <span className={cn("inline-flex items-center gap-0.5 text-xs font-medium", colorClass)} dir="ltr">
      <Icon className="size-3.5" />
      {decimalAbsFixed(pct, 1)}%
    </span>
  );
}

/**
 * One KPI card reading current/previous/pct_change straight from a
 * get_dashboard_summary() section (§13 Comparison Engine). `section` is
 * the already-redacted sub-object (e.g. `summary.sales`) — a card for a
 * field the actor cannot see is simply not rendered (§79), matching every
 * other report component's true-absence handling.
 */
export function KpiCard({ section, field }: { section: Record<string, unknown>; field: KpiFieldConfig }) {
  if (!(field.key in section)) return null;
  const current = section[field.key];
  const pctRaw = section[`${field.key}_pct_change`];
  const pct = pctRaw === null || pctRaw === undefined ? null : (pctRaw as string | number);

  return (
    <div className="rounded-xl border border-border bg-card p-4">
      <p className="text-xs text-muted-foreground">{field.label}</p>
      <p className="mt-1 text-lg font-semibold" dir="ltr">
        {formatValue(current, field.format)}
      </p>
      <div className="mt-1">
        <ChangeIndicator pct={pct} invert={field.invertColor} />
      </div>
    </div>
  );
}

export function KpiSection({
  title,
  section,
  fields,
}: {
  title: string;
  section: Record<string, unknown> | undefined;
  fields: KpiFieldConfig[];
}) {
  if (!section) return null;
  const visible = fields.filter((f) => f.key in section);
  if (visible.length === 0) return null;

  return (
    <div className="mb-6">
      <h2 className="mb-2 text-sm font-semibold text-muted-foreground">{title}</h2>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
        {visible.map((f) => (
          <KpiCard key={f.key} section={section} field={f} />
        ))}
      </div>
    </div>
  );
}

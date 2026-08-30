import { formatSAR, formatGrams } from "@/lib/money";
import { Decimal, toDecimal, decimalSign, decimalRatioToNumber } from "@/lib/decimal";

export interface TrendBucket {
  bucket_start: string;
  bucket_end: string;
  bucket_label: string;
  [key: string]: unknown;
}

/** Patch 8.1 §43-46 — format-by-metric: get_dashboard_trends() (0205) returns several metrics per bucket beyond net_operating_return (orders_count/returns_count are plain counts, never money) — the tooltip must format each one correctly rather than assuming every value is SAR. Mirrors ReportColumnConfig's "money"/"weight"/"int" vocabulary (report-table.tsx). */
export type TrendValueFormat = "money" | "int" | "weight";

export function formatTrendValue(v: string | number, format: TrendValueFormat): string {
  switch (format) {
    case "int":
      // no-float-ok: a count, never money/weight/percent — single-shot Intl.NumberFormat argument, not used in further arithmetic (§21).
      return new Intl.NumberFormat("ar-SA").format(Number(v));
    case "weight":
      return formatGrams(v);
    case "money":
    default:
      return formatSAR(v);
  }
}

/**
 * Dependency-free SVG bar chart for get_dashboard_trends() (§19/§73 —
 * buckets are ALWAYS zero-filled by the RPC itself, so every bar position
 * here is a real, gap-free chart point, never a missing one silently
 * skipped). Renders `valueKey` (defaults to net_operating_return) per
 * bucket around a zero baseline — positive bars accent-colored, negative
 * bars destructive-colored, matching §18's Net Operating Return semantics
 * (a period CAN legitimately be net-negative, e.g. a heavy return month).
 * `format` (§43-46) controls how the tooltip renders the raw value —
 * defaults to "money" (the pre-existing behavior, still correct for every
 * money-typed metric); pass "int" for a count-typed metric like
 * orders_count/returns_count.
 */
export function TrendChart({
  buckets,
  valueKey = "net_operating_return",
  format = "money",
  title,
}: {
  buckets: TrendBucket[];
  valueKey?: string;
  format?: TrendValueFormat;
  title: string;
}) {
  if (buckets.length === 0 || !(valueKey in buckets[0])) return null;

  // Patch 8.1 §19 — the max-abs baseline and each bar's height ratio are
  // computed via Decimal end to end; `decimalRatioToNumber()`'s own
  // `.toNumber()` is the one legitimate conversion, right at the SVG
  // pixel-height boundary — never an intermediate `Number(raw)` used for
  // further comparison/division (the bug this replaces).
  const rawValues: (string | number)[] = buckets.map((b) => (b[valueKey] ?? 0) as string | number);
  const maxAbs = rawValues.reduce((acc, v) => {
    const abs = toDecimal(v).abs();
    return abs.gt(acc) ? abs : acc;
  }, new Decimal(1));

  const width = 100;
  const height = 40;
  const midY = height / 2;
  const barWidth = width / buckets.length;
  const gap = barWidth * 0.15;

  return (
    <div className="mb-6 rounded-xl border border-border bg-card p-4">
      <p className="mb-3 text-sm font-semibold text-muted-foreground">{title}</p>
      <svg viewBox={`0 0 ${width} ${height}`} className="h-32 w-full" preserveAspectRatio="none" role="img" aria-label={title}>
        <line x1="0" y1={midY} x2={width} y2={midY} className="stroke-border" strokeWidth="0.3" />
        {rawValues.map((v, i) => {
          const barHeight = decimalRatioToNumber(v, maxAbs) * (height / 2 - 2);
          const isNonNegative = decimalSign(v) >= 0;
          const x = i * barWidth + gap / 2;
          const y = isNonNegative ? midY - barHeight : midY;
          return (
            <rect
              key={i}
              x={x}
              y={y}
              width={Math.max(0, barWidth - gap)}
              height={Math.max(0.5, barHeight)}
              className={isNonNegative ? "fill-accent/70" : "fill-destructive/60"}
              rx="0.5"
            >
              <title>
                {buckets[i].bucket_label}: {formatTrendValue(v, format)}
              </title>
            </rect>
          );
        })}
      </svg>
      <div className="mt-2 flex justify-between text-[10px] text-muted-foreground" dir="ltr">
        <span>{buckets[0]?.bucket_label}</span>
        {buckets.length > 2 && <span>{buckets[Math.floor(buckets.length / 2)]?.bucket_label}</span>}
        <span>{buckets[buckets.length - 1]?.bucket_label}</span>
      </div>
    </div>
  );
}

import { ArrowDownRight, ArrowUpRight, Minus, TrendingUp } from "lucide-react";
import { formatSAR } from "@/lib/money";
import { decimalSign, decimalAbsFixed } from "@/lib/decimal";
import { cn } from "@/lib/utils";
import { MANAGEMENT_NOR_FIELDS } from "@/features/reports/export/management-registry";

/**
 * §18/§20 — the Net Operating Return hero card. Renders the formula itself
 * (Net Sales Profit + Net Shipping Result + Net Effective Adjustments
 * Profit = Net Operating Return) alongside the three components, so the
 * figure is never a "trust me" black box. Absent entirely if the actor
 * lacks the permissions that would reveal net_operating_return (§79).
 */
export function NetOperatingReturnCard({ nor }: { nor: Record<string, unknown> | undefined }) {
  if (!nor || !("net_operating_return" in nor)) return null;

  // Patch 8.1 §19 — `total` is only ever handed to `formatSAR()` below
  // (a single-shot display conversion, the established no-float-guard
  // exception), never compared/combined — kept as the raw TEXT value
  // rather than pre-converting to Number. Sign/magnitude for the
  // percent-change badge go through Decimal (`decimalSign`/
  // `decimalAbsFixed`), never a bare `Number(pctRaw)` fed into `>`/`===`.
  const total = nor.net_operating_return as string | number;
  const pctRaw = nor.net_operating_return_pct_change;
  const pct = pctRaw === null || pctRaw === undefined ? null : (pctRaw as string | number);
  const sign = pct === null ? null : decimalSign(pct);
  const isUp = sign !== null && sign > 0;
  const isFlat = sign === 0;
  const colorClass = sign === null ? "text-muted-foreground" : isFlat ? "text-muted-foreground" : isUp ? "text-success" : "text-destructive";
  const Icon = sign === null || isFlat ? Minus : isUp ? ArrowUpRight : ArrowDownRight;

  const components = MANAGEMENT_NOR_FIELDS;

  return (
    <div className="mb-6 rounded-2xl border border-accent/30 bg-accent/5 p-5">
      <div className="flex flex-col items-start justify-between gap-3 sm:flex-row sm:items-center">
        <div className="flex items-center gap-2">
          <TrendingUp className="size-5 text-accent" />
          <p className="text-sm font-medium text-muted-foreground">صافي العائد التشغيلي — Net Operating Return</p>
        </div>
        {pct !== null && (
          <span className={cn("inline-flex items-center gap-0.5 text-sm font-medium", colorClass)} dir="ltr">
            <Icon className="size-4" />
            {decimalAbsFixed(pct, 1)}% مقارنة بالفترة السابقة
          </span>
        )}
      </div>

      <p className="mt-2 text-3xl font-bold" dir="ltr">
        {formatSAR(total)}
      </p>

      <div className="mt-4 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground">
        {components.map((c, i) => (
          <span key={c.key} className="flex items-center gap-2">
            {i > 0 && <span className="text-border">+</span>}
            <span>
              {c.label}: <span dir="ltr">{c.key in nor ? formatSAR(String(nor[c.key])) : "—"}</span>
            </span>
          </span>
        ))}
        <span className="text-border">=</span>
        <span className="font-medium text-foreground">
          صافي العائد التشغيلي: <span dir="ltr">{formatSAR(total)}</span>
        </span>
      </div>
    </div>
  );
}

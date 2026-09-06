import { ArrowDownRight, ArrowUpRight, Minus, TrendingUp } from "lucide-react";
import { formatSAR } from "@/lib/money";
import { decimalSign, decimalAbsFixed } from "@/lib/decimal";
import { cn } from "@/lib/utils";
import { MANAGEMENT_NOR_FIELDS } from "@/features/reports/export/management-registry";

/**
 * §18/§20 — the operating-result hero card. Renders the formula itself
 * (Net Sales Profit + Net Shipping Result + Net Effective Adjustments
 * Profit) alongside the three components, so the figure is never a
 * "trust me" black box. Absent entirely if the actor lacks the permissions
 * that would reveal net_operating_return (§79).
 *
 * Phase 10 labelling: the long-standing `net_operating_return` value has
 * ALWAYS been an operating contribution measured BEFORE operating expenses —
 * its formula has no expense term at all. It is therefore labelled as such
 * here, so it is never read as an after-expenses result. When the actor also
 * holds expenses.view, migration 0236 supplies
 * `operating_expenses_total` / `net_operating_result_after_expenses`, and the
 * genuine after-expenses figure is shown beneath it. Neither the stored value
 * nor its meaning changed — only the wording, and the added second line.
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

  // Phase 10 (0236) — present only when the actor holds expenses.view.
  const hasExpenseView = "net_operating_result_after_expenses" in nor;
  const expensesTotal = hasExpenseView ? (nor.operating_expenses_total as string | number) : null;
  const afterExpenses = hasExpenseView ? (nor.net_operating_result_after_expenses as string | number) : null;

  return (
    <div className="mb-6 rounded-2xl border border-accent/30 bg-accent/5 p-5">
      <div className="flex flex-col items-start justify-between gap-3 sm:flex-row sm:items-center">
        <div className="flex items-center gap-2">
          <TrendingUp className="size-5 text-accent" />
          <p className="text-sm font-medium text-muted-foreground">المساهمة التشغيلية قبل المصروفات — Operating Contribution (before expenses)</p>
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
          المساهمة التشغيلية قبل المصروفات: <span dir="ltr">{formatSAR(total)}</span>
        </span>
      </div>

      {hasExpenseView && (
        <div className="mt-4 border-t border-accent/20 pt-4">
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground">
            <span>
              المساهمة قبل المصروفات: <span dir="ltr">{formatSAR(total)}</span>
            </span>
            <span className="text-border">−</span>
            <span>
              المصروفات التشغيلية: <span dir="ltr">{formatSAR(expensesTotal as string | number)}</span>
            </span>
            <span className="text-border">=</span>
            <span className="font-medium text-foreground">صافي النتيجة التشغيلية بعد المصروفات</span>
          </div>
          <p className="mt-1 text-2xl font-bold" dir="ltr">
            {formatSAR(afterExpenses as string | number)}
          </p>
        </div>
      )}
    </div>
  );
}

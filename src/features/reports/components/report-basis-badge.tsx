import { Info } from "lucide-react";

export const BASIS_LABELS_AR: Record<string, string> = {
  current_effective: "الأساس: الحالة الفعلية الحالية",
  movements_during_period: "الأساس: الحركات خلال الفترة",
  current_effective_impact_within_period: "الأساس: الأثر الفعلي الحالي ضمن الفترة",
  // Patch 8.1 §26-29/§30-32 — Returns' and COD's dual-basis values (0208/
  // 0209) were never added here, so their DEFAULT basis (`business_effect`
  // for Returns, always shown on first load) fell through to the `?? basis`
  // raw-string fallback below — a real, live "أساس: business_effect" label
  // leak on the Returns/COD report pages. Fixed by giving every basis value
  // any Reports RPC can return its own Arabic label.
  business_effect: "الأساس: الأثر التجاري المعتمد",
  actual_cash: "الأساس: التدفق النقدي الفعلي",
  collection_transitions: "الأساس: حركات التحصيل الفعلية",
};

/**
 * Options for a basis-selector dropdown, keyed by report so each dual-basis
 * report page only offers ITS OWN two valid values (never a value the RPC
 * itself would reject with a `basis غير صالح` exception, §84/§85).
 */
export const BASIS_SELECT_OPTIONS: Record<string, { value: string; label: string }[]> = {
  shipping: [
    { value: "current_effective", label: BASIS_LABELS_AR.current_effective },
    { value: "movements_during_period", label: BASIS_LABELS_AR.movements_during_period },
  ],
  returns: [
    { value: "business_effect", label: BASIS_LABELS_AR.business_effect },
    { value: "actual_cash", label: BASIS_LABELS_AR.actual_cash },
  ],
  cod: [
    { value: "current_effective", label: BASIS_LABELS_AR.current_effective },
    { value: "collection_transitions", label: BASIS_LABELS_AR.collection_transitions },
  ],
};

/**
 * Pure formatting shared by the on-screen badge below AND the PDF/Excel
 * export generators (§39) — one place decides the exact basis wording.
 */
export function formatBasisLines(basis?: string, rowBasis?: string, summaryBasis?: string): string[] {
  if (!basis && !rowBasis && !summaryBasis) return [];
  return basis
    ? [BASIS_LABELS_AR[basis] ?? basis]
    : ([
        rowBasis ? `الصفوف — ${BASIS_LABELS_AR[rowBasis] ?? rowBasis}` : null,
        summaryBasis ? `الإجمالي — ${BASIS_LABELS_AR[summaryBasis] ?? summaryBasis}` : null,
      ].filter(Boolean) as string[]);
}

/**
 * §83 Report Basis Indicator — reports must be explicit about whether
 * figures reflect "Current Effective" state or "Movements during the
 * Period" whenever that could be ambiguous. Renders nothing for a report
 * with no `basis`/`row_basis`+`summary_basis` field at all.
 */
export function ReportBasisBadge({ basis, rowBasis, summaryBasis }: { basis?: string; rowBasis?: string; summaryBasis?: string }) {
  const lines = formatBasisLines(basis, rowBasis, summaryBasis);
  if (lines.length === 0) return null;

  return (
    <div className="mb-4 flex items-start gap-2 rounded-lg border border-border bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
      <Info className="mt-0.5 size-3.5 shrink-0" />
      <div className="space-y-0.5">
        {lines.map((line, i) => (
          <p key={i}>{line}</p>
        ))}
      </div>
    </div>
  );
}

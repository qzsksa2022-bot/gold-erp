import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { formatSAR } from "@/lib/money";
import { formatRiyadhDate } from "@/lib/date";
import { MANAGEMENT_BREAKDOWN_COLUMNS, MANAGEMENT_BREAKDOWN_GRANULARITY_LABELS_AR } from "@/features/reports/export/management-registry";

function formatBreakdownCell(raw: unknown, format: "money" | "int"): React.ReactNode {
  if (raw === null || raw === undefined) return <span className="text-muted-foreground">—</span>;
  // no-float-ok: "int" is a count, never money/weight/percent — single-shot Intl.NumberFormat argument, not used in further arithmetic (§21).
  return format === "money" ? formatSAR(raw as string | number) : new Intl.NumberFormat("ar-SA").format(Number(raw));
}

/**
 * Hotfix 8.1.2 §6-15 — Weekly/Monthly/Yearly Management Report period
 * breakdown table. Reads `report.breakdown`/`report.breakdown_granularity`
 * (0222) verbatim — the same `get_dashboard_trends()` bucket shape the
 * Dashboard's own trend chart already renders (bucket_start/bucket_end/
 * bucket_label + a true-key-absence-redacted set of financial columns,
 * §79). Daily has no `breakdown` key at all (a single business_date IS
 * already the smallest report unit, per 0222's own comment) so this
 * renders nothing for it — the caller simply never mounts it on that page.
 */
export function ManagementBreakdownTable({ breakdown, granularity }: { breakdown: unknown; granularity: unknown }) {
  if (!Array.isArray(breakdown) || breakdown.length === 0) return null;
  const rows = breakdown as Record<string, unknown>[];
  const gran = typeof granularity === "string" ? granularity : "day";
  const granLabel = MANAGEMENT_BREAKDOWN_GRANULARITY_LABELS_AR[gran] ?? gran;
  const visibleColumns = MANAGEMENT_BREAKDOWN_COLUMNS.filter((c) => c.key in rows[0]);

  return (
    <div className="mb-6">
      <h2 className="mb-2 text-sm font-semibold text-muted-foreground">التفصيل حسب {granLabel}</h2>
      <div className="rounded-xl border border-border bg-card">
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>الفترة</TableHead>
                {visibleColumns.map((c) => (
                  <TableHead key={c.key}>{c.label}</TableHead>
                ))}
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row, i) => (
                <TableRow key={String(row.bucket_start ?? i)}>
                  <TableCell className="text-sm">
                    {gran === "month" || typeof row.bucket_start !== "string" ? String(row.bucket_label ?? "") : formatRiyadhDate(row.bucket_start)}
                  </TableCell>
                  {visibleColumns.map((c) => (
                    <TableCell key={c.key} className="text-sm" dir="ltr">
                      {formatBreakdownCell(row[c.key], c.format)}
                    </TableCell>
                  ))}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </div>
    </div>
  );
}

import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/shared/empty-state";
import { formatSAR, formatGrams } from "@/lib/money";
import { formatRiyadhDate } from "@/lib/date";
import type { LucideIcon } from "lucide-react";
import type { PermissionKey } from "@/lib/permissions/constants";

export type ColumnFormat = "money" | "weight" | "int" | "date" | "text" | "badge";

export interface ReportColumnConfig {
  key: string;
  label: string;
  format: ColumnFormat;
  /** Hide on small screens (mirrors the "hidden sm:table-cell" convention used across every existing list page). */
  hiddenOnSmall?: boolean;
  /** For format="badge" — maps a raw value to a Badge variant. */
  badgeVariant?: (value: unknown) => "default" | "secondary" | "success" | "warning" | "destructive" | "accent";
  /** For format="badge"/"text" — maps a raw value to its display label. */
  labelMap?: Record<string, string>;
  /**
   * Patch 8.1 §15/§16/§61/§62 — the underlying report RPC key-absence
   * pattern (§79) already hides this column's data from a caller lacking
   * this permission (the row simply never has the key). On SCREEN that is
   * enough by itself: `visibleColumns` below already filters by
   * `c.key in rows[0]`, so a redacted column's header never renders here.
   * This metadata exists so the EXPORT route (`api/reports/export/route.ts`)
   * can filter `definition.columns` the SAME way BEFORE handing them to the
   * PDF/Excel renderers — those iterate `definition.columns`
   * unconditionally and cannot rely on "first row has the key" (an empty
   * report has zero rows, §61/§62's explicit required test case). Declaring
   * `permission` here is what lets the export route drop a forbidden
   * column's header entirely, never a blank/null cell.
   */
  permission?: PermissionKey;
}

function formatCell(raw: unknown, col: ReportColumnConfig): React.ReactNode {
  if (raw === null || raw === undefined) return <span className="text-muted-foreground">—</span>;
  switch (col.format) {
    case "money":
      return formatSAR(raw as string | number);
    case "weight":
      return formatGrams(raw as string | number);
    case "int":
      // no-float-ok: a count, never money/weight/percent — single-shot Intl.NumberFormat argument, not used in further arithmetic (§21).
      return new Intl.NumberFormat("ar-SA").format(Number(raw));
    case "date":
      return formatRiyadhDate(raw as string);
    case "badge": {
      const label = col.labelMap?.[String(raw)] ?? String(raw);
      const variant = col.badgeVariant?.(raw) ?? "secondary";
      return <Badge variant={variant}>{label}</Badge>;
    }
    default:
      return col.labelMap?.[String(raw)] ?? String(raw);
  }
}

/**
 * Renders a report's paginated `rows` array (§21-§37) as a table — a
 * column is included in `columns` config per-page, but only actually
 * rendered when the FIRST row (or, absent rows, none) carries that key at
 * all: a redacted financial column (§79) is simply not present on any row,
 * so it never shows up here rather than rendering as a column of "—".
 */
export function ReportTable({
  rows,
  columns,
  emptyIcon,
  emptyTitle,
  emptyDescription,
  rowKey,
  footer,
}: {
  rows: Record<string, unknown>[];
  columns: ReportColumnConfig[];
  emptyIcon: LucideIcon;
  emptyTitle: string;
  emptyDescription: string;
  rowKey: string;
  /** Rendered inside the same bordered card, below the table (e.g. <Pagination>). */
  footer?: React.ReactNode;
}) {
  if (rows.length === 0) {
    return <EmptyState icon={emptyIcon} title={emptyTitle} description={emptyDescription} />;
  }

  const visibleColumns = columns.filter((c) => c.key in rows[0]);

  return (
    <div className="rounded-xl border border-border bg-card">
    <div className="overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            {visibleColumns.map((c) => (
              <TableHead key={c.key} className={c.hiddenOnSmall ? "hidden sm:table-cell" : undefined}>
                {c.label}
              </TableHead>
            ))}
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row, i) => (
            <TableRow key={String(row[rowKey] ?? i)}>
              {visibleColumns.map((c) => (
                <TableCell key={c.key} className={c.hiddenOnSmall ? "hidden text-sm sm:table-cell" : "text-sm"} dir={c.format === "money" || c.format === "weight" || c.format === "int" ? "ltr" : undefined}>
                  {formatCell(row[c.key], c)}
                </TableCell>
              ))}
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
      {footer}
    </div>
  );
}

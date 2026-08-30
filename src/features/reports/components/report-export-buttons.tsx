import { FileDown, FileSpreadsheet } from "lucide-react";
import { Button } from "@/components/ui/button";

/**
 * §44 — "PDF"/"Excel" export buttons for a report page. Forwards the
 * page's OWN current URL search params (date range, store, every filter)
 * verbatim to `/api/reports/export`, so the export always reflects exactly
 * what is on screen right now — same filters, same scope. A plain `<a
 * href>` (not `next/link`) is used deliberately: this is a real file
 * download/navigation, not a client-side route transition.
 *
 * Each button is only rendered if the actor actually holds the matching
 * `reports.export_pdf`/`reports.export_excel` permission (§79 style —
 * hidden, not disabled, when absent); the export route re-checks both that
 * and the report's own domain permission server-side regardless.
 */
export function ReportExportButtons({
  slug,
  searchParams,
  canPdf,
  canExcel,
}: {
  slug: string;
  searchParams: Record<string, string | string[] | undefined>;
  canPdf: boolean;
  canExcel: boolean;
}) {
  if (!canPdf && !canExcel) return null;

  function href(format: "pdf" | "excel"): string {
    const qs = new URLSearchParams();
    for (const [key, value] of Object.entries(searchParams)) {
      if (typeof value === "string" && value) qs.set(key, value);
    }
    qs.set("report", slug);
    qs.set("format", format);
    return `/api/reports/export?${qs.toString()}`;
  }

  return (
    <div className="flex items-center gap-2">
      {canPdf && (
        <Button asChild variant="outline" size="sm">
          <a href={href("pdf")}>
            <FileDown className="size-4" />
            PDF
          </a>
        </Button>
      )}
      {canExcel && (
        <Button asChild variant="outline" size="sm">
          <a href={href("excel")}>
            <FileSpreadsheet className="size-4" />
            Excel
          </a>
        </Button>
      )}
    </div>
  );
}

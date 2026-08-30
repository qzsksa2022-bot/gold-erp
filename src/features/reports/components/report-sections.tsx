import { EmptyState } from "@/components/shared/empty-state";
import { ReportSummaryCards } from "./report-summary-cards";
import { ReportTable } from "./report-table";
import type { ReportSectionDefinition } from "../export/presentation";
import type { LucideIcon } from "lucide-react";

/**
 * Hotfix 8.1.1 §1/§5/§46 — renders whatever `resolveReportSections()`
 * resolved for the current envelope: ONE section for a single-shape
 * report, or a basis-varying report's ONE currently-selected-basis
 * section, or several genuinely independent sections (Payment Methods:
 * Sales/Refund/Settlement; COD: current_effective|collection_transitions
 * + optional Settlement) — each with its OWN summary cards and table,
 * under its own heading whenever more than one section is present (a
 * single-section report's own page title already says this, §17 parity
 * with the PDF/Excel renderers).
 *
 * §55-E — a caller resolved to ZERO sections at all (e.g. an actor with
 * only the base `reports.view` permission and no section-granting domain
 * permission) gets ONE safe empty state, never a crash and never a
 * fabricated section — matching `renderTableReportPdf`/
 * `renderTableReportExcel`'s own empty-sections handling.
 *
 * Only the PRIMARY section (`unpaginated` falsy — always the first/only
 * section a paginated RPC call actually limits/offsets) ever receives the
 * page's `<Pagination>` footer; every secondary section (refund_rows/
 * settlement_rows) always returns its complete matching set and is never
 * paginated (§9/§31), so it renders with no footer at all.
 */
export function ReportSections({
  sections,
  emptyIcon,
  emptyTitle,
  emptyDescription,
  primaryFooter,
}: {
  sections: ReportSectionDefinition[];
  emptyIcon: LucideIcon;
  emptyTitle: string;
  emptyDescription: string;
  /** Rendered below the table ONLY for the primary (paginated) section — e.g. <Pagination>. */
  primaryFooter?: React.ReactNode;
}) {
  if (sections.length === 0) {
    return <EmptyState icon={emptyIcon} title="لا توجد أقسام مصرّح بعرضها" description="لا تملك صلاحية عرض أي قسم من هذا التقرير." />;
  }

  return (
    <div className="space-y-8">
      {sections.map((section) => (
        <div key={section.key}>
          {sections.length > 1 && <h3 className="mb-3 text-sm font-semibold text-foreground">{section.titleAr}</h3>}
          <ReportSummaryCards summary={section.summary} fields={section.summaryFields} />
          <ReportTable
            rows={section.rows}
            columns={section.columns}
            rowKey={section.rowKey}
            emptyIcon={emptyIcon}
            emptyTitle={emptyTitle}
            emptyDescription={emptyDescription}
            footer={!section.unpaginated ? primaryFooter : undefined}
          />
        </div>
      ))}
    </div>
  );
}

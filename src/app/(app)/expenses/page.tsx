import Link from "next/link";
import { Receipt, Tags } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getStoreExpenses, getActiveExpenseCategories, EXPENSES_PAGE_SIZE } from "@/features/expenses/queries";
import { getReportVisibleStores } from "@/features/reports/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Can } from "@/lib/permissions/context";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { ReportExportButtons } from "@/features/reports/components/report-export-buttons";
import { ExpenseRecordDialog } from "@/features/expenses/components/expense-record-dialog";
import { ExpenseReverseDialog } from "@/features/expenses/components/expense-reverse-dialog";
import { EXPENSE_ENTRY_KIND_LABELS_AR } from "@/features/expenses/schema";
import { ROUTES } from "@/lib/constants";
import { riyadhTodayIsoDate, formatRiyadhDate } from "@/lib/date";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

export default async function ExpensesPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("expenses.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const dateFrom = str("date_from") || monthStart();
  const dateTo = str("date_to") || riyadhTodayIsoDate();
  const storeId = str("store_id") || undefined;
  const categoryId = str("expense_category_id") || undefined;
  const entryKind = str("entry_kind") || undefined;
  const search = str("search") || undefined;

  const [envelope, stores, categories] = await Promise.all([
    getStoreExpenses({
      date_from: dateFrom,
      date_to: dateTo,
      store_ids: storeId ? [storeId] : undefined,
      expense_category_id: categoryId,
      entry_kind: entryKind,
      search,
      page,
    }),
    getReportVisibleStores(),
    // The record dialog may only offer ACTIVE categories; an actor without
    // expenses.create never sees it, so a failure here must not break the page.
    getActiveExpenseCategories().catch(() => []),
  ]);

  const { rows, summary, total_count: totalCount } = envelope;

  return (
    <div>
      <PageHeader
        title="مصروفات الفروع"
        description="دفتر المصروفات التشغيلية — سجل إضافي فقط: التصحيح يتم بحركة عكس مؤرَّخة، ولا يُعدَّل أو يُحذف أي قيد."
        actions={
          <div className="flex flex-wrap gap-2">
            <Can permission="expenses.manage_categories">
              <Button asChild variant="outline">
                <Link href={ROUTES.expenseCategories}>
                  <Tags className="size-4" />
                  التصنيفات
                </Link>
              </Button>
            </Can>
            <ReportExportButtons
              slug="expenses"
              searchParams={sp}
              canPdf={sessionHasPermission(session, "reports.export_pdf")}
              canExcel={sessionHasPermission(session, "reports.export_excel")}
            />
            <Can permission="expenses.create">
              <ExpenseRecordDialog stores={stores} categories={categories} />
            </Can>
          </div>
        }
      />

      <ReportFilterBar
        search={search}
        dateFrom={dateFrom}
        dateTo={dateTo}
        storeId={storeId}
        stores={stores}
        searchPlaceholder="رقم المصروف أو الوصف..."
        selects={[
          {
            key: "expense_category_id",
            placeholder: "التصنيف",
            allLabel: "كل التصنيفات",
            value: categoryId ?? "",
            options: categories.map((c) => ({ value: c.id, label: c.name_ar })),
          },
          {
            key: "entry_kind",
            placeholder: "نوع الحركة",
            allLabel: "الكل",
            value: entryKind ?? "",
            options: [
              { value: "expense", label: EXPENSE_ENTRY_KIND_LABELS_AR.expense },
              { value: "reversal", label: EXPENSE_ENTRY_KIND_LABELS_AR.reversal },
            ],
          },
        ]}
      />

      {/* Every figure below is server-computed from the append-only ledger and
          arrives as text — nothing here re-adds or re-parses a money value. */}
      <div className="mb-4 grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">إجمالي المصروفات المسجَّلة</p>
          <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
            {summary.gross_expenses_total}
          </p>
        </div>
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">إجمالي حركات العكس</p>
          <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
            {summary.reversals_total}
          </p>
        </div>
        <div className="rounded-xl border border-accent/30 bg-accent/5 p-4">
          <p className="text-xs text-muted-foreground">صافي المصروفات التشغيلية</p>
          <p className="mt-1 font-mono text-lg font-semibold text-accent" dir="ltr">
            {summary.operating_expenses_total}
          </p>
        </div>
      </div>

      {rows.length === 0 ? (
        <EmptyState icon={Receipt} title="لا توجد مصروفات مطابقة" description="جرّب تعديل الفلاتر أو نطاق التاريخ، أو سجّل مصروفًا جديدًا." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>الرقم</TableHead>
                <TableHead>التاريخ</TableHead>
                <TableHead>الفرع</TableHead>
                <TableHead>التصنيف</TableHead>
                <TableHead>النوع</TableHead>
                <TableHead>المبلغ</TableHead>
                <TableHead className="hidden lg:table-cell">الوصف</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="font-mono text-sm" dir="ltr">
                    {row.expense_number}
                  </TableCell>
                  <TableCell className="text-sm">{formatRiyadhDate(row.business_date)}</TableCell>
                  <TableCell className="text-sm">{row.store_name}</TableCell>
                  <TableCell className="text-sm">{row.category_name}</TableCell>
                  <TableCell>
                    <Badge variant={row.entry_kind === "reversal" ? "secondary" : "outline"}>{EXPENSE_ENTRY_KIND_LABELS_AR[row.entry_kind]}</Badge>
                  </TableCell>
                  <TableCell className="font-mono text-sm font-medium" dir="ltr">
                    {row.amount}
                  </TableCell>
                  <TableCell className="hidden max-w-xs truncate text-sm text-muted-foreground lg:table-cell">{row.description ?? "—"}</TableCell>
                  <TableCell>
                    {row.entry_kind === "expense" && !row.is_reversed && (
                      <Can permission="expenses.reverse">
                        <ExpenseReverseDialog expenseId={row.id} expenseNumber={row.expense_number} amount={row.amount} />
                      </Can>
                    )}
                    {row.entry_kind === "expense" && row.is_reversed && <span className="text-xs text-muted-foreground">معكوس</span>}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <Pagination
            page={page}
            pageSize={EXPENSES_PAGE_SIZE}
            total={totalCount}
            buildHref={(p) => {
              const params = new URLSearchParams();
              params.set("date_from", dateFrom);
              params.set("date_to", dateTo);
              if (storeId) params.set("store_id", storeId);
              if (categoryId) params.set("expense_category_id", categoryId);
              if (entryKind) params.set("entry_kind", entryKind);
              if (search) params.set("search", search);
              params.set("page", String(p));
              return `${ROUTES.expenses}?${params.toString()}`;
            }}
          />
        </div>
      )}
    </div>
  );
}

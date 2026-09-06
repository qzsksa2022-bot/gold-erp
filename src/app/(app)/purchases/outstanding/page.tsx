import Link from "next/link";
import { Wallet, ArrowRight } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { getSupplierOutstanding, getSupplierStatement } from "@/features/purchases/queries";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { ROUTES } from "@/lib/constants";
import { riyadhTodayIsoDate, formatRiyadhDate } from "@/lib/date";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

/**
 * Supplier liabilities, plus a per-supplier statement when one is selected.
 *
 * Every figure is derived live from the immutable invoice and payment ledgers
 * (migration 0240) — there is no cached "balance owed" column anywhere in the
 * schema, so these numbers cannot drift out of agreement with the documents
 * that produced them.
 */
export default async function SupplierOutstandingPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await requirePermission("purchases.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");

  const supplierId = str("supplier_id") || undefined;
  const dateFrom = str("date_from") || monthStart();
  const dateTo = str("date_to") || riyadhTodayIsoDate();

  const [outstanding, statement] = await Promise.all([
    getSupplierOutstanding(),
    supplierId ? getSupplierStatement(supplierId, dateFrom, dateTo).catch(() => null) : Promise.resolve(null),
  ]);

  return (
    <div>
      <PageHeader
        title="المستحق للموردين"
        description="الرصيد المستحق محسوب لحظيًا من الفواتير والدفعات غير القابلة للتعديل — لا يوجد رصيد مخزَّن يمكن أن يختلف عن مستنداته. الفواتير المعكوسة لا تُحتسب."
        actions={
          <Button asChild variant="outline">
            <Link href={ROUTES.purchases}>
              <ArrowRight className="size-4" />
              عودة للمشتريات
            </Link>
          </Button>
        }
      />

      <div className="mb-4 rounded-xl border border-accent/30 bg-accent/5 p-4">
        <p className="text-xs text-muted-foreground">إجمالي المستحق لكل الموردين</p>
        <p className="mt-1 font-mono text-2xl font-semibold text-accent" dir="ltr">
          {outstanding.summary.outstanding_total}
        </p>
      </div>

      {outstanding.rows.length === 0 ? (
        <EmptyState icon={Wallet} title="لا توجد التزامات قائمة" description="كل فواتير الشراء ضمن نطاقك مسدَّدة بالكامل أو معكوسة." />
      ) : (
        <div className="mb-8 rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>المورّد</TableHead>
                <TableHead>فواتير قائمة</TableHead>
                <TableHead>المستحق</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {outstanding.rows.map((row) => (
                <TableRow key={row.supplier_id}>
                  <TableCell className="text-sm font-medium">{row.supplier_name}</TableCell>
                  <TableCell className="text-sm">{row.open_invoices_count}</TableCell>
                  <TableCell className="font-mono text-sm font-medium" dir="ltr">
                    {row.outstanding}
                  </TableCell>
                  <TableCell>
                    <Button asChild variant="ghost" size="sm">
                      <Link href={`${ROUTES.purchasesOutstanding}?supplier_id=${row.supplier_id}&date_from=${dateFrom}&date_to=${dateTo}`}>كشف الحساب</Link>
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {statement && (
        <>
          <h2 className="mb-1 text-sm font-semibold">
            كشف حساب {statement.supplier_name}
            {statement.supplier_vat_number && (
              <span className="ms-2 font-mono text-xs font-normal text-muted-foreground" dir="ltr">
                {statement.supplier_vat_number}
              </span>
            )}
          </h2>
          <p className="mb-3 text-xs text-muted-foreground">
            من {formatRiyadhDate(statement.date_from)} إلى {formatRiyadhDate(statement.date_to)}
          </p>

          {/* Period MOVEMENT. */}
          <div className="mb-4 grid grid-cols-1 gap-4 sm:grid-cols-3">
            <div className="rounded-xl border border-border bg-card p-4">
              <p className="text-xs text-muted-foreground">إجمالي المُفوتر خلال الفترة</p>
              <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
                {statement.summary.invoiced_total}
              </p>
            </div>
            <div className="rounded-xl border border-border bg-card p-4">
              <p className="text-xs text-muted-foreground">إجمالي المسدَّد خلال الفترة</p>
              <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
                {statement.summary.paid_total}
              </p>
            </div>
            <div className="rounded-xl border border-border bg-card p-4">
              <p className="text-xs text-muted-foreground">صافي الحركة</p>
              <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
                {statement.summary.net_movement}
              </p>
            </div>
          </div>

          {/* BALANCES. Kept visually separate from the movement figures above,
              and each labelled with the date it is "as of" — a single
              unqualified "balance" is exactly what makes a statement
              impossible to reconcile. */}
          <div className="mb-4 grid grid-cols-1 gap-4 sm:grid-cols-3">
            <div className="rounded-xl border border-border bg-card p-4">
              <p className="text-xs text-muted-foreground">الرصيد الافتتاحي — قبل {formatRiyadhDate(statement.date_from)}</p>
              <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
                {statement.summary.opening_balance}
              </p>
            </div>
            <div className="rounded-xl border border-accent/30 bg-accent/5 p-4">
              <p className="text-xs text-muted-foreground">الرصيد حتى {formatRiyadhDate(statement.date_to)}</p>
              <p className="mt-1 font-mono text-lg font-semibold text-accent" dir="ltr">
                {statement.summary.closing_balance}
              </p>
              <p className="mt-1 text-xs text-muted-foreground">لا يتأثر بأي حركة لاحقة لهذا التاريخ.</p>
            </div>
            <div className="rounded-xl border border-border bg-card p-4">
              <p className="text-xs text-muted-foreground">الرصيد الحالي — اليوم</p>
              <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
                {statement.summary.current_balance}
              </p>
              {statement.summary.current_balance !== statement.summary.closing_balance && (
                <p className="mt-1 text-xs text-warning">يختلف عن الرصيد حتى تاريخ التقرير بسبب حركات لاحقة.</p>
              )}
            </div>
          </div>

          <div className="rounded-xl border border-border bg-card">
            {statement.entries.length === 0 ? (
              <p className="p-6 text-center text-sm text-muted-foreground">لا توجد حركات لهذا المورّد خلال الفترة المحددة.</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>المرجع</TableHead>
                    <TableHead>التاريخ</TableHead>
                    <TableHead>النوع</TableHead>
                    <TableHead>المبلغ</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {statement.entries.map((e) => (
                    <TableRow key={`${e.kind}-${e.reference}`}>
                      <TableCell className="font-mono text-sm" dir="ltr">
                        {e.reference}
                      </TableCell>
                      <TableCell className="text-sm">{formatRiyadhDate(e.business_date)}</TableCell>
                      <TableCell>
                        <Badge variant={e.entry_kind === "reversal" ? "secondary" : "outline"}>
                          {e.entry_kind === "reversal" ? "عكس" : e.kind === "invoice" ? "فاتورة" : "دفعة"}
                        </Badge>
                      </TableCell>
                      <TableCell className="font-mono text-sm font-medium" dir="ltr">
                        {e.amount}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </div>
        </>
      )}
    </div>
  );
}

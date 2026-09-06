import Link from "next/link";
import { PackagePlus, Users, Plus, Wallet } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { sessionHasPermission } from "@/lib/permissions/session";
import { getPurchaseInvoices, getActiveSuppliers, PURCHASES_PAGE_SIZE } from "@/features/purchases/queries";
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
import { PAYMENT_STATUS_LABELS_AR } from "@/features/purchases/schema";
import { ROUTES } from "@/lib/constants";
import { riyadhTodayIsoDate, formatRiyadhDate } from "@/lib/date";

function monthStart(): string {
  return `${riyadhTodayIsoDate().slice(0, 7)}-01`;
}

function statusVariant(status: string): "success" | "warning" | "destructive" | "secondary" {
  if (status === "paid") return "success";
  if (status === "partial") return "warning";
  if (status === "reversed" || status === "reversal") return "destructive";
  return "secondary";
}

export default async function PurchasesPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const session = await requirePermission("purchases.view");
  const sp = await searchParams;
  const str = (k: string) => (typeof sp[k] === "string" ? (sp[k] as string) : "");
  const page = Math.max(1, Number(str("page")) || 1);

  const dateFrom = str("date_from") || monthStart();
  const dateTo = str("date_to") || riyadhTodayIsoDate();
  const storeId = str("store_id") || undefined;
  const supplierId = str("supplier_id") || undefined;
  const entryKind = str("entry_kind") || undefined;
  const paymentStatus = str("payment_status") || undefined;
  const search = str("search") || undefined;

  const [envelope, stores, suppliers] = await Promise.all([
    getPurchaseInvoices({
      date_from: dateFrom,
      date_to: dateTo,
      store_ids: storeId ? [storeId] : undefined,
      supplier_id: supplierId,
      entry_kind: entryKind,
      payment_status: paymentStatus,
      search,
      page,
    }),
    getReportVisibleStores(),
    // The supplier filter only lists ACTIVE suppliers; an actor without
    // purchases.manage_suppliers can still read them, so a failure here must
    // not break the page.
    getActiveSuppliers().catch(() => []),
  ]);

  const { rows, summary, total_count: totalCount } = envelope;

  return (
    <div>
      <PageHeader
        title="المشتريات والموردون"
        description="دفتر فواتير الشراء — سجل إضافي فقط: التصحيح يتم بمستند عكس مؤرَّخ، ولا تُعدَّل فاتورة ولا تُحذف. ترحيل الفاتورة يُدخل كمياتها للمخزون في نفس العملية."
        actions={
          <div className="flex flex-wrap gap-2">
            <Button asChild variant="outline">
              <Link href={ROUTES.purchasesOutstanding}>
                <Wallet className="size-4" />
                المستحق للموردين
              </Link>
            </Button>
            <Can permission="purchases.manage_suppliers">
              <Button asChild variant="outline">
                <Link href={ROUTES.suppliers}>
                  <Users className="size-4" />
                  الموردون
                </Link>
              </Button>
            </Can>
            <ReportExportButtons
              slug="purchases"
              searchParams={sp}
              canPdf={sessionHasPermission(session, "reports.export_pdf")}
              canExcel={sessionHasPermission(session, "reports.export_excel")}
            />
            <Can permission="purchases.create">
              <Button asChild>
                <Link href={ROUTES.purchasesNew}>
                  <Plus className="size-4" />
                  فاتورة شراء
                </Link>
              </Button>
            </Can>
          </div>
        }
      />

      {/* Decision 5, stated on the screen an operator lives in. */}
      <p className="mb-4 rounded-lg border border-border bg-muted/40 p-3 text-xs text-muted-foreground">
        مشتريات المخزون اقتناء أصل، وليست مصروفًا تشغيليًا: هذه المبالغ لا تدخل في شاشة المصروفات ولا في صافي العائد التشغيلي ولا في تكلفة البضاعة المباعة.
      </p>

      <ReportFilterBar
        search={search}
        dateFrom={dateFrom}
        dateTo={dateTo}
        storeId={storeId}
        stores={stores}
        searchPlaceholder="رقم المستند أو رقم فاتورة المورّد..."
        selects={[
          {
            key: "supplier_id",
            placeholder: "المورّد",
            allLabel: "كل الموردين",
            value: supplierId ?? "",
            options: suppliers.map((s) => ({ value: s.id, label: s.name_ar })),
          },
          {
            key: "payment_status",
            placeholder: "حالة السداد",
            allLabel: "الكل",
            value: paymentStatus ?? "",
            options: [
              { value: "unpaid", label: PAYMENT_STATUS_LABELS_AR.unpaid },
              { value: "partial", label: PAYMENT_STATUS_LABELS_AR.partial },
              { value: "paid", label: PAYMENT_STATUS_LABELS_AR.paid },
              { value: "reversed", label: PAYMENT_STATUS_LABELS_AR.reversed },
            ],
          },
          {
            key: "entry_kind",
            placeholder: "نوع المستند",
            allLabel: "الكل",
            value: entryKind ?? "",
            options: [
              { value: "invoice", label: "فاتورة" },
              { value: "reversal", label: "مستند عكس" },
            ],
          },
        ]}
      />

      {/* Every figure below is server-computed from the append-only ledgers and
          arrives as text — nothing here re-adds or re-parses a money value. */}
      <div className="mb-4 grid grid-cols-1 gap-4 sm:grid-cols-4">
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">إجمالي الصافي</p>
          <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
            {summary.net_total}
          </p>
        </div>
        <div className="rounded-xl border border-border bg-card p-4">
          {/* Named precisely: this is what suppliers charged, not a recoverable amount. */}
          <p className="text-xs text-muted-foreground">الضريبة كما وردت من الموردين</p>
          <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
            {summary.vat_total}
          </p>
        </div>
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">إجمالي المشتريات</p>
          <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
            {summary.gross_total}
          </p>
        </div>
        <div className="rounded-xl border border-accent/30 bg-accent/5 p-4">
          <p className="text-xs text-muted-foreground">المستحق للموردين</p>
          <p className="mt-1 font-mono text-lg font-semibold text-accent" dir="ltr">
            {summary.outstanding_total}
          </p>
        </div>
      </div>

      {rows.length === 0 ? (
        <EmptyState icon={PackagePlus} title="لا توجد فواتير شراء مطابقة" description="جرّب تعديل الفلاتر أو نطاق التاريخ، أو رحّل فاتورة شراء جديدة." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>رقم المستند</TableHead>
                <TableHead>التاريخ</TableHead>
                <TableHead>المورّد</TableHead>
                <TableHead className="hidden lg:table-cell">فاتورة المورّد</TableHead>
                <TableHead className="hidden sm:table-cell">الفرع</TableHead>
                <TableHead>الحالة</TableHead>
                <TableHead>الإجمالي</TableHead>
                <TableHead>المتبقي</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="font-mono text-sm" dir="ltr">
                    <Link href={`${ROUTES.purchases}/${row.id}`} className="text-accent hover:underline">
                      {row.purchase_number}
                    </Link>
                  </TableCell>
                  <TableCell className="text-sm">{formatRiyadhDate(row.business_date)}</TableCell>
                  <TableCell className="text-sm">{row.supplier_name}</TableCell>
                  <TableCell className="hidden font-mono text-sm text-muted-foreground lg:table-cell" dir="ltr">
                    {row.supplier_invoice_number ?? "—"}
                  </TableCell>
                  <TableCell className="hidden text-sm sm:table-cell">{row.store_name}</TableCell>
                  <TableCell>
                    <Badge variant={statusVariant(row.payment_status)}>{PAYMENT_STATUS_LABELS_AR[row.payment_status] ?? row.payment_status}</Badge>
                  </TableCell>
                  <TableCell className="font-mono text-sm font-medium" dir="ltr">
                    {row.gross_total}
                  </TableCell>
                  <TableCell className="font-mono text-sm" dir="ltr">
                    {row.outstanding}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <Pagination
            page={page}
            pageSize={PURCHASES_PAGE_SIZE}
            total={totalCount}
            buildHref={(p) => {
              const params = new URLSearchParams();
              params.set("date_from", dateFrom);
              params.set("date_to", dateTo);
              if (storeId) params.set("store_id", storeId);
              if (supplierId) params.set("supplier_id", supplierId);
              if (entryKind) params.set("entry_kind", entryKind);
              if (paymentStatus) params.set("payment_status", paymentStatus);
              if (search) params.set("search", search);
              params.set("page", String(p));
              return `${ROUTES.purchases}?${params.toString()}`;
            }}
          />
        </div>
      )}
    </div>
  );
}

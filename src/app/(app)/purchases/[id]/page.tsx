import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowRight } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { getPurchaseInvoice } from "@/features/purchases/queries";
import { PageHeader } from "@/components/shared/page-header";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Can } from "@/lib/permissions/context";
import { PurchaseReverseDialog, SupplierPaymentDialog, SupplierPaymentReverseDialog } from "@/features/purchases/components/purchase-dialogs";
import { TAX_TREATMENT_LABELS_AR, PAYMENT_MODE_LABELS_AR, type TaxTreatment, type PaymentMode } from "@/features/purchases/schema";
import { ROUTES } from "@/lib/constants";
import { formatRiyadhDate } from "@/lib/date";

export default async function PurchaseInvoiceDetailPage({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission("purchases.view");
  const { id } = await params;

  // get_purchase_invoice() raises for an invoice outside the caller's visible
  // store scope, which is indistinguishable from "does not exist" — deliberately.
  const invoice = await getPurchaseInvoice(id).catch(() => null);
  if (!invoice) notFound();

  const isInvoice = invoice.entry_kind === "invoice";
  const hasUnreversedPayment = invoice.payments.some((p) => p.entry_kind === "payment" && !p.is_reversed);
  const canPay = isInvoice && !invoice.is_reversed && invoice.outstanding !== "0.00";

  return (
    <div>
      <PageHeader
        title={`فاتورة شراء ${invoice.purchase_number}`}
        description={
          isInvoice
            ? "مستند شراء مرحَّل. لا يُعدَّل ولا يُحذف — التصحيح يتم بمستند عكس مؤرَّخ."
            : "مستند عكس مؤرَّخ. أنشئ لتصفية فاتورة شراء سابقة، ولا يُعكس بدوره."
        }
        actions={
          <div className="flex flex-wrap gap-2">
            <Button asChild variant="outline">
              <Link href={ROUTES.purchases}>
                <ArrowRight className="size-4" />
                عودة للمشتريات
              </Link>
            </Button>
            {canPay && (
              <Can permission="purchases.record_payment">
                <SupplierPaymentDialog invoiceId={invoice.id} purchaseNumber={invoice.purchase_number} outstanding={invoice.outstanding} />
              </Can>
            )}
            {isInvoice && !invoice.is_reversed && (
              <Can permission="purchases.reverse">
                <PurchaseReverseDialog
                  invoiceId={invoice.id}
                  purchaseNumber={invoice.purchase_number}
                  grossTotal={invoice.gross_total}
                  hasUnreversedPayment={hasUnreversedPayment}
                />
              </Can>
            )}
          </div>
        }
      />

      {invoice.is_reversed && (
        <p className="mb-4 rounded-lg border border-destructive/40 bg-destructive/5 p-3 text-sm text-destructive">
          هذه الفاتورة معكوسة بالكامل بمستند عكس مؤرَّخ، ولا يترتب عليها أي التزام تجاه المورّد.
        </p>
      )}

      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">المورّد</p>
          <p className="mt-1 text-sm font-medium">{invoice.supplier_name}</p>
          {/* The supplier's VAT number as it was at posting time — a snapshot,
              not a live lookup, so editing the supplier never rewrites history. */}
          <p className="mt-1 font-mono text-xs text-muted-foreground" dir="ltr">
            {invoice.supplier_vat_number ?? "—"}
          </p>
        </div>
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">تاريخ الترحيل</p>
          <p className="mt-1 text-sm font-medium">{formatRiyadhDate(invoice.business_date)}</p>
        </div>
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">فاتورة المورّد</p>
          <p className="mt-1 font-mono text-sm font-medium" dir="ltr">
            {invoice.supplier_invoice_number ?? "—"}
          </p>
          <p className="mt-1 text-xs text-muted-foreground">
            {invoice.supplier_invoice_date ? formatRiyadhDate(invoice.supplier_invoice_date) : "—"}
          </p>
        </div>
        <div className="rounded-xl border border-accent/30 bg-accent/5 p-4">
          <p className="text-xs text-muted-foreground">المتبقي</p>
          <p className="mt-1 font-mono text-lg font-semibold text-accent" dir="ltr">
            {invoice.outstanding}
          </p>
        </div>
      </div>

      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">الصافي</p>
          <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
            {invoice.net_total}
          </p>
        </div>
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">الضريبة كما وردت من المورّد</p>
          <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
            {invoice.vat_total}
          </p>
        </div>
        <div className="rounded-xl border border-border bg-card p-4">
          <p className="text-xs text-muted-foreground">الإجمالي</p>
          <p className="mt-1 font-mono text-lg font-semibold" dir="ltr">
            {invoice.gross_total}
          </p>
        </div>
      </div>

      {invoice.reversal_reason && (
        <p className="mb-6 rounded-lg border border-border bg-muted/40 p-3 text-sm">
          <span className="text-muted-foreground">سبب العكس: </span>
          {invoice.reversal_reason}
        </p>
      )}

      <h2 className="mb-3 text-sm font-semibold">البنود</h2>
      <div className="mb-6 rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>الصنف</TableHead>
              <TableHead className="hidden sm:table-cell">SKU</TableHead>
              <TableHead>الكمية</TableHead>
              <TableHead className="hidden lg:table-cell">تكلفة الوحدة</TableHead>
              <TableHead>المعالجة الضريبية</TableHead>
              <TableHead>الصافي</TableHead>
              <TableHead>الضريبة</TableHead>
              <TableHead>الإجمالي</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {invoice.lines.map((line) => (
              <TableRow key={line.id}>
                <TableCell className="text-sm">{line.item_name}</TableCell>
                <TableCell className="hidden font-mono text-sm text-muted-foreground sm:table-cell" dir="ltr">
                  {line.sku}
                </TableCell>
                <TableCell className="font-mono text-sm" dir="ltr">
                  {line.quantity}
                </TableCell>
                <TableCell className="hidden font-mono text-sm lg:table-cell" dir="ltr">
                  {line.unit_net_cost}
                </TableCell>
                <TableCell className="text-sm">
                  {TAX_TREATMENT_LABELS_AR[line.tax_treatment as TaxTreatment] ?? line.tax_treatment}
                  {line.tax_treatment === "standard" && <span className="text-muted-foreground"> ({line.tax_rate_percent}%)</span>}
                </TableCell>
                <TableCell className="font-mono text-sm" dir="ltr">
                  {line.net_amount}
                </TableCell>
                <TableCell className="font-mono text-sm" dir="ltr">
                  {line.vat_amount}
                </TableCell>
                <TableCell className="font-mono text-sm font-medium" dir="ltr">
                  {line.gross_amount}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>

      <h2 className="mb-3 text-sm font-semibold">الدفعات</h2>
      <div className="rounded-xl border border-border bg-card">
        {invoice.payments.length === 0 ? (
          <p className="p-6 text-center text-sm text-muted-foreground">لا توجد دفعات مسجَّلة على هذه الفاتورة.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>رقم الحركة</TableHead>
                <TableHead>التاريخ</TableHead>
                <TableHead>النوع</TableHead>
                <TableHead>الطريقة</TableHead>
                <TableHead className="hidden lg:table-cell">المرجع</TableHead>
                <TableHead>المبلغ</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {invoice.payments.map((p) => (
                <TableRow key={p.id}>
                  <TableCell className="font-mono text-sm" dir="ltr">
                    {p.payment_number}
                  </TableCell>
                  <TableCell className="text-sm">{formatRiyadhDate(p.business_date)}</TableCell>
                  <TableCell>
                    <Badge variant={p.entry_kind === "reversal" ? "secondary" : "outline"}>{p.entry_kind === "reversal" ? "عكس" : "دفعة"}</Badge>
                  </TableCell>
                  <TableCell className="text-sm">{PAYMENT_MODE_LABELS_AR[p.payment_mode as PaymentMode] ?? p.payment_mode}</TableCell>
                  <TableCell className="hidden font-mono text-sm text-muted-foreground lg:table-cell" dir="ltr">
                    {p.payment_reference ?? "—"}
                  </TableCell>
                  <TableCell className="font-mono text-sm font-medium" dir="ltr">
                    {p.amount}
                  </TableCell>
                  <TableCell>
                    {p.entry_kind === "payment" && !p.is_reversed && (
                      <Can permission="purchases.reverse_payment">
                        <SupplierPaymentReverseDialog paymentId={p.id} paymentNumber={p.payment_number} amount={p.amount} />
                      </Can>
                    )}
                    {p.entry_kind === "payment" && p.is_reversed && <span className="text-xs text-muted-foreground">معكوسة</span>}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </div>
    </div>
  );
}

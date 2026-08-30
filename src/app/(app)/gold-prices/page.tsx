import { AlertTriangle, Coins } from "lucide-react";
import { requirePermission } from "@/lib/permissions/guard";
import { getPriceEntryRowsForDate, getMissingPricesForDate, listPriceHistory } from "@/features/gold-prices/queries";
import { listKarats } from "@/features/karats/queries";
import { listSearchParamsSchema } from "@/lib/validation/common";
import { PageHeader } from "@/components/shared/page-header";
import { EmptyState } from "@/components/shared/empty-state";
import { Pagination } from "@/components/shared/pagination";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Can } from "@/lib/permissions/context";
import { TodayPriceForm } from "@/features/gold-prices/components/today-price-form";
import { PriceHistoryToolbar } from "@/features/gold-prices/components/price-history-toolbar";
import { formatRiyadhDate, formatRiyadhDateTime, riyadhTodayIsoDate } from "@/lib/date";

export default async function GoldPricesPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await requirePermission("gold_prices.view");

  const sp = await searchParams;
  const { page, pageSize } = listSearchParamsSchema.parse(sp);
  const entryDate = typeof sp.date === "string" && sp.date ? sp.date : riyadhTodayIsoDate();
  const karatId = typeof sp.karatId === "string" ? sp.karatId : "";
  const dateFrom = typeof sp.dateFrom === "string" ? sp.dateFrom : "";
  const dateTo = typeof sp.dateTo === "string" ? sp.dateTo : "";

  const [entryRows, missingToday, { rows: history, total }, karats] = await Promise.all([
    getPriceEntryRowsForDate(entryDate),
    getMissingPricesForDate(riyadhTodayIsoDate()),
    listPriceHistory({ karatId: karatId || undefined, dateFrom: dateFrom || undefined, dateTo: dateTo || undefined, page, pageSize }),
    listKarats(),
  ]);

  return (
    <div>
      <PageHeader title="أسعار الذهب" description="سجل تاريخي لأسعار الذهب اليومية لكل عيار — لا يُحذف أي سعر سابق." />

      {missingToday.length > 0 && (
        <div className="mb-4 flex items-start gap-3 rounded-xl border border-warning/30 bg-warning/10 px-4 py-3 text-sm text-warning">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span>
            لم يُدخل بعد سعر اليوم ({formatRiyadhDate(riyadhTodayIsoDate())}) للعيارات التالية:{" "}
            <span className="font-semibold">{missingToday.map((k) => k.name_ar).join("، ")}</span>
          </span>
        </div>
      )}

      <Can permission="gold_prices.edit">
        {entryRows.length === 0 ? (
          <EmptyState icon={Coins} title="لا توجد عيارات نشطة" description="أضف عيارًا نشطًا واحدًا على الأقل من صفحة العيارات أولًا." />
        ) : (
          <div className="mb-8">
            <h2 className="mb-3 text-sm font-semibold text-muted-foreground">
              إدخال أسعار {entryDate === riyadhTodayIsoDate() ? "اليوم" : "بتاريخ"} — {formatRiyadhDate(entryDate)}
            </h2>
            <TodayPriceForm date={entryDate} rows={entryRows} />
          </div>
        )}
      </Can>

      <h2 className="mb-3 text-sm font-semibold text-muted-foreground">سجل الأسعار</h2>
      <PriceHistoryToolbar karats={karats} karatId={karatId} dateFrom={dateFrom} dateTo={dateTo} />

      {history.length === 0 ? (
        <EmptyState icon={Coins} title="لا توجد أسعار مسجَّلة" description="لا توجد أسعار مطابقة لهذا الفلتر." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>التاريخ</TableHead>
                <TableHead>العيار</TableHead>
                <TableHead>السعر (ر.س/جم)</TableHead>
                <TableHead className="hidden sm:table-cell">المصدر</TableHead>
                <TableHead className="hidden md:table-cell">آخر تعديل</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {history.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="font-medium">{formatRiyadhDate(row.price_date)}</TableCell>
                  <TableCell>{row.karat?.name_ar ?? "—"}</TableCell>
                  <TableCell className="tabular-nums">{row.price_per_gram}</TableCell>
                  <TableCell className="hidden sm:table-cell">
                    <Badge variant={row.source_type === "manual" ? "outline" : "secondary"}>
                      {row.source_type === "manual" ? "يدوي" : "مستورد"}
                      {row.is_manual_override && row.source_type !== "manual" ? " (تعديل يدوي)" : ""}
                    </Badge>
                  </TableCell>
                  <TableCell className="hidden text-sm text-muted-foreground md:table-cell">
                    {row.updated_by_profile?.full_name ?? "—"} · {formatRiyadhDateTime(row.updated_at)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          <Pagination
            page={page}
            pageSize={pageSize}
            total={total}
            buildHref={(p) =>
              `/gold-prices?${new URLSearchParams({ karatId, dateFrom, dateTo, page: String(p) }).toString()}`
            }
          />
        </div>
      )}
    </div>
  );
}

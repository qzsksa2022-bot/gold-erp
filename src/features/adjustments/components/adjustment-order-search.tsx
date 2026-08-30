"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { Search, Loader2 } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { formatRiyadhDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { searchSalesOrdersForAdjustmentAction } from "../actions";

type OrderResult = {
  sales_order_id: string;
  order_number: string;
  sale_date: string;
  store_name: string | null;
  customer_name: string | null;
  customer_phone: string | null;
  original_invoice_amount: string;
};

/**
 * First step of the New Adjustment/Service flow (§25/§36) — searches by
 * order number, customer name, or customer phone via
 * search_sales_orders_for_adjustment() (0137), gated on adjustments.create
 * ALONE — never sales.view. Mirrors ShipmentOrderSearch/ReturnOrderSearch.
 * The picked order's id + number are carried forward as query params so
 * /adjustments/new can re-resolve the exact row server-side.
 */
export function AdjustmentOrderSearch() {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<OrderResult[] | null>(null);
  const [searched, setSearched] = useState(false);
  const [isPending, startTransition] = useTransition();

  function runSearch() {
    if (!query.trim()) return;
    startTransition(async () => {
      setSearched(true);
      const result = await searchSalesOrdersForAdjustmentAction(query);
      setResults(result.success ? result.data : []);
    });
  }

  return (
    <Card>
      <CardContent className="flex flex-col gap-4 pt-6">
        <div className="flex flex-col gap-1.5">
          <label className="text-sm text-muted-foreground">ابحث برقم عملية البيع أو اسم/جوال العميل لبدء تعديل/خدمة جديد</label>
          <div className="flex items-center gap-2">
            <div className="relative flex-1">
              <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                autoFocus
                placeholder="مثال: SO-0000000123"
                className="ps-9"
                dir="ltr"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && runSearch()}
                disabled={isPending}
              />
            </div>
            <Button type="button" onClick={runSearch} disabled={isPending || !query.trim()}>
              {isPending && <Loader2 className="size-4 animate-spin" />}
              بحث
            </Button>
          </div>
        </div>

        {searched && !isPending && (results?.length ?? 0) === 0 && <p className="text-sm text-muted-foreground">لا توجد عمليات بيع مطابقة لهذا البحث.</p>}

        {results && results.length > 0 && (
          <div className="flex flex-col divide-y divide-border rounded-lg border border-border">
            {results.map((r) => (
              <Link
                key={r.sales_order_id}
                href={`${ROUTES.adjustmentsNew}?sales_order_id=${r.sales_order_id}&order_number=${encodeURIComponent(r.order_number)}`}
                className="flex items-center justify-between gap-3 px-4 py-3 text-sm hover:bg-muted/40"
              >
                <div className="flex flex-col gap-0.5">
                  <span className="font-mono text-accent" dir="ltr">
                    {r.order_number}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {formatRiyadhDate(r.sale_date)} — {r.store_name ?? "—"} {r.customer_name ? `— ${r.customer_name}` : ""}
                  </span>
                </div>
                <span className="font-medium" dir="ltr">
                  {r.original_invoice_amount}
                </span>
              </Link>
            ))}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

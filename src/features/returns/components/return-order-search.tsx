"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { Search, Loader2 } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { formatRiyadhDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { searchSalesOrdersForReturnAction } from "../actions";

type SearchResult = { id: string; order_number: string; sale_date: string; store_name: string | null; customer_name: string | null; subtotal: string };

/**
 * First step of the New Return flow — every Returns RPC needs a Sale's
 * uuid, but staff only know its order_number. Once an order is picked, the
 * flow moves on to /returns/new?sales_order_id=<id>, which loads the full
 * returnable-items view (get_returnable_sales_order(), migration 0090).
 */
export function ReturnOrderSearch() {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResult[] | null>(null);
  const [searched, setSearched] = useState(false);
  const [isPending, startTransition] = useTransition();

  function runSearch() {
    if (!query.trim()) return;
    startTransition(async () => {
      const result = await searchSalesOrdersForReturnAction(query);
      setSearched(true);
      setResults(result.success ? result.data : []);
    });
  }

  return (
    <Card>
      <CardContent className="flex flex-col gap-4 pt-6">
        <div className="flex flex-col gap-1.5">
          <label className="text-sm text-muted-foreground">ابحث برقم عملية البيع لبدء مرتجع جديد</label>
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

        {searched && !isPending && (results?.length ?? 0) === 0 && (
          <p className="text-sm text-muted-foreground">لا توجد عمليات بيع مطابقة لهذا الرقم.</p>
        )}

        {results && results.length > 0 && (
          <div className="flex flex-col divide-y divide-border rounded-lg border border-border">
            {results.map((r) => (
              <Link
                key={r.id}
                href={`${ROUTES.returnsNew}?sales_order_id=${r.id}`}
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
                  {r.subtotal}
                </span>
              </Link>
            ))}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { Search, Loader2 } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { formatRiyadhDate } from "@/lib/date";
import { ROUTES } from "@/lib/constants";
import { searchSalesOrdersForShipmentAction, searchSalesReturnsForShipmentAction } from "../actions";
import type { ShipmentDirection } from "@/types/database";

type OrderResult = { id: string; order_number: string; sale_date: string; store_name: string | null; customer_name: string | null };
type ReturnResult = { id: string; return_number: string; return_date: string; status: string; sales_order_id: string; order_number: string | null; store_name: string | null };

/**
 * First step of the New Shipment flow (Section 39) — mirrors ReturnOrderSearch
 * exactly, extended with a direction toggle (Section 9's outbound/return
 * semantics). Outbound searches by order_number (search_sales_orders_for_
 * shipment, 0120); Return searches by return_number (search_sales_returns_
 * for_shipment, 0120 — only approved/reversed returns ever surface here,
 * matching create_shipment()'s own eligibility check). The picked result's
 * order_number/return_number is carried forward as a query param so
 * /shipments/new can re-resolve the exact row server-side without a
 * dedicated get-by-id lookup RPC.
 */
export function ShipmentOrderSearch() {
  const [direction, setDirection] = useState<ShipmentDirection>("outbound");
  const [query, setQuery] = useState("");
  const [orderResults, setOrderResults] = useState<OrderResult[] | null>(null);
  const [returnResults, setReturnResults] = useState<ReturnResult[] | null>(null);
  const [searched, setSearched] = useState(false);
  const [isPending, startTransition] = useTransition();

  function runSearch() {
    if (!query.trim()) return;
    startTransition(async () => {
      setSearched(true);
      if (direction === "outbound") {
        const result = await searchSalesOrdersForShipmentAction(query);
        setOrderResults(result.success ? result.data : []);
        setReturnResults(null);
      } else {
        const result = await searchSalesReturnsForShipmentAction({ returnNumber: query });
        setReturnResults(result.success ? result.data : []);
        setOrderResults(null);
      }
    });
  }

  function handleDirectionChange(value: string) {
    setDirection(value as ShipmentDirection);
    setQuery("");
    setOrderResults(null);
    setReturnResults(null);
    setSearched(false);
  }

  const hasResults = (orderResults?.length ?? 0) > 0 || (returnResults?.length ?? 0) > 0;

  return (
    <Card>
      <CardContent className="flex flex-col gap-4 pt-6">
        <Tabs value={direction} onValueChange={handleDirectionChange}>
          <TabsList>
            <TabsTrigger value="outbound">شحنة ذهاب (للعميل)</TabsTrigger>
            <TabsTrigger value="return">شحنة إرجاع (من العميل)</TabsTrigger>
          </TabsList>
        </Tabs>

        <div className="flex flex-col gap-1.5">
          <label className="text-sm text-muted-foreground">
            {direction === "outbound" ? "ابحث برقم عملية البيع لبدء شحنة ذهاب جديدة" : "ابحث برقم المرتجع (معتمَد) لبدء شحنة إرجاع جديدة"}
          </label>
          <div className="flex items-center gap-2">
            <div className="relative flex-1">
              <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                autoFocus
                placeholder={direction === "outbound" ? "مثال: SO-0000000123" : "مثال: SR-0000000045"}
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

        {searched && !isPending && !hasResults && (
          <p className="text-sm text-muted-foreground">
            {direction === "outbound" ? "لا توجد عمليات بيع مطابقة لهذا الرقم." : "لا توجد مرتجعات معتمَدة مطابقة لهذا الرقم."}
          </p>
        )}

        {direction === "outbound" && orderResults && orderResults.length > 0 && (
          <div className="flex flex-col divide-y divide-border rounded-lg border border-border">
            {orderResults.map((r) => (
              <Link
                key={r.id}
                href={`${ROUTES.shipmentsNew}?direction=outbound&sales_order_id=${r.id}&order_number=${encodeURIComponent(r.order_number)}`}
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
              </Link>
            ))}
          </div>
        )}

        {direction === "return" && returnResults && returnResults.length > 0 && (
          <div className="flex flex-col divide-y divide-border rounded-lg border border-border">
            {returnResults.map((r) => (
              <Link
                key={r.id}
                href={`${ROUTES.shipmentsNew}?direction=return&sales_order_id=${r.sales_order_id}&order_number=${encodeURIComponent(r.order_number ?? "")}&sales_return_id=${r.id}&return_number=${encodeURIComponent(r.return_number)}`}
                className="flex items-center justify-between gap-3 px-4 py-3 text-sm hover:bg-muted/40"
              >
                <div className="flex flex-col gap-0.5">
                  <span className="font-mono text-accent" dir="ltr">
                    {r.return_number}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {formatRiyadhDate(r.return_date)} — {r.store_name ?? "—"} — عملية البيع {r.order_number ?? "—"}
                  </span>
                </div>
              </Link>
            ))}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

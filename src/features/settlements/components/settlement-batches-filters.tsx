"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useState, useTransition } from "react";
import { Search } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { SETTLEMENT_BATCH_EFFECTIVE_STATUSES, SETTLEMENT_BATCH_STATUS_LABELS_AR, SETTLEMENT_ROUTE_KINDS, SETTLEMENT_ROUTE_KIND_LABELS_AR } from "../schema";

type Route = { id: string; code: string; name_ar: string; route_kind: string; status: string };
type NamedLookup = { id: string; name_ar: string };
type StoreLookup = { id: string; code: string; name_ar: string };

/**
 * /settlements list filters — same URL-driven pattern as AdjustmentsFilters.
 * Patch 7.1 §25 (migration 0191) gave list_settlement_batches() a complete
 * filter set; `effective_status` replaces the old `status` control — it is
 * a strict superset (draft/finalized/reconciled PLUS 'cancelled', now
 * genuinely filterable server-side instead of only ever a badge derived
 * client-side, item 17). `has_variance` is only ever rendered/sent for an
 * actor holding settlements.view_financials — the RPC itself refuses the
 * filter outright otherwise (§25), so a non-financials actor never even
 * sees the control.
 */
export function SettlementBatchesFilters({
  search,
  dateFrom,
  dateTo,
  settlementRouteId,
  effectiveStatus,
  routeKind,
  paymentMethodId,
  collectionChannelId,
  shippingCarrierId,
  storeId,
  hasVariance,
  routes,
  paymentMethods,
  collectionChannels,
  shippingCarriers,
  stores,
  canViewFinancials,
}: {
  search: string;
  dateFrom: string;
  dateTo: string;
  settlementRouteId: string;
  effectiveStatus: string;
  routeKind: string;
  paymentMethodId: string;
  collectionChannelId: string;
  shippingCarrierId: string;
  storeId: string;
  hasVariance: string;
  routes: Route[];
  paymentMethods: NamedLookup[];
  collectionChannels: NamedLookup[];
  shippingCarriers: NamedLookup[];
  stores: StoreLookup[];
  canViewFinancials: boolean;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [value, setValue] = useState(search);
  const [, startTransition] = useTransition();

  function updateParams(next: Record<string, string>) {
    const params = new URLSearchParams(searchParams.toString());
    for (const [key, val] of Object.entries(next)) {
      if (val) params.set(key, val);
      else params.delete(key);
    }
    params.set("page", "1");
    startTransition(() => router.push(`${pathname}?${params.toString()}`));
  }

  return (
    <div className="mb-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
      <div className="relative">
        <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          placeholder="رقم الدفعة أو مرجع الكشف..."
          className="ps-9"
          dir="ltr"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && updateParams({ search: value })}
          onBlur={() => updateParams({ search: value })}
        />
      </div>

      <Input type="date" dir="ltr" value={dateFrom} onChange={(e) => updateParams({ date_from: e.target.value })} />
      <Input type="date" dir="ltr" value={dateTo} onChange={(e) => updateParams({ date_to: e.target.value })} />

      <Select value={settlementRouteId || "all"} onValueChange={(v) => updateParams({ settlement_route_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="مسار التسوية" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل المسارات</SelectItem>
          {routes.map((r) => (
            <SelectItem key={r.id} value={r.id}>
              {r.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={effectiveStatus || "all"} onValueChange={(v) => updateParams({ effective_status: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="الحالة" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل الحالات</SelectItem>
          {SETTLEMENT_BATCH_EFFECTIVE_STATUSES.map((s) => (
            <SelectItem key={s} value={s}>
              {SETTLEMENT_BATCH_STATUS_LABELS_AR[s]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={routeKind || "all"} onValueChange={(v) => updateParams({ route_kind: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="نوع المسار" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل الأنواع</SelectItem>
          {SETTLEMENT_ROUTE_KINDS.map((k) => (
            <SelectItem key={k} value={k}>
              {SETTLEMENT_ROUTE_KIND_LABELS_AR[k]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={paymentMethodId || "all"} onValueChange={(v) => updateParams({ payment_method_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="طريقة الدفع" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل طرق الدفع</SelectItem>
          {paymentMethods.map((p) => (
            <SelectItem key={p.id} value={p.id}>
              {p.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={collectionChannelId || "all"} onValueChange={(v) => updateParams({ collection_channel_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="قناة التحصيل" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل القنوات</SelectItem>
          {collectionChannels.map((c) => (
            <SelectItem key={c.id} value={c.id}>
              {c.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={shippingCarrierId || "all"} onValueChange={(v) => updateParams({ shipping_carrier_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="شركة الشحن" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل شركات الشحن</SelectItem>
          {shippingCarriers.map((c) => (
            <SelectItem key={c.id} value={c.id}>
              {c.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={storeId || "all"} onValueChange={(v) => updateParams({ store_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="المتجر" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل المتاجر</SelectItem>
          {stores.map((s) => (
            <SelectItem key={s.id} value={s.id}>
              {s.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      {canViewFinancials && (
        <Select value={hasVariance || "all"} onValueChange={(v) => updateParams({ has_variance: v === "all" ? "" : v })}>
          <SelectTrigger>
            <SelectValue placeholder="الفرق المالي" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">كل الدفعات</SelectItem>
            <SelectItem value="true">بها فرق مطابقة</SelectItem>
            <SelectItem value="false">بلا فرق مطابقة</SelectItem>
          </SelectContent>
        </Select>
      )}
    </div>
  );
}

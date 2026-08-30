"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useState, useTransition } from "react";
import { Search } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { SHIPMENT_STATUSES, SHIPMENT_STATUS_LABELS_AR, SHIPMENT_DIRECTIONS, SHIPMENT_DIRECTION_LABELS_AR, COD_COLLECTION_STATES, COD_COLLECTION_STATE_LABELS_AR } from "../schema";

type Store = { id: string; name_ar: string };
type Carrier = { id: string; code: string; name_ar: string };
type Zone = { id: string; code: string; name_ar: string };

/**
 * /shipments list filters — same URL-driven pattern as ReturnsFilters.
 * Patch 5.1 item 12 added orderNumber/returnNumber/originalSaleStoreId/
 * codCollectionState. `stores` here is used both for the processing-store
 * filter AND (via `originalSaleStoreId`) the original-Sale-store filter —
 * same visible-store list, two distinct filter dimensions (list_shipments()
 * / migration 0126 distinguishes p_store_id from p_original_sale_store_id).
 */
export function ShipmentsFilters({
  shipmentNumber,
  trackingNumber,
  orderNumber,
  returnNumber,
  dateFrom,
  dateTo,
  storeId,
  originalSaleStoreId,
  carrierId,
  shippingZoneId,
  direction,
  currentStatus,
  codCollectionState,
  stores,
  carriers,
  zones,
}: {
  shipmentNumber: string;
  trackingNumber: string;
  orderNumber: string;
  returnNumber: string;
  dateFrom: string;
  dateTo: string;
  storeId: string;
  originalSaleStoreId: string;
  carrierId: string;
  shippingZoneId: string;
  direction: string;
  currentStatus: string;
  codCollectionState: string;
  stores: Store[];
  carriers: Carrier[];
  zones: Zone[];
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [value, setValue] = useState(shipmentNumber);
  const [trackingValue, setTrackingValue] = useState(trackingNumber);
  const [orderValue, setOrderValue] = useState(orderNumber);
  const [returnValue, setReturnValue] = useState(returnNumber);
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
          placeholder="رقم الشحنة..."
          className="ps-9"
          dir="ltr"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && updateParams({ shipment_number: value })}
          onBlur={() => updateParams({ shipment_number: value })}
        />
      </div>

      <div className="relative">
        <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          placeholder="رقم التتبع..."
          className="ps-9"
          dir="ltr"
          value={trackingValue}
          onChange={(e) => setTrackingValue(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && updateParams({ tracking_number: trackingValue })}
          onBlur={() => updateParams({ tracking_number: trackingValue })}
        />
      </div>

      <div className="relative">
        <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          placeholder="رقم عملية البيع..."
          className="ps-9"
          dir="ltr"
          value={orderValue}
          onChange={(e) => setOrderValue(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && updateParams({ order_number: orderValue })}
          onBlur={() => updateParams({ order_number: orderValue })}
        />
      </div>

      <div className="relative">
        <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          placeholder="رقم المرتجع..."
          className="ps-9"
          dir="ltr"
          value={returnValue}
          onChange={(e) => setReturnValue(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && updateParams({ return_number: returnValue })}
          onBlur={() => updateParams({ return_number: returnValue })}
        />
      </div>

      <Input type="date" dir="ltr" value={dateFrom} onChange={(e) => updateParams({ date_from: e.target.value })} />
      <Input type="date" dir="ltr" value={dateTo} onChange={(e) => updateParams({ date_to: e.target.value })} />

      <Select value={storeId || "all"} onValueChange={(v) => updateParams({ store_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="المتجر المعالِج" />
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

      <Select value={originalSaleStoreId || "all"} onValueChange={(v) => updateParams({ original_sale_store_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="متجر عملية البيع الأصلية" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل متاجر البيع الأصلية</SelectItem>
          {stores.map((s) => (
            <SelectItem key={s.id} value={s.id}>
              {s.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={carrierId || "all"} onValueChange={(v) => updateParams({ carrier_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="شركة الشحن" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل شركات الشحن</SelectItem>
          {carriers.map((c) => (
            <SelectItem key={c.id} value={c.id}>
              {c.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={shippingZoneId || "all"} onValueChange={(v) => updateParams({ shipping_zone_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="المنطقة" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل المناطق</SelectItem>
          {zones.map((z) => (
            <SelectItem key={z.id} value={z.id}>
              {z.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={direction || "all"} onValueChange={(v) => updateParams({ direction: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="الاتجاه" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل الاتجاهات</SelectItem>
          {SHIPMENT_DIRECTIONS.map((d) => (
            <SelectItem key={d} value={d}>
              {SHIPMENT_DIRECTION_LABELS_AR[d]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={currentStatus || "all"} onValueChange={(v) => updateParams({ current_status: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="الحالة" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل الحالات</SelectItem>
          {SHIPMENT_STATUSES.map((s) => (
            <SelectItem key={s} value={s}>
              {SHIPMENT_STATUS_LABELS_AR[s]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={codCollectionState || "all"} onValueChange={(v) => updateParams({ cod_collection_state: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="حالة تحصيل COD" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل حالات التحصيل</SelectItem>
          {COD_COLLECTION_STATES.map((s) => (
            <SelectItem key={s} value={s}>
              {COD_COLLECTION_STATE_LABELS_AR[s]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  );
}

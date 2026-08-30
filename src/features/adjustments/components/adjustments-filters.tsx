"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useState, useTransition } from "react";
import { Search } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { ADJUSTMENT_EFFECTIVE_STATUSES, ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR } from "../schema";

type Store = { id: string; name_ar: string };
type AdjType = { id: string; code: string; name_ar: string };
type PaymentLookup = { id: string; key: string; name_ar: string };

/**
 * /adjustments list filters — same URL-driven pattern as ShipmentsFilters/
 * ReturnsFilters. Patch 6.1 item 21 adds originalSaleStoreId (the linked
 * Sale's OWN store, distinct from the processing-store filter above it) /
 * paymentMethodId/collectionChannelId/participatesInSettlement.
 */
export function AdjustmentsFilters({
  search,
  dateFrom,
  dateTo,
  storeId,
  originalSaleStoreId,
  adjustmentTypeId,
  paymentMethodId,
  collectionChannelId,
  participatesInSettlement,
  status,
  stores,
  types,
  paymentMethods,
  collectionChannels,
}: {
  search: string;
  dateFrom: string;
  dateTo: string;
  storeId: string;
  originalSaleStoreId: string;
  adjustmentTypeId: string;
  paymentMethodId: string;
  collectionChannelId: string;
  participatesInSettlement: string;
  status: string;
  stores: Store[];
  types: AdjType[];
  paymentMethods: PaymentLookup[];
  collectionChannels: PaymentLookup[];
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
          placeholder="رقم التعديل/الخدمة أو رقم عملية البيع..."
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

      <Select value={storeId || "all"} onValueChange={(v) => updateParams({ store_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="المتجر المُعالِج" />
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

      <Select value={adjustmentTypeId || "all"} onValueChange={(v) => updateParams({ adjustment_type_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="نوع التعديل/الخدمة" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل الأنواع</SelectItem>
          {types.map((t) => (
            <SelectItem key={t.id} value={t.id}>
              {t.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={status || "all"} onValueChange={(v) => updateParams({ status: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="الحالة" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل الحالات</SelectItem>
          {ADJUSTMENT_EFFECTIVE_STATUSES.map((s) => (
            <SelectItem key={s} value={s}>
              {ADJUSTMENT_EFFECTIVE_STATUS_LABELS_AR[s]}
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
          <SelectItem value="all">كل قنوات التحصيل</SelectItem>
          {collectionChannels.map((c) => (
            <SelectItem key={c.id} value={c.id}>
              {c.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={participatesInSettlement || "all"} onValueChange={(v) => updateParams({ participates_in_settlement: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="ضمن التسوية" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">الكل</SelectItem>
          <SelectItem value="true">ضمن التسوية فقط</SelectItem>
          <SelectItem value="false">خارج التسوية فقط</SelectItem>
        </SelectContent>
      </Select>
    </div>
  );
}

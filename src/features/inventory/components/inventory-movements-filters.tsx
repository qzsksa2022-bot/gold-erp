"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useTransition } from "react";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";

type Lookup = { id: string; name_ar: string; sku?: string };

/** /inventory/movements list filters — URL-driven, mirrors InventoryBalancesFilters. */
export function InventoryMovementsFilters({
  storeId,
  itemId,
  dateFrom,
  dateTo,
  stores,
  items,
}: {
  storeId: string;
  itemId: string;
  dateFrom: string;
  dateTo: string;
  stores: Lookup[];
  items: Lookup[];
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
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
      <Select value={itemId || "all"} onValueChange={(v) => updateParams({ item_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="الصنف" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل الأصناف</SelectItem>
          {items.map((i) => (
            <SelectItem key={i.id} value={i.id}>
              {i.sku ? `${i.sku} — ${i.name_ar}` : i.name_ar}
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

      <Input type="date" dir="ltr" value={dateFrom} onChange={(e) => updateParams({ date_from: e.target.value })} />
      <Input type="date" dir="ltr" value={dateTo} onChange={(e) => updateParams({ date_to: e.target.value })} />
    </div>
  );
}

"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useState, useTransition } from "react";
import { Search } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { RETURN_STATUSES, RETURN_STATUS_LABELS_AR, RETURN_SCENARIOS, RETURN_SCENARIO_LABELS_AR } from "../schema";

// Patch 4.2 (Section 7) — narrowed to the {id, name_ar} shape returned by
// returns_visible_store_lookups() (migration 0105), gated on returns.view
// rather than the Master Data stores.view.
type Store = { id: string; name_ar: string };

/** Returns list filters — same URL-driven pattern as SalesFilters. Patch 4.1 (Section 14) adds order_number/original_store_id/scenario. */
export function ReturnsFilters({
  returnNumber,
  orderNumber,
  dateFrom,
  dateTo,
  processedStoreId,
  originalStoreId,
  status,
  scenario,
  stores,
}: {
  returnNumber: string;
  orderNumber?: string;
  dateFrom: string;
  dateTo: string;
  processedStoreId: string;
  originalStoreId?: string;
  status: string;
  scenario?: string;
  stores: Store[];
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [value, setValue] = useState(returnNumber);
  const [orderValue, setOrderValue] = useState(orderNumber ?? "");
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
          placeholder="رقم المرتجع..."
          className="ps-9"
          dir="ltr"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && updateParams({ return_number: value })}
          onBlur={() => updateParams({ return_number: value })}
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

      <Input type="date" dir="ltr" value={dateFrom} onChange={(e) => updateParams({ date_from: e.target.value })} />
      <Input type="date" dir="ltr" value={dateTo} onChange={(e) => updateParams({ date_to: e.target.value })} />

      <Select value={processedStoreId || "all"} onValueChange={(v) => updateParams({ processed_store_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="متجر المعالجة" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل متاجر المعالجة</SelectItem>
          {stores.map((s) => (
            <SelectItem key={s.id} value={s.id}>
              {s.name_ar}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={originalStoreId || "all"} onValueChange={(v) => updateParams({ original_store_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="متجر البيع الأصلي" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل متاجر البيع الأصلي</SelectItem>
          {stores.map((s) => (
            <SelectItem key={s.id} value={s.id}>
              {s.name_ar}
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
          {RETURN_STATUSES.map((s) => (
            <SelectItem key={s} value={s}>
              {RETURN_STATUS_LABELS_AR[s]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select value={scenario || "all"} onValueChange={(v) => updateParams({ scenario: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="السيناريو" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل السيناريوهات</SelectItem>
          {RETURN_SCENARIOS.map((s) => (
            <SelectItem key={s} value={s}>
              {RETURN_SCENARIO_LABELS_AR[s]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  );
}

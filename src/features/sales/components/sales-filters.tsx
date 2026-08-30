"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useState, useTransition } from "react";
import { Search } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { Database } from "@/types/database";

type Store = Database["public"]["Tables"]["stores"]["Row"];
type PaymentMethod = Database["public"]["Tables"]["payment_methods"]["Row"];
type Channel = Database["public"]["Tables"]["collection_channels"]["Row"];
/** From list_sales_salespersons() (migration 0070) — deliberately narrower than a `profiles` row (id/full_name only), and never requires users.view. */
type Salesperson = { id: string; full_name: string };

/** Sales list filters (spec §16) — same URL-driven pattern as AuditLogFilters. */
export function SalesFilters({
  orderNumber,
  dateFrom,
  dateTo,
  storeId,
  salespersonId,
  paymentMethodId,
  collectionChannelId,
  stores,
  salespeople,
  paymentMethods,
  collectionChannels,
}: {
  orderNumber: string;
  dateFrom: string;
  dateTo: string;
  storeId: string;
  salespersonId: string;
  paymentMethodId: string;
  collectionChannelId: string;
  stores: Store[];
  salespeople: Salesperson[];
  paymentMethods: PaymentMethod[];
  collectionChannels: Channel[];
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [value, setValue] = useState(orderNumber);
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
    <div className="mb-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-6">
      <div className="relative">
        <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          placeholder="رقم العملية..."
          className="ps-9"
          dir="ltr"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && updateParams({ order_number: value })}
          onBlur={() => updateParams({ order_number: value })}
        />
      </div>

      <Input type="date" dir="ltr" value={dateFrom} onChange={(e) => updateParams({ date_from: e.target.value })} />
      <Input type="date" dir="ltr" value={dateTo} onChange={(e) => updateParams({ date_to: e.target.value })} />

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

      <Select value={salespersonId || "all"} onValueChange={(v) => updateParams({ salesperson_id: v === "all" ? "" : v })}>
        <SelectTrigger>
          <SelectValue placeholder="الموظف" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">كل الموظفين</SelectItem>
          {salespeople.map((p) => (
            <SelectItem key={p.id} value={p.id}>
              {p.full_name}
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
          {paymentMethods.map((m) => (
            <SelectItem key={m.id} value={m.id}>
              {m.name_ar}
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
    </div>
  );
}

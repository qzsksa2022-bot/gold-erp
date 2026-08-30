"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useTransition } from "react";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";

const MONTH_LABELS_AR = ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"];

/**
 * Year (+ optional month) picker for the Monthly/Yearly Management Reports
 * (§36/§37) — these reports address a calendar period rather than a date
 * range, so `ReportFilterBar`'s date inputs don't fit; this is a small
 * bespoke sibling following the exact same URL-is-source-of-truth
 * convention (page resets to 1 on any change — not that these reports
 * paginate, but it keeps the pattern uniform).
 */
export function PeriodPicker({
  year,
  month,
  showMonth = false,
  storeId,
  stores,
  yearsBack = 8,
}: {
  year: number;
  month?: number;
  showMonth?: boolean;
  storeId?: string;
  stores?: { id: string; name_ar: string }[];
  yearsBack?: number;
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
    startTransition(() => router.push(`${pathname}?${params.toString()}`));
  }

  const currentYear = new Date().getFullYear();
  const years = Array.from({ length: yearsBack + 2 }, (_, i) => currentYear + 1 - i);

  return (
    <div className="mb-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
      <Select value={String(year)} onValueChange={(v) => updateParams({ year: v })}>
        <SelectTrigger>
          <SelectValue placeholder="السنة" />
        </SelectTrigger>
        <SelectContent>
          {years.map((y) => (
            <SelectItem key={y} value={String(y)}>
              {y}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      {showMonth && (
        <Select value={String(month ?? 1)} onValueChange={(v) => updateParams({ month: v })}>
          <SelectTrigger>
            <SelectValue placeholder="الشهر" />
          </SelectTrigger>
          <SelectContent>
            {MONTH_LABELS_AR.map((label, i) => (
              <SelectItem key={i} value={String(i + 1)}>
                {label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      )}

      {stores && (
        <Select value={storeId || "all"} onValueChange={(v) => updateParams({ store_id: v === "all" ? "" : v })}>
          <SelectTrigger>
            <SelectValue placeholder="المتجر" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">كل المتاجر المتاحة</SelectItem>
            {stores.map((s) => (
              <SelectItem key={s.id} value={s.id}>
                {s.name_ar}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      )}
    </div>
  );
}

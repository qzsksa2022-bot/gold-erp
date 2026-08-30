"use client";

import { useRouter, useSearchParams, usePathname } from "next/navigation";
import { useState, useTransition } from "react";
import { Search } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";

export interface ReportSelectFilterOption {
  value: string;
  label: string;
}

export interface ReportSelectFilterConfig {
  key: string;
  placeholder: string;
  allLabel: string;
  options: ReportSelectFilterOption[];
  /**
   * Hotfix 8.1.2 §28-30 — URL keys to CLEAR (never just hide) whenever this
   * select's value changes. Built for the Returns report's `basis` select:
   * switching basis makes whichever of `payment_method_id`/
   * `refund_method_id` applied under the OLD basis stale (the RPC itself
   * already ignores it under the new basis, 0219 §36 — this is about the
   * URL/UI not silently carrying a filter chip that no longer does
   * anything, which would resurface with its old value the moment the user
   * switched back). Not needed by any select that doesn't gate another
   * select's relevance.
   */
  clearKeys?: string[];
}

/** Patch 8.1 §39-42 — a free-text filter beyond the bar's one primary `search` box (e.g. Settlements' `provider_statement_reference`, an exact/ILIKE reference lookup distinct from the batch-number search). */
export interface ReportTextFilterConfig {
  key: string;
  placeholder: string;
  value: string;
}

/** Patch 8.1 §39-42 — a second, independent date range beyond the primary `date_from`/`date_to` (e.g. Returns' `original_sale_date_from`/`_to`, which filters by the ORIGINAL sale's date rather than the return movement's own date). */
export interface ReportDateRangeFilterConfig {
  fromKey: string;
  toKey: string;
  label: string;
  fromValue: string;
  toValue: string;
}

type StoreLookup = { id: string; name_ar: string };

/**
 * Shared URL-driven filter bar for every Phase 8 report page (§45/§63 —
 * server-side filtering, the URL itself is the single source of truth for
 * the current filter state so a link to a filtered report is shareable/
 * bookmarkable, mirroring SettlementBatchesFilters' own convention).
 *
 * `selects` is a config-driven list of extra report-specific dropdowns
 * (category/karat/payment method/scenario/status/etc.) so each of the 16
 * report pages stays a thin wrapper instead of hand-rolling its own filter
 * form. `showSearch`/`stores` are optional — a report with no free-text
 * search or no store concept (e.g. the Daily/Weekly/Monthly/Yearly
 * Management Reports) simply omits them.
 */
export function ReportFilterBar({
  search,
  dateFrom,
  dateTo,
  storeId,
  stores,
  selects = [],
  textFilters = [],
  extraDateRange,
  showSearch = true,
  showDateRange = true,
  /** Single-date mode for the Daily/Weekly Management Reports — renders ONE date input bound to `date_from` instead of a from/to pair. */
  singleDate = false,
  /**
   * Hotfix 8.1.3 §3 — URL keys to CLEAR (never just leave behind) whenever
   * the PRIMARY date range is edited by hand. Built for the Dashboard's
   * `period_preset` (0221's `p_period_preset`): once the user types their
   * own `date_from`/`date_to`, the preset key written by the last
   * quick-period button no longer describes the range being requested, and a
   * stale key would make `report_calendar_comparison_period()` compare
   * against the wrong calendar unit entirely. Empty by default — every other
   * report page has nothing that a date edit invalidates.
   */
  dateChangeClearKeys = [],
  searchPlaceholder = "بحث...",
}: {
  search?: string;
  dateFrom?: string;
  dateTo?: string;
  storeId?: string;
  stores?: StoreLookup[];
  selects?: (ReportSelectFilterConfig & { value: string })[];
  textFilters?: ReportTextFilterConfig[];
  extraDateRange?: ReportDateRangeFilterConfig;
  showSearch?: boolean;
  showDateRange?: boolean;
  singleDate?: boolean;
  dateChangeClearKeys?: string[];
  searchPlaceholder?: string;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [value, setValue] = useState(search ?? "");
  const [textValues, setTextValues] = useState<Record<string, string>>(() => Object.fromEntries(textFilters.map((t) => [t.key, t.value])));
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

  /**
   * Hotfix 8.1.3 §3 — a primary-date edit commits its own key PLUS an empty
   * value for every `dateChangeClearKeys` entry; `updateParams` already
   * deletes (rather than writes) an empty value, so the stale key leaves the
   * URL entirely instead of lingering as `period_preset=`.
   */
  function withDateChangeClears(next: Record<string, string>): Record<string, string> {
    for (const key of dateChangeClearKeys) next[key] = "";
    return next;
  }

  return (
    <div className="mb-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
      {showSearch && (
        <div className="relative">
          <Search className="pointer-events-none absolute start-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder={searchPlaceholder}
            className="ps-9"
            dir="ltr"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && updateParams({ search: value })}
            onBlur={() => updateParams({ search: value })}
          />
        </div>
      )}

      {showDateRange && !singleDate && (
        <>
          <Input type="date" dir="ltr" value={dateFrom ?? ""} onChange={(e) => updateParams(withDateChangeClears({ date_from: e.target.value }))} />
          <Input type="date" dir="ltr" value={dateTo ?? ""} onChange={(e) => updateParams(withDateChangeClears({ date_to: e.target.value }))} />
        </>
      )}

      {singleDate && <Input type="date" dir="ltr" value={dateFrom ?? ""} onChange={(e) => updateParams(withDateChangeClears({ date_from: e.target.value }))} />}

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

      {selects.map((sel) => (
        <Select
          key={sel.key}
          value={sel.value || "all"}
          onValueChange={(v) => {
            const next: Record<string, string> = { [sel.key]: v === "all" ? "" : v };
            for (const clearKey of sel.clearKeys ?? []) next[clearKey] = "";
            updateParams(next);
          }}
        >
          <SelectTrigger>
            <SelectValue placeholder={sel.placeholder} />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">{sel.allLabel}</SelectItem>
            {sel.options.map((opt) => (
              <SelectItem key={opt.value} value={opt.value}>
                {opt.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      ))}

      {textFilters.map((t) => (
        <Input
          key={t.key}
          placeholder={t.placeholder}
          dir="ltr"
          value={textValues[t.key] ?? ""}
          onChange={(e) => setTextValues((prev) => ({ ...prev, [t.key]: e.target.value }))}
          onKeyDown={(e) => e.key === "Enter" && updateParams({ [t.key]: textValues[t.key] ?? "" })}
          onBlur={() => updateParams({ [t.key]: textValues[t.key] ?? "" })}
        />
      ))}

      {extraDateRange && (
        <div className="col-span-full grid grid-cols-1 gap-3 sm:grid-cols-[auto_1fr_1fr] sm:items-center">
          <span className="text-xs text-muted-foreground">{extraDateRange.label}</span>
          <Input type="date" dir="ltr" value={extraDateRange.fromValue ?? ""} onChange={(e) => updateParams({ [extraDateRange.fromKey]: e.target.value })} />
          <Input type="date" dir="ltr" value={extraDateRange.toValue ?? ""} onChange={(e) => updateParams({ [extraDateRange.toKey]: e.target.value })} />
        </div>
      )}
    </div>
  );
}

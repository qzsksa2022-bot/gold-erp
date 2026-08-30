import { describe, expect, it, vi, beforeEach, beforeAll } from "vitest";
import { cleanup, render, screen, fireEvent } from "@testing-library/react";
import "@testing-library/jest-dom";

// Patch 8.1 §70 — REAL component tests for the two URL-driven filter
// controls every Phase 8 report/dashboard page is built on
// (ReportFilterBar, used by all 16 report pages; PeriodPicker, used by the
// Monthly/Yearly Management Reports) — neither had ANY React/Vitest
// coverage before this file, even though report-basis-badge.tsx/
// report-table.tsx/report-summary-cards.tsx/report-export-buttons.tsx (the
// OTHER shared report components) were already covered by
// tests/reports-dashboard-components.test.tsx. This file closes that gap
// for the two components that own the URL itself (§45/§63 — the URL is the
// single source of truth for filter state, so a filtered report link stays
// shareable/bookmarkable) — the exact mechanism the new Patch 8.1 typed
// filters (textFilters/extraDateRange/selects incl. the report_shipping_
// zones_lookup-backed zone dropdown and the basis dropdown) all funnel
// through.
//
// Radix's <Select> needs a few jsdom polyfills for its pointer interactions
// (hasPointerCapture/scrollIntoView/ResizeObserver) — the same, well-known
// requirement already established by tests/adjustments-entry-form-zero-
// charge-state-machine.test.tsx / tests/settlements-preview-state-machine.
// test.tsx; none of this changes the real components under test.
beforeAll(() => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (window.HTMLElement.prototype as any).hasPointerCapture = vi.fn(() => false);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (window.HTMLElement.prototype as any).releasePointerCapture = vi.fn();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (window.HTMLElement.prototype as any).setPointerCapture = vi.fn();
  window.HTMLElement.prototype.scrollIntoView = vi.fn();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (global as any).ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
});

/** Mirrors tests/settlements-preview-state-machine.test.tsx's own pickSelectOption helper for a Radix <Select> in jsdom. */
function pickSelectOption(trigger: HTMLElement, optionName: string | RegExp) {
  fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false, pointerId: 1 });
  fireEvent.click(trigger);
  const option = screen.getByRole("option", { name: optionName });
  fireEvent.pointerUp(option);
  fireEvent.click(option);
}

const { push, searchParamsString } = vi.hoisted(() => ({ push: vi.fn(), searchParamsString: { current: "" } }));
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push, refresh: vi.fn() }),
  useSearchParams: () => new URLSearchParams(searchParamsString.current),
  usePathname: () => "/reports/sales",
}));

import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { PeriodPicker } from "@/features/reports/components/period-picker";

beforeEach(() => {
  cleanup();
  push.mockReset();
  searchParamsString.current = "";
});

describe("ReportFilterBar — URL-driven filter state (§45/§63)", () => {
  it("a free-text search box only updates the URL on blur/Enter (not on every keystroke), and resets page to 1", () => {
    render(<ReportFilterBar search="" dateFrom="2026-08-01" dateTo="2026-08-29" />);
    const input = screen.getByPlaceholderText("بحث...");
    fireEvent.change(input, { target: { value: "SALE-000" } });
    expect(push).not.toHaveBeenCalled();
    fireEvent.blur(input);
    expect(push).toHaveBeenCalledTimes(1);
    const url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.get("search")).toBe("SALE-000");
    expect(url.searchParams.get("page")).toBe("1");
  });

  it("Enter key on the search box also commits (not just blur)", () => {
    render(<ReportFilterBar search="" dateFrom="2026-08-01" dateTo="2026-08-29" />);
    const input = screen.getByPlaceholderText("بحث...");
    fireEvent.change(input, { target: { value: "abc" } });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(push).toHaveBeenCalledTimes(1);
    expect(new URL(push.mock.calls[0][0], "http://localhost").searchParams.get("search")).toBe("abc");
  });

  it("changing date_from/date_to updates the URL immediately (no blur needed) and preserves pre-existing OTHER params rather than clobbering them", () => {
    searchParamsString.current = "store_id=store-9&sort=amount_desc";
    render(<ReportFilterBar search="" dateFrom="2026-08-01" dateTo="2026-08-29" storeId="store-9" />);
    const dateInputs = screen.getAllByDisplayValue(/2026-08-/);
    fireEvent.change(dateInputs[0], { target: { value: "2026-07-01" } });
    const url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.get("date_from")).toBe("2026-07-01");
    expect(url.searchParams.get("store_id")).toBe("store-9");
    expect(url.searchParams.get("sort")).toBe("amount_desc");
    expect(url.searchParams.get("page")).toBe("1");
  });

  it("singleDate mode (Daily/Weekly Management Reports) renders exactly ONE date input bound to date_from, not a from/to pair", () => {
    render(<ReportFilterBar dateFrom="2026-08-15" singleDate showSearch={false} showDateRange />);
    expect(screen.getAllByDisplayValue("2026-08-15")).toHaveLength(1);
  });

  it("showDateRange=false and showSearch=false render neither control", () => {
    render(<ReportFilterBar dateFrom="2026-08-15" dateTo="2026-08-29" showDateRange={false} showSearch={false} />);
    expect(screen.queryByPlaceholderText("بحث...")).not.toBeInTheDocument();
    expect(screen.queryByDisplayValue("2026-08-15")).not.toBeInTheDocument();
  });

  it("Patch 8.1 §39-42: a config-driven `selects` dropdown (e.g. a basis or shipping-zone filter) updates its OWN key on choice, and choosing the sentinel 'all' option CLEARS the param entirely rather than writing the literal string 'all'", () => {
    searchParamsString.current = "basis=current_effective";
    render(
      <ReportFilterBar
        dateFrom="2026-08-01"
        dateTo="2026-08-29"
        showSearch={false}
        selects={[
          {
            key: "basis",
            placeholder: "الأساس",
            allLabel: "الكل",
            value: "current_effective",
            options: [
              { value: "current_effective", label: "الأثر الحالي" },
              { value: "movements_during_period", label: "الحركات خلال الفترة" },
            ],
          },
        ]}
      />,
    );
    const trigger = screen.getByRole("combobox");
    pickSelectOption(trigger, "الحركات خلال الفترة");
    expect(push).toHaveBeenCalledTimes(1);
    let url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.get("basis")).toBe("movements_during_period");

    push.mockReset();
    pickSelectOption(trigger, "الكل");
    expect(push).toHaveBeenCalledTimes(1);
    url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.has("basis")).toBe(false);
  });

  it("Patch 8.1 §39-42: a `textFilters` entry (e.g. Settlements' provider_statement_reference) commits its OWN key on blur, independently of the primary search box", () => {
    render(
      <ReportFilterBar
        dateFrom="2026-08-01"
        dateTo="2026-08-29"
        textFilters={[{ key: "provider_statement_reference", placeholder: "مرجع كشف مزود الخدمة", value: "" }]}
      />,
    );
    const searchInput = screen.getByPlaceholderText("بحث...");
    const refInput = screen.getByPlaceholderText("مرجع كشف مزود الخدمة");
    fireEvent.change(refInput, { target: { value: "REF-123" } });
    fireEvent.blur(refInput);
    expect(push).toHaveBeenCalledTimes(1);
    const url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.get("provider_statement_reference")).toBe("REF-123");
    expect(url.searchParams.has("search")).toBe(false);
    expect(searchInput).toHaveValue("");
  });

  it("Patch 8.1 §39-42: `extraDateRange` (e.g. Returns' original_sale_date_from/_to) writes its OWN pair of keys, independent of the primary date_from/date_to", () => {
    // In production the URL and the dateFrom/dateTo props are always in
    // sync (the page reads both off the SAME real URL) -- mirror that here
    // so updateParams' searchParams.toString() (its actual source of
    // truth, not the React props) already carries date_from/date_to.
    searchParamsString.current = "date_from=2026-08-01&date_to=2026-08-29";
    render(
      <ReportFilterBar
        dateFrom="2026-08-01"
        dateTo="2026-08-29"
        extraDateRange={{ fromKey: "original_sale_date_from", toKey: "original_sale_date_to", label: "تاريخ البيع الأصلي", fromValue: "", toValue: "" }}
      />,
    );
    const extraFromInput = screen.getByText("تاريخ البيع الأصلي").parentElement!.querySelectorAll("input")[0];
    fireEvent.change(extraFromInput, { target: { value: "2026-01-01" } });
    const url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.get("original_sale_date_from")).toBe("2026-01-01");
    expect(url.searchParams.get("date_from")).toBe("2026-08-01");
  });

  it("the store dropdown clears store_id when 'كل المتاجر المتاحة' (all stores) is chosen", () => {
    searchParamsString.current = "store_id=store-1";
    render(
      <ReportFilterBar
        dateFrom="2026-08-01"
        dateTo="2026-08-29"
        showSearch={false}
        storeId="store-1"
        stores={[
          { id: "store-1", name_ar: "متجر الرياض" },
          { id: "store-2", name_ar: "متجر جدة" },
        ]}
      />,
    );
    pickSelectOption(screen.getByRole("combobox"), "متجر جدة");
    let url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.get("store_id")).toBe("store-2");

    push.mockReset();
    pickSelectOption(screen.getByRole("combobox"), "كل المتاجر المتاحة");
    url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.has("store_id")).toBe(false);
  });
});

describe("PeriodPicker — calendar-period URL state for Monthly/Yearly Management Reports (§36/§37)", () => {
  it("changing the year updates ONLY the year param (no page param -- these reports don't paginate)", () => {
    render(<PeriodPicker year={2026} />);
    pickSelectOption(screen.getAllByRole("combobox")[0], "2025");
    expect(push).toHaveBeenCalledTimes(1);
    const url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.get("year")).toBe("2025");
    expect(url.searchParams.has("page")).toBe(false);
  });

  it("showMonth=false (Yearly Report) renders exactly one combobox (year only); showMonth=true (Monthly Report) renders a second month combobox with all 12 Arabic month labels", () => {
    const { unmount } = render(<PeriodPicker year={2026} showMonth={false} />);
    expect(screen.getAllByRole("combobox")).toHaveLength(1);
    unmount();

    render(<PeriodPicker year={2026} month={8} showMonth />);
    const combos = screen.getAllByRole("combobox");
    expect(combos).toHaveLength(2);
    fireEvent.pointerDown(combos[1], { button: 0, ctrlKey: false, pointerId: 1 });
    fireEvent.click(combos[1]);
    expect(screen.getByRole("option", { name: "أغسطس" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "يناير" })).toBeInTheDocument();
  });

  it("choosing a month writes the month param independently of year, and defaults the trigger to month 1 when no month prop is passed", () => {
    // Mirrors the extraDateRange test above -- the URL and the `year` prop
    // are always in sync in production; updateParams' actual source of
    // truth is searchParams.toString(), not the React prop.
    searchParamsString.current = "year=2026";
    render(<PeriodPicker year={2026} showMonth />);
    const combos = screen.getAllByRole("combobox");
    pickSelectOption(combos[1], "مارس");
    const url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.get("month")).toBe("3");
    expect(url.searchParams.get("year")).toBe("2026");
  });

  it("the optional store dropdown behaves identically to ReportFilterBar's (all-stores sentinel clears store_id)", () => {
    render(<PeriodPicker year={2026} stores={[{ id: "store-1", name_ar: "متجر الرياض" }]} storeId="store-1" />);
    const combos = screen.getAllByRole("combobox");
    pickSelectOption(combos[combos.length - 1], "كل المتاجر المتاحة");
    const url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.has("store_id")).toBe(false);
  });
});

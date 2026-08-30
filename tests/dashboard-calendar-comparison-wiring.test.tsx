// Hotfix 8.1.3 Blocker 1 — Dashboard calendar-comparison wiring.
//
// Migration 0221 shipped `get_dashboard_summary_with_comparison()` (the
// calendar-aware comparison wrapper: "This Month" compares against the FULL
// previous calendar month, "This Week" against the FULL previous Riyadh
// week) and 0222 wired the four Management Reports to it — but the Dashboard
// itself still called the bare `get_dashboard_summary()`, so every Dashboard
// KPI's comparison figure was still the generic "immediately preceding
// equal-length range" the whole hotfix existed to stop using, and the
// `p_period_preset` key the wrapper resolves that calendar unit FROM was
// never sent at all.
//
// This file proves the four wiring rules end to end:
//   §1 the page calls the WRAPPER RPC, never `get_dashboard_summary`;
//   §2 a quick-period button's own preset key reaches `p_period_preset`;
//   §3 a manual date edit leaves NO stale preset behind (in the URL the bar
//      writes, and in what the page then forwards to the RPC);
//   §4 the default month-start→today range resolves to `this_month`.
//
// Testing convention follows this project's own established pattern for
// server-only Next.js code under Vitest (see tests/reports-export-route-
// integration.test.ts and tests/settlements-actions-permission-boundary.
// test.ts): mock ONLY the true I/O boundaries — `requirePermission` (reads
// real cookies) and `@/lib/supabase/server`'s `createClient` (makes a real
// network call) — and run the REAL page component, the REAL query wrappers
// and the REAL preset resolver through them. The page is an async Server
// Component: awaiting it returns its element tree, which is all that is
// needed here (the assertions are about which RPC it called with which
// arguments, not about rendered markup — that is already covered by
// tests/reports-dashboard-components.test.tsx).
import { describe, expect, it, vi, beforeEach } from "vitest";
import { cleanup, render, screen, fireEvent } from "@testing-library/react";
import "@testing-library/jest-dom";

const { requirePermission } = vi.hoisted(() => ({ requirePermission: vi.fn() }));
vi.mock("@/lib/permissions/guard", () => ({ requirePermission }));

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({
    rpc: rpcMock,
    // getDashboardStats() reads four ordinary PostgREST queries (profiles /
    // stores / audit_logs). Supabase's query builder is a thenable, so one
    // chainable stub whose `then` resolves an empty result set satisfies
    // every one of them — none of this file's assertions depend on those
    // counts.
    from: () => makeQueryStub(),
  }),
}));

// Every module in the page's import graph starts with `import "server-only"`,
// whose default Node resolution condition throws unconditionally (it only
// no-ops under the `"react-server"` condition Next.js's own bundler sets,
// which Vitest does not). Mocked exactly as in tests/reports-export-route-
// integration.test.ts — the established project convention for this.
vi.mock("server-only", () => ({}));

// The Dashboard page renders two client components that call
// `next/navigation` hooks (`PeriodPresets`, `ReportFilterBar`). The page-
// level tests only build their elements (never render them), but the
// component-level tests at the bottom of this file DO render them, so the
// hooks are stubbed here the same way tests/report-filter-bar-and-period-
// picker.test.tsx stubs them.
const { push, searchParamsString } = vi.hoisted(() => ({ push: vi.fn(), searchParamsString: { current: "" } }));
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push, refresh: vi.fn() }),
  useSearchParams: () => new URLSearchParams(searchParamsString.current),
  usePathname: () => "/dashboard",
}));

/* eslint-disable @typescript-eslint/no-explicit-any */
function makeQueryStub() {
  const chain: any = {
    select: () => chain,
    eq: () => chain,
    in: () => chain,
    order: () => chain,
    limit: () => chain,
    then: (resolve: any, reject: any) => Promise.resolve({ data: [], count: 0, error: null }).then(resolve, reject),
  };
  return chain;
}
/* eslint-enable @typescript-eslint/no-explicit-any */

import DashboardPage from "@/app/(app)/dashboard/page";
import { PeriodPresets } from "@/features/dashboard/components/period-presets";
import { ReportFilterBar } from "@/features/reports/components/report-filter-bar";
import { buildPresets, resolveDashboardPeriodPreset, CUSTOM_PERIOD_PRESET } from "@/features/dashboard/period-presets";
import { riyadhTodayIsoDate } from "@/lib/date";

/**
 * A realistically-shaped `get_dashboard_summary_with_comparison()` envelope
 * (0221): the same domain sub-objects `get_dashboard_summary()` returns,
 * plus the wrapper's own `period_preset`/`previous_date_from`/
 * `previous_date_to`/`comparison_mode` envelope keys.
 */
const SUMMARY_ENVELOPE = {
  date_from: "2026-08-01",
  date_to: "2026-08-30",
  period_preset: "this_month",
  previous_date_from: "2026-07-01",
  previous_date_to: "2026-07-31",
  comparison_mode: "calendar_aware",
  contains_open_business_day: false,
  sales: { orders_count: 1, previous_orders_count: 2, orders_count_change: -1, sales_revenue: "1000.00" },
  net_operating_return: { net_operating_return: "150.00" },
};

const TRENDS_ENVELOPE = { granularity: "day", date_from: "2026-08-01", date_to: "2026-08-30", buckets: [] };

function rpcRouter() {
  return vi.fn(async (name: string) => {
    switch (name) {
      case "get_dashboard_summary_with_comparison":
        return { data: SUMMARY_ENVELOPE, error: null };
      case "get_dashboard_trends":
        return { data: TRENDS_ENVELOPE, error: null };
      case "report_visible_stores_lookup":
        return { data: [], error: null };
      default:
        throw new Error(`unexpected rpc call in test: ${name}`);
    }
  });
}

/** The single `get_dashboard_summary_with_comparison` call's argument object. */
function comparisonCallArgs() {
  const call = rpcMock.mock.calls.find((c) => c[0] === "get_dashboard_summary_with_comparison");
  expect(call, "the Dashboard never called get_dashboard_summary_with_comparison").toBeDefined();
  return call![1] as Record<string, unknown>;
}

async function renderDashboard(params: Record<string, string>) {
  requirePermission.mockResolvedValue({ userId: "actor-1", email: "viewer@example.invalid", permissions: new Set(["dashboard.view"]), isSuperAdmin: false });
  rpcMock.mockImplementation(rpcRouter());
  await DashboardPage({ searchParams: Promise.resolve(params) });
}

beforeEach(() => {
  cleanup();
  requirePermission.mockReset();
  rpcMock.mockReset();
  push.mockReset();
  searchParamsString.current = "";
});

describe("Hotfix 8.1.3 §1-2 — the Dashboard page calls the calendar-aware comparison RPC with the right preset", () => {
  it("§1 CRITICAL: the page calls get_dashboard_summary_with_comparison and NEVER the bare get_dashboard_summary", async () => {
    await renderDashboard({});

    const called = rpcMock.mock.calls.map((c) => c[0]);
    expect(called).toContain("get_dashboard_summary_with_comparison");
    expect(called).not.toContain("get_dashboard_summary");
  });

  it("§4: with NO query params at all, the default month-start→today range is sent as the `this_month` preset (never `custom`, never null)", async () => {
    await renderDashboard({});

    const today = riyadhTodayIsoDate();
    const args = comparisonCallArgs();
    expect(args).toMatchObject({
      p_date_from: `${today.slice(0, 7)}-01`,
      p_date_to: today,
      p_period_preset: "this_month",
      p_store_ids: null,
    });
  });

  it.each(["today", "yesterday", "last7", "last30", "this_week", "last_week", "this_month", "last_month", "this_year", "last_year"])(
    "§2: the quick-period button preset `%s` reaches the RPC as p_period_preset, together with that preset's OWN from/to",
    async (key) => {
      const preset = buildPresets().find((p) => p.key === key)!;
      await renderDashboard({ date_from: preset.from, date_to: preset.to, period_preset: key });

      expect(comparisonCallArgs()).toMatchObject({ p_date_from: preset.from, p_date_to: preset.to, p_period_preset: key });
    },
  );

  it("§2: an explicit store_id is still forwarded alongside the preset (the preset wiring did not displace store scoping)", async () => {
    const preset = buildPresets().find((p) => p.key === "this_week")!;
    await renderDashboard({ date_from: preset.from, date_to: preset.to, period_preset: "this_week", store_id: "store-9" });

    expect(comparisonCallArgs()).toMatchObject({ p_period_preset: "this_week", p_store_ids: ["store-9"] });
  });

  it("§2/§3: a hand-crafted UNKNOWN preset key is never forwarded verbatim — it is re-derived from the range like an absent one", async () => {
    await renderDashboard({ date_from: "2026-03-11", date_to: "2026-04-07", period_preset: "not-a-real-preset" });

    expect(comparisonCallArgs()).toMatchObject({ p_period_preset: CUSTOM_PERIOD_PRESET });
  });
});

describe("Hotfix 8.1.3 §3 — a manual date edit leaves no stale preset", () => {
  it("§3 CRITICAL: a hand-picked range with NO period_preset param reaches the RPC as `custom`, never a leftover calendar preset", async () => {
    await renderDashboard({ date_from: "2026-03-11", date_to: "2026-04-07" });

    const args = comparisonCallArgs();
    expect(args).toMatchObject({ p_date_from: "2026-03-11", p_date_to: "2026-04-07", p_period_preset: CUSTOM_PERIOD_PRESET });
  });

  it("§3 CRITICAL: editing a date in the filter bar REMOVES period_preset from the URL entirely (not `period_preset=`), while keeping every other param", () => {
    // The URL the user is on after clicking "هذا الشهر".
    searchParamsString.current = "date_from=2026-08-01&date_to=2026-08-30&period_preset=this_month&store_id=store-9";
    render(<ReportFilterBar dateFrom="2026-08-01" dateTo="2026-08-30" storeId="store-9" showSearch={false} dateChangeClearKeys={["period_preset"]} />);

    const dateInputs = screen.getAllByDisplayValue(/2026-08-/);
    fireEvent.change(dateInputs[1], { target: { value: "2026-08-15" } });

    expect(push).toHaveBeenCalledTimes(1);
    const url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.get("date_to")).toBe("2026-08-15");
    expect(url.searchParams.has("period_preset")).toBe(false);
    expect(url.searchParams.get("date_from")).toBe("2026-08-01");
    expect(url.searchParams.get("store_id")).toBe("store-9");
  });

  it("§3: editing date_from clears the preset just as date_to does", () => {
    searchParamsString.current = "date_from=2026-08-01&date_to=2026-08-30&period_preset=this_month";
    render(<ReportFilterBar dateFrom="2026-08-01" dateTo="2026-08-30" showSearch={false} dateChangeClearKeys={["period_preset"]} />);

    fireEvent.change(screen.getAllByDisplayValue(/2026-08-/)[0], { target: { value: "2026-08-10" } });

    const url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.get("date_from")).toBe("2026-08-10");
    expect(url.searchParams.has("period_preset")).toBe(false);
  });

  it("§3: the clearing is OPT-IN — a report page that passes no dateChangeClearKeys is completely unaffected (no regression for the other 16 report pages)", () => {
    searchParamsString.current = "date_from=2026-08-01&date_to=2026-08-30&period_preset=this_month";
    render(<ReportFilterBar dateFrom="2026-08-01" dateTo="2026-08-30" showSearch={false} />);

    fireEvent.change(screen.getAllByDisplayValue(/2026-08-/)[0], { target: { value: "2026-08-10" } });

    expect(new URL(push.mock.calls[0][0], "http://localhost").searchParams.get("period_preset")).toBe("this_month");
  });
});

describe("Hotfix 8.1.3 §2 — the quick-period buttons write period_preset into the URL", () => {
  it("clicking a preset writes its OWN key alongside date_from/date_to, preserving unrelated params", () => {
    searchParamsString.current = "store_id=store-9";
    render(<PeriodPresets dateFrom="2026-08-01" dateTo="2026-08-30" periodPreset="this_month" />);

    fireEvent.click(screen.getByRole("button", { name: "هذا الأسبوع" }));

    expect(push).toHaveBeenCalledTimes(1);
    const url = new URL(push.mock.calls[0][0], "http://localhost");
    const thisWeek = buildPresets().find((p) => p.key === "this_week")!;
    expect(url.searchParams.get("period_preset")).toBe("this_week");
    expect(url.searchParams.get("date_from")).toBe(thisWeek.from);
    expect(url.searchParams.get("date_to")).toBe(thisWeek.to);
    expect(url.searchParams.get("store_id")).toBe("store-9");
  });

  it("clicking a preset OVERWRITES a previously-set period_preset rather than appending a second one", () => {
    searchParamsString.current = "period_preset=this_month";
    render(<PeriodPresets periodPreset="this_month" />);

    fireEvent.click(screen.getByRole("button", { name: "الشهر الماضي" }));

    const url = new URL(push.mock.calls[0][0], "http://localhost");
    expect(url.searchParams.getAll("period_preset")).toEqual(["last_month"]);
  });

  it("the resolved preset drives the active-button highlight: `custom` (a hand-picked range) highlights NOTHING", () => {
    const { unmount } = render(<PeriodPresets dateFrom="2026-08-01" dateTo="2026-08-30" periodPreset="this_month" />);
    expect(screen.getByRole("button", { name: "هذا الشهر" }).className).toContain("border-accent");
    unmount();

    render(<PeriodPresets dateFrom="2026-03-11" dateTo="2026-04-07" periodPreset={CUSTOM_PERIOD_PRESET} />);
    for (const button of screen.getAllByRole("button")) expect(button.className).not.toContain("border-accent");
  });
});

describe("Hotfix 8.1.3 §2-4 — resolveDashboardPeriodPreset (pure)", () => {
  // Wednesday 2026-09-02 — not itself a Riyadh week boundary, matching
  // tests/dashboard-period-presets.test.ts's own pinned date.
  const WED_SEP_2_2026 = new Date(2026, 8, 2);

  it("§4: the default month-start→today range resolves to this_month even with NO preset param", () => {
    expect(resolveDashboardPeriodPreset(undefined, "2026-09-01", "2026-09-02", WED_SEP_2_2026)).toBe("this_month");
  });

  /**
   * Hotfix 8.1.3 §4 — the collision this rule exists for, pinned to a real
   * date rather than left to whichever day the suite happens to run on: on
   * the 30th of a month, `last30` (today-29 → today) and `this_month`
   * (month start → today) are byte-for-byte the SAME range. Deriving the
   * first list match would send `last30`, which 0221 handles in its generic
   * equal-length `else` branch — the default Dashboard view would silently
   * lose calendar-aware comparison on exactly one day per month.
   */
  it("§4: on a day where `last30` coincides exactly with `this_month`, derivation resolves to the CALENDAR unit", () => {
    const AUG_30_2026 = new Date(2026, 7, 30);
    const presets = buildPresets(AUG_30_2026);
    const last30 = presets.find((p) => p.key === "last30")!;
    const thisMonth = presets.find((p) => p.key === "this_month")!;
    expect([last30.from, last30.to]).toEqual([thisMonth.from, thisMonth.to]); // the collision itself

    expect(resolveDashboardPeriodPreset(undefined, thisMonth.from, thisMonth.to, AUG_30_2026)).toBe("this_month");
    // An explicitly-clicked "آخر 30 يومًا" still wins over the derivation.
    expect(resolveDashboardPeriodPreset("last30", thisMonth.from, thisMonth.to, AUG_30_2026)).toBe("last30");
  });

  it("§4: the same tie-break applies to a Friday's `last7`/`this_week` collision", () => {
    const FRI_SEP_4_2026 = new Date(2026, 8, 4);
    expect(FRI_SEP_4_2026.getDay()).toBe(5); // Friday — the last day of a Riyadh week
    const presets = buildPresets(FRI_SEP_4_2026);
    const last7 = presets.find((p) => p.key === "last7")!;
    const thisWeek = presets.find((p) => p.key === "this_week")!;
    expect([last7.from, last7.to]).toEqual([thisWeek.from, thisWeek.to]);

    expect(resolveDashboardPeriodPreset(undefined, thisWeek.from, thisWeek.to, FRI_SEP_4_2026)).toBe("this_week");
  });

  it("§2: a known preset key is passed through untouched", () => {
    expect(resolveDashboardPeriodPreset("this_week", "2026-08-29", "2026-09-02", WED_SEP_2_2026)).toBe("this_week");
  });

  it("§3: no preset + a range matching no preset resolves to custom", () => {
    expect(resolveDashboardPeriodPreset(undefined, "2026-03-11", "2026-04-07", WED_SEP_2_2026)).toBe(CUSTOM_PERIOD_PRESET);
    expect(resolveDashboardPeriodPreset("", "2026-03-11", "2026-04-07", WED_SEP_2_2026)).toBe(CUSTOM_PERIOD_PRESET);
  });

  it("§3: an unknown key never leaks through to p_period_preset", () => {
    expect(resolveDashboardPeriodPreset("../../etc", "2026-03-11", "2026-04-07", WED_SEP_2_2026)).toBe(CUSTOM_PERIOD_PRESET);
  });

  it("§4: every key it can return is one report_calendar_comparison_period() (0221) actually understands", () => {
    // The presets 0221 branches on by name, plus the `custom` key its own
    // `else` branch documents. A preset key this resolver could emit but
    // 0221 never names would silently get equal-length comparison.
    const known = new Set(["today", "yesterday", "last7", "last30", "this_week", "last_week", "this_month", "last_month", "this_year", "last_year", CUSTOM_PERIOD_PRESET]);
    for (const preset of buildPresets(WED_SEP_2_2026)) expect(known.has(preset.key)).toBe(true);
    expect(known.has(resolveDashboardPeriodPreset(undefined, "1999-01-01", "1999-01-02", WED_SEP_2_2026))).toBe(true);
  });
});

import { describe, expect, it } from "vitest";
import { buildPresets, ymd } from "@/features/dashboard/components/period-presets";

// Phase 8 Patch 8.1 §43-46 — Dashboard period presets. `buildPresets`
// accepts a pinned `now` (a Date whose LOCAL getters already read as Riyadh
// wall-clock time, `riyadhNow()`'s own contract) so this suite never
// depends on the real system clock. Wednesday 2026-09-02 is used
// specifically because it is NOT itself a Riyadh week boundary — it
// exercises the Saturday-start-week math (`riyadh_week_start()`, 0199)
// rather than a degenerate same-day case.
const WED_SEP_2_2026 = new Date(2026, 8, 2);

describe("features/dashboard/components/period-presets.tsx — buildPresets", () => {
  it("computes every preset's from/to relative to a pinned Wednesday, matching the Riyadh Week Contract (Saturday start) for 'this week'", () => {
    const presets = buildPresets(WED_SEP_2_2026);
    const byKey = Object.fromEntries(presets.map((p) => [p.key, p]));

    expect(byKey.today).toMatchObject({ from: "2026-09-02", to: "2026-09-02" });
    expect(byKey.yesterday).toMatchObject({ from: "2026-09-01", to: "2026-09-01" });
    expect(byKey.last7).toMatchObject({ from: "2026-08-27", to: "2026-09-02" });
    expect(byKey.last30).toMatchObject({ from: "2026-08-04", to: "2026-09-02" });
    // Riyadh Week Contract (0199 riyadh_week_start): Saturday→Friday. Wed
    // Sep 2 2026 falls in the week that started Saturday Aug 29 2026.
    expect(byKey.this_week).toMatchObject({ from: "2026-08-29", to: "2026-09-02" });
    expect(byKey.this_month).toMatchObject({ from: "2026-09-01", to: "2026-09-02" });
    expect(byKey.last_month).toMatchObject({ from: "2026-08-01", to: "2026-08-31" });
    expect(byKey.this_year).toMatchObject({ from: "2026-01-01", to: "2026-09-02" });
  });

  it("'this week' resolves to itself when pinned exactly on a Riyadh week-start Saturday (degenerate boundary case)", () => {
    const saturday = new Date(2026, 7, 29); // Sat 2026-08-29
    expect(saturday.getDay()).toBe(6);
    const presets = buildPresets(saturday);
    const thisWeek = presets.find((p) => p.key === "this_week")!;
    expect(thisWeek.from).toBe("2026-08-29");
    expect(thisWeek.to).toBe("2026-08-29");
  });

  it("'last month' correctly rolls back across a January→December year boundary", () => {
    const presets = buildPresets(new Date(2026, 0, 15)); // 2026-01-15
    const lastMonth = presets.find((p) => p.key === "last_month")!;
    expect(lastMonth.from).toBe("2025-12-01");
    expect(lastMonth.to).toBe("2025-12-31");
  });

  it("every preset has a distinct key and a non-empty Arabic label", () => {
    const presets = buildPresets(WED_SEP_2_2026);
    const keys = presets.map((p) => p.key);
    expect(new Set(keys).size).toBe(keys.length);
    for (const p of presets) expect(p.label.length).toBeGreaterThan(0);
  });
});

describe("features/dashboard/components/period-presets.tsx — ymd", () => {
  it("zero-pads single-digit month/day", () => {
    expect(ymd(new Date(2026, 0, 5))).toBe("2026-01-05");
  });
});

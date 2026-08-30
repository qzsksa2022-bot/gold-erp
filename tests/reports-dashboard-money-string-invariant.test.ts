import { describe, expect, it, vi, beforeEach } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

// Phase 8 (Reports, Dashboard & Exports) — extends the "no-JS-float" guard
// pattern established by tests/settlements-money-string-invariant.test.ts
// to src/features/reports and src/features/dashboard.
//
// IMPORTANT — this is a DIFFERENT invariant shape than the settlements
// guard, not a blind copy, because these two features sit on different
// sides of the Decimal Transport Boundary (§40/§41):
//
//   - settlements/schema.ts is on the WRITE path: a user-typed money value
//     must stay a STRING all the way from the form to the RPC call, so
//     `Number(`/`parseFloat(`/`parseInt(` are illegitimate ANYWHERE in that
//     directory (even inside a `.refine()` validation callback) — there is
//     no display formatting concern there at all, only a wire-safety one.
//
//   - src/features/reports and src/features/dashboard are READ-ONLY: they
//     fetch a report/dashboard RPC's jsonb payload and DISPLAY it.
//     queries.ts's own header comment states the actual rule: "never parse
//     [a money/weight field] with parseFloat/Number for anything that feeds
//     another calculation; format-only display via src/lib/money.ts is
//     fine." So `Number(` is genuinely legitimate in the display COMPONENTS
//     (report-table.tsx/kpi-section.tsx/etc. all call `Number(raw)` as a
//     direct, single-shot argument to `Intl.NumberFormat(...).format(...)`
//     or `formatSAR`/`formatGrams` themselves do this internally) — banning
//     it there would be actively wrong, not a safety net.
//
//     The genuine transport-boundary analog to settlements/schema.ts, on
//     THIS side, is queries.ts: the thin wrapper around `supabase.rpc(...)`
//     that hands the RPC's jsonb payload to React. That layer must return
//     the payload utterly VERBATIM — no coercion of any kind — exactly like
//     settlements/schema.ts must never coerce a value on its way OUT. That
//     is what this file actually guards, both statically (source-scan) and
//     at runtime (a mocked RPC response round-tripped through the real
//     query function, asserting byte-for-byte string identity).
vi.mock("server-only", () => ({}));

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({ rpc: rpcMock }),
}));

function stripComments(source: string): string {
  const withoutBlockComments = source.replace(/\/\*[\s\S]*?\*\//g, "");
  return withoutBlockComments
    .split("\n")
    .map((line) => line.replace(/\/\/.*$/, ""))
    .join("\n");
}

describe("STATIC: src/features/reports/queries.ts and src/features/dashboard/queries.ts never coerce the RPC payload", () => {
  const QUERY_FILES = [
    path.join(process.cwd(), "src/features/reports/queries.ts"),
    path.join(process.cwd(), "src/features/dashboard/queries.ts"),
  ];

  it.each(QUERY_FILES.map((f) => [path.relative(process.cwd(), f), f] as const))(
    "%s: zero Number(/parseFloat(/parseInt( calls anywhere — every RPC response is returned utterly verbatim (the Decimal Transport Boundary starts here, not just at the RPC itself)",
    (_label, file) => {
      const source = stripComments(readFileSync(file, "utf-8"));
      expect(source).not.toMatch(/\bNumber\s*\(/);
      expect(source).not.toMatch(/\bparseFloat\s*\(/);
      expect(source).not.toMatch(/\bparseInt\s*\(/);
    },
  );

  it("regression guard for the scanner itself: a synthetic Number( call in a query wrapper is caught (proves this scan isn't accidentally vacuous)", () => {
    const synthetic = `
      export async function getSalesReport(f) {
        const { data } = await supabase.rpc("get_sales_report", {});
        return { ...data, sales_revenue: Number(data.summary.sales_revenue) };
      }
    `;
    expect(stripComments(synthetic)).toMatch(/\bNumber\s*\(/);
  });
});

describe("STATIC: report-registry.ts / management-registry.ts declare column formats via a CLOSED, safe set — never a raw 'number' passthrough format", () => {
  // §40/§41 belt-and-braces: every column/summary-field/KPI-field format
  // string used across the report registries must be one of the formats
  // report-table.tsx/report-summary-cards.tsx/kpi-section.tsx actually
  // implement via formatSAR/formatGrams/Intl.NumberFormat/formatRiyadhDate
  // — a typo'd or ad hoc new format string would silently fall through to
  // `String(raw)` (harmless for display but a signal something drifted from
  // the shared registry's own contract), so this pins the known-good set.
  const KNOWN_FORMATS = new Set(["money", "weight", "int", "date", "text", "badge"]);

  it("every format value in report-registry.ts's column/summary-field arrays is a known, implemented format", () => {
    const source = readFileSync(path.join(process.cwd(), "src/features/reports/export/report-registry.ts"), "utf-8");
    const formatMatches = [...source.matchAll(/format:\s*"([a-z_]+)"/g)].map((m) => m[1]);
    expect(formatMatches.length).toBeGreaterThan(20); // sanity: the registry is large, this should find plenty
    for (const f of formatMatches) {
      expect(KNOWN_FORMATS.has(f), `unexpected format "${f}" in report-registry.ts`).toBe(true);
    }
  });
});

describe("RUNTIME: queries.ts hands the RPC's money/weight TEXT fields through byte-for-byte, never coerced to a JS number", () => {
  beforeEach(() => {
    rpcMock.mockReset();
  });

  // 27 significant digits — deliberately beyond IEEE-754 double precision
  // (~15-17 guaranteed decimal digits), mirroring supabase/tests/
  // postgrest_http_test_setup.sql's own synthetic Patch 2.2 test value.
  // Real schema columns never reach this width, but using a literal wide
  // enough to force a REAL rounding error if it were ever coerced is what
  // actually proves the mechanism, not just "no real value happens to be
  // long enough to expose it yet".
  const HIGH_PRECISION_VALUE = "123456789012345678.123456789";

  it("getSalesReport() returns summary.sales_revenue as the EXACT original string, unchanged, never Number()-rounded", async () => {
    const { getSalesReport } = await import("@/features/reports/queries");
    rpcMock.mockResolvedValue({
      data: {
        total_count: 1,
        limit: 50,
        offset: 0,
        summary: { orders_count: 1, sales_revenue: HIGH_PRECISION_VALUE },
        rows: [{ order_id: "1", sales_revenue: HIGH_PRECISION_VALUE }],
      },
      error: null,
    });

    const envelope = await getSalesReport({ date_from: "2026-08-01", date_to: "2026-08-29", page: 1 });

    expect(typeof envelope.summary.sales_revenue).toBe("string");
    expect(envelope.summary.sales_revenue).toBe(HIGH_PRECISION_VALUE);
    expect(envelope.rows[0].sales_revenue).toBe(HIGH_PRECISION_VALUE);
  });

  it("getDashboardSummary() returns net_operating_return.net_operating_return as the EXACT original string, unchanged", async () => {
    const { getDashboardSummary } = await import("@/features/dashboard/queries");
    rpcMock.mockResolvedValue({
      data: {
        basis: "current_effective_impact_within_period",
        net_operating_return: { net_operating_return: HIGH_PRECISION_VALUE },
      },
      error: null,
    });

    const result = await getDashboardSummary("2026-08-01", "2026-08-29");
    const nor = result.net_operating_return as Record<string, unknown>;

    expect(typeof nor.net_operating_return).toBe("string");
    expect(nor.net_operating_return).toBe(HIGH_PRECISION_VALUE);
  });

  it("§79: getSalesReport() propagates a genuinely ABSENT profit key as absent — not present-as-null and not present-as-0 — through the exact same object reference React renders from", async () => {
    const { getSalesReport } = await import("@/features/reports/queries");
    const summaryWithoutProfit = { orders_count: 5, sales_revenue: "100.00" }; // no gross_profit key at all
    rpcMock.mockResolvedValue({
      data: { total_count: 5, limit: 50, offset: 0, summary: summaryWithoutProfit, rows: [] },
      error: null,
    });

    const envelope = await getSalesReport({ date_from: "2026-08-01", date_to: "2026-08-29", page: 1 });
    expect("gross_profit" in envelope.summary).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Patch 8.1 §19-21 — extends the guard beyond queries.ts's blanket ban to
// every OTHER file under src/features/reports/**, src/features/dashboard/**,
// src/features/reports/export/**, and src/app/api/reports/export/**. Unlike
// queries.ts (a pure transport layer with zero legitimate Number() use),
// these files DO have legitimate Number()/parseFloat()/parseInt() call
// sites — count formatting (Intl.NumberFormat on an "int" field), calendar
// date-part parsing (year/month query params) — so a blanket ban would be
// wrong here. The rule instead (§21's own wording: "any Number( allowlist
// exception must be explicit, documented, final-rendering-only — never a
// blanket per-file exception") is: every bare Number(/parseFloat(/parseInt(
// call site in these directories must carry an inline `no-float-ok:` marker
// comment (on the same line or the line immediately above) explaining WHY
// it's safe — money/weight/percent ARITHMETIC (sums, ratios, comparisons,
// Math.abs/max) must instead go through `@/lib/decimal`'s `Decimal`/
// `toDecimal`/`decimalSign`/`decimalAbsFixed`/`decimalRatioToNumber`/
// `safeExcelNumber` helpers, whose OWN `.toNumber()`/internal conversions
// are the legitimate final-rendering-boundary step and are deliberately NOT
// flagged by this scan (`\bNumber\s*\(` requires a word boundary
// immediately before "Number", so `toNumber(`/`safeExcelNumber(`/
// `decimalRatioToNumber(` — every decimal.js-suffixed or camelCase-prefixed
// call — never matches; only a genuinely BARE `Number(`/`parseFloat(`/
// `parseInt(` does).
describe("STATIC §19-21: every Number(/parseFloat(/parseInt( in reports/dashboard display+export code is an explicitly documented, final-rendering-only exception", () => {
  const TARGET_DIRS = [
    "src/features/reports",
    "src/features/dashboard",
    "src/app/api/reports/export",
  ].map((d) => path.join(process.cwd(), d));

  // queries.ts files are covered by the STRICTER, zero-tolerance blanket ban
  // above (the genuine Decimal Transport Boundary) — excluded here so the
  // two rules never conflict; a Number( there fails the blanket-ban test
  // regardless of any marker comment.
  const EXCLUDED_BASENAMES = new Set(["queries.ts"]);

  function collectSourceFiles(dir: string): string[] {
    const out: string[] = [];
    for (const entry of readdirSync(dir)) {
      const full = path.join(dir, entry);
      const st = statSync(full);
      if (st.isDirectory()) {
        out.push(...collectSourceFiles(full));
      } else if (/\.(ts|tsx)$/.test(entry) && !entry.endsWith(".test.ts") && !entry.endsWith(".test.tsx") && !EXCLUDED_BASENAMES.has(entry)) {
        out.push(full);
      }
    }
    return out;
  }

  const files = TARGET_DIRS.flatMap((d) => collectSourceFiles(d));

  it("sanity: this scan actually found a meaningful number of source files (not accidentally vacuous)", () => {
    expect(files.length).toBeGreaterThan(15);
  });

  it.each(files.map((f) => [path.relative(process.cwd(), f), f] as const))("%s: every bare Number(/parseFloat(/parseInt( call carries a same-line-or-line-above `no-float-ok:` marker", (_label, file) => {
    const rawLines = readFileSync(file, "utf-8").split("\n");
    // Strip block/line comments for MATCHING purposes only (so a comment's
    // own prose mentioning "Number(" is never mistaken for a real call) —
    // LINE-PRESERVING, unlike the shared `stripComments()` above (which
    // deletes embedded newlines inside a multi-line block comment and would
    // silently shift every subsequent line number out of correlation with
    // `rawLines`, where the marker itself is read from).
    let insideBlockComment = false;
    const strippedLines = rawLines.map((line) => {
      let result = "";
      let i = 0;
      while (i < line.length) {
        if (insideBlockComment) {
          const end = line.indexOf("*/", i);
          if (end === -1) {
            i = line.length;
          } else {
            i = end + 2;
            insideBlockComment = false;
          }
          continue;
        }
        if (line.startsWith("//", i)) break; // rest of line is a line comment
        if (line.startsWith("/*", i)) {
          insideBlockComment = true;
          i += 2;
          continue;
        }
        result += line[i];
        i++;
      }
      return result;
    });
    const offenders: number[] = [];
    strippedLines.forEach((line, i) => {
      if (/\bNumber\s*\(|\bparseFloat\s*\(|\bparseInt\s*\(/.test(line)) {
        const hasMarkerHere = /no-float-ok:/.test(rawLines[i] ?? "");
        const hasMarkerAbove = i > 0 && /no-float-ok:/.test(rawLines[i - 1] ?? "");
        if (!hasMarkerHere && !hasMarkerAbove) offenders.push(i + 1);
      }
    });
    expect(offenders, `${path.relative(process.cwd(), file)}: unmarked Number(/parseFloat(/parseInt( at line(s) ${offenders.join(", ")} — either route the value through @/lib/decimal or add an inline "no-float-ok: <reason>" marker`).toEqual([]);
  });

  it("regression guard for the scanner itself: a synthetic unmarked Number( call is caught (proves this scan isn't accidentally vacuous)", () => {
    const synthetic = `
      function renderBar(v) {
        const n = Number(v);
        return n > 0 ? "up" : "down";
      }
    `;
    const stripped = stripComments(synthetic);
    expect(/\bNumber\s*\(/.test(stripped)).toBe(true);
  });
});

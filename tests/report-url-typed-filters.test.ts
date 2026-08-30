import { describe, expect, it } from "vitest";
import { buildReportHref, typedStringFilter, typedBooleanFilter, typedIntFilter } from "@/features/reports/url";

// Phase 8 Patch 8.1 §39-42 — Typed Filter Parser regression tests.
//
// Before this, every report page hand-rolled `const str = (k) => typeof
// sp[k] === "string" ? sp[k] : ""` and relied on `str(k) || undefined` for
// every filter, string- or boolean-typed alike. That works for text, but a
// genuinely boolean-typed RPC parameter (Settlements' `has_variance`,
// Shipping's `is_cod`, §41/§9) needs the raw "true"/"false" string turned
// into a REAL boolean — never a bare `Boolean("false")`, which incorrectly
// evaluates to `true` for any non-empty string. These pure functions are
// the one place that conversion happens, shared by every report page and
// the export route (`api/reports/export/route.ts`) alike.
describe("features/reports/url.ts — typed filter parser", () => {
  describe("typedStringFilter", () => {
    it("passes a non-empty string through unchanged", () => {
      expect(typedStringFilter("abc")).toBe("abc");
    });

    it("returns undefined for an empty string, undefined, or an empty array", () => {
      expect(typedStringFilter("")).toBeUndefined();
      expect(typedStringFilter(undefined)).toBeUndefined();
      expect(typedStringFilter([])).toBeUndefined();
    });

    it("takes the first element of a multi-valued query param, never silently stringifying the whole array", () => {
      expect(typedStringFilter(["first", "second"])).toBe("first");
    });
  });

  describe("typedBooleanFilter", () => {
    it('parses the exact string "true" as boolean true', () => {
      expect(typedBooleanFilter("true")).toBe(true);
    });

    it('parses the exact string "false" as boolean false — NEVER coerced to true by a bare Boolean("false")', () => {
      expect(typedBooleanFilter("false")).toBe(false);
    });

    it("returns undefined (filter not applied) for absent/empty input", () => {
      expect(typedBooleanFilter(undefined)).toBeUndefined();
      expect(typedBooleanFilter("")).toBeUndefined();
    });

    it("returns undefined — never throws, never guesses — for any unrecognized/tampered value", () => {
      expect(typedBooleanFilter("1")).toBeUndefined();
      expect(typedBooleanFilter("yes")).toBeUndefined();
      expect(typedBooleanFilter("TRUE")).toBeUndefined();
      expect(typedBooleanFilter("null")).toBeUndefined();
    });
  });

  describe("typedIntFilter", () => {
    it("parses a plain integer string", () => {
      expect(typedIntFilter("42")).toBe(42);
    });

    it("parses a negative integer string", () => {
      expect(typedIntFilter("-3")).toBe(-3);
    });

    it("returns undefined for a fractional value — never silently truncated", () => {
      expect(typedIntFilter("3.5")).toBeUndefined();
    });

    it("returns undefined for non-numeric garbage", () => {
      expect(typedIntFilter("abc")).toBeUndefined();
      expect(typedIntFilter("1e3")).toBeUndefined();
    });

    it("returns undefined for absent input", () => {
      expect(typedIntFilter(undefined)).toBeUndefined();
    });

    it("enforces an inclusive `min` bound (e.g. a page number must be ≥ 1)", () => {
      expect(typedIntFilter("0", { min: 1 })).toBeUndefined();
      expect(typedIntFilter("1", { min: 1 })).toBe(1);
    });
  });
});

// buildReportHref regression guard — a boolean `false` filter value must
// still be serialized into the pagination href (it is a meaningful,
// deliberately-chosen filter value, not an absent one) even though `false`
// is falsy in JS. This was already correct before Patch 8.1 (the function
// only special-cases `undefined`/`null`/`""`), but is now load-bearing for
// real boolean filters (`has_variance=false`, `is_cod=false`) for the first
// time, so it is worth pinning explicitly.
describe("features/reports/url.ts — buildReportHref (boolean filter serialization)", () => {
  it("serializes a `false` boolean filter value into the URL rather than dropping it", () => {
    const href = buildReportHref("/reports/settlements", { has_variance: false }, undefined, 1);
    expect(href).toContain("has_variance=false");
  });

  it("still drops undefined/null/empty-string filter values as before", () => {
    const href = buildReportHref("/reports/settlements", { has_variance: undefined, status: null, search: "" }, undefined, 1);
    expect(href).not.toContain("has_variance");
    expect(href).not.toContain("status");
    expect(href).not.toContain("search");
  });
});

import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import {
  createSettlementRouteFeeVersionSchema,
  finalizeSettlementBatchSchema,
  recordSettlementBankMovementSchema,
} from "@/features/settlements/schema";

// Phase 7 Integrity Patch 7.1 §33 — regression guard for the file's own
// documented invariant (schema.ts's header comment): "Every financial input
// here stays a STRING all the way to the RPC call — never parsed through
// Number()/parseFloat() at any point in this file or in actions.ts". This
// is inherently a static-shape concern, so it is checked two ways:
//
//   1. RUNTIME — parse representative valid input through every money/
//      percentage-bearing schema and assert the parsed value stays a
//      string, byte-for-byte, never rounded/coerced to a JS number. This
//      catches the real regression (someone adding `.transform(Number)`
//      or similar to a money field) even if the exact source pattern used
//      to do it isn't one of the ones grepped for below.
//   2. STATIC — scan schema.ts's own source text for the specific known-bad
//      patterns the governing spec calls out (parseFloat/parseInt anywhere,
//      or Number( used inside a `.transform(` callback rather than only
//      inside `.refine(` validation callbacks, where it never touches the
//      value that is actually returned).

describe("settlements/schema.ts — money/percentage fields stay strings end-to-end (regression guard)", () => {
  it("createSettlementRouteFeeVersionSchema keeps percentage_fee/fixed_fee/batch_fee_fixed as strings, unrounded, exactly as submitted", () => {
    const parsed = createSettlementRouteFeeVersionSchema.parse({
      settlement_route_id: "11111111-1111-1111-1111-111111111111",
      route_kind: "payment_collection",
      effective_from: "2026-08-20",
      transaction_fee_strategy: "route_formula",
      transaction_fee_model: "percentage_plus_fixed",
      percentage_fee: "2.500",
      fixed_fee: "3.1234",
      batch_fee_fixed: "10.10",
    });

    expect(typeof parsed.percentage_fee).toBe("string");
    expect(parsed.percentage_fee).toBe("2.500"); // never rounded to 2.5 by a Number() round-trip
    expect(typeof parsed.fixed_fee).toBe("string");
    expect(parsed.fixed_fee).toBe("3.1234"); // 4dp preserved — a Number() round-trip cannot silently drop precision here
    expect(typeof parsed.batch_fee_fixed).toBe("string");
    expect(parsed.batch_fee_fixed).toBe("10.10");
  });

  it("finalizeSettlementBatchSchema keeps batch_fee_override as a string", () => {
    const parsed = finalizeSettlementBatchSchema.parse({
      id: "11111111-1111-1111-1111-111111111111",
      row_version: 1,
      selected_sources: [{ source_kind: "sale", source_event_id: "22222222-2222-2222-2222-222222222222" }],
      batch_fee_override: "15.50",
      override_reason: "تجاوز يدوي",
    });

    expect(typeof parsed.batch_fee_override).toBe("string");
    expect(parsed.batch_fee_override).toBe("15.50");
  });

  it("recordSettlementBankMovementSchema keeps a signed amount as a string, sign and precision intact", () => {
    const parsed = recordSettlementBankMovementSchema.parse({
      settlement_batch_id: "11111111-1111-1111-1111-111111111111",
      movement_business_date: "2026-08-20",
      amount: "-250.75",
    });

    expect(typeof parsed.amount).toBe("string");
    expect(parsed.amount).toBe("-250.75");
  });

  // schema.ts's own header comment documents the invariant using the exact
  // words "Number()"/"parseFloat()" as prose — so both static checks below
  // strip `//` line comments first and scan only actual code, never the
  // documentation describing the rule.
  function codeOnly(source: string): string {
    return source
      .split("\n")
      .map((line) => line.replace(/\/\/.*$/, ""))
      .join("\n");
  }

  it("STATIC: schema.ts CODE (comments stripped) contains no parseFloat(/parseInt( call anywhere (never a legitimate use here)", () => {
    const source = codeOnly(readFileSync(path.join(process.cwd(), "src/features/settlements/schema.ts"), "utf-8"));
    expect(source).not.toMatch(/parseFloat\(/);
    expect(source).not.toMatch(/parseInt\(/);
  });

  it("STATIC: no `.transform(...)` callback in schema.ts coerces its value through Number(...) (Number( is only ever used inside `.refine(` validation, which never changes the returned value)", () => {
    const source = codeOnly(readFileSync(path.join(process.cwd(), "src/features/settlements/schema.ts"), "utf-8"));
    // A `.transform((v) => ... Number(...) ...)` — the specific shape that
    // would silently turn a money/percentage string into a JS number on its
    // way out of the schema. `.refine((v) => ... Number(v) ...)` is fine
    // (and expected — used for the >0 / <=100 bound checks) since refine
    // never changes what the schema actually returns.
    const badTransformNumberCoercion = /\.transform\(\s*\([^)]*\)\s*=>\s*[^,;]*\bNumber\(/;
    expect(source).not.toMatch(badTransformNumberCoercion);
  });
});

// ---------------------------------------------------------------------------
// Hotfix 7.1.1 §13 — the governing spec explicitly tightened this file's own
// guard: "لا تعمل Exception لـrefine" (no exception even inside `.refine()`).
// The TWO static checks above only ever scanned schema.ts, and the second
// one's own bad-pattern regex is scoped to `.transform(` specifically —
// exactly the shape of blind spot §13 closed (schema.ts previously had TWO
// Number(v) calls that lived safely inside `.refine(` callbacks, invisible
// to that regex). This describe block replaces that narrower coverage with
// an unconditional, whole-directory scan: every .ts/.tsx file under
// src/features/settlements/ (schema.ts, actions.ts, and every components/
// *.tsx file — anywhere a `.refine()`/`.superRefine()` body or any other
// financial-input-handling code could reintroduce Number(/parseFloat(/
// parseInt(), including inside a refine callback) must contain ZERO matches
// of any of the three, comments/JSDoc stripped first (never applied to
// string literals containing the words as prose, since none exist here —
// confirmed by grep across the directory when this test was written).
// ---------------------------------------------------------------------------
describe("src/features/settlements/**/*.{ts,tsx} — Hotfix 7.1.1 §13 whole-directory scan, refine-body-INCLUSIVE (no carve-out for .refine()/.superRefine() callbacks)", () => {
  const SETTLEMENTS_DIR = path.join(process.cwd(), "src/features/settlements");

  /**
   * Strips BOTH block comments (`/* ... *‍/`, including JSDoc headers — e.g.
   * actions.ts's own "... never Number() (§13)." JSDoc line, which a
   * `//`-only stripper would miss and misreport as a live violation) and
   * `//` line comments, so only genuine code is scanned below.
   */
  function stripComments(source: string): string {
    const withoutBlockComments = source.replace(/\/\*[\s\S]*?\*\//g, "");
    return withoutBlockComments
      .split("\n")
      .map((line) => line.replace(/\/\/.*$/, ""))
      .join("\n");
  }

  function collectSourceFiles(dir: string): string[] {
    const files: string[] = [];
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        files.push(...collectSourceFiles(full));
      } else if (/\.(ts|tsx)$/.test(entry.name)) {
        files.push(full);
      }
    }
    return files;
  }

  const files = collectSourceFiles(SETTLEMENTS_DIR);

  it("the scan itself is not accidentally empty — it found schema.ts, actions.ts, queries.ts, and the components/ directory", () => {
    expect(files.length).toBeGreaterThanOrEqual(10);
    expect(files.some((f) => f.endsWith(`${path.sep}schema.ts`))).toBe(true);
    expect(files.some((f) => f.endsWith(`${path.sep}actions.ts`))).toBe(true);
    expect(files.some((f) => f.endsWith(`${path.sep}queries.ts`))).toBe(true);
    expect(files.some((f) => f.includes(`${path.sep}components${path.sep}`))).toBe(true);
  });

  it.each(collectSourceFiles(SETTLEMENTS_DIR).map((f) => [path.relative(SETTLEMENTS_DIR, f), f] as const))(
    "%s: zero Number(/parseFloat(/parseInt( calls anywhere in the code — including inside a .refine()/.superRefine() callback body",
    (_relativePath, file) => {
      const source = stripComments(readFileSync(file, "utf-8"));
      expect(source).not.toMatch(/\bNumber\s*\(/);
      expect(source).not.toMatch(/\bparseFloat\s*\(/);
      expect(source).not.toMatch(/\bparseInt\s*\(/);
    },
  );

  it("regression guard for the scanner itself: a synthetic Number( call placed INSIDE a .refine() callback body is caught, not exempted (proves this scan is genuinely refine-body-inclusive, unlike the pre-§13 guard)", () => {
    const synthetic = `
      import { z } from "zod";
      export const s = z.string().refine((v) => Number(v) > 0, "bad");
    `;
    const stripped = stripComments(synthetic);
    expect(stripped).toMatch(/\bNumber\s*\(/);
  });
});

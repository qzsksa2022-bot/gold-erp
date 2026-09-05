import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { recordStoreExpenseSchema } from "@/features/expenses/schema";

// Phase 10 (Store Expenses Core) — regression guard for schema.ts's own
// documented invariant: "every monetary input here stays a STRING all the way
// to the RPC call — never parsed through Number()/parseFloat() at any point
// in this file or in actions.ts", mirroring tests/inventory-money-string-
// invariant.test.ts exactly.
//
//   1. RUNTIME — parse representative valid input through the amount-bearing
//      schema and assert the parsed value stays a string, byte-for-byte,
//      never rounded/coerced to a JS number.
//   2. STATIC — whole-directory scan of src/features/expenses/**/*.{ts,tsx}
//      (schema.ts, actions.ts, queries.ts, and every components/*.tsx file,
//      REFINE-BODY-INCLUSIVE) for Number(/parseFloat(/parseInt(, comments
//      stripped first.

describe("expenses/schema.ts — monetary fields stay strings end-to-end (regression guard)", () => {
  it("recordStoreExpenseSchema keeps amount as a string, unrounded, exactly as submitted", () => {
    const parsed = recordStoreExpenseSchema.parse({
      store_id: "11111111-1111-1111-1111-111111111111",
      expense_category_id: "22222222-2222-2222-2222-222222222222",
      amount: "1500.50",
      business_date: "2026-09-05",
    });

    expect(typeof parsed.amount).toBe("string");
    expect(parsed.amount).toBe("1500.50");
  });

  it("preserves a trailing zero — a Number() round-trip would silently drop it", () => {
    const parsed = recordStoreExpenseSchema.parse({
      store_id: "11111111-1111-1111-1111-111111111111",
      expense_category_id: "22222222-2222-2222-2222-222222222222",
      amount: "1500.00",
      business_date: "2026-09-05",
    });

    expect(parsed.amount).toBe("1500.00");
  });

  it("preserves a large amount exactly, beyond what a float round-trip guarantees", () => {
    const parsed = recordStoreExpenseSchema.parse({
      store_id: "11111111-1111-1111-1111-111111111111",
      expense_category_id: "22222222-2222-2222-2222-222222222222",
      amount: "99999999999.99",
      business_date: "2026-09-05",
    });

    expect(parsed.amount).toBe("99999999999.99");
  });

  it("rejects a zero amount", () => {
    expect(() =>
      recordStoreExpenseSchema.parse({
        store_id: "11111111-1111-1111-1111-111111111111",
        expense_category_id: "22222222-2222-2222-2222-222222222222",
        amount: "0",
        business_date: "2026-09-05",
      }),
    ).toThrow();
  });

  it("rejects a negative amount — a reversal is a separate, dated RPC, never a negative input here", () => {
    expect(() =>
      recordStoreExpenseSchema.parse({
        store_id: "11111111-1111-1111-1111-111111111111",
        expense_category_id: "22222222-2222-2222-2222-222222222222",
        amount: "-1",
        business_date: "2026-09-05",
      }),
    ).toThrow();
  });

  it("rejects more than 2 decimal places (store_expenses.amount is numeric(14,2))", () => {
    expect(() =>
      recordStoreExpenseSchema.parse({
        store_id: "11111111-1111-1111-1111-111111111111",
        expense_category_id: "22222222-2222-2222-2222-222222222222",
        amount: "10.123",
        business_date: "2026-09-05",
      }),
    ).toThrow();
  });
});

describe("src/features/expenses/**/*.{ts,tsx} — whole-directory scan, refine-body-INCLUSIVE (no carve-out for .refine()/.superRefine() callbacks)", () => {
  const EXPENSES_DIR = path.join(process.cwd(), "src/features/expenses");

  function stripComments(source: string): string {
    // CRLF is normalized away FIRST: `.` in a JS regex matches any character
    // except a line terminator, and `\r` is one, so on a CRLF checkout
    // `/\/\/.*$/` would never match and no `//` comment would be stripped —
    // the scan would then fail on comments that merely MENTION Number().
    // (Same fix as tests/inventory-money-string-invariant.test.ts.)
    const withoutBlockComments = source.replace(/\r\n/g, "\n").replace(/\/\*[\s\S]*?\*\//g, "");
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

  const files = collectSourceFiles(EXPENSES_DIR);

  it("the scan itself is not accidentally empty — it found schema.ts, actions.ts, queries.ts, and the components/ directory", () => {
    expect(files.length).toBeGreaterThanOrEqual(5);
    expect(files.some((f) => f.endsWith(`${path.sep}schema.ts`))).toBe(true);
    expect(files.some((f) => f.endsWith(`${path.sep}actions.ts`))).toBe(true);
    expect(files.some((f) => f.endsWith(`${path.sep}queries.ts`))).toBe(true);
    expect(files.some((f) => f.includes(`${path.sep}components${path.sep}`))).toBe(true);
  });

  it.each(collectSourceFiles(EXPENSES_DIR).map((f) => [path.relative(EXPENSES_DIR, f), f] as const))(
    "%s: zero Number(/parseFloat(/parseInt( calls anywhere in the code — including inside a .refine()/.superRefine() callback body",
    (_relativePath, file) => {
      const source = stripComments(readFileSync(file, "utf-8"));
      expect(source).not.toMatch(/\bNumber\s*\(/);
      expect(source).not.toMatch(/\bparseFloat\s*\(/);
      expect(source).not.toMatch(/\bparseInt\s*\(/);
    },
  );
});

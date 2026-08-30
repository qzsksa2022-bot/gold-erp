import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { receiveInventoryStockSchema, adjustInventoryStockSchema } from "@/features/inventory/schema";

// Phase 9 (Inventory Core) — regression guard for schema.ts's own documented
// invariant: "every quantity input here stays a STRING all the way to the
// RPC call — never parsed through Number()/parseFloat() at any point in
// this file or in actions.ts", mirroring tests/settlements-money-string-
// invariant.test.ts / tests/adjustments-*-invariant guards exactly.
//
//   1. RUNTIME — parse representative valid input through every quantity-
//      bearing schema and assert the parsed value stays a string,
//      byte-for-byte, never rounded/coerced to a JS number.
//   2. STATIC — whole-directory scan of src/features/inventory/**/*.{ts,tsx}
//      (schema.ts, actions.ts, queries.ts, and every components/*.tsx file,
//      REFINE-BODY-INCLUSIVE) for Number(/parseFloat(/parseInt(, comments
//      stripped first.

describe("inventory/schema.ts — quantity fields stay strings end-to-end (regression guard)", () => {
  it("receiveInventoryStockSchema keeps quantity as a string, unrounded, exactly as submitted", () => {
    const parsed = receiveInventoryStockSchema.parse({
      item_id: "11111111-1111-1111-1111-111111111111",
      store_id: "22222222-2222-2222-2222-222222222222",
      quantity: "12.500",
      business_date: "2026-08-20",
    });

    expect(typeof parsed.quantity).toBe("string");
    expect(parsed.quantity).toBe("12.500"); // trailing zero preserved — a Number() round-trip would silently drop it
  });

  it("adjustInventoryStockSchema keeps a signed quantity_delta as a string, sign and precision intact", () => {
    const parsed = adjustInventoryStockSchema.parse({
      item_id: "11111111-1111-1111-1111-111111111111",
      store_id: "22222222-2222-2222-2222-222222222222",
      quantity_delta: "-2.375",
      reason: "جرد فعلي",
      business_date: "2026-08-20",
    });

    expect(typeof parsed.quantity_delta).toBe("string");
    expect(parsed.quantity_delta).toBe("-2.375");
  });

  it("adjustInventoryStockSchema accepts a positive quantity_delta unchanged", () => {
    const parsed = adjustInventoryStockSchema.parse({
      item_id: "11111111-1111-1111-1111-111111111111",
      store_id: "22222222-2222-2222-2222-222222222222",
      quantity_delta: "3.125",
      reason: "جرد فعلي",
      business_date: "2026-08-20",
    });

    expect(typeof parsed.quantity_delta).toBe("string");
    expect(parsed.quantity_delta).toBe("3.125");
  });

  it("adjustInventoryStockSchema rejects a zero quantity_delta", () => {
    expect(() =>
      adjustInventoryStockSchema.parse({
        item_id: "11111111-1111-1111-1111-111111111111",
        store_id: "22222222-2222-2222-2222-222222222222",
        quantity_delta: "0",
        reason: "جرد فعلي",
        business_date: "2026-08-20",
      }),
    ).toThrow();
  });

  it("receiveInventoryStockSchema rejects a negative quantity", () => {
    expect(() =>
      receiveInventoryStockSchema.parse({
        item_id: "11111111-1111-1111-1111-111111111111",
        store_id: "22222222-2222-2222-2222-222222222222",
        quantity: "-1",
        business_date: "2026-08-20",
      }),
    ).toThrow();
  });
});

describe("src/features/inventory/**/*.{ts,tsx} — whole-directory scan, refine-body-INCLUSIVE (no carve-out for .refine()/.superRefine() callbacks)", () => {
  const INVENTORY_DIR = path.join(process.cwd(), "src/features/inventory");

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

  const files = collectSourceFiles(INVENTORY_DIR);

  it("the scan itself is not accidentally empty — it found schema.ts, actions.ts, queries.ts, and the components/ directory", () => {
    expect(files.length).toBeGreaterThanOrEqual(6);
    expect(files.some((f) => f.endsWith(`${path.sep}schema.ts`))).toBe(true);
    expect(files.some((f) => f.endsWith(`${path.sep}actions.ts`))).toBe(true);
    expect(files.some((f) => f.endsWith(`${path.sep}queries.ts`))).toBe(true);
    expect(files.some((f) => f.includes(`${path.sep}components${path.sep}`))).toBe(true);
  });

  it.each(collectSourceFiles(INVENTORY_DIR).map((f) => [path.relative(INVENTORY_DIR, f), f] as const))(
    "%s: zero Number(/parseFloat(/parseInt( calls anywhere in the code — including inside a .refine()/.superRefine() callback body",
    (_relativePath, file) => {
      const source = stripComments(readFileSync(file, "utf-8"));
      expect(source).not.toMatch(/\bNumber\s*\(/);
      expect(source).not.toMatch(/\bparseFloat\s*\(/);
      expect(source).not.toMatch(/\bparseInt\s*\(/);
    },
  );
});

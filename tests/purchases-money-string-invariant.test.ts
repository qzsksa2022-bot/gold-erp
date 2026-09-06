import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import {
  postPurchaseInvoiceSchema,
  recordSupplierPaymentSchema,
  purchaseInvoiceLineSchema,
  sumMoney,
  normalizeMoney,
  isZeroDecimal,
} from "@/features/purchases/schema";

// Phase 11 (Purchases & Suppliers Core) — regression guard for schema.ts's own
// documented invariant: "every monetary input here stays a STRING all the way
// to the RPC call — never parsed through Number()/parseFloat() at any point in
// this file or in actions.ts", mirroring tests/expenses-money-string-
// invariant.test.ts exactly.
//
//   1. RUNTIME — parse representative valid input through the amount-bearing
//      schemas and assert the parsed values stay strings, byte-for-byte.
//   2. EXACTNESS — the client-side total helpers are integer-cent arithmetic,
//      proven on values a float would demonstrably get wrong.
//   3. STATIC — whole-directory scan of src/features/purchases/**/*.{ts,tsx}
//      (schema.ts, actions.ts, queries.ts, and every components/*.tsx file,
//      REFINE-BODY-INCLUSIVE) for Number(/parseFloat(/parseInt(, comments
//      stripped first.

const SUPPLIER_ID = "11111111-1111-1111-1111-111111111111";
const STORE_ID = "22222222-2222-2222-2222-222222222222";
const ITEM_ID = "33333333-3333-3333-3333-333333333333";
const INVOICE_ID = "44444444-4444-4444-4444-444444444444";

function line(overrides: Record<string, string> = {}) {
  return {
    inventory_item_id: ITEM_ID,
    quantity: "10",
    unit_net_cost: "100",
    tax_treatment: "standard",
    tax_rate_percent: "15",
    net_amount: "1000.00",
    vat_amount: "150.00",
    gross_amount: "1150.00",
    ...overrides,
  };
}

describe("purchases/schema.ts — monetary fields stay strings end-to-end (regression guard)", () => {
  it("postPurchaseInvoiceSchema keeps every total and line amount a string, unrounded", () => {
    const parsed = postPurchaseInvoiceSchema.parse({
      supplier_id: SUPPLIER_ID,
      store_id: STORE_ID,
      business_date: "2026-09-05",
      lines: [line()],
      net_total: "1000.00",
      vat_total: "150.00",
      gross_total: "1150.00",
    });

    expect(typeof parsed.gross_total).toBe("string");
    expect(parsed.gross_total).toBe("1150.00");
    expect(typeof parsed.lines[0].gross_amount).toBe("string");
    expect(parsed.lines[0].gross_amount).toBe("1150.00");
  });

  it("preserves a trailing zero — a Number() round-trip would silently drop it", () => {
    const parsed = recordSupplierPaymentSchema.parse({
      invoice_id: INVOICE_ID,
      amount: "1500.00",
      payment_mode: "cash",
      business_date: "2026-09-05",
    });
    expect(parsed.amount).toBe("1500.00");
  });

  it("preserves a large amount exactly, beyond what a float round-trip guarantees", () => {
    const parsed = recordSupplierPaymentSchema.parse({
      invoice_id: INVOICE_ID,
      amount: "99999999999.99",
      payment_mode: "cash",
      business_date: "2026-09-05",
    });
    expect(parsed.amount).toBe("99999999999.99");
  });

  it("rejects a zero, negative or over-scaled payment amount", () => {
    for (const amount of ["0", "-1", "10.123"]) {
      expect(() =>
        recordSupplierPaymentSchema.parse({ invoice_id: INVOICE_ID, amount, payment_mode: "cash", business_date: "2026-09-05" }),
      ).toThrow();
    }
  });

  it("rejects a line whose gross <> net + vat, exactly — one halala of drift is still a rejection", () => {
    expect(() => purchaseInvoiceLineSchema.parse(line({ gross_amount: "1150.01" }))).toThrow();
    expect(() => purchaseInvoiceLineSchema.parse(line({ gross_amount: "1149.99" }))).toThrow();
  });

  it("rejects a non-standard line carrying VAT or a rate, and accepts one carrying neither", () => {
    expect(() => purchaseInvoiceLineSchema.parse(line({ tax_treatment: "exempt", vat_amount: "150.00" }))).toThrow();
    expect(() =>
      purchaseInvoiceLineSchema.parse(line({ tax_treatment: "exempt", vat_amount: "0", tax_rate_percent: "15", gross_amount: "1000.00" })),
    ).toThrow();

    const ok = purchaseInvoiceLineSchema.parse(
      line({ tax_treatment: "out_of_scope", vat_amount: "0", tax_rate_percent: "0", gross_amount: "1000.00" }),
    );
    expect(ok.tax_treatment).toBe("out_of_scope");
  });

  it("rejects a header total that disagrees with the sum of its lines", () => {
    expect(() =>
      postPurchaseInvoiceSchema.parse({
        supplier_id: SUPPLIER_ID,
        store_id: STORE_ID,
        business_date: "2026-09-05",
        lines: [line()],
        net_total: "1000.00",
        vat_total: "150.00",
        gross_total: "1151.00",
      }),
    ).toThrow();
  });

  it("accepts a multi-line invoice whose totals sum exactly", () => {
    const parsed = postPurchaseInvoiceSchema.parse({
      supplier_id: SUPPLIER_ID,
      store_id: STORE_ID,
      business_date: "2026-09-05",
      lines: [line(), line({ net_amount: "0.10", vat_amount: "0.02", gross_amount: "0.12", quantity: "1", unit_net_cost: "0.1" })],
      net_total: "1000.10",
      vat_total: "150.02",
      gross_total: "1150.12",
    });
    expect(parsed.lines).toHaveLength(2);
  });
});

describe("sumMoney / normalizeMoney — exact integer-cent arithmetic, never floating point", () => {
  it("adds values that IEEE-754 addition gets demonstrably wrong", () => {
    // 0.1 + 0.2 === 0.30000000000000004 as a JS float. Here it must be exact.
    expect(sumMoney("0.10", "0.20")).toBe("0.30");
    expect(sumMoney("0.07", "0.01")).toBe("0.08");
    expect(sumMoney("1000.10", "0.20")).toBe("1000.30");
  });

  it("keeps precision on values beyond a float's exact integer range", () => {
    expect(sumMoney("99999999999.99", "0.01")).toBe("100000000000.00");
  });

  it("normalizes to exactly two places without rounding drift", () => {
    expect(normalizeMoney("5")).toBe("5.00");
    expect(normalizeMoney("5.1")).toBe("5.10");
    expect(normalizeMoney("0")).toBe("0.00");
    expect(normalizeMoney("0.5")).toBe("0.50");
  });

  it("never produces a negative zero", () => {
    expect(normalizeMoney("-0")).toBe("0.00");
    expect(normalizeMoney("-0.00")).toBe("0.00");
    expect(sumMoney("5.00", "-5.00")).toBe("0.00");
  });

  it("handles signed sums, which is what a reversal produces", () => {
    expect(sumMoney("1150.00", "-1150.00")).toBe("0.00");
    expect(sumMoney("100.00", "-350.00")).toBe("-250.00");
  });

  it("isZeroDecimal decides textually, covering every spelling of zero", () => {
    for (const v of ["0", "0.0", "0.000", "-0", "-0.00"]) expect(isZeroDecimal(v)).toBe(true);
    for (const v of ["1", "0.01", "15"]) expect(isZeroDecimal(v)).toBe(false);
  });
});

describe("src/features/purchases/**/*.{ts,tsx} — whole-directory scan, refine-body-INCLUSIVE (no carve-out for .refine()/.superRefine() callbacks)", () => {
  const PURCHASES_DIR = path.join(process.cwd(), "src/features/purchases");

  function stripComments(source: string): string {
    // CRLF is normalized away FIRST: `.` in a JS regex matches any character
    // except a line terminator, and `\r` is one, so on a CRLF checkout
    // `/\/\/.*$/` would never match and no `//` comment would be stripped —
    // the scan would then fail on comments that merely MENTION Number().
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

  const files = collectSourceFiles(PURCHASES_DIR);

  it("the scan itself is not accidentally empty — it found schema.ts, actions.ts, queries.ts, and the components/ directory", () => {
    expect(files.length).toBeGreaterThanOrEqual(5);
    expect(files.some((f) => f.endsWith(`${path.sep}schema.ts`))).toBe(true);
    expect(files.some((f) => f.endsWith(`${path.sep}actions.ts`))).toBe(true);
    expect(files.some((f) => f.endsWith(`${path.sep}queries.ts`))).toBe(true);
    expect(files.some((f) => f.includes(`${path.sep}components${path.sep}`))).toBe(true);
  });

  it.each(collectSourceFiles(PURCHASES_DIR).map((f) => [path.relative(PURCHASES_DIR, f), f] as const))(
    "%s: zero Number(/parseFloat(/parseInt( calls anywhere in the code — including inside a .refine()/.superRefine() callback body",
    (_relativePath, file) => {
      const source = stripComments(readFileSync(file, "utf-8"));
      expect(source).not.toMatch(/\bNumber\s*\(/);
      expect(source).not.toMatch(/\bparseFloat\s*\(/);
      expect(source).not.toMatch(/\bparseInt\s*\(/);
    },
  );
});

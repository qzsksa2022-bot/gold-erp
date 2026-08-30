import { describe, expect, it } from "vitest";
import {
  Decimal,
  isNonNegativeDecimal,
  isPositiveDecimal,
  toDecimal,
  toDisplayNumber,
  toFixedString,
  decimalSign,
  decimalAbsFixed,
  decimalRatioToNumber,
  safeExcelNumber,
} from "@/lib/decimal";

// Phase 2 spec §11/§17: "0.1 + 0.2" must not silently degrade to
// floating-point-unsafe arithmetic anywhere business logic touches money.
// These tests exist purely to prove the Decimal wrapper this project
// standardizes on behaves correctly — no Sales/VAT calculation is
// implemented yet (deliberately out of scope for Phase 2).
describe("decimal helper — floating point safety", () => {
  it("plain JS Number is unsafe for 0.1 + 0.2 (documents WHY this module exists)", () => {
    expect(0.1 + 0.2).not.toBe(0.3);
    expect(0.1 + 0.2).toBeCloseTo(0.3); // only "close", never exact
  });

  it("Decimal(0.1).plus(0.2) is exactly 0.3, not a floating-point approximation", () => {
    const result = toDecimal("0.1").plus(toDecimal("0.2"));
    expect(result.toString()).toBe("0.3");
    expect(result.equals(new Decimal("0.3"))).toBe(true);
  });

  it("chained multiplication (price * weight * markup) stays exact through many steps", () => {
    // Mirrors the SHAPE of the future gold-price formula (§11) without
    // implementing sale calculation logic — pure arithmetic-safety proof.
    const pricePerGram = toDecimal("310.55");
    const manufacturingFee = toDecimal("8.25");
    const weight = toDecimal("3.127");
    const vatMultiplier = toDecimal("1.15");

    const cost = pricePerGram.plus(manufacturingFee).times(weight).times(vatMultiplier);

    // (310.55+8.25) * 3.127 * 1.15, cross-checked independently below.
    expect(cost.toFixed(6)).toBe("1146.420740");

    // Cross-check via a second, independent Decimal call chain (different
    // grouping order) — both must land on the exact same value, which
    // would not be guaranteed with plain float arithmetic due to
    // operation-order-dependent rounding error.
    const crossCheck = weight.times(vatMultiplier).times(pricePerGram.plus(manufacturingFee));
    expect(crossCheck.toFixed(6)).toBe(cost.toFixed(6));
  });

  it("toDecimal accepts strings (the shape a finance-safe _safe RPC, migration 0052, returns a NUMERIC value as)", () => {
    expect(toDecimal("1234.5678").toString()).toBe("1234.5678");
  });

  it("toDecimal accepts an existing Decimal instance without re-parsing loss", () => {
    const original = new Decimal("99.999999999999999999");
    expect(toDecimal(original)).toBe(original);
  });

  it("toFixedString rounds half-up at the configured precision, for persistence/display", () => {
    expect(toFixedString("1.005", 2)).toBe("1.01");
    expect(toFixedString("2.5", 0)).toBe("3");
    expect(toFixedString("10")).toBe("10.00");
  });

  it("toDisplayNumber is explicitly for display only and documented as such", () => {
    expect(toDisplayNumber("42.5")).toBe(42.5);
  });

  it("isPositiveDecimal / isNonNegativeDecimal validate financial inputs without throwing", () => {
    expect(isPositiveDecimal("10.5")).toBe(true);
    expect(isPositiveDecimal("0")).toBe(false);
    expect(isPositiveDecimal("-1")).toBe(false);
    expect(isPositiveDecimal("not-a-number")).toBe(false);

    expect(isNonNegativeDecimal("0")).toBe(true);
    expect(isNonNegativeDecimal("-0.01")).toBe(false);
    expect(isNonNegativeDecimal("garbage")).toBe(false);
  });

  it("large sums of 0.1 do not drift under Decimal (classic float failure case)", () => {
    let sum = toDecimal(0);
    for (let i = 0; i < 10; i++) {
      sum = sum.plus("0.1");
    }
    expect(sum.toString()).toBe("1");
    // The equivalent float loop is the textbook failure this replaces:
    let floatSum = 0;
    for (let i = 0; i < 10; i++) floatSum += 0.1;
    expect(floatSum).not.toBe(1);
  });
});

// Financial Integrity Patch 2.1, item 7 (corrected and actually closed in
// Patch 2.2 — see DELIVERY_REPORT.md's Patch 2.2 appendix): the PostgREST/
// JSON transport boundary. Postgres's NUMERIC type is arbitrary-precision,
// but PostgREST serializes a raw NUMERIC column to JSON as an UNQUOTED
// number token by default (Postgres itself never loses precision doing this
// — jsonb keeps the original numeric text internally). The loss happens on
// the RECEIVING end: any JSON decoder (JSON.parse, and therefore
// supabase-js's fetch().json() under the hood) turns that unquoted token
// into an IEEE-754 double the instant it is parsed as a number, which
// cannot exactly represent every value a NUMERIC column can hold. A prior
// version of this comment claimed src/types/database.ts declares every
// NUMERIC column as `string` — that was both false and, more importantly,
// not how PostgREST actually behaves; database.ts now correctly types raw
// NUMERIC Row columns as `number` (matching PostgREST/real `supabase gen
// types typescript` reality — see scripts/check-numeric-column-types.ts),
// and the finance-safe `_safe` RPCs added in migration 0052
// (`gold_price_for_karat_on_date_safe()` etc.) are the ONLY thing that
// genuinely returns these values as quoted JSON strings, by casting `::text`
// inside Postgres before PostgREST ever serializes the value. This project's
// columns (NUMERIC(12,4)/(6,3)) never actually reach that many significant
// digits today, but the boundary must be handled correctly regardless —
// these tests prove it with a value that genuinely cannot survive the
// number path, and prove the string path (what the `_safe` RPCs actually
// produce over real PostgREST — proven over real HTTP in
// scripts/run_postgrest_http_test.sh) survives losslessly.
describe("decimal helper — PostgREST/JSON transport boundary (high-precision values)", () => {
  // 25 significant digits — comfortably beyond IEEE-754 double's ~15-17
  // guaranteed significant decimal digits.
  const HIGH_PRECISION_VALUE = "123456789012345678.123456789";

  it("documents the failure mode: parsing a NUMERIC value as a bare JSON number silently loses precision", () => {
    // Simulates exactly what PostgREST's own numeric->JSON serialization
    // produces on the wire: an UNQUOTED number token.
    const wirePayloadAsNumber = `{"price_per_gram":${HIGH_PRECISION_VALUE}}`;
    const decoded = JSON.parse(wirePayloadAsNumber) as { price_per_gram: number };

    // The round-tripped value is no longer equal to the original string —
    // this is the silent corruption this whole patch item exists to avoid.
    expect(String(decoded.price_per_gram)).not.toBe(HIGH_PRECISION_VALUE);
    expect(typeof decoded.price_per_gram).toBe("number");
  });

  it("the string transport the finance-safe _safe RPCs use survives the exact same value losslessly, end to end into Decimal", () => {
    // What a real PostgREST response for gold_price_for_karat_on_date_safe()
    // (migration 0052) actually looks like once the value is cast ::text
    // inside Postgres before serialization — the fix this patch enforces.
    // Proven for real over HTTP/PostgREST in
    // scripts/run_postgrest_http_test.sh, not just simulated here.
    const wirePayloadAsString = JSON.stringify({ price_per_gram: HIGH_PRECISION_VALUE });
    const decoded = JSON.parse(wirePayloadAsString) as { price_per_gram: string };

    // JSON.parse never touches a quoted string's contents — lossless by
    // construction up to this point.
    expect(decoded.price_per_gram).toBe(HIGH_PRECISION_VALUE);
    expect(typeof decoded.price_per_gram).toBe("string");

    // The critical last step: converting straight to Decimal (never via
    // Number()) preserves it exactly all the way into the value the app
    // actually computes/displays with.
    const asDecimal = toDecimal(decoded.price_per_gram);
    expect(asDecimal.toString()).toBe(HIGH_PRECISION_VALUE);

    // And explicitly: going through Number() at any point, even from the
    // correctly-transported string, reintroduces exactly the same loss —
    // proving the fix is "never call Number() on a financial value", not
    // just "make the transport a string".
    expect(String(Number(decoded.price_per_gram))).not.toBe(HIGH_PRECISION_VALUE);
  });
});

// Phase 8 Patch 8.1 §18-21 — the Reports/Dashboard financial-arithmetic
// helpers (decimalSign/decimalAbsFixed/decimalRatioToNumber/safeExcelNumber)
// built to replace the bare `Number(raw)`-then-compare/divide/Math.abs
// pattern that had crept into TrendChart/KpiSection/NetOperatingReturnCard/
// pdf.ts/excel.ts's percentage rendering (see report-registry.ts sibling
// tests for the export-level proof; these are the underlying primitives).
describe("Patch 8.1 §18-21 — Reports/Dashboard financial-arithmetic helpers", () => {
  describe("decimalSign", () => {
    it("returns 1 for a positive value, -1 for negative, 0 for zero — and 0 for null", () => {
      expect(decimalSign("12.34")).toBe(1);
      expect(decimalSign("-0.01")).toBe(-1);
      expect(decimalSign("0")).toBe(0);
      expect(decimalSign("0.00")).toBe(0);
      expect(decimalSign(null as unknown as string)).toBe(0);
    });

    it("never rounds a high-precision value to 0 the way `Number(raw) === 0` risks for a subnormal-looking string", () => {
      // Not actually reachable by IEEE-754 subnormal issues at this scale,
      // but proves the sign is read from the Decimal, not a coerced double.
      expect(decimalSign("0.000000000000000000000000001")).toBe(1);
    });
  });

  describe("decimalAbsFixed", () => {
    it("formats the absolute value to the requested decimal places as a STRING, never touching a JS double", () => {
      expect(decimalAbsFixed("-12.345", 1)).toBe("12.3"); // ROUND_HALF_UP per this module's config
      expect(decimalAbsFixed("7.5", 1)).toBe("7.5");
      expect(decimalAbsFixed("0", 1)).toBe("0.0");
    });
  });

  describe("decimalRatioToNumber", () => {
    it("computes |numerator|/denominator via Decimal, converting to Number only at the final step", () => {
      expect(decimalRatioToNumber("50", "100")).toBeCloseTo(0.5);
      expect(decimalRatioToNumber("-75", "100")).toBeCloseTo(0.75); // abs()'d
    });

    it("returns 0 for a zero denominator instead of Infinity/NaN (a legitimate zero-height chart axis)", () => {
      expect(decimalRatioToNumber("50", "0")).toBe(0);
      expect(Number.isFinite(decimalRatioToNumber("50", "0"))).toBe(true);
    });
  });

  describe("safeExcelNumber — §18 the Excel numeric-cell precision-safety contract", () => {
    it("writes an ordinary money value (well within safe range) as a genuine number", () => {
      const result = safeExcelNumber("1234.56", 2);
      expect(result.safe).toBe(true);
      if (result.safe) expect(result.value).toBe(1234.56);
    });

    it("writes an ordinary weight value (3dp) as a genuine number", () => {
      const result = safeExcelNumber("12.345", 3);
      expect(result.safe).toBe(true);
      if (result.safe) expect(result.value).toBeCloseTo(12.345);
    });

    it("returns { safe: true, value: null } for a null/blank/absent input, never throwing", () => {
      expect(safeExcelNumber(null)).toEqual({ safe: true, value: null });
      expect(safeExcelNumber(undefined)).toEqual({ safe: true, value: null });
      expect(safeExcelNumber("")).toEqual({ safe: true, value: null });
    });

    it("§18 REQUIRED TEST: a 27-significant-digit value falls back to an EXACT text cell, never a silently-rounded number", () => {
      // Mirrors this file's own HIGH_PRECISION_VALUE convention — deliberately
      // far beyond IEEE-754 double precision AND beyond what
      // Number.MAX_SAFE_INTEGER can represent even after 2dp scaling.
      const huge = "123456789012345678901234.56"; // 26 significant digits, 2dp
      const result = safeExcelNumber(huge, 2);
      expect(result.safe).toBe(false);
      if (!result.safe) {
        // The exact original value, never rounded/truncated/converted.
        expect(result.text).toBe(huge);
      }
    });

    it("the safety boundary is exercised exactly at Number.MAX_SAFE_INTEGER (scaled) — one cent below is safe, one cent above falls back to text", () => {
      const scale = 2;
      const maxSafeAtScale = new Decimal(Number.MAX_SAFE_INTEGER).div(new Decimal(10).pow(scale));
      const justSafe = maxSafeAtScale.toFixed(scale);
      const justUnsafe = maxSafeAtScale.plus(1).toFixed(scale);

      const safeResult = safeExcelNumber(justSafe, scale);
      expect(safeResult.safe).toBe(true);

      const unsafeResult = safeExcelNumber(justUnsafe, scale);
      expect(unsafeResult.safe).toBe(false);
      if (!unsafeResult.safe) expect(unsafeResult.text).toBe(justUnsafe);
    });

    it("never loses the sign or precision for a negative value that falls back to text", () => {
      const huge = "-999999999999999999999.999";
      const result = safeExcelNumber(huge, 3);
      expect(result.safe).toBe(false);
      if (!result.safe) expect(result.text).toBe(huge);
    });
  });
});

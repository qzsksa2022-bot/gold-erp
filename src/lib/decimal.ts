/**
 * Single source of truth for financial arithmetic in this codebase.
 *
 * JavaScript `Number` is IEEE-754 binary floating point — `0.1 + 0.2` does
 * not equal `0.3`. That is unacceptable for money (gold prices, weights,
 * manufacturing fees, payment commissions, VAT — everything Phase 2/3
 * touches). Every calculation MUST go through Decimal from here on;
 * `Number` is for DISPLAY/formatting only (e.g. feeding a `<input
 * type="number">`'s value), never as an intermediate step in a financial
 * computation.
 *
 * decimal.js is configured once, here, so every call site in the app
 * shares the same precision/rounding behavior — never `import Decimal from
 * "decimal.js"` directly elsewhere; import { Decimal, toDecimal, ... } from
 * "@/lib/decimal" instead.
 */
import Decimal from "decimal.js";

// 34 significant digits (matches IEEE 754 decimal128) is far beyond what
// any value in this system needs (prices/weights/fees are at most a
// handful of decimal places) — generous headroom so chained multiplication
// (price * weight * (1 + vat) * ...) never loses precision to rounding
// before the final, deliberate rounding step at display/persistence time.
Decimal.set({ precision: 34, rounding: Decimal.ROUND_HALF_UP });

export { Decimal };

/** A value that can be losslessly turned into a Decimal. */
export type Decimalish = string | number | Decimal;

/**
 * Converts a value to a Decimal. Prefer passing a `string` — but be aware of
 * WHERE that string must come from: a Postgres NUMERIC column read raw via
 * `supabase.from(...).select(...)` does NOT reliably arrive as a string.
 * PostgREST serializes `numeric` as an UNQUOTED JSON number by default, and
 * real `supabase gen types typescript` output types those columns `number`,
 * not `string` (a prior version of this comment claimed the opposite — that
 * was wrong; see DELIVERY_REPORT.md's Financial Integrity Patch 2.2 appendix
 * for the corrected explanation and the real HTTP/PostgREST proof). The
 * decode from that unquoted JSON number token into a JS double is exactly
 * where precision can silently be lost for a high-precision value — by the
 * time you have a `string` from a raw numeric read, it may already have come
 * from `String(someNumber)`, which is too late.
 *
 * The only genuinely safe string source is a dedicated finance-safe RPC that
 * casts the value `::text` INSIDE Postgres before PostgREST ever serializes
 * it (see migration 0052 — `gold_price_for_karat_on_date_safe()`,
 * `manufacturing_fee_for_karat_on_date_safe()`,
 * `payment_fee_for_method_on_date_safe()`). Any code that will feed a
 * database-sourced financial value into toDecimal() MUST read it through one
 * of those `_safe` RPCs, never via a raw `.select()` on a NUMERIC column.
 *
 * Passing a `number` is supported for literals/tests but should never
 * originate from a prior float computation, and should never originate from
 * a raw (non-`_safe`) read of a NUMERIC column either — by the time a value
 * is a JS number, precision may already be lost.
 */
export function toDecimal(value: Decimalish): Decimal {
  return value instanceof Decimal ? value : new Decimal(value);
}

/**
 * Rounds to `dp` decimal places (default 2, i.e. currency subunits) using
 * this module's configured rounding mode, and returns a plain string —
 * the safe representation for persisting back to a NUMERIC column or
 * displaying to the user. Never call `.toNumber()` on a financial result
 * for anything other than transient display formatting.
 */
export function toFixedString(value: Decimalish, dp = 2): string {
  return toDecimal(value).toFixed(dp);
}

/**
 * Converts a Decimal to a plain JS number for DISPLAY ONLY (e.g. handing a
 * value to an `<input type="number">` or a chart library). Never feed the
 * result back into another financial calculation — re-derive from the
 * original Decimal/string instead.
 */
export function toDisplayNumber(value: Decimalish): number {
  return toDecimal(value).toNumber();
}

/** True if `value` parses as a valid, positive Decimal (e.g. a price). */
export function isPositiveDecimal(value: Decimalish): boolean {
  try {
    return toDecimal(value).gt(0);
  } catch {
    return false;
  }
}

/** True if `value` parses as a valid, non-negative Decimal (e.g. a fee). */
export function isNonNegativeDecimal(value: Decimalish): boolean {
  try {
    return toDecimal(value).gte(0);
  } catch {
    return false;
  }
}

/**
 * Patch 3.2 item 4 — true if `value` parses as a valid Decimal with at most
 * `maxDp` digits after the decimal point. Mirrors (as a UX-only pre-check)
 * the DB's validate_sales_item_precision() (migration 0074), which is the
 * actual source of truth and REJECTS over-precision input outright rather
 * than silently rounding it — this client-side check exists only so the
 * user sees the same rejection immediately, before a round trip.
 */
export function hasMaxDecimalPlaces(value: Decimalish, maxDp: number): boolean {
  try {
    const dp = toDecimal(value).decimalPlaces();
    return dp <= maxDp;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Phase 8 Patch 8.1 §18-21 — Reports/Dashboard financial-arithmetic helpers.
//
// The "No JS Float" contract (already enforced in queries.ts/dashboard
// queries.ts by tests/reports-dashboard-money-string-invariant.test.ts) was
// never explicit about ARITHMETIC done downstream of those wrappers —
// TrendChart/KpiSection/NetOperatingReturnCard and the PDF/Excel percentage
// renderers were each doing their own ad hoc `Number(raw)` immediately
// followed by comparison/division/Math.abs/Math.max, i.e. using the
// IEEE-754 double as an INTERMEDIATE step, not just a final render value.
// The three helpers below make the correct pattern (compute via Decimal,
// convert to a primitive Number only once, at the literal last step before
// an SVG/CSS/Excel-cell boundary) the path of least resistance, so no call
// site needs to reach for a bare `Number(...)` to do real math again.
// ---------------------------------------------------------------------------

/**
 * -1 / 0 / 1 for a financial value's sign, computed via Decimal — replaces
 * the `Number(raw) > 0` / `=== 0` comparison pattern (§19) that was
 * scattered across KpiSection/NetOperatingReturnCard/pdf.ts's percentage
 * rendering. Returns 0 (treated as non-negative) if `raw` is absent/blank
 * — callers already only invoke this after confirming the key is present
 * (§79 key-absence is checked separately, upstream).
 */
export function decimalSign(value: Decimalish): -1 | 0 | 1 {
  if (value === null || value === undefined || value === "") return 0;
  const d = toDecimal(value);
  if (d.isZero()) return 0;
  return d.isNegative() ? -1 : 1;
}

/**
 * Absolute value, rounded to `dp` decimal places, returned as a STRING —
 * replaces `Math.abs(Number(raw)).toFixed(dp)` (§19). decimal.js's own
 * `.toFixed()` never routes through a JS double at all, so this is safer
 * than even "convert once, then .toFixed()" — there is no float step
 * whatsoever, from the original string to the final display string.
 */
export function decimalAbsFixed(value: Decimalish, dp = 1): string {
  return toDecimal(value).abs().toFixed(dp);
}

/**
 * Computes `|numerator| / denominator` via Decimal and converts to a
 * primitive Number ONLY at the very end — the one place this is legitimate
 * per the No-JS-Float contract: a chart bar's pixel-height ratio (or any
 * other literal rendering-boundary value: SVG width, CSS length) is not
 * itself a financial figure that could accumulate further error, it is the
 * terminal output. Replaces `Math.abs(Number(raw)) / maxAbs` (§19,
 * TrendChart). Returns 0 if `denominator` is 0 (avoids Infinity/NaN in the
 * rendered output) rather than throwing — a chart with a zero-height axis
 * is a legitimate, harmless render state.
 */
export function decimalRatioToNumber(numerator: Decimalish, denominator: Decimalish): number {
  const denom = toDecimal(denominator);
  if (denom.isZero()) return 0;
  return toDecimal(numerator).abs().div(denom).toNumber();
}

/**
 * §18 — the Excel numeric-cell safety contract: a money/weight TEXT value
 * is safe to write as a genuine Excel *number* (enabling native
 * SUM/AVERAGE) only if scaling it to an integer at its own decimal
 * precision (`scale` places — 2 for SAR money, 3 for gram weights in this
 * schema) still fits inside `Number.MAX_SAFE_INTEGER`; IEEE-754 doubles
 * cannot represent every integer beyond that threshold, and this codebase
 * would rather write a value as exact TEXT than risk a silently-wrong
 * total. Every real value in this system (prices/weights/fees) is far
 * below the threshold — this is a defensive proof, not a workaround for an
 * observed bug — but the check must actually run, not be assumed, per the
 * explicit §18 requirement (proven by a dedicated 27-significant-digit
 * test case).
 *
 * Returns `{ safe: true, value }` (write as a numeric cell) or
 * `{ safe: false, text }` (write `text` as a TEXT cell instead — the
 * caller must NEVER fall back to `Number(text)` after this returns
 * `safe: false`, or the whole point of the check is defeated). Returns
 * `{ safe: true, value: null }` for a null/blank/absent input — callers
 * treat that as "write nothing" exactly as the pre-existing `toNumber()`
 * behavior did.
 */
export function safeExcelNumber(raw: unknown, scale = 2): { safe: true; value: number | null } | { safe: false; text: string } {
  if (raw === null || raw === undefined || raw === "") return { safe: true, value: null };
  let d: Decimal;
  try {
    d = new Decimal(String(raw));
  } catch {
    return { safe: true, value: null };
  }
  const scaledAbs = d.abs().mul(new Decimal(10).pow(scale));
  if (scaledAbs.gt(Number.MAX_SAFE_INTEGER)) {
    return { safe: false, text: d.toFixed(scale) };
  }
  return { safe: true, value: d.toNumber() };
}

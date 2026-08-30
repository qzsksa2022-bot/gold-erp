/**
 * Money & measurement standards for this system (established now even
 * though no financial features ship in this phase — see section 12 of the
 * spec). Every future module (Sales, Returns, Settlements, Gold Prices...)
 * MUST follow these rules:
 *
 *  1. Never use a JavaScript `number`/`float` as the source of truth for a
 *     monetary amount, a gold weight in grams, or a percentage that feeds a
 *     financial calculation. Floats cannot represent decimal fractions like
 *     0.1 exactly, and errors compound across many transactions.
 *  2. In Postgres, money and weight columns must be `NUMERIC(precision,
 *     scale)`, never `float4`/`float8`/`real`/`double precision`. Suggested
 *     scales for this domain: NUMERIC(14,2) for SAR amounts, NUMERIC(10,3)
 *     for gram weights (jewelry weights commonly need 3 decimal places),
 *     NUMERIC(6,3) for percentages.
 *  3. In TypeScript, treat any value coming from a NUMERIC column as a
 *     `string` (the pg driver returns numeric as string to avoid silent
 *     precision loss) and do arithmetic with a decimal library (e.g.
 *     decimal.js) — never `parseFloat` it and use `+`/`*` directly.
 *  4. Formatting for display only (safe to use floats/Intl here, since this
 *     is presentation, not computation):
 */
import { APP_DEFAULTS } from "@/lib/constants";

export function formatSAR(amount: number | string): string {
  const value = typeof amount === "string" ? Number(amount) : amount;
  return new Intl.NumberFormat(APP_DEFAULTS.locale, {
    style: "currency",
    currency: APP_DEFAULTS.currency,
    currencyDisplay: "symbol",
    maximumFractionDigits: 2,
  }).format(value);
}

export function formatGrams(grams: number | string): string {
  const value = typeof grams === "string" ? Number(grams) : grams;
  return `${new Intl.NumberFormat(APP_DEFAULTS.locale, { maximumFractionDigits: 3 }).format(value)} جم`;
}

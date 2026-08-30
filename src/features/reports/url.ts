/**
 * Builds a report page's paginated href by re-serializing its own filter
 * object (skipping array-shaped internal fields like `store_ids`, which
 * the URL represents singularly as `store_id`) plus an explicit page
 * number. Shared across every report page's <Pagination buildHref> to
 * avoid repeating this boilerplate 16 times.
 */
export function buildReportHref(basePath: string, filters: Record<string, unknown>, storeId: string | undefined, page: number): string {
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(filters)) {
    if (k === "store_ids" || k === "page") continue;
    if (v !== undefined && v !== null && v !== "") params.set(k, String(v));
  }
  if (storeId) params.set("store_id", storeId);
  params.set("page", String(page));
  return `${basePath}?${params.toString()}`;
}

/**
 * Patch 8.1 §39-42 — Typed Filter Parser.
 *
 * Every report filter arrives, ultimately, as a raw string (or absent) from
 * a URL query param — whether read from a Next.js server page's
 * `searchParams` object or the export route handler's `URLSearchParams`.
 * Before this, every report page hand-rolled its own `const str = (k) =>
 * typeof sp[k] === "string" ? sp[k] : ""` and then relied on `str(k) ||
 * undefined` for optional string filters — which works for plain text, but
 * has no answer for a genuinely boolean-typed RPC parameter (e.g.
 * Settlements' `p_has_variance`, Shipping's `p_is_cod`, §41/§9): passing
 * the raw string "false" straight through as a "truthy non-empty string"
 * would silently apply the WRONG filter (or never apply "false" at all,
 * since `"false" || undefined` keeps the string, and a careless `Boolean("false")`
 * would incorrectly evaluate to `true`). These pure functions are the one
 * place a raw filter string becomes a correctly-typed JS value — or
 * `undefined` when absent/unrecognized (NEVER a thrown error; an
 * unrecognized filter value should silently not filter rather than 500 the
 * page) — reused identically by every report page AND the export route, so
 * screen and export can never type-parse a filter differently (§39 Single
 * Reporting Engine, extended to the filter-parsing layer itself).
 */
export type RawFilterValue = string | string[] | undefined;

function firstString(raw: RawFilterValue): string | undefined {
  const v = Array.isArray(raw) ? raw[0] : raw;
  return typeof v === "string" && v !== "" ? v : undefined;
}

/** Optional free-text/enum-select filter — the plain string, or `undefined` when absent/empty. */
export function typedStringFilter(raw: RawFilterValue): string | undefined {
  return firstString(raw);
}

/** Strictly "true"/"false" only — any other raw value (including garbage query-string tampering) is treated as "filter not applied", never coerced truthy/falsy. */
export function typedBooleanFilter(raw: RawFilterValue): boolean | undefined {
  const v = firstString(raw);
  if (v === "true") return true;
  if (v === "false") return false;
  return undefined;
}

/** Strictly digit-only (optionally signed) integers — a non-numeric or fractional raw value is treated as absent rather than silently truncated. `min` rejects out-of-range values the same way (e.g. page numbers must be ≥ 1). */
export function typedIntFilter(raw: RawFilterValue, opts?: { min?: number }): number | undefined {
  const v = firstString(raw);
  if (v === undefined || !/^-?\d+$/.test(v)) return undefined;
  const n = Number(v); // no-float-ok: strict-integer-regex-checked value (page/count), never money/weight/percent (§21).
  if (opts?.min !== undefined && n < opts.min) return undefined;
  return n;
}

/**
 * Drift check: every raw Postgres NUMERIC/DECIMAL column in the `public`
 * schema must be typed as a plain `number` (never `string`, never
 * "string | number") in the hand-maintained src/types/database.ts Row type
 * -- matching PostgREST's real, actual runtime behavior, not a hoped-for
 * one.
 *
 * IMPORTANT, CORRECTED (Financial Integrity Patch 2.2): an earlier version
 * of this script (and its accompanying comments in src/lib/decimal.ts)
 * asserted the OPPOSITE -- that every NUMERIC column must be typed
 * `string`, on the false premise that supabase-js / `supabase gen types
 * typescript` "always" serializes NUMERIC as a string. That premise was
 * wrong. PostgREST serializes a `numeric` column to JSON as an UNQUOTED
 * number token by DEFAULT, and the real, current postgres-meta/Supabase
 * typegen maps Postgres `numeric` to TypeScript `number`, not `string` --
 * confirmed by reading postgres-meta's actual type-mapping source (it has
 * no special case for `numeric`; it falls through to the generic
 * PostgreSQL-type-name passthrough, which is `number` for every numeric-
 * family OID). A hand-written `string` type on a RAW numeric column does
 * NOT change what PostgREST actually sends on the wire -- it just makes
 * database.ts describe a shape that never occurs, giving false confidence.
 *
 * This script now checks the file for the TRUTH instead: every raw NUMERIC
 * Row column must be `number`. This is deliberately the FULL extent of what
 * this script protects -- it says nothing about whether a given call site is
 * safe to feed into a Decimal financial calculation. It is not. Protecting
 * an actual calculation is a SEPARATE, stronger requirement solved by an
 * entirely different mechanism: the finance-safe `_safe`-suffixed RPCs added
 * in migration 0052 (`gold_price_for_karat_on_date_safe()`,
 * `manufacturing_fee_for_karat_on_date_safe()`,
 * `payment_fee_for_method_on_date_safe()`), which cast the value `::text`
 * INSIDE Postgres before PostgREST ever serializes it -- those genuinely
 * return SQL `text`/JSON strings, and are the only thing this project
 * considers safe to feed into src/lib/decimal.ts's toDecimal() for a real
 * calculation. This script does not (and structurally cannot, from
 * information_schema alone) verify that every call site actually uses the
 * `_safe` variant instead of the raw one -- that is verified by the real
 * HTTP/PostgREST integration test, scripts/run_postgrest_http_test.sh (see
 * DELIVERY_REPORT.md's Patch 2.2 appendix), and remains a code-review
 * discipline point for Sales/Returns/Settlements when that work begins.
 *
 * This is a stand-in for `supabase gen types typescript`'s own drift
 * checking. The official CLI needs a running Docker daemon even in
 * `--db-url` (non-Docker-project) mode as of the version available when
 * this was written (confirmed by hand in this environment -- see
 * DELIVERY_REPORT.md's Patch 2.1 appendix for the exact error), and this
 * sandbox has no usable Docker daemon; re-confirmed unchanged while writing
 * Patch 2.2. The moment Docker / a real Supabase project is available,
 * prefer running the official CLI and diffing its output against
 * src/types/database.ts directly -- this script is the dependency-free
 * fallback that works everywhere psql already works (which this repo's SQL
 * test suites already require), and it now asserts the corrected, real
 * PostgREST behavior instead of the disproven "always string" claim.
 *
 * Usage:
 *   DATABASE_URL=postgres://... npx tsx scripts/check-numeric-column-types.ts
 * Exits non-zero (and prints exactly what's wrong) on any drift -- wire this
 * into CI right after the SQL test suites run against the same database.
 */
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";

const DATABASE_URL = process.env.DATABASE_URL ?? "postgresql://postgres@localhost:5432/gold_erp_test";
const DATABASE_TYPES_PATH = path.join(process.cwd(), "src/types/database.ts");

type NumericColumn = { table: string; column: string };

function fetchNumericColumns(): NumericColumn[] {
  const query = `
    select table_name || '|' || column_name
    from information_schema.columns
    where table_schema = 'public' and data_type = 'numeric'
    order by 1;
  `;
  const output = execFileSync("psql", [DATABASE_URL, "-tAc", query], { encoding: "utf-8" });
  return output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const [table, column] = line.split("|");
      return { table, column };
    });
}

/** Extracts the `Row: { ... }` block text for a given table from database.ts, via brace counting (the file has no nested braces inside a Row block deep enough to confuse this — verified against every Phase 2 table). */
function extractRowBlock(source: string, tableName: string): string | null {
  const tableMarker = `      ${tableName}: {`;
  const tableStart = source.indexOf(tableMarker);
  if (tableStart === -1) return null;

  const rowMarker = "Row: {";
  const rowStart = source.indexOf(rowMarker, tableStart);
  if (rowStart === -1) return null;

  let depth = 1;
  let i = rowStart + rowMarker.length;
  const contentStart = i;
  while (depth > 0 && i < source.length) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}") depth--;
    i++;
  }
  return source.slice(contentStart, i - 1);
}

function extractFieldType(rowBlock: string, column: string): string | null {
  const fieldRegex = new RegExp(`\\b${column}\\??:\\s*([^;\\n]+);`);
  const match = rowBlock.match(fieldRegex);
  return match ? match[1].trim() : null;
}

function main() {
  const columns = fetchNumericColumns();
  if (columns.length === 0) {
    console.log("No NUMERIC/DECIMAL columns found in public schema — nothing to check.");
    return;
  }

  const source = readFileSync(DATABASE_TYPES_PATH, "utf-8");
  const problems: string[] = [];

  for (const { table, column } of columns) {
    const rowBlock = extractRowBlock(source, table);
    if (rowBlock === null) {
      problems.push(`${table}.${column}: could not find a Row type block for table "${table}" in ${DATABASE_TYPES_PATH} — is this table missing from database.ts?`);
      continue;
    }

    const fieldType = extractFieldType(rowBlock, column);
    if (fieldType === null) {
      problems.push(`${table}.${column}: NUMERIC column has no matching field in the Row type — database.ts is out of sync with the real schema.`);
      continue;
    }

    // Must be exactly "number" (optionally "| null") — matching PostgREST's
    // real, default unquoted-JSON-number serialization of a raw `numeric`
    // column. Any "string" token here would (falsely) claim a safety this
    // raw column does not actually have on the wire.
    const typeTokens = fieldType.split("|").map((t) => t.trim());
    const hasBareNumber = typeTokens.includes("number");
    const hasString = typeTokens.includes("string");

    if (!hasBareNumber || hasString) {
      problems.push(
        `${table}.${column}: Row type is "${fieldType}" — a raw NUMERIC column must be typed as a plain number (optionally "| null"), matching what PostgREST actually serializes it as (an unquoted JSON number) and what real \`supabase gen types typescript\` output would produce. A "string" token here falsely claims a transport safety this raw column does not have — if this value needs to enter a financial calculation, add/use a finance-safe "_safe" RPC (see migration 0052) instead of relying on a hand-typed string here. Fix the Row type in ${DATABASE_TYPES_PATH}.`,
      );
    }
  }

  if (problems.length > 0) {
    console.error(`\nNumeric column type drift detected (${problems.length} problem${problems.length === 1 ? "" : "s"}):\n`);
    for (const p of problems) console.error(`  - ${p}`);
    console.error("");
    process.exit(1);
  }

  console.log(`OK: all ${columns.length} raw NUMERIC column(s) in the public schema are correctly typed as number in database.ts (matching real PostgREST behavior).`);
  for (const { table, column } of columns) console.log(`  - ${table}.${column}`);
  console.log(
    "\nReminder: this only checks that raw numeric columns are honestly typed. It does NOT verify financial calculations are safe — that requires reading through a finance-safe \"_safe\" RPC (migration 0052), proven over real HTTP in scripts/run_postgrest_http_test.sh.",
  );
}

main();

#!/usr/bin/env bash
# ==============================================================================
# Patch 6.1 (item 35/37) dedicated upgrade-safety harness.
#
# Unlike scripts/run_upgrade_test_phase6_adjustments.sh (which proves Phase 6
# Core is usable immediately after 0133-0143, starting from an EMPTY
# Adjustments table), this script proves the actual backfill/migration
# safety of Patch 6.1 itself (0144-latest) against a database that ALREADY
# has real Phase-6-Core Adjustments data, created under the OLD (pre-Patch-
# 6.1) RPC/schema contracts — including deliberately reproducing the two
# genuine pre-Patch-6.1 bugs items 9/10 (zero-charge rows carrying a
# non-zero resolved fee) and item 20 (reversal rows missing the 5 signed
# impact columns) so 0144's and 0150's backfills have something real to
# prove themselves against, not merely an empty-table no-op.
#
# Sequence (four SEPARATE psql invocations, exactly like a real production
# upgrade would experience it — no step re-runs seed.sql, and the pre-
# fixture data is COMMITTED, never rolled back):
#   1. Fresh DB + supabase/tests/local_harness_setup.sql (auth schema stub).
#   2. Migrations 0001-0143 only (everything through Phase 6 Core, BEFORE
#      Patch 6.1 exists).
#   3. The real supabase/seed.sql.
#   4. supabase/tests/fixtures/patch_6_1_upgrade_pre_fixture.sql — creates 5
#      real fixture scenarios via the OLD RPCs, COMMITTED (not rolled back),
#      recording their IDs/numbers into a permanent public.p6u61_scratch
#      table so they survive into the next step.
#   5. Migrations 0144-latest on top (the actual Patch 6.1 upgrade).
#   6. supabase/tests/upgrade_patch_6_1_fixtures.test.sql — reads back
#      p6u61_scratch and asserts the backfills/migrations behaved correctly,
#      then drops the scratch table as final cleanup.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_patch_6_1_upgrade_test" \
#     ./scripts/run_upgrade_test_patch_6_1.sh
#
# Requires: a Postgres server reachable at $DATABASE_URL's host, with
# CREATEDB privilege for the connecting role (the script drops/recreates the
# target database each run so it always starts from a clean slate).
# ==============================================================================
set -euo pipefail

DATABASE_URL="${DATABASE_URL:?Set DATABASE_URL to the target test database (it will be dropped and recreated)}"

DB_NAME="${DATABASE_URL##*/}"
ADMIN_URL="${DATABASE_URL%/*}/postgres"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Dropping/recreating $DB_NAME"
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\";"

echo "==> Applying test harness setup (auth schema stub)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/local_harness_setup.sql

echo "==> Applying migrations 0001-0143 only (pre-Patch-6.1 state, i.e. Phase 6 Core already shipped)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 143 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Creating real pre-Patch-6.1 Adjustments fixture data (OLD RPC/schema contracts, COMMITTED)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/patch_6_1_upgrade_pre_fixture.sql

echo "==> Applying migrations 0144-latest on top (the actual upgrade — Patch 6.1)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 144 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_patch_6_1_fixtures.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_patch_6_1_fixtures.test.sql

echo "==> Patch 6.1 upgrade-fixtures test PASSED"

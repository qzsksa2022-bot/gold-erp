#!/usr/bin/env bash
# ==============================================================================
# Phase 7 (Settlements Core) dedicated upgrade-safety harness.
#
# Unlike scripts/run_upgrade_test_phase6_adjustments.sh (which only needed an
# ordinary Sales Order created under the OLD schema, since Phase 6 is a
# wholly new module with no backfill of pre-existing data), this script
# proves the actual REASON Phase 7 exists: the Settlement Source Adapter
# (0176) must be able to discover Sales/Returns/Adjustments data that was
# ALREADY COMMITTED to the database genuinely BEFORE Phase 7 (0167+) ever
# existed — not a synthetic post-upgrade-only fixture. It follows
# scripts/run_upgrade_test_patch_6_1.sh's richer "create fixture data BEFORE
# the upgrade, assert on it AFTER" pattern (three separate psql invocations
# for the fixture/migrations/assertions, plus the two prior ones for harness
# setup and pre-Phase-7 migrations+seed).
#
# Sequence (FIVE separate psql invocations, exactly like a real production
# upgrade would experience it — no step re-runs seed.sql, and the pre-
# fixture data is COMMITTED, never rolled back):
#   1. Fresh DB + supabase/tests/local_harness_setup.sql (auth schema stub).
#   2. Migrations 0001-0166 only (everything through the last shipped state,
#      BEFORE Phase 7 exists — no settlements.* schema/RPC at all yet).
#   3. The real supabase/seed.sql.
#   4. supabase/tests/fixtures/phase7_upgrade_pre_fixture.sql — creates one
#      store + minimal master data, one Sales Order, one full approved Sales
#      Return, and one approved participates_in_settlement Adjustment (+ its
#      reversal) via the OLD (pre-Phase-7) Sales/Returns/Adjustments RPCs,
#      COMMITTED (not rolled back), recording their IDs/numbers/known
#      figures into a permanent public.p7u_scratch table so they survive
#      into the next step.
#   5. Migrations 0167-0183 on top (the actual upgrade — Phase 7).
#   6. supabase/tests/upgrade_phase7_settlements.test.sql — reads back
#      p7u_scratch, creates ONE settlement route + fee version, proves
#      list_unsettled_settlement_sources() discovers the pre-existing
#      pre-Phase-7 data with the exact signed Sign Convention figures,
#      finalizes a batch claiming them, confirms settlement_batch_lines
#      snapshots correctly, confirms every historical id/number is
#      byte-identical post-migration, then drops the scratch table.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_phase7_upgrade_test" \
#     ./scripts/run_upgrade_test_phase7_settlements.sh
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

echo "==> Applying migrations 0001-0166 only (pre-Phase-7 state)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 166 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Creating real pre-Phase-7 Sales/Returns/Adjustments fixture data (OLD RPC/schema contracts, COMMITTED)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/phase7_upgrade_pre_fixture.sql

echo "==> Applying migrations 0167-latest on top (the actual upgrade — Phase 7 Settlements Core)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 167 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_phase7_settlements.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase7_settlements.test.sql

echo "==> Phase 7 upgrade test PASSED"

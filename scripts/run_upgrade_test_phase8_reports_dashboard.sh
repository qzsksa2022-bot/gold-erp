#!/usr/bin/env bash
# ==============================================================================
# Phase 8 (Reports/Dashboard/Exports) dedicated upgrade-safety harness.
# ==============================================================================
# Hotfix 9.1.0: supabase/tests/upgrade_phase8_reports_dashboard.test.sql had
# NO runner script at all — it was the only *.test.sql file in the repository
# that no scripts/*.sh referenced, so it never ran anywhere. This script is
# that missing runner. The CI "SQL test coverage" step now fails the build if
# any upgrade test file is ever left unreferenced like this again.
#
# The baseline is NOT chosen arbitrarily — it is taken from the test file's
# own header, which states it verifies "0199-0204 on top of the FROZEN
# 0001-0198 baseline (§0)". Hence: build to exactly 0198, apply the real
# supabase/seed.sql at that point, then apply 0199-latest on top in a SEPARATE
# psql invocation (seed.sql is NEVER re-run), exactly as a production upgrade
# would experience it.
#
# Unlike scripts/run_upgrade_test_phase8_multidomain.sh (same 198 boundary),
# this script deliberately applies NO pre-fixture. That is the whole point of
# the test it runs: it proves the 21 new report RPCs are safe against a
# database holding ONLY seed.sql's reference data — i.e. one that never ran
# Phase 8's golden-scenario fixture — so they cannot be assuming any
# Phase-8-specific data shape, snapshot column or backfilled value. The test
# file says so explicitly ("No \i of the Phase 8 golden fixture here BY
# DESIGN"), and it creates the one actor it needs itself.
#
# Mirrors scripts/run_upgrade_test_phase9_inventory.sh's structure exactly,
# with the pre/post migration boundary moved to 198/199.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_phase8_reports_upgrade_test" \
#     ./scripts/run_upgrade_test_phase8_reports_dashboard.sh
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

echo "==> Applying migrations 0001-0198 only (pre-Phase-8-reports state)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 198 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Applying migrations 0199-latest on top (the actual upgrade — Phase 8 reports/dashboard)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 199 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_phase8_reports_dashboard.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase8_reports_dashboard.test.sql

echo "==> Phase 8 reports/dashboard upgrade test PASSED"

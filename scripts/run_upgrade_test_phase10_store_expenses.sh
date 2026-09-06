#!/usr/bin/env bash
# ==============================================================================
# Phase 10 (Store Expenses Core) dedicated upgrade-safety harness.
# ==============================================================================
# Builds a database to EXACTLY migration 0232 + the real supabase/seed.sql
# (Phase 10 not yet applied — a real production database at this point has
# already run seed.sql once, long ago), THEN applies migrations 0233-latest on
# top (a SEPARATE psql invocation, exactly like production would experience an
# upgrade — seed.sql is NEVER re-run), and finally runs
# supabase/tests/upgrade_phase10_store_expenses.test.sql (also a separate
# invocation) to prove:
#
#   (A) The 5 new Phase 10 permission keys (expenses.view/create/reverse/
#       manage_categories/process_closed_day) and their role grants come from
#       migration 0233 itself, idempotently — not from seed.sql.
#   (B) The entire new expense engine (category catalog, record/reverse
#       lifecycle, signed append-only ledger, live totals) is immediately
#       usable the moment 0233-0236 finish applying. Store Expenses has no
#       dependency on any pre-existing Sales/Returns/Settlements data, so this
#       script needs no special legacy fixture beyond the real seed.sql.
#   (C) The pre-existing net_operating_return contract survived untouched —
#       the legacy dashboard RPCs were not edited, only wrapped.
#
# The 0232 boundary is the frozen Phase 9 + Hotfix 9.1.0 baseline: the last
# shipped state before Phase 10.
#
# Mirrors scripts/run_upgrade_test_phase9_inventory.sh's structure exactly,
# with the pre/post migration boundary moved to 232/233.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_phase10_upgrade_test" \
#     ./scripts/run_upgrade_test_phase10_store_expenses.sh
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

echo "==> Applying migrations 0001-0232 only (pre-Phase-10 state)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 232 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Applying migrations 0233-latest on top (the actual upgrade — Phase 10)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 233 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_phase10_store_expenses.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase10_store_expenses.test.sql

echo "==> Phase 10 upgrade test PASSED"

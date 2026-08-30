#!/usr/bin/env bash
# ==============================================================================
# Phase 9 (Inventory Core) dedicated upgrade-safety harness.
# ==============================================================================
# Builds a database to EXACTLY migration 0226 + the real supabase/seed.sql
# (Phase 9 not yet applied — a real production database at this point has
# already run seed.sql once, long ago), THEN applies migrations 0227-latest
# on top (a SEPARATE psql invocation, exactly like production would
# experience an upgrade — seed.sql is NEVER re-run), and finally runs
# supabase/tests/upgrade_phase9_inventory.test.sql (also a separate
# invocation) to prove:
#
#   (A) The 3 new Phase 9 permission keys (inventory.view/receive/adjust)
#       and their role grants come from migration 0227 itself, idempotently
#       — not from seed.sql.
#   (B) The entire new Inventory engine (item catalog, receive/adjust
#       lifecycle, balance derived live from the ledger, negative-stock
#       rejection) is immediately usable the moment 0227-0229 finish
#       applying — Inventory Core has no dependency on any pre-existing
#       Sales/Returns/Settlements data (unlike Phase 6/7's upgrade tests,
#       which prove usability against a pre-existing Sales Order), so this
#       script needs no special legacy fixture beyond the real seed.sql.
#
# Mirrors scripts/run_upgrade_test_phase6_adjustments.sh's structure
# exactly, with the pre/post migration boundary moved to 226/227.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_phase9_upgrade_test" \
#     ./scripts/run_upgrade_test_phase9_inventory.sh
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

echo "==> Applying migrations 0001-0226 only (pre-Phase-9 state)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 226 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Applying migrations 0227-latest on top (the actual upgrade — Phase 9)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 227 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_phase9_inventory.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase9_inventory.test.sql

echo "==> Phase 9 upgrade test PASSED"

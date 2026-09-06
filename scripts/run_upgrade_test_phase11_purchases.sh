#!/usr/bin/env bash
# ==============================================================================
# Phase 11 (Purchases & Suppliers Core) dedicated upgrade-safety harness.
# ==============================================================================
# Builds a database to EXACTLY migration 0236 + the real supabase/seed.sql
# (Phase 11 not yet applied — a real production database at this point has
# already run seed.sql once, long ago), THEN applies migrations 0237-latest on
# top (a SEPARATE psql invocation, exactly like production would experience an
# upgrade — seed.sql is NEVER re-run), and finally runs
# supabase/tests/upgrade_phase11_purchases.test.sql (also a separate
# invocation) to prove:
#
#   (A) The 7 new Phase 11 permission keys (purchases.view/create/reverse/
#       record_payment/reverse_payment/manage_suppliers/process_closed_day) and
#       their role grants come from migration 0237 itself, idempotently — not
#       from seed.sql.
#   (B) The whole purchasing engine (supplier catalogue, invoice posting with
#       atomic inventory receipt, partial payments, both reversal paths,
#       statements and outstanding-liability reporting) is immediately usable
#       the moment 0237-0240 finish applying.
#   (C) Decision 5 structurally: the Phase 10 expense schema gained no
#       purchase/supplier column, constraint or foreign key, and neither
#       ledger's RPCs reference the other.
#   (D) Decision 3: net_operating_return and every legacy dashboard RPC
#       survived with no knowledge of purchases.
#   (E) Decision 2: Phase 9's record_inventory_stock_movement() was called, not
#       forked — no purchase RPC writes inventory_stock_movements itself.
#
# The 0236 boundary is the frozen Phase 10 + Hotfix 10.1.0 baseline: the last
# shipped state before Phase 11.
#
# Mirrors scripts/run_upgrade_test_phase10_store_expenses.sh's structure
# exactly, with the pre/post migration boundary moved to 236/237.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_phase11_upgrade_test" \
#     ./scripts/run_upgrade_test_phase11_purchases.sh
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

echo "==> Applying migrations 0001-0236 only (pre-Phase-11 state)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 236 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Applying migrations 0237-latest on top (the actual upgrade — Phase 11)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 237 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_phase11_purchases.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase11_purchases.test.sql

echo "==> Phase 11 upgrade test PASSED"

#!/usr/bin/env bash
# ==============================================================================
# Phase 6 (Services / Adjustments Core) dedicated upgrade-safety harness.
#
# Builds a database to EXACTLY migration 0132 + the real supabase/seed.sql
# (Phase 6 not yet applied — a real production database at this point has
# already run seed.sql once, long ago), creates a real Sales Order using the
# OLD (pre-Phase-6) schema/RPCs, THEN applies migrations 0133-latest on top
# (a SEPARATE psql invocation, exactly like production would experience an
# upgrade — seed.sql is NEVER re-run), and finally runs
# supabase/tests/upgrade_phase6_adjustments.test.sql (also a separate
# invocation) to prove:
#
#   (A) The 4 new Phase 6 permission keys (adjustments.manage_cost/reverse/
#       process_closed_day/manage_types) and their role grants come from
#       migration 0133 itself, idempotently — not from seed.sql.
#   (B) The entire new Adjustments engine (types, create/approve/reverse
#       lifecycle, fee/profit math, Sales-profit independence) is
#       immediately usable against a Sales Order that was created BEFORE
#       Phase 6 existed, with no backfill/migration of sales_orders needed.
#
# This is DELIBERATELY separate from scripts/run_upgrade_test.sh (the
# general Foundation-only upgrade proof) and
# scripts/run_upgrade_test_patch_4_2.sh / run_upgrade_test_hotfix_4_2_1.sh
# (Returns/Refund-Ledger-specific legacy-data backfill proofs) — Phase 6
# introduces no backfill of existing data at all (it is a wholly new,
# additive module), so unlike those two this script needs no special
# pre-Phase-6 fixture beyond the real seed.sql + one ordinary Sales Order.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_phase6_upgrade_test" \
#     ./scripts/run_upgrade_test_phase6_adjustments.sh
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

echo "==> Applying migrations 0001-0132 only (pre-Phase-6 state)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 132 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Applying migrations 0133-latest on top (the actual upgrade — Phase 6)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 133 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_phase6_adjustments.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase6_adjustments.test.sql

echo "==> Phase 6 upgrade test PASSED"

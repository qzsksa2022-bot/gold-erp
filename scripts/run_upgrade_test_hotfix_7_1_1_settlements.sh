#!/usr/bin/env bash
# ==============================================================================
# Phase 7 — Final Integrity Hotfix 7.1.1 (§20 item D) dedicated upgrade-safety
# harness.
#
# Proves item D: "0191->latest over REAL Hotfix-7.1.1-relevant data (fee
# reversal original, reversed return, draft/finalized/reconciled/cancelled
# batches, movements/reversals, claims, cross-store adjustment, route/channel
# config)". Mirrors scripts/run_upgrade_test_phase7_1_settlements.sh's own
# structure exactly, one migration-number boundary later.
#
# Sequence (FIVE separate psql invocations, no step re-runs seed.sql, the
# pre-fixture data is COMMITTED, never rolled back):
#   1. Fresh DB + supabase/tests/local_harness_setup.sql (auth schema stub).
#   2. Migrations 0001-0191 only (the ORIGINAL Patch 7.1 Settlements Core end
#      state, BEFORE Hotfix 7.1.1/0192 exists).
#   3. The real supabase/seed.sql.
#   4. supabase/tests/fixtures/hotfix_7_1_1_upgrade_pre_fixture.sql — builds
#      real Settlement data under the OLD (0169-0191) RPCs, COMMITTED, into
#      the permanent public.h711u_scratch table.
#   5. Migrations 0192-latest on top (the actual upgrade — Hotfix 7.1.1).
#   6. supabase/tests/upgrade_hotfix_7_1_1_settlements.test.sql — asserts
#      byte-identical pre-existing data, confirms the NEW discovery logic
#      never resurrects an already-claimed source, and exercises every NEW
#      hotfix capability against fresh post-upgrade data, then drops the
#      scratch table.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_hotfix711_upgrade_d_test" \
#     ./scripts/run_upgrade_test_hotfix_7_1_1_settlements.sh
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

echo "==> Applying migrations 0001-0191 only (the ORIGINAL Patch 7.1 Settlements Core end state, BEFORE Hotfix 7.1.1 exists)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 191 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Creating real pre-Hotfix-7.1.1 Settlements fixture data (OLD 0169-0191 RPC/schema contracts, COMMITTED) — return finalized under the OLD NULL-channel-only matching rule, cross-store adjustment, draft/reconciled/cancelled batches, bank movement + reversal"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/hotfix_7_1_1_upgrade_pre_fixture.sql

echo "==> Applying migrations 0192-latest on top (the actual upgrade — Phase 7 Final Integrity Hotfix 7.1.1)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 192 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_hotfix_7_1_1_settlements.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_hotfix_7_1_1_settlements.test.sql

echo "==> Hotfix 7.1.1 upgrade test (item D) PASSED"

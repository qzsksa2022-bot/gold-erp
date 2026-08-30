#!/usr/bin/env bash
# ==============================================================================
# Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2 (§11/§15 item E)
# dedicated upgrade-safety harness.
#
# Proves item E: "0196->latest with the new route-drift fixture" — a Sale/
# Return/Approve/Reverse/edit-to-B/B sequence built entirely under the OLD
# (pre-0197) 0001-0196 contracts, committed, THEN upgraded to latest, THEN
# confirmed the backfilled collection_channel_id_snapshot reconstructs the
# TRUE historical channel (A) via audit history — never the Sale's current
# live channel (B) — and that Discovery on the same real data now resolves
# to Route A only. Mirrors scripts/run_upgrade_test_hotfix_7_1_1_settlements.sh's
# own structure exactly, one migration-number boundary later.
#
# Sequence (FIVE separate psql invocations, no step re-runs seed.sql, the
# pre-fixture data is COMMITTED, never rolled back):
#   1. Fresh DB + supabase/tests/local_harness_setup.sql (auth schema stub).
#   2. Migrations 0001-0196 only (the Hotfix 7.1.1 end state, BEFORE Hotfix
#      7.1.2/0197 exists).
#   3. The real supabase/seed.sql.
#   4. supabase/tests/fixtures/hotfix_7_1_2_upgrade_pre_fixture.sql — builds
#      the real route-drift scenario under the OLD (0169-0196) RPC/schema
#      contracts, COMMITTED, into the permanent public.h712u_scratch table
#      (including a recorded PRE-upgrade baseline proving the bug is real).
#   5. Migrations 0197-latest on top (the actual upgrade — Hotfix 7.1.2).
#   6. supabase/tests/upgrade_hotfix_7_1_2_settlements.test.sql — asserts
#      the backfill reconstructed history correctly (not the live state),
#      the anchor column is untouched, Discovery now resolves to Route A
#      only, and every pre-existing column is byte-identical.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_hotfix712_upgrade_e_test" \
#     ./scripts/run_upgrade_test_hotfix_7_1_2_settlements.sh
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

echo "==> Applying migrations 0001-0196 only (the Hotfix 7.1.1 end state, BEFORE Hotfix 7.1.2 exists)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 196 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Creating the real pre-Hotfix-7.1.2 route-drift fixture (OLD 0169-0196 RPC/schema contracts, COMMITTED) — Sale A/A -> Return -> Approve -> Reverse -> edit Sale to B/B, plus the recorded PRE-upgrade bug baseline"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/hotfix_7_1_2_upgrade_pre_fixture.sql

echo "==> Applying migrations 0197-latest on top (the actual upgrade — Phase 7 Final Historical Route Snapshot Hotfix 7.1.2)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 197 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_hotfix_7_1_2_settlements.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_hotfix_7_1_2_settlements.test.sql

echo "==> Hotfix 7.1.2 upgrade test (item E) PASSED"

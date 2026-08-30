#!/usr/bin/env bash
# ==============================================================================
# Phase 8 — Final Integrity Hotfix 8.1.1 (§60) — 0214->latest upgrade-safety
# harness.
#
# Proves migrations 0215-latest (this hotfix's own new SQL, §0's freeze
# line) apply cleanly on top of a database that already has migrations
# 0001-0214 (everything through Patch 8.1) + real, COMMITTED data written
# entirely via 0214-era RPC contracts -- and that the hotfix's fixed report
# RPCs (get_cod_report §23-26, get_settlements_report §28-31) correctly
# re-derive the RIGHT answer over that HISTORICAL data, not just over data
# created after the fix shipped.
#
# Sequence (three separate psql invocations, no step re-runs seed.sql, the
# pre-fixture data is COMMITTED, never rolled back):
#   1. Fresh DB + supabase/tests/local_harness_setup.sql (auth schema stub).
#   2. Migrations 0001-0214 only (the FROZEN pre-Hotfix-8.1.1 baseline, §0).
#   3. The real supabase/seed.sql.
#   4. supabase/tests/fixtures/hotfix_8_1_1_upgrade_pre_fixture.sql -- the
#      exact 9-call COD collection-state chain from this hotfix's own
#      transaction-scoped regression test, plus a never-finalized draft
#      settlement batch + a separate finalized one -- all via OLD (0214-era)
#      RPCs, COMMITTED, ids recorded into public.h811tu_scratch.
#   5. Migrations 0215-latest on top (this hotfix's own SQL).
#   6. supabase/tests/upgrade_hotfix_8_1_1_reports.test.sql -- reads back
#      h811tu_scratch, calls get_cod_report()/get_settlements_report() over
#      the pre-existing data, and asserts the exact figures this hotfix's
#      own SQL regression test already proved for freshly-created data
#      (net_cod_collection_effect=1000.00/4 rows/1 reversal; draft batch
#      surfaced with zero financial contribution; finalized batch isolated
#      with batches_count=1) now also hold for HISTORICAL, pre-hotfix data.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_h811t_upgrade_test" \
#     ./scripts/run_upgrade_test_hotfix_8_1_1_reports.sh
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

echo "==> Applying migrations 0001-0214 only (FROZEN pre-Hotfix-8.1.1 baseline, §0)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 214 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Creating real pre-Hotfix-8.1.1 COD + Settlements fixture data (OLD 0214-era RPC contracts, COMMITTED)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/hotfix_8_1_1_upgrade_pre_fixture.sql

echo "==> Applying migrations 0215-latest on top (this hotfix's own SQL)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 215 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_hotfix_8_1_1_reports.test.sql (drops public.h811tu_scratch itself on completion)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_hotfix_8_1_1_reports.test.sql

echo "==> SUCCESS: Hotfix 8.1.1 §60 0214->latest upgrade test passed"

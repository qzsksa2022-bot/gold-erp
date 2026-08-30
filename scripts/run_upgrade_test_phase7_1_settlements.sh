#!/usr/bin/env bash
# ==============================================================================
# Phase 7 Integrity Patch 7.1 (§34 item C) dedicated upgrade-safety harness.
#
# Proves the item C requirement of the governing patch spec: "0183->latest
# over REAL existing Phase 7 data (draft batch, finalized batch, reconciled
# batch, cancelled batch, bank movements, reversals, claimed sources, route
# fee versions)". Unlike scripts/run_upgrade_test_phase7_settlements.sh
# (which proves 0166->0183, i.e. Phase 7 ITSELF landing on top of pre-Phase-7
# data), this script proves the NARROWER, SPECIFIC-to-this-patch case:
# 0183->latest (0184-0191, Patch 7.1) landing on top of REAL data already
# created under Phase 7's OWN (0169-0183) RPC/schema contracts — the exact
# shape production already has the instant before Patch 7.1 ships.
#
# Sequence (FIVE separate psql invocations, exactly like a real production
# upgrade would experience it — no step re-runs seed.sql, and the pre-
# fixture data is COMMITTED, never rolled back):
#   1. Fresh DB + supabase/tests/local_harness_setup.sql (auth schema stub).
#   2. Migrations 0001-0183 only (the ORIGINAL Phase 7 Settlements Core
#      delivery's end state, BEFORE Patch 7.1/0184 exists).
#   3. The real supabase/seed.sql.
#   4. supabase/tests/fixtures/phase7_1_upgrade_pre_fixture.sql — builds one
#      settlement route + fee version, a draft batch, a finalized batch
#      (claiming an OLD 'return_refund'-kind source), a reconciled batch
#      (finalize -> zero-variance bank movement -> reconcile), and a
#      cancelled batch (finalize -> bank movement -> reversal -> cancel),
#      ALL via the OLD (0169-0183) Settlements RPCs, COMMITTED (not rolled
#      back), recording every id/number/known-figure PLUS a to_jsonb(row)
#      snapshot of every row of interest into a permanent public.p71u_scratch
#      table so they survive into the next step.
#   5. Migrations 0184-0191 on top (the actual upgrade — Patch 7.1).
#   6. supabase/tests/upgrade_phase7_1_settlements.test.sql — reads back
#      public.p71u_scratch, re-snapshots the SAME rows the SAME way and
#      asserts byte-identical equality (no data loss, no silent migration-
#      time mutation — 0172/0173's immutability triggers only ever protected
#      against APPLICATION writes, never a migration script itself, so this
#      is genuinely worth proving), then confirms the NEW (0191) get_
#      settlement_batch()/list_settlement_batches() still read this OLD-
#      shape data back correctly (old 'return_refund'-kind line displays
#      fine; the cancelled batch's original_* figures are unchanged while
#      its effective_* figures are exactly 0.00), then drops the scratch
#      table.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_patch71_upgrade_c_test" \
#     ./scripts/run_upgrade_test_phase7_1_settlements.sh
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

echo "==> Applying migrations 0001-0183 only (the ORIGINAL Phase 7 Settlements Core end state, BEFORE Patch 7.1 exists)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 183 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Creating real pre-Patch-7.1 Settlements fixture data (OLD 0169-0183 RPC/schema contracts, COMMITTED) — draft/finalized/reconciled/cancelled batches, bank movement + reversal, claimed sources, route fee version"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/phase7_1_upgrade_pre_fixture.sql

echo "==> Applying migrations 0184-latest on top (the actual upgrade — Phase 7 Integrity Patch 7.1)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 184 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_phase7_1_settlements.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase7_1_settlements.test.sql

echo "==> Phase 7.1 upgrade test (item C) PASSED"

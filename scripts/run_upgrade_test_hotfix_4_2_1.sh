#!/usr/bin/env bash
# ==============================================================================
# Hotfix 4.2.1 dedicated legacy-Returns-refund-ledger upgrade-safety harness
# (spec Section 22: "Upgrade from 0105 with: active refund events, reversed
# legacy refund events, and approved returns using fee-engine v1").
#
# Builds a database to EXACTLY migration 0105 + the real supabase/seed.sql
# (Patch 4.2 shipped, Hotfix 4.2.1 not yet applied), creates real Returns/
# refund-ledger data using the CURRENT-AT-0105 Returns RPC signatures —
# including reversing a refund event with the OLD (pre-0107) UPDATE-based
# reverse_sales_return_refund_event(), and approving a return under the OLD
# (pre-0109) item-value/covers-all-remaining fee engine — THEN applies
# migrations 0106-latest on top (a SEPARATE psql invocation, exactly like
# production would experience an upgrade), and finally runs
# supabase/tests/upgrade_hotfix_4_2_1_legacy_refunds.test.sql (also a
# separate invocation) to prove:
#
#   (A) an active (never-reversed) refund event gets no row in the new
#       sales_return_refund_event_reversals ledger, and still counts toward
#       actual_refunded_total after upgrade.
#   (B) a legacy status='reversed' event gets EXACTLY ONE row in the new
#       ledger, carrying over the exact same historical reversal facts, and
#       actual_refunded_total is IDENTICAL before and after the upgrade.
#   (C) an approved return computed under the OLD v1 fee engine keeps its
#       exact historical payment_fee_reversal_amount after upgrade, tagged
#       calculation_version=1, never silently recomputed by the v2 engine.
#
# This is DELIBERATELY separate from scripts/run_upgrade_test_patch_4_2.sh
# (which proves 0092-0105's OWN upgrade safety, not this hotfix's).
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_hf421_upgrade_test" \
#     ./scripts/run_upgrade_test_hotfix_4_2_1.sh
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

echo "==> Applying migrations 0001-0105 only (Patch 4.2 shipped, pre-Hotfix-4.2.1 state)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 105 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Applying Hotfix 4.2.1 legacy-upgrade pre-fixture (creates refund-ledger data with the OLD pre-0106 RPC behavior)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/hotfix_4_2_1_legacy_upgrade_pre_fixture.sql

echo "==> Applying migrations 0106-latest on top (the actual upgrade, Hotfix 4.2.1)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 106 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_hotfix_4_2_1_legacy_refunds.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_hotfix_4_2_1_legacy_refunds.test.sql

echo "==> Hotfix 4.2.1 legacy-upgrade test PASSED"

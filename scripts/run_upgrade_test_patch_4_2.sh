#!/usr/bin/env bash
# ==============================================================================
# Patch 4.2 dedicated legacy-Returns upgrade-safety harness (spec item 10 /
# Section 12 "Missing Upgrade Tests").
#
# Builds a database to EXACTLY migration 0091 + the real supabase/seed.sql
# (Patch 4.1/4.2 not yet applied), creates real Returns data using the OLD
# (pre-0092) Returns RPC signatures — including editing a Sale AFTER a
# Pending return already exists against it — THEN applies migrations
# 0092-latest on top (a SEPARATE psql invocation, exactly like production
# would experience an upgrade), and finally runs
# supabase/tests/upgrade_patch_4_2_legacy_returns.test.sql (also a separate
# invocation) to prove:
#
#   (A) requires_sale_refresh (0099) is correctly backfilled true for a
#       legacy Pending return, the staleness it flags is REAL (not just a
#       flag disconnected from the actual data), approve_sales_return()
#       (0101) rejects it outright, and refresh_pending_sales_return_from_
#       sale() (0100) is the one remediation path that clears it and lets
#       approval subsequently succeed on the CURRENT correct price.
#   (B) the three new Section 12 financial columns (returned_original_sale_
#       amount/recovered_original_cost_amount/net_sales_profit_adjustment)
#       are correctly backfilled (0099) for a legacy Approved return that
#       predates them, and get_sales_return()'s adjusted_order_net_sales_
#       profit (0098/0104) correctly reflects the backfilled adjustment.
#   (C) the same backfill also applies to a legacy Reversed return, but
#       adjusted_order_net_sales_profit on ITS order correctly EXCLUDES the
#       adjustment (only status='approved' returns are ever summed).
#
# This is DELIBERATELY separate from scripts/run_upgrade_test.sh (the
# general Foundation-only upgrade proof, which does not touch Returns data
# at all) — this script's whole purpose is Returns-specific.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_p42_upgrade_test" \
#     ./scripts/run_upgrade_test_patch_4_2.sh
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

echo "==> Applying migrations 0001-0091 only (pre-Patch-4.1/4.2 state)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 91 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql (production upgrade starts from real seed data, not a synthetic snapshot)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Applying Patch 4.2 legacy-upgrade pre-fixture (creates Returns data with the OLD pre-0092 RPC signatures)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/patch_4_2_legacy_upgrade_pre_fixture.sql

echo "==> Applying migrations 0092-latest on top (the actual upgrade, Patch 4.1 + Patch 4.2)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 92 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_patch_4_2_legacy_returns.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_patch_4_2_legacy_returns.test.sql

echo "==> Patch 4.2 legacy-upgrade test PASSED"

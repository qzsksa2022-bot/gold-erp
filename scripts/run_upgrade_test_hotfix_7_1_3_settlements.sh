#!/usr/bin/env bash
# ==============================================================================
# Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3 (§11/§13/§14/§17
# item E) dedicated upgrade-safety harness.
#
# Proves item E: "0196 -> corrected 0197/0198 WITH BOTH the existing
# historical-drift fixture (§12) AND the new refreshed-pending fixture
# (§11) AND multi-refresh data (§13)" — all built under the OLD (pre-0197)
# 0001-0196 contracts, COMMITTED into the SAME database, THEN upgraded
# together to the corrected 0197-latest in one pass, THEN both the EXISTING
# (unmodified) upgrade_hotfix_7_1_2_settlements.test.sql and the NEW
# upgrade_hotfix_7_1_3_settlements.test.sql are run against that one real
# upgraded database.
#
# Sequence (SEVEN separate psql invocations, no step re-runs seed.sql, all
# fixture data is COMMITTED, never rolled back):
#   1. Fresh DB + supabase/tests/local_harness_setup.sql (auth schema stub).
#   2. Migrations 0001-0196 only (the Hotfix 7.1.1 end state, BEFORE Hotfix
#      7.1.2/7.1.3's 0197-0198 exist).
#   3. The real supabase/seed.sql.
#   4. supabase/tests/fixtures/hotfix_7_1_2_upgrade_pre_fixture.sql — the
#      EXISTING §12 route-drift scenario (Sale A/A -> Return -> Approve ->
#      Reverse -> Sale B/B), unmodified.
#   5. supabase/tests/fixtures/hotfix_7_1_3_upgrade_pre_fixture.sql — the NEW
#      §11 refreshed-pending scenario (Sale A/A -> Return -> Sale B/B ->
#      refresh -> left PENDING) and §13 multi-refresh scenario (A/A -> B/B
#      (refresh) -> C/C (refresh) -> left PENDING).
#   6. Migrations 0197-latest on top (the actual upgrade — the CORRECTED
#      Hotfix 7.1.3 0197/0198).
#   7. upgrade_hotfix_7_1_2_settlements.test.sql (§12 — must still PASS
#      against the corrected migrations, on the SAME real upgraded data).
#   8. upgrade_hotfix_7_1_3_settlements.test.sql (§11/§13 — the new
#      refreshed-pending/multi-refresh backfill + post-upgrade lifecycle +
#      Discovery proof).
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_hotfix713_upgrade_e_test" \
#     ./scripts/run_upgrade_test_hotfix_7_1_3_settlements.sh
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

echo "==> Applying migrations 0001-0196 only (the Hotfix 7.1.1 end state, BEFORE 0197/0198 exist)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 196 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Creating the EXISTING Hotfix 7.1.2 route-drift fixture (§12, OLD 0169-0196 RPC/schema contracts, COMMITTED)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/hotfix_7_1_2_upgrade_pre_fixture.sql

echo "==> Creating the NEW Hotfix 7.1.3 refreshed-pending + multi-refresh fixtures (§11/§13, OLD 0169-0196 RPC/schema contracts, COMMITTED)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/hotfix_7_1_3_upgrade_pre_fixture.sql

echo "==> Applying migrations 0197-latest on top (the actual upgrade — CORRECTED Hotfix 7.1.3 0197/0198)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 197 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_hotfix_7_1_2_settlements.test.sql (§12 — must still PASS against the corrected migrations)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_hotfix_7_1_2_settlements.test.sql

echo "==> Running upgrade_hotfix_7_1_3_settlements.test.sql (§11/§13 — new refreshed-pending/multi-refresh proof)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_hotfix_7_1_3_settlements.test.sql

echo "==> Hotfix 7.1.3 upgrade test (item E, §11/§12/§13 combined) PASSED"

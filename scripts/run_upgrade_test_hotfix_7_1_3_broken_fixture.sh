#!/usr/bin/env bash
# ==============================================================================
# Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3 (§14) —
# explicit-FAIL-path upgrade-safety proof.
#
# Proves §14's second half: "if the required audit row_version is missing
# AND the current Sale isn't the same basis, migration must FAIL explicitly
# — never guess, never fall back to the old timestamp heuristic."
#
# Builds a refreshed-pending Return under the OLD 0001-0196 contract (basis
# = source_sale_row_version=2), then DELIBERATELY corrupts its audit trail
# (deletes the one audit_logs row the backfill needs, and moves the Sale to
# a THIRD version so the safe fallback can't apply either) via
# hotfix_7_1_3_upgrade_broken_fixture.sql, COMMITS that, then attempts to
# apply migrations 0197-latest on top.
#
# Unlike every other upgrade-safety script in this project, this one
# EXPECTS migration 0197 to FAIL — a non-zero exit from that one psql
# invocation is the PASSING outcome here, proving 0197's backfill integrity
# check (§6/§7/§8) genuinely aborts the whole migration (leaving NO partial
# state — 0197 is wrapped in an explicit transaction) rather than silently
# writing a guessed/wrong collection_channel_id_snapshot. Because a real
# migration FAIL cannot coexist with a passing "happy path" upgrade in the
# same database, this always runs in its OWN dedicated, disposable database.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_hotfix713_upgrade_broken_test" \
#     ./scripts/run_upgrade_test_hotfix_7_1_3_broken_fixture.sh
#
# Requires: a Postgres server reachable at $DATABASE_URL's host, with
# CREATEDB privilege for the connecting role (the script drops/recreates the
# target database each run so it always starts from a clean slate).
# ==============================================================================
set -uo pipefail

DATABASE_URL="${DATABASE_URL:?Set DATABASE_URL to the target test database (it will be dropped and recreated)}"

DB_NAME="${DATABASE_URL##*/}"
ADMIN_URL="${DATABASE_URL%/*}/postgres"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Dropping/recreating $DB_NAME"
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" || exit 1
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\";" || exit 1

echo "==> Applying test harness setup (auth schema stub)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/local_harness_setup.sql || exit 1

echo "==> Applying migrations 0001-0196 only (BEFORE 0197/0198 exist)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 196 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" || exit 1
  fi
done

echo "==> Applying the real supabase/seed.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql || exit 1

echo "==> Creating the DELIBERATELY BROKEN refreshed-pending fixture (§14) — audit trail corrupted, COMMITTED"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/hotfix_7_1_3_upgrade_broken_fixture.sql || exit 1

echo "==> Applying migrations 0197-latest on top — 0197's backfill for the corrupted Return is EXPECTED TO FAIL (this is the pass condition for this script)"
EXPECT_197_TO_FAIL=0
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 197 ]; then
    echo "   - $base"
    if [ "$num" -eq 197 ]; then
      if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" > /tmp/h713ub_0197_output.txt 2>&1; then
        echo "==> UNEXPECTED: migration 0197 SUCCEEDED against the corrupted fixture — it should have aborted with an explicit backfill integrity error. FAIL."
        cat /tmp/h713ub_0197_output.txt
        exit 1
      else
        EXPECT_197_TO_FAIL=1
        echo "==> Migration 0197 correctly FAILED (expected). Output:"
        cat /tmp/h713ub_0197_output.txt
        if ! grep -q "backfill integrity check FAILED" /tmp/h713ub_0197_output.txt; then
          echo "==> FAIL: 0197 failed, but NOT with the expected 'backfill integrity check FAILED' message — this may be a different, unrelated failure."
          exit 1
        fi
        H713UB_RETURN_ID="$(psql "$DATABASE_URL" -X -A -t -v ON_ERROR_STOP=1 -c "select value from public.h713ub_scratch where label = 'return_id';")"
        if [ -z "$H713UB_RETURN_ID" ] || ! grep -q "$H713UB_RETURN_ID" /tmp/h713ub_0197_output.txt; then
          echo "==> FAIL: 0197's error message did not name the corrupted h713ub fixture's Return (return_id=$H713UB_RETURN_ID) — cannot confirm it identified the right row."
          exit 1
        fi
        break
      fi
    fi
  fi
done

if [ "$EXPECT_197_TO_FAIL" -ne 1 ]; then
  echo "==> FAIL: migration 0197 was never reached/attempted — script logic error."
  exit 1
fi

echo "==> Confirming the migration transaction left NO partial state (0197 is wrapped in an explicit transaction; the ALTER TABLE ADD COLUMN from Part A should have been rolled back along with everything else)"
COL_EXISTS="$(psql "$DATABASE_URL" -X -A -t -v ON_ERROR_STOP=1 -c "select count(*) from information_schema.columns where table_schema='public' and table_name='sales_returns' and column_name='collection_channel_id_snapshot';")"
if [ "$COL_EXISTS" != "0" ]; then
  echo "==> FAIL: collection_channel_id_snapshot column exists after 0197 aborted — the migration's transaction wrapping did not roll back cleanly (partial state leaked)."
  exit 1
fi
echo "==> Confirmed: no partial state — collection_channel_id_snapshot does not exist, 0197's failed transaction rolled back completely."

echo "==> Hotfix 7.1.3 explicit-FAIL-path test (§14) PASSED — the corrupted refreshed-pending Return correctly aborted the whole migration with a named, explicit error instead of silently guessing a wrong collection_channel_id_snapshot"

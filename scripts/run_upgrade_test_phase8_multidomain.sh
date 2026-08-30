#!/usr/bin/env bash
# ==============================================================================
# Patch 8.1 §52-53 — Real MULTI-DOMAIN 0198->latest upgrade-safety harness.
#
# Proves every Phase 8 / Patch 8.1 report RPC (0199-0214) correctly reads
# and aggregates data that genuinely existed BEFORE any of them did --
# Sales, Returns (+ a real cash refund event + its reversal), Adjustments
# (+ its reversal), Shipping (a real COD not_collected -> collected
# transition), and an already-FINALIZED Settlement batch with a recorded
# bank movement -- all created via the OLD (pre-Phase-8, 0198) RPC
# contracts and fully COMMITTED, exactly as a real production upgrade would
# already have accumulated.
#
# Sequence (five separate psql invocations, no step re-runs seed.sql, the
# pre-fixture data is COMMITTED, never rolled back):
#   1. Fresh DB + supabase/tests/local_harness_setup.sql (auth schema stub).
#   2. Migrations 0001-0198 only (the FROZEN pre-Phase-8 baseline, §0).
#   3. The real supabase/seed.sql.
#   4. supabase/tests/fixtures/phase8_upgrade_pre_fixture.sql -- creates the
#      full cross-domain dataset described above via the OLD RPCs,
#      COMMITTED, recording every id/number/known figure into a permanent
#      public.p8u_scratch table so it survives into the next step.
#   5. Migrations 0199-latest on top (the actual upgrade -- all of Phase 8
#      + Patch 8.1).
#   6. supabase/tests/upgrade_phase8_multidomain.test.sql -- reads back
#      p8u_scratch, calls every Phase 8 report/dashboard RPC over a window
#      containing the pre-existing data, and asserts real figures (not
#      just "no exception") match what the pre-fixture actually created.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_phase8_upgrade_test" \
#     ./scripts/run_upgrade_test_phase8_multidomain.sh
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

echo "==> Applying migrations 0001-0198 only (FROZEN pre-Phase-8 baseline, §0)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 198 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying the real supabase/seed.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql

echo "==> Creating real pre-Phase-8 multi-domain fixture data (OLD RPC/schema contracts, COMMITTED)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/phase8_upgrade_pre_fixture.sql

echo "==> Applying migrations 0199-latest on top (the actual upgrade -- Phase 8 + Patch 8.1)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 199 ]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_phase8_multidomain.test.sql (drops public.p8u_scratch itself on completion)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_phase8_multidomain.test.sql

echo "==> SUCCESS: Patch 8.1 §52-53 multi-domain 0198->latest upgrade test passed"

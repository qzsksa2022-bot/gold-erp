#!/usr/bin/env bash
# ==============================================================================
# Builds a database the exact way spec item 4 (Financial Integrity Patch 2.1)
# describes production upgrading — Foundation (0001-0039) + Foundation-only
# seed data, then 0040-through-latest WITHOUT ever running the current
# (Phase-2-aware) supabase/seed.sql — and runs
# supabase/tests/upgrade_from_0039.test.sql against it.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:PASSWORD@127.0.0.1:5432/gold_erp_upgrade_test" \
#     ./scripts/run_upgrade_test.sh
#
# Requires: a Postgres server reachable at $DATABASE_URL's host, with
# CREATEDB privilege for the connecting role (the script drops/recreates the
# target database each run so it always starts from a clean slate).
# ==============================================================================
set -euo pipefail

DATABASE_URL="${DATABASE_URL:?Set DATABASE_URL to the target test database (it will be dropped and recreated)}"

# Split DATABASE_URL into "everything but the db name" (to connect to the
# server's default 'postgres' maintenance db for DROP/CREATE) and the db name
# itself.
DB_NAME="${DATABASE_URL##*/}"
ADMIN_URL="${DATABASE_URL%/*}/postgres"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Dropping/recreating $DB_NAME"
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\";"

echo "==> Applying test harness setup (auth schema stub)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/local_harness_setup.sql

echo "==> Applying Foundation migrations 0001-0039 only"
for f in supabase/migrations/00[0-3][0-9]_*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -le 39 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Applying Foundation-only seed fixture (NOT the real seed.sql)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fixtures/foundation_only_seed.sql

echo "==> Applying Phase 2 / Patch 2.1 migrations 0040-latest (still no seed.sql)"
for f in supabase/migrations/*.sql; do
  base="$(basename "$f")"
  num="${base%%_*}"
  if [ "$num" -ge 40 ]; then
    echo "   - $base"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  fi
done

echo "==> Running upgrade_from_0039.test.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/upgrade_from_0039.test.sql

echo "==> Upgrade test PASSED"

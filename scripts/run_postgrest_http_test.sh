#!/usr/bin/env bash
# ==============================================================================
# Builds a fully throwaway database, starts a REAL PostgREST binary against
# it, signs a real JWT, and runs scripts/postgrest-http-test.mjs — the real
# HTTP/PostgREST integration test for Financial Integrity Patch 2.2, item 2
# (the Decimal Transport Boundary fix). This is NOT a simulation: it proves,
# over actual HTTP against actual PostgREST (v12.2.3, official binary),
# that raw NUMERIC values are serialized as unquoted JSON numbers (lossy for
# high precision) and that the finance-safe "_safe" RPCs (migration 0052)
# are serialized as quoted JSON strings (lossless).
#
# Requires:
#   - psql reachable, with CREATEDB + role-creation privilege for
#     ADMIN_DATABASE_URL's connecting role (the script drops/recreates the
#     target database and the `anon`/`authenticated`/`service_role`/
#     `authenticator` roles each run).
#   - The PostgREST binary at $POSTGREST_BIN (default /tmp/postgrest — see
#     DELIVERY_REPORT.md's Patch 2.2 appendix for how it was obtained: the
#     official v12.2.3 static Linux binary from PostgREST's GitHub releases).
#   - Node with @supabase/postgrest-js and decimal.js already installed
#     (both are already project dependencies / transitive dependencies via
#     supabase-js — nothing extra to install).
#
# Usage:
#   ADMIN_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:5432/postgres" \
#     ./scripts/run_postgrest_http_test.sh
#
# Exits non-zero if any step (DB build, PostgREST startup, or any assertion
# in postgrest-http-test.mjs) fails.
# ==============================================================================
set -euo pipefail

ADMIN_DATABASE_URL="${ADMIN_DATABASE_URL:?Set ADMIN_DATABASE_URL to a connection string for the 'postgres' maintenance database}"
DB_NAME="gold_erp_postgrest_test"
TARGET_HOST_PORT="${ADMIN_DATABASE_URL#*@}"       # e.g. 127.0.0.1:5432/postgres
TARGET_HOST_PORT="${TARGET_HOST_PORT%/*}"          # e.g. 127.0.0.1:5432
DATABASE_URL="${ADMIN_DATABASE_URL%/*}/${DB_NAME}"

POSTGREST_BIN="${POSTGREST_BIN:-/tmp/postgrest}"
POSTGREST_PORT="${POSTGREST_PORT:-3111}"
POSTGREST_URL="http://127.0.0.1:${POSTGREST_PORT}"
JWT_SECRET="patch22-http-test-secret-do-not-use-in-prod-$(date +%s 2>/dev/null || echo static)0000000000000000"
WORKDIR="$(mktemp -d)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

POSTGREST_PID=""
cleanup() {
  if [ -n "$POSTGREST_PID" ]; then
    kill "$POSTGREST_PID" 2>/dev/null || true
    wait "$POSTGREST_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> [1/8] Dropping/recreating $DB_NAME"
psql "$ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" >/dev/null
psql "$ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$DB_NAME\";" >/dev/null

echo "==> [2/8] Ensuring anon/authenticated/service_role/authenticator roles exist"
psql "$ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -c "
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'authenticator_pw'; END IF;
END \$\$;" >/dev/null
psql "$ADMIN_DATABASE_URL" -v ON_ERROR_STOP=1 -c "GRANT anon TO authenticator; GRANT authenticated TO authenticator; GRANT service_role TO authenticator;" >/dev/null

echo "==> [3/8] Applying local harness setup + all migrations + seed.sql"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/local_harness_setup.sql >/dev/null
for f in supabase/migrations/*.sql; do
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f" >/dev/null
done
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql >/dev/null

echo "==> [4/8] Applying postgrest_http_test_setup.sql (test-only fixture)"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/postgrest_http_test_setup.sql >/dev/null

echo "==> [5/8] Writing PostgREST config"
AUTHENTICATOR_URL="postgresql://authenticator:authenticator_pw@${TARGET_HOST_PORT%%/*}/${DB_NAME}"
cat > "$WORKDIR/postgrest.conf" <<EOF
db-uri = "${AUTHENTICATOR_URL}"
db-schemas = "public"
db-anon-role = "anon"
jwt-secret = "${JWT_SECRET}"
server-port = ${POSTGREST_PORT}
db-pool = 4
EOF

echo "==> [6/8] Starting PostgREST (${POSTGREST_BIN})"
if [ ! -x "$POSTGREST_BIN" ]; then
  echo "FATAL: PostgREST binary not found/executable at $POSTGREST_BIN — set POSTGREST_BIN or see DELIVERY_REPORT.md Patch 2.2 appendix for how it was obtained." >&2
  exit 1
fi
"$POSTGREST_BIN" "$WORKDIR/postgrest.conf" > "$WORKDIR/pgrst.log" 2>&1 &
POSTGREST_PID=$!

for i in $(seq 1 20); do
  if curl -s -o /dev/null "$POSTGREST_URL/"; then
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "FATAL: PostgREST did not become ready in time. Log:" >&2
    cat "$WORKDIR/pgrst.log" >&2
    exit 1
  fi
  sleep 0.5
done
echo "    PostgREST ready at $POSTGREST_URL"

echo "==> [7/8] Signing test JWTs (profit actor + non-profit actor + service_role verification actor + Phase 6 Adjustments-create-only actor + Patch 6.1 manage-cost-only/store-B-only actors + Phase 7 Settlements actors + Hotfix 7.1.1 actors)"
TEST_JWT="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000001" "authenticated")"
TEST_JWT_NO_PROFIT="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000002" "authenticated")"
# Patch 3.1 item M: a service_role-signed JWT, used ONLY as a verification
# oracle (bypasses RLS, exactly like src/lib/supabase/admin.ts's real
# server-side client) to prove sales_order_items rows are genuinely
# soft-removed (status='removed', row still exists) rather than hard-deleted
# — sales_order_items has zero SELECT RLS policies for `authenticated`, so
# this cannot be proven any other way over real HTTP.
TEST_JWT_SERVICE="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "00000000-0000-0000-0000-000000000000" "service_role")"
# Phase 6 (Services / Adjustments Core), Part 11, §25 — a THIRD real actor
# holding ONLY adjustments.create (no sales.view at all), proving search_
# sales_orders_for_adjustment() never depends on sales.view over real HTTP.
TEST_JWT_ADJ_CREATE_ONLY="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000003" "authenticated")"
# Patch 6.1 item 2 — a FOURTH actor holding ONLY adjustments.manage_cost (no
# view/create/approve), proving the dedicated cost RPC works standalone.
TEST_JWT_ADJ_MANAGE_COST_ONLY="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000004" "authenticated")"
# Patch 6.1 items 12/13/31 — a FIFTH actor, single-store-scoped to Store B
# only (adjustments.view + adjustments.approve), proving the cross-store
# read/reject scope fix over real HTTP. Phase 7 Integrity Patch 7.1
# (Settlements Core) additionally grants this SAME actor settlements.view/
# view_financials/create (postgrest_http_test_setup.sql), reusing it for the
# Settlements §5/§6 cross-store privacy proof.
TEST_JWT_ADJ_STORE_B_ONLY="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000005" "authenticated")"
# Phase 7 Integrity Patch 7.1 (Settlements Core) — four more narrow actors:
# settlements.create-only (§7/§24), settlements.manage_routes-only (§2/§23),
# and the two §8 audit-permission-split actors (settlements.view_financials
# alone / sales.view_profit alone).
TEST_JWT_SETTLE_CREATE_ONLY="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000006" "authenticated")"
TEST_JWT_SETTLE_MANAGE_ROUTES_ONLY="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000007" "authenticated")"
TEST_JWT_SETTLE_AUDIT_FIN_ONLY="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000008" "authenticated")"
TEST_JWT_SALES_PROFIT_NO_SETTLE_FIN="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000009" "authenticated")"
# Phase 7 Final Integrity Hotfix 7.1.1 (Settlements Core, migrations
# 0192-0196) — three more narrow actors for Part 15: a SECOND settlements.
# create-only identity (§4 non-owner rejection), a single-store-scoped actor
# holding every lifecycle write permission (§5 fail-closed proof), and a
# settlements.reconcile-only actor with no view_financials (§7 redaction).
TEST_JWT_SETTLE_CREATE_ONLY_2="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000010" "authenticated")"
TEST_JWT_SETTLE_STORE_SCOPED="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000011" "authenticated")"
TEST_JWT_SETTLE_RECONCILE_ONLY="$(node scripts/sign-test-jwt.mjs "$JWT_SECRET" "c9000000-0000-4000-8000-000000000012" "authenticated")"

echo "==> [8/8] Running the real HTTP/PostgREST integration test"
POSTGREST_URL="$POSTGREST_URL" TEST_JWT="$TEST_JWT" TEST_JWT_NO_PROFIT="$TEST_JWT_NO_PROFIT" TEST_JWT_SERVICE="$TEST_JWT_SERVICE" TEST_JWT_ADJ_CREATE_ONLY="$TEST_JWT_ADJ_CREATE_ONLY" TEST_JWT_ADJ_MANAGE_COST_ONLY="$TEST_JWT_ADJ_MANAGE_COST_ONLY" TEST_JWT_ADJ_STORE_B_ONLY="$TEST_JWT_ADJ_STORE_B_ONLY" TEST_JWT_SETTLE_CREATE_ONLY="$TEST_JWT_SETTLE_CREATE_ONLY" TEST_JWT_SETTLE_MANAGE_ROUTES_ONLY="$TEST_JWT_SETTLE_MANAGE_ROUTES_ONLY" TEST_JWT_SETTLE_AUDIT_FIN_ONLY="$TEST_JWT_SETTLE_AUDIT_FIN_ONLY" TEST_JWT_SALES_PROFIT_NO_SETTLE_FIN="$TEST_JWT_SALES_PROFIT_NO_SETTLE_FIN" TEST_JWT_SETTLE_CREATE_ONLY_2="$TEST_JWT_SETTLE_CREATE_ONLY_2" TEST_JWT_SETTLE_STORE_SCOPED="$TEST_JWT_SETTLE_STORE_SCOPED" TEST_JWT_SETTLE_RECONCILE_ONLY="$TEST_JWT_SETTLE_RECONCILE_ONLY" node scripts/postgrest-http-test.mjs

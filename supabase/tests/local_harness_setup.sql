-- ============================================================================
-- Local Postgres test harness setup
-- ============================================================================
-- Recreates just enough of Supabase's `auth` schema to run the migrations
-- and supabase/tests/rls_and_permissions.test.sql against a plain local
-- Postgres instance, without needing a real Supabase project. This is NOT
-- part of the application schema and must never be applied to a real
-- Supabase database (which already has its own real `auth` schema) --
-- it exists purely so RLS/SECURITY DEFINER/trigger behavior can be verified
-- automatically and repeatably in CI or on a developer machine.
--
-- Usage (run once against a fresh, throwaway database):
--   createdb gold_erp_test
--   psql -d gold_erp_test -c "create role anon nologin;"
--   psql -d gold_erp_test -c "create role authenticated nologin;"
--   psql -d gold_erp_test -c "create role service_role nologin bypassrls;"
--   psql -d gold_erp_test -v ON_ERROR_STOP=1 -f supabase/tests/local_harness_setup.sql
--   for f in supabase/migrations/*.sql; do
--     psql -d gold_erp_test -v ON_ERROR_STOP=1 -f "$f" || break
--   done
--   psql -d gold_erp_test -v ON_ERROR_STOP=1 -f supabase/seed.sql
--   psql -d gold_erp_test -v ON_ERROR_STOP=1 -f supabase/tests/rls_and_permissions.test.sql
--
-- The `anon` / `authenticated` / `service_role` roles above match Supabase's
-- real Postgres role names exactly, which is what every RLS policy and
-- GRANT in this project's migrations references.
-- ============================================================================

create schema if not exists auth;

-- Minimal stand-in for auth.users -- only the columns this project's
-- triggers/migrations actually read.
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  last_sign_in_at timestamptz
);

-- Faithful reproduction of Supabase's real implementations: both read the
-- `request.jwt.claims` GUC that PostgREST sets per-request from the
-- caller's JWT. Tests simulate a request by doing:
--   set role authenticated;
--   set local request.jwt.claims = '{"sub":"<uuid>","role":"authenticated"}';
--
-- Guarded (plpgsql, not the one-line `sql` version Supabase ships) against
-- current_setting() returning an empty string: real Supabase never hits
-- that path (PostgREST either sets a full JWT-claims blob at the start of a
-- fresh per-request transaction, or never sets the GUC at all -- it never
-- RESETs mid-transaction), but this test suite runs as one long-lived
-- transaction and uses `reset request.jwt.claims;` between simulated
-- requests to return to an unauthenticated context. In Postgres, RESET on a
-- custom GUC that was previously SET leaves it as '' (empty string), not
-- NULL/undefined -- and ''::json raises "invalid input syntax for type
-- json: the input string ended unexpectedly", not simply "no claims". Cast
-- only when there is actually something to parse.
create or replace function auth.uid()
returns uuid
language plpgsql stable
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if v_claims is null or v_claims = '' then
    return null;
  end if;
  return nullif(v_claims::json->>'sub', '')::uuid;
end;
$$;

create or replace function auth.role()
returns text
language plpgsql stable
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if v_claims is null or v_claims = '' then
    return null;
  end if;
  return nullif(v_claims::json->>'role', '');
end;
$$;

-- service_role needs ordinary table privileges in addition to BYPASSRLS
-- (BYPASSRLS skips RLS policies, not the underlying GRANT system) -- mirrors
-- what a real Supabase project's service_role already has.
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
grant usage on schema public to anon, authenticated, service_role;
grant all on schema public to service_role;

-- A real Supabase project's service_role also has full access to the real
-- `auth` schema (it IS the Admin API's underlying role) -- e.g.
-- admin.auth.admin.createUser() in src/features/users/actions.ts inserts
-- into auth.users as service_role. Foundation Hardening 1.2's test sections
-- (9d/9e/14, which create additional test actors mid-suite via `set role
-- service_role; insert into auth.users ...`, exactly mirroring that
-- Admin-API call site) need the same access here, or every such insert
-- fails with "permission denied for schema auth" even though the
-- equivalent call succeeds against a real Supabase project.
grant usage on schema auth to service_role;
grant all on auth.users to service_role;

-- A real Supabase project also exposes auth.uid()/auth.role() to `anon`/
-- `authenticated` directly (that is the entire point of those functions --
-- RLS policies and app code alike call them while running AS those roles).
-- Foundation Hardening 1.2's test sections call public.is_super_admin(
-- auth.uid()) directly from inside an actor's own `do $$` block (not only
-- indirectly through a SECURITY DEFINER wrapper, which would bypass this
-- either way) -- without schema USAGE here, that direct call fails with
-- "permission denied for schema auth" even though the equivalent call
-- succeeds against a real Supabase project.
grant usage on schema auth to anon, authenticated;

-- A real Supabase project grants `anon`/`authenticated` blanket table-level
-- SELECT/INSERT/UPDATE/DELETE by default (RLS policies, not table grants,
-- are what actually restrict them) -- reproduce that here so a REVOKEd/
-- missing table grant never masquerades as "RLS correctly denied this".
-- Applied per-table (not ALL TABLES) because at the point this script runs,
-- during local setup, only auth.users exists yet; the migrations that
-- create the public.* tables run after this file, and each one already
-- calls `alter table ... enable row level security` itself. Re-run the two
-- ALTER DEFAULT PRIVILEGES lines below (or the block at the bottom) after
-- all migrations are applied if you ever add a table without them.
alter default privileges in schema public grant select, insert, update, delete on tables to anon, authenticated;
alter default privileges in schema public grant usage, select on sequences to anon, authenticated;

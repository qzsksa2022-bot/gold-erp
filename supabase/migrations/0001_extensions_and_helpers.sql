-- ============================================================================
-- 0001: Extensions & shared helper functions
-- ============================================================================
-- pgcrypto gives us gen_random_uuid(); it is enabled by default on Supabase
-- projects but we declare it explicitly so this migration set is portable.
create extension if not exists pgcrypto;

-- Generic "touch updated_at" trigger used by every mutable table that has an
-- updated_at column. Centralizing this avoids copy-pasted trigger bodies and
-- guarantees consistent behaviour (UTC, set on every UPDATE regardless of
-- what the client sent).
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'BEFORE UPDATE trigger: stamps updated_at = now() on every row update.';

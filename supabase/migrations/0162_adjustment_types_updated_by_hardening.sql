-- ============================================================================
-- 0162: Phase 6 Final Integrity Hotfix 6.1.1 (6/6): adjustment_types
-- updated_at/updated_by system-managed column hardening
-- ============================================================================
-- Migrations 0001-0161 are unmodified.
--
-- Hotfix 6.1.1 item 9 — 0153 already hardened code/created_at/created_by
-- (BEFORE UPDATE, raises on any attempted change) and the lock/no-delete
-- invariants. updated_at/updated_by were left to the sanctioned RPCs
-- (create/update/disable/enable_adjustment_type, 0136) setting them
-- correctly themselves, plus 0001's generic set_updated_at() trigger for
-- updated_at alone — but nothing forced updated_by to the REAL invoking
-- actor against a trusted direct write (service_role, or any future
-- SECURITY DEFINER function) that supplied an arbitrary value instead.
--
-- This mirrors the project's existing generic system-managed-columns
-- pattern (enforce_system_managed_columns(), 0021/0048): on UPDATE,
-- updated_at is always stamped now() and updated_by is always pinned to
-- auth.uid() when auth.uid() is not null (an ordinary `authenticated`
-- write, direct or through an RPC, can never forge it to someone else's
-- id); when auth.uid() IS null (a genuinely trusted context — service_role,
-- migrations, seed.sql, exactly like every other table using this same
-- pattern project-wide) whatever value was explicitly supplied is left
-- alone, since that is a legitimate system-attributed write, not client
-- forgery. A dedicated, narrower function (not the shared 4-column
-- enforce_system_managed_columns()) is used here deliberately: it touches
-- ONLY updated_at/updated_by, leaving code/created_at/created_by exactly as
-- 0153 already protects them (an explicit raise, not a silent pin) —
-- attaching the full 4-column function instead would silently change that
-- already-correct behavior for created_at/created_by (item 16 in the
-- "don't reopen what's already correct" list).
--
-- No RLS/permission change — `authenticated`''s grants on adjustment_types
-- are untouched; this is a trigger-level hardening only.
-- ---------------------------------------------------------------------------
create or replace function public.adjustment_types_enforce_updated_columns()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  if auth.uid() is not null then
    new.updated_by := auth.uid();
  end if;
  return new;
end;
$$;

comment on function public.adjustment_types_enforce_updated_columns() is
  'Hotfix 6.1.1 item 9 — forces adjustment_types.updated_at/updated_by to server truth on every UPDATE, mirroring the project''s existing enforce_system_managed_columns() pattern (0021/0048) but narrowed to these two columns only (code/created_at/created_by stay protected by 0153''s own explicit-raise trigger, unchanged). auth.uid() is not null => pinned to the real invoking actor, overriding whatever the statement supplied; auth.uid() is null (service_role/migrations/seed.sql — a genuinely trusted context, same as every other table using this pattern) => whatever was explicitly supplied is kept, a legitimate system-attributed write.';

revoke execute on function public.adjustment_types_enforce_updated_columns() from public;

create trigger adjustment_types_enforce_updated_columns
  before update on public.adjustment_types
  for each row
  execute function public.adjustment_types_enforce_updated_columns();

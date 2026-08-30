-- ============================================================================
-- 0153: Phase 6 Integrity Patch 6.1 (10/13): adjustment_types table-level
-- lock trigger (item 15) + code/identity immutability + no-delete DB
-- invariant (item 16)
-- ============================================================================
-- Migrations 0001-0152 are unmodified.
--
-- item 15 — the sanctioned writer RPCs (create/update/disable/enable_
-- adjustment_type, 0136) already took the EXCLUSIVE adjustments lock (1006)
-- before writing, but that convention lived ENTIRELY in the RPC body — a
-- trusted direct write (service_role, or any future SECURITY DEFINER
-- function that forgets the convention) could bypass it, since Layer-A RLS
-- only blocks `authenticated`, never a role with BYPASSRLS. This BEFORE
-- STATEMENT trigger makes the lock unconditional: ANY insert/update/delete
-- statement against adjustment_types — through the sanctioned RPCs or not —
-- takes the EXCLUSIVE lock first.
--
-- item 16 — `code` immutability and "no hard delete, ever" were previously
-- pure RPC-level conventions (update_adjustment_type() never accepted a
-- code parameter; no RPC ever issued a DELETE). This migration makes both a
-- real DB invariant that holds even against a trusted direct write:
--   - BEFORE UPDATE: code/created_at/created_by can never change.
--   - BEFORE DELETE: always rejected, unconditionally.
-- ---------------------------------------------------------------------------
grant execute on function public.acquire_adjustments_lock_exclusive() to service_role;
grant execute on function public.acquire_adjustments_lock_shared() to service_role;

create or replace function public.adjustment_types_acquire_lock_before_write()
returns trigger
language plpgsql
as $$
begin
  perform public.acquire_adjustments_lock_exclusive();
  return null;
end;
$$;

comment on function public.adjustment_types_acquire_lock_before_write() is
  'Patch 6.1 item 15 — BEFORE STATEMENT trigger body: takes the EXCLUSIVE adjustments lock (1006) before ANY insert/update/delete statement against adjustment_types, regardless of whether it goes through a sanctioned RPC. Runs as the invoking role (not SECURITY DEFINER) — acquire_adjustments_lock_exclusive() is granted to both authenticated and service_role for this reason.';

create trigger adjustment_types_lock_before_write
  before insert or update or delete on public.adjustment_types
  for each statement
  execute function public.adjustment_types_acquire_lock_before_write();

create or replace function public.adjustment_types_reject_identity_mutation()
returns trigger
language plpgsql
as $$
begin
  if new.code is distinct from old.code then
    raise exception 'رمز نوع التعديل/الخدمة ثابت ولا يمكن تغييره بعد الإنشاء' using errcode = 'P0001';
  end if;
  if new.created_at is distinct from old.created_at then
    raise exception 'تاريخ إنشاء نوع التعديل/الخدمة غير قابل للتعديل' using errcode = 'P0001';
  end if;
  if new.created_by is distinct from old.created_by then
    raise exception 'مُنشئ نوع التعديل/الخدمة غير قابل للتعديل' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.adjustment_types_reject_identity_mutation() is
  'Patch 6.1 item 16 — BEFORE UPDATE FOR EACH ROW: code/created_at/created_by are immutable at the DB level, not merely because no RPC exposes them as parameters. update_adjustment_type()/disable_adjustment_type()/enable_adjustment_type() (0136) never touch these columns, so this never fires against them.';

create trigger adjustment_types_reject_identity_mutation
  before update on public.adjustment_types
  for each row
  execute function public.adjustment_types_reject_identity_mutation();

create or replace function public.adjustment_types_reject_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'أنواع التعديلات/الخدمات لا تُحذف أبدًا — عطّلها بدلًا من ذلك (disable_adjustment_type)' using errcode = 'P0001';
end;
$$;

comment on function public.adjustment_types_reject_delete() is
  'Patch 6.1 item 16 — unconditional DELETE rejection at the DB level, matching "no hard delete, ever" being an actual invariant rather than an RPC convention.';

create trigger adjustment_types_reject_delete
  before delete on public.adjustment_types
  for each row
  execute function public.adjustment_types_reject_delete();

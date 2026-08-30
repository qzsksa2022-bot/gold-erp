-- ============================================================================
-- 0022: Lock roles.is_system (and roles.key) from application users
-- ============================================================================
-- Foundation Hardening 1.2, item 7.
--
-- Gaps closed in 0009's protect_system_role_identity(): it only fires
-- `if tg_op = 'UPDATE' and old.is_system then ...` -- which means:
--  1. INSERT was never covered at all. roles_insert (0010) only requires
--     users.manage_permissions, with no is_system restriction, so an
--     application user holding that permission could directly
--     `insert into roles (key, name_ar, is_system) values (..., true)` and
--     create a brand-new "system" role via a raw REST call.
--  2. UPDATE only guarded rows where old.is_system was ALREADY true. A row
--     with old.is_system = false skips the check entirely, so flipping a
--     custom role's is_system from false to true went completely
--     unguarded -- effectively promoting an arbitrary custom role to
--     "system" status (immune from deletion, implying special trust) with
--     nothing but users.manage_permissions.
--
-- Fix: is_system may only ever become true from a trusted bootstrap context
-- (migrations, seed.sql, direct SQL) -- never via INSERT or UPDATE from an
-- application user, even one holding users.manage_permissions. This is
-- layered ADDITIONALLY beside 0009's protect_system_role_identity(), which
-- keeps doing its existing job (an ALREADY-system row's key/is_system stay
-- immutable, and it cannot be deleted) unchanged.
--
-- Also locks roles.key on UPDATE for every role, system or custom: the app
-- never edits it after creation (src/features/users/roles-actions.ts
-- generates it once at INSERT time; roleFormSchema, what the edit form
-- actually submits, has no key field at all), so there is no legitimate
-- reason a direct REST call should be able to rewrite it either.

create or replace function public.enforce_role_system_identity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if TG_OP = 'INSERT' and new.is_system then
    raise exception 'لا يمكن إنشاء دور نظامي (is_system) من سياق تطبيق -- فقط عبر Migration/Bootstrap موثوق'
      using errcode = 'P0001';
  end if;

  if TG_OP = 'UPDATE' and new.is_system and not old.is_system then
    raise exception 'لا يمكن تحويل دور مخصص إلى دور نظامي (is_system) من سياق تطبيق'
      using errcode = 'P0001';
  end if;

  if TG_OP = 'UPDATE' and new.key is distinct from old.key then
    raise exception 'لا يمكن تغيير مفتاح الدور (key) عبر الواجهة' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.enforce_role_system_identity() is
  'is_system can only ever become true from a trusted bootstrap context (never via INSERT or UPDATE from an application user, even one holding users.manage_permissions) -- closes the gap where 0009''s protect_system_role_identity() only guarded rows that were ALREADY is_system=true. Also locks roles.key from ever changing via UPDATE (the app never needs to). Rows that are already legitimately is_system=true (old.is_system = true, unchanged) still pass through freely, so renaming a seeded system role''s display name stays exactly as allowed as before.';

revoke execute on function public.enforce_role_system_identity() from public;

create trigger roles_enforce_system_identity
  before insert or update on public.roles
  for each row
  execute function public.enforce_role_system_identity();

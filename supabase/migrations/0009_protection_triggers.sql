-- ============================================================================
-- 0009: Integrity/protection triggers
-- ============================================================================
-- These enforce invariants that a column-level RLS policy cannot express on
-- its own. They run regardless of caller (even service-role scripts), so
-- they are the last line of defense for the two most dangerous mistakes in
-- a permission system: locking everyone out, and privilege escalation.

-- 1) Never allow the system to end up with zero active Super Admins.
create or replace function public.protect_last_super_admin()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_super_admin_role_id uuid;
  v_remaining_count int;
begin
  select id into v_super_admin_role_id from public.roles where key = 'super_admin';

  if v_super_admin_role_id is null then
    return coalesce(new, old);
  end if;

  if tg_table_name = 'user_roles' and tg_op = 'DELETE' then
    if old.role_id = v_super_admin_role_id then
      select count(*) into v_remaining_count
      from public.user_roles ur
      join public.profiles p on p.id = ur.user_id
      where ur.role_id = v_super_admin_role_id
        and ur.user_id <> old.user_id
        and p.status = 'active';

      if v_remaining_count = 0 then
        raise exception 'لا يمكن إزالة آخر مستخدم Super Admin نشط في النظام'
          using errcode = 'P0001';
      end if;
    end if;
    return old;
  end if;

  if tg_table_name = 'profiles' and tg_op = 'UPDATE' then
    if old.status = 'active' and new.status = 'suspended' then
      if exists (
        select 1 from public.user_roles
        where user_id = old.id and role_id = v_super_admin_role_id
      ) then
        select count(*) into v_remaining_count
        from public.user_roles ur
        join public.profiles p on p.id = ur.user_id
        where ur.role_id = v_super_admin_role_id
          and ur.user_id <> old.id
          and p.status = 'active';

        if v_remaining_count = 0 then
          raise exception 'لا يمكن تعطيل آخر مستخدم Super Admin نشط في النظام'
            using errcode = 'P0001';
        end if;
      end if;
    end if;
    return new;
  end if;

  return coalesce(new, old);
end;
$$;

create trigger user_roles_protect_last_super_admin
  before delete on public.user_roles
  for each row
  execute function public.protect_last_super_admin();

create trigger profiles_protect_last_super_admin
  before update of status on public.profiles
  for each row
  execute function public.protect_last_super_admin();

-- 2) Only an existing Super Admin can grant the super_admin role to someone
-- else (prevents a lower-privileged admin from escalating themselves or a
-- colleague to Super Admin even if they somehow gained users.manage_permissions).
create or replace function public.prevent_super_admin_privilege_escalation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role_key text;
begin
  -- The trusted server-only service-role connection (BYPASSRLS) is exempt:
  -- it is used only by src/lib/supabase/admin.ts (never shipped to the
  -- browser) for the initial Super Admin bootstrap script and other
  -- privileged backend operations. RLS policies don't apply to it, but
  -- triggers still fire regardless of BYPASSRLS, so we exempt it explicitly
  -- here rather than accidentally locking out the bootstrap flow. We check
  -- auth.role() (reads the request.jwt GUC) rather than current_user,
  -- because current_user is reassigned to the function OWNER while inside
  -- a SECURITY DEFINER function and would never match 'service_role' here.
  if auth.role() = 'service_role' then
    return new;
  end if;

  select key into v_role_key from public.roles where id = new.role_id;

  if v_role_key = 'super_admin' and not public.is_super_admin(auth.uid()) then
    raise exception 'فقط مستخدم Super Admin يمكنه منح دور Super Admin لمستخدم آخر'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

create trigger user_roles_prevent_privilege_escalation
  before insert on public.user_roles
  for each row
  execute function public.prevent_super_admin_privilege_escalation();

-- 3) System (seeded) roles keep a stable identity: key and is_system cannot
-- be changed, and the row cannot be deleted (defense in depth alongside the
-- "not is_system" clause in the DELETE RLS policy).
create or replace function public.protect_system_role_identity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and old.is_system then
    if new.key <> old.key or new.is_system <> old.is_system then
      raise exception 'لا يمكن تعديل هوية دور نظامي (key / is_system)'
        using errcode = 'P0001';
    end if;
  end if;

  if tg_op = 'DELETE' and old.is_system then
    raise exception 'لا يمكن حذف دور نظامي أساسي'
      using errcode = 'P0001';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger roles_protect_system_identity_update
  before update on public.roles
  for each row
  execute function public.protect_system_role_identity();

create trigger roles_protect_system_identity_delete
  before delete on public.roles
  for each row
  execute function public.protect_system_role_identity();

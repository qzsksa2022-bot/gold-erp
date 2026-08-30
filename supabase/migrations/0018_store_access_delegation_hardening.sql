-- ============================================================================
-- 0018: Close store-scope privilege escalation + atomic store-access replace
-- ============================================================================
-- Foundation Hardening 1.2, items 1 and 9. Bundled together because item 9's
-- atomic replace RPC must obey exactly the same delegation rules item 1
-- introduces -- it does, "for free", because it is SECURITY INVOKER and
-- issues ordinary INSERT/DELETE statements on user_store_access, so every
-- trigger below fires for it exactly as it would for a direct REST call.
--
-- Gaps closed (found by a second independent review after 1.1):
--  1. A user holding only users.edit could change their OWN
--     store_access_scope/default_store_id (RLS's profiles_update policy
--     authorizes the whole row for users.edit, and 0014's column-lock
--     trigger lets users.edit through unconditionally) -- i.e. a
--     non-Super-Admin could grant themselves scope='all' simply by editing
--     their own profile.
--  2. Nothing stopped a user holding users.manage_permissions from
--     inserting/deleting THEIR OWN user_store_access rows (0013's
--     self-modification triggers only cover user_roles and
--     user_permission_overrides, not user_store_access).
--  3. A user.manage_permissions holder could grant ANY other user access to
--     ANY store, including stores the granter themselves cannot operate --
--     i.e. delegation was unbounded, letting a store-scoped admin hand out
--     access wider than their own.
--  4. Nothing distinguished "change my own store scope" from "change my
--     own display name" -- both were gated by the same broad users.edit.

-- ---------------------------------------------------------------------------
-- New permission: users.manage_store_access. Store-scope columns
-- (store_access_scope, default_store_id) and user_store_access grants are a
-- security boundary in their own right (they decide what business data a
-- user will be able to touch once Sales/Reports exist) and should not
-- piggyback on users.edit (general profile editing) any more than
-- sensitive-permission management piggybacks on it. Inserted directly here
-- (idempotent, ON CONFLICT DO NOTHING) rather than only in seed.sql, so a
-- database that already ran 0001-0017 gets it just by applying this one new
-- migration -- re-running seed.sql is not required (though seed.sql is
-- updated too, for a consistent fresh install).
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('users.manage_store_access', 'users', 'إدارة نطاق وصول المستخدم للمتاجر (Store Scope)', 'Manage a user''s store access scope')
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r, public.permissions p
where r.key = 'super_admin' and p.key = 'users.manage_store_access'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r, public.permissions p
where r.key = 'admin' and p.key = 'users.manage_store_access'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- RLS: additive permissive policies. Postgres OR-combines multiple
-- permissive policies for the same command on the same table, so these
-- ADD an alternate path for users.manage_store_access holders without
-- touching 0010's existing profiles_update / user_store_access_insert /
-- user_store_access_delete policies at all. Row-level authorization is
-- still only half the story -- the triggers below do the column/escalation
-- enforcement RLS cannot express.
-- ---------------------------------------------------------------------------
create policy profiles_update_store_access on public.profiles
  for update to authenticated
  using (public.has_permission('users.manage_store_access'))
  with check (public.has_permission('users.manage_store_access'));

create policy user_store_access_insert_scoped on public.user_store_access
  for insert to authenticated
  with check (public.has_permission('users.manage_store_access'));

create policy user_store_access_delete_scoped on public.user_store_access
  for delete to authenticated
  using (public.has_permission('users.manage_store_access'));

-- ---------------------------------------------------------------------------
-- Trigger 1: profiles store-scope column lock.
--  * store_access_scope / default_store_id may only change when the actor
--    holds users.manage_store_access -- holding users.edit alone is no
--    longer sufficient (closes gap 1 and gap 4). This runs independently of
--    0014's enforce_profile_update_column_authorization, which still
--    governs every OTHER column exactly as before; a users.edit holder
--    passes 0014 unconditionally but can now still be stopped here
--    specifically for these two columns.
--  * Self-escalation: a non-Super-Admin can never change these two columns
--    on their OWN row, even if they hold users.manage_store_access --
--    mirrors the self-modification pattern 0013 established for
--    user_roles/user_permission_overrides.
--  * scope = 'all' is the most powerful value (every active store, no
--    per-store review needed) -- the most secure rule is that only a
--    Super Admin may ever set it for anyone. A manage_store_access holder
--    who is not a Super Admin can move someone into/within 'single'/
--    'multiple' but never assign the broadest scope.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_store_scope_authorization()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if new.store_access_scope is distinct from old.store_access_scope
    or new.default_store_id is distinct from old.default_store_id
  then
    if new.id = auth.uid() and not public.is_super_admin(auth.uid()) then
      raise exception 'لا يمكنك تعديل نطاق وصولك للمتاجر (Store Scope) الخاص بحسابك أنت'
        using errcode = 'P0001';
    end if;

    if not public.has_permission('users.manage_store_access') then
      raise exception 'يتطلب تعديل نطاق وصول المتاجر صلاحية users.manage_store_access'
        using errcode = 'P0001';
    end if;

    if new.store_access_scope = 'all' and not public.is_super_admin(auth.uid()) then
      raise exception 'فقط Super Admin يمكنه ضبط نطاق وصول لكل المتاجر (all) لمستخدم'
        using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

comment on function public.enforce_store_scope_authorization() is
  'Store-scope columns (store_access_scope, default_store_id) require users.manage_store_access specifically -- users.edit alone is not enough. Blocks self-escalation, and restricts scope=all to Super Admin regardless of who holds manage_store_access. Independent of and additional to 0014''s general edit/disable column lock.';

revoke execute on function public.enforce_store_scope_authorization() from public;

create trigger profiles_enforce_store_scope_authorization
  before update on public.profiles
  for each row
  execute function public.enforce_store_scope_authorization();

-- ---------------------------------------------------------------------------
-- Trigger 2: user_store_access self-modification + delegation limit.
--  * Self-block: a non-Super-Admin can never insert/delete their OWN
--    user_store_access rows (closes gap 2) -- granting/revoking your own
--    store access is exactly the "user_roles self-modification" pattern
--    0013 already blocks for roles/overrides, just missing for this table.
--  * Delegation limit: granting someone ELSE access to a store requires
--    the ACTOR themselves to currently be able to operate that store
--    (public.user_operable_store_ids(auth.uid())) -- unless the actor is a
--    Super Admin. You cannot hand out access wider than your own, the same
--    "cannot grant what you don't hold" principle 0013 applies to
--    permissions, applied here to stores (closes gap 3).
-- ---------------------------------------------------------------------------
create or replace function public.enforce_store_access_delegation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_target_user uuid := coalesce(new.user_id, old.user_id);
  v_store_id uuid := coalesce(new.store_id, old.store_id);
begin
  if public.is_trusted_bootstrap_context() then
    return coalesce(new, old);
  end if;

  if v_target_user = auth.uid() and not public.is_super_admin(auth.uid()) then
    raise exception 'لا يمكنك تعديل وصولك الخاص للمتاجر (user_store_access) بنفسك'
      using errcode = 'P0001';
  end if;

  if TG_OP = 'INSERT' and not public.is_super_admin(auth.uid()) then
    if not exists (
      select 1 from public.user_operable_store_ids(auth.uid()) sid where sid = v_store_id
    ) then
      raise exception 'لا يمكنك منح وصول لمتجر لا تملك أنت نفسك صلاحية العمل عليه'
        using errcode = 'P0001';
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

comment on function public.enforce_store_access_delegation() is
  'Blocks a non-Super-Admin from granting/revoking their OWN user_store_access rows, and from delegating access to a store outside their own operable set. Applies regardless of which RLS policy (users.manage_permissions or users.manage_store_access) let the INSERT/DELETE through.';

revoke execute on function public.enforce_store_access_delegation() from public;

create trigger user_store_access_enforce_delegation
  before insert or delete on public.user_store_access
  for each row
  execute function public.enforce_store_access_delegation();

-- ---------------------------------------------------------------------------
-- Item 9: atomic store-access replacement.
--
-- The app previously computed a diff client-side and issued a separate
-- insert() then delete() (src/features/users/actions.ts,
-- setUserStoreAccessAction) -- two independent round trips, so a failure
-- between them (a delegation-limit rejection on one store mid-batch, a
-- dropped connection) could leave a user with a half-applied set of store
-- grants. This function computes the same diff and applies it as ONE
-- function call: a single plpgsql function invoked as one top-level
-- statement runs in one implicit transaction, so any exception anywhere
-- inside (including a trigger raised by enforce_store_access_delegation
-- above on any single store in the batch) rolls back the ENTIRE call --
-- either every change lands, or none does.
--
-- Deliberately SECURITY INVOKER (the default -- no "security definer"
-- clause below): it must run AS the calling authenticated user so RLS and
-- every user_store_access trigger (delegation limit, self-block, the
-- active-store check from 0012, the audit trigger from 0016) apply
-- exactly as they would to a direct REST call -- this function is a
-- transactional wrapper around the same authorized path, not a privilege
-- escalation around it.
-- ---------------------------------------------------------------------------
create or replace function public.replace_user_store_access(p_user_id uuid, p_store_ids uuid[])
returns void
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_to_add uuid[];
  v_to_remove uuid[];
begin
  select coalesce(array_agg(sid), '{}') into v_to_add
  from (
    select distinct sid from unnest(coalesce(p_store_ids, '{}'::uuid[])) as sid
    except
    select store_id from public.user_store_access where user_id = p_user_id
  ) t;

  select coalesce(array_agg(store_id), '{}') into v_to_remove
  from (
    select store_id from public.user_store_access where user_id = p_user_id
    except
    select distinct sid from unnest(coalesce(p_store_ids, '{}'::uuid[])) as sid
  ) t;

  if array_length(v_to_remove, 1) > 0 then
    delete from public.user_store_access
      where user_id = p_user_id and store_id = any(v_to_remove);
  end if;

  if array_length(v_to_add, 1) > 0 then
    insert into public.user_store_access (user_id, store_id, created_by)
    select p_user_id, sid, auth.uid()
    from unnest(v_to_add) as sid;
  end if;
end;
$$;

comment on function public.replace_user_store_access(uuid, uuid[]) is
  'Atomically replaces a user''s user_store_access grants with exactly p_store_ids: all-or-nothing (one function call = one implicit transaction). SECURITY INVOKER by design -- runs as the calling user, so RLS and every user_store_access trigger (delegation limit, self-block, active-store check, audit logging) apply exactly as for a direct REST call. Replaces the two-step insert()-then-delete() src/features/users/actions.ts used to do client-side.';

revoke execute on function public.replace_user_store_access(uuid, uuid[]) from public;
grant execute on function public.replace_user_store_access(uuid, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- Trigger-interaction fix: 0014's enforce_profile_update_column_authorization
-- fires BEFORE this migration's profiles_enforce_store_scope_authorization
-- (alphabetically, "column_authorization" < "store_scope_authorization"), and
-- 0014's fail-closed final branch unconditionally rejects any actor who
-- holds neither users.edit nor users.disable -- it has no knowledge of the
-- new users.manage_store_access path this migration's own RLS policy
-- (profiles_update_store_access, above) just opened up. Without this fix, a
-- manage_store_access-only actor's legitimate store-scope UPDATE would be
-- wrongly rejected by 0014 with the wrong ("لا تملك صلاحية تعديل بيانات
-- المستخدمين") error message before ever reaching
-- enforce_store_scope_authorization's own, more specific self-escalation /
-- scope='all' logic above.
--
-- Re-defined here (0014's file itself is NOT edited, per the "never touch a
-- shipped migration" rule) with a third branch, mirroring the existing
-- disable-only "only this column may change" pattern: a
-- users.manage_store_access holder (without users.edit/users.disable) may
-- pass this gate ONLY when the changed columns are limited to
-- store_access_scope / default_store_id. The finer rules -- self-escalation
-- block, scope='all' restricted to Super Admin -- are NOT repeated here;
-- they are enforced independently by enforce_store_scope_authorization
-- above, which fires immediately after this trigger for the same UPDATE.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_profile_update_column_authorization()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  -- Full edit rights: no column restriction.
  if public.has_permission('users.edit') then
    return new;
  end if;

  -- Disable-only rights: every column except status (and the
  -- system-maintained updated_at/updated_by) must be byte-for-byte
  -- unchanged.
  if public.has_permission('users.disable') then
    if new.full_name is distinct from old.full_name
      or new.email is distinct from old.email
      or new.default_store_id is distinct from old.default_store_id
      or new.store_access_scope is distinct from old.store_access_scope
      or new.created_by is distinct from old.created_by
      or new.created_at is distinct from old.created_at
    then
      raise exception 'صلاحية تعطيل/تفعيل المستخدم تسمح فقط بتغيير حالة الحساب (status)، وليس بقية البيانات'
        using errcode = 'P0001';
    end if;
    return new;
  end if;

  -- Store-scope-only rights (0018): store_access_scope / default_store_id
  -- may change, nothing else -- self-escalation and scope='all' are gated
  -- separately by enforce_store_scope_authorization, not repeated here.
  if public.has_permission('users.manage_store_access') then
    if new.full_name is distinct from old.full_name
      or new.email is distinct from old.email
      or new.status is distinct from old.status
      or new.created_by is distinct from old.created_by
      or new.created_at is distinct from old.created_at
    then
      raise exception 'صلاحية إدارة نطاق وصول المتاجر تسمح فقط بتغيير نطاق الوصول (Store Scope)، وليس بقية بيانات المستخدم'
        using errcode = 'P0001';
    end if;
    return new;
  end if;

  -- Neither permission: RLS's USING/WITH CHECK should already have rejected
  -- this before the trigger ever runs, but fail closed regardless in case a
  -- future policy change ever loosens that without updating this trigger.
  raise exception 'لا تملك صلاحية تعديل بيانات المستخدمين' using errcode = 'P0001';
end;
$$;

comment on function public.enforce_profile_update_column_authorization() is
  'Re-defined by 0018 (originally 0009/0014) to add a third branch: users.manage_store_access holders (without users.edit/users.disable) may change store_access_scope/default_store_id only. Fires before 0018''s own enforce_store_scope_authorization trigger, which independently enforces self-escalation and scope=all restrictions for the same columns.';

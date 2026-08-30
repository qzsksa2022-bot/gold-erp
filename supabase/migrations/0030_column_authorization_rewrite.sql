-- ============================================================================
-- 0030: Rewrite column authorization as strict per-column-group permissions
-- ============================================================================
-- Foundation Hardening 1.3, item 3. Ships as a NEW migration after 0029
-- (needs profiles.provisioned_at and the app.finalize_provisioning flag both
-- introduced there).
--
-- 0014's enforce_profile_update_column_authorization() (last redefined by
-- 0018) has a "first matching broad permission wins" shape:
--   if has_permission('users.edit') then return new;   -- NO column
--                                                          restriction at all
--   if has_permission('users.disable') then <status-only check>; return new;
--   if has_permission('users.manage_store_access') then <store-only check>; return new;
--
-- The first branch is the bug a second independent review found: a
-- users.edit holder can change ANY column, including `status` -- which
-- nullifies the entire point of users.disable being a narrower, separate
-- permission (e.g. a support-tier admin who should be able to suspend/
-- reactivate accounts but never rename someone or change their own
-- colleagues' data). The equivalent bug exists for stores: stores.edit lets
-- an actor change `status` too, nullifying stores.disable. (Store-scope
-- columns were already independently protected by 0018's separate
-- enforce_store_scope_authorization trigger, which fires regardless of what
-- this trigger allows -- that part was not actually broken, but this
-- rewrite still stops treating users.edit as a shortcut around it, per the
-- explicit "no 'if edit, let everything through' branch" requirement.)
--
-- Fix: replace the "first permission wins, then bypass everything else"
-- shape with independent per-group checks. Each column group requires its
-- OWN permission to change, and a single UPDATE spanning more than one group
-- requires the union of all the relevant permissions -- there is no shortcut
-- permission that authorizes another group's columns.
--
-- Column groups:
--   profiles: full_name                       -> users.edit
--             status                          -> users.disable
--             store_access_scope/default_store_id -> users.manage_store_access
--             (email, provisioned_at, created_*/updated_* are governed
--              independently by 0021/0029 and are not re-checked here)
--   stores:   code/name_ar/name_en/logo_url/description -> stores.edit
--             status                          -> stores.disable
--             (created_*/updated_* governed independently by 0021)
--
-- finalize_new_user_profile() legitimately changes full_name + status +
-- store_access_scope + default_store_id together, gated only by its own
-- users.create check -- not by whichever of users.edit/users.disable/
-- users.manage_store_access the calling admin happens to also hold. It
-- reuses the SAME app.finalize_provisioning transaction-local flag 0029
-- introduced (see that migration's comment for why the flag can never leak
-- across statements/transactions) to bypass this trigger's per-column
-- checks entirely for its own single UPDATE -- while 0018's dedicated
-- enforce_store_scope_authorization trigger (CREATE OR REPLACE'd below to
-- add the same, narrowly-scoped bypass) still independently enforces the
-- self-escalation block and the scope='all'-requires-Super-Admin /
-- default_store_id-operable-range rules even during finalize, since those
-- are exactly the "harder invariants that stay universal regardless of
-- caller" this design deliberately does not weaken.

-- ---------------------------------------------------------------------------
-- profiles: independent per-group checks, no group implies another.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_profile_update_column_authorization()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_changed_edit boolean;
  v_changed_disable boolean;
  v_changed_store boolean;
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  -- finalize_new_user_profile()'s own trusted, users.create-gated write:
  -- bypasses the per-column checks below entirely. It does NOT bypass
  -- 0021's email immutability, 0029's provisioned_at immutability/
  -- activation-invariant, or 0025/0018's store-scope self-escalation /
  -- scope=all / operable-range rules -- those are separate triggers this
  -- flag is not referenced by.
  if coalesce(current_setting('app.finalize_provisioning', true), 'off') = 'on' then
    return new;
  end if;

  v_changed_edit := new.full_name is distinct from old.full_name;
  v_changed_disable := new.status is distinct from old.status;
  v_changed_store := new.store_access_scope is distinct from old.store_access_scope
    or new.default_store_id is distinct from old.default_store_id;

  if v_changed_edit and not public.has_permission('users.edit') then
    raise exception 'يتطلب تعديل بيانات المستخدم (الاسم) صلاحية users.edit'
      using errcode = 'P0001';
  end if;

  if v_changed_disable and not public.has_permission('users.disable') then
    raise exception 'يتطلب تغيير حالة الحساب (تفعيل/تعطيل) صلاحية users.disable على وجه التحديد'
      using errcode = 'P0001';
  end if;

  if v_changed_store and not public.has_permission('users.manage_store_access') then
    raise exception 'يتطلب تعديل نطاق وصول المتاجر صلاحية users.manage_store_access على وجه التحديد'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.enforce_profile_update_column_authorization() is
  '0030: strict per-column-group authorization -- each of {full_name}, {status}, {store_access_scope,default_store_id} independently requires its own permission (users.edit / users.disable / users.manage_store_access respectively); an UPDATE spanning more than one group requires all of the relevant permissions together. No permission is a shortcut for another group''s columns any more (closes the "users.edit implies status too" / "users.disable... wait no, that direction was never wrong" bug -- specifically the users.edit-implies-everything bypass). email/provisioned_at/system-managed columns are governed independently by 0021/0029 and intentionally not re-checked here. finalize_new_user_profile() bypasses this trigger via the app.finalize_provisioning transaction-local flag (0029) for its own single, independently users.create-gated UPDATE.';

-- ---------------------------------------------------------------------------
-- stores: same principle, two groups (no store-scope group -- stores have no
-- analogous concept).
-- ---------------------------------------------------------------------------
create or replace function public.enforce_store_update_column_authorization()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_changed_edit boolean;
  v_changed_disable boolean;
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  v_changed_edit := new.code is distinct from old.code
    or new.name_ar is distinct from old.name_ar
    or new.name_en is distinct from old.name_en
    or new.logo_url is distinct from old.logo_url
    or new.description is distinct from old.description;
  v_changed_disable := new.status is distinct from old.status;

  if v_changed_edit and not public.has_permission('stores.edit') then
    raise exception 'يتطلب تعديل بيانات المتجر صلاحية stores.edit'
      using errcode = 'P0001';
  end if;

  if v_changed_disable and not public.has_permission('stores.disable') then
    raise exception 'يتطلب تغيير حالة المتجر (تفعيل/تعطيل) صلاحية stores.disable على وجه التحديد'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.enforce_store_update_column_authorization() is
  '0030: strict per-column-group authorization, same principle as profiles -- {code,name_ar,name_en,logo_url,description} requires stores.edit, {status} requires stores.disable specifically; stores.edit is no longer a shortcut that also authorizes status changes. Combined changes require both permissions.';

-- ---------------------------------------------------------------------------
-- enforce_store_scope_authorization(): CREATE OR REPLACE again (0018 then
-- 0025) to add the SAME app.finalize_provisioning bypass, but ONLY around
-- the users.manage_store_access requirement -- self-escalation, scope='all',
-- and the 0025 default_store_id-operable-range checks stay fully active
-- even during finalize, per this migration's header comment.
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

    if coalesce(current_setting('app.finalize_provisioning', true), 'off') <> 'on' then
      if not public.has_permission('users.manage_store_access') then
        raise exception 'يتطلب تعديل نطاق وصول المتاجر صلاحية users.manage_store_access'
          using errcode = 'P0001';
      end if;
    end if;

    if new.store_access_scope = 'all' and not public.is_super_admin(auth.uid()) then
      raise exception 'فقط Super Admin يمكنه ضبط نطاق وصول لكل المتاجر (all) لمستخدم'
        using errcode = 'P0001';
    end if;

    if new.default_store_id is distinct from old.default_store_id
      and new.default_store_id is not null
      and not public.is_super_admin(auth.uid())
    then
      if not exists (
        select 1 from public.user_operable_store_ids(auth.uid()) sid where sid = new.default_store_id
      ) then
        raise exception 'لا يمكنك تعيين متجر افتراضي لمستخدم آخر لا تملك أنت نفسك صلاحية العمل عليه'
          using errcode = 'P0001';
      end if;
    end if;
  end if;

  return new;
end;
$$;

comment on function public.enforce_store_scope_authorization() is
  '0030: adds the app.finalize_provisioning bypass (0029) around the users.manage_store_access requirement ONLY, so finalize_new_user_profile() can set a brand-new user''s initial store scope under its own users.create gate without also needing users.manage_store_access -- self-escalation (n/a for finalize, target is never the acting admin), scope=all-requires-Super-Admin, and the 0025 default_store_id-operable-range check remain fully enforced even during finalize.';

-- ============================================================================
-- 0034: Complete store-scope delegation for store_access_scope-only changes
-- ============================================================================
-- Foundation Hardening 1.4, item 3. Ships as a NEW migration after 0033.
--
-- 0025 closed the case where changing default_store_id itself points outside
-- the actor's own operable range. A second independent review found a
-- narrower but real gap: default_store_id is only PART of what determines a
-- profile's actual (effective) store access -- store_access_scope decides
-- HOW default_store_id / user_store_access combine into that effective set
-- (see user_operable_store_ids(), 0017/0031), and neither 0018 nor 0025 ever
-- checked what happens to the EFFECTIVE set when ONLY store_access_scope
-- changes and default_store_id is left untouched.
--
-- Concretely: a target already has default_store_id = C (say from an
-- earlier 'single'-scope assignment, or a leftover user_store_access grant
-- from an earlier 'multiple'-scope stint) where C is OUTSIDE actor A's own
-- operable range (A operates only stores A and B). If actor A flips the
-- target's store_access_scope from 'single' to 'multiple' (or back), C can
-- silently enter or leave the target's EFFECTIVE store access -- e.g.
-- flipping into 'multiple' surfaces whatever user_store_access rows already
-- exist for that target (possibly including C, from history), or flipping a
-- 'multiple'-scope target with a C grant back to 'single' with
-- default_store_id already = C makes C the target's ENTIRE access -- all
-- without default_store_id itself ever changing, so 0025's own check never
-- fires for either direction.
--
-- Fix: compute the actual set of stores this profile would operate BEFORE
-- and AFTER the pending change (the same three-branch logic
-- user_operable_store_ids() uses, but parameterized so it can be evaluated
-- for hypothetical NEW values that have not been written to the row yet),
-- diff the two sets, and require every store that ENTERS or LEAVES that
-- effective set to be within the actor's own operable range -- unless the
-- actor is Super Admin.
--
-- NOTE (found while testing): the "changed" CTE below parenthesizes each
-- EXCEPT explicitly -- (A except B) union (B except A) -- rather than
-- writing "A except B union B except A" bare. UNION and EXCEPT share the
-- same precedence in SQL and are LEFT-ASSOCIATIVE, so the bare, unparenthesized
-- form parses as "((A except B) union B) except A", not the intended
-- "(A except B) union (B except A)" symmetric difference. Concretely, with
-- old_effective empty and new_effective = {C} (a target entering a store),
-- the bare form evaluates to "(({C} except {}) union {}) except {C}" = {}
-- -- the very entry the check exists to catch silently disappears. Caught
-- only because the "entering" direction (027, 27c below) was tested
-- separately from the "leaving" direction (025, 27a) -- the two are not
-- symmetric under left-associative evaluation, even though the underlying
-- set logic is. This subsumes 0025's default_store_id check for the
-- 'single'-scope case (a changed default_store_id under scope='single'
-- always shows up as an entry in the diff) while additionally covering the
-- scope-only-change case 0025 never considered. 0025's own check is left in
-- place regardless (defense in depth, and it also still correctly
-- constrains default_store_id even under scope='multiple'/'all', where it
-- does not by itself affect the effective set but is kept consistent as a
-- UI/data-hygiene invariant per 0025's own header comment).
--
-- Deliberately NOT bypassed by the app.finalize_provisioning flag: mirrors
-- 0030's own explicit design choice to keep 0025's default_store_id-operable
-- -range check active even during finalize -- this is the same class of
-- invariant (which store(s) can this specific users.create-holding actor
-- cause a brand-new user to actually operate), just computed completely
-- instead of only through default_store_id.

-- ---------------------------------------------------------------------------
-- Helper: the set of ACTIVE stores a hypothetical (scope, default_store_id,
-- user_id) combination would resolve to -- mirrors user_operable_store_ids()
-- (0017/0031) branch-for-branch, but takes scope/default_store_id as
-- explicit parameters instead of reading them from the CURRENT row in
-- public.profiles. Needed because this is evaluated from inside a BEFORE
-- UPDATE trigger for BOTH the OLD and the not-yet-written NEW values of the
-- very row being updated -- a lookup by id could only ever see the OLD
-- version. user_store_access rows themselves are read live (this trigger
-- never modifies that table, so the OLD and NEW evaluations share the same
-- underlying grants -- only scope/default_store_id, sourced from the
-- trigger's OLD/NEW record, differ between the two calls). Not fail-closed
-- on account status the way user_operable_store_ids() is (0031) -- this is a
-- pure structural resolver used to diff two hypothetical sets, not to
-- authorize a session.
-- ---------------------------------------------------------------------------
create or replace function public.resolve_operable_stores(p_scope text, p_default_store_id uuid, p_user_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id from public.stores
  where status = 'active'
    and (
      p_scope = 'all'
      or (p_scope = 'single' and id = p_default_store_id)
      or (p_scope = 'multiple' and id in (
        select store_id from public.user_store_access where user_id = p_user_id
      ))
    );
$$;

comment on function public.resolve_operable_stores(text, uuid, uuid) is
  '0034: same active-store resolution logic as user_operable_store_ids(), but takes scope/default_store_id as explicit parameters instead of looking them up by id -- lets enforce_store_scope_authorization() compute a profile''s hypothetical effective-access set for OLD and NEW values inside its own BEFORE UPDATE trigger.';

revoke execute on function public.resolve_operable_stores(text, uuid, uuid) from public;

-- ---------------------------------------------------------------------------
-- enforce_store_scope_authorization(): CREATE OR REPLACE again (0018, 0025,
-- 0030) to add the effective-access diff check.
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

    -- 0034: full effective-access diff -- catches store_access_scope-only
    -- changes (default_store_id untouched) that still move a store into or
    -- out of the target's actual operable set.
    if not public.is_super_admin(auth.uid()) then
      if exists (
        with old_effective as (
          select store_id from public.resolve_operable_stores(old.store_access_scope, old.default_store_id, old.id) store_id
        ), new_effective as (
          select store_id from public.resolve_operable_stores(new.store_access_scope, new.default_store_id, new.id) store_id
        ), changed as (
          (select store_id from new_effective except select store_id from old_effective)
          union
          (select store_id from old_effective except select store_id from new_effective)
        )
        select 1 from changed
        where changed.store_id not in (select sid from public.user_operable_store_ids(auth.uid()) sid)
      ) then
        raise exception 'هذا التغيير سيُدخل أو يُخرج متجرًا من الوصول الفعلي لهذا المستخدم، وأنت لا تملك صلاحية العمل على ذلك المتجر'
          using errcode = 'P0001';
      end if;
    end if;
  end if;

  return new;
end;
$$;

comment on function public.enforce_store_scope_authorization() is
  '0034: adds the full before/after EFFECTIVE-access diff (via resolve_operable_stores) on top of 0018/0025/0030''s checks -- self-escalation block, users.manage_store_access requirement (bypassable only by finalize_new_user_profile()''s transaction-local flag), scope=all restricted to Super Admin, default_store_id itself restricted to the actor''s own operable range, and now: ANY store entering or leaving the target''s actual effective access (computed from the full scope/default_store_id/user_store_access combination, not just default_store_id) must be within the actor''s own operable range unless the actor is Super Admin. Catches store_access_scope-only changes 0025 could not.';

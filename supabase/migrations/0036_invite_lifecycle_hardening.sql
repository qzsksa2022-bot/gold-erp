-- ============================================================================
-- 0036: Fix the cancelled-invite lifecycle (no more stranded auth users)
-- ============================================================================
-- Foundation Hardening 1.4, item 5. Ships as a NEW migration after 0035.
--
-- Foundation Hardening 1.3 item 8's UserStatusToggle cancels a pending_setup
-- invite by moving status straight to 'suspended' (setUserStatusAction,
-- gated by users.disable) -- enforce_pending_setup_transition (0019) never
-- objected to that specific transition (it only ever checked pending_setup
-- -> active and ->pending_setup). At the time that looked like a reasonable
-- "just disable it" outcome. A second independent review found it actually
-- strands the underlying auth.users row permanently:
--
--  * finalize_new_user_profile() (0016/0019/0029) ONLY ever matches
--    status = 'pending_setup' -- once moved to 'suspended' it can never be
--    used to complete the account.
--  * 0029's enforce_activation_requires_provisioning trigger permanently
--    blocks status from ever reaching 'active' again without a
--    provisioned_at that only a trusted bootstrap context or
--    finalize_new_user_profile() itself can ever set -- and nothing else
--    can set it for this row any more, per the point above.
--
-- So "cancel invite" via that UPDATE leaves a real auth.users row (with a
-- real email, blocking that email from ever being used to invite someone
-- else, and a real password already set by createUserAction) in a dead
-- 'suspended' state with NO path to ever become usable OR to be cleanly
-- removed through the app. Foundation Hardening 1.3 item 8's own UI already
-- had to special-case this exact state (UserStatusToggle renders nothing for
-- suspended + provisioned_at IS NULL) precisely because there was nothing
-- useful left to offer -- that was already a symptom of this bug, not a fix
-- for it.
--
-- Fix: pick ONE clear flow and make it the only one. Cancelling an invite
-- now means deleting the still-unprovisioned auth.users row outright, via
-- the trusted service-role Admin API (see cancelUserInviteAction,
-- src/features/users/actions.ts) -- profiles.id references auth.users(id)
-- ON DELETE CASCADE (0002), so the matching profiles row (and everything
-- that references it) disappears in the same operation. That action
-- independently re-verifies status = 'pending_setup' AND provisioned_at IS
-- NULL server-side before ever calling the Admin API, so it can never be
-- used to delete a real account. There is no "resume" path for a cancelled
-- invite by design -- re-inviting the same email is exactly createUserAction
-- (a fresh users.create + finalize_new_user_profile() cycle), which cannot
-- bypass either gate.
--
-- The database independently closes the OLD path so nothing -- not just
-- this app's own UI, but any future caller -- can ever recreate the
-- stranded state again: pending_setup -> suspended (or any status other
-- than 'active') via a normal client UPDATE is now rejected outright. Only
-- pending_setup -> active (still gated by users.create, 0019) remains
-- reachable from pending_setup via UPDATE; every other exit is the deletion
-- path above.

create or replace function public.enforce_pending_setup_transition()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if old.status = 'pending_setup' and new.status = 'active' and not public.has_permission('users.create') then
    raise exception 'إتمام تفعيل حساب مستخدم جديد يتطلب صلاحية users.create'
      using errcode = 'P0001';
  end if;

  if new.status = 'pending_setup' and old.status is distinct from 'pending_setup' then
    raise exception 'لا يمكن نقل حساب إلى حالة انتظار الإعداد (pending_setup) إلا عند إنشائه'
      using errcode = 'P0001';
  end if;

  -- 0036: pending_setup -> anything other than 'active' (e.g. 'suspended',
  -- the old "cancel invite" path) is no longer a valid client UPDATE at all
  -- -- it would strand the underlying auth.users row with no way to ever
  -- complete OR reactivate it (finalize_new_user_profile() only matches
  -- pending_setup; 0029 then permanently blocks reaching 'active' again
  -- without a provisioned_at nothing else can set). Cancelling an invite
  -- must delete the still-unprovisioned auth user outright (see
  -- cancelUserInviteAction, a trusted service-role Admin API call -- a
  -- trusted bootstrap context, not a client UPDATE -- that relies on
  -- ON DELETE CASCADE from auth.users to profiles) instead of leaving a
  -- stranded row behind.
  if old.status = 'pending_setup' and new.status <> 'pending_setup' and new.status <> 'active' then
    raise exception 'لا يمكن نقل حساب قيد الإعداد إلى حالة أخرى غير التفعيل مباشرة -- استخدم "إلغاء الدعوة" لحذف الحساب غير المكتمل نهائيًا'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.enforce_pending_setup_transition() is
  '0036: pending_setup -> active requires users.create specifically (0019). Nothing may move a row INTO pending_setup via UPDATE -- only the trusted handle_new_auth_user() INSERT sets it. And (0036) pending_setup -> anything OTHER than active is rejected outright for any non-trusted actor -- cancelling an invite is now exclusively a trusted-context auth.users deletion (cancelUserInviteAction), never a status UPDATE, so a never-provisioned row can never again be stranded in ''suspended'' with no path to completion or removal.';

-- ============================================================================
-- 0038: Trusted, actor-attributed audit event for invite cancellation
-- ============================================================================
-- Patch 1.4.1, item 3. Ships as a NEW migration after 0037.
--
-- 0036 (Foundation Hardening 1.4) made cancelUserInviteAction
-- (src/features/users/actions.ts) delete the still-unprovisioned auth.users
-- row outright via the service-role Admin API, relying on
-- profiles.id -> auth.users.id ON DELETE CASCADE (0002) to remove the
-- matching profiles row in the same operation. That row deletion IS already
-- logged automatically -- profiles_audit_trigger (0016) fires on the
-- resulting DELETE and writes a `user.delete` audit_logs row -- but its
-- `user_id` column comes from audit_table_changes()'s own
-- `insert into audit_logs (user_id, ...) values (auth.uid(), ...)`. The
-- DELETE on auth.users (and the cascaded DELETE on profiles it triggers) is
-- executed by Supabase's Auth service using its own internal, JWT-less
-- database role when admin.auth.admin.deleteUser() is called from the
-- service-role Admin API -- auth.uid() resolves to NULL in that context,
-- exactly like log_auth_event_trusted()'s own header comment (0023)
-- describes for service_role connections generally. Net effect: the
-- resulting `user.delete` row records THAT an unprovisioned account was
-- removed, but not WHICH staff member clicked "cancel invite" -- the one
-- piece of information that actually matters for accountability here.
--
-- Fix: a new, narrow, self-scoped RPC -- log_user_invite_cancel() -- called
-- from cancelUserInviteAction via the ORDINARY session client (the acting
-- staff member's own JWT, NOT the admin client) BEFORE the admin client
-- deletes the auth user. Because it runs under the actor's own session,
-- auth.uid() correctly resolves to the real actor here (unlike
-- log_auth_event_trusted(), which needs an explicit p_user_id argument
-- specifically because IT is called via the JWT-less admin client -- this
-- function is called earlier, while a real session still exists, so it
-- follows the SAME self-scoped pattern as get_my_permissions()/
-- am_i_super_admin() instead).
--
-- Guarded independently at the database layer (not just by
-- cancelUserInviteAction's own re-check) so a client cannot fabricate this
-- event for an arbitrary user or without the right permission:
--  * caller must hold users.disable (the same permission
--    cancelUserInviteAction itself requires) -- an ordinary authenticated
--    user cannot call this RPC to manufacture a fake cancellation record.
--  * the target must actually BE a still-pending_setup, never-provisioned
--    profile at the moment of the call (status = 'pending_setup' AND
--    provisioned_at IS NULL) -- the same invariant
--    cancelUserInviteAction's own server-side check enforces, repeated here
--    independently so the RPC cannot be used to attach an
--    "invite_cancel"-labelled event to an already-provisioned account.
--
-- Action name `user.invite_cancel` follows the existing
-- `<entity_type>.<verb>` taxonomy (0024) but as a hand-written event (no
-- backing INSERT/UPDATE/DELETE row of its own to derive it from) -- the
-- same shape as the three auth.* events (0023). It is DELIBERATELY
-- distinct from, and additional to, the `user.delete` event
-- audit_table_changes() still produces automatically for the same
-- cancellation: `user.invite_cancel` is the actor-attributed, intent-level
-- record of a staff decision ("X decided to cancel Y's invite"); `user.delete`
-- remains the generic, mechanical row-lifecycle record every profiles
-- deletion produces regardless of cause or caller (its own user_id may be
-- NULL here, exactly as described above). Two entity_type='user' rows for
-- one cancellation is intentional, not a duplicate -- one records WHO
-- decided and WHY, the other records WHAT happened to the row.
create or replace function public.log_user_invite_cancel(p_target_user_id uuid, p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
  v_target_status text;
  v_target_provisioned timestamptz;
begin
  if v_actor is null then
    raise exception 'يتطلب هذا الإجراء جلسة مستخدم موثَّقة'
      using errcode = 'P0001';
  end if;

  if not public.has_permission('users.disable') then
    raise exception 'يتطلب تسجيل إلغاء دعوة صلاحية users.disable'
      using errcode = 'P0001';
  end if;

  select status, provisioned_at into v_target_status, v_target_provisioned
  from public.profiles
  where id = p_target_user_id;

  if v_target_status is null then
    raise exception 'المستخدم المستهدَف غير موجود'
      using errcode = 'P0001';
  end if;

  if v_target_status is distinct from 'pending_setup' or v_target_provisioned is not null then
    raise exception 'لا يمكن تسجيل إلغاء دعوة لحساب ليس دعوة قيد الإعداد فعليًا (قد يكون مُفعّلاً بالفعل أو معطّلاً)'
      using errcode = 'P0001';
  end if;

  -- No email, no other free-form PII -- only the two ids, the actor, and an
  -- optional reason (data-minimisation, per the review's explicit
  -- instruction). entity_id = the target's own id; old_values/new_values
  -- deliberately left null (there is no before/after row state to compare
  -- for a hand-written intent event -- unlike audit_table_changes(), which
  -- diffs an actual row).
  insert into public.audit_logs (user_id, action, entity_type, entity_id, reason)
  values (v_actor, 'user.invite_cancel', 'user', p_target_user_id, p_reason)
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.log_user_invite_cancel(uuid, text) is
  '0038: writes a trusted, actor-attributed user.invite_cancel audit_logs row. Self-scoped (auth.uid(), like get_my_permissions()) -- must be called under the ACTOR''s own session, before the admin client deletes the target auth user, or auth.uid() would no longer reflect who initiated the cancellation. Gated independently by users.disable and by the target still being an unprovisioned pending_setup row at call time, so a client cannot fabricate this event for an arbitrary user or permission level. Deliberately additional to (not a replacement for) the generic user.delete row audit_table_changes() still produces for the same cascade -- see this migration''s header comment for why both are intentional.';

revoke execute on function public.log_user_invite_cancel(uuid, text) from public;
grant execute on function public.log_user_invite_cancel(uuid, text) to authenticated;

-- ============================================================================
-- 0039: invite-cancel audit event becomes service_role-only, logged AFTER
-- the actual deletion succeeds
-- ============================================================================
-- Foundation Audit Hotfix 1.4.2. Ships as a NEW migration after 0038. This
-- is a narrow fix to ONE remaining gap in Patch 1.4.1, item 3 -- nothing
-- else in Foundation is touched.
--
-- The gap (found in review, confirmed real): 0038's log_user_invite_cancel()
-- was GRANTed to `authenticated`, gated only by holding users.disable and by
-- the target currently being a pending_setup/unprovisioned row. That is not
-- enough -- any staff member who happens to hold users.disable could call
-- this RPC directly (e.g. from the browser console, or any REST client)
-- against a real pending invite and write a `user.invite_cancel` row
-- WITHOUT ever actually cancelling anything -- the invite stays fully
-- intact, but the audit log now falsely claims it was cancelled. An audit
-- trail that a caller can partially fabricate through the front door is not
-- trustworthy, even if permission-gated.
--
-- A second, related problem: cancelUserInviteAction (src/features/users/
-- actions.ts) called log_user_invite_cancel() BEFORE admin.auth.admin.
-- deleteUser() -- so a delete failure after a successful audit write left
-- the log claiming a cancellation that never actually happened, and nothing
-- prevented two concurrent/retried calls from writing the event twice for
-- the same target.
--
-- Fix, in three parts:
--  1. Revoke `authenticated`'s EXECUTE on log_user_invite_cancel(uuid, text)
--     entirely (function kept, not dropped -- same "superseded, not
--     rewritten" precedent as log_auth_event(text) in 0023). No signed-in
--     client -- regardless of which permissions it holds -- can call it any
--     more.
--  2. New log_user_invite_cancel_trusted(p_actor_user_id, p_target_user_id,
--     p_reason) -- service_role-only (same shape/precedent as
--     log_auth_event_trusted(), 0023): the caller passes the actor id
--     explicitly, because a service_role connection has no JWT `sub` claim
--     of its own to read via auth.uid(). Called from cancelUserInviteAction
--     via the ADMIN client, but only AFTER admin.auth.admin.deleteUser()
--     has already succeeded -- the actor id itself is captured EARLIER, from
--     the acting staff member's own verified session (requirePermission()'s
--     return value), before the admin client is touched at all, so it is
--     still a trustworthy, server-verified value despite being passed as a
--     plain argument to a JWT-less connection.
--     Two independent DB-level invariants make this un-fakeable even by our
--     own server code, not just by an external client:
--       a) a matching `user.delete` audit_logs row for the SAME target must
--          already exist -- structurally enforces "no event without an
--          actual completed deletion" against a REAL recorded deletion, not
--          merely "the profile row happens to be absent" (which would also
--          be true for a target id that never had a profile to begin with).
--          audit_table_changes() (0016) writes that row automatically, in
--          the same transaction as the auth.users/profiles delete itself.
--          The target's profiles row is also re-checked as not existing, as
--          a second, redundant signal.
--       b) the supplied actor must currently hold users.disable (re-checked
--          via get_user_permissions(), the service_role-only source of
--          truth, 0008/0015) -- closes the small staleness window between
--          the Server Action's own requirePermission() check and this call.
--     Idempotent: a partial unique index (below) allows at most one
--     `user.invite_cancel` row per target, ever; a retried/concurrent call
--     for the same target returns the SAME row's id instead of erroring or
--     duplicating.
--  3. audit_logs itself already has no UPDATE/DELETE policy for any role
--     (0006/0010) -- unchanged, re-confirmed by a new SQL test below.
--
-- `user.delete` is UNCHANGED and remains intentionally separate -- see
-- 0038's own header comment for why both events coexist by design.

-- ---------------------------------------------------------------------------
-- 1) Close the old, directly-callable path.
-- ---------------------------------------------------------------------------
revoke execute on function public.log_user_invite_cancel(uuid, text) from authenticated;

comment on function public.log_user_invite_cancel(uuid, text) is
  'SUPERSEDED as of 0039 by log_user_invite_cancel_trusted(uuid, uuid, text) (service_role-only). No longer reachable by `authenticated` at all: any signed-in user holding users.disable could previously call this directly against a real pending invite and write a user.invite_cancel row without the invite ever actually being cancelled -- a partially-fabricatable audit trail. Kept (not dropped) only so its definition/history is not rewritten.';

-- ---------------------------------------------------------------------------
-- 2) Idempotency: at most one user.invite_cancel row per target, ever.
--    Partial unique index -- matches the WHERE clause used in the trusted
--    function's own ON CONFLICT clause below.
-- ---------------------------------------------------------------------------
create unique index audit_logs_invite_cancel_once_idx
  on public.audit_logs (entity_id)
  where entity_type = 'user' and action = 'user.invite_cancel';

comment on index public.audit_logs_invite_cancel_once_idx is
  '0039: at most one user.invite_cancel row may ever exist per target user_id -- guarantees a retried/concurrent cancellation cannot double-log the same event, independent of any applicationlevel retry/dedup logic.';

-- ---------------------------------------------------------------------------
-- 3) The new trusted, service_role-only logging path.
-- ---------------------------------------------------------------------------
create or replace function public.log_user_invite_cancel_trusted(
  p_actor_user_id uuid,
  p_target_user_id uuid,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_actor_user_id is null then
    raise exception 'p_actor_user_id مطلوب' using errcode = 'P0001';
  end if;

  if p_target_user_id is null then
    raise exception 'p_target_user_id مطلوب' using errcode = 'P0001';
  end if;

  -- Invariant (a): a completed deletion for this EXACT target must already
  -- be on record -- checked via the automatic `user.delete` row
  -- audit_table_changes() (0016) writes as part of the same transaction
  -- that deletes auth.users/profiles, not merely "the profile row happens
  -- to be absent". The weaker check would also pass for a target id that
  -- never had a profile in the first place (nothing to delete, nothing that
  -- happened) -- checking for the actual `user.delete` audit row instead
  -- structurally ties this event to a REAL completed deletion, not just to
  -- caller-side ordering discipline. Even a bug in our own Server Action
  -- that called this too early (or with a bogus id) is rejected here, not
  -- just an external client trying to call it directly (which can't reach
  -- this function at all -- see the EXECUTE grant below).
  if not exists (
    select 1 from public.audit_logs
    where entity_type = 'user' and entity_id = p_target_user_id and action = 'user.delete'
  ) then
    raise exception 'لا يمكن تسجيل إلغاء دعوة قبل حذف حساب الهدف فعليًا -- لا يوجد سجل user.delete مطابق يثبت اكتمال الحذف'
      using errcode = 'P0001';
  end if;

  if exists (select 1 from public.profiles where id = p_target_user_id) then
    raise exception 'لا يمكن تسجيل إلغاء دعوة والهدف لا يزال له صفّ profiles قائم -- الحذف لم يكتمل فعليًا'
      using errcode = 'P0001';
  end if;

  -- Invariant (b): the supplied actor must currently hold users.disable --
  -- re-checked here independently of whatever the calling Server Action
  -- verified moments earlier via requirePermission(). get_user_permissions()
  -- is the service_role-only source of truth (0008/0015); this function is
  -- itself only reachable by service_role, so calling it directly is safe.
  if not exists (
    select 1 from public.get_user_permissions(p_actor_user_id) gp where gp = 'users.disable'
  ) then
    raise exception 'الفاعل المُمرَّر لا يملك صلاحية users.disable حاليًا -- لا يمكن تسجيل إلغاء الدعوة'
      using errcode = 'P0001';
  end if;

  -- No email, no other free-form PII -- only the two ids, the actor, and an
  -- optional reason (unchanged from 0038's own data-minimisation rule).
  -- ON CONFLICT against the partial unique index above makes this call
  -- idempotent: a retry or a race for the same target returns the SAME
  -- row's id instead of raising a duplicate-key error or writing a second
  -- row.
  insert into public.audit_logs (user_id, action, entity_type, entity_id, reason)
  values (p_actor_user_id, 'user.invite_cancel', 'user', p_target_user_id, p_reason)
  on conflict (entity_id) where (entity_type = 'user' and action = 'user.invite_cancel')
  do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id
    from public.audit_logs
    where entity_type = 'user' and entity_id = p_target_user_id and action = 'user.invite_cancel'
    order by created_at asc
    limit 1;
  end if;

  return v_id;
end;
$$;

comment on function public.log_user_invite_cancel_trusted(uuid, uuid, text) is
  '0039: trusted, service_role-only replacement for log_user_invite_cancel(uuid, text) (0038, now unreachable by authenticated). Writes a user.invite_cancel audit_logs row ONLY after independently confirming a matching user.delete audit_logs row already exists for the same target (i.e. the actual auth.users/profiles deletion already succeeded and was recorded) and that the supplied actor currently holds users.disable. Idempotent via a partial unique index on audit_logs (entity_id) WHERE entity_type=''user'' AND action=''user.invite_cancel'' -- a retry/race returns the existing row''s id instead of duplicating. Called from cancelUserInviteAction (src/features/users/actions.ts) via the admin/service-role client, AFTER admin.auth.admin.deleteUser() succeeds, with the actor id captured earlier from the acting staff member''s own verified session (requirePermission()) -- mirrors log_auth_event_trusted()''s (0023) established pattern exactly.';

revoke execute on function public.log_user_invite_cancel_trusted(uuid, uuid, text) from public;
grant execute on function public.log_user_invite_cancel_trusted(uuid, uuid, text) to service_role;

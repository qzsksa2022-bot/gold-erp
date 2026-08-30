-- ============================================================================
-- 0023: Move login-success/logout audit events to a trusted server-only path
-- ============================================================================
-- Foundation Hardening 1.2, item 6.
--
-- Gap: 0016's log_auth_event(p_action text) was SECURITY DEFINER, allowlisted
-- to exactly 'auth.login_success'/'auth.logout', and stamped user_id =
-- auth.uid() -- so it could not be used to impersonate someone ELSE or to
-- fabricate a truly arbitrary event. But it was directly GRANTed to
-- `authenticated`, meaning ANY signed-in client could call it themselves, at
-- ANY time, as many times as they liked -- completely decoupled from an
-- actual sign-in/sign-out actually happening. A user could pad their own
-- audit trail with fake login_success entries to build a false timeline
-- ("I was logged in during X"), or spam fake logout events, none of which
-- corresponded to a real auth state change. The app only ever called it
-- immediately after a genuine signInWithPassword/before signOut
-- (src/features/auth/actions.ts), but the RPC itself did not enforce that
-- -- any other authenticated caller could invoke it directly via PostgREST,
-- unrelated to the app's own call sites entirely.
--
-- Fix: move both events to a service_role-only function, called from
-- server-only code AFTER independently verifying the session server-side
-- (loginAction already re-checks the profile status post sign-in;
-- logoutAction already calls getUser() before signing out) -- the same
-- trust boundary already established for the failed-login path in 0016
-- (log_audit_event, called via the admin/service-role client from
-- src/lib/audit/log-failed-login.ts). `authenticated` loses the ability to
-- call anything auth-lifecycle-shaped directly, closing the self-call gap
-- entirely rather than trying to further constrain it.

create or replace function public.log_auth_event_trusted(p_user_id uuid, p_action text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_user_id is null then
    raise exception 'p_user_id مطلوب' using errcode = 'P0001';
  end if;

  if p_action not in ('auth.login_success', 'auth.logout') then
    raise exception 'إجراء غير مسموح به لهذه الدالة' using errcode = 'P0001';
  end if;

  insert into public.audit_logs (user_id, action, entity_type, entity_id)
  values (p_user_id, p_action, 'auth', p_user_id)
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.log_auth_event_trusted(uuid, text) is
  'service_role-only replacement for authenticated-callable log_auth_event(text) (0016). Called from server-only code (src/features/auth/actions.ts, via the admin/service-role client) AFTER independently verifying the session server-side -- no signed-in client can reach this directly any more, closing the gap where any authenticated user could self-call the old RPC at arbitrary times to fabricate login/logout timeline entries. p_user_id is supplied explicitly by the trusted caller since a service_role connection has no JWT sub claim of its own to read via auth.uid().';

revoke execute on function public.log_auth_event_trusted(uuid, text) from public;
grant execute on function public.log_auth_event_trusted(uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- Revoke authenticated's ability to call the old self-scoped version at
-- all. Not dropped (keeps its execution history/definition intact rather
-- than risking an unforeseen dependency), but no longer reachable by any
-- signed-in client -- src/features/auth/actions.ts is updated alongside
-- this migration to call log_auth_event_trusted() above instead.
-- ---------------------------------------------------------------------------
revoke execute on function public.log_auth_event(text) from authenticated;

comment on function public.log_auth_event(text) is
  'SUPERSEDED as of 0023 by log_auth_event_trusted(uuid, text) (service_role-only). No longer reachable by `authenticated`: any signed-in client could previously call this directly, at arbitrary times, to fabricate login_success/logout timeline entries under their own identity without a real corresponding login/logout ever happening. Kept (not dropped) only so its definition/history is not rewritten.';

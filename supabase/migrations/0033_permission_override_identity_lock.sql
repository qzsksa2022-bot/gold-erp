-- ============================================================================
-- 0033: Lock user_permission_overrides identity (user_id / permission_id)
-- ============================================================================
-- Foundation Hardening 1.4, item 2. Ships as a NEW migration after 0032.
--
-- user_permission_overrides has (user_id, permission_id) as its primary key
-- -- the row's entire IDENTITY. 0013/0026/0027 all correctly gate WHETHER a
-- given override may be created/changed/removed (self-modification block,
-- Super-Admin-target protection, sensitive-permission-key protection), but
-- nothing ever stopped an actor who otherwise passes those checks from
-- UPDATing user_id or permission_id on an EXISTING row -- which is not
-- really "editing an override" at all, it is silently re-pointing an
-- already-authorized override at a completely different (user, permission)
-- pair. Two concrete ways this is worse than a normal INSERT/DELETE pair:
--
--  1. It can move an override from an ordinary user to a Super Admin target
--     (or vice versa) without ever going through 0026's INSERT-time
--     protect_super_admin_entity check on the NEW identity -- that trigger
--     inspects the row's target user, but an UPDATE that only changes
--     user_id/permission_id was never conceived of as "targeting" anyone
--     new by the INSERT-shaped checks written before this review.
--  2. It can move an override off of a sensitive permission key onto a
--     harmless one (evading 0027's sensitive-key protection on any FUTURE
--     inspection of that row) or, more dangerously, re-point an existing,
--     already-approved-looking row to point AT a sensitive key -- an UPDATE
--     is a strictly different code path from the INSERT 0013/0027 actually
--     scrutinize for sensitive keys.
--
-- Fix: user_id and permission_id become fully immutable after INSERT, full
-- stop -- there is no legitimate reason to ever change either one. "Moving"
-- an override to a different user or permission is exactly what DELETE +
-- INSERT already means, and DELETE + INSERT correctly re-runs every
-- INSERT-time and DELETE-time check (self-block, Super-Admin-target,
-- sensitive-key) against the identity actually being touched, instead of an
-- UPDATE sliding underneath them. Only `effect` and `reason` may change via
-- UPDATE; created_at/created_by are already independently pinned by 0021's
-- enforce_created_by_immutable.

create or replace function public.enforce_permission_override_identity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_trusted_bootstrap_context() then
    return new;
  end if;

  if new.user_id is distinct from old.user_id
    or new.permission_id is distinct from old.permission_id
  then
    raise exception 'لا يمكن تغيير المستخدم أو الصلاحية المرتبطة باستثناء موجود -- احذف الاستثناء الحالي وأنشئ آخر جديدًا بدلاً من ذلك'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.enforce_permission_override_identity() is
  '0033: (user_id, permission_id) on user_permission_overrides is immutable after INSERT for any non-trusted actor -- an UPDATE may only change effect/reason. Prevents silently re-pointing an already-authorized override at a different user (e.g. onto/off of a Super Admin target) or a different permission (e.g. onto/off of a sensitive key) without re-running the INSERT/DELETE-time checks (0013/0026/0027) that actually scrutinize the identity being touched. "Moving" an override is DELETE + INSERT, which correctly re-triggers all of those; this trigger closes the UPDATE side-door around them.';

revoke execute on function public.enforce_permission_override_identity() from public;

create trigger user_permission_overrides_enforce_identity
  before update on public.user_permission_overrides
  for each row
  execute function public.enforce_permission_override_identity();

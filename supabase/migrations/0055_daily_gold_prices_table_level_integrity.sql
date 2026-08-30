-- ============================================================================
-- 0055: Final Integrity Hotfix 2.2.1 (1/2) — daily_gold_prices table-level
-- integrity: inactive-karat block moved to the table itself, plus
-- price_date/karat_id immutability
-- ============================================================================
-- Foundation (0001-0039), Phase 2 (0040-0046), Financial Integrity Patch 2.1
-- (0047-0050), and Financial Integrity Patch 2.2 (0051-0054) are all closed
-- and NOT modified here — every change in this hotfix starts at 0055. This
-- is a narrow follow-up to Patch 2.2, not a new review and not the start of
-- Sales/Returns/Shipments/Settlements.
--
-- ---------------------------------------------------------------------------
-- Gap closed here (hotfix item 1): 0054 added the "no brand-new price row
-- for an inactive karat" rule, but ONLY inside save_daily_gold_price()/
-- save_daily_gold_prices_bulk() (both SECURITY INVOKER RPCs). daily_gold_
-- prices itself still has its original direct RLS INSERT policy (0041,
-- untouched by 0051's trigger, which only ever pins the four source-
-- attribution columns and never inspects karat status) for any
-- `authenticated` actor holding gold_prices.edit -- so a direct PostgREST
-- INSERT that bypasses both RPCs entirely could still create a brand-new
-- price row for an inactive karat, exactly the gap 0054 believed it had
-- closed. The fix belongs on the table itself, not only inside the RPCs
-- that are merely one of several ways to reach it -- mirroring the design
-- 0047 already used for manufacturing_fee_versions/payment_method_fee_
-- versions (enforce_manufacturing_fee_version_karat_active()/enforce_
-- payment_method_fee_version_invariants(): a BEFORE INSERT table trigger,
-- unconditional, no trusted-context exemption -- "a version can never be
-- created for an inactive karat/payment method", full stop, for ANY writer).
-- daily_gold_prices gets the identical treatment here for the identical
-- reason: disabling a karat is meant to stop ALL new usage of it, not just
-- usage that happens to go through one particular RPC.
--
-- Scope, precisely (matches 0054's own scope): only a genuinely NEW row is
-- blocked for an inactive karat. Reading history and correcting an existing
-- price row for a karat that was later disabled remain completely
-- unaffected.
--
-- IMPORTANT Postgres subtlety, discovered while testing this migration
-- (not obvious from the RPCs' behavior alone): a BEFORE INSERT row trigger
-- fires for the CANDIDATE row of an `INSERT ... ON CONFLICT (...) DO
-- UPDATE` statement even when the conflict is ultimately resolved as an
-- UPDATE -- exactly the shape save_daily_gold_price()/save_daily_gold_
-- prices_bulk()'s upsert uses for a legitimate correction to an existing
-- row. A trigger that only looked at TG_OP (always 'INSERT' here,
-- regardless of whether it ends up an update via ON CONFLICT) would
-- therefore wrongly block a legitimate correction to an existing row whose
-- karat was later disabled -- reproduced concretely while testing this very
-- migration against financial_integrity_patch_2_2.test.sql's own §4.3 case.
-- The trigger below instead checks for the existing row directly (same
-- (price_date, karat_id) lookup 0054's RPC-level check already does),
-- exactly matching the "only a genuinely NEW row is blocked" scope stated
-- above and preserving the "corrections stay unaffected" guarantee for
-- every write path, not just the RPCs.
--
-- No trusted-context exemption (unlike 0051's source-integrity trigger,
-- which exists specifically to reserve external_api for a genuine future
-- trusted integration): this is a business-validity rule, not a trust-level
-- rule, and 0047's precedent for the exact same kind of rule (no new child
-- row against an inactive parent) applies it unconditionally to every
-- writer including service_role. There is no legitimate scenario in this
-- project today where service_role/a migration/a seed needs to insert a
-- brand-new daily price for an already-inactive karat.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_daily_gold_price_karat_active()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_row_exists boolean;
begin
  select status into v_status from public.karats where id = new.karat_id;

  select true into v_row_exists from public.daily_gold_prices
    where price_date = new.price_date and karat_id = new.karat_id;

  if v_status is distinct from 'active' and v_row_exists is null then
    raise exception 'لا يمكن تسجيل سعر جديد لعيار غير نشط' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.enforce_daily_gold_price_karat_active() is
  'Rejects a BRAND-NEW daily_gold_prices row for a karat whose status is not ''active'' -- mirrors enforce_manufacturing_fee_version_karat_active() (0047) in spirit, applied at the table level so no write path (RPC or direct PostgREST INSERT) can bypass it. "Brand-new" is judged by an explicit (price_date, karat_id) existence check, NOT by TG_OP alone -- a BEFORE INSERT row trigger fires for the candidate row of an `INSERT ... ON CONFLICT DO UPDATE` statement even when the conflict resolves as an UPDATE (save_daily_gold_price()/save_daily_gold_prices_bulk()''s own upsert shape), so TG_OP is always ''INSERT'' here regardless of whether this ends up a correction to an existing row -- see migration 0055 header comment for how this was discovered. Applies unconditionally, including to a trusted bootstrap context -- see migration 0055 header comment for why no exemption is warranted here. save_daily_gold_price()/save_daily_gold_prices_bulk() (0054) keep their own application-layer check too (defense in depth, not a regression -- a caller without karats.view still gets a clear, correctly-worded error from the RPC instead of a raw trigger exception).';

revoke execute on function public.enforce_daily_gold_price_karat_active() from public;

create trigger daily_gold_prices_enforce_karat_active
  before insert on public.daily_gold_prices
  for each row
  execute function public.enforce_daily_gold_price_karat_active();

-- ---------------------------------------------------------------------------
-- Gap closed here (hotfix item 2): price_date/karat_id together are a daily
-- price row's identity (they are literally its unique-constraint key,
-- (price_date, karat_id) from 0041) -- but nothing ever stopped a direct
-- UPDATE (RLS-permitted for any gold_prices.edit holder, same path as the
-- source-forgery gap 0051 closed for the source-attribution columns) from
-- silently REPOINTING an existing price row to a different date and/or a
-- different karat, corrupting history in place instead of ever going
-- through a proper insert/correction. save_daily_gold_price()/save_daily_
-- gold_prices_bulk()'s own `ON CONFLICT DO UPDATE` clause never touches
-- price_date/karat_id (only price_per_gram/source_*/notes/updated_*), so
-- this trigger never fires for any legitimate write through those RPCs --
-- exactly the same "the trigger is a no-op for every legitimate caller"
-- property enforce_manufacturing_fee_version_immutable() (0047, PART B) has
-- for karat_id/fee_per_gram/effective_from. Unconditional, including for a
-- trusted bootstrap context, mirroring that same precedent exactly: a
-- price row's identity must never be rewritten in place by anyone -- the
-- only sanctioned way to fix a mis-entered date/karat is to correct the
-- price value on the correct (price_date, karat_id) pair (or, if a row was
-- genuinely entered under the wrong identity, a service_role operator
-- deletes it and a human re-enters it correctly -- daily_gold_prices has no
-- soft-delete/history requirement as strict as the Versioning tables', so
-- this project does not need a "cancel and reopen" ceremony here, only the
-- immutability guarantee itself).
-- ---------------------------------------------------------------------------
create or replace function public.enforce_daily_gold_price_identity_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.price_date is distinct from old.price_date
    or new.karat_id is distinct from old.karat_id
  then
    raise exception 'لا يمكن تعديل تاريخ السعر أو العيار لسجل سعر موجود — التاريخ والعيار يحدّدان هوية السجل؛ لتصحيح قيمة خاطئة استخدم نفس (التاريخ، العيار) الصحيحين بدلًا من ذلك'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.enforce_daily_gold_price_identity_immutable() is
  'price_date/karat_id are permanent once a daily_gold_prices row is created -- together they are the row''s identity (and its unique-constraint key). Mirrors enforce_manufacturing_fee_version_immutable() (0047 PART B) exactly. Applies unconditionally, even to a trusted bootstrap context. Never fires for save_daily_gold_price()/save_daily_gold_prices_bulk()''s own ON CONFLICT DO UPDATE path, which never touches either column.';

revoke execute on function public.enforce_daily_gold_price_identity_immutable() from public;

create trigger daily_gold_prices_enforce_identity_immutable
  before update on public.daily_gold_prices
  for each row
  execute function public.enforce_daily_gold_price_identity_immutable();

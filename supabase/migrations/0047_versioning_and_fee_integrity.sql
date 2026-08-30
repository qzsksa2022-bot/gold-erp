-- ============================================================================
-- 0047: Financial Integrity Patch 2.1 (1/4) — versioning lockdown + invariants
-- ============================================================================
-- Foundation (0001-0039) and Phase 2 (0040-0046) are both closed and NOT
-- modified by this migration or any other in this patch — every change
-- starts at 0047. This patch is narrow and specific: it closes financial
-- data-integrity gaps in the Phase 2 versioning design, it is NOT a new
-- security review and it does NOT open Sales/Returns/Shipments/Settlements.
--
-- Gap closed here (spec item 1): manufacturing_fee_versions and
-- payment_method_fee_versions each had an `_insert`/`_update` RLS policy
-- letting any `authenticated` actor holding the matching `.manage`
-- permission write to these tables DIRECTLY via PostgREST — bypassing
-- create_manufacturing_fee_version()/create_payment_method_fee_version()
-- entirely. That RPC is what makes "never edit a rate that already took
-- effect, only end-and-replace atomically" true; a direct INSERT/UPDATE has
-- no such guarantee. From this migration on, `authenticated` cannot INSERT
-- or UPDATE these two tables under any circumstance — only the two RPC
-- families below (now SECURITY DEFINER, the sole write path for real users)
-- and a trusted bootstrap context (service_role/direct SQL, which BYPASSRLS
-- entirely — exactly how supabase/seed.sql and 0049's data migration seed
-- the initial rows) can write to them at all.
--
-- Gap closed here (spec item 2): cancelling a future, not-yet-effective
-- version correctly marks it 'cancelled', but the predecessor version it had
-- superseded was left permanently 'ended' with a real effective_to instead
-- of being reopened — creating a financial gap (no version at all covering
-- dates after that effective_to) even though, from the business's point of
-- view, nothing ever actually changed (the future version never took
-- effect). create_manufacturing_fee_version()/create_payment_method_fee_
-- version() are unchanged in this migration; cancel_manufacturing_fee_
-- version()/cancel_payment_method_fee_version() now atomically reopen the
-- exact predecessor they had ended, in the same transaction, or do nothing
-- further if there was no predecessor (never invents a value).
--
-- Gap closed here (spec item 6, DB invariant half): a version's numeric
-- shape must match its parent's fee_model at creation time (not just be
-- validated in application code), a version can never be created for an
-- inactive karat/payment method, and percentage_fee is capped at 100. The
-- "what happens if fee_model is changed after fee versions already exist"
-- question (also spec item 6) is answered concretely at the bottom of this
-- migration, not just in prose.

-- ---------------------------------------------------------------------------
-- PART A — Close the direct-write RLS path on both versioning tables.
-- SELECT policies (gated by `.view`) are untouched. There is intentionally
-- no replacement INSERT/UPDATE policy for `authenticated` — the RPCs below
-- are SECURITY DEFINER and therefore bypass RLS entirely when they write
-- (exactly the same mechanism audit_table_changes()/log_user_invite_cancel_
-- trusted() already rely on in Foundation), so no policy is needed for the
-- legitimate path either.
-- ---------------------------------------------------------------------------
drop policy manufacturing_fee_versions_insert on public.manufacturing_fee_versions;
drop policy manufacturing_fee_versions_update on public.manufacturing_fee_versions;
drop policy payment_method_fee_versions_insert on public.payment_method_fee_versions;
drop policy payment_method_fee_versions_update on public.payment_method_fee_versions;

comment on table public.manufacturing_fee_versions is
  'Versioned manufacturing fee per gram, by karat. `authenticated` has NO direct INSERT/UPDATE path as of 0047 — every write goes through create_manufacturing_fee_version()/cancel_manufacturing_fee_version() (SECURITY DEFINER) or a trusted bootstrap context (service_role/direct SQL). Append-only in spirit: rows are never edited after creation except effective_to/status, which only those two functions ever touch.';

comment on table public.payment_method_fee_versions is
  'Versioned percentage/fixed fee per payment method, mirroring manufacturing_fee_versions. `authenticated` has NO direct INSERT/UPDATE path as of 0047 — every write goes through create_payment_method_fee_version()/cancel_payment_method_fee_version() (SECURITY DEFINER) or a trusted bootstrap context.';

-- ---------------------------------------------------------------------------
-- PART B — Immutability: a version's identity (which karat/payment method)
-- and its financial value/start date can never change after the row exists,
-- for ANY writer, including a trusted bootstrap context — the only
-- sanctioned corrections are "end this version, insert a new one"
-- (create_*_version) or "withdraw a future version, reopen its predecessor"
-- (cancel_*_version). Both of those only ever touch effective_to/status, so
-- neither trigger below is ever tripped by legitimate code.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_manufacturing_fee_version_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.karat_id is distinct from old.karat_id
    or new.fee_per_gram is distinct from old.fee_per_gram
    or new.effective_from is distinct from old.effective_from
  then
    raise exception 'لا يمكن تعديل العيار أو قيمة المصنعية أو تاريخ السريان لإصدار موجود — أنشئ إصدارًا جديدًا عبر create_manufacturing_fee_version() بدلًا من ذلك'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.enforce_manufacturing_fee_version_immutable() is
  'karat_id/fee_per_gram/effective_from are permanent once a manufacturing_fee_versions row is created — only effective_to/status may ever change (by create_manufacturing_fee_version()/cancel_manufacturing_fee_version() alone). Applies unconditionally, even to a trusted bootstrap context: a version''s recorded value must never be rewritten in place by anyone.';

revoke execute on function public.enforce_manufacturing_fee_version_immutable() from public;

create trigger manufacturing_fee_versions_enforce_immutable
  before update on public.manufacturing_fee_versions
  for each row
  execute function public.enforce_manufacturing_fee_version_immutable();

create or replace function public.enforce_payment_method_fee_version_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.payment_method_id is distinct from old.payment_method_id
    or new.percentage_fee is distinct from old.percentage_fee
    or new.fixed_fee is distinct from old.fixed_fee
    or new.effective_from is distinct from old.effective_from
  then
    raise exception 'لا يمكن تعديل طريقة الدفع أو قيمة العمولة أو تاريخ السريان لإصدار موجود — أنشئ إصدارًا جديدًا عبر create_payment_method_fee_version() بدلًا من ذلك'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.enforce_payment_method_fee_version_immutable() is
  'payment_method_id/percentage_fee/fixed_fee/effective_from are permanent once a payment_method_fee_versions row is created — mirrors enforce_manufacturing_fee_version_immutable() exactly.';

revoke execute on function public.enforce_payment_method_fee_version_immutable() from public;

create trigger payment_method_fee_versions_enforce_immutable
  before update on public.payment_method_fee_versions
  for each row
  execute function public.enforce_payment_method_fee_version_immutable();

-- ---------------------------------------------------------------------------
-- PART C — Creation-time invariants (BEFORE INSERT only — UPDATE can never
-- reach these columns once PART B is in place, so there is nothing to
-- re-validate on UPDATE).
--
-- 1. A version can never be created for an inactive karat/payment method —
--    disabling a karat/method is meant to stop NEW usage, not just hide it
--    from a picklist; creating a fresh rate for something already retired
--    would be a modeling contradiction.
-- 2. payment_method_fee_versions' shape must match the parent payment
--    method's `fee_model` at the moment of creation:
--      none                   -> percentage_fee = 0 AND fixed_fee = 0
--      percentage             -> fixed_fee = 0 (percentage_fee unrestricted)
--      fixed                  -> percentage_fee = 0 (fixed_fee unrestricted)
--      percentage_plus_fixed  -> both allowed, no extra restriction
--    This is enforced as a DB invariant (not just app-layer Zod validation)
--    so a direct RPC call or a future code path cannot silently create a
--    shape-inconsistent version.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_manufacturing_fee_version_karat_active()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
begin
  select status into v_status from public.karats where id = new.karat_id;

  if v_status is distinct from 'active' then
    raise exception 'لا يمكن إنشاء إصدار مصنعية لعيار غير نشط' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.enforce_manufacturing_fee_version_karat_active() is
  'Rejects creating a manufacturing_fee_versions row for a karat whose status is not ''active'' — a disabled karat should never gain a fresh rate. BEFORE INSERT only (karat_id is immutable after creation, see PART B).';

revoke execute on function public.enforce_manufacturing_fee_version_karat_active() from public;

create trigger manufacturing_fee_versions_enforce_karat_active
  before insert on public.manufacturing_fee_versions
  for each row
  execute function public.enforce_manufacturing_fee_version_karat_active();

create or replace function public.enforce_payment_method_fee_version_invariants()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status text;
  v_fee_model text;
begin
  select status, fee_model into v_status, v_fee_model
  from public.payment_methods
  where id = new.payment_method_id;

  if v_status is distinct from 'active' then
    raise exception 'لا يمكن إنشاء نسخة عمولة لطريقة دفع غير نشطة' using errcode = 'P0001';
  end if;

  if v_fee_model = 'none' and (new.percentage_fee <> 0 or new.fixed_fee <> 0) then
    raise exception 'طريقة الدفع هذه معرَّفة بدون رسوم (none) — لا يمكن إنشاء نسخة عمولة بقيم غير صفرية' using errcode = 'P0001';
  elsif v_fee_model = 'percentage' and new.fixed_fee <> 0 then
    raise exception 'طريقة الدفع هذه معرَّفة كنسبة فقط (percentage) — المبلغ الثابت يجب أن يكون صفرًا' using errcode = 'P0001';
  elsif v_fee_model = 'fixed' and new.percentage_fee <> 0 then
    raise exception 'طريقة الدفع هذه معرَّفة كمبلغ ثابت فقط (fixed) — النسبة يجب أن تكون صفرًا' using errcode = 'P0001';
  end if;
  -- percentage_plus_fixed: both columns are free (>= 0, percentage <= 100
  -- via the CHECK constraint below) — no additional shape restriction.

  return new;
end;
$$;

comment on function public.enforce_payment_method_fee_version_invariants() is
  'BEFORE INSERT only (payment_method_id/percentage_fee/fixed_fee are immutable after creation, PART B): rejects a fee version for an inactive payment method, and rejects a percentage_fee/fixed_fee shape that does not match the parent payment_methods.fee_model at the moment of creation.';

revoke execute on function public.enforce_payment_method_fee_version_invariants() from public;

create trigger payment_method_fee_versions_enforce_invariants
  before insert on public.payment_method_fee_versions
  for each row
  execute function public.enforce_payment_method_fee_version_invariants();

-- percentage_fee was already checked >= 0 (0045); cap it at 100 — a
-- commission rate above 100% of the sale amount is never a legitimate
-- configuration in this business.
alter table public.payment_method_fee_versions
  add constraint payment_method_fee_versions_percentage_max check (percentage_fee <= 100);

-- ---------------------------------------------------------------------------
-- PART D — What happens if `fee_model` changes on a payment method that
-- already has fee versions (spec item 6, closing question). Decision,
-- documented and enforced, not just described:
--
--   1. Historical/ended fee versions are NEVER touched by a fee_model
--      change — they are permanent history, correct for the model that was
--      true at the time they were created (PART B already makes them
--      immutable regardless). A later fee_model change does not, and must
--      not, retroactively invalidate them; the UI reads each version by its
--      OWN percentage_fee/fixed_fee, never by cross-referencing the
--      payment method's CURRENT fee_model.
--   2. The CURRENTLY OPEN version (effective_to IS NULL, status='active'),
--      if one exists, is what could become shape-inconsistent going
--      forward. Rather than silently leaving that inconsistency in place
--      (or silently mutating/cancelling the open version as a surprising
--      side effect of an unrelated metadata edit), a fee_model change that
--      would make the currently open version's own values inconsistent
--      with the NEW fee_model is REJECTED outright. The admin must first
--      create a new, shape-compliant fee version (which atomically ends
--      the old one via create_payment_method_fee_version() — the normal,
--      audited path) or cancel a future one, THEN change fee_model.
--   3. If there is no currently open version (e.g. COD today) or the open
--      version already happens to satisfy the new shape (e.g. an all-zero
--      "none"-shaped version trivially also satisfies "percentage"'s
--      "fixed_fee = 0" requirement), the fee_model change is allowed
--      immediately — there is nothing inconsistent to create.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_payment_method_fee_model_change_consistency()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_open record;
begin
  if new.fee_model is distinct from old.fee_model then
    select * into v_open
    from public.payment_method_fee_versions
    where payment_method_id = new.id and effective_to is null and status = 'active';

    if found then
      if new.fee_model = 'none' and (v_open.percentage_fee <> 0 or v_open.fixed_fee <> 0) then
        raise exception 'لا يمكن تغيير fee_model إلى none — يوجد إصدار عمولة سارٍ/مجدوَل بقيم غير صفرية. أنشئ إصدار عمولة جديدًا متوافقًا أولًا (أو ألغِ الإصدار المستقبلي)، ثم غيّر fee_model'
          using errcode = 'P0001';
      elsif new.fee_model = 'percentage' and v_open.fixed_fee <> 0 then
        raise exception 'لا يمكن تغيير fee_model إلى percentage — الإصدار الساري/المجدوَل يتضمن مبلغًا ثابتًا غير صفري. أنشئ إصدار عمولة جديدًا متوافقًا أولًا، ثم غيّر fee_model'
          using errcode = 'P0001';
      elsif new.fee_model = 'fixed' and v_open.percentage_fee <> 0 then
        raise exception 'لا يمكن تغيير fee_model إلى fixed — الإصدار الساري/المجدوَل يتضمن نسبة غير صفرية. أنشئ إصدار عمولة جديدًا متوافقًا أولًا، ثم غيّر fee_model'
          using errcode = 'P0001';
      end if;
    end if;
  end if;

  return new;
end;
$$;

comment on function public.enforce_payment_method_fee_model_change_consistency() is
  'See PART D comment above this function in 0047. Rejects a fee_model change that would leave the CURRENTLY OPEN fee version (if any) shape-inconsistent with the new model; historical/ended versions are never touched or re-validated — they remain correct for the model that was true when each was created.';

revoke execute on function public.enforce_payment_method_fee_model_change_consistency() from public;

create trigger payment_methods_enforce_fee_model_change_consistency
  before update of fee_model on public.payment_methods
  for each row
  execute function public.enforce_payment_method_fee_model_change_consistency();

-- ---------------------------------------------------------------------------
-- PART E — The two "create" RPCs, re-declared SECURITY DEFINER (identical
-- signature and business logic to 0042/0045 — CREATE OR REPLACE, not a new
-- function). Now that PART A has removed `authenticated`'s direct RLS
-- write path entirely, these functions ARE the entire authorization
-- surface for real users, so the internal has_permission() check (already
-- present) is load-bearing rather than a second layer on top of RLS.
-- Fixed search_path (set search_path = public, pg_temp) prevents a
-- search_path-hijacking attack against a SECURITY DEFINER function; EXECUTE
-- is revoked from PUBLIC (which includes anon/authenticated by default) and
-- re-granted explicitly, only to `authenticated` — `anon` and every other
-- role have no path to these functions at all.
-- ---------------------------------------------------------------------------
create or replace function public.create_manufacturing_fee_version(
  p_karat_id uuid,
  p_fee_per_gram numeric,
  p_effective_from date,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_open record;
begin
  if not public.has_permission('manufacturing_fees.manage') then
    raise exception 'ليست لديك صلاحية إدارة المصنعية' using errcode = 'P0001';
  end if;

  if p_karat_id is null or p_fee_per_gram is null or p_effective_from is null then
    raise exception 'العيار، قيمة المصنعية، وتاريخ السريان كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_fee_per_gram < 0 then
    raise exception 'قيمة المصنعية لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  select * into v_open
  from public.manufacturing_fee_versions
  where karat_id = p_karat_id and effective_to is null and status = 'active'
  for update;

  if found then
    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار مصنعية سارٍ/مجدوَل لهذا العيار بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق. لإلغاء إصدار مستقبلي لم يسرِ بعد، استخدم cancel_manufacturing_fee_version أولًا.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.manufacturing_fee_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.manufacturing_fee_versions (karat_id, fee_per_gram, effective_from, effective_to, status, notes, created_by)
  values (p_karat_id, p_fee_per_gram, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_manufacturing_fee_version(uuid, numeric, date, text) is
  'Atomically ends the karat''s currently open manufacturing fee version (if the new effective_from is after it) and inserts the new one — the only sanctioned way to change a manufacturing fee. SECURITY DEFINER as of 0047 (authenticated has no direct table write path anymore) — has_permission() is now the sole authorization gate for this operation, in addition to RLS still governing SELECT.';

revoke execute on function public.create_manufacturing_fee_version(uuid, numeric, date, text) from public;
grant execute on function public.create_manufacturing_fee_version(uuid, numeric, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- cancel_manufacturing_fee_version(): withdraws a future version AND, new in
-- 0047, atomically reopens the exact predecessor it had ended (effective_to
-- = NULL, status = 'active') in the SAME transaction — closing the
-- financial gap spec item 2 describes. The predecessor is found precisely
-- (karat_id match, status='ended', effective_to = the cancelled version's
-- own effective_from - 1 — exactly the value create_manufacturing_fee_
-- version() would have stamped when it ended that row), never guessed by
-- "most recent" ordering. The cancelled row's status is flipped to
-- 'cancelled' BEFORE the predecessor is reopened, in that order, so the
-- GIST exclusion constraint (status <> 'cancelled') never sees the two
-- ranges as simultaneously live. If there is no predecessor (the cancelled
-- version was the karat''s first-ever version), nothing further happens —
-- no value is invented.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_manufacturing_fee_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_predecessor record;
begin
  if not public.has_permission('manufacturing_fees.manage') then
    raise exception 'ليست لديك صلاحية إدارة المصنعية' using errcode = 'P0001';
  end if;

  select * into v_row from public.manufacturing_fee_versions where id = p_version_id for update;

  if not found then
    raise exception 'إصدار المصنعية غير موجود' using errcode = 'P0001';
  end if;

  if v_row.status <> 'active' then
    raise exception 'هذا الإصدار ليس نشِطًا أصلًا (تم إلغاؤه أو استبداله سابقًا)' using errcode = 'P0001';
  end if;

  if v_row.effective_from <= current_date then
    raise exception 'لا يمكن إلغاء إصدار مصنعية سارٍ بالفعل أو مضى تاريخ سريانه — يُسمح فقط بإلغاء إصدار مستقبلي لم يسرِ بعد' using errcode = 'P0001';
  end if;

  update public.manufacturing_fee_versions set status = 'cancelled' where id = p_version_id;

  select * into v_predecessor
  from public.manufacturing_fee_versions
  where karat_id = v_row.karat_id and status = 'ended' and effective_to = v_row.effective_from - 1
  for update;

  if found then
    update public.manufacturing_fee_versions
    set effective_to = null, status = 'active'
    where id = v_predecessor.id;
  end if;
end;
$$;

comment on function public.cancel_manufacturing_fee_version(uuid) is
  'Withdraws a manufacturing fee version that has not taken effect yet, AND (new in 0047) atomically reopens the exact predecessor it had ended, so no date-range gap is left behind. SECURITY DEFINER as of 0047.';

revoke execute on function public.cancel_manufacturing_fee_version(uuid) from public;
grant execute on function public.cancel_manufacturing_fee_version(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Same two changes (SECURITY DEFINER + reopen-predecessor-on-cancel),
-- mirrored exactly, for payment_method_fee_versions.
-- ---------------------------------------------------------------------------
create or replace function public.create_payment_method_fee_version(
  p_payment_method_id uuid,
  p_percentage_fee numeric,
  p_fixed_fee numeric,
  p_effective_from date,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_open record;
begin
  if not public.has_permission('payment_methods.manage') then
    raise exception 'ليست لديك صلاحية إدارة طرق الدفع' using errcode = 'P0001';
  end if;

  if p_payment_method_id is null or p_effective_from is null then
    raise exception 'طريقة الدفع وتاريخ السريان مطلوبان' using errcode = 'P0001';
  end if;

  p_percentage_fee := coalesce(p_percentage_fee, 0);
  p_fixed_fee := coalesce(p_fixed_fee, 0);

  if p_percentage_fee < 0 or p_fixed_fee < 0 then
    raise exception 'قيم العمولة لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  select * into v_open
  from public.payment_method_fee_versions
  where payment_method_id = p_payment_method_id and effective_to is null and status = 'active'
  for update;

  if found then
    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار عمولة سارٍ/مجدوَل لهذه الطريقة بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق. لإلغاء إصدار مستقبلي لم يسرِ بعد، استخدم cancel_payment_method_fee_version أولًا.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.payment_method_fee_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.payment_method_fee_versions
    (payment_method_id, percentage_fee, fixed_fee, effective_from, effective_to, status, notes, created_by)
  values
    (p_payment_method_id, p_percentage_fee, p_fixed_fee, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) is
  'Atomically ends the payment method''s currently open fee version (if the new effective_from is after it) and inserts the new one. SECURITY DEFINER as of 0047 — mirrors create_manufacturing_fee_version() exactly. The shape/active-method invariants (PART C) fire as a BEFORE INSERT trigger on the underlying table, so they apply here too.';

revoke execute on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) from public;
grant execute on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) to authenticated;

create or replace function public.cancel_payment_method_fee_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_predecessor record;
begin
  if not public.has_permission('payment_methods.manage') then
    raise exception 'ليست لديك صلاحية إدارة طرق الدفع' using errcode = 'P0001';
  end if;

  select * into v_row from public.payment_method_fee_versions where id = p_version_id for update;

  if not found then
    raise exception 'إصدار العمولة غير موجود' using errcode = 'P0001';
  end if;

  if v_row.status <> 'active' then
    raise exception 'هذا الإصدار ليس نشِطًا أصلًا (تم إلغاؤه أو استبداله سابقًا)' using errcode = 'P0001';
  end if;

  if v_row.effective_from <= current_date then
    raise exception 'لا يمكن إلغاء إصدار عمولة سارٍ بالفعل أو مضى تاريخ سريانه — يُسمح فقط بإلغاء إصدار مستقبلي لم يسرِ بعد' using errcode = 'P0001';
  end if;

  update public.payment_method_fee_versions set status = 'cancelled' where id = p_version_id;

  select * into v_predecessor
  from public.payment_method_fee_versions
  where payment_method_id = v_row.payment_method_id and status = 'ended' and effective_to = v_row.effective_from - 1
  for update;

  if found then
    update public.payment_method_fee_versions
    set effective_to = null, status = 'active'
    where id = v_predecessor.id;
  end if;
end;
$$;

comment on function public.cancel_payment_method_fee_version(uuid) is
  'Withdraws a payment fee version that has not taken effect yet, AND (new in 0047) atomically reopens the exact predecessor it had ended. SECURITY DEFINER as of 0047. Mirrors cancel_manufacturing_fee_version() exactly.';

revoke execute on function public.cancel_payment_method_fee_version(uuid) from public;
grant execute on function public.cancel_payment_method_fee_version(uuid) to authenticated;

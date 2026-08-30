-- ============================================================================
-- 0058: Phase 3 — Sales Core (1/8): VAT rate versioning
-- ============================================================================
-- Migrations 0001-0057 are unmodified — every Phase 3 change starts at 0058.
--
-- Phase 2 (0040-0046) never built a VAT version table — VAT (15%) was never
-- persisted anywhere, only ever a literal in application-layer preview code.
-- Sales (§2 of the Phase 3 spec) needs VAT as a real, versioned, DB-resolved
-- input to Total Product Cost exactly like Gold Price and Manufacturing Fee
-- already are — so this migration builds `vat_rate_versions` as the third
-- member of that same family, before any Sales table exists.
--
-- Design: byte-for-byte the same versioning pattern as
-- manufacturing_fee_versions (0042, hardened 0047/0053/0056) and
-- payment_method_fee_versions (0045, same hardening) — end-then-insert,
-- GIST exclusion against overlap, at-most-one-Future-Version enforced from
-- day one (no need for a later 0053-style patch), business_today()-based
-- "already effective" / "still future" judgments from day one (no need for
-- a later 0056/0057-style patch), predecessor-reopen on cancel. The one
-- structural difference: manufacturing/payment fees are versioned PER
-- karat/payment-method (the exclusion constraint partitions on that FK);
-- VAT is a single, store-independent, system-wide rate, so the exclusion
-- constraint here has no equality partition — it is simply "no two
-- non-cancelled VAT periods may overlap, full stop."
--
-- Direct-write policy is deliberately STRICTER than manufacturing/payment
-- fees: those tables keep an authenticated INSERT/UPDATE RLS policy for
-- defense-in-depth (the app never uses that path, but it exists under the
-- same permission the RPC checks). The Phase 3 spec explicitly requires
-- VAT to have NO raw authenticated INSERT/UPDATE at all — management ONLY
-- through the trusted RPCs below. This migration honors that literally: no
-- INSERT/UPDATE RLS policy is created on vat_rate_versions, so a direct
-- PostgREST/table write is structurally impossible for `authenticated`
-- regardless of permission — the two SECURITY DEFINER RPCs below are the
-- only path in, exactly like log_audit_event (0016) is the only path into
-- audit_logs.
create table public.vat_rate_versions (
  id uuid primary key default gen_random_uuid(),
  -- numeric(6,3) matches this project's existing convention for a
  -- versioned percentage rate (payment_method_fee_versions.percentage_fee,
  -- 0045) — chosen for consistency with that sibling table rather than
  -- introducing a second precision convention for the same conceptual kind
  -- of value. 100.000 max comfortably fits.
  rate_percent numeric(6, 3) not null check (rate_percent >= 0 and rate_percent <= 100),
  effective_from date not null,
  -- NULL = open-ended (the current/scheduled rate). Stamped only by
  -- create_vat_rate_version() below when a newer version supersedes it.
  effective_to date,
  -- Same three-state meaning as manufacturing_fee_versions.status (0042):
  -- 'active' = the current open-ended version (at most one, see the
  --            partial unique index below).
  -- 'ended'  = superseded by a later version — still permanent history for
  --            the date range it covered.
  -- 'cancelled' = a FUTURE version withdrawn before it ever took effect —
  --            the only status excluded from resolution and the overlap
  --            guard.
  status text not null default 'active' check (status in ('active', 'ended', 'cancelled')),
  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);

comment on table public.vat_rate_versions is
  'Versioned VAT rate (system-wide, not per-store/karat/method) — same append-only versioning pattern as manufacturing_fee_versions (0042) / payment_method_fee_versions (0045). No direct authenticated INSERT/UPDATE is granted anywhere (unlike those two siblings) — management is exclusively through create_vat_rate_version()/cancel_vat_rate_version() below, both SECURITY DEFINER.';

-- At most one open (effective_to IS NULL, status='active') version at any
-- time — "the current/next scheduled VAT rate."
create unique index vat_rate_versions_open_idx
  on public.vat_rate_versions ((true))
  where effective_to is null and status = 'active';

comment on index public.vat_rate_versions_open_idx is
  'At most one open-ended active VAT version system-wide — the ((true)) expression index key is a deliberate idiom for "at most one row matching this partial predicate" on a table with no natural partitioning column (VAT has no karat_id/payment_method_id equivalent to partition on, unlike the two sibling versioning tables).';

-- No two non-cancelled VAT periods may overlap, enforced at the database
-- level. No equality term in the EXCLUDE clause (unlike the two sibling
-- tables) — VAT has no partitioning FK, the whole table is one timeline.
alter table public.vat_rate_versions
  add constraint vat_rate_versions_no_overlap
  exclude using gist (
    daterange(effective_from, effective_to, '[]') with &&
  )
  where (status <> 'cancelled');

create index vat_rate_versions_effective_from_idx on public.vat_rate_versions (effective_from);
create index vat_rate_versions_status_idx on public.vat_rate_versions (status);

alter table public.vat_rate_versions enable row level security;

create policy vat_rate_versions_select on public.vat_rate_versions
  for select to authenticated
  using (public.has_permission('vat_rates.view'));

-- Deliberately NO insert/update policy — see the table comment above and
-- the migration header. All writes go through the two SECURITY DEFINER
-- RPCs below, which check has_permission('vat_rates.manage') themselves
-- and bypass RLS by design (same pattern as every other SECURITY DEFINER
-- writer in this project, e.g. finalize_new_user_profile, 0016).
-- No DELETE policy either — a version, once created, is permanent history
-- or 'cancelled' in place; never removed.

create trigger vat_rate_versions_audit_trigger
  after insert or update or delete on public.vat_rate_versions
  for each row execute function public.audit_table_changes('vat_rate_version', 'id');

-- ---------------------------------------------------------------------------
-- Atomic "create a new VAT version" — mirrors create_manufacturing_fee_
-- version() (0042/0053/0056) exactly, including the at-most-one-Future-
-- Version guard and business_today()-based judgment from day one (both
-- were later patches for the fee-versioning siblings; VAT gets them
-- immediately since it is being built after those lessons were learned).
-- SECURITY DEFINER: this is the ONLY way to write this table at all (no
-- direct-write RLS policy exists), so has_permission() here is the sole
-- authorization gate, exactly like the two fee-versioning functions since
-- 0047.
-- ---------------------------------------------------------------------------
create or replace function public.create_vat_rate_version(
  p_rate_percent numeric,
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
  v_today date := public.business_today();
begin
  if not public.has_permission('vat_rates.manage') then
    raise exception 'ليست لديك صلاحية إدارة ضريبة القيمة المضافة' using errcode = 'P0001';
  end if;

  if p_rate_percent is null or p_effective_from is null then
    raise exception 'نسبة الضريبة وتاريخ السريان كلاهما مطلوبان' using errcode = 'P0001';
  end if;

  if p_rate_percent < 0 or p_rate_percent > 100 then
    raise exception 'نسبة ضريبة القيمة المضافة يجب أن تكون بين 0 و 100' using errcode = 'P0001';
  end if;

  select * into v_open
  from public.vat_rate_versions
  where effective_to is null and status = 'active'
  for update;

  if found then
    if v_open.effective_from > v_today then
      raise exception 'يوجد بالفعل إصدار ضريبة مستقبلي مجدوَل (يسري اعتبارًا من %) ولم يسرِ بعد — لا يمكن جدولة إصدار مستقبلي آخر فوقه. ألغِ الإصدار المستقبلي الحالي عبر cancel_vat_rate_version() أولًا، ثم أنشئ الإصدار الجديد.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار ضريبة سارٍ/مجدوَل بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق. لإلغاء إصدار مستقبلي لم يسرِ بعد، استخدم cancel_vat_rate_version أولًا.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.vat_rate_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.vat_rate_versions (rate_percent, effective_from, effective_to, status, notes, created_by)
  values (p_rate_percent, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_vat_rate_version(numeric, date, text) is
  'Atomically ends the currently open VAT version (if the new effective_from is after it) and inserts the new one — the only sanctioned way to change the VAT rate. At most one Future Version system-wide (cancel it first via cancel_vat_rate_version()). "Still future"/"already effective" are judged against public.business_today() (Asia/Riyadh), not current_date. SECURITY DEFINER — this table has no direct-write RLS policy at all, so this function is the exclusive write path.';

revoke execute on function public.create_vat_rate_version(numeric, date, text) from public;
grant execute on function public.create_vat_rate_version(numeric, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Withdraw a FUTURE VAT version that has not taken effect yet, atomically
-- reopening the exact predecessor it had ended — mirrors
-- cancel_manufacturing_fee_version() (0042/0047/0056) exactly.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_vat_rate_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_predecessor record;
begin
  if not public.has_permission('vat_rates.manage') then
    raise exception 'ليست لديك صلاحية إدارة ضريبة القيمة المضافة' using errcode = 'P0001';
  end if;

  select * into v_row from public.vat_rate_versions where id = p_version_id for update;

  if not found then
    raise exception 'إصدار الضريبة غير موجود' using errcode = 'P0001';
  end if;

  if v_row.status <> 'active' then
    raise exception 'هذا الإصدار ليس نشِطًا أصلًا (تم إلغاؤه أو استبداله سابقًا)' using errcode = 'P0001';
  end if;

  if v_row.effective_from <= public.business_today() then
    raise exception 'لا يمكن إلغاء إصدار ضريبة سارٍ بالفعل أو مضى تاريخ سريانه — يُسمح فقط بإلغاء إصدار مستقبلي لم يسرِ بعد' using errcode = 'P0001';
  end if;

  update public.vat_rate_versions set status = 'cancelled' where id = p_version_id;

  select * into v_predecessor
  from public.vat_rate_versions
  where status = 'ended' and effective_to = v_row.effective_from - 1
  for update;

  if found then
    update public.vat_rate_versions
    set effective_to = null, status = 'active'
    where id = v_predecessor.id;
  end if;
end;
$$;

comment on function public.cancel_vat_rate_version(uuid) is
  'Withdraws a VAT version that has not taken effect yet (effective_from strictly after public.business_today()), and atomically reopens the exact predecessor it had ended. SECURITY DEFINER — exclusive write path (see table comment).';

revoke execute on function public.cancel_vat_rate_version(uuid) from public;
grant execute on function public.cancel_vat_rate_version(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Resolver: VAT rate applicable on a date. Raises instead of returning
-- NULL/0/a hardcoded fallback — matches gold_price_for_karat_on_date /
-- manufacturing_fee_for_karat_on_date / payment_fee_for_method_on_date
-- exactly, and is precisely what makes "Sale dated where no VAT Version
-- exists must fail with a clear message, never silently assume 15%" (Phase
-- 3 spec §3/§9) true at the one place every VAT-consuming caller resolves
-- through.
-- ---------------------------------------------------------------------------
create or replace function public.vat_rate_for_date(p_date date default public.business_today())
returns numeric
language plpgsql
stable
as $$
declare
  v_rate numeric;
begin
  select rate_percent into v_rate
  from public.vat_rate_versions
  where status <> 'cancelled'
    and effective_from <= p_date
    and (effective_to is null or effective_to >= p_date)
  order by effective_from desc
  limit 1;

  if v_rate is null then
    raise exception 'لا يوجد إصدار ضريبة قيمة مضافة معتمد بتاريخ %', p_date using errcode = 'P0001';
  end if;

  return v_rate;
end;
$$;

comment on function public.vat_rate_for_date(date) is
  'VAT rate percentage (e.g. 15.000 meaning 15%) applicable on a date, resolved from vat_rate_versions. Raises P0001 (never returns NULL/0/a hardcoded default) if no version covers that date. Default p_date is public.business_today() (Asia/Riyadh), matching every other "today" default added since 0056/0057. SECURITY INVOKER; RLS (vat_rates.view) governs SELECT access on the underlying table as usual — a caller without vat_rates.view can still call this function (PUBLIC EXECUTE, like the sibling *_for_*_on_date functions) but gets nothing beyond the resolved numeric rate, no row-level detail.';

-- ---------------------------------------------------------------------------
-- Finance-safe sibling (0052-pattern): casts ::text inside Postgres before
-- PostgREST ever serializes it, so callers (Sales calculation code) get a
-- quoted JSON string, losslessly, and can feed it straight into
-- src/lib/decimal.ts's toDecimal() without ever passing through a JS
-- Number. This — not vat_rate_for_date() — is what any Sales-facing
-- TypeScript code must call.
-- ---------------------------------------------------------------------------
create or replace function public.vat_rate_for_date_safe(p_date date default public.business_today())
returns text
language sql
stable
as $$
  select public.vat_rate_for_date(p_date)::text;
$$;

comment on function public.vat_rate_for_date_safe(date) is
  'Finance-safe sibling of vat_rate_for_date() — see gold_price_for_karat_on_date_safe() (0052) for the full rationale, identical pattern. Default p_date is public.business_today() (Asia/Riyadh) — resolved independently in THIS function''s own signature, not inherited from vat_rate_for_date()''s default, per the exact default-parameter-resolution lesson documented in migration 0057''s header comment (a wrapper that calls its callee with an explicit argument never reaches the callee''s own default).';

-- No REVOKE/GRANT changes for vat_rate_for_date/vat_rate_for_date_safe —
-- PUBLIC EXECUTE, SECURITY INVOKER, matching every other *_for_*_on_date /
-- *_for_*_on_date_safe pair in this project (0041/0042/0045/0052).

-- ---------------------------------------------------------------------------
-- Permissions: vat_rates.view / vat_rates.manage — granular, not a
-- settings.manage substitute (Phase 3 spec §3 explicit instruction). Same
-- idempotent-forward-migration pattern as 0049 (Financial Integrity Patch
-- 2.1) — inserted here directly so a production upgrade from 0057 gets
-- them without depending on supabase/seed.sql being re-run; the matching
-- rows are also added to seed.sql for a fresh/local `db reset`, targeting
-- the same ON CONFLICT key, so re-running that file after this migration
-- has already run is a pure no-op.
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('vat_rates.view', 'financial_master_data', 'عرض ضريبة القيمة المضافة', 'View VAT rate'),
  ('vat_rates.manage', 'financial_master_data', 'إدارة ضريبة القيمة المضافة', 'Manage VAT rate')
on conflict (key) do nothing;

-- Role grants: same shape as the Phase 2 Master Data view/manage split
-- (0049) — Admin gets manage (consistent with already holding
-- manufacturing_fees.manage/payment_methods.manage), Supervisor/
-- Accountant/Sales Employee get view-only (Sales calculation code needs to
-- be ABLE to resolve the rate transparently in Preview responses, but none
-- of those roles configure it), matching the exact reasoning already
-- documented in seed.sql for the other Master Data permissions.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = 'vat_rates.manage'
where r.key = 'admin'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key in ('admin', 'supervisor', 'accountant', 'sales_employee') and p.key = 'vat_rates.view'
on conflict do nothing;

-- super_admin: already implicitly granted every permission via
-- has_permission()'s super-admin short-circuit, but 0049/seed.sql's own
-- convention is to also insert the row explicitly "for transparent UI
-- display" — matched here for the same reason.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin' and p.key in ('vat_rates.view', 'vat_rates.manage')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Baseline seed: current VAT rate, 15%, effective from the day this
-- migration/Phase 3 is deployed (public.business_today(), Asia/Riyadh) —
-- NOT a claim about when 15% VAT actually took effect in Saudi Arabia
-- historically. Sales did not exist as a feature before this migration, so
-- there is no legitimate historical Sale that could ever need a VAT rate
-- dated earlier than this baseline; any attempt to resolve VAT for a date
-- before it correctly raises (spec §3/§9: "لا تخترع تاريخًا تاريخيًا
-- للضريبة السعودية — وثّق نقطة البداية بوضوح"). Idempotent via the same
-- partial-unique-open-index ON CONFLICT target 0049 established for the
-- fee-versioning siblings.
-- ---------------------------------------------------------------------------
insert into public.vat_rate_versions (rate_percent, effective_from, notes)
select 15, public.business_today(), 'الإعداد الأساسي عند إطلاق Phase 3 (Sales Core) — ليس تأريخًا لتاريخ سريان ضريبة القيمة المضافة الفعلي في المملكة، بل نقطة بداية النظام لهذا الإصدار.'
where not exists (select 1 from public.vat_rate_versions where effective_to is null and status = 'active');

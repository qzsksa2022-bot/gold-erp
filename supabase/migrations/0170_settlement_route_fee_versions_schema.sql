-- ============================================================================
-- 0170: Phase 7 — Settlements Core (4/N): settlement_route_fee_versions
-- schema (Financial Master Data Versioning Hardening pattern)
-- ============================================================================
-- Migrations 0001-0169 are unmodified.
--
-- Replicates the EXACT hardening pattern already proven for
-- payment_method_fee_versions (0045/0047/0048/0053/0056/0066) — no-overlap
-- (GIST exclusion + partial-unique open-version index), immutability of
-- historical (closed) versions, no hard delete (no DELETE policy at all),
-- system columns protection (created_at/created_by immutable — no
-- updated_at/updated_by, matching the sibling table exactly: an edit is
-- always a new row, never an in-place update of value columns), and a
-- table-level EXCLUSIVE lock before any write (item 13/14 — collapsed into
-- one migration rather than payment_method_fee_versions' original
-- incremental history, since this is greenfield with no existing rows/
-- behavior to preserve; the FINAL state matches item-for-item).
--
-- transaction_fee_strategy (item 11):
--   source_snapshot — reuse the ALREADY-COMMITTED historical fee snapshot
--     on the source event itself (Sales/Returns/Adjustments already have
--     Historical Fee Snapshots per Phase 2/3/4/6) — the architectural
--     DEFAULT for every payment_collection route, since re-deriving a fee
--     Settlements never originally computed would violate item 1's
--     governing principle ("Settlements ليست Profit Engine جديدًا").
--   route_formula — this version's own percentage_fee/fixed_fee (shaped by
--     transaction_fee_model, reusing the EXACT SAME enum as payment_
--     methods.fee_model — percentage/fixed/percentage_plus_fixed/none) is
--     applied instead. This is the ONLY place COD %/fixed settlement fee
--     configuration lives (item 11) — a cod_carrier route may use this OR
--     `none`, per the operator's own configuration choice, never a
--     hardcoded default.
--   none — no transaction fee at all for this route/period.
--
-- cod_fee_reversal_policy (item 12) is REQUIRED exactly when
-- transaction_fee_strategy = 'route_formula' AND the parent route is
-- cod_carrier (a carrier does not always reverse its COD fee on a reversal
-- — full/proportional/none must be configured explicitly, never assumed);
-- NULL in every other case. Enforced by the creation-time invariant trigger
-- below (needs to join settlement_routes for route_kind, so it cannot be a
-- plain CHECK constraint).
-- ---------------------------------------------------------------------------
create table public.settlement_route_fee_versions (
  id uuid primary key default gen_random_uuid(),
  settlement_route_id uuid not null references public.settlement_routes (id) on delete restrict,
  effective_from date not null,
  effective_to date,
  transaction_fee_strategy text not null check (transaction_fee_strategy in ('source_snapshot', 'route_formula', 'none')),
  transaction_fee_model text check (transaction_fee_model in ('percentage', 'fixed', 'percentage_plus_fixed', 'none')),
  percentage_fee numeric(6, 3) check (percentage_fee is null or (percentage_fee >= 0 and percentage_fee <= 100)),
  fixed_fee numeric(12, 4) check (fixed_fee is null or fixed_fee >= 0),
  batch_fee_fixed numeric(12, 2) not null default 0 check (batch_fee_fixed >= 0),
  cod_fee_reversal_policy text check (cod_fee_reversal_policy in ('full', 'proportional', 'none')),
  status text not null default 'active' check (status in ('active', 'ended', 'cancelled')),
  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);

comment on table public.settlement_route_fee_versions is
  'Phase 7 (items 11/12) — versioned transaction-fee configuration per Settlement Route. Mirrors payment_method_fee_versions'' hardening exactly. No hard delete, no in-place edit of value columns (an edit is always a new version) — a version is permanent history once created.';

create index settlement_route_fee_versions_route_idx on public.settlement_route_fee_versions (settlement_route_id);
create index settlement_route_fee_versions_effective_from_idx on public.settlement_route_fee_versions (effective_from);

create unique index settlement_route_fee_versions_open_idx
  on public.settlement_route_fee_versions (settlement_route_id)
  where effective_to is null and status = 'active';

alter table public.settlement_route_fee_versions
  add constraint settlement_route_fee_versions_no_overlap
  exclude using gist (
    settlement_route_id with =,
    daterange(effective_from, effective_to, '[]') with &&
  )
  where (status <> 'cancelled');

alter table public.settlement_route_fee_versions enable row level security;

create policy settlement_route_fee_versions_select on public.settlement_route_fee_versions
  for select to authenticated
  using (public.has_permission('settlements.view_financials'));

comment on policy settlement_route_fee_versions_select on public.settlement_route_fee_versions is
  'Phase 7 — gated on settlements.view_financials (fee percentages/fixed amounts are financial configuration, a stricter bar than the base settlement_routes catalog). No INSERT/UPDATE/DELETE policy exists at all — create/cancel_settlement_route_fee_version() (0171) are the entire write surface.';

-- ---------------------------------------------------------------------------
-- Creation-time shape invariant (mirrors enforce_payment_method_fee_
-- version_invariants(), 0047 PART C).
-- ---------------------------------------------------------------------------
create or replace function public.enforce_settlement_route_fee_version_invariants()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_route record;
begin
  select * into v_route from public.settlement_routes where id = new.settlement_route_id;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;

  if new.transaction_fee_strategy = 'route_formula' then
    if new.transaction_fee_model is null then
      raise exception 'شكل الرسوم (transaction_fee_model) مطلوب عند اختيار route_formula' using errcode = 'P0001';
    end if;
    if new.transaction_fee_model in ('percentage', 'percentage_plus_fixed') and new.percentage_fee is null then
      raise exception 'النسبة المئوية للرسوم مطلوبة لهذا الشكل' using errcode = 'P0001';
    end if;
    if new.transaction_fee_model in ('fixed', 'percentage_plus_fixed') and new.fixed_fee is null then
      raise exception 'القيمة الثابتة للرسوم مطلوبة لهذا الشكل' using errcode = 'P0001';
    end if;
    if new.transaction_fee_model = 'percentage' and new.fixed_fee is not null and new.fixed_fee <> 0 then
      raise exception 'شكل النسبة المئوية لا يقبل قيمة ثابتة' using errcode = 'P0001';
    end if;
    if new.transaction_fee_model = 'fixed' and new.percentage_fee is not null and new.percentage_fee <> 0 then
      raise exception 'الشكل الثابت لا يقبل نسبة مئوية' using errcode = 'P0001';
    end if;

    if v_route.route_kind = 'cod_carrier' then
      if new.cod_fee_reversal_policy is null then
        raise exception 'سياسة عكس رسوم COD (cod_fee_reversal_policy) مطلوبة عند استخدام route_formula لمسار COD ناقل' using errcode = 'P0001';
      end if;
    else
      if new.cod_fee_reversal_policy is not null then
        raise exception 'سياسة عكس رسوم COD لا تنطبق إلا على مسارات COD الناقل' using errcode = 'P0001';
      end if;
    end if;
  else
    if new.transaction_fee_model is not null or new.percentage_fee is not null or new.fixed_fee is not null then
      raise exception 'لا يجوز تحديد شكل/قيم رسوم عندما تكون الاستراتيجية source_snapshot أو none' using errcode = 'P0001';
    end if;
    if new.cod_fee_reversal_policy is not null then
      raise exception 'سياسة عكس رسوم COD لا تنطبق إلا مع route_formula' using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function public.enforce_settlement_route_fee_version_invariants() from public;

create trigger settlement_route_fee_versions_enforce_invariants
  before insert on public.settlement_route_fee_versions
  for each row
  execute function public.enforce_settlement_route_fee_version_invariants();

-- ---------------------------------------------------------------------------
-- Immutability of historical/closed versions — only effective_to/status may
-- ever change (via the RPCs, 0171). Mirrors enforce_payment_method_fee_
-- version_immutable() (0047) exactly, extended to this table's extra
-- value columns.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_settlement_route_fee_version_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.settlement_route_id is distinct from old.settlement_route_id
    or new.effective_from is distinct from old.effective_from
    or new.transaction_fee_strategy is distinct from old.transaction_fee_strategy
    or new.transaction_fee_model is distinct from old.transaction_fee_model
    or new.percentage_fee is distinct from old.percentage_fee
    or new.fixed_fee is distinct from old.fixed_fee
    or new.batch_fee_fixed is distinct from old.batch_fee_fixed
    or new.cod_fee_reversal_policy is distinct from old.cod_fee_reversal_policy
  then
    raise exception 'لا يمكن تعديل مسار التسوية أو تاريخ السريان أو قيم الرسوم لإصدار موجود — أنشئ إصدارًا جديدًا عبر create_settlement_route_fee_version() بدلًا من ذلك'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

revoke execute on function public.enforce_settlement_route_fee_version_immutable() from public;

create trigger settlement_route_fee_versions_enforce_immutable
  before update on public.settlement_route_fee_versions
  for each row
  execute function public.enforce_settlement_route_fee_version_immutable();

-- created_at/created_by immutability — reuses the existing generic
-- enforce_created_by_immutable() (0021), exactly like payment_method_fee_
-- versions (0048) does; no redefinition needed.
create trigger settlement_route_fee_versions_enforce_created_by
  before insert or update on public.settlement_route_fee_versions
  for each row
  execute function public.enforce_created_by_immutable();

-- ---------------------------------------------------------------------------
-- Table-level BEFORE STATEMENT lock (item 13/14).
-- ---------------------------------------------------------------------------
create or replace function public.settlement_route_fee_versions_acquire_lock_before_write()
returns trigger
language plpgsql
as $$
begin
  perform public.acquire_settlement_master_lock_exclusive();
  return null;
end;
$$;

create trigger settlement_route_fee_versions_lock_before_write
  before insert or update or delete on public.settlement_route_fee_versions
  for each statement
  execute function public.settlement_route_fee_versions_acquire_lock_before_write();

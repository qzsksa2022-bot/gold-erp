-- ============================================================================
-- 0172: Phase 7 — Settlements Core (6/N): settlement_number sequence +
-- settlement_batches schema
-- ============================================================================
-- Migrations 0001-0171 are unmodified.
--
-- settlement_batches is the header row of a Settlement (item 15). Lifecycle
-- (item 17): draft -> finalized -> reconciled is a REAL status transition on
-- this very row (unlike Adjustments' reversal, which never touches the
-- original approved row) — Reconciliation genuinely moves finalized ->
-- reconciled in place. Cancellation is DELIBERATELY separate (item 33): an
-- append-only settlement_batch_cancellations row (0175) — this row is NEVER
-- touched by cancellation, "effective_status = cancelled" is derived at
-- read time, never a status value stored here.
--
-- Snapshot fields (route/payment-method/channel/carrier/fee-version/
-- percentages/batch-fee) are NULL while status='draft' (item 18 — a draft
-- reserves nothing financially yet) and are populated ONLY by
-- finalize_settlement_batch() (0178) — after which they become permanently
-- frozen (item 38), enforced below by settlement_batches_reject_financial_
-- mutation, which activates the instant OLD.status <> 'draft'.
--
-- actual_bank_movement/variance are DELIBERATELY NOT columns here — item 31
-- computes both live, at read time, from the settlement_bank_movement_
-- events/_reversals ledger (0174) — a stored "actual" column would be
-- exactly the kind of client-suppliable Source of Truth item 1 forbids.
-- ---------------------------------------------------------------------------
create sequence public.settlement_number_seq as bigint start with 1 increment by 1 no cycle;

create or replace function public.generate_settlement_number()
returns text
language sql
as $$
  select 'SET-' || lpad(nextval('public.settlement_number_seq')::text, 10, '0');
$$;

comment on function public.generate_settlement_number() is
  'Phase 7 (item 16) — issues the next globally-unique, gap-tolerant, concurrency-safe settlement number (format SET-0000000001). VOLATILE. Deliberately NOT granted to `authenticated` — only create_draft_settlement_batch() (0177), itself SECURITY DEFINER, calls this.';

revoke execute on function public.generate_settlement_number() from public;

create table public.settlement_batches (
  id uuid primary key default gen_random_uuid(),
  settlement_number text not null unique,
  settlement_route_id uuid not null references public.settlement_routes (id) on delete restrict,
  settlement_date date not null,
  status text not null default 'draft' check (status in ('draft', 'finalized', 'reconciled')),
  provider_statement_reference text,
  notes text,
  -- Snapshot at finalization (item 15/38) — NULL while draft.
  route_code_snapshot text,
  route_name_ar_snapshot text,
  route_name_en_snapshot text,
  route_kind_snapshot text,
  payment_method_id_snapshot uuid,
  payment_method_name_snapshot text,
  collection_channel_id_snapshot uuid,
  collection_channel_name_snapshot text,
  shipping_carrier_id_snapshot uuid,
  shipping_carrier_name_snapshot text,
  route_fee_version_id_snapshot uuid,
  transaction_fee_strategy_snapshot text,
  transaction_percentage_fee_snapshot numeric(6, 3),
  transaction_fixed_fee_snapshot numeric(12, 4),
  batch_fee_snapshot numeric(12, 2) not null default 0,
  is_batch_fee_override boolean not null default false,
  configured_batch_fee_snapshot numeric(12, 2),
  override_reason text,
  gross_source_impact numeric(14, 2),
  provider_fee_impact numeric(14, 2),
  expected_before_batch_fee numeric(14, 2),
  expected_bank_settlement numeric(14, 2),
  settlement_calculation_version integer,
  row_version bigint not null default 1,
  finalized_at timestamptz,
  finalized_by uuid references public.profiles (id) on delete set null,
  reconciled_at timestamptz,
  reconciled_by uuid references public.profiles (id) on delete set null,
  reconciliation_reason text,
  variance_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  constraint settlement_batches_lifecycle_fields_consistent check (
    (status = 'draft' and finalized_at is null and reconciled_at is null)
    or (status = 'finalized' and finalized_at is not null and reconciled_at is null)
    or (status = 'reconciled' and finalized_at is not null and reconciled_at is not null)
  ),
  constraint settlement_batches_calc_version_consistent check (
    (status in ('finalized', 'reconciled') and settlement_calculation_version = 1)
    or (status = 'draft' and settlement_calculation_version is null)
  ),
  constraint settlement_batches_batch_fee_override_consistent check (
    (is_batch_fee_override = false and override_reason is null)
    or (is_batch_fee_override = true and override_reason is not null)
  )
);

create index settlement_batches_route_idx on public.settlement_batches (settlement_route_id);
create index settlement_batches_date_idx on public.settlement_batches (settlement_date);
create index settlement_batches_status_idx on public.settlement_batches (status);

alter table public.settlement_batches enable row level security;

-- item 41 — raw authenticated SELECT would expose aggregates/financial
-- data; no SELECT policy at all. Every read goes through
-- get_settlement_batch()/list_settlement_batches() (0182), which apply
-- settlements.view_financials redaction AND cross-store privacy (item 21)
-- themselves.
comment on table public.settlement_batches is
  'Phase 7 (item 15) — Settlement Batch header. Lifecycle draft->finalized->reconciled is a real in-place transition; cancellation is a SEPARATE append-only event (settlement_batch_cancellations, 0175) that never touches this row. Snapshot fields freeze permanently the instant status leaves ''draft'' (enforced by settlement_batches_reject_financial_mutation below). No hard delete, ever. Zero direct RLS policies (item 41/21 — a raw row could leak cross-store aggregates) — every read/write goes through SECURITY DEFINER RPCs.';

-- ---------------------------------------------------------------------------
-- Financial/identity field freeze — activates the instant a row leaves
-- 'draft'. status/reconciled_*/row_version/updated_at/updated_by remain
-- mutable (the lifecycle RPCs themselves enforce valid state-machine
-- direction; this trigger only protects the FINANCIAL FACTS, mirroring
-- item 38's Snapshot Stability requirement at the DB level, not merely an
-- RPC convention).
-- ---------------------------------------------------------------------------
create or replace function public.settlement_batches_reject_financial_mutation()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'draft' then
    return new;
  end if;

  if new.settlement_route_id is distinct from old.settlement_route_id
    or new.settlement_date is distinct from old.settlement_date
    or new.route_code_snapshot is distinct from old.route_code_snapshot
    or new.route_name_ar_snapshot is distinct from old.route_name_ar_snapshot
    or new.route_name_en_snapshot is distinct from old.route_name_en_snapshot
    or new.route_kind_snapshot is distinct from old.route_kind_snapshot
    or new.payment_method_id_snapshot is distinct from old.payment_method_id_snapshot
    or new.payment_method_name_snapshot is distinct from old.payment_method_name_snapshot
    or new.collection_channel_id_snapshot is distinct from old.collection_channel_id_snapshot
    or new.collection_channel_name_snapshot is distinct from old.collection_channel_name_snapshot
    or new.shipping_carrier_id_snapshot is distinct from old.shipping_carrier_id_snapshot
    or new.shipping_carrier_name_snapshot is distinct from old.shipping_carrier_name_snapshot
    or new.route_fee_version_id_snapshot is distinct from old.route_fee_version_id_snapshot
    or new.transaction_fee_strategy_snapshot is distinct from old.transaction_fee_strategy_snapshot
    or new.transaction_percentage_fee_snapshot is distinct from old.transaction_percentage_fee_snapshot
    or new.transaction_fixed_fee_snapshot is distinct from old.transaction_fixed_fee_snapshot
    or new.batch_fee_snapshot is distinct from old.batch_fee_snapshot
    or new.is_batch_fee_override is distinct from old.is_batch_fee_override
    or new.configured_batch_fee_snapshot is distinct from old.configured_batch_fee_snapshot
    or new.override_reason is distinct from old.override_reason
    or new.gross_source_impact is distinct from old.gross_source_impact
    or new.provider_fee_impact is distinct from old.provider_fee_impact
    or new.expected_before_batch_fee is distinct from old.expected_before_batch_fee
    or new.expected_bank_settlement is distinct from old.expected_bank_settlement
    or new.settlement_calculation_version is distinct from old.settlement_calculation_version
    or new.finalized_at is distinct from old.finalized_at
    or new.finalized_by is distinct from old.finalized_by
    or new.created_at is distinct from old.created_at
    or new.created_by is distinct from old.created_by
  then
    raise exception 'الحقائق المالية/اللقطة لدفعة تسوية معتمَدة أو مطابَقة غير قابلة للتعديل أبدًا' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.settlement_batches_reject_financial_mutation() is
  'Phase 7 (item 38) — the instant a batch leaves draft, its route/financial/snapshot facts are frozen at the DB level forever, even against a trusted direct write. status/reconciled_*/row_version/updated_at/updated_by stay mutable so reconcile_settlement_batch() (0180) can still transition finalized -> reconciled in place.';

create trigger settlement_batches_reject_financial_mutation
  before update on public.settlement_batches
  for each row
  execute function public.settlement_batches_reject_financial_mutation();

create or replace function public.settlement_batches_reject_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'دفعات التسوية لا تُحذف أبدًا — ألغِها بدلًا من ذلك (cancel_settlement_batch)' using errcode = 'P0001';
end;
$$;

create trigger settlement_batches_reject_delete
  before delete on public.settlement_batches
  for each row
  execute function public.settlement_batches_reject_delete();

-- updated_by anti-forgery — same corrected pattern as settlement_routes
-- (0168) and adjustment_types post-Hotfix-6.1.2 (0164).
create or replace function public.settlement_batches_enforce_updated_columns()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  new.updated_at := now();
  if v_actor is not null and exists (select 1 from public.profiles where id = v_actor) then
    new.updated_by := v_actor;
  else
    new.updated_by := old.updated_by;
  end if;
  return new;
end;
$$;

revoke execute on function public.settlement_batches_enforce_updated_columns() from public;

create trigger settlement_batches_enforce_updated_columns
  before update on public.settlement_batches
  for each row
  execute function public.settlement_batches_enforce_updated_columns();

-- created_at/created_by immutability on INSERT+UPDATE (reuse generic 0021
-- helper — it also stamps created_at/created_by on INSERT, which is fine
-- since every write here is through a SECURITY DEFINER RPC that runs as a
-- real actor).
create trigger settlement_batches_enforce_created_by
  before insert or update on public.settlement_batches
  for each row
  execute function public.enforce_created_by_immutable();

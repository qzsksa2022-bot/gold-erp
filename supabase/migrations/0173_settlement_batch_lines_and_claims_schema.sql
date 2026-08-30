-- ============================================================================
-- 0173: Phase 7 — Settlements Core (7/N): settlement_batch_lines +
-- settlement_source_claims schema
-- ============================================================================
-- Migrations 0001-0172 are unmodified.
--
-- settlement_batch_lines (item 24) — one immutable financial-snapshot row
-- PER SOURCE EVENT claimed into a batch at Finalization. INSERT-only,
-- forever (no UPDATE, no DELETE) — a cancelled batch's lines are NEVER
-- touched (item 34), only the claim (below) is released.
--
-- settlement_source_claims (item 25) — the DB-level (not merely
-- client-side) invariant that the SAME source event can never be
-- effectively inside two batches at once. "Active" = released_at IS NULL;
-- the partial unique index below is the actual DB unique invariant. A
-- cancelled batch's claim is released (released_at/by/reason set, an
-- UPDATE — the spec's own wording is explicit: "Claim تُreleased ... ولا
-- يُحذف Historical line", i.e. update-in-place is sanctioned here, unlike
-- every OTHER financial correction in this module which is append-only —
-- a claim is a reservation/lock record, not a financial fact itself; the
-- financial fact is the immutable settlement_batch_lines row, untouched by
-- a release).
-- ---------------------------------------------------------------------------
create table public.settlement_batch_lines (
  id uuid primary key default gen_random_uuid(),
  settlement_batch_id uuid not null references public.settlement_batches (id) on delete restrict,
  source_kind text not null check (source_kind in ('sale', 'return_refund', 'return_refund_reversal', 'adjustment_approved', 'adjustment_reversal', 'cod_collection', 'cod_reversal')),
  source_event_id uuid not null,
  source_number_snapshot text not null,
  source_business_date date not null,
  primary_store_id uuid not null references public.stores (id) on delete restrict,
  secondary_store_id uuid references public.stores (id) on delete restrict,
  primary_store_name_snapshot text not null,
  secondary_store_name_snapshot text,
  payment_method_id_snapshot uuid,
  payment_method_name_snapshot text,
  collection_channel_id_snapshot uuid,
  collection_channel_name_snapshot text,
  shipping_carrier_id_snapshot uuid,
  shipping_carrier_name_snapshot text,
  gross_collection_impact numeric(14, 2) not null,
  provider_fee_impact numeric(14, 2) not null,
  expected_settlement_impact numeric(14, 2) not null,
  provider_fee_source text not null check (provider_fee_source in ('source_snapshot', 'route_formula', 'none')),
  source_fee_version_id uuid,
  route_fee_version_id uuid,
  source_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint settlement_batch_lines_expected_formula check (expected_settlement_impact = gross_collection_impact - provider_fee_impact)
);

comment on table public.settlement_batch_lines is
  'Phase 7 (item 24) — one immutable financial-snapshot row per source event claimed into a batch at Finalization. INSERT-only forever. No profit-sensitive hidden data (no gold/manufacturing/VAT cost, no product gross profit, no sales net profit, no adjustment direct cost, no shipping P/L) — Settlement-only figures per item 19/24.';

create index settlement_batch_lines_batch_idx on public.settlement_batch_lines (settlement_batch_id);
create index settlement_batch_lines_source_idx on public.settlement_batch_lines (source_kind, source_event_id);
create index settlement_batch_lines_primary_store_idx on public.settlement_batch_lines (primary_store_id);
create index settlement_batch_lines_secondary_store_idx on public.settlement_batch_lines (secondary_store_id);

alter table public.settlement_batch_lines enable row level security;
-- No SELECT/INSERT/UPDATE/DELETE policy at all (item 41) — every read goes
-- through get_settlement_batch() (0182), which applies settlements.
-- view_financials redaction AND cross-store privacy (item 21) itself; every
-- write happens ONLY inside finalize_settlement_batch() (0178), SECURITY
-- DEFINER.

create or replace function public.settlement_batch_lines_reject_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'سطور دفعة التسوية لا تُعدَّل ولا تُحذف أبدًا — هي لقطة مالية دائمة' using errcode = 'P0001';
end;
$$;

create trigger settlement_batch_lines_reject_update
  before update on public.settlement_batch_lines
  for each row
  execute function public.settlement_batch_lines_reject_mutation();

create trigger settlement_batch_lines_reject_delete
  before delete on public.settlement_batch_lines
  for each row
  execute function public.settlement_batch_lines_reject_mutation();

-- ---------------------------------------------------------------------------
create table public.settlement_source_claims (
  id uuid primary key default gen_random_uuid(),
  settlement_batch_id uuid not null references public.settlement_batches (id) on delete restrict,
  source_kind text not null check (source_kind in ('sale', 'return_refund', 'return_refund_reversal', 'adjustment_approved', 'adjustment_reversal', 'cod_collection', 'cod_reversal')),
  source_event_id uuid not null,
  claimed_at timestamptz not null default now(),
  claimed_by uuid references public.profiles (id) on delete set null,
  released_at timestamptz,
  released_by uuid references public.profiles (id) on delete set null,
  release_reason text,
  constraint settlement_source_claims_release_consistent check (
    (released_at is null and released_by is null and release_reason is null)
    or (released_at is not null and release_reason is not null)
  )
);

comment on table public.settlement_source_claims is
  'Phase 7 (item 25) — DB-level uniqueness that a source event can be effectively inside at most ONE batch at a time (settlement_source_claims_active_unique_idx below is the real invariant, not a client-side check). Cancelling a batch releases its claims (released_at/by/reason set — audit-safe UPDATE, the one sanctioned exception to this module''s append-only-correction convention, since a claim is a reservation record, not a financial fact) so the same source can be re-claimed by a future batch; the historical settlement_batch_lines row is NEVER touched by a release.';

create unique index settlement_source_claims_active_unique_idx
  on public.settlement_source_claims (source_kind, source_event_id)
  where released_at is null;

create index settlement_source_claims_batch_idx on public.settlement_source_claims (settlement_batch_id);

alter table public.settlement_source_claims enable row level security;
-- No RLS policy at all — internal bookkeeping table, never read directly by
-- the client; finalize/cancel_settlement_batch() (SECURITY DEFINER) are the
-- entire read/write surface.

create or replace function public.settlement_source_claims_reject_mutation()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'DELETE' then
    raise exception 'سجلات المطالبة بمصدر تسوية لا تُحذف أبدًا — تُحرَّر (release) بدلًا من ذلك' using errcode = 'P0001';
  end if;

  -- UPDATE: only a first-time release transition is allowed — every other
  -- field, and any SECOND release attempt, is rejected.
  if old.released_at is not null then
    raise exception 'سجل المطالبة هذا محرَّر بالفعل — لا يمكن تحريره مرة أخرى' using errcode = 'P0001';
  end if;
  if new.settlement_batch_id is distinct from old.settlement_batch_id
    or new.source_kind is distinct from old.source_kind
    or new.source_event_id is distinct from old.source_event_id
    or new.claimed_at is distinct from old.claimed_at
    or new.claimed_by is distinct from old.claimed_by
  then
    raise exception 'لا يمكن تعديل هوية سجل المطالبة — فقط تحريره مسموح' using errcode = 'P0001';
  end if;
  if new.released_at is null then
    raise exception 'التعديل المسموح الوحيد هو تحرير المطالبة (تعيين released_at)' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

create trigger settlement_source_claims_reject_mutation
  before update or delete on public.settlement_source_claims
  for each row
  execute function public.settlement_source_claims_reject_mutation();

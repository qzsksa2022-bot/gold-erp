-- ============================================================================
-- 0174: Phase 7 — Settlements Core (8/N): settlement_bank_movement_events +
-- settlement_bank_movement_reversals schema
-- ============================================================================
-- Migrations 0001-0173 are unmodified.
--
-- item 29 — actual bank movement is NEVER a directly-editable column on
-- settlement_batches; it is an append-only signed ledger. Positive = bank
-- deposit / carrier remittance received; negative = bank debit / processor
-- withdrawal — never assumed always-positive (item 29).
--
-- item 30 — any correction is a SEPARATE reversal row, never an UPDATE/
-- DELETE of the original movement. Max one reversal per movement event
-- (settlement_bank_movement_reversals.bank_movement_event_id UNIQUE).
-- ---------------------------------------------------------------------------
create table public.settlement_bank_movement_events (
  id uuid primary key default gen_random_uuid(),
  settlement_batch_id uuid not null references public.settlement_batches (id) on delete restrict,
  movement_business_date date not null,
  amount numeric(14, 2) not null check (amount <> 0),
  bank_reference text,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null
);

comment on table public.settlement_bank_movement_events is
  'Phase 7 (item 29) — append-only signed ledger of actual bank/carrier movements against a Finalized settlement batch. Positive = deposit/remittance received; negative = debit/withdrawal. INSERT-only, forever — corrections are a separate reversal row (settlement_bank_movement_reversals), never an UPDATE/DELETE here.';

create index settlement_bank_movement_events_batch_idx on public.settlement_bank_movement_events (settlement_batch_id);
create index settlement_bank_movement_events_date_idx on public.settlement_bank_movement_events (movement_business_date);

alter table public.settlement_bank_movement_events enable row level security;
-- No RLS policy at all (item 41) — record_settlement_bank_movement() (0179)
-- is the only writer; get_settlement_batch() (0182) is the only reader,
-- gated on settlements.view_financials + cross-store privacy (item 21).

create or replace function public.settlement_bank_movement_events_reject_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'حركات البنك المسجَّلة لا تُعدَّل ولا تُحذف أبدًا — سجِّل حركة عكسية (reverse_settlement_bank_movement) بدلًا من ذلك' using errcode = 'P0001';
end;
$$;

create trigger settlement_bank_movement_events_reject_update
  before update on public.settlement_bank_movement_events
  for each row
  execute function public.settlement_bank_movement_events_reject_mutation();

create trigger settlement_bank_movement_events_reject_delete
  before delete on public.settlement_bank_movement_events
  for each row
  execute function public.settlement_bank_movement_events_reject_mutation();

-- ---------------------------------------------------------------------------
create table public.settlement_bank_movement_reversals (
  id uuid primary key default gen_random_uuid(),
  bank_movement_event_id uuid not null unique references public.settlement_bank_movement_events (id) on delete restrict,
  reversal_business_date date not null,
  reason text not null,
  amount_impact numeric(14, 2) not null,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  constraint settlement_bank_movement_reversals_reason_required check (btrim(reason) <> '')
);

comment on table public.settlement_bank_movement_reversals is
  'Phase 7 (item 30) — at most ONE reversal per bank movement event (UNIQUE bank_movement_event_id), amount_impact = -original amount, written authoritatively by reverse_settlement_bank_movement() (0179), never a client-suppliable figure. INSERT-only, forever.';

create index settlement_bank_movement_reversals_batch_via_event_idx on public.settlement_bank_movement_reversals (bank_movement_event_id);

alter table public.settlement_bank_movement_reversals enable row level security;
-- No RLS policy at all — same posture as the events table above.

create or replace function public.settlement_bank_movement_reversals_reject_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'عكوس حركات البنك لا تُعدَّل ولا تُحذف أبدًا' using errcode = 'P0001';
end;
$$;

create trigger settlement_bank_movement_reversals_reject_update
  before update on public.settlement_bank_movement_reversals
  for each row
  execute function public.settlement_bank_movement_reversals_reject_mutation();

create trigger settlement_bank_movement_reversals_reject_delete
  before delete on public.settlement_bank_movement_reversals
  for each row
  execute function public.settlement_bank_movement_reversals_reject_mutation();

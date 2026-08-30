-- ============================================================================
-- 0175: Phase 7 — Settlements Core (9/N): settlement_batch_cancellations
-- schema
-- ============================================================================
-- Migrations 0001-0174 are unmodified.
--
-- item 17/33/34 — cancellation is a SEPARATE append-only event, exactly
-- mirroring how sales_order_adjustment_reversals (0135) never mutates the
-- original approved adjustment row. "effective_status = cancelled" is
-- computed at read time (item 17: "لا تجعل Client يستنتج effective
-- status") by get_settlement_batch()/list_settlement_batches() (0182)
-- checking for the existence of a cancellation row, never a status value
-- written back onto settlement_batches itself.
-- ---------------------------------------------------------------------------
create table public.settlement_batch_cancellations (
  id uuid primary key default gen_random_uuid(),
  settlement_batch_id uuid not null unique references public.settlement_batches (id) on delete restrict,
  cancellation_business_date date not null,
  reason text not null,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  constraint settlement_batch_cancellations_reason_required check (btrim(reason) <> '')
);

comment on table public.settlement_batch_cancellations is
  'Phase 7 (item 17/33/34) — append-only cancellation event, at most ONE per batch (UNIQUE settlement_batch_id). Never mutates settlement_batches/settlement_batch_lines/reconciliation history — those stay exactly as they were. "effective_status = cancelled" is derived by EXISTS(this table), never a stored status value.';

alter table public.settlement_batch_cancellations enable row level security;
-- No RLS policy at all — cancel_settlement_batch() (0181) is the only
-- writer; get_settlement_batch()/list_settlement_batches() (0182) are the
-- only readers.

create or replace function public.settlement_batch_cancellations_reject_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'سجلات إلغاء دفعات التسوية لا تُعدَّل ولا تُحذف أبدًا' using errcode = 'P0001';
end;
$$;

create trigger settlement_batch_cancellations_reject_update
  before update on public.settlement_batch_cancellations
  for each row
  execute function public.settlement_batch_cancellations_reject_mutation();

create trigger settlement_batch_cancellations_reject_delete
  before delete on public.settlement_batch_cancellations
  for each row
  execute function public.settlement_batch_cancellations_reject_mutation();

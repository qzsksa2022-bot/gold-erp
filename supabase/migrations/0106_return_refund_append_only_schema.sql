-- ============================================================================
-- 0106: Phase 4 — Final Hotfix 4.2.1 (1/7): append-only actual-refund-ledger
-- schema — sales_return_refund_event_reversals, reference/refund_method_
-- name_snapshot columns, payment_fee_reversal_calculation_version, legacy
-- backfill, and a protective trigger locking sales_return_refund_events
-- from any future UPDATE/DELETE.
-- ============================================================================
-- Migrations 0001-0105 are UNCHANGED. Every fix in this hotfix is additive
-- starting here. Still no Shipping / Settlements / Services-Adjustments /
-- Inventory / Reports work. Every fix from 0092-0105 (Patch 4.1/4.2) is
-- preserved untouched except where this hotfix's own migrations explicitly
-- CREATE OR REPLACE a function body.
--
-- ---------------------------------------------------------------------------
-- Part A — Section 1: sales_return_refund_event_reversals — the real
-- append-only fix.
-- ---------------------------------------------------------------------------
-- The bug: sales_return_refund_events (0082) was documented as "append-
-- only" but reverse_sales_return_refund_event() (0089/0097/0103) actually
-- ran an UPDATE against the SAME row (status/reversed_at/reversed_by/
-- reversal_reason/reversal_business_date) — a soft update, not append-only.
-- The original spec was explicit: no DELETE, no silent financial edit, and
-- a mistaken refund must be corrected by an INDEPENDENT reversal event
-- linked to the original, with the original row staying exactly as written.
--
-- Fix: a new, separate, genuinely insert-only table. A refund event's
-- effective status becomes DERIVED — active if no row here references it,
-- reversed if one does. unique(refund_event_id) makes "reverse the same
-- event twice" a constraint violation, not an application-level check that
-- could race.
create table public.sales_return_refund_event_reversals (
  id uuid primary key default gen_random_uuid(),
  refund_event_id uuid not null unique references public.sales_return_refund_events (id) on delete restrict,
  sales_return_id uuid not null references public.sales_returns (id) on delete restrict,
  reversal_business_date date not null,
  reversal_reason text not null,
  reversed_by uuid references public.profiles (id) on delete set null,
  reversed_at timestamptz not null default now()
);

comment on table public.sales_return_refund_event_reversals is
  'Hotfix 4.2.1 (Section 1) — the REAL append-only reversal ledger for sales_return_refund_events. A refund event is "reversed" if and only if a row here references it (unique(refund_event_id) makes double-reversal a constraint violation, not a race-prone application check) — never by mutating the original event row, which is now trigger-protected from UPDATE/DELETE (see Part D below). Written exclusively by reverse_sales_return_refund_event() (0107). amount/refund_method_id are NOT duplicated here (denormalized snapshot risk) — the original event row is immutable, so joining it is always accurate; only the reversal''s OWN facts (business date, reason, actor, timestamp) live here. Zero direct RLS policies for `authenticated` (same access model as every other Returns table since 0082) — the Returns RPCs are the only read/write path.';

create index sales_return_refund_event_reversals_return_idx
  on public.sales_return_refund_event_reversals (sales_return_id);

alter table public.sales_return_refund_event_reversals enable row level security;
-- Deliberately zero RLS policies for `authenticated` — same access model.

-- ---------------------------------------------------------------------------
-- Part B — Section 6/17: reference + refund_method_name_snapshot on the
-- original event.
-- ---------------------------------------------------------------------------
-- reference — a free-text external reference (bank transfer number,
-- payment-gateway reference, internal reference) that Phase 4's original
-- spec asked for and was never implemented. No uniqueness constraint —
-- different systems may format references differently, and a return could
-- legitimately be refunded partially via more than one instrument.
alter table public.sales_return_refund_events
  add column reference text;

comment on column public.sales_return_refund_events.reference is
  'Hotfix 4.2.1 (Section 6) — optional free-text external reference (bank transfer number, payment-gateway reference, internal reference). No uniqueness enforced. Permanent once set (this table is now trigger-protected from UPDATE, Part D below) — set only at INSERT time by record_sales_return_refund() (0107).';

-- refund_method_name_snapshot — a stable historical label, captured at
-- record time, so the Detail page never depends on payment_methods.view
-- (narrow lookup, 0105, is already record-time gated correctly) NOR on the
-- payment method's CURRENT name (which could be renamed/relabeled later)
-- to show what refund method a PAST event actually used.
alter table public.sales_return_refund_events
  add column refund_method_name_snapshot text;

comment on column public.sales_return_refund_events.refund_method_name_snapshot is
  'Hotfix 4.2.1 (Section 17) — a stable historical label for refund_method_id, captured at record time (record_sales_return_refund(), 0107) so the Detail view never depends on the payment method''s CURRENT name (which may be renamed later) nor on payment_methods.view. Backfilled once below (Part E) for every pre-existing event from the payment method''s name_ar as it stands today — the best available estimate for rows that predate this column, since no historical name was ever captured for them. Permanent once set (trigger-protected, Part D below).';

-- ---------------------------------------------------------------------------
-- Part C — Section 13: payment_fee_reversal_calculation_version on
-- sales_returns.
-- ---------------------------------------------------------------------------
-- Mirrors the established calculation_version convention already used on
-- sales_order_items (Sales phase) — a version marker attached at the moment
-- a financial figure is actually computed, NEVER silently recomputed onto
-- old rows by a later engine change. NULL for a return that has never been
-- approved (pending/rejected — no fee reversal was ever computed). Set once
-- at approval time (approve_sales_return(), 0109) and never touched again
-- (including by reverse_sales_return(), 0102, which flips is_effective but
-- never re-derives any financial figure — Patch 4.1 Section 6 convention).
alter table public.sales_returns
  add column payment_fee_reversal_calculation_version integer
    check (payment_fee_reversal_calculation_version is null or payment_fee_reversal_calculation_version in (1, 2));

comment on column public.sales_returns.payment_fee_reversal_calculation_version is
  'Hotfix 4.2.1 (Section 13) — 1 = payment_fee_reversal_amount was computed by the ORIGINAL compute_sales_return_fee_reversal() (item-value/returned_original_sale_amount basis, 0085-0101 — the bug this hotfix fixes). 2 = computed by compute_sales_return_fee_reversal_v2() (approved-refund-amount basis, 0109). NULL for a return that has never been approved. Backfilled to 1 below (Part E) for every pre-existing approved/reversed row — their historical payment_fee_reversal_amount is NEVER recomputed by this hotfix; only a NEW approval (any return, including a legacy Pending one approved after this hotfix) ever gets version 2. Set once at approval, never touched by reversal.';

-- ---------------------------------------------------------------------------
-- Part D — Section 1/3: lock sales_return_refund_events from UPDATE/DELETE.
-- ---------------------------------------------------------------------------
-- Installed AFTER the backfill below (Part E), which needs one UPDATE pass
-- to set refund_method_name_snapshot on pre-existing rows — that backfill
-- is the ONLY UPDATE this table will ever see again. From this point
-- forward, EVERY application code path (record_sales_return_refund() only
-- ever INSERTs; reverse_sales_return_refund_event() now inserts into
-- sales_return_refund_event_reversals instead, Part A/0107) never issues
-- UPDATE/DELETE against this table again — this trigger is a real,
-- unconditional backstop, not merely a convention. A future migration that
-- genuinely needs to alter this table's data (should never happen — the
-- whole point is that it doesn't) must explicitly DROP/DISABLE this trigger
-- first, which is itself a deliberate, visible, reviewable act.
create function public.reject_sales_return_refund_event_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'sales_return_refund_events سجل ثابت لا يقبل التعديل أو الحذف بعد إنشائه — أي تصحيح يجب أن يكون عبر sales_return_refund_event_reversals' using errcode = 'P0001';
end;
$$;

comment on function public.reject_sales_return_refund_event_mutation() is
  'Hotfix 4.2.1 (Section 3) — unconditional trigger backstop: sales_return_refund_events accepts INSERT only, forever. Any correction must go through sales_return_refund_event_reversals (Part A) instead.';

create trigger sales_return_refund_events_no_update
  before update on public.sales_return_refund_events
  for each row execute function public.reject_sales_return_refund_event_mutation();

create trigger sales_return_refund_events_no_delete
  before delete on public.sales_return_refund_events
  for each row execute function public.reject_sales_return_refund_event_mutation();

-- ---------------------------------------------------------------------------
-- Part E — Section 2/13: legacy backfill.
-- ---------------------------------------------------------------------------
-- Postgres executes this file top-to-bottom, so Part D's triggers are
-- already installed by the time this part's UPDATE (refund_method_name_
-- snapshot backfill) runs below. Rather than reordering the whole file
-- (burying the schema/trigger definition below a data migration), the
-- trigger function is redefined here with a narrow, migration-only escape
-- hatch: a session-local GUC no application RPC ever sets.
create or replace function public.reject_sales_return_refund_event_mutation()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('app.allow_refund_event_backfill', true), 'off') = 'on' then
    return coalesce(new, old);
  end if;
  raise exception 'sales_return_refund_events سجل ثابت لا يقبل التعديل أو الحذف بعد إنشائه — أي تصحيح يجب أن يكون عبر sales_return_refund_event_reversals' using errcode = 'P0001';
end;
$$;

do $$
begin
  perform set_config('app.allow_refund_event_backfill', 'on', true);

  -- Section 2 — Upgrade Safety: every pre-existing event with the legacy
  -- status='reversed' gets exactly one row in the new reversal table,
  -- carrying over its own historical reversal_reason/reversed_by/
  -- reversed_at/reversal_business_date verbatim. If reversal_business_date
  -- is NULL (a row old enough to predate that column, Patch 4.1 0097), the
  -- best documented estimate is used per spec: (reversed_at AT TIME ZONE
  -- 'Asia/Riyadh')::date — never a different invented date, and only when
  -- reversed_at itself is actually present (it always is, per the 0082
  -- table's own CHECK constraint requiring it whenever status='reversed').
  insert into public.sales_return_refund_event_reversals (
    refund_event_id, sales_return_id, reversal_business_date, reversal_reason, reversed_by, reversed_at
  )
  select
    e.id, e.sales_return_id,
    coalesce(e.reversal_business_date, (e.reversed_at at time zone 'Asia/Riyadh')::date),
    e.reversal_reason, e.reversed_by, e.reversed_at
  from public.sales_return_refund_events e
  where e.status = 'reversed';

  -- Section 17 — best-available historical label for every pre-existing
  -- event (this hotfix never captured a truer one at record time, since
  -- the column did not exist yet) — the payment method's CURRENT name_ar,
  -- documented explicitly as an estimate, not a claim of historical
  -- accuracy. reference stays NULL (no data ever existed to backfill it
  -- from).
  update public.sales_return_refund_events e
  set refund_method_name_snapshot = pm.name_ar
  from public.payment_methods pm
  where pm.id = e.refund_method_id and e.refund_method_name_snapshot is null;

  -- Section 13 — every pre-existing approved/reversed return was, by
  -- definition, approved under the ORIGINAL (item-value-basis)
  -- compute_sales_return_fee_reversal() — version 1. Their historical
  -- payment_fee_reversal_amount is NOT recomputed here or anywhere in this
  -- hotfix.
  update public.sales_returns
  set payment_fee_reversal_calculation_version = 1
  where status in ('approved', 'reversed') and payment_fee_reversal_calculation_version is null;

  perform set_config('app.allow_refund_event_backfill', 'off', true);
end $$;

comment on function public.reject_sales_return_refund_event_mutation() is
  'Hotfix 4.2.1 (Section 3) — unconditional trigger backstop against UPDATE/DELETE on sales_return_refund_events, with a single session-local GUC escape hatch (app.allow_refund_event_backfill) used ONLY by this migration''s own one-time backfill above. No application RPC ever sets this GUC — record_sales_return_refund() only INSERTs, reverse_sales_return_refund_event() (0107) inserts into sales_return_refund_event_reversals instead. A future migration needing a genuine one-time correction would use the same documented pattern, visibly, in its own file.';

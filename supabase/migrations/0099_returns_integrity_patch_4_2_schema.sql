-- ============================================================================
-- 0099: Final Returns Integrity Patch 4.2 (1/7): schema — legacy-pending
-- stale-sale invariant, legacy-approved financial backfill, refund
-- reconciliation history table
-- ============================================================================
-- Migrations 0001-0098 are UNCHANGED. Every fix in this patch is additive
-- starting here. No Shipping / Settlements / Services-Adjustments /
-- Inventory / Reports work. Every fix from 0092-0098 (Patch 4.1) is
-- preserved untouched except where this patch's own migrations explicitly
-- CREATE OR REPLACE a function body (never its access model or any other
-- already-correct behavior).
--
-- ---------------------------------------------------------------------------
-- Part A — Section 1: requires_sale_refresh, the real fix for the Upgrade
-- Safety gap in 0092's backfill.
-- ---------------------------------------------------------------------------
-- The bug: 0092 backfilled source_sale_row_version to the Sale's CURRENT
-- row_version for every pre-existing return, including still-PENDING ones.
-- For a legacy Pending return, that is informational at best and WRONG at
-- worst — the return's actual sales_return_items.*_snapshot columns were
-- captured under the OLD (pre-0092) create_sales_return(), at whatever
-- row_version the Sale was at back then. If the Sale was edited AGAIN after
-- that snapshot but BEFORE this patch is applied, 0092's backfill makes
-- source_sale_row_version equal the Sale's row_version as of the upgrade —
-- which now also happens to be the Sale's CURRENT row_version, since no
-- further edit occurred between upgrade and this approval attempt. Patch
-- 4.1's approve_sales_return() stale-sale guard (0095) compares v_order.
-- row_version = v_old_return.source_sale_row_version and sees them equal —
-- and approves a return whose ITEM snapshots are actually stale. A silent
-- financial-integrity gap that 0092's own backfill introduced.
--
-- Fix: an explicit, independent boolean invariant. Any return that was
-- already PENDING when 0092/4.1 applied can never be trusted to have a
-- reliable source_sale_row_version <-> item-snapshot correspondence, no
-- matter what row_version arithmetic says — it must go through the ONE
-- explicit, human-reviewed refresh path before it can ever be approved.
-- ---------------------------------------------------------------------------
alter table public.sales_returns
  add column requires_sale_refresh boolean not null default false;

comment on column public.sales_returns.requires_sale_refresh is
  'Patch 4.2 (Section 1) — TRUE means this Pending return''s item/header snapshots cannot be trusted to correspond to source_sale_row_version, and approve_sales_return() (0101) MUST reject approval outright until refresh_pending_sales_return_from_sale() (0100) is called explicitly (which also clears this flag). Backfilled TRUE for every return that was already ''pending'' at the moment this migration ran (Patch 4.1''s 0092 backfill could not distinguish a reliably-fresh row_version match from a coincidentally-matching stale one — see this migration''s header comment). create_sales_return() (0100) always inserts FALSE for a brand-new return, since it captures the snapshot and source_sale_row_version together, atomically, in the same statement — there is no window for them to diverge at creation time. Never reset to TRUE by any other writer; never consulted for a non-pending return (irrelevant once decided).';

-- Every return still 'pending' at the moment of this upgrade needs an
-- explicit refresh before it can ever be approved — regardless of whether
-- it was created before OR after 0092 (a return created under Patch 4.1's
-- own create_sales_return(), 0093, reliably has a fresh
-- source_sale_row_version; flagging it too is a harmless one-time refresh
-- requirement, strictly safer than trying to distinguish the two cases by
-- created_at, which the spec explicitly calls out as sufficient: "أقصى شيء
-- سيحتاج Refresh صريح مرة واحدة").
update public.sales_returns
set requires_sale_refresh = true
where status = 'pending';

-- ---------------------------------------------------------------------------
-- Part B — Section 2: legacy financial backfill for Approved/Reversed
-- returns that predate Patch 4.1's Section 12 fields.
-- ---------------------------------------------------------------------------
-- The bug: 0092 backfilled is_effective/included_in_decision/sale_date_
-- snapshot/source_sale_row_version for EVERY pre-existing return, but never
-- touched returned_original_sale_amount/recovered_original_cost_amount/
-- net_sales_profit_adjustment — those three columns stayed NULL for any
-- return that was already 'approved'/'reversed' before this patch series
-- began (they are written ONLY by approve_sales_return(), and a legacy row
-- was approved by the OLD, pre-0095 version of that function, which knew
-- nothing about these columns). get_returnable_sales_order()/get_sales_
-- return()/list_sales_returns() (0098) compute adjusted_order_net_sales_
-- profit as so.net_sales_profit + SUM(net_sales_profit_adjustment) over
-- approved returns — SUM() silently treats a NULL as "contributes nothing",
-- so a legacy Approved return's real, already-realized profit impact simply
-- never appeared in the adjusted total. A financial correctness gap, not
-- merely a display gap.
--
-- Fix: a one-time, narrowly-scoped backfill UPDATE — touches ONLY rows
-- where status IN ('approved','reversed') AND returned_original_sale_amount
-- IS NULL (i.e. a row approve_sales_return() 0095+ never wrote to; a row
-- approved under 0095+ already has a real, correct value here and this
-- WHERE clause skips it untouched). Sourced entirely from this return's OWN
-- historical sales_return_items snapshots (never re-reads sales_order_items
-- master data, which may have changed since) — the exact same status='
-- active' OR included_in_decision=true predicate get_sales_return() (0098)
-- already uses to define "this return's final historical item set", so the
-- figure computed here is definitionally identical to what a contemporary
-- approve_sales_return() call would have produced from the same items.
-- Every OTHER existing column (approved_refund_amount, payment_fee_
-- reversal_amount, sales_revenue_reversal_amount, refund_fee_policy_
-- snapshot, status, approved_at/reversed_at and every *_by/*_reason) is
-- read here, never written — this backfill adds three previously-missing
-- figures, it does not re-derive or second-guess anything already recorded.
-- collection_state is deliberately NOT guessed for these legacy rows — it
-- already defaulted to 'unknown' when 0092 added the column, and stays
-- there; Patch 4.1/4.2 never invent a historical fact that was not
-- actually recorded at the time.
-- ---------------------------------------------------------------------------
with legacy_item_totals as (
  select
    sri.sales_return_id,
    coalesce(sum(sri.sale_price_snapshot), 0) as returned_original_sale_amount,
    coalesce(sum(sri.total_cost_snapshot), 0) as recovered_original_cost_amount
  from public.sales_return_items sri
  where sri.status = 'active' or sri.included_in_decision = true
  group by sri.sales_return_id
)
update public.sales_returns sr
set returned_original_sale_amount = round(t.returned_original_sale_amount, 2),
    recovered_original_cost_amount = round(t.recovered_original_cost_amount, 2),
    -- Section 12's own formula, unchanged: -revenue_reversal + recovered_cost
    -- + fee_reversal. sales_revenue_reversal_amount/payment_fee_reversal_
    -- amount already existed pre-Patch-4.1 (written by the OLD approve_
    -- sales_return()) and are read here exactly as already stored, never
    -- recomputed.
    net_sales_profit_adjustment = round(
      -coalesce(sr.sales_revenue_reversal_amount, 0) + t.recovered_original_cost_amount + coalesce(sr.payment_fee_reversal_amount, 0),
      2
    )
from legacy_item_totals t
where t.sales_return_id = sr.id
  and sr.status in ('approved', 'reversed')
  and sr.returned_original_sale_amount is null;

comment on column public.sales_returns.returned_original_sale_amount is
  'Patch 4.1 (Section 1/12) — SUM(sale_price_snapshot) of this return''s active items, written ONLY at approval by approve_sales_return() (0101). Distinct from sales_revenue_reversal_amount (= this minus the deduction) and from approved_refund_amount (a separate, explicitly-set figure — Section 1). Patch 4.2 (0099): every pre-existing Approved/Reversed return that predated this column''s introduction (0092) was backfilled once from its own historical sales_return_items snapshots (status=''active'' OR included_in_decision=true) — see 0099''s header comment for why 0092''s own backfill could not do this safely at schema-migration time.';
comment on column public.sales_returns.recovered_original_cost_amount is
  'Patch 4.1 (Section 1/12) — SUM(total_cost_snapshot) of this return''s active items, written ONLY at approval. Profit-sensitive (sales.view_profit). Patch 4.2 (0099): backfilled once for every pre-existing Approved/Reversed return — see returned_original_sale_amount''s comment and 0099''s header comment.';
comment on column public.sales_returns.net_sales_profit_adjustment is
  'Patch 4.1 (Section 12) — -sales_revenue_reversal_amount + recovered_original_cost_amount + payment_fee_reversal_amount, written ONLY at approval. This, not gross/net_profit_reversal_amount, is the authoritative profit-adjustment figure going forward. Profit-sensitive. Patch 4.2 (0099): backfilled once for every pre-existing Approved/Reversed return using its OWN already-stored sales_revenue_reversal_amount/payment_fee_reversal_amount plus the freshly-backfilled recovered_original_cost_amount — without this, adjusted_order_net_sales_profit (0098/0104) silently treated every legacy Approved return''s real profit impact as zero (SUM() skips NULL). See 0099''s header comment.';

-- ---------------------------------------------------------------------------
-- Part C — Section 4: append-only refund reconciliation history. finalize_
-- sales_return_refund()/reopen_sales_return_refund_reconciliation() (0103)
-- write here; sales_returns.refund_finalized_at/by/refund_final_variance_
-- reason (0092) remain the CURRENT-state columns (unchanged shape/meaning),
-- this table is the full history of every finalize/reopen transition that
-- ever happened, in order — nothing here is ever updated or deleted.
-- ---------------------------------------------------------------------------
create table public.sales_return_refund_reconciliation_events (
  id uuid primary key default gen_random_uuid(),
  sales_return_id uuid not null references public.sales_returns (id) on delete restrict,
  event_type text not null check (event_type in ('finalized', 'reopened')),
  actual_refunded_total numeric(14, 2) not null,
  approved_refund_amount numeric(14, 2),
  variance numeric(14, 2) not null,
  reason text,
  actor uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

comment on table public.sales_return_refund_reconciliation_events is
  'Patch 4.2 (Section 4) — append-only history of every refund-reconciliation state transition (finalized/reopened) for a return, written exclusively by finalize_sales_return_refund()/reopen_sales_return_refund_reconciliation() (0103). A return can be finalized, reopened, and finalized again any number of times; every transition is preserved here permanently (never updated/deleted), each with its own point-in-time snapshot of actual_refunded_total/approved_refund_amount/variance/reason/actor — sales_returns.refund_finalized_at/by/refund_final_variance_reason (0092) remain the CURRENT-state columns only, reflecting the most recent transition. Zero direct RLS policies for `authenticated` (same access model as every other Returns table since 0082) — get_sales_return() (0104) is the only read path.';

create index sales_return_refund_reconciliation_events_return_idx
  on public.sales_return_refund_reconciliation_events (sales_return_id, created_at);

-- Zero policies, exactly like sales_returns/sales_return_items/sales_
-- return_refund_events (0082) — SECURITY DEFINER RPCs (finalize_sales_
-- return_refund()/reopen_sales_return_refund_reconciliation()/get_sales_
-- return(), 0103/0104) are the only read/write path for `authenticated`.
alter table public.sales_return_refund_reconciliation_events enable row level security;

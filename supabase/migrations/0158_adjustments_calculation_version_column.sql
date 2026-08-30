-- ============================================================================
-- 0158: Phase 6 Final Integrity Hotfix 6.1.1 (2/6): calculation_version
-- column (schema + backfill)
-- ============================================================================
-- Migrations 0001-0157 are unmodified.
--
-- Hotfix 6.1.1 item 7 — the original Phase 6 requirement asked for a
-- calculation_version to track which version of the profit-calculation
-- engine an APPROVED record's financial snapshot was computed under, but no
-- such column was ever added (0133-0157). This migration adds the column
-- and backfills every EXISTING approved row deterministically to 1 — every
-- approved row so far (Phase 6 Core through Patch 6.1) was computed by the
-- exact same, single calculation contract that has existed since
-- approve_sales_order_adjustment() was first introduced (0140/0148), so
-- there is only ever one legitimate historical value to backfill to, never
-- an invented one.
--
-- Contract (written authoritatively by approve_sales_order_adjustment() v3,
-- 0159 — never accepted as a client input on any RPC):
--   pending / rejected (never financially approved) -> NULL.
--   approved                                        -> 1 (current engine).
--   reversed (still an approved row underneath, §16/0142) -> keeps its
--     ORIGINAL approval's calculation_version untouched — the reversal
--     records a separate administrative event (sales_order_adjustment_
--     reversals) and never mutates the original row's approval facts.
-- ---------------------------------------------------------------------------
alter table public.sales_order_adjustments
  add column calculation_version integer;

comment on column public.sales_order_adjustments.calculation_version is
  'Hotfix 6.1.1 item 7 — which version of the profit-calculation engine this row''s financial snapshot (direct_cost/payment_fee_amount/gross_adjustment_profit/net_adjustment_profit) was computed under. NULL while pending/rejected (never approved, nothing to version). Written ONLY by approve_sales_order_adjustment() (0159) — never a client-supplied RPC parameter. A reversal never changes it (the original approval fact is immutable).';

-- The backfill MUST run BEFORE the CHECK constraint below is added: a real
-- database upgrading from 0001-0157 (or from the still-under-review
-- 0144-0156 draft) can already contain APPROVED rows created before this
-- column existed — every one of them starts out NULL immediately after the
-- ADD COLUMN above, which would violate a "approved => not null" constraint
-- validated at ADD TIME. Backfilling first, then adding the constraint,
-- is the same ordering lesson already applied in 0144/0150 (see
-- TEST_RESULTS_PATCH_6_1.md §2) — deliberately re-applied here rather than
-- repeated as a fresh mistake.
--
-- The backfill UPDATE is also blocked by 0154's own sales_order_
-- adjustments_reject_terminal_mutation trigger (ANY update to an approved/
-- rejected row is unconditionally rejected, even a migration's own
-- backfill) — the SAME class of bug already hit and fixed once in 0150 for
-- the reversals table's own append-only trigger. Bracketing this single
-- UPDATE with DISABLE/ENABLE TRIGGER, exactly like 0150 already does, is
-- the fix.
alter table public.sales_order_adjustments disable trigger sales_order_adjustments_reject_terminal_mutation;

do $$
declare
  v_backfilled integer;
begin
  with backfilled as (
    update public.sales_order_adjustments
    set calculation_version = 1
    where status = 'approved' and calculation_version is null
    returning 1
  )
  select count(*) into v_backfilled from backfilled;

  raise notice 'Hotfix 6.1.1 item 7: % صف معتمَد أُعيد ضبط calculation_version له إلى 1 (النسخة الوحيدة التاريخية الموجودة لمحرك الحساب حتى الآن)', v_backfilled;
end $$;

alter table public.sales_order_adjustments enable trigger sales_order_adjustments_reject_terminal_mutation;

alter table public.sales_order_adjustments
  add constraint sales_order_adjustments_calculation_version_consistent check (
    (status = 'approved' and calculation_version is not null)
    or (status <> 'approved' and calculation_version is null)
  );

comment on constraint sales_order_adjustments_calculation_version_consistent on public.sales_order_adjustments is
  'Hotfix 6.1.1 item 7 — calculation_version is set if and only if the row is (or was, and remains underneath a reversal) approved; NULL for pending/rejected. Enforced at the DB level so no RPC bug can leave an approved row unversioned or a non-approved row carrying a stray version.';

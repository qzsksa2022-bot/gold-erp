-- ============================================================================
-- Phase 8 — Final Integrity Hotfix 8.1.1 — §28-31 CRITICAL follow-up:
-- _report_settlement_batch_in_store_scope() must be vacuously TRUE for a
-- batch with zero settlement_batch_lines (a still-draft batch), matching
-- the ALREADY-ESTABLISHED, correct polarity of the Settlements domain's own
-- _settlement_batch_all_stores_visible() (0186, §6/§7) -- not silently
-- exclude it.
-- ============================================================================
-- Migrations 0001-0219 are FROZEN. This migration only ADDS 0220+.
--
-- The bug (discovered while writing this hotfix's own SQL regression
-- coverage for §28-31's "Draft effective_status is a real, working filter"
-- claim, hotfix_8_1_1_reports_exports.test.sql section B): a genuinely
-- draft settlement_batches row structurally has ZERO settlement_batch_lines
-- rows -- create_draft_settlement_batch() (0177) "reserves NOTHING
-- financially: no settlement_source_claims row is created, no
-- settlement_batch_lines row is created" -- lines are only ever inserted by
-- finalize_settlement_batch() (0178/0185). _report_settlement_batch_in_
-- store_scope() (0200), used by get_settlements_report() (0218) and every
-- other Reports/Dashboard reader of settlement_batches, required
-- `exists (select 1 from settlement_batch_lines where settlement_batch_id
-- = p_settlement_batch_id)` as its FIRST condition -- so a zero-line batch
-- was ALWAYS excluded from scope, regardless of store filter, regardless
-- of the actor's own store_access_scope. That made 0218's own
-- p_effective_status='draft' fix dead code in practice: a never-finalized
-- draft batch (the only kind that can ever have status='draft' -- see
-- settlement_batches_reject_financial_mutation, 0172) could never actually
-- appear in get_settlements_report()'s rows, no matter how correctly the
-- rest of the filter pipeline handled it.
--
-- The Settlements domain's own equivalent helper,
-- _settlement_batch_all_stores_visible() (0186, §6/§7), already gets this
-- exactly right: "Vacuously true for a batch with zero lines (a draft --
-- nothing to hide yet, see §7's own separate privacy contract for
-- drafts)." This migration brings _report_settlement_batch_in_store_scope()
-- to that same, already-proven-correct polarity: a batch with NO lines at
-- all is now IN scope (there is nothing store-specific to hide/exclude
-- yet); a batch with >=1 line is unchanged from before -- in scope only if
-- EVERY line's primary store (and secondary store, when set) is within
-- p_store_ids.
--
-- Safety for every other existing caller (get_dashboard_summary x2,
-- get_payment_methods_report, get_cod_report, get_settlements_report x2 via
-- 0212/0218, the daily/weekly/monthly/yearly settlements reports): every
-- one of them restricts its own batch source to
-- `status in ('finalized', 'reconciled')` (either inline or via
-- settle_finalized_scoped/equivalent), and a finalized-or-reconciled batch
-- ALWAYS has >=1 line by construction (finalize_settlement_batch is the
-- only writer of settlement_batch_lines, and it always writes at least the
-- batch's own selected sources). So the zero-lines branch was previously
-- unreachable dead code for every one of those call sites -- this change
-- is a pure no-op for all of them, and only starts actually mattering for
-- get_settlements_report()'s own new p_effective_status='draft' path
-- (0218), which is exactly the case it needed to unblock.
--
-- Signature is UNCHANGED from 0200 -- body-only fix, CREATE OR REPLACE
-- directly (§0, no DROP needed).
-- ============================================================================
begin;

create or replace function public._report_settlement_batch_in_store_scope(p_settlement_batch_id uuid, p_store_ids uuid[])
returns boolean
language sql
stable
as $$
  select not exists (
    select 1 from public.settlement_batch_lines l
    where l.settlement_batch_id = p_settlement_batch_id
      and (
        not (l.primary_store_id = any (p_store_ids))
        or (l.secondary_store_id is not null and not (l.secondary_store_id = any (p_store_ids)))
      )
  );
$$;

comment on function public._report_settlement_batch_in_store_scope(uuid, uuid[]) is
  'Phase 8 §8/§9 (internal), fixed by Hotfix 8.1.1 §28-31 follow-up (0220): true iff settlement batch p_settlement_batch_id has EVERY line''s primary AND secondary store (when set) within p_store_ids -- now VACUOUSLY TRUE for a batch with zero lines (a still-draft batch -- nothing store-specific to hide yet), matching _settlement_batch_all_stores_visible()''s (0186) already-correct polarity, instead of the previous always-FALSE-on-zero-lines bug that made get_settlements_report()''s p_effective_status=''draft'' filter (0218) permanently return zero rows for any genuinely-unfinalized draft batch. Reused by get_dashboard_summary() (0200), get_payment_methods_report() (0207), get_cod_report() (0209/0216), get_settlements_report() (0212/0218), the daily/weekly/monthly/yearly settlements reports (0204), and the payment-methods settlement historical-labels fix (0217) -- every one of those restricts its own batch source to finalized/reconciled batches, which always have >=1 line by construction, so this fix is a pure no-op for all of them.';

commit;

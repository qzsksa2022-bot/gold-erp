-- ============================================================================
-- 0163: Phase 6 Final Audit & Invariant Hotfix 6.1.2 (1/4): calculation_version
-- strict exact-value invariant
-- ============================================================================
-- Migrations 0001-0162 are unmodified (Hotfix 6.1.2 freeze rule — every fix
-- this round is a brand-new migration starting at 0163; nothing before it is
-- touched, including 0144, which was the one-time explicitly-sanctioned
-- exception for the PREVIOUS round only and does not carry forward).
--
-- Hotfix 6.1.2 item 2 (BLOCKER) — 0158's
-- sales_order_adjustments_calculation_version_consistent CHECK only enforces
-- "approved <=> calculation_version IS NOT NULL". That is too loose: an
-- approved row with calculation_version = 2, 99, or -1 currently satisfies
-- the constraint even though no such calculation engine version has ever
-- existed. The column exists specifically to pin which engine computed the
-- row's financial snapshot (0158), so the DB itself must reject any value
-- other than the one real, currently-existing engine version.
--
-- This migration replaces the constraint with the literal invariant:
--   (status = 'approved' AND calculation_version = 1)
--   OR (status <> 'approved' AND calculation_version IS NULL)
--
-- No other value is accepted for an approved row until/unless a future,
-- explicit migration deliberately introduces a v2 calculation engine and
-- loosens this contract on purpose. Until such a migration exists, 1 is the
-- only legitimate value approve_sales_order_adjustment() may ever write
-- (0159, unchanged in behavior by this migration — only its audit payload is
-- touched, separately, by 0165).
-- ---------------------------------------------------------------------------
alter table public.sales_order_adjustments
  drop constraint sales_order_adjustments_calculation_version_consistent;

alter table public.sales_order_adjustments
  add constraint sales_order_adjustments_calculation_version_consistent check (
    (status = 'approved' and calculation_version = 1)
    or (status <> 'approved' and calculation_version is null)
  );

comment on constraint sales_order_adjustments_calculation_version_consistent on public.sales_order_adjustments is
  'Hotfix 6.1.2 item 2 — closed, exact-value contract: an approved row''s calculation_version MUST equal 1 (the only calculation engine that has ever existed); a non-approved row''s calculation_version MUST be NULL. No other value is accepted. A future v2 engine requires its own explicit migration to deliberately loosen this constraint — it must never be loosened implicitly or by omission.';

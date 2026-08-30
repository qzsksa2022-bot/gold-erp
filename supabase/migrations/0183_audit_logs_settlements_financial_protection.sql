-- ============================================================================
-- 0183: Phase 7 — Settlements Core (17/N): audit_logs RLS — gate financial
-- settlement.* actions behind settlements.view_financials
-- ============================================================================
-- Migrations 0001-0182 are unmodified. Mirrors 0072/0091/0121/0143/0156's
-- exact pattern, extended for Settlements' own action namespace.
--
-- Gated (carries a money figure, requires settlements.view_financials in
-- addition to audit_logs.view):
--   settlement.finalize            — gross/fee/batch-fee/expected payload.
--   settlement.bank_movement       — signed bank-movement amount.
--   settlement.bank_movement_reverse — amount_impact.
--   settlement.reconcile           — actual/expected/variance payload.
--   settlement.cancel              — undoes a money-claiming batch (mirrors
--                                     adjustment.reverse staying gated even
--                                     though this project's convention is:
--                                     any action that unwinds a financial
--                                     claim is treated as financial).
--   settlement.batch_fee_override  — configured/override batch-fee values.
--
-- Deliberately left UNGATED (name/code/status/reason only, no money figure
-- — mirrors adjustment_type.*/adjustment.closed_day_override staying
-- ungated, and payment_method_fee_version.create/cancel never having been
-- gated at all despite carrying fee CONFIGURATION, not a source's money):
--   settlement.create, settlement.update (draft header only — a draft
--     reserves nothing financially, item 18).
--   settlement.closed_day_override (reason + settlement_number only).
--   settlement_route.create/update/disable/enable (0169).
--   settlement_route_fee_version.create/cancel (0171 — fee % / fixed
--     CONFIGURATION, the same class of Master Data that has never been
--     gated in this codebase, e.g. payment_method_fee_version).
-- ---------------------------------------------------------------------------
drop policy audit_logs_select on public.audit_logs;

create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    public.has_permission('audit_logs.view')
    and (
      (
        action not like 'sale.%'
        and action not like 'return.%'
        and action not in (
          'shipment.create', 'shipment.cost_record', 'shipment.cost_correct', 'shipment.charge_correct',
          'shipping_rate.create', 'shipping_rate.cancel',
          'customer_return_shipping_fee.create', 'customer_return_shipping_fee.cancel',
          'adjustment.create', 'adjustment.update', 'adjustment.approve', 'adjustment.reverse', 'adjustment.cost_set',
          'settlement.finalize', 'settlement.bank_movement', 'settlement.bank_movement_reverse',
          'settlement.reconcile', 'settlement.cancel', 'settlement.batch_fee_override'
        )
      )
      or public.has_permission('sales.view_profit')
      or public.has_permission('settlements.view_financials')
    )
  );

comment on policy audit_logs_select on public.audit_logs is
  'audit_logs.view alone grants every action outside sale.%/return.% (0072/0091), outside the four financial shipment.* actions (0121), outside the four Rate-Configuration actions (0124), outside the five financial adjustment.* actions (0143/0156), and outside the six financial settlement.* actions (0183: finalize/bank_movement/bank_movement_reverse/reconcile/cancel/batch_fee_override). A row matching any sales/returns/shipment/adjustment gated action additionally requires sales.view_profit; a row matching any gated settlement.* action additionally requires settlements.view_financials (its own module''s financial-visibility permission, deliberately not sales.view_profit — Settlements has its own view/view_financials split, item 40). settlement.create/update/closed_day_override and every settlement_route.*/settlement_route_fee_version.* action remain UNGATED (no money figure carried). Enforced in RLS, holds against every access path including a raw PostgREST request.';

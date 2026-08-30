-- ============================================================================
-- 0187: Phase 7 — Integrity Patch 7.1 (4/N): audit_logs RLS — separate,
-- non-overlapping permission branches (§8), settlement_route_fee_version
-- audit gating decision (§9).
-- ============================================================================
-- Migrations 0001-0186 are FROZEN.
--
-- §8 (CRITICAL) — 0183's audit_logs_select ended its financial branch with
-- `... or public.has_permission('sales.view_profit') or public.has_
-- permission('settlements.view_financials')` — a GLOBAL OR across BOTH
-- permissions applied to BOTH domains' gated actions. That meant an actor
-- holding ONLY sales.view_profit could read Settlements' financial audit
-- entries (finalize/bank_movement/reconcile/cancel/batch_fee_override
-- payloads carrying gross/fee/expected/actual/variance figures) without
-- ever holding settlements.view_financials, and symmetrically an actor
-- holding ONLY settlements.view_financials could read Sales/Returns/
-- Shipping/Adjustments' financial audit entries without sales.view_profit
-- — a real cross-domain permission leak, not merely redundant grants.
--
-- Fix: three genuinely separate branches, joined by OR at the TOP level
-- only (never inside a shared financial clause):
--   (A) Sales/Returns/Shipping/Adjustments financial actions — audit_logs.
--       view + sales.view_profit. settlements.view_financials grants
--       NOTHING here.
--   (B) Settlements financial actions — audit_logs.view + settlements.
--       view_financials. sales.view_profit grants NOTHING here.
--   (C) every other (non-financial) action — audit_logs.view alone.
-- Every action classified into exactly one of A/B/C (verified against
-- 0072/0091/0121/0124/0143/0156/0183's own action lists — reproduced
-- verbatim below, nothing added or dropped except §9's addition to B).
--
-- §9 — settlement_route_fee_version.create/cancel (0171) carries real
-- percentage_fee/fixed_fee/batch_fee_fixed CONFIGURATION values. 0183
-- originally left these ungated (matching payment_method_fee_version.*,
-- never gated anywhere in this codebase). Patch 7.1 §9 revisits this
-- explicitly and states a preference: gate an audit action behind
-- settlements.view_financials whenever its payload carries a real money
-- figure — chosen here over the old precedent-matching rationale, since
-- the patch's own instruction is the more specific, more recent authority
-- on this exact question. This does NOT block settlements.manage_routes
-- (route/fee-version management) itself — audit_logs SELECT visibility is
-- an entirely separate permission axis from the RPCs that write these
-- rows; a manage_routes-only actor keeps full ability to create/cancel fee
-- versions, they simply won't see those two action kinds in the Audit Log
-- view without settlements.view_financials too. Added to Branch B above
-- (Settlements' OWN financial-visibility permission — not sales.view_
-- profit, consistent with settlement.finalize etc.).
-- ---------------------------------------------------------------------------
drop policy audit_logs_select on public.audit_logs;

create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    public.has_permission('audit_logs.view')
    and (
      -- Branch C — every action NOT in Branch A or Branch B below needs
      -- nothing more than audit_logs.view.
      (
        action not like 'sale.%'
        and action not like 'return.%'
        and action not in (
          'shipment.create', 'shipment.cost_record', 'shipment.cost_correct', 'shipment.charge_correct',
          'shipping_rate.create', 'shipping_rate.cancel',
          'customer_return_shipping_fee.create', 'customer_return_shipping_fee.cancel',
          'adjustment.create', 'adjustment.update', 'adjustment.approve', 'adjustment.reverse', 'adjustment.cost_set',
          'settlement.finalize', 'settlement.bank_movement', 'settlement.bank_movement_reverse',
          'settlement.reconcile', 'settlement.cancel', 'settlement.batch_fee_override',
          'settlement_route_fee_version.create', 'settlement_route_fee_version.cancel'
        )
      )
      or (
        -- Branch A — Sales/Returns/Shipping/Adjustments financial actions.
        -- settlements.view_financials grants NOTHING in this branch.
        (
          action like 'sale.%'
          or action like 'return.%'
          or action in (
            'shipment.create', 'shipment.cost_record', 'shipment.cost_correct', 'shipment.charge_correct',
            'shipping_rate.create', 'shipping_rate.cancel',
            'customer_return_shipping_fee.create', 'customer_return_shipping_fee.cancel',
            'adjustment.create', 'adjustment.update', 'adjustment.approve', 'adjustment.reverse', 'adjustment.cost_set'
          )
        )
        and public.has_permission('sales.view_profit')
      )
      or (
        -- Branch B — Settlements financial actions (own module's own
        -- financial-visibility permission). sales.view_profit grants
        -- NOTHING in this branch.
        action in (
          'settlement.finalize', 'settlement.bank_movement', 'settlement.bank_movement_reverse',
          'settlement.reconcile', 'settlement.cancel', 'settlement.batch_fee_override',
          'settlement_route_fee_version.create', 'settlement_route_fee_version.cancel'
        )
        and public.has_permission('settlements.view_financials')
      )
    )
  );

comment on policy audit_logs_select on public.audit_logs is
  'Patch 7.1 §8/§9 — audit_logs.view alone grants every NON-financial action (Branch C). Branch A (Sales/Returns/Shipping/Adjustments financial actions) additionally requires sales.view_profit — settlements.view_financials grants nothing here. Branch B (Settlements financial actions, INCLUDING settlement_route_fee_version.create/cancel as of §9) additionally requires settlements.view_financials — sales.view_profit grants nothing here. The two permissions are never OR''d together across domains (0183''s bug). settlement.create/update/closed_day_override and settlement_route.*/settlement_route_fee_version.create/cancel''s CREATION (only its AUDIT READ is now gated, not the RPC itself) remain otherwise as documented in 0183. Enforced in RLS, holds against every access path including a raw PostgREST request.';

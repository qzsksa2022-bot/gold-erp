-- ============================================================================
-- 0143: Phase 6 — Services / Adjustments Core (11/11): audit_logs profit
-- protection for adjustment.* (§34, fine-grained — mirrors 0121/0124's
-- exact-action-name approach, NOT the blanket prefix approach used for
-- sale.%/return.%)
-- ============================================================================
-- Migrations 0001-0142 are unmodified.
--
-- adjustment.create/update/approve/reverse each carry a money payload
-- (customer_charge/direct_cost/payment_fee_amount/gross_adjustment_profit/
-- net_adjustment_profit in old_values/new_values) — gated behind sales.
-- view_profit, reused verbatim (no separate adjustments.view_profit
-- permission). adjustment.reject (reason only, no money) and adjustment.
-- closed_day_override/adjustment_type.create/update/disable/enable (name/
-- code/status/reason only, never a money figure) remain UNGATED — audit_
-- logs.view alone is enough, exactly like shipment.status_add/shipment.
-- closed_day_override staying ungated in 0121.
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
          'adjustment.create', 'adjustment.update', 'adjustment.approve', 'adjustment.reverse'
        )
      )
      or public.has_permission('sales.view_profit')
    )
  );

comment on policy audit_logs_select on public.audit_logs is
  'audit_logs.view alone grants every action outside sale.%/return.% (0072/0091), outside the four financial shipment.* actions (0121), outside the four Rate-Configuration actions (0124), and outside the four financial adjustment.* actions added by Phase 6 (0143): adjustment.create/update/approve/reverse each carry customer_charge/direct_cost/payment_fee_amount/gross_adjustment_profit/net_adjustment_profit. adjustment.reject/adjustment.closed_day_override AND adjustment_type.create/update/disable/enable (name/code/status/reason only, never a money figure) remain UNGATED. A row matching any gated action additionally requires sales.view_profit — reused verbatim, no separate adjustments.view_profit permission. Enforced in RLS, holds against every access path including a raw PostgREST request.';

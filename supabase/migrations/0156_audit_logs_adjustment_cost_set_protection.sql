-- ============================================================================
-- 0156: Phase 6 Integrity Patch 6.1 (13/13): audit_logs profit protection
-- for the new adjustment.cost_set action (0145's dedicated cost RPC)
-- ============================================================================
-- Migrations 0001-0155 are unmodified.
--
-- adjustment.cost_set (0145) carries a direct_cost money payload in its
-- old_values/new_values, exactly like adjustment.create/update/approve/
-- reverse (0143) — it must be gated behind sales.view_profit the same way,
-- reusing the same policy shape 0143 established (fine-grained exact-action
-- list, NOT a blanket adjustment.% prefix — adjustment.reject/adjustment_
-- type.*/adjustment.closed_day_override remain ungated).
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
          'adjustment.create', 'adjustment.update', 'adjustment.approve', 'adjustment.reverse', 'adjustment.cost_set'
        )
      )
      or public.has_permission('sales.view_profit')
    )
  );

comment on policy audit_logs_select on public.audit_logs is
  'audit_logs.view alone grants every action outside sale.%/return.% (0072/0091), outside the four financial shipment.* actions (0121), outside the four Rate-Configuration actions (0124), and outside the five financial adjustment.* actions (0143/0156): adjustment.create/update/approve/reverse/cost_set each carry a money payload. adjustment.reject/adjustment.closed_day_override AND adjustment_type.create/update/disable/enable (name/code/status/reason only, never a money figure) remain UNGATED. A row matching any gated action additionally requires sales.view_profit. Enforced in RLS, holds against every access path including a raw PostgREST request.';

-- ============================================================================
-- 0121: Phase 5 — Shipping Core (9/9): close the Shipping profit leak
-- through audit_logs, extending the 0072/0091 pattern
-- ============================================================================
-- Migrations 0001-0120 are unmodified. create_shipment()/record_shipment_
-- actual_cost()/correct_shipment_actual_cost()/correct_shipment_customer_
-- charge() (0117/0118) write audit rows whose old_values/new_values carry
-- customer_shipping_charge/expected_carrier_cost/actual_carrier_cost/
-- net_shipping_expected/net_shipping_actual — the exact same class of
-- profit-sensitive payload 0072 (Sales) and 0091 (Returns) already closed
-- off. Without this migration, a user holding audit_logs.view but NOT
-- sales.view_profit could read a Shipment's full financial payload straight
-- out of audit_logs, bypassing the profit-hiding get_shipment()/list_
-- shipments() (0119) were built to enforce.
--
-- Design decision (documented per this phase's own delivery notes) — UNLIKE
-- 0072/0091's blanket 'sale.%'/'return.%' prefix gating, this migration
-- gates by EXACT action name, action-by-action:
--
--   shipment.create         -> GATED (customer_shipping_charge/expected_
--                               carrier_cost/net_shipping_expected payload)
--   shipment.cost_record     -> GATED (amount/net_shipping_actual payload)
--   shipment.cost_correct    -> GATED (old+new amount/net_shipping_actual)
--   shipment.charge_correct  -> GATED (old+new net_shipping_expected/actual)
--   shipment.status_add      -> UNGATED (status/notes/dates only — zero
--                               financial figures, ever)
--   shipment.closed_day_override -> UNGATED (business_date/action/reason
--                               only — never carries an amount itself, even
--                               though it is always logged alongside one of
--                               the four gated actions above)
--
-- Reasoning for fine-grained over blanket-prefix here: a 'shipment.%' role
-- (Section 25's shipping_employee) is expected to read its OWN operational
-- audit trail (who changed a status and when) without needing sales.
-- view_profit — a blanket prefix would have hidden shipment.status_add from
-- that role too, which 0072/0091's Sales/Returns actions never needed to
-- worry about (every sale.%/return.% action they had at the time carried at
-- least a plausible profit-adjacent payload). Any FUTURE shipment.% action
-- must be reviewed and explicitly added to the gated list below if it ever
-- carries a money figure — this is a deliberate trade-off versus 0072/0091's
-- "automatically covers future actions" property, made explicit here so a
-- future migration doesn't silently reintroduce the leak.
-- ---------------------------------------------------------------------------
drop policy if exists audit_logs_select on public.audit_logs;

create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    public.has_permission('audit_logs.view')
    and (
      (
        action not like 'sale.%'
        and action not like 'return.%'
        and action not in ('shipment.create', 'shipment.cost_record', 'shipment.cost_correct', 'shipment.charge_correct')
      )
      or public.has_permission('sales.view_profit')
    )
  );

comment on policy audit_logs_select on public.audit_logs is
  'audit_logs.view alone grants every action outside the sale.%/return.% prefixes (0072/0091) and outside the four explicitly-listed financial shipment.* actions (0121: shipment.create/cost_record/cost_correct/charge_correct — each carries a money payload). shipment.status_add and shipment.closed_day_override remain UNGATED (audit_logs.view alone is enough) — neither ever carries a financial figure, so a shipping_employee reading their own operational trail does not need sales.view_profit. A row matching any gated action additionally requires sales.view_profit — reused verbatim, no separate shipments.view_profit permission. Enforced in RLS, holds against every access path including a raw PostgREST request.';

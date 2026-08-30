-- ============================================================================
-- 0072: Phase 3 — Sales Integrity Patch 3.1 (final): close the Sales profit
-- leak through audit_logs
-- ============================================================================
-- Migrations 0001-0071 are unmodified. Spec item 4.
--
-- The gap: create_sales_order()/update_sales_order() (0068/0069) write
-- sale.create/sale.update rows to audit_logs whose new_values/old_values
-- contain net_sales_profit/subtotal, and update_sales_order()'s old_values.
-- items is a full to_jsonb() of every sales_order_items row it touched —
-- including gold_component_cost/manufacturing_component_cost/base_cost/
-- vat_cost/total_cost/gross_profit and every snapshot. audit_logs_select
-- (0010) has always gated purely on has_permission('audit_logs.view') — a
-- user holding audit_logs.view but NOT sales.view_profit could read a
-- Sale's full financial payload straight out of audit_logs, completely
-- bypassing the profit-hiding get_sales_order()/list_sales_orders() were
-- built to enforce (0059/0062/0070's whole reason for existing).
--
-- Fix, enforced at the RLS level (so it holds for every access path,
-- including a raw PostgREST request against /audit_logs, not just
-- well-behaved application code): a row whose action starts with 'sale.'
-- (sale.create, sale.update, sale.closed_day_update — every Sales action
-- that ever carries a financial payload) requires audit_logs.view AND
-- sales.view_profit together. daily_closing.create does not match the
-- 'sale.' prefix and is NOT financially sensitive (its payload is only
-- store_id/business_date) — it stays reachable under audit_logs.view alone,
-- exactly as spec item 4 requires. No row is deleted or redacted — the full
-- financial audit trail remains intact and fully readable by anyone holding
-- both permissions; this only narrows WHO may read it.
drop policy if exists audit_logs_select on public.audit_logs;

create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    public.has_permission('audit_logs.view')
    and (
      -- Every OTHER action (including daily_closing.create, and any
      -- non-Sales action from Foundation/Phase 2) is unaffected — gated on
      -- audit_logs.view alone, exactly as before this migration.
      action not like 'sale.%'
      or public.has_permission('sales.view_profit')
    )
  );

comment on policy audit_logs_select on public.audit_logs is
  'Patch 3.1 item 4 — audit_logs.view alone grants every non-Sales audit row (including daily_closing.create, which carries no financial payload) exactly as before. A row whose action starts with ''sale.'' (sale.create/sale.update/sale.closed_day_update — the only actions whose old_values/new_values ever carry cost/profit figures, per create_sales_order()/update_sales_order(), 0068/0069) additionally requires sales.view_profit — closing the profit leak where audit_logs.view alone could otherwise read a Sale''s full financial payload with no sales.view_profit check at all. Enforced in RLS, so it holds against every access path including a raw PostgREST request, not only well-behaved application code. Nothing is deleted or redacted — only who may read it changes.';

-- No INSERT/UPDATE/DELETE policy existed before and none is added now — see
-- 0006/0010's original access-model note (log_audit_event() is, and
-- remains, the sole writer).

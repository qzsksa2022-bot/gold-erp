-- ============================================================================
-- 0091: Phase 4 — Returns Core (10/10): close the Returns profit leak
-- through audit_logs, extending the 0072 pattern
-- ============================================================================
-- Migrations 0001-0090 are unmodified. approve_sales_return()/reverse_
-- sales_return() (0087/0088) write return.approve/return.reverse audit rows
-- whose old_values/new_values carry sales_revenue_reversal_amount/
-- gross_profit_reversal_amount/payment_fee_reversal_amount/net_profit_
-- reversal_amount — the exact same class of profit-sensitive payload 0072
-- already closed off for Sales' sale.% actions. Without this migration, a
-- user holding audit_logs.view but NOT sales.view_profit could read a
-- Return's full financial payload straight out of audit_logs, bypassing the
-- profit-hiding get_sales_return()/list_sales_returns() (0090) were built to
-- enforce — identical gap, identical fix, reusing sales.view_profit (no new
-- returns.view_profit permission is introduced).
--
-- return.create/return.update/return.reject/return.refund_recorded/
-- return.refund_reversed/return.closed_day_override carry no profit
-- payload today, but are included under the same 'return.%' prefix
-- anyway — matching 0072's own reasoning ("every Sales action that ever
-- carries a financial payload") applied conservatively: it costs nothing to
-- gate the whole taxonomy prefix together, and it means a FUTURE action
-- added under 'return.%' is automatically covered without needing another
-- migration to remember this rule.
drop policy if exists audit_logs_select on public.audit_logs;

create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    public.has_permission('audit_logs.view')
    and (
      (action not like 'sale.%' and action not like 'return.%')
      or public.has_permission('sales.view_profit')
    )
  );

comment on policy audit_logs_select on public.audit_logs is
  'audit_logs.view alone grants every action outside the sale.%/return.% prefixes exactly as before. A row whose action starts with ''sale.'' (0072) OR ''return.'' (0091 — return.approve/return.reverse carry the profit-sensitive reversal payload; every other return.% action is included conservatively for the same reasoning) additionally requires sales.view_profit — reused verbatim, no separate returns.view_profit permission. Enforced in RLS, holds against every access path including a raw PostgREST request. Nothing is deleted or redacted — only who may read it changes.';

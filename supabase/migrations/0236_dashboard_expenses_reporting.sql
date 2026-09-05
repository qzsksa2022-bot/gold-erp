-- ============================================================================
-- 0236: Phase 10 — Store Expenses Core (4/4): expense-aware reporting
-- ============================================================================
-- Migrations 0001-0235 are unmodified.
--
-- BACKWARD COMPATIBILITY IS THE WHOLE DESIGN OF THIS MIGRATION.
-- ---------------------------------------------------------------------------
-- get_dashboard_summary() (0200, last replaced 0223) and
-- get_dashboard_summary_with_comparison() (0221) are NOT touched — not one
-- line. `net_operating_return` therefore keeps its exact historical meaning
-- and its exact historical value:
--
--     net_operating_return = effective_net_sales_profit
--                          + net_shipping_result
--                          + net_adjustments_result
--
-- i.e. an operating contribution measured BEFORE operating expenses. Every
-- existing caller, every golden-scenario figure (68.00 / 497.00 / 565.00) and
-- every management report continues to return precisely what it returned
-- before Phase 10 existed.
--
-- The expense-aware view is a NEW, additive wrapper —
-- get_dashboard_summary_with_expenses() — built exactly the way 0221 built
-- get_dashboard_summary_with_comparison(): it CALLS the canonical function
-- and restructures the result, re-deriving no financial figure of its own. It
-- adds three explicitly-named fields whose meaning cannot be confused with
-- the old one:
--
--     operating_contribution_before_expenses  -- verbatim copy of the legacy
--                                                net_operating_return value
--     operating_expenses_total                -- sum(amount) over the ledger
--     net_operating_result_after_expenses     -- contribution - expenses
--
-- and keeps `net_operating_return` alongside them, unchanged, so a reader can
-- see both numbers at once and nothing silently changes meaning.
--
-- §79 true key-absence is preserved in both directions: an actor without
-- expenses.view gets NONE of the three new keys and no `expenses` section at
-- all (not zeros), and an actor without the financial permissions that gate
-- `net_operating_return` never gains them through this wrapper.
-- ---------------------------------------------------------------------------
begin;

-- ---------------------------------------------------------------------------
-- _store_expenses_total_for_scope() — internal. sum(amount) over the
-- append-only ledger for a (period, store scope). Signed by construction, so
-- a reversal automatically nets its original out; no separate subtraction and
-- no second aggregate to keep in step.
-- ---------------------------------------------------------------------------
create or replace function public._store_expenses_total_for_scope(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[]
)
returns numeric
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(sum(se.amount), 0)::numeric(14, 2)
  from public.store_expenses se
  where se.store_id = any (p_store_ids)
    and se.business_date between p_date_from and p_date_to;
$$;

comment on function public._store_expenses_total_for_scope(date, date, uuid[]) is
  'Phase 10 (internal) — sum(amount) over store_expenses for a period and an ALREADY-AUTHORIZED store scope. Performs no permission check of its own: the caller resolves and authorizes the scope first. Not granted to authenticated.';

revoke execute on function public._store_expenses_total_for_scope(date, date, uuid[]) from public;

-- ---------------------------------------------------------------------------
-- get_dashboard_summary_with_expenses() — the expense-aware Dashboard RPC.
-- ---------------------------------------------------------------------------
create or replace function public.get_dashboard_summary_with_expenses(
  p_date_from date,
  p_date_to date,
  p_period_preset text default null,
  p_store_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_result jsonb;
  v_nor jsonb;
  v_scope uuid[];
  v_prev_from date;
  v_prev_to date;
  v_cur_expenses numeric(14, 2);
  v_prev_expenses numeric(14, 2);
  v_contribution numeric(14, 2);
  v_prev_contribution numeric(14, 2);
  v_after numeric(14, 2);
  v_prev_after numeric(14, 2);
  v_entries int;
begin
  -- No permission/date-range check of its own: the canonical wrapper below
  -- already enforces every one of those atomically for this exact actor, and
  -- duplicating them here would be exactly the kind of parallel copy 0221's
  -- header forbids.
  v_result := public.get_dashboard_summary_with_comparison(p_date_from, p_date_to, p_period_preset, p_store_ids);

  -- Expenses are a separately-permissioned domain: without expenses.view the
  -- response is byte-for-byte what get_dashboard_summary_with_comparison()
  -- returned (§79 — the keys are ABSENT, never zero).
  if v_actor is null or not public.has_permission('expenses.view') then
    return v_result;
  end if;

  -- Same store scope the summary itself used. An explicit p_store_ids was
  -- already validated against the actor's scope by the call above, so by the
  -- time we get here it is safe to reuse verbatim.
  if p_store_ids is not null then
    v_scope := p_store_ids;
  else
    select coalesce(array_agg(sid), array[]::uuid[]) into v_scope from public.user_visible_store_ids(v_actor) sid;
  end if;

  v_prev_from := (v_result ->> 'previous_date_from')::date;
  v_prev_to := (v_result ->> 'previous_date_to')::date;

  v_cur_expenses := public._store_expenses_total_for_scope(p_date_from, p_date_to, v_scope);
  v_prev_expenses := coalesce(public._store_expenses_total_for_scope(v_prev_from, v_prev_to, v_scope), 0);

  select count(*) into v_entries
  from public.store_expenses se
  where se.store_id = any (v_scope)
    and se.business_date between p_date_from and p_date_to;

  v_result := v_result || jsonb_build_object('expenses', jsonb_build_object(
    'entries_count', v_entries,
    'operating_expenses_total', v_cur_expenses::text,
    'previous_operating_expenses_total', v_prev_expenses::text,
    'operating_expenses_total_change', (v_cur_expenses - v_prev_expenses)::text,
    'operating_expenses_total_pct_change', public.report_pct_change(v_cur_expenses, v_prev_expenses)
  ));

  -- The three explicit result fields are added ONLY when this actor can
  -- actually see net_operating_return — that section is itself gated inside
  -- get_dashboard_summary(), and an expense-only actor must not gain a
  -- profit figure through this wrapper.
  v_nor := v_result -> 'net_operating_return';
  if v_nor is not null then
    v_contribution := (v_nor ->> 'net_operating_return')::numeric;
    v_prev_contribution := (v_nor ->> 'previous_net_operating_return')::numeric;
    v_after := v_contribution - v_cur_expenses;
    v_prev_after := coalesce(v_prev_contribution, 0) - v_prev_expenses;

    v_result := v_result || jsonb_build_object('net_operating_return', v_nor || jsonb_build_object(
      -- VERBATIM copy of the legacy value under an unambiguous name — the
      -- jsonb value is carried across as-is, never re-cast, so it is
      -- byte-identical to `net_operating_return` (which itself stays exactly
      -- where it was, unchanged). Re-casting through numeric(14, 2) would
      -- silently re-scale "0" into "0.00" and break that identity.
      'operating_contribution_before_expenses', v_nor -> 'net_operating_return',
      'operating_expenses_total', v_cur_expenses::text,
      'net_operating_result_after_expenses', v_after::text,
      'previous_net_operating_result_after_expenses', v_prev_after::text,
      'net_operating_result_after_expenses_change', (v_after - v_prev_after)::text,
      'net_operating_result_after_expenses_pct_change', public.report_pct_change(v_after, v_prev_after),
      'expenses_formula', 'operating_contribution_before_expenses - operating_expenses_total = net_operating_result_after_expenses'
    ));
  end if;

  return v_result;
end;
$$;

comment on function public.get_dashboard_summary_with_expenses(date, date, text, uuid[]) is
  'Phase 10 — expense-aware Dashboard summary. Calls the CANONICAL get_dashboard_summary_with_comparison() (0221) and only ADDS to its result: an `expenses` section and, inside net_operating_return, the explicit operating_contribution_before_expenses / operating_expenses_total / net_operating_result_after_expenses triad. The legacy `net_operating_return` key is left byte-for-byte unchanged, so every pre-Phase-10 caller and every golden-scenario figure is unaffected. Both new groups honour §79 true key-absence (expenses.view for the expense keys; the existing financial gates for the net_operating_return section). SECURITY DEFINER.';

revoke execute on function public.get_dashboard_summary_with_expenses(date, date, text, uuid[]) from public;
grant execute on function public.get_dashboard_summary_with_expenses(date, date, text, uuid[]) to authenticated;

commit;

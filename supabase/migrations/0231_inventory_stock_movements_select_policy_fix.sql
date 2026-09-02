-- ============================================================================
-- 0231: Phase 9 review fix — inventory_stock_movements SELECT policy must use
-- the self-scoped my_visible_store_ids() wrapper
-- ============================================================================
-- Migrations 0001-0230 are unmodified; this is an additive fix on top of the
-- committed Phase 9 migrations (0227-0230), matching 0230's own approach.
--
-- Review finding: 0228's `inventory_stock_movements_select` policy scopes by
--   store_id in (select sid from public.user_visible_store_ids(auth.uid()) sid)
-- but `user_visible_store_ids(uuid)` is deliberately service_role-only —
-- 0017 revokes EXECUTE from PUBLIC and grants it to `service_role` alone,
-- precisely because its uuid parameter would otherwise let any caller probe
-- ANOTHER user's store scope. An RLS policy is evaluated as the querying
-- role, so as `authenticated` this policy does not merely fail to match
-- rows — the query aborts outright with:
--
--   ERROR:  permission denied for function user_visible_store_ids
--
-- i.e. EVERY direct SELECT against public.inventory_stock_movements by a
-- real (authenticated) client session errors, no matter which permissions or
-- store scope that user holds. The Phase 9 RPCs in 0229 are all SECURITY
-- DEFINER and bypass RLS internally, which is why nothing in the application
-- path surfaced this — but 0228 added that SELECT policy specifically so
-- `Can`-gated UI reads, dashboards and reports could select directly, and
-- that is exactly what does not work.
--
-- This is a known, already-documented trap in this codebase: migration 0059
-- (daily_closings_select) carries a verbatim comment warning that the
-- self-scoped, authenticated-callable my_visible_store_ids() wrapper (0017)
-- must be used inside an RLS policy, "NOT user_visible_store_ids(uuid) ...
-- referencing it directly inside an RLS policy evaluated as `authenticated`
-- fails with 'permission denied for function' on every real request". 0228
-- reintroduced the same mistake; this migration brings the Inventory ledger
-- back in line with that established convention (0035/0059 and every other
-- store-scoped RLS policy in the project).
--
-- Semantics are otherwise IDENTICAL: my_visible_store_ids() is defined
-- (0017) as `select * from public.user_visible_store_ids(auth.uid())`, so it
-- resolves the exact same store set for the exact same actor — including
-- disabled stores (historical visibility), and including 0031's fail-closed
-- empty result for a non-active account. Only the callability changes.
-- ---------------------------------------------------------------------------
begin;

drop policy if exists inventory_stock_movements_select on public.inventory_stock_movements;

create policy inventory_stock_movements_select on public.inventory_stock_movements
  for select to authenticated
  using (
    public.has_permission('inventory.view')
    -- my_visible_store_ids() (0017), NOT user_visible_store_ids(uuid) — see
    -- this migration's header and 0059's identical note.
    and store_id in (select public.my_visible_store_ids())
  );

commit;

-- ============================================================================
-- 0230: Phase 9 review fix — inventory lock helper: internal-only EXECUTE
-- ============================================================================
-- Migrations 0001-0229 are unmodified; this is an additive fix on top of the
-- committed Phase 9 migrations (0227-0229), not a rewrite of them.
--
-- Review finding: 0227 granted EXECUTE on
-- public.acquire_inventory_item_store_lock(uuid, uuid) directly to
-- `authenticated`. That advisory lock exists ONLY to be taken from inside
-- record_inventory_stock_movement() (0229), immediately before it sums the
-- stock_movements ledger for a given (item_id, store_id) pair. Granting
-- direct EXECUTE let any authenticated session call
-- acquire_inventory_item_store_lock() itself -- inside its own open
-- transaction, holding the SAME advisory lock key for as long as it liked --
-- purely to create contention against legitimate receive_inventory_stock()/
-- adjust_inventory_stock() calls for that item/store. The helper takes raw
-- item_id/store_id parameters with no permission check of its own, so this
-- was reachable by any authenticated user regardless of whether they hold
-- any inventory.* permission at all.
--
-- Fix: revoke direct EXECUTE from `authenticated` (PUBLIC was already
-- revoked in 0227). record_inventory_stock_movement() (0229) is itself
-- SECURITY DEFINER and, per its own 0229 comment, is deliberately never
-- granted to `authenticated` directly either -- a call made from inside a
-- SECURITY DEFINER function runs under that function's OWNER, and an owner
-- always retains implicit EXECUTE on its own functions regardless of this
-- REVOKE. receive_inventory_stock()/adjust_inventory_stock() (both
-- SECURITY DEFINER, same owner, calling record_inventory_stock_movement()
-- which calls acquire_inventory_item_store_lock()) therefore keep working
-- completely unchanged; only a direct top-level call to
-- acquire_inventory_item_store_lock() by an authenticated client session is
-- now rejected.
-- ---------------------------------------------------------------------------
revoke execute on function public.acquire_inventory_item_store_lock(uuid, uuid) from authenticated;

comment on function public.acquire_inventory_item_store_lock(uuid, uuid) is
  'Phase 9 (fixed 0230) -- INTERNAL ONLY. EXCLUSIVE transaction-scoped advisory lock keyed on (1008, hashtext(item_id || '':'' || store_id)), acquired by record_inventory_stock_movement() (0229) before summing the stock_movements ledger for that (item, store) pair, so two concurrent movements can never both observe a pre-decrement balance and both push it negative. Released automatically at transaction end. EXECUTE is intentionally NOT granted to authenticated/PUBLIC (0230) -- only reachable via the SECURITY DEFINER RPC call path (owner privileges), never directly by a client session.';

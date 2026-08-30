-- ============================================================================
-- 0067: Phase 3 — Sales Integrity Patch 3.1 (3/7): stable sales_order_items
-- identity (status/removed_at/removed_by)
-- ============================================================================
-- Migrations 0001-0066 are unmodified. Spec item 1: sales_order_items rows
-- must never be hard-deleted by an edit — update_sales_order() (0063)
-- currently does `delete from sales_order_items where sales_order_id = ...`
-- then re-inserts the full set, which destroys and reissues every item's id
-- on every single edit (even a pure customer_name change), violating No Hard
-- Delete and making a future Returns feature's permanent FK to
-- sales_order_items.id impossible. Fixed structurally here: an item is
-- never deleted, only ever marked 'removed' in place, keeping its id, every
-- snapshot column, and its full history forever. 0069 (the update_sales_
-- order rewrite) is the migration that actually STOPS issuing the DELETE —
-- this migration only adds the columns that make that possible.
alter table public.sales_order_items
  add column status text not null default 'active' check (status in ('active', 'removed')),
  add column removed_at timestamptz,
  add column removed_by uuid references public.profiles (id) on delete set null,
  add constraint sales_order_items_removed_fields_consistent check (
    (status = 'active' and removed_at is null and removed_by is null)
    or (status = 'removed' and removed_at is not null)
  );

comment on column public.sales_order_items.status is
  'Patch 3.1 item 1 — ''active'' (default; counted in every current Read/Totals) or ''removed'' (soft-removed by an edit that dropped this line from the order — the row is permanently preserved for history/future Returns FKs, but excluded from every active-item Read and from order-level totals). Never hard-deleted, ever. Set exclusively by update_sales_order() (0069).';
comment on column public.sales_order_items.removed_at is
  'Timestamp this item was soft-removed (status set to ''removed''). NULL while status=''active''. Never updated again once set (a removed item cannot be un-removed in Phase 3 — no such workflow exists).';
comment on column public.sales_order_items.removed_by is
  'The actor (profiles.id) whose update_sales_order() call soft-removed this item. NULL while status=''active''.';
comment on constraint sales_order_items_removed_fields_consistent on public.sales_order_items is
  'status and removed_at/removed_by must agree: an ''active'' item has neither removal field set, a ''removed'' item always has removed_at set (removed_by may be null if the actor''s profile was later hard-deleted via ON DELETE SET NULL — the row itself is never removed).';

-- Every existing item (created before this migration, under the old
-- delete+reinsert behavior) is implicitly 'active' by the column default —
-- correct: nothing in Phase 3's existing data was ever soft-removed, since
-- the concept did not exist until now.

create index sales_order_items_sales_order_status_idx
  on public.sales_order_items (sales_order_id, status);

comment on index public.sales_order_items_sales_order_status_idx is
  'Patch 3.1 item 1 — every Read RPC (list_sales_orders/get_sales_order, 0070) and every totals recomputation inside update_sales_order() (0069) filters sales_order_items to status=''active'' for a given sales_order_id; this composite index serves that exact predicate.';

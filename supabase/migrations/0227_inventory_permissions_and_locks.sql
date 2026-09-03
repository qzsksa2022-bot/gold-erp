-- ============================================================================
-- 0227: Phase 9 — Inventory Core (1/3): permissions + advisory lock
-- ============================================================================
-- Migrations 0001-0226 are unmodified — Phase 9 starts at 0227 (approved
-- scope: Inventory Core only). No Salla API / Carrier API / Bank API / GL /
-- COGS / Attachments / Backups / 2FA activation / sync / Forecasting-AI /
-- CRM / Payroll / Purchasing / Store Expenses / external integrations in
-- this or any later Phase 9 migration. Sales/Returns are NOT modified to
-- auto-decrement/restock inventory in this phase — every stock movement is
-- a manual, explicit action (receive or adjust) via the RPCs in 0229.
--
-- Three ordinary permission keys, following the exact shape of every prior
-- phase's first migration (0133 for Adjustments, 0167 for Settlements):
--   inventory.view    — read item catalog, stock balances, movement history.
--   inventory.receive — create a new catalog item (a new SKU is typically
--                        introduced at the moment stock is first received
--                        for it) and record a "receive" stock movement
--                        (quantity_delta must be positive).
--   inventory.adjust  — correct an existing item's catalog fields
--                        (name/category/karat/unit/notes/active) and record
--                        a manual stock correction movement (quantity_delta
--                        may be positive or negative, mandatory reason).
-- Deliberately NOT touching the three sensitive/Super-Admin-guarded
-- permissions (users.manage_permissions/settings.manage/backups.manage,
-- migration 0013 lineage) — these are ordinary, non-sensitive keys.
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('inventory.view', 'inventory', 'عرض كتالوج الأصناف وأرصدة المخزون وسجل الحركات', 'View inventory item catalog, stock balances and movement history'),
  ('inventory.receive', 'inventory', 'إضافة صنف جديد وتسجيل استلام مخزون', 'Create inventory items and record stock receipts'),
  ('inventory.adjust', 'inventory', 'تعديل بيانات صنف وتسجيل تصحيح يدوي للمخزون', 'Edit inventory items and record manual stock corrections')
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin'
  and p.key in ('inventory.view', 'inventory.receive', 'inventory.adjust')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'admin'
  and p.key in ('inventory.view', 'inventory.receive', 'inventory.adjust')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'supervisor'
  and p.key in ('inventory.view', 'inventory.receive', 'inventory.adjust')
on conflict do nothing;

-- Accountant: view-only, mirrors accountant getting shipments.view/
-- adjustments.view without any operational write grant.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'accountant'
  and p.key = 'inventory.view'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Advisory lock namespace registry (grep pg_advisory_xact_lock across the
-- repo): 1001 = financial master (0065), 1002 = daily close (0065), 1003 =
-- unused/reserved, 1004 = returns order lock (0082, parameterized by
-- sales_order_id), 1005 = shipping rates (0113), 1006 = adjustment_types
-- (0133), 1007 = settlement master lock (0167). 1008 is the next free key1.
--
-- Unlike those precedents, Inventory Core has no single row to lock for a
-- stock movement (the "balance" is never a stored column — see 0228/0229 —
-- it is always SUM()'d live from the append-only ledger, exactly mirroring
-- Settlements' bank-movement-ledger pattern, 0174/0180). The race that must
-- be serialized is: two concurrent movements against the SAME (item_id,
-- store_id) pair both reading the same balance and both deciding a
-- negative-stock decrement is safe. record_inventory_stock_movement() (0229)
-- takes this EXCLUSIVE lock, keyed on hashtext(item_id || ':' || store_id),
-- BEFORE summing the ledger, so a second concurrent call for the same pair
-- blocks until the first transaction commits or rolls back — mirroring
-- acquire_returns_order_lock()'s pg_advisory_xact_lock(1004,
-- hashtext(p_sales_order_id::text)) shape exactly (0082).
-- ---------------------------------------------------------------------------
create or replace function public.acquire_inventory_item_store_lock(p_item_id uuid, p_store_id uuid)
returns void
language sql
as $$
  select pg_advisory_xact_lock(1008, hashtext(p_item_id::text || ':' || p_store_id::text));
$$;

comment on function public.acquire_inventory_item_store_lock(uuid, uuid) is
  'Phase 9 — EXCLUSIVE transaction-scoped advisory lock keyed on (1008, hashtext(item_id || '':'' || store_id)), acquired by record_inventory_stock_movement() (0229) before summing the stock_movements ledger for that (item, store) pair, so two concurrent movements can never both observe a pre-decrement balance and both push it negative. Released automatically at transaction end.';

revoke execute on function public.acquire_inventory_item_store_lock(uuid, uuid) from public;
grant execute on function public.acquire_inventory_item_store_lock(uuid, uuid) to authenticated;

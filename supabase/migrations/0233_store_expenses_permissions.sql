-- ============================================================================
-- 0233: Phase 10 — Store Expenses Core (1/4): permissions
-- ============================================================================
-- Migrations 0001-0232 are unmodified — Phase 10 starts at 0233 (approved
-- scope: Store Expenses Core only). No Purchasing / suppliers / Attachments /
-- Payroll / approval workflows / GL / COGS / recoverable input-VAT / Bank /
-- Carrier / Salla integrations, and NO automatic Sales, Returns or Inventory
-- integration, in this or any later Phase 10 migration. Every expense entry is
-- a manual, explicit action via the RPCs in 0235.
--
-- Five ordinary permission keys, following the exact shape of every prior
-- phase's first migration (0133 Adjustments, 0167 Settlements, 0227
-- Inventory):
--   expenses.view              — read the category catalog, the expense
--                                ledger, and the expenses report.
--   expenses.create            — post an expense entry (positive amount) for
--                                an operable store.
--   expenses.reverse           — post a DATED reversal entry against an
--                                existing expense. Posted expenses are never
--                                updated or deleted (0234 enforces this at
--                                table level), so this is the only correction
--                                path.
--   expenses.manage_categories — create/rename/enable/disable expense
--                                categories (global master data).
--   expenses.process_closed_day— post an expense or a reversal whose business
--                                date falls in an already-closed day. Mirrors
--                                shipments./returns./adjustments./settlements.
--                                process_closed_day exactly.
--
-- Deliberately NOT touching the three sensitive/Super-Admin-guarded
-- permissions (users.manage_permissions/settings.manage/backups.manage,
-- migration 0013 lineage) — these are ordinary, non-sensitive keys.
--
-- Seeded HERE, in the migration itself, never in supabase/seed.sql: a real
-- production upgrade never re-runs seed.sql, so a permission that only
-- existed there would simply be missing after an upgrade. 0234's upgrade test
-- asserts exactly this.
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('expenses.view', 'expenses', 'عرض تصنيفات المصروفات ودفتر مصروفات الفروع', 'View expense categories and the store expense ledger'),
  ('expenses.create', 'expenses', 'تسجيل مصروف تشغيلي لفرع', 'Record an operating expense for a store'),
  ('expenses.reverse', 'expenses', 'عكس مصروف مسجَّل بحركة عكس مؤرَّخة', 'Reverse a posted expense with a dated reversal entry'),
  ('expenses.manage_categories', 'expenses', 'إدارة تصنيفات المصروفات', 'Manage expense categories'),
  ('expenses.process_closed_day', 'expenses', 'تسجيل/عكس مصروف في يوم مقفل', 'Record or reverse an expense on a closed business day')
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin'
  and p.key in ('expenses.view', 'expenses.create', 'expenses.reverse', 'expenses.manage_categories', 'expenses.process_closed_day')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'admin'
  and p.key in ('expenses.view', 'expenses.create', 'expenses.reverse', 'expenses.manage_categories', 'expenses.process_closed_day')
on conflict do nothing;

-- Supervisor: full operational power over expense RECORDS (record, reverse,
-- closed-day override) but NOT over the global category catalog — mirrors
-- 0133 giving supervisor adjustments.reverse/process_closed_day while
-- withholding adjustments.manage_types.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'supervisor'
  and p.key in ('expenses.view', 'expenses.create', 'expenses.reverse', 'expenses.process_closed_day')
on conflict do nothing;

-- Accountant: view-only, mirrors accountant getting inventory.view (0227) /
-- adjustments.view without any operational write grant.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'accountant'
  and p.key = 'expenses.view'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- No new advisory lock namespace is registered by Phase 10, deliberately.
-- ---------------------------------------------------------------------------
-- Registry (grep pg_advisory_xact_lock): 1001 financial master (0065), 1002
-- daily close (0065), 1004 returns order (0082), 1005 shipping rates (0113),
-- 1006 adjustment_types (0133), 1007 settlement master (0167), 1008
-- inventory item/store (0227).
--
-- Phase 10 needs none of its own:
--   * There is no derived balance to serialize. Unlike Inventory, an expense
--     entry never has to read-then-decide against an aggregate — it is an
--     unconditional append. Two concurrent expenses for the same store/day
--     are both simply valid.
--   * The daily-close race is already covered by the EXISTING shared/
--     exclusive pair on key 1002 (acquire_daily_close_lock_shared, 0065),
--     which 0235 acquires exactly like every other domain does.
--   * The one genuine mutual-exclusion invariant Phase 10 adds — a posted
--     expense may be reversed AT MOST ONCE — is enforced by a row lock plus a
--     partial UNIQUE index in 0234, which is a stronger DB-level guarantee
--     than an advisory lock (it holds even if a future caller forgets to take
--     the lock), mirroring settlement_bank_movement_reversals (0174).
-- ---------------------------------------------------------------------------

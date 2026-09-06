-- ============================================================================
-- 0237: Phase 11 — Purchases & Suppliers Core (1/4): permissions
-- ============================================================================
-- Migrations 0001-0236 are unmodified — Phase 11 starts at 0237 (approved
-- scope: Purchases & Suppliers Core only). No GL / COGS / recoverable input
-- VAT / VAT returns / Attachments / purchasing approvals / Payroll / Bank /
-- Carrier / Salla integrations, no change to sales profit or the
-- replacement-cost engine, and no automatic sales-to-inventory linkage, in
-- this or any later Phase 11 migration.
--
-- Seven ordinary permission keys, following the shape of every prior phase's
-- first migration (0133 Adjustments, 0167 Settlements, 0227 Inventory, 0233
-- Store Expenses):
--   purchases.view              — read suppliers, purchase invoices, supplier
--                                 payments, statements and reports.
--   purchases.create            — POST a purchase invoice. Posting is the one
--                                 act that also moves stock (0239 routes every
--                                 quantity through Phase 9's own engine), so
--                                 this key alone authorises both.
--   purchases.reverse           — post a DATED reversal document against an
--                                 invoice. Posted invoices are never updated
--                                 or deleted (0238 enforces that at table
--                                 level), so this is the only correction path.
--   purchases.record_payment    — record a (possibly partial) supplier payment
--                                 against an invoice. Separate from `create`
--                                 exactly as settlements.record_bank_movement
--                                 is separate from settlements.create (0167):
--                                 recording a purchase and paying for it are
--                                 different powers.
--   purchases.reverse_payment   — post a dated reversal of a payment.
--   purchases.manage_suppliers  — create/edit/enable/disable suppliers (global
--                                 master data).
--   purchases.process_closed_day— post an invoice, reversal, payment or
--                                 payment reversal whose business date falls
--                                 in an already-closed day. Mirrors
--                                 shipments./returns./adjustments./
--                                 settlements./expenses.process_closed_day.
--
-- Deliberately NOT touching the three sensitive/Super-Admin-guarded
-- permissions (users.manage_permissions/settings.manage/backups.manage,
-- migration 0013 lineage) — these are ordinary, non-sensitive keys.
--
-- Seeded HERE, in the migration itself, never in supabase/seed.sql: a real
-- production upgrade never re-runs seed.sql, so a permission that only existed
-- there would simply be missing after an upgrade. 0240's upgrade test asserts
-- exactly this.
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('purchases.view', 'purchases', 'عرض الموردين وفواتير الشراء والمدفوعات', 'View suppliers, purchase invoices and supplier payments'),
  ('purchases.create', 'purchases', 'ترحيل فاتورة شراء (وإدخال كمياتها للمخزون)', 'Post a purchase invoice (and receive its quantities into inventory)'),
  ('purchases.reverse', 'purchases', 'عكس فاتورة شراء بمستند عكس مؤرَّخ', 'Reverse a purchase invoice with a dated reversal document'),
  ('purchases.record_payment', 'purchases', 'تسجيل دفعة لمورّد', 'Record a supplier payment'),
  ('purchases.reverse_payment', 'purchases', 'عكس دفعة مورّد بحركة عكس مؤرَّخة', 'Reverse a supplier payment with a dated reversal entry'),
  ('purchases.manage_suppliers', 'purchases', 'إدارة بيانات الموردين', 'Manage supplier master data'),
  ('purchases.process_closed_day', 'purchases', 'ترحيل/عكس شراء أو دفعة في يوم مقفل', 'Post or reverse a purchase or payment on a closed business day')
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin' and p.key like 'purchases.%'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'admin' and p.key like 'purchases.%'
on conflict do nothing;

-- Supervisor: full operational power over purchase RECORDS (post, reverse,
-- pay, reverse payment, closed-day override) but NOT over the global supplier
-- catalogue — mirrors 0133 giving supervisor adjustments.reverse/
-- process_closed_day while withholding adjustments.manage_types, and 0233
-- doing the same for expenses.manage_categories.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'supervisor'
  and p.key in ('purchases.view', 'purchases.create', 'purchases.reverse',
                'purchases.record_payment', 'purchases.reverse_payment', 'purchases.process_closed_day')
on conflict do nothing;

-- Accountant: view-only, mirrors accountant getting inventory.view (0227) /
-- expenses.view (0233) / adjustments.view without any operational write grant.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'accountant' and p.key = 'purchases.view'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- No new advisory lock namespace is registered by Phase 11, deliberately.
-- ---------------------------------------------------------------------------
-- Registry (grep pg_advisory_xact_lock): 1001 financial master (0065), 1002
-- daily close (0065), 1004 returns order (0082), 1005 shipping rates (0113),
-- 1006 adjustment_types (0133), 1007 settlement master (0167), 1008 inventory
-- item/store (0227).
--
-- Every mutual-exclusion invariant this phase adds is already covered by a
-- stronger or pre-existing mechanism:
--   * Two payments racing the SAME remaining balance, and payment-vs-invoice-
--     reversal — both serialized by a `select ... for update` ROW LOCK on the
--     parent purchase_invoices row (0239). A row lock is the precise tool
--     here: the contended resource IS a row.
--   * Duplicate supplier invoice number for the same supplier — a partial
--     UNIQUE index (0238), which holds even if a future caller forgets to
--     lock.
--   * At most one reversal per invoice, and per payment — partial UNIQUE
--     indexes (0238).
--   * Duplicate/partial inventory posting — a UNIQUE constraint on the
--     line -> inventory movement link (0238), plus the fact that posting is
--     one atomic RPC.
--   * Inventory quantity races — the EXISTING 1008 lock, taken inside
--     record_inventory_stock_movement() (0229), which 0239 calls rather than
--     reimplementing.
--   * Daily close — the EXISTING shared/exclusive pair on key 1002 (0065).
-- ---------------------------------------------------------------------------

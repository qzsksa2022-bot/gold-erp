-- ============================================================================
-- 0049: Financial Integrity Patch 2.1 (3/4) — production upgrade path
-- ============================================================================
-- Spec item 4. Every Phase 2 permission/grant/initial-master-data row so far
-- has lived ONLY in supabase/seed.sql — fine for a fresh `db reset`, but a
-- REAL production database that was deployed at Foundation (0039) and is
-- now being upgraded by applying 0040 onward does NOT re-run seed.sql (that
-- would be destructive/wrong against live data, and nothing in a normal
-- migration-apply workflow does it automatically). Without this migration,
-- such a database would have the Phase 2 TABLES (from 0040-0048) but none
-- of the karats.view/karats.manage/etc. permission rows, none of the new
-- role_permissions grants, and none of the initial karats/categories/
-- payment methods/collection channels — every Phase 2 page would 403 for
-- everyone (no permission rows exist at all) and every picklist would be
-- empty.
--
-- This migration is the forward, idempotent, ON-CONFLICT-safe data fix:
-- running it (as part of a normal migration apply) makes a database that
-- only ever ran Foundation's seed.sql fully correct for Phase 2, with no
-- manual step and no re-running seed.sql. It is scoped to EXACTLY what
-- Phase 2 added — the 10 new permission keys, the new role_permissions
-- grants for those specific keys, and the initial master data rows — not a
-- re-assertion of Foundation's own permissions/roles/grants (a production
-- database already has those from its original deploy; re-inserting them
-- here would be harmless under ON CONFLICT DO NOTHING but is intentionally
-- left out to keep this migration's blast radius exactly matching what
-- Phase 2 (0040-0046) actually added).
--
-- supabase/seed.sql is UNCHANGED and remains fully valid for a fresh
-- `db reset`/local dev database — every statement below is copied verbatim
-- from its own Phase 2 section, so re-running seed.sql after this migration
-- has already applied is a pure no-op (every INSERT here uses the exact
-- same ON CONFLICT target seed.sql uses, so seed.sql's later run finds
-- nothing left to do).

-- ---------------------------------------------------------------------------
-- New permission keys (must exist BEFORE the grants below, which look them
-- up by key).
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('karats.view', 'financial_master_data', 'عرض العيارات', 'View karats'),
  ('karats.manage', 'financial_master_data', 'إدارة العيارات', 'Manage karats'),
  ('manufacturing_fees.view', 'financial_master_data', 'عرض المصنعية', 'View manufacturing fees'),
  ('manufacturing_fees.manage', 'financial_master_data', 'إدارة المصنعية', 'Manage manufacturing fees'),
  ('categories.view', 'financial_master_data', 'عرض تصنيفات المنتجات', 'View product categories'),
  ('categories.manage', 'financial_master_data', 'إدارة تصنيفات المنتجات', 'Manage product categories'),
  ('payment_methods.view', 'financial_master_data', 'عرض طرق الدفع وعمولاتها', 'View payment methods & fees'),
  ('payment_methods.manage', 'financial_master_data', 'إدارة طرق الدفع وعمولاتها', 'Manage payment methods & fees'),
  ('collection_channels.view', 'financial_master_data', 'عرض قنوات التحصيل', 'View collection channels'),
  ('collection_channels.manage', 'financial_master_data', 'إدارة قنوات التحصيل', 'Manage collection channels')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Role grants — scoped to exactly the 10 new keys, same least-privilege
-- distribution as seed.sql (see that file's own comments for the reasoning
-- behind each role's exact list, e.g. why sales_employee deliberately does
-- NOT get manufacturing_fees.view).
-- ---------------------------------------------------------------------------
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any(array[
  'karats.view', 'karats.manage',
  'manufacturing_fees.view', 'manufacturing_fees.manage',
  'categories.view', 'categories.manage',
  'payment_methods.view', 'payment_methods.manage',
  'collection_channels.view', 'collection_channels.manage'
])
where r.key = 'admin'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any(array[
  'karats.view', 'manufacturing_fees.view', 'categories.view', 'payment_methods.view', 'collection_channels.view'
])
where r.key = 'supervisor'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any(array[
  'karats.view', 'manufacturing_fees.view', 'categories.view', 'payment_methods.view', 'collection_channels.view'
])
where r.key = 'accountant'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any(array[
  'karats.view', 'categories.view', 'payment_methods.view', 'collection_channels.view'
])
where r.key = 'sales_employee'
on conflict do nothing;

-- super_admin: has_permission() already short-circuits to true for super
-- admins regardless of role_permissions rows (Foundation) — these rows are
-- purely for "transparent UI display" (seed.sql's own phrase), never for
-- authorization. seed.sql's super_admin insert is a blanket
-- `cross join public.permissions`, so it picks up EVERY permission that
-- exists at the time it runs — including these 10, once this migration has
-- inserted them. An earlier version of this migration/comment incorrectly
-- assumed super_admin never gets these rows at all; that was wrong (seed.sql
-- does grant them, via the cross join) and meant a production upgrade that
-- later ran seed.sql anyway would not be a true no-op for this one row set.
-- Fixed here to grant explicitly, matching seed.sql's actual behavior
-- exactly, so re-running seed.sql after this migration is a genuine no-op
-- for every table it touches, not just most of them.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any(array[
  'karats.view', 'karats.manage',
  'manufacturing_fees.view', 'manufacturing_fees.manage',
  'categories.view', 'categories.manage',
  'payment_methods.view', 'payment_methods.manage',
  'collection_channels.view', 'collection_channels.manage'
])
where r.key = 'super_admin'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Initial master data (copied verbatim from supabase/seed.sql's own Phase 2
-- section — see that file for per-row rationale, e.g. why COD gets no fee
-- version).
-- ---------------------------------------------------------------------------
insert into public.karats (code, purity_per_mille, name_ar, name_en, sort_order) values
  ('18', 750.000, 'عيار 18', '18K', 1),
  ('21', 875.000, 'عيار 21', '21K', 2),
  ('22', 916.667, 'عيار 22', '22K', 3),
  ('24', 999.900, 'عيار 24', '24K', 4)
on conflict (code) do nothing;

insert into public.product_categories (code, name_ar, name_en, sort_order) values
  ('bullion', 'سبائك', 'Bullion', 1),
  ('sets', 'أطقم', 'Sets', 2),
  ('half_sets', 'أنصاف أطقم', 'Half Sets', 3),
  ('bangles', 'بناجر', 'Bangles', 4),
  ('bracelets', 'أساور', 'Bracelets', 5),
  ('hand_pieces', 'قطع يد', 'Hand Pieces', 6),
  ('rings', 'خواتم', 'Rings', 7),
  ('chains', 'سلاسل / عقود', 'Chains / Necklaces', 8),
  ('earrings', 'أقراط', 'Earrings', 9),
  ('pendants', 'تعليقات', 'Pendants', 10)
on conflict (code) do nothing;

insert into public.payment_methods (key, name_ar, name_en, fee_model, refund_fee_policy, sort_order) values
  ('cash', 'نقد', 'Cash', 'none', 'non_refundable_fee', 1),
  ('bank_transfer', 'تحويل بنكي', 'Bank Transfer', 'none', 'non_refundable_fee', 2),
  ('mada', 'مدى', 'Mada', 'percentage', 'manual', 3),
  ('visa', 'فيزا', 'Visa', 'percentage', 'manual', 4),
  ('tabby', 'تابي (Tabby)', 'Tabby', 'percentage', 'proportional_reversal', 5),
  ('tamara', 'تمارا (Tamara)', 'Tamara', 'percentage', 'proportional_reversal', 6),
  ('cod', 'الدفع عند الاستلام (COD)', 'Cash on Delivery', 'percentage_plus_fixed', 'manual', 7)
on conflict (key) do nothing;

insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, notes)
select id, 0, 0, current_date, 'إعداد أولي — لا توجد عمولة حاليًا'
from public.payment_methods where key = 'cash'
on conflict (payment_method_id) where (effective_to is null and status = 'active') do nothing;

insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, notes)
select id, 0, 0, current_date, 'إعداد أولي — لا توجد عمولة حاليًا إلى أن تُحدَّد أي تكلفة'
from public.payment_methods where key = 'bank_transfer'
on conflict (payment_method_id) where (effective_to is null and status = 'active') do nothing;

insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, notes)
select id, 1, 0, current_date, 'إعداد أولي'
from public.payment_methods where key = 'mada'
on conflict (payment_method_id) where (effective_to is null and status = 'active') do nothing;

insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, notes)
select id, 2.5, 0, current_date, 'إعداد أولي'
from public.payment_methods where key = 'visa'
on conflict (payment_method_id) where (effective_to is null and status = 'active') do nothing;

insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, notes)
select id, 8, 0, current_date, 'إعداد أولي'
from public.payment_methods where key = 'tabby'
on conflict (payment_method_id) where (effective_to is null and status = 'active') do nothing;

insert into public.payment_method_fee_versions (payment_method_id, percentage_fee, fixed_fee, effective_from, notes)
select id, 7, 0, current_date, 'إعداد أولي'
from public.payment_methods where key = 'tamara'
on conflict (payment_method_id) where (effective_to is null and status = 'active') do nothing;

-- COD: deliberately NO fee version, same as seed.sql — until an Admin
-- creates one via the Payment Methods UI, payment_fee_for_method_on_date()
-- (0045) raises a clear error for COD instead of silently charging 0%.

insert into public.collection_channels (key, name_ar, name_en, sort_order) values
  ('direct_store', 'مباشر / المتجر', 'Direct / Store', 1),
  ('salla_wallet', 'محفظة سلة (Salla Wallet)', 'Salla Wallet', 2)
on conflict (key) do nothing;

-- ============================================================================
-- Seed data: permission catalog, default roles + their permission bundles,
-- and default system settings.
--
-- This file is idempotent (safe to re-run) via ON CONFLICT DO NOTHING /
-- DO UPDATE, so it can run on `supabase db reset` as well as against an
-- already-seeded project without duplicating rows.
--
-- Deliberately NOT seeded here: stores, users. See scripts/create-super-
-- admin.ts for bootstrapping the first Super Admin account, and the Stores
-- page for creating real branches once names/codes are known.
--
-- Extended for Phase 2 (Financial Master Data, migrations 0040-0046): seeds
-- karats, product_categories, payment_methods (+ their initial fee
-- versions), and collection_channels. Every value below is ordinary,
-- Admin-editable row data, NOT a constant baked into application code — an
-- Admin can add/rename/reorder/disable any of it afterwards through the UI.
-- COD is deliberately seeded with NO fee version (see that section) rather
-- than a fabricated rate.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Permissions catalog
-- ---------------------------------------------------------------------------
-- Categories "shipments" and "adjustments" extend the list given in the spec
-- (which only enumerated dashboard/stores/users/reports/gold_prices/sales/
-- returns/settlements/audit_logs/system) so the Shipping Employee role and
-- the "الشحنات" / "التعديلات والخدمات" nav sections have something
-- meaningful to gate once those modules are built. No UI/logic for them
-- exists yet in this phase — Coming Soon pages only.
insert into public.permissions (key, category, description_ar, description_en) values
  ('dashboard.view', 'dashboard', 'عرض لوحة التحكم', 'View dashboard'),
  ('dashboard.view_financials', 'dashboard', 'عرض المؤشرات المالية في لوحة التحكم', 'View financial widgets on dashboard'),

  ('stores.view', 'stores', 'عرض المتاجر', 'View stores'),
  ('stores.create', 'stores', 'إضافة متجر', 'Create store'),
  ('stores.edit', 'stores', 'تعديل بيانات متجر', 'Edit store'),
  ('stores.disable', 'stores', 'تعطيل / إعادة تفعيل متجر', 'Disable / re-enable store'),

  ('users.view', 'users', 'عرض المستخدمين', 'View users'),
  ('users.create', 'users', 'إنشاء مستخدم', 'Create user'),
  ('users.edit', 'users', 'تعديل مستخدم', 'Edit user'),
  ('users.disable', 'users', 'تعطيل / إعادة تفعيل مستخدم', 'Disable / re-enable user'),
  ('users.manage_permissions', 'users', 'إدارة الأدوار والصلاحيات', 'Manage roles & permissions'),
  -- Added in migrations/0018 (Foundation Hardening 1.2): store-scope columns
  -- and user_store_access grants are their own security boundary and no
  -- longer piggyback on users.edit. Listed here too (idempotent) so a fresh
  -- `supabase db reset` and an existing project that only applies 0018 both
  -- converge on the same seeded state.
  ('users.manage_store_access', 'users', 'إدارة نطاق وصول المستخدم للمتاجر (Store Scope)', 'Manage a user''s store access scope'),

  ('reports.view', 'reports', 'عرض التقارير', 'View reports'),
  ('reports.export_pdf', 'reports', 'تصدير تقرير PDF', 'Export report as PDF'),
  ('reports.export_excel', 'reports', 'تصدير تقرير Excel', 'Export report as Excel'),

  ('gold_prices.view', 'gold_prices', 'عرض أسعار الذهب', 'View gold prices'),
  ('gold_prices.edit', 'gold_prices', 'تعديل أسعار الذهب', 'Edit gold prices'),

  -- Added in migrations/0040-0046 (Phase 2: Financial Master Data). Kept
  -- granular per module rather than reusing settings.manage (spec §12:
  -- "لا تستخدم settings.manage لكل شيء إذا كان هذا سيجعل الصلاحيات واسعة
  -- أكثر من اللازم") — a role that only needs to see/manage e.g. payment
  -- methods should never implicitly gain system settings access, and vice
  -- versa. Also inserted directly by migration 0049 (idempotent, same ON
  -- CONFLICT target) so a production upgrade gets them without re-running
  -- this file — see 0049's own header comment.
  ('karats.view', 'financial_master_data', 'عرض العيارات', 'View karats'),
  ('karats.manage', 'financial_master_data', 'إدارة العيارات', 'Manage karats'),
  ('manufacturing_fees.view', 'financial_master_data', 'عرض المصنعية', 'View manufacturing fees'),
  ('manufacturing_fees.manage', 'financial_master_data', 'إدارة المصنعية', 'Manage manufacturing fees'),
  ('categories.view', 'financial_master_data', 'عرض تصنيفات المنتجات', 'View product categories'),
  ('categories.manage', 'financial_master_data', 'إدارة تصنيفات المنتجات', 'Manage product categories'),
  ('payment_methods.view', 'financial_master_data', 'عرض طرق الدفع وعمولاتها', 'View payment methods & fees'),
  ('payment_methods.manage', 'financial_master_data', 'إدارة طرق الدفع وعمولاتها', 'Manage payment methods & fees'),
  ('collection_channels.view', 'financial_master_data', 'عرض قنوات التحصيل', 'View collection channels'),
  ('collection_channels.manage', 'financial_master_data', 'إدارة قنوات التحصيل', 'Manage collection channels'),

  ('sales.view', 'sales', 'عرض المبيعات', 'View sales'),
  ('sales.create', 'sales', 'إنشاء عملية بيع', 'Create sale'),
  ('sales.edit', 'sales', 'تعديل عملية بيع', 'Edit sale'),
  ('sales.edit_closed_day', 'sales', 'تعديل مبيعات يوم مقفل', 'Edit sales on a closed day'),
  ('sales.view_profit', 'sales', 'عرض الربحية', 'View profit figures'),
  -- Phase 3 (Sales Core, migration 0060) — Daily Close.
  ('sales.close_day', 'sales', 'إغلاق يوم المبيعات', 'Close a sales day'),

  ('returns.view', 'returns', 'عرض المرتجعات', 'View returns'),
  ('returns.create', 'returns', 'إنشاء مرتجع', 'Create return'),
  ('returns.approve', 'returns', 'اعتماد مرتجع', 'Approve return'),

  ('settlements.view', 'settlements', 'عرض التسويات', 'View settlements'),
  ('settlements.manage', 'settlements', 'إدارة التسويات', 'Manage settlements'),

  ('shipments.view', 'shipments', 'عرض الشحنات', 'View shipments'),
  ('shipments.create', 'shipments', 'إنشاء شحنة', 'Create shipment'),
  ('shipments.update_status', 'shipments', 'تحديث حالة الشحنة', 'Update shipment status'),

  ('adjustments.view', 'adjustments', 'عرض التعديلات والخدمات', 'View adjustments/services'),
  ('adjustments.create', 'adjustments', 'إنشاء تعديل/خدمة', 'Create adjustment/service'),
  ('adjustments.approve', 'adjustments', 'اعتماد تعديل/خدمة', 'Approve adjustment/service'),

  ('audit_logs.view', 'audit_logs', 'عرض سجل الأحداث', 'View audit log'),

  ('settings.manage', 'system', 'إدارة إعدادات النظام', 'Manage system settings'),
  ('backups.manage', 'system', 'إدارة النسخ الاحتياطي', 'Manage backups')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Default roles
-- ---------------------------------------------------------------------------
insert into public.roles (key, name_ar, name_en, description_ar, is_system) values
  ('super_admin', 'مدير عام (Super Admin)', 'Super Admin', 'صلاحية كاملة على النظام، لا يمكن حذفه أو تعطيله بالكامل.', true),
  ('admin', 'مدير', 'Admin', 'صلاحيات إدارية واسعة على المتاجر والمستخدمين والتقارير.', true),
  ('supervisor', 'مشرف', 'Supervisor', 'إشراف تشغيلي على المبيعات والمرتجعات والتقارير.', true),
  ('accountant', 'محاسب', 'Accountant', 'الاطلاع على التقارير المالية والتسويات.', true),
  ('sales_employee', 'موظف مبيعات', 'Sales Employee', 'تنفيذ عمليات البيع والمرتجعات الأساسية.', true),
  ('shipping_employee', 'موظف شحن', 'Shipping Employee', 'إدارة الشحنات وحالتها.', true)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Role → permission bundles
-- ---------------------------------------------------------------------------
-- super_admin gets every permission explicitly (for transparent UI display),
-- even though has_permission() already short-circuits to true for super
-- admins regardless of role_permissions rows.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any(array[
  'dashboard.view', 'dashboard.view_financials',
  'stores.view', 'stores.create', 'stores.edit', 'stores.disable',
  'users.view', 'users.create', 'users.edit', 'users.disable', 'users.manage_permissions', 'users.manage_store_access',
  'reports.view', 'reports.export_pdf', 'reports.export_excel',
  'gold_prices.view', 'gold_prices.edit',
  -- Phase 2 (0040-0046): Admin gets full Master Data management by default,
  -- consistent with already holding gold_prices.edit — spec §12: "Admin
  -- يحصل على Master Data management بشكل افتراضي".
  'karats.view', 'karats.manage',
  'manufacturing_fees.view', 'manufacturing_fees.manage',
  'categories.view', 'categories.manage',
  'payment_methods.view', 'payment_methods.manage',
  'collection_channels.view', 'collection_channels.manage',
  'sales.view', 'sales.create', 'sales.edit', 'sales.edit_closed_day', 'sales.view_profit',
  'returns.view', 'returns.create', 'returns.approve',
  'settlements.view', 'settlements.manage',
  'shipments.view', 'shipments.create', 'shipments.update_status',
  'adjustments.view', 'adjustments.create', 'adjustments.approve',
  'audit_logs.view',
  'settings.manage'
])
where r.key = 'admin'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any(array[
  'dashboard.view', 'dashboard.view_financials',
  'stores.view',
  'users.view',
  'reports.view', 'reports.export_pdf', 'reports.export_excel',
  'gold_prices.view',
  -- Phase 2: view-only oversight of Master Data — supervisors do not
  -- manage rates/catalogs, only need to see current values while
  -- supervising sales/returns.
  'karats.view', 'manufacturing_fees.view', 'categories.view', 'payment_methods.view', 'collection_channels.view',
  'sales.view', 'sales.create', 'sales.edit', 'sales.view_profit',
  'returns.view', 'returns.create', 'returns.approve',
  'settlements.view',
  'shipments.view', 'shipments.update_status',
  'adjustments.view', 'adjustments.create', 'adjustments.approve',
  'audit_logs.view'
])
where r.key = 'supervisor'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any(array[
  'dashboard.view', 'dashboard.view_financials',
  'stores.view',
  'reports.view', 'reports.export_pdf', 'reports.export_excel',
  'gold_prices.view',
  -- Phase 2: accountant is a financial-oversight role — sees the full cost
  -- structure (including manufacturing_fees.view, which sales_employee
  -- deliberately does NOT get below — see that block's comment).
  'karats.view', 'manufacturing_fees.view', 'categories.view', 'payment_methods.view', 'collection_channels.view',
  'sales.view', 'sales.view_profit',
  'returns.view',
  'settlements.view', 'settlements.manage',
  'audit_logs.view'
])
where r.key = 'accountant'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any(array[
  'dashboard.view',
  'stores.view',
  'gold_prices.view',
  -- Phase 2: sales employees need View-only access to the master data a
  -- future sale screen will read from (karats/categories/payment methods/
  -- collection channels) — spec §12: "موظف المبيعات مستقبلًا يحتاج View
  -- فقط للبيانات اللازمة للبيع، وليس Manage". manufacturing_fees.view is
  -- deliberately NOT included here: the manufacturing fee is part of the
  -- internal cost structure (feeds into margin/profit, same sensitivity
  -- class as sales.view_profit, which this role also does not hold) and
  -- has no reason to be visible to someone who cannot see profit figures.
  'karats.view', 'categories.view', 'payment_methods.view', 'collection_channels.view',
  'sales.view', 'sales.create',
  'returns.view', 'returns.create'
])
where r.key = 'sales_employee'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = any(array[
  'dashboard.view',
  'stores.view',
  'shipments.view', 'shipments.create', 'shipments.update_status'
])
where r.key = 'shipping_employee'
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Default system settings
-- ---------------------------------------------------------------------------
insert into public.system_settings (category, key, value) values
  ('general', 'system_name_ar', '"نظام إدارة المبيعات والربحية"'),
  ('general', 'system_name_en', '"Gold Sales & Profitability System"'),
  ('general', 'currency', '"SAR"'),
  ('general', 'timezone', '"Asia/Riyadh"'),
  ('appearance', 'logo_url', 'null'),
  ('appearance', 'accent_color', '"#A9812E"'),
  ('appearance', 'font_family', 'null'),
  ('security', 'two_factor_enabled', 'false'),
  ('security', 'session_timeout_minutes', '480')
on conflict (category, key) do nothing;

-- ---------------------------------------------------------------------------
-- Phase 2 — Financial Master Data (migrations 0040-0046)
--
-- Financial Integrity Patch 2.1 (migration 0049) added a forward, idempotent
-- data migration that inserts these exact same permission keys, role grants,
-- and master-data rows directly as part of applying migrations — so a
-- PRODUCTION upgrade from Foundation (0039) never depends on this file being
-- re-run. Everything below is UNCHANGED and still runs correctly for a
-- fresh/local `db reset`: every statement here targets the same ON CONFLICT
-- key 0049 uses, so if 0049 already ran, re-running this section is a pure
-- no-op (every INSERT finds nothing left to do).
-- ---------------------------------------------------------------------------

-- Karats — the four purities currently traded. Editable rows, not
-- hardcoded constants; an Admin can add more later (spec §2).
insert into public.karats (code, purity_per_mille, name_ar, name_en, sort_order) values
  ('18', 750.000, 'عيار 18', '18K', 1),
  ('21', 875.000, 'عيار 21', '21K', 2),
  ('22', 916.667, 'عيار 22', '22K', 3),
  ('24', 999.900, 'عيار 24', '24K', 4)
on conflict (code) do nothing;

-- Product categories — initial main-level set (spec §5). Not treated as a
-- final/closed list — Admin can add, reorder, or nest subcategories under
-- any of these afterwards. No subcategories are pre-seeded.
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

-- Payment methods (spec §6). fee_model records the SHAPE a fee version is
-- expected to take for this method — actual rates live in
-- payment_method_fee_versions below, never here.
insert into public.payment_methods (key, name_ar, name_en, fee_model, refund_fee_policy, sort_order) values
  ('cash', 'نقد', 'Cash', 'none', 'non_refundable_fee', 1),
  ('bank_transfer', 'تحويل بنكي', 'Bank Transfer', 'none', 'non_refundable_fee', 2),
  ('mada', 'مدى', 'Mada', 'percentage', 'manual', 3),
  ('visa', 'فيزا', 'Visa', 'percentage', 'manual', 4),
  -- Tabby/Tamara: refund_fee_policy = proportional_reversal covers BOTH
  -- spec §8 bullets with a single value — a full refund is simply the
  -- proportional case where the refunded fraction is 100%, so it does not
  -- need its own separate 'full_reversal' row; that literal enum value is
  -- kept available in the schema for a future provider whose policy is
  -- genuinely all-or-nothing rather than proportional.
  ('tabby', 'تابي (Tabby)', 'Tabby', 'percentage', 'proportional_reversal', 5),
  ('tamara', 'تمارا (Tamara)', 'Tamara', 'percentage', 'proportional_reversal', 6),
  -- COD: fee_model already anticipates a future %+fixed shape (spec §7:
  -- "نسبة + رسوم تحويل ثابتة") even though NO fee version is seeded for it
  -- below — see that section.
  ('cod', 'الدفع عند الاستلام (COD)', 'Cash on Delivery', 'percentage_plus_fixed', 'manual', 7)
on conflict (key) do nothing;

-- Initial fee versions ("current configuration", spec §7) — effective from
-- the day this system is deployed/seeded. Percentages stored as plain
-- numbers (e.g. 8 = 8%), matching how payment_method_fee_versions.
-- percentage_fee is documented/consumed everywhere else in this project.
-- The partial unique index on (payment_method_id) WHERE effective_to IS
-- NULL AND status='active' (0045) is the ON CONFLICT target, so re-running
-- this file never touches an already-configured method's current rate.
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

-- COD: deliberately NO fee version seeded — spec §7: "لا تخترع نسبة؛
-- اتركها قابلة للإعداد بدون قيمة وهمية إذا أمكن". Until an Admin creates
-- one via the Payment Methods UI, payment_fee_for_method_on_date() (0045)
-- raises a clear error for COD instead of silently charging 0%.

-- Collection channels (spec §9) — independent from payment_methods.
insert into public.collection_channels (key, name_ar, name_en, sort_order) values
  ('direct_store', 'مباشر / المتجر', 'Direct / Store', 1),
  ('salla_wallet', 'محفظة سلة (Salla Wallet)', 'Salla Wallet', 2)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Phase 3 — Sales Core (migration 0058: VAT rate versioning)
--
-- Same dual-path convention as Phase 2/0049 above: migration 0058 already
-- inserts the vat_rates.view/vat_rates.manage permissions, their role
-- grants, and the 15% baseline vat_rate_versions row directly and
-- idempotently, so a production upgrade from 0057 gets them without this
-- file ever being re-run. The statements below target the exact same ON
-- CONFLICT keys, so re-running this file for a fresh/local `db reset` after
-- 0058 has already run is a pure no-op — they exist here only so a reader
-- of this file sees the full current baseline in one place.
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('vat_rates.view', 'financial_master_data', 'عرض ضريبة القيمة المضافة', 'View VAT rate'),
  ('vat_rates.manage', 'financial_master_data', 'إدارة ضريبة القيمة المضافة', 'Manage VAT rate')
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p on p.key = 'vat_rates.manage'
where r.key = 'admin'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key in ('admin', 'supervisor', 'accountant', 'sales_employee') and p.key = 'vat_rates.view'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin' and p.key in ('vat_rates.view', 'vat_rates.manage')
on conflict do nothing;

insert into public.vat_rate_versions (rate_percent, effective_from, notes)
select 15, public.business_today(), 'الإعداد الأساسي عند إطلاق Phase 3 (Sales Core) — ليس تأريخًا لتاريخ سريان ضريبة القيمة المضافة الفعلي في المملكة، بل نقطة بداية النظام لهذا الإصدار.'
where not exists (select 1 from public.vat_rate_versions where effective_to is null and status = 'active');

-- ---------------------------------------------------------------------------
-- Phase 3 — Sales Core (migration 0060: sales.close_day permission)
-- Same dual-path convention as above — 0060 already grants this
-- idempotently for a production upgrade; mirrored here for a fresh reset.
-- ---------------------------------------------------------------------------
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key in ('admin', 'supervisor') and p.key = 'sales.close_day'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin' and p.key = 'sales.close_day'
on conflict do nothing;

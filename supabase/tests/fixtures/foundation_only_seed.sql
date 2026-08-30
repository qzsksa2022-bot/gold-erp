-- ============================================================================
-- TEST FIXTURE — Foundation-only seed snapshot (simulates seed.sql as it
-- existed at 0039, BEFORE Phase 2 / Financial Integrity Patch 2.1 ever
-- existed).
-- ============================================================================
-- This is NOT part of the application's real seed path — it exists solely
-- so supabase/tests/upgrade_from_0039.test.sql can prove the spec item 4
-- claim: "a production DB that already ran Foundation's seed must get
-- Phase 2's permissions/grants/master-data automatically when migrations
-- 0040-0050 are applied, WITHOUT re-running the (now Phase-2-aware)
-- supabase/seed.sql".
--
-- Content = supabase/seed.sql's permissions/roles/role_permissions/
-- system_settings sections, with every Phase 2 addition surgically removed:
--   - The 10 `financial_master_data` category permission keys (karats.*,
--     manufacturing_fees.*, categories.*, payment_methods.*,
--     collection_channels.*) are NOT inserted here.
--   - Each role's role_permissions grant list has its Phase 2 keys removed
--     (admin/supervisor/accountant/sales_employee each had some; shipping_
--     employee had none to begin with).
--   - The entire trailing "Phase 2 — Financial Master Data" section (karats/
--     product_categories/payment_methods/payment_method_fee_versions/
--     collection_channels rows) is omitted entirely — a real Foundation-only
--     production DB has none of these tables' rows, since those tables
--     (and the tables themselves) did not exist before migration 0040.
--
-- Keep this fixture's non-Phase-2 content byte-for-byte consistent with
-- seed.sql's own non-Phase-2 content whenever seed.sql's Foundation section
-- changes (it should not, Foundation is closed) — this file is a snapshot
-- of a closed, historical state, not a living document.
-- ============================================================================

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
  ('users.manage_store_access', 'users', 'إدارة نطاق وصول المستخدم للمتاجر (Store Scope)', 'Manage a user''s store access scope'),

  ('reports.view', 'reports', 'عرض التقارير', 'View reports'),
  ('reports.export_pdf', 'reports', 'تصدير تقرير PDF', 'Export report as PDF'),
  ('reports.export_excel', 'reports', 'تصدير تقرير Excel', 'Export report as Excel'),

  ('gold_prices.view', 'gold_prices', 'عرض أسعار الذهب', 'View gold prices'),
  ('gold_prices.edit', 'gold_prices', 'تعديل أسعار الذهب', 'Edit gold prices'),

  ('sales.view', 'sales', 'عرض المبيعات', 'View sales'),
  ('sales.create', 'sales', 'إنشاء عملية بيع', 'Create sale'),
  ('sales.edit', 'sales', 'تعديل عملية بيع', 'Edit sale'),
  ('sales.edit_closed_day', 'sales', 'تعديل مبيعات يوم مقفل', 'Edit sales on a closed day'),
  ('sales.view_profit', 'sales', 'عرض الربحية', 'View profit figures'),

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

insert into public.roles (key, name_ar, name_en, description_ar, is_system) values
  ('super_admin', 'مدير عام (Super Admin)', 'Super Admin', 'صلاحية كاملة على النظام، لا يمكن حذفه أو تعطيله بالكامل.', true),
  ('admin', 'مدير', 'Admin', 'صلاحيات إدارية واسعة على المتاجر والمستخدمين والتقارير.', true),
  ('supervisor', 'مشرف', 'Supervisor', 'إشراف تشغيلي على المبيعات والمرتجعات والتقارير.', true),
  ('accountant', 'محاسب', 'Accountant', 'الاطلاع على التقارير المالية والتسويات.', true),
  ('sales_employee', 'موظف مبيعات', 'Sales Employee', 'تنفيذ عمليات البيع والمرتجعات الأساسية.', true),
  ('shipping_employee', 'موظف شحن', 'Shipping Employee', 'إدارة الشحنات وحالتها.', true)
on conflict (key) do nothing;

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

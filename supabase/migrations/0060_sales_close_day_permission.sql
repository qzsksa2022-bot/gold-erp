-- ============================================================================
-- 0060: Phase 3 — Sales Core (3/8): sales.close_day permission
-- ============================================================================
-- Migrations 0001-0059 are unmodified.
--
-- Foundation already seeded five sales.* permission keys ahead of Sales
-- actually being built (sales.view, sales.create, sales.edit,
-- sales.edit_closed_day, sales.view_profit — see supabase/seed.sql and
-- src/lib/permissions/constants.ts, both pre-dating this migration) with
-- role grants already assigned per role (admin/supervisor get create+edit+
-- edit_closed_day+view_profit, accountant gets view+view_profit,
-- sales_employee gets view+create only, matching the Phase 3 spec's own
-- §27 permission-test scenarios exactly as already seeded). The Daily Close
-- feature (§19-20) introduces exactly one NEW permission Foundation did not
-- anticipate: sales.close_day, gating close_sales_day() (0064). This
-- migration adds only that.
insert into public.permissions (key, category, description_ar, description_en) values
  ('sales.close_day', 'sales', 'إغلاق يوم المبيعات', 'Close a sales day')
on conflict (key) do nothing;

-- Admin and Supervisor get it by default — Daily Close is an operational
-- end-of-day control, the same governance tier as sales.edit_closed_day
-- (which both roles already hold). Accountant (financial oversight, not
-- day-to-day store operations), sales_employee (front-line sales entry),
-- and shipping_employee do not.
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

-- ============================================================================
-- 0133: Phase 6 — Services / Adjustments Core (1/11): permissions + advisory
-- locks
-- ============================================================================
-- Migrations 0001-0132 are unmodified — Phase 6 starts at 0133 (user
-- directive). No Settlements / Reports-final-Dashboard / Inventory /
-- PDF-Excel / Attachments-Backups-2FA / External Integration in this or any
-- later Phase 6 migration. Adjustment Gross/Net Profit is fully independent
-- from Sales P/L and Shipping P/L — nothing in this phase writes to
-- sales_orders.net_sales_profit, sales_returns.net_sales_profit_adjustment,
-- or shipments.net_shipping_expected/net_shipping_actual.
--
-- adjustments.view / adjustments.create / adjustments.approve already exist
-- (seeded in supabase/seed.sql, granted to admin/supervisor as Coming-Soon
-- placeholders since Phase 3 — see seed.sql lines ~97-99/153/177). New keys
-- added here, mirroring 0113's shipments.* precedent exactly:
--   adjustments.manage_cost      — required to APPROVE (direct_cost/fee/
--                                   profit are computed and locked in at
--                                   approval — see 0140) and to edit a
--                                   PENDING adjustment's financial fields.
--                                   Kept separate from adjustments.approve
--                                   is NOT split further in this phase —
--                                   approve itself already implies the
--                                   authority to lock in the financial
--                                   snapshot; manage_cost instead gates
--                                   supplying/correcting direct_cost while
--                                   PENDING (see 0139's update RPC) for a
--                                   role that can prepare a record for
--                                   approval without approval power itself.
--   adjustments.reverse          — administrative append-only reversal of
--                                   an approved record (0141). NOT a refund
--                                   engine permission — no Refund Ledger
--                                   exists in this phase.
--   adjustments.process_closed_day — mirrors shipments.process_closed_day
--                                   (0113) / returns.process_closed_day
--                                   (0082) exactly.
--   adjustments.manage_types     — Master Data permission for the
--                                   adjustment_types catalog (0134),
--                                   mirroring shipping_rates.manage's
--                                   shape. Deliberately doubles as both
--                                   "view full catalog including disabled"
--                                   and "manage" — this catalog has no
--                                   separate `.view_types` key (not listed
--                                   in the governing spec's permission
--                                   list) since it is small, low-churn
--                                   Master Data with a single admin-facing
--                                   screen; day-to-day type SELECTION while
--                                   creating an adjustment goes through a
--                                   narrow lookup gated on adjustments.
--                                   create instead (0136), never requiring
--                                   this permission.
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('adjustments.manage_cost', 'adjustments', 'إدارة التكلفة المباشرة لتعديل/خدمة قبل الاعتماد', 'Manage direct cost of a pending adjustment/service before approval'),
  ('adjustments.reverse', 'adjustments', 'عكس تعديل/خدمة معتمدة (تصحيح إداري)', 'Reverse an approved adjustment/service (administrative correction)'),
  ('adjustments.process_closed_day', 'adjustments', 'معالجة تعديل/خدمة في يوم مقفل', 'Process an adjustment/service financial action on a closed business day'),
  ('adjustments.manage_types', 'adjustments', 'إدارة أنواع التعديلات/الخدمات', 'Manage adjustment/service types catalog')
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin'
  and p.key in ('adjustments.manage_cost', 'adjustments.reverse', 'adjustments.process_closed_day', 'adjustments.manage_types')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'admin'
  and p.key in ('adjustments.manage_cost', 'adjustments.reverse', 'adjustments.process_closed_day', 'adjustments.manage_types')
on conflict do nothing;

-- Supervisor: same restricted-financial-power set as shipments.manage_cost/
-- process_closed_day (0113) — full correction/override power on records,
-- but not Master Data catalog management (manage_types stays admin-only,
-- mirrors shipping_rates.manage being admin-only while supervisor gets
-- shipping_rates.view).
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'supervisor'
  and p.key in ('adjustments.manage_cost', 'adjustments.reverse', 'adjustments.process_closed_day')
on conflict do nothing;

-- Accountant: existing financial-oversight pattern — already holds
-- adjustments.view (seed.sql). No new operational/write grant here (mirrors
-- accountant getting shipments.view/shipping_rates.view only, no
-- shipments.manage_cost).

-- sales_employee / shipping_employee: no adjustments.* grants at all in
-- this phase (mirrors sales_employee not getting returns.reverse and
-- shipping_employee not getting shipments.manage_cost) — day-to-day
-- creation of a Service/Adjustment record is a supervisor/admin-level
-- action per this spec's default role shape; a real deployment can grant
-- adjustments.create to any role via the Users/Permissions UI without any
-- code change (permissions are never hardcoded to a role name).

-- ---------------------------------------------------------------------------
-- Advisory lock for adjustment_types CONFIGURATION reads/writes, mirroring
-- acquire_shipping_rates_lock_shared/exclusive (0113) exactly. New
-- namespace key1 = 1006 (1001 = financial master, 1002 = daily close,
-- 1004 = returns order lock, 1005 = shipping rates — 1003 unused/reserved).
-- Writers (create/update/disable/enable_adjustment_type, 0136) take
-- EXCLUSIVE; readers resolving a type at Approval time (0140) take SHARED
-- first, so a type snapshot can never be computed against a torn
-- Master-Data write.
-- ---------------------------------------------------------------------------
create or replace function public.acquire_adjustments_lock_shared()
returns void
language sql
as $$
  select pg_advisory_xact_lock_shared(1006, 0);
$$;

comment on function public.acquire_adjustments_lock_shared() is
  'Phase 6 — SHARED transaction-scoped advisory lock keyed on (1006, 0) for adjustment_types CONFIGURATION. Acquired before resolving/snapshotting a type inside create/update/approve_sales_order_adjustment() (0139/0140), exactly mirroring acquire_shipping_rates_lock_shared() (0113). Released automatically at transaction end.';

create or replace function public.acquire_adjustments_lock_exclusive()
returns void
language sql
as $$
  select pg_advisory_xact_lock(1006, 0);
$$;

comment on function public.acquire_adjustments_lock_exclusive() is
  'Phase 6 — EXCLUSIVE transaction-scoped advisory lock keyed on (1006, 0), acquired by create/update/disable/enable_adjustment_type() (0136) before writing, so a concurrent Approval never resolves a torn/half-written type row.';

revoke execute on function public.acquire_adjustments_lock_shared() from public;
grant execute on function public.acquire_adjustments_lock_shared() to authenticated;
revoke execute on function public.acquire_adjustments_lock_exclusive() from public;
grant execute on function public.acquire_adjustments_lock_exclusive() to authenticated;

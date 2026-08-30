-- ============================================================================
-- 0167: Phase 7 — Settlements Core (1/N): permissions + advisory locks
-- ============================================================================
-- Migrations 0001-0166 are unmodified — Phase 7 starts at 0167 (user
-- directive, stricter freeze than any prior round: NO exception on any
-- migration 0001-0166, not even a single line). No Reports/Dashboard-final /
-- PDF/Excel / Inventory / Salla / Carrier-API / Bank-API / Attachments /
-- Backups / 2FA / any phase after Settlements in this or any later Phase 7
-- migration.
--
-- `settlements.view` and `settlements.manage` already exist (seeded in
-- supabase/seed.sql as Coming-Soon placeholders since Foundation, granted to
-- admin/supervisor/accountant) — exactly the same situation 0133's header
-- documented for `adjustments.view/create/approve` before Phase 6. Per the
-- governing spec item 39 ("أعد استخدام الموجود ... وأضف فقط الناقص"):
--   - `settlements.view` is REUSED as-is (operational-only visibility, see
--     item 40 below).
--   - `settlements.manage` is NOT part of the governing spec's required
--     11-key list and is superseded by the granular keys below (mirrors how
--     coarse Coming-Soon placeholders elsewhere quietly became vestigial
--     once real granular permissions arrived) — left in place, unused, for
--     upgrade-safety (a seeded/already-granted permission row is never
--     retracted), never referenced by any new RLS policy or RPC.
--   - 10 new keys added: `settlements.view_financials`,
--     `settlements.create`, `settlements.finalize`,
--     `settlements.record_bank_movement`, `settlements.reconcile`,
--     `settlements.reconcile_variance`, `settlements.cancel`,
--     `settlements.override_batch_fee`, `settlements.process_closed_day`,
--     `settlements.manage_routes`.
--
-- Role assignment (documented rationale, not a hardcoded role-name business
-- rule anywhere in code — permissions are always resolved via
-- has_permission(), never `role.key = 'admin'` checks):
--   admin            — full 11-key set (mirrors admin's near-full-module
--                       grants across every prior phase).
--   supervisor       — full OPERATIONAL power (view/view_financials/create/
--                       finalize/record_bank_movement/reconcile/cancel/
--                       process_closed_day) EXCEPT the two financial-
--                       EXCEPTION-approval keys (reconcile_variance,
--                       override_batch_fee) and Master Data catalog
--                       management (manage_routes) — mirrors 0133's
--                       supervisor getting manage_cost/reverse/
--                       process_closed_day but NOT manage_types.
--   accountant       — financial-CONTROLLER oversight role: view/
--                       view_financials/reconcile_variance/
--                       override_batch_fee (the two "approve an exception
--                       with mandatory reason" powers) — NOT day-to-day
--                       operational create/finalize/record_bank_movement/
--                       cancel, mirroring accountant never holding
--                       adjustments.manage_cost/reverse either.
--   sales_employee/
--   shipping_employee — no settlements.* grants at all (mirrors
--                       adjustments.* being entirely absent from both).
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('settlements.view_financials', 'settlements', 'عرض التفاصيل المالية للتسويات', 'View settlement financial details'),
  ('settlements.create', 'settlements', 'إنشاء دفعة تسوية', 'Create a settlement batch'),
  ('settlements.finalize', 'settlements', 'اعتماد/إنهاء دفعة التسوية', 'Finalize a settlement batch'),
  ('settlements.record_bank_movement', 'settlements', 'تسجيل حركة بنكية على دفعة التسوية', 'Record a bank movement on a settlement batch'),
  ('settlements.reconcile', 'settlements', 'مطابقة دفعة التسوية', 'Reconcile a settlement batch'),
  ('settlements.reconcile_variance', 'settlements', 'اعتماد فرق المطابقة في التسوية', 'Approve a settlement reconciliation variance'),
  ('settlements.cancel', 'settlements', 'إلغاء دفعة تسوية', 'Cancel a settlement batch'),
  ('settlements.override_batch_fee', 'settlements', 'تجاوز رسوم الدفعة الافتراضية', 'Override the default settlement batch fee'),
  ('settlements.process_closed_day', 'settlements', 'معالجة تسوية في يوم مقفل', 'Process a settlement action on a closed business day'),
  ('settlements.manage_routes', 'settlements', 'إدارة مسارات التسوية وإصدارات رسومها', 'Manage settlement routes and their fee versions')
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin'
  and p.key in (
    'settlements.view_financials', 'settlements.create', 'settlements.finalize',
    'settlements.record_bank_movement', 'settlements.reconcile', 'settlements.reconcile_variance',
    'settlements.cancel', 'settlements.override_batch_fee', 'settlements.process_closed_day',
    'settlements.manage_routes'
  )
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'admin'
  and p.key in (
    'settlements.view_financials', 'settlements.create', 'settlements.finalize',
    'settlements.record_bank_movement', 'settlements.reconcile', 'settlements.reconcile_variance',
    'settlements.cancel', 'settlements.override_batch_fee', 'settlements.process_closed_day',
    'settlements.manage_routes'
  )
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'supervisor'
  and p.key in (
    'settlements.view_financials', 'settlements.create', 'settlements.finalize',
    'settlements.record_bank_movement', 'settlements.reconcile', 'settlements.cancel',
    'settlements.process_closed_day'
  )
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'accountant'
  and p.key in ('settlements.view_financials', 'settlements.reconcile_variance', 'settlements.override_batch_fee')
on conflict do nothing;

-- sales_employee / shipping_employee: no new settlements.* grants (mirrors
-- adjustments.* being entirely absent from both role blocks in 0133).

-- ---------------------------------------------------------------------------
-- Settlement Master Lock — new advisory-lock namespace, key1 = 1007. Every
-- distinct key1 currently in use: 1001 (financial master), 1002 (daily
-- close, parameterized), 1003 (unused/reserved, never reclaimed), 1004
-- (returns order lock, parameterized), 1005 (shipping rates), 1006
-- (adjustment_types). 1007 is the next free, non-colliding key.
--
-- Writers of settlement_routes/settlement_route_fee_versions take EXCLUSIVE;
-- Settlement Finalization takes SHARED before resolving route/fee-version
-- and holds it until every line is snapshotted, so a concurrent Master Data
-- write can never race a torn read (exactly the same pattern as
-- acquire_adjustments_lock_shared/exclusive, 0133, and
-- acquire_financial_master_lock_shared/exclusive, 0065/0066).
-- ---------------------------------------------------------------------------
create or replace function public.acquire_settlement_master_lock_shared()
returns void
language sql
as $$
  select pg_advisory_xact_lock_shared(1007, 0);
$$;

comment on function public.acquire_settlement_master_lock_shared() is
  'Phase 7 — SHARED transaction-scoped advisory lock keyed on (1007, 0) for Settlement Master Data (settlement_routes/settlement_route_fee_versions) CONFIGURATION. Acquired by finalize_settlement_batch() before resolving/snapshotting a route+fee-version, so it can never observe a torn concurrent write. Released automatically at transaction end.';

create or replace function public.acquire_settlement_master_lock_exclusive()
returns void
language sql
as $$
  select pg_advisory_xact_lock(1007, 0);
$$;

comment on function public.acquire_settlement_master_lock_exclusive() is
  'Phase 7 — EXCLUSIVE transaction-scoped advisory lock keyed on (1007, 0), acquired by every writer of settlement_routes/settlement_route_fee_versions before writing, so a concurrent Finalization never resolves a torn/half-written route or fee-version row. Also acquired by a table-level BEFORE STATEMENT trigger on both tables (0168/0170) so even a trusted/service_role direct write cannot bypass the lock.';

revoke execute on function public.acquire_settlement_master_lock_shared() from public;
grant execute on function public.acquire_settlement_master_lock_shared() to authenticated;
revoke execute on function public.acquire_settlement_master_lock_exclusive() from public;
grant execute on function public.acquire_settlement_master_lock_exclusive() to authenticated;

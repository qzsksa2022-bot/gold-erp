-- ============================================================================
-- 0113: Phase 5 — Shipping Core (1/9): permissions, advisory locks,
-- carriers/zones master data
-- ============================================================================
-- Migrations 0001-0112 are unmodified — Phase 5 starts at 0113 (user
-- directive). No Settlements / Services-Adjustments / Inventory /
-- Reports-PDF-Excel / Carrier API integration / Salla work in this or any
-- later Phase 5 migration. Shipping P/L is fully independent from Sales
-- P/L — nothing in this migration or any later one in this phase writes to
-- sales_orders.net_sales_profit or sales_returns.net_sales_profit_
-- adjustment.
--
-- ---------------------------------------------------------------------------
-- Part A — new permissions. shipments.view/create/update_status already
-- exist (seeded before Phase 5, granted to admin/supervisor(partial)/
-- shipping_employee). New keys added here:
--   shipments.manage_cost      — record/correct actual carrier cost AND
--                                 correct customer shipping charge (both are
--                                 "the financial side of a shipment").
--   shipments.correct_status   — out-of-normal-flow status corrections
--                                 (state-machine "correction" transitions,
--                                 see 0116's validate_shipment_status_
--                                 transition()), distinct from the everyday
--                                 forward transitions shipments.update_status
--                                 already covers.
--   shipments.process_closed_day — mirrors returns.process_closed_day
--                                 (0082) exactly, for shipment financial
--                                 actions on an already-closed business day.
--   shipping_rates.view/manage — Master Data permissions for carriers/
--                                 zones/rate configuration, mirroring
--                                 karats.view/manage's shape exactly. Kept
--                                 SEPARATE from shipments.* so a shipping-
--                                 floor operator (shipping_employee) can
--                                 create/update shipments without also being
--                                 able to reconfigure carrier rates, and an
--                                 admin configuring rates does not need any
--                                 shipments.* grant to do so.
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('shipments.manage_cost', 'shipments', 'إدارة تكلفة ورسوم الشحنة الفعلية', 'Manage actual shipment cost/charge'),
  ('shipments.correct_status', 'shipments', 'تصحيح حالة شحنة بشكل استثنائي', 'Correct a shipment status out of normal flow'),
  ('shipments.process_closed_day', 'shipments', 'معالجة شحنة في يوم مقفل', 'Process a shipment financial action on a closed business day'),
  ('shipping_rates.view', 'shipping_rates', 'عرض شركات الشحن والمناطق والتسعير', 'View carriers/zones/shipping rates'),
  ('shipping_rates.manage', 'shipping_rates', 'إدارة شركات الشحن والمناطق والتسعير', 'Manage carriers/zones/shipping rates')
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin'
  and p.key in ('shipments.manage_cost', 'shipments.correct_status', 'shipments.process_closed_day', 'shipping_rates.view', 'shipping_rates.manage')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'admin'
  and p.key in ('shipments.manage_cost', 'shipments.correct_status', 'shipments.process_closed_day', 'shipping_rates.view', 'shipping_rates.manage')
on conflict do nothing;

-- Supervisor: same restricted-financial-power set as returns.reverse/
-- returns.record_refund/returns.process_closed_day (0082) — full
-- correction/override power, but read-only on rate CONFIGURATION (only
-- admin reconfigures carrier rates, mirrors payment_methods.manage/
-- karats.manage being admin-only while supervisor gets *.view).
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'supervisor'
  and p.key in ('shipments.manage_cost', 'shipments.correct_status', 'shipments.process_closed_day', 'shipping_rates.view')
on conflict do nothing;

-- Accountant: previously had ZERO shipments.* grants (Shipping did not
-- exist yet). Mirrors this role's existing "financial-oversight, view-only"
-- pattern across every other module (sales.view_profit but not sales.edit,
-- returns.view but not returns.create, karats.view but not karats.manage)
-- — gets shipments.view (to review shipment records) + shipping_rates.view
-- (to review rate configuration), nothing operational or write-capable.
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'accountant'
  and p.key in ('shipments.view', 'shipping_rates.view')
on conflict do nothing;

-- shipping_employee keeps exactly its existing grant (shipments.view/
-- create/update_status). Deliberately NOT given manage_cost/correct_status/
-- process_closed_day — same reasoning as sales_employee not getting
-- returns.reverse/returns.record_refund/returns.process_closed_day (0082):
-- day-to-day operational actions only, financial correction/override power
-- stays with admin/supervisor.

-- ---------------------------------------------------------------------------
-- Part B — advisory lock for shipping rate CONFIGURATION reads/writes,
-- mirroring acquire_financial_master_lock_shared/exclusive (0065) exactly.
-- New namespace key1 = 1005 (1001 = financial master, 1002 = daily close,
-- 1004 = returns order lock — 1003 unused/reserved, 1005 never collides
-- with any of these since advisory locks compare (key1, key2) as a pair).
-- Writers (create/cancel *_rate_version, 0114/0115) take EXCLUSIVE;
-- readers resolving a rate mid-transaction (create_shipment, 0117) take
-- SHARED first, so a shipment snapshot can never be computed against a
-- torn rate-versioning write.
-- ---------------------------------------------------------------------------
create or replace function public.acquire_shipping_rates_lock_shared()
returns void
language sql
as $$
  select pg_advisory_xact_lock_shared(1005, 0);
$$;

comment on function public.acquire_shipping_rates_lock_shared() is
  'Phase 5 — SHARED transaction-scoped advisory lock keyed on (1005, 0) for shipping rate CONFIGURATION (shipping_carrier_rate_versions/customer_return_shipping_fee_versions). Acquired by create_shipment()/preview_shipment_expected_cost() (0117) before resolving any rate, exactly mirroring acquire_financial_master_lock_shared() (0065). Released automatically at transaction end.';

create or replace function public.acquire_shipping_rates_lock_exclusive()
returns void
language sql
as $$
  select pg_advisory_xact_lock(1005, 0);
$$;

comment on function public.acquire_shipping_rates_lock_exclusive() is
  'Phase 5 — EXCLUSIVE transaction-scoped advisory lock keyed on (1005, 0). Acquired by create/cancel_shipping_carrier_rate_version() and create/cancel_customer_return_shipping_fee_version() (0114/0115) immediately after the permission check, so a rate CONFIGURATION write can never commit in the middle of a concurrent shipment''s rate snapshot resolution. Released automatically at transaction end.';

revoke execute on function public.acquire_shipping_rates_lock_shared() from public;
grant execute on function public.acquire_shipping_rates_lock_shared() to authenticated;
revoke execute on function public.acquire_shipping_rates_lock_exclusive() from public;
grant execute on function public.acquire_shipping_rates_lock_exclusive() to authenticated;

-- ---------------------------------------------------------------------------
-- Part C — shipping_carriers (Section 4). Direct RLS SELECT/INSERT/UPDATE
-- gated on shipping_rates.view/manage, exactly like karats (0040) — this is
-- reference Master Data, not a computed profit figure, so it does not need
-- the "zero direct policies, RPC-only" treatment Sales/Returns/Shipments
-- use. No dedicated create/disable RPC: a plain INSERT/UPDATE under RLS
-- (or the Roles & Permissions-style admin screen) is exactly how karats/
-- categories/payment_methods/collection_channels already work.
-- ---------------------------------------------------------------------------
create table public.shipping_carriers (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_ar text not null,
  name_en text,
  -- Section 3 — never branch calculation logic on this or on `code`; it
  -- exists purely for UI grouping (e.g. hide the tracking-number field for
  -- 'store_courier'). Every actual cost/rate lookup keys on carrier_id.
  carrier_type text not null check (carrier_type in ('external', 'store_courier', 'other')),
  status text not null default 'active' check (status in ('active', 'disabled')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.shipping_carriers is
  'Phase 5 (Section 4) — carrier master data (external carriers + the store''s own courier). Never hard-deleted — disable (status=disabled) instead; a disabled carrier is rejected for NEW shipments (create_shipment, 0117) but every historical shipment referencing it is untouched and still fully readable. code is the stable machine key referenced by shipping_carrier_rate_versions and shipments.carrier_id — calculation logic must never branch on it (Section 3).';

create index shipping_carriers_status_idx on public.shipping_carriers (status);

alter table public.shipping_carriers enable row level security;

create policy shipping_carriers_select on public.shipping_carriers
  for select to authenticated
  using (public.has_permission('shipping_rates.view'));

create policy shipping_carriers_insert on public.shipping_carriers
  for insert to authenticated
  with check (public.has_permission('shipping_rates.manage'));

create policy shipping_carriers_update on public.shipping_carriers
  for update to authenticated
  using (public.has_permission('shipping_rates.manage'))
  with check (public.has_permission('shipping_rates.manage'));

-- No DELETE policy: shipments/rate versions may already reference a
-- carrier; disable instead of removing.

create trigger shipping_carriers_set_updated_at
  before update on public.shipping_carriers
  for each row
  execute function public.set_updated_at();

-- Seed (Section 4/7/52 — deterministic, idempotent via unique `code`, safe
-- to re-run on every upgrade). Names/types only — NO rate/cost values are
-- seeded here (that belongs to shipping_carrier_rate_versions, 0114, where
-- the "do not invent a number we don't have" rule from Section 7 actually
-- applies).
insert into public.shipping_carriers (code, name_ar, name_en, carrier_type) values
  ('SMSA', 'SMSA', 'SMSA', 'external'),
  ('ARAMEX', 'أرامكس', 'Aramex', 'external'),
  ('BARQ', 'برق', 'Barq', 'external'),
  ('REDBOX', 'ريدبوكس', 'RedBox', 'external'),
  ('STORE_COURIER', 'مندوب المتجر', 'Store Courier', 'store_courier')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- Part D — shipping_zones (Section 5). Same access model as carriers.
-- Deliberately just two labeled rules for now (Riyadh / Outside Riyadh),
-- no geocoding/city detection — the user picks a zone explicitly at
-- shipment-creation time (Section 5: "المستخدم يحدد Zone عند إنشاء
-- الشحنة").
-- ---------------------------------------------------------------------------
create table public.shipping_zones (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_ar text not null,
  name_en text,
  status text not null default 'active' check (status in ('active', 'disabled')),
  sort_order integer not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.shipping_zones is
  'Phase 5 (Section 5) — configurable shipping-rate zone labels (e.g. Riyadh / Outside Riyadh), NOT a geocoding/city-detection system. Never hard-deleted — disable (status=disabled) instead. code is the stable machine key referenced by shipping_carrier_rate_versions/customer_return_shipping_fee_versions/shipments.shipping_zone_id.';

create index shipping_zones_status_idx on public.shipping_zones (status);

alter table public.shipping_zones enable row level security;

create policy shipping_zones_select on public.shipping_zones
  for select to authenticated
  using (public.has_permission('shipping_rates.view'));

create policy shipping_zones_insert on public.shipping_zones
  for insert to authenticated
  with check (public.has_permission('shipping_rates.manage'));

create policy shipping_zones_update on public.shipping_zones
  for update to authenticated
  using (public.has_permission('shipping_rates.manage'))
  with check (public.has_permission('shipping_rates.manage'));

create trigger shipping_zones_set_updated_at
  before update on public.shipping_zones
  for each row
  execute function public.set_updated_at();

insert into public.shipping_zones (code, name_ar, name_en, sort_order) values
  ('RIYADH', 'الرياض', 'Riyadh', 10),
  ('OUTSIDE_RIYADH', 'خارج الرياض', 'Outside Riyadh', 20)
on conflict (code) do nothing;

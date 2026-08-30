-- ============================================================================
-- 0134: Phase 6 — Services / Adjustments Core (2/11): adjustment_types
-- (configurable Service/Adjustment Types master data)
-- ============================================================================
-- Migrations 0001-0133 are unmodified.
--
-- No hardcoded service types anywhere in this phase (spec §1) — this table
-- is the single source of what a "type" is. `code` is immutable once
-- created (no update RPC ever changes it, 0136) so historical snapshots
-- (sales_order_adjustments.adjustment_type_code_snapshot, 0135) remain a
-- stable join key even if name_ar/name_en is later edited. No hard delete —
-- a type that is no longer offered is disabled (status='disabled'), which
-- blocks it from NEW selection (0138's lookup, 0140's approval validation)
-- while remaining fully visible on every historical record that already
-- references it (id FK is never removed; the name/code SNAPSHOT on an
-- approved adjustment is additionally immune to a later rename).
-- ---------------------------------------------------------------------------
create table public.adjustment_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_ar text not null,
  name_en text,
  description text,
  status text not null default 'active' check (status in ('active', 'disabled')),
  sort_order integer not null default 0,
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint adjustment_types_code_not_blank check (btrim(code) <> ''),
  constraint adjustment_types_name_ar_not_blank check (btrim(name_ar) <> '')
);

comment on table public.adjustment_types is
  'Phase 6 (§5) — configurable catalog of Post-Sale Service/Adjustment types (e.g. تركيب/تصليح/فحص إضافي — none of these are hardcoded, an Admin defines them here). `code` is immutable once set. No hard delete — disable/enable only (0136). No direct authenticated INSERT/UPDATE/DELETE — every write goes through create_adjustment_type()/update_adjustment_type()/disable_adjustment_type()/enable_adjustment_type() (0136), all SECURITY DEFINER.';

create index adjustment_types_status_idx on public.adjustment_types (status);

alter table public.adjustment_types enable row level security;

-- SELECT only — gated on any of the three permissions that legitimately
-- need to read this catalog (view records that reference a type, create a
-- new adjustment and pick a type, or manage the catalog itself). No
-- INSERT/UPDATE/DELETE policy for `authenticated` — all writes are RPC-only
-- (mirrors the Patch 5.1 shipping_carrier_rate_versions lockdown, 0122).
create policy adjustment_types_select on public.adjustment_types
  for select to authenticated
  using (
    public.has_permission('adjustments.view')
    or public.has_permission('adjustments.create')
    or public.has_permission('adjustments.manage_types')
  );

create trigger adjustment_types_set_updated_at
  before update on public.adjustment_types
  for each row
  execute function public.set_updated_at();

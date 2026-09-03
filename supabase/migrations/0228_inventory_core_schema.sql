-- ============================================================================
-- 0228: Phase 9 — Inventory Core (2/3): item master + append-only stock
-- movement ledger
-- ============================================================================
-- Migrations 0001-0227 are unmodified.
--
-- Two tables:
--   inventory_items            — a global SKU/item master (NOT store-scoped
--                                 — the same catalog item can exist/move
--                                 across every store). Mirrors the shape of
--                                 sales_order_items' category_id/karat_id/
--                                 sku snapshot fields (0059) but as a real,
--                                 first-class, FK-backed row instead of a
--                                 free-text per-sale snapshot.
--   inventory_stock_movements  — an append-only, STORE-scoped ledger. There
--                                 is deliberately no stored "stock_on_hand"/
--                                 "quantity" balance column anywhere — the
--                                 balance for a given (item, store) pair is
--                                 always SUM(quantity_delta) computed live,
--                                 exactly mirroring settlement_bank_
--                                 movement_events' balance-derived-from-
--                                 ledger pattern (0174/0180). This sidesteps
--                                 the classic negative-balance race entirely
--                                 by never storing the aggregate that a race
--                                 could corrupt (the actual race guard is
--                                 the advisory lock from 0227, taken by the
--                                 RPC in 0229 before it sums the ledger).
-- ---------------------------------------------------------------------------

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  sku text not null,
  name_ar text not null,
  category_id uuid not null references public.product_categories (id) on delete restrict,
  -- Nullable: not every inventory item is necessarily a karat-graded gold
  -- item (e.g. packaging/supplies could be tracked here too) — unlike
  -- sales_order_items.karat_id (required, every SOLD line is a graded gold
  -- item), the item MASTER stays flexible.
  karat_id uuid references public.karats (id) on delete restrict,
  unit text not null default 'gram' check (unit in ('gram', 'piece')),
  active boolean not null default true,
  notes text,
  row_version bigint not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  constraint inventory_items_sku_not_blank check (btrim(sku) <> ''),
  constraint inventory_items_name_ar_not_blank check (btrim(name_ar) <> '')
);

-- Case-insensitive uniqueness (mirrors product_categories.code precedent,
-- 0043) — 'ABC-1' and 'abc-1' are the same SKU.
create unique index inventory_items_sku_unique_idx on public.inventory_items (lower(sku));

create index inventory_items_category_id_idx on public.inventory_items (category_id);
create index inventory_items_karat_id_idx on public.inventory_items (karat_id);
create index inventory_items_active_idx on public.inventory_items (active);

comment on table public.inventory_items is
  'Phase 9 — global inventory item/SKU master. NOT store-scoped (the catalog is shared across stores); per-store stock is entirely derived from inventory_stock_movements. Never hard-deleted (active=false instead) once a movement may reference it.';

create trigger inventory_items_set_updated_at
  before update on public.inventory_items
  for each row execute function public.set_updated_at();

-- Enable RLS with ZERO direct-write policies (Layer-A lockdown, mirrors
-- sales_order_adjustments/settlement_batches exactly) — every mutation goes
-- through a SECURITY DEFINER RPC (0229), the base table is unreachable via
-- a raw .insert()/.update()/.delete() regardless of permission. A narrow
-- SELECT policy exists so `Can`-gated UI reads and dashboards/reports may
-- eventually select directly (never required for the RPCs themselves,
-- which are all security definer and bypass RLS internally).
alter table public.inventory_items enable row level security;

create policy inventory_items_select on public.inventory_items
  for select to authenticated
  using (public.has_permission('inventory.view'));

-- ---------------------------------------------------------------------------
-- inventory_stock_movements — append-only, store-scoped ledger.
-- movement_kind='receive' rows must carry a strictly positive quantity_delta
-- (mirrors sales_order_items.weight_grams > 0 style CHECK, 0059);
-- movement_kind='adjust' rows may be positive (found extra stock) or
-- negative (found missing stock) but never zero, and always carry a
-- mandatory reason — mirrors settlement_bank_movement_events.amount <> 0
-- (0174) and every reversal/correction table in this repo requiring a
-- non-blank reason.
-- ---------------------------------------------------------------------------
create table public.inventory_stock_movements (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.inventory_items (id) on delete restrict,
  store_id uuid not null references public.stores (id) on delete restrict,
  movement_kind text not null check (movement_kind in ('receive', 'adjust')),
  quantity_delta numeric(12, 3) not null check (quantity_delta <> 0),
  business_date date not null default current_date,
  reason text,
  reference text,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  constraint inventory_stock_movements_receive_positive check (
    (movement_kind = 'receive' and quantity_delta > 0)
    or (movement_kind = 'adjust')
  ),
  constraint inventory_stock_movements_adjust_reason_required check (
    (movement_kind = 'adjust' and reason is not null and btrim(reason) <> '')
    or (movement_kind = 'receive')
  )
);

create index inventory_stock_movements_item_store_idx on public.inventory_stock_movements (item_id, store_id);
create index inventory_stock_movements_store_id_idx on public.inventory_stock_movements (store_id);
create index inventory_stock_movements_business_date_idx on public.inventory_stock_movements (business_date);

comment on table public.inventory_stock_movements is
  'Phase 9 — append-only, store-scoped stock ledger. There is no stored balance column anywhere: stock on hand for an (item_id, store_id) pair is always sum(quantity_delta), computed live by the RPCs in 0229 (mirrors settlement_bank_movement_events, 0174). INSERT-only forever — the two reject-mutation triggers below make this a DB-level guarantee, not just a convention.';

create or replace function public.reject_inventory_stock_movement_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'حركات المخزون سجل للقراءة فقط بعد إنشائها — أي تصحيح يتم عبر حركة تصحيح جديدة (adjust)' using errcode = 'P0001';
end;
$$;

create trigger inventory_stock_movements_reject_update
  before update on public.inventory_stock_movements
  for each row execute function public.reject_inventory_stock_movement_mutation();

create trigger inventory_stock_movements_reject_delete
  before delete on public.inventory_stock_movements
  for each row execute function public.reject_inventory_stock_movement_mutation();

-- Zero direct-write RLS policies (RPC-only, mirrors sales_order_adjustments/
-- settlement_bank_movement_events exactly); a narrow SELECT policy gated on
-- inventory.view AND store visibility, mirroring how Sales/Settlements
-- scope historical reads to user_visible_store_ids().
alter table public.inventory_stock_movements enable row level security;

create policy inventory_stock_movements_select on public.inventory_stock_movements
  for select to authenticated
  using (
    public.has_permission('inventory.view')
    and store_id in (select sid from public.user_visible_store_ids(auth.uid()) sid)
  );

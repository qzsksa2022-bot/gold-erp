-- ============================================================================
-- 0082: Phase 4 — Returns Core (1/10): schema, permissions, advisory lock
-- ============================================================================
-- Migrations 0001-0081 are unmodified — Phase 4 starts at 0082 (user
-- directive). No Shipping / Settlements / Services / Adjustments / Inventory
-- / Reports-PDF-Excel work in this or any later Phase 4 migration. See
-- PHASE_4_DESIGN_NOTES.md for the full rationale behind every decision
-- below (folded into DELIVERY_REPORT.md's Phase 4 appendix at delivery).
--
-- ---------------------------------------------------------------------------
-- Access model — identical reasoning to sales_orders/sales_order_items
-- (0059): a user holding returns.view but NOT sales.view_profit must never
-- obtain gross_profit_reversal_amount/net_profit_reversal_amount/cost
-- snapshots via ANY direct API. RLS is row-level, not column-level, so (as
-- with Sales) the only design that satisfies this unconditionally is: zero
-- direct authenticated SELECT/INSERT/UPDATE/DELETE policies on any of the
-- three tables below — every read goes through a trusted SECURITY DEFINER
-- Read RPC (0090) that decides in application logic whether to include
-- profit-sensitive columns for THIS caller; every write goes through a
-- trusted SECURITY DEFINER RPC (0085-0089). Audit trail is written
-- explicitly inside each RPC via log_audit_event(), same as Sales — the
-- generic audit_table_changes() trigger (0016/0024) is deliberately NOT
-- attached to these tables, for the identical reason 0059 documents.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Part A — new permissions (returns.view/create/approve already exist,
-- seeded before Phase 4). Default grants mirror the EXISTING returns.approve
-- grant exactly — same roles that can approve a return can also reverse it,
-- record a refund against it, or override a closed processing day.
-- ---------------------------------------------------------------------------
insert into public.permissions (key, category, description_ar, description_en) values
  ('returns.reverse', 'returns', 'التراجع عن مرتجع معتمد', 'Reverse an approved return'),
  ('returns.record_refund', 'returns', 'تسجيل استرداد نقدي فعلي', 'Record an actual cash refund'),
  ('returns.process_closed_day', 'returns', 'معالجة مرتجع في يوم مقفل', 'Process a return on a closed business day')
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key = 'super_admin' and p.key in ('returns.reverse', 'returns.record_refund', 'returns.process_closed_day')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
cross join public.permissions p
where r.key in ('admin', 'supervisor') and p.key in ('returns.reverse', 'returns.record_refund', 'returns.process_closed_day')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Part B — advisory lock: acquire_returns_order_lock_exclusive(order_id).
-- New namespace key1 = 1004 (1001 = financial master data, 1002 = daily
-- close, both 0065 — 1004 never collides with either since advisory locks
-- compare (key1, key2) as a pair). Exclusive-only (no shared counterpart
-- needed — every return-lifecycle writer takes this exclusively; there is
-- no concurrent-readers-vs-one-writer split here, unlike financial-master).
-- Serializes every return-lifecycle mutation (create/update-pending/
-- approve/reject/reverse — 0085-0088) for ONE order, and is also acquired
-- by update_sales_order()'s new "does an effective return exist" guard
-- (0084) — closes the race between a concurrent Sales financial edit and a
-- concurrent Return approval on the same order. VOLATILE (default),
-- transaction-scoped, REVOKE FROM PUBLIC + GRANT TO authenticated exactly
-- like acquire_financial_master_lock_exclusive() (0065) — reachable
-- directly by authenticated SECURITY INVOKER-adjacent callers, bounded
-- pacing risk only (acquires-then-releases-at-transaction-end, reads/writes
-- no data itself).
-- ---------------------------------------------------------------------------
create or replace function public.acquire_returns_order_lock_exclusive(p_sales_order_id uuid)
returns void
language sql
as $$
  select pg_advisory_xact_lock(1004, hashtext(p_sales_order_id::text));
$$;

comment on function public.acquire_returns_order_lock_exclusive(uuid) is
  'Phase 4 — EXCLUSIVE transaction-scoped advisory lock keyed on (1004, hashtext(sales_order_id)). Acquired by every Returns lifecycle writer (create_sales_return/update_pending_sales_return/approve_sales_return/reject_sales_return/reverse_sales_return, 0085-0088) for the target order, AND by update_sales_order()''s effective-return guard (0084) — so a concurrent Sales financial edit and a concurrent Return approval/reversal on the SAME order can never race past each others'' checks. Released automatically at transaction end.';

revoke execute on function public.acquire_returns_order_lock_exclusive(uuid) from public;
grant execute on function public.acquire_returns_order_lock_exclusive(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Part C — sales_returns (header)
-- ---------------------------------------------------------------------------
create table public.sales_returns (
  id uuid primary key default gen_random_uuid(),
  return_number text not null unique,
  sales_order_id uuid not null references public.sales_orders (id) on delete restrict,
  -- The store PROCESSING this return — may differ from the original Sale's
  -- store_id (a customer may return at a different branch than they bought
  -- from). Drives store-scope checks and daily-close locking for the
  -- return itself, independently of the original Sale's store/day.
  processed_store_id uuid not null references public.stores (id) on delete restrict,
  return_date date not null,
  customer_name_snapshot text,
  customer_phone_snapshot text,
  scenario text not null check (scenario in (
    'defective_product', 'customer_changed_mind', 'wrong_item_delivered', 'customer_never_received', 'other'
  )),
  scenario_notes text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'reversed')),
  row_version bigint not null default 1,
  -- Snapshots from sales_orders, captured ONLY at return creation — never
  -- live-resolved afterward (snapshot-only calculation, see design notes).
  order_subtotal_snapshot numeric(14, 2) not null,
  order_payment_fee_amount_snapshot numeric(14, 2) not null,
  payment_method_id uuid not null references public.payment_methods (id) on delete restrict,
  -- Computed ONLY at approval; retained permanently afterward (a later
  -- reversal does not erase these historical figures, it only stops them
  -- being "effective" — reversed_at below marks that transition instead).
  sales_revenue_reversal_amount numeric(14, 2),
  gross_profit_reversal_amount numeric(14, 2),
  payment_fee_reversal_amount numeric(14, 2),
  net_profit_reversal_amount numeric(14, 2),
  approved_refund_amount numeric(14, 2),
  -- payment_methods.refund_fee_policy read LIVE at approval time (current
  -- config consumed, not a historical resolver call — see design notes) and
  -- stored here so the exact rule actually applied is permanently visible.
  refund_fee_policy_snapshot text,
  approved_at timestamptz,
  approved_by uuid references public.profiles (id) on delete set null,
  rejected_at timestamptz,
  rejected_by uuid references public.profiles (id) on delete set null,
  rejection_reason text,
  reversed_at timestamptz,
  reversed_by uuid references public.profiles (id) on delete set null,
  reversal_reason text,
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_returns_scenario_notes_required_when_other check (
    scenario <> 'other' or (scenario_notes is not null and btrim(scenario_notes) <> '')
  ),
  -- Lifecycle field consistency — mirrors sales_order_items_removed_fields_
  -- consistent (0067)'s style: each status implies exactly which of the
  -- approve/reject/reverse field groups must (not) be set. 'reversed'
  -- implies approval fields stay set (a reversed return WAS approved) while
  -- reject fields stay null (a return is reached by exactly one terminal
  -- path — reject XOR approve-then-optionally-reverse, never both).
  constraint sales_returns_lifecycle_fields_consistent check (
    (status = 'pending' and approved_at is null and rejected_at is null and reversed_at is null)
    or (status = 'approved' and approved_at is not null and rejected_at is null and reversed_at is null)
    or (status = 'rejected' and rejected_at is not null and approved_at is null and reversed_at is null)
    or (status = 'reversed' and approved_at is not null and reversed_at is not null and rejected_at is null)
  )
);

comment on table public.sales_returns is
  'One row per return transaction (header). No hard delete, ever. No direct authenticated INSERT/UPDATE/DELETE/SELECT — every read goes through get_sales_return()/list_sales_returns() (0090), every write through create_sales_return()/update_pending_sales_return()/approve_sales_return()/reject_sales_return()/reverse_sales_return() (0085-0088), all SECURITY DEFINER. sales_order_id is permanent once set. "Effective return" = status = ''approved'' (approved and not yet reversed) — the only state that (a) exclusively claims its items'' sales_order_item_id via sales_return_items'' partial unique index, and (b) triggers update_sales_order()''s financial-lock guard (0084).';

create index sales_returns_sales_order_idx on public.sales_returns (sales_order_id);
create index sales_returns_processed_store_return_date_idx on public.sales_returns (processed_store_id, return_date);
create index sales_returns_status_idx on public.sales_returns (status);
create index sales_returns_payment_method_idx on public.sales_returns (payment_method_id);

alter table public.sales_returns enable row level security;
-- Deliberately zero RLS policies for `authenticated` — see the access-model
-- note at the top of this migration.

create trigger sales_returns_set_updated_at
  before update on public.sales_returns
  for each row
  execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Part D — sales_return_items
-- ---------------------------------------------------------------------------
create table public.sales_return_items (
  id uuid primary key default gen_random_uuid(),
  sales_return_id uuid not null references public.sales_returns (id) on delete restrict,
  -- Mandatory, permanent FK to the stable item identity (0067) — never
  -- line_no/category+weight/karat+price. This is the join key every
  -- coverage/double-return/order-state computation is built on.
  sales_order_item_id uuid not null references public.sales_order_items (id) on delete restrict,
  line_no integer not null check (line_no > 0),
  status text not null default 'active' check (status in ('active', 'removed')),
  removed_at timestamptz,
  removed_by uuid references public.profiles (id) on delete set null,
  -- Full snapshot from sales_order_items, captured ONLY at the moment this
  -- row is inserted (return creation, or a later pending edit that adds
  -- this item back as a fresh row — see update_pending_sales_return, 0086,
  -- which never reactivates a removed row, only inserts a new one) — never
  -- live-resolved, never re-read from sales_order_items afterward.
  category_name_ar_snapshot text not null,
  karat_code_snapshot text not null,
  karat_name_ar_snapshot text not null,
  weight_grams_snapshot numeric(10, 4) not null,
  sale_price_snapshot numeric(14, 2) not null,
  gold_component_cost_snapshot numeric(14, 2) not null,
  manufacturing_component_cost_snapshot numeric(14, 2) not null,
  base_cost_snapshot numeric(14, 2) not null,
  vat_cost_snapshot numeric(14, 2) not null,
  total_cost_snapshot numeric(14, 2) not null,
  gross_profit_snapshot numeric(14, 2) not null,
  item_calculation_version_snapshot integer not null,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (sales_return_id, line_no),
  constraint sales_return_items_removed_fields_consistent check (
    (status = 'active' and removed_at is null and removed_by is null)
    or (status = 'removed' and removed_at is not null)
  )
);

comment on table public.sales_return_items is
  'One row per returned line. No hard delete, ever — dropping an item from a still-pending return (update_pending_sales_return, 0086), or rejecting/reversing the whole return (which cascades a soft-remove over every active item), only ever sets status=''removed''; a removed row is never reused, a re-added item gets a brand new row. Every *_snapshot column is fixed at INSERT time from sales_order_items and never re-read afterward (snapshot-only calculation).';

-- THE double-return guard: at most one ACTIVE sales_return_items row may
-- ever reference a given sales_order_item_id, for as long as its parent
-- return is pending or approved (reject/reverse cascade the item to
-- removed, freeing it up again) — a real DB-enforced UNIQUE constraint, not
-- an app-only check, so it holds even against a raw service_role write. See
-- PHASE_4_DESIGN_NOTES.md for why this is preferred over an advisory lock
-- for this specific invariant, and 0126's concurrency test for proof this
-- correctly rejects a genuine concurrent double-claim race.
create unique index sales_return_items_order_item_active_uq
  on public.sales_return_items (sales_order_item_id)
  where status = 'active';

create index sales_return_items_sales_return_idx on public.sales_return_items (sales_return_id);
create index sales_return_items_sales_order_item_idx on public.sales_return_items (sales_order_item_id);

alter table public.sales_return_items enable row level security;
-- Deliberately zero RLS policies for `authenticated` — same access model.

-- ---------------------------------------------------------------------------
-- Part E — sales_return_refund_events (append-only actual-cash-refund ledger)
-- ---------------------------------------------------------------------------
create table public.sales_return_refund_events (
  id uuid primary key default gen_random_uuid(),
  sales_return_id uuid not null references public.sales_returns (id) on delete restrict,
  amount numeric(14, 2) not null check (amount > 0),
  refund_method_id uuid not null references public.payment_methods (id) on delete restrict,
  refunded_at timestamptz not null default now(),
  notes text,
  status text not null default 'active' check (status in ('active', 'reversed')),
  reversed_at timestamptz,
  reversed_by uuid references public.profiles (id) on delete set null,
  reversal_reason text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint sales_return_refund_events_reversed_fields_consistent check (
    (status = 'active' and reversed_at is null and reversed_by is null and reversal_reason is null)
    or (status = 'reversed' and reversed_at is not null and reversal_reason is not null)
  )
);

comment on table public.sales_return_refund_events is
  'Append-only ledger of ACTUAL cash refunds against a return — fully independent from sales_returns.approved_refund_amount (the computed TARGET; see design notes). amount/refund_method_id/notes are permanent once inserted; the only mutation ever allowed is status active->reversed (reverse_sales_return_refund_event(), 0089) to soft-void a mistaken entry, exactly mirroring sales_order_items'' soft-remove — never a hard delete, never an in-place amount edit. Actual Refunded Total = sum(amount) where status=''active''.';

create index sales_return_refund_events_sales_return_idx on public.sales_return_refund_events (sales_return_id);
create index sales_return_refund_events_refund_method_idx on public.sales_return_refund_events (refund_method_id);

alter table public.sales_return_refund_events enable row level security;
-- Deliberately zero RLS policies for `authenticated` — same access model.

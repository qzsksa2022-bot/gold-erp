-- ============================================================================
-- 0059: Phase 3 — Sales Core (2/8): core schema (order number, sales_orders,
-- sales_order_items, daily_closings)
-- ============================================================================
-- Migrations 0001-0058 are unmodified. This migration builds SCHEMA ONLY —
-- no client-writable path exists yet (no RPC to insert a row is created
-- until 0061/0063/0064) and RLS is enabled with ZERO policies for
-- `authenticated` on all three tables (see the access-model note below) —
-- deliberately so a fresh DB in between 0059 and 0061 has these tables
-- present but completely inert, matching how 0059 is meant to be read as a
-- pure "shape" migration.
--
-- ---------------------------------------------------------------------------
-- Access model, decided here and binding for every later Sales migration:
--
-- Every other sensitive table in this project (karats, manufacturing_fee_
-- versions, payment_methods, ...) keeps an authenticated INSERT/UPDATE RLS
-- policy for defense-in-depth even though the app always goes through a
-- trusted RPC — because for those tables, "the row is visible" and "the row
-- is writable" are the same permission (manufacturing_fees.manage), and
-- there is no per-COLUMN secret inside the row.
--
-- Sales is structurally different: §15 of the Phase 3 spec requires that a
-- user holding sales.view but NOT sales.view_profit must never be able to
-- obtain gross_profit/net_sales_profit/cost columns via ANY direct API —
-- not table SELECT, not a crafted PostgREST request. RLS is ROW-level, not
-- COLUMN-level, so a permissive "SELECT if sales.view" policy cannot itself
-- express "this row, minus these four columns." The only design that
-- satisfies §15 unconditionally is: no direct authenticated SELECT (or
-- INSERT/UPDATE/DELETE) policy on sales_orders/sales_order_items AT ALL —
-- every read goes through a trusted SECURITY DEFINER Read RPC (0062) that
-- decides, in application logic, whether to include the profit-sensitive
-- columns for THIS caller; every write goes through a trusted SECURITY
-- DEFINER RPC (create_sales_order 0061, update_sales_order 0063) the same
-- way manufacturing_fee_versions' create/cancel functions do, minus the
-- defense-in-depth direct-write policy (there is nothing to defend in
-- depth for a table with zero direct client access at all).
--
-- Consequence for auditing: the generic audit_table_changes() AFTER trigger
-- (0016/0024) is deliberately NOT attached to these three tables. That
-- trigger exists to catch mutations that bypass application code entirely
-- (a raw PostgREST call, a future forgetful code path) — a real risk for
-- every OTHER sensitive table, which does keep a direct-write RLS policy.
-- Sales has no such bypass path: the RPCs above are the only way to write
-- these tables (RLS denies everything else), so logging explicitly inside
-- each RPC via log_audit_event() is exactly as tamper-proof as a trigger
-- would be here, and it is the only way to produce the exact Arabic action
-- taxonomy the spec requires (sale.create / sale.update /
-- sale.closed_day_update / daily_closing.create — §21) including the
-- closed-day-edit distinction and mandatory reason, neither of which a
-- generic to_jsonb(old)/to_jsonb(new) trigger can determine on its own.
-- This is the narrow, documented, Sales-specific audit design the Phase 3
-- spec's §20 explicitly authorizes in place of extending Foundation's
-- generic mechanism — Foundation Hardening (0001-0039) and the audit
-- redesign (0016/0024) are not reopened or modified by this or any later
-- Phase 3 migration.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Order number: a Postgres SEQUENCE is the concurrency-safe primitive the
-- spec requires (§5: "MUST NOT use MAX(order_number)+1") — nextval() is
-- atomic across concurrent transactions with no lock contention and no
-- possibility of two callers ever observing the same value, unlike any
-- SELECT-then-compute approach. Global (not per-store) — the spec requires
-- global uniqueness, store-independent. Gaps on rollback are expected and
-- explicitly acceptable per spec §28 ("ما يهم هو التفرد لا التسلسل بلا
-- فجوات") — nextval() does not roll back with its calling transaction.
create sequence public.sales_order_number_seq as bigint start with 1 increment by 1 no cycle;

create or replace function public.generate_sales_order_number()
returns text
language sql
as $$
  select 'SALE-' || lpad(nextval('public.sales_order_number_seq')::text, 10, '0');
$$;

comment on function public.generate_sales_order_number() is
  'Issues the next globally-unique, gap-tolerant, concurrency-safe order number (format SALE-0000000001 — the exact format is an implementation detail, only global uniqueness/non-forgeability/monotonic-non-reuse are the real contract). VOLATILE (default) — nextval() has side effects and must never be marked STABLE/IMMUTABLE. Deliberately NOT granted to `authenticated` (see REVOKE below) — only create_sales_order() (0061), itself SECURITY DEFINER, calls this; a client can never pre-burn or forge a specific order number by calling this directly.';

revoke execute on function public.generate_sales_order_number() from public;
-- No GRANT to authenticated — SECURITY DEFINER callers (create_sales_order,
-- 0061) execute as the function owner, which retains EXECUTE implicitly;
-- see is_trusted_bootstrap_context() (0013) for the identical pattern.

-- ---------------------------------------------------------------------------
-- sales_orders
-- ---------------------------------------------------------------------------
create table public.sales_orders (
  id uuid primary key default gen_random_uuid(),
  -- Issued exclusively by generate_sales_order_number() inside
  -- create_sales_order() (0061) — never client-supplied, never editable.
  order_number text not null unique,
  store_id uuid not null references public.stores (id) on delete restrict,
  -- The business day this sale belongs to (drives Daily Close/§19-20 and
  -- every financial snapshot resolution, §8) — distinct from sold_at
  -- (the real-world moment of entry). Phase 3 keeps this unchangeable once
  -- set (§18: "يُفضَّل عدم السماح بتغيير store_id أو sale_date... لتفادي
  -- نقل سجل مالي تاريخي بين متجر/يوم آخر") — enforced by update_sales_order
  -- (0063) simply never accepting it as an editable field, not by a DB
  -- trigger (no legitimate DB-level writer other than that RPC exists to
  -- guard against).
  sale_date date not null,
  sold_at timestamptz not null default now(),
  salesperson_id uuid not null references public.profiles (id) on delete restrict,
  payment_method_id uuid not null references public.payment_methods (id) on delete restrict,
  collection_channel_id uuid not null references public.collection_channels (id) on delete restrict,
  customer_name text,
  customer_phone text,
  notes text,
  -- Payment fee snapshot (§8) — resolved once at creation (or recomputed on
  -- a financial edit, 0063) from payment_fee_for_method_on_date(), never
  -- re-derived live afterward.
  payment_fee_version_id uuid not null references public.payment_method_fee_versions (id) on delete restrict,
  payment_fee_percentage_snapshot numeric(6, 3) not null check (payment_fee_percentage_snapshot >= 0),
  payment_fee_fixed_snapshot numeric(12, 4) not null check (payment_fee_fixed_snapshot >= 0),
  -- Order-level computed totals (§2/§7 — rounded to 2dp, the currency
  -- output boundary; every intermediate step of the computation that
  -- PRODUCES these values uses full NUMERIC precision inside the
  -- create/update RPCs, never rounded before this final storage point).
  payment_fee_amount numeric(14, 2) not null check (payment_fee_amount >= 0),
  subtotal numeric(14, 2) not null,
  gross_profit numeric(14, 2) not null,
  net_sales_profit numeric(14, 2) not null,
  -- Tags which version of the calculation engine produced this row's
  -- totals — not consumed by any logic in this phase, reserved so a future
  -- change to the calculation rules can distinguish old snapshots from new
  -- ones without guessing from created_at.
  calculation_version integer not null default 1,
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.sales_orders is
  'One row per sales order (header). No hard delete, ever. No direct authenticated INSERT/UPDATE/DELETE/SELECT — see the access-model note at the top of migration 0059. order_number is issued exclusively by generate_sales_order_number() and is permanent once set; store_id/sale_date are permanent once set (Phase 3 has no order-identity-change workflow, §18).';

create index sales_orders_sale_date_idx on public.sales_orders (sale_date);
create index sales_orders_store_sale_date_idx on public.sales_orders (store_id, sale_date);
create index sales_orders_salesperson_sale_date_idx on public.sales_orders (salesperson_id, sale_date);
create index sales_orders_payment_method_idx on public.sales_orders (payment_method_id);
create index sales_orders_collection_channel_idx on public.sales_orders (collection_channel_id);

alter table public.sales_orders enable row level security;
-- Deliberately zero RLS policies for `authenticated` — see the access-model
-- note at the top of this migration. service_role (used only by internal
-- tooling/scripts, never the app) is unaffected by RLS as usual.

create trigger sales_orders_set_updated_at
  before update on public.sales_orders
  for each row
  execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- sales_order_items
-- ---------------------------------------------------------------------------
create table public.sales_order_items (
  id uuid primary key default gen_random_uuid(),
  sales_order_id uuid not null references public.sales_orders (id) on delete restrict,
  line_no integer not null check (line_no > 0),
  category_id uuid not null references public.product_categories (id) on delete restrict,
  karat_id uuid not null references public.karats (id) on delete restrict,
  item_name text,
  description text,
  -- Free-form internal reference/SKU — NOT integrated with an Inventory
  -- system (not built in this phase, §35) and not validated against
  -- anything; purely a searchable label the salesperson may optionally
  -- enter.
  sku text,
  weight_grams numeric(10, 4) not null check (weight_grams > 0),
  sale_price numeric(14, 2) not null check (sale_price >= 0),
  -- Snapshots (§8) — resolved once at creation (or recomputed on a
  -- financial edit, 0063) from sale_date; never re-derived live afterward,
  -- so a later change to the category name / karat name / gold price /
  -- manufacturing fee / VAT rate never silently alters a historical item.
  category_name_ar_snapshot text not null,
  karat_code_snapshot text not null,
  karat_name_ar_snapshot text not null,
  daily_gold_price_id uuid not null references public.daily_gold_prices (id) on delete restrict,
  gold_price_per_gram_snapshot numeric(12, 4) not null check (gold_price_per_gram_snapshot > 0),
  manufacturing_fee_version_id uuid not null references public.manufacturing_fee_versions (id) on delete restrict,
  manufacturing_fee_per_gram_snapshot numeric(12, 4) not null check (manufacturing_fee_per_gram_snapshot >= 0),
  vat_rate_version_id uuid not null references public.vat_rate_versions (id) on delete restrict,
  vat_rate_percent_snapshot numeric(6, 3) not null check (vat_rate_percent_snapshot >= 0 and vat_rate_percent_snapshot <= 100),
  -- Cost breakdown (§2 formulas), each column the exact term the spec names
  -- — rounded to 2dp at this final storage boundary (§7); the RPCs that
  -- compute these use full NUMERIC precision throughout and round only
  -- once, right here.
  gold_component_cost numeric(14, 2) not null,
  manufacturing_component_cost numeric(14, 2) not null,
  base_cost numeric(14, 2) not null,
  vat_cost numeric(14, 2) not null,
  total_cost numeric(14, 2) not null,
  gross_profit numeric(14, 2) not null,
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (sales_order_id, line_no)
);

comment on table public.sales_order_items is
  'One row per line item on a sales order. No hard delete, ever — editing an order''s items (0063) replaces the item set inside the same transaction as the order, never leaves an orphaned or partially-updated item. No direct authenticated INSERT/UPDATE/DELETE/SELECT — see the access-model note in migration 0059''s header. Every *_snapshot / *_cost / gross_profit column is fixed at write time and never recomputed from current master data afterward (§26).';

create index sales_order_items_sales_order_idx on public.sales_order_items (sales_order_id);
create index sales_order_items_category_idx on public.sales_order_items (category_id);
create index sales_order_items_karat_idx on public.sales_order_items (karat_id);

alter table public.sales_order_items enable row level security;
-- Deliberately zero RLS policies for `authenticated` — same access model as
-- sales_orders above.

create trigger sales_order_items_set_updated_at
  before update on public.sales_order_items
  for each row
  execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- daily_closings
-- ---------------------------------------------------------------------------
-- No row for (store_id, business_date) = day open. A row exists = day
-- closed. No hard delete, no reopen in this phase (§19) — once inserted, a
-- row is permanent; there is no UPDATE/DELETE RPC for this table at all.
create table public.daily_closings (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id) on delete restrict,
  business_date date not null,
  closed_at timestamptz not null default now(),
  closed_by uuid references public.profiles (id) on delete set null,
  notes text,
  unique (store_id, business_date)
);

comment on table public.daily_closings is
  'Presence of a row = (store_id, business_date) is closed for new/edited Sales unless the caller holds sales.edit_closed_day with a mandatory reason (§20). No row = day open. No hard delete, no reopen in Phase 3 — permanent once created. Written exclusively by close_sales_day() (0064, SECURITY DEFINER).';

-- Unlike sales_orders/sales_order_items, this table carries no
-- profit-sensitive data at all (just store/date/who/when/optional note),
-- so a direct SELECT policy gated by sales.view + store visibility is
-- sufficient and does not need to go through a Read RPC — any caller who
-- can see a store's Sales history (user_visible_store_ids) needs to be
-- able to tell whether a given day is closed (e.g. the "اليوم مغلق" badge,
-- §22) without an extra round trip.
alter table public.daily_closings enable row level security;

create policy daily_closings_select on public.daily_closings
  for select to authenticated
  using (
    public.has_permission('sales.view')
    -- my_visible_store_ids() (0017), NOT user_visible_store_ids(uuid) --
    -- the latter is deliberately service_role-only (its uuid parameter
    -- would let any caller probe another user's scope), so referencing it
    -- directly inside an RLS policy evaluated as `authenticated` fails
    -- with "permission denied for function" on every real request. Every
    -- other RLS policy in this project that needs store scope already uses
    -- the self-scoped, authenticated-callable my_operable_store_ids()/
    -- my_visible_store_ids() wrappers for exactly this reason (e.g. 0035)
    -- -- this policy now matches that established convention.
    and store_id in (select public.my_visible_store_ids())
  );

-- No INSERT/UPDATE/DELETE policy — close_sales_day() (0064) is the
-- exclusive writer (SECURITY DEFINER), and there is no update/reopen path
-- at all in this phase.

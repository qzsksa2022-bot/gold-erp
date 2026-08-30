-- ============================================================================
-- 0116: Phase 5 — Shipping Core (4/9): shipments, status/financial event
-- ledgers, state machine
-- ============================================================================
-- Migrations 0001-0115 are unmodified.
--
-- Access model — IDENTICAL reasoning to sales_orders (0059)/sales_returns
-- (0082): shipments carries a MIX of non-sensitive operational columns
-- (shipment_number, order/return links, carrier, zone, tracking, customer_
-- shipping_charge, status, dates — Section 26, visible to shipments.view)
-- and Profit/Cost-sensitive columns on the SAME row (expected_carrier_cost/
-- actual_carrier_cost/net_shipping_expected/net_shipping_actual — Section
-- 26, visible only to sales.view_profit). RLS is row-level, not
-- column-level, so the only design that satisfies this unconditionally is:
-- ZERO direct authenticated policies on any of the three tables below —
-- every read goes through get_shipment()/list_shipments() (0119, decides
-- column inclusion in application logic), every write through the RPCs in
-- 0117/0118. Audit trail is written explicitly via log_audit_event() inside
-- each RPC (0121 extends audit_logs RLS the same way 0072/0091 already do
-- for sale.%/return.%).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Part A — shipment_number (Section 10): globally unique, DB-generated,
-- concurrency-safe via a Postgres SEQUENCE (nextval() is atomic) — byte-for-
-- byte the same pattern as generate_sales_order_number()/generate_sales_
-- return_number() (0059/0083). Gaps on rollback are expected and harmless.
-- ---------------------------------------------------------------------------
create sequence public.shipment_number_seq as bigint start with 1 increment by 1 no cycle;

create or replace function public.generate_shipment_number()
returns text
language sql
as $$
  select 'SHP-' || lpad(nextval('public.shipment_number_seq')::text, 10, '0');
$$;

comment on function public.generate_shipment_number() is
  'Phase 5 (Section 10) — issues the next globally-unique, gap-tolerant, concurrency-safe shipment number (format SHP-0000000001). VOLATILE. Deliberately NOT granted to `authenticated` — only create_shipment() (0117), itself SECURITY DEFINER, calls this.';

revoke execute on function public.generate_shipment_number() from public;

-- ---------------------------------------------------------------------------
-- Part B — shipments (header). No UNIQUE(sales_order_id) — Section 12:
-- multiple shipments per order/return are a first-class scenario (partial
-- shipments, replacements, multiple return legs).
-- ---------------------------------------------------------------------------
create table public.shipments (
  id uuid primary key default gen_random_uuid(),
  shipment_number text not null unique,
  sales_order_id uuid not null references public.sales_orders (id) on delete restrict,
  -- Section 23 — only ever set for direction='return' (enforced by the
  -- check constraint below); NOT re-validated against the return's CURRENT
  -- status on every future read, only at creation time (create_shipment,
  -- 0117) — a return shipment is a historical fact once created, exactly
  -- like sales_return_items keeps its link even if the parent return is
  -- later reversed.
  sales_return_id uuid references public.sales_returns (id) on delete restrict,
  -- The store PROCESSING this shipment (Section 24) — drives store-scope
  -- checks and Daily Close locking, independent of the original Sale's
  -- store.
  store_id uuid not null references public.stores (id) on delete restrict,
  carrier_id uuid not null references public.shipping_carriers (id) on delete restrict,
  shipping_zone_id uuid not null references public.shipping_zones (id) on delete restrict,
  direction text not null check (direction in ('outbound', 'return')),
  fulfillment_type text not null default 'delivery' check (fulfillment_type in ('delivery', 'store_courier', 'pickup', 'other')),
  tracking_number text,
  external_reference text,
  -- Recipient snapshot (Section 9) — captured at creation, never re-read
  -- live from sales_orders afterward (a customer's phone/name on file may
  -- change later; the shipment reflects who it was actually sent to/for at
  -- the time).
  customer_name_snapshot text,
  customer_phone_snapshot text,
  recipient_address_snapshot text,
  shipment_date date not null,
  -- Financial snapshots (Section 16/17/18) — customer_shipping_charge is
  -- the ORIGINAL value captured at creation and never overwritten in place;
  -- a later correction is an append-only shipment_financial_events row
  -- (Section 19/33/20) — get_shipment()/list_shipments() (0119) derive the
  -- CURRENT effective value from the latest such event if one exists, else
  -- fall back to this column.
  customer_shipping_charge numeric(10, 2) not null check (customer_shipping_charge >= 0),
  carrier_rate_version_id uuid references public.shipping_carrier_rate_versions (id) on delete restrict,
  expected_carrier_cost numeric(10, 2) not null check (expected_carrier_cost >= 0),
  -- Section 17 — if no rate CONFIGURATION existed at creation time, the
  -- actor supplied this manually with a mandatory reason instead of the
  -- expected cost silently defaulting to zero or creation being blocked
  -- indefinitely.
  expected_carrier_cost_is_manual boolean not null default false,
  expected_carrier_cost_manual_reason text,
  -- Cache of the latest actual_cost_recorded/actual_cost_correction event's
  -- amount (Section 19) — NULL until the first real invoice is recorded.
  -- The append-only shipment_financial_events table (Part D) is the real
  -- source of truth/history; this column exists purely so get_shipment()/
  -- list_shipments() don't need a correlated subquery on every read.
  actual_carrier_cost numeric(10, 2),
  -- Cached Shipping P/L (Section 32) — recomputed transactionally on every
  -- write that could change either input (create/cost-record/cost-correct/
  -- charge-correct), never read live-derived elsewhere.
  net_shipping_expected numeric(10, 2) not null,
  net_shipping_actual numeric(10, 2),
  -- COD (Section 21/22) — OPERATIONAL state only. No settlement batches,
  -- no bank reconciliation, no commissions in this phase.
  is_cod boolean not null default false,
  cod_expected_amount numeric(10, 2),
  cod_collection_state text not null default 'unknown' check (cod_collection_state in ('expected', 'collected', 'not_collected', 'unknown')),
  current_status text not null default 'created' check (current_status in (
    'created', 'ready_for_pickup', 'picked_up', 'in_transit', 'out_for_delivery',
    'delivered', 'delivery_failed', 'customer_refused', 'customer_never_received',
    'returned_to_store', 'cancelled'
  )),
  notes text,
  row_version bigint not null default 1,
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Section 23 — a Return shipment (sales_return_id set) requires
  -- direction='return'; an Outbound shipment (direction='outbound') must
  -- never carry a sales_return_id. A real DB invariant, not just an
  -- application-level check.
  constraint shipments_return_link_matches_direction check (
    (sales_return_id is null) or (direction = 'return')
  ),
  constraint shipments_manual_expected_cost_consistent check (
    (expected_carrier_cost_is_manual = false and expected_carrier_cost_manual_reason is null)
    or (expected_carrier_cost_is_manual = true and expected_carrier_cost_manual_reason is not null and btrim(expected_carrier_cost_manual_reason) <> '')
  ),
  -- Section 17 — a NON-manual expected cost must always carry the rate
  -- version it was resolved from (the historical snapshot proof); a MANUAL
  -- one never does (there was no configuration to snapshot).
  constraint shipments_rate_version_matches_manual_flag check (
    (expected_carrier_cost_is_manual = true and carrier_rate_version_id is null)
    or (expected_carrier_cost_is_manual = false and carrier_rate_version_id is not null)
  ),
  constraint shipments_cod_fields_consistent check (
    (is_cod = false and cod_expected_amount is null) or (is_cod = true)
  )
);

comment on table public.shipments is
  'Phase 5 — one row per shipment leg (outbound or return). No hard delete, ever — a mistaken/unwanted shipment is cancelled via a status event (current_status=''cancelled''), never removed. No UNIQUE(sales_order_id) — Section 12: multiple shipments per order/return is a first-class scenario. No direct authenticated INSERT/UPDATE/DELETE/SELECT — every read goes through get_shipment()/list_shipments() (0119), every write through create_shipment()/add_shipment_status_event()/record_shipment_actual_cost()/correct_shipment_actual_cost()/correct_shipment_customer_charge() (0117/0118), all SECURITY DEFINER. Shipping P/L (net_shipping_expected/net_shipping_actual) is fully independent from sales_orders.net_sales_profit/sales_returns.net_sales_profit_adjustment — nothing in this phase writes to either of those columns.';

create index shipments_sales_order_idx on public.shipments (sales_order_id);
create index shipments_sales_return_idx on public.shipments (sales_return_id) where sales_return_id is not null;
create index shipments_store_shipment_date_idx on public.shipments (store_id, shipment_date);
create index shipments_carrier_idx on public.shipments (carrier_id);
create index shipments_current_status_idx on public.shipments (current_status);

alter table public.shipments enable row level security;
-- Deliberately zero RLS policies for `authenticated` — see the access-model
-- note at the top of this migration.

create trigger shipments_set_updated_at
  before update on public.shipments
  for each row
  execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Part C — shipment_status_events (Section 13/14): append-only. NO UPDATE/
-- DELETE, ever, unconditionally — unlike sales_return_refund_events (0106),
-- there is no legacy pre-existing data to backfill here (Phase 5 is brand
-- new), so no escape-hatch GUC is needed at all.
-- ---------------------------------------------------------------------------
create table public.shipment_status_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.shipments (id) on delete restrict,
  status text not null check (status in (
    'created', 'ready_for_pickup', 'picked_up', 'in_transit', 'out_for_delivery',
    'delivered', 'delivery_failed', 'customer_refused', 'customer_never_received',
    'returned_to_store', 'cancelled'
  )),
  event_business_date date not null,
  event_at timestamptz not null default now(),
  notes text,
  -- Section 14 — true for any transition NOT on the normal forward flow
  -- (validate_shipment_status_transition() below) — required to carry a
  -- non-empty `notes` (used as the mandatory reason) and requires the actor
  -- to hold shipments.correct_status, enforced in add_shipment_status_
  -- event() (0118), not here.
  is_correction boolean not null default false,
  external_reference text,
  actor uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

comment on table public.shipment_status_events is
  'Phase 5 (Section 13) — append-only status timeline. shipments.current_status (Part B) is a transactionally-maintained cache of the latest event here, updated only by add_shipment_status_event() (0118) — never written directly. NO UPDATE/DELETE, ever (trigger-enforced below) — a wrong status is corrected by appending a NEW is_correction=true event with a mandatory reason, never by editing/removing history.';

create index shipment_status_events_shipment_idx on public.shipment_status_events (shipment_id, created_at);

alter table public.shipment_status_events enable row level security;
-- Deliberately zero RLS policies for `authenticated`.

create or replace function public.reject_shipment_status_event_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'shipment_status_events سجل ثابت لا يقبل التعديل أو الحذف بعد إنشائه' using errcode = 'P0001';
end;
$$;

create trigger shipment_status_events_no_update
  before update on public.shipment_status_events
  for each row execute function public.reject_shipment_status_event_mutation();

create trigger shipment_status_events_no_delete
  before delete on public.shipment_status_events
  for each row execute function public.reject_shipment_status_event_mutation();

comment on function public.reject_shipment_status_event_mutation() is
  'Phase 5 (Section 13) — unconditional trigger backstop against UPDATE/DELETE on shipment_status_events. No escape hatch (unlike 0106''s app.allow_refund_event_backfill) — Phase 5 has no legacy pre-existing data to backfill.';

-- ---------------------------------------------------------------------------
-- Part D — shipment_financial_events (Section 19/20/33): append-only ledger
-- for BOTH actual-carrier-cost recording/correction AND customer-shipping-
-- charge correction. One unified table (rather than two nearly-identical
-- ones) — every event type shares the exact same shape (amount + business
-- date + reference + reason/notes + actor), and the distinction of WHICH
-- shipment column each affects is exactly what event_type encodes.
-- ---------------------------------------------------------------------------
create table public.shipment_financial_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.shipments (id) on delete restrict,
  event_type text not null check (event_type in ('actual_cost_recorded', 'actual_cost_correction', 'customer_charge_correction')),
  amount numeric(10, 2) not null check (amount >= 0),
  business_date date not null,
  reference text,
  -- Mandatory for *_correction event types (enforced in record_shipment_
  -- actual_cost()/correct_shipment_actual_cost()/correct_shipment_customer_
  -- charge(), 0118, not by a table CHECK, since the same free-text column
  -- is optional notes for the very first actual_cost_recorded event).
  reason text,
  actor uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

comment on table public.shipment_financial_events is
  'Phase 5 (Section 19/33) — append-only financial correction ledger. actual_cost_recorded = the first real carrier invoice amount known for a shipment; actual_cost_correction = a later correction to that (mandatory reason); customer_charge_correction = a correction to the ORIGINAL customer_shipping_charge captured at creation (mandatory reason). shipments.actual_carrier_cost (cache) = the amount of the latest actual_cost_recorded/actual_cost_correction row for that shipment; the CURRENT effective customer_shipping_charge (derived in get_shipment()/list_shipments(), 0119) = the amount of the latest customer_charge_correction row if one exists, else shipments.customer_shipping_charge itself. NO UPDATE/DELETE, ever (trigger-enforced below) — "لا overwrite مالي بلا تاريخ".';

create index shipment_financial_events_shipment_idx on public.shipment_financial_events (shipment_id, created_at);

alter table public.shipment_financial_events enable row level security;
-- Deliberately zero RLS policies for `authenticated`.

create or replace function public.reject_shipment_financial_event_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'shipment_financial_events سجل ثابت لا يقبل التعديل أو الحذف بعد إنشائه' using errcode = 'P0001';
end;
$$;

create trigger shipment_financial_events_no_update
  before update on public.shipment_financial_events
  for each row execute function public.reject_shipment_financial_event_mutation();

create trigger shipment_financial_events_no_delete
  before delete on public.shipment_financial_events
  for each row execute function public.reject_shipment_financial_event_mutation();

-- ---------------------------------------------------------------------------
-- Part E — the state machine (Section 13/14). A plain, explicitly-documented
-- lookup, NOT a carrier-branching decision (Section 3's ban is specifically
-- on branching CALCULATION logic by carrier identity — a shipment status
-- state machine is a genuinely different concern and applies uniformly
-- across every carrier/fulfillment_type).
--
-- Normal forward flow (no shipments.correct_status/reason needed, though a
-- free-text `notes` is always accepted):
--   created            -> ready_for_pickup | picked_up | cancelled
--   ready_for_pickup   -> picked_up | cancelled
--   picked_up          -> in_transit | out_for_delivery | delivery_failed | cancelled
--   in_transit         -> out_for_delivery | delivery_failed | cancelled
--   out_for_delivery   -> delivered | delivery_failed | customer_refused | customer_never_received
--   delivery_failed    -> out_for_delivery | returned_to_store | customer_never_received | cancelled
--   customer_refused   -> returned_to_store | customer_never_received
--   customer_never_received -> returned_to_store
--   delivered, returned_to_store, cancelled -> (terminal; no normal forward
--     transition out of any of these three)
-- Any transition NOT listed above (including any transition FROM delivered/
-- returned_to_store/cancelled) is a CORRECTION — requires shipments.
-- correct_status + a non-empty reason, enforced in add_shipment_status_
-- event() (0118), and is tagged is_correction=true on the appended event.
-- ---------------------------------------------------------------------------
create or replace function public.validate_shipment_status_transition(p_current text, p_new text)
returns boolean
language sql
immutable
as $$
  select p_new = any(case p_current
    when 'created' then array['ready_for_pickup', 'picked_up', 'cancelled']
    when 'ready_for_pickup' then array['picked_up', 'cancelled']
    when 'picked_up' then array['in_transit', 'out_for_delivery', 'delivery_failed', 'cancelled']
    when 'in_transit' then array['out_for_delivery', 'delivery_failed', 'cancelled']
    when 'out_for_delivery' then array['delivered', 'delivery_failed', 'customer_refused', 'customer_never_received']
    when 'delivery_failed' then array['out_for_delivery', 'returned_to_store', 'customer_never_received', 'cancelled']
    when 'customer_refused' then array['returned_to_store', 'customer_never_received']
    when 'customer_never_received' then array['returned_to_store']
    else array[]::text[]
  end);
$$;

comment on function public.validate_shipment_status_transition(text, text) is
  'Phase 5 (Section 13/14) — true iff (p_current -> p_new) is a NORMAL forward transition per the documented state machine above (see this migration''s Part E comment for the full diagram). false for any other pair, including delivered/returned_to_store/cancelled -> anything (all three are terminal for normal flow) and p_current = p_new (re-appending the same status is always a correction, never a no-op normal transition). IMMUTABLE, no table access.';

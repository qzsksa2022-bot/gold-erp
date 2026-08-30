-- ============================================================================
-- 0135: Phase 6 — Services / Adjustments Core (3/11): sales_order_adjustments
-- + sales_order_adjustment_reversals (append-only)
-- ============================================================================
-- Migrations 0001-0134 are unmodified.
--
-- Access model — IDENTICAL reasoning to shipments (0116): sales_order_
-- adjustments carries a MIX of non-sensitive operational columns
-- (adjustment_number, sales_order_id link, type, dates, processing store,
-- customer_charge — §31, visible to adjustments.view) and Profit/Cost-
-- sensitive columns on the SAME row (direct_cost/payment_fee_amount/
-- gross_adjustment_profit/net_adjustment_profit — §29, visible only to
-- sales.view_profit). RLS is row-level, not column-level, so the only
-- design that satisfies this unconditionally is: ZERO direct authenticated
-- policies on either table below — every read goes through
-- get_sales_order_adjustment()/list_sales_order_adjustments() (0142,
-- decides column inclusion in application logic), every write through the
-- RPCs in 0139/0140/0141. Audit trail is written explicitly via
-- log_audit_event() inside each RPC (0143 extends audit_logs RLS the same
-- way 0121/0124 already do for shipment.%/shipping_rate.%).
--
-- Core architectural rule (§2): the ORIGINAL invoice (sales_orders.
-- subtotal) is NEVER touched by anything in this migration or any later
-- Phase 6 one. Adjustments are wholly separate append-only records; a
-- narrow summary RPC (0142) computes Original + Effective Approved
-- Adjustments Charges = Total Including Adjustments. Returns/Shipping stay
-- fully separate — nothing here reads sales_returns or shipments.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Part A — adjustment_number (§14): globally unique, DB-generated,
-- concurrency-safe via a Postgres SEQUENCE — byte-for-byte the same pattern
-- as generate_sales_order_number()/generate_shipment_number() (0059/0116).
-- Deliberately NOT MAX()+1.
-- ---------------------------------------------------------------------------
create sequence public.adjustment_number_seq as bigint start with 1 increment by 1 no cycle;

create or replace function public.generate_adjustment_number()
returns text
language sql
as $$
  select 'ADJ-' || lpad(nextval('public.adjustment_number_seq')::text, 10, '0');
$$;

comment on function public.generate_adjustment_number() is
  'Phase 6 (§14) — issues the next globally-unique, gap-tolerant, concurrency-safe adjustment number (format ADJ-0000000001). VOLATILE. Deliberately NOT granted to `authenticated` — only create_sales_order_adjustment() (0139), itself SECURITY DEFINER, calls this.';

revoke execute on function public.generate_adjustment_number() from public;

-- ---------------------------------------------------------------------------
-- Part B — sales_order_adjustments (header + financial fields).
-- ---------------------------------------------------------------------------
create table public.sales_order_adjustments (
  id uuid primary key default gen_random_uuid(),
  adjustment_number text not null unique,
  sales_order_id uuid not null references public.sales_orders (id) on delete restrict,
  adjustment_type_id uuid not null references public.adjustment_types (id) on delete restrict,
  -- §27 — snapshotted ONLY at Approval (0140); NULL while pending (the live
  -- join via adjustment_type_id is the source of truth for a pending
  -- record's display name). Immune to a later type rename/disable once set.
  adjustment_type_code_snapshot text,
  adjustment_type_name_ar_snapshot text,
  adjustment_type_name_en_snapshot text,
  -- The store PROCESSING this adjustment (§23) — drives store-scope checks
  -- and Daily Close locking, independent of the original Sale's store.
  -- Cross-store (Order at Store A, Processing at Store B) is explicitly
  -- allowed if the actor has visibility of A and can operate B.
  processing_store_id uuid not null references public.stores (id) on delete restrict,
  adjustment_date date not null,
  payment_method_id uuid not null references public.payment_methods (id) on delete restrict,
  collection_channel_id uuid not null references public.collection_channels (id) on delete restrict,
  -- §28 — snapshotted at Approval, same reasoning as the type snapshot
  -- above (a payment method/channel could be renamed after approval).
  payment_method_name_snapshot text,
  collection_channel_name_snapshot text,
  -- §13 — explicit user input, NEVER inferred/hardcoded per payment method
  -- or brand. Editable while pending; immutable once approved (0140 simply
  -- carries the pending value forward and never re-asks for it).
  participates_in_settlement boolean not null,
  -- §9 — >= 0, exactly 2 decimals (enforced in the RPCs via round(x,2)
  -- before every write, matching the project-wide convention documented in
  -- migration 0116's header — no DB-level scale CHECK exists anywhere in
  -- this schema).
  customer_charge numeric(12, 2) not null check (customer_charge >= 0),
  -- §9 — nullable while pending (an explicit 0.00 is a real, different
  -- input from "not yet supplied" — the CHECK below enforces direct_cost is
  -- required before status can become 'approved').
  direct_cost numeric(12, 2) check (direct_cost is null or direct_cost >= 0),
  -- §11/§12 — resolved + snapshotted ONLY at Approval (0140) from the SAME
  -- canonical payment_fee_for_method_on_date() engine Sales uses (0056),
  -- computed on customer_charge, never on any Sales Order subtotal. NULL
  -- while pending — Preview (0138) is explicitly NOT a trusted source.
  payment_fee_version_id uuid references public.payment_method_fee_versions (id) on delete restrict,
  payment_fee_percentage_snapshot numeric(6, 3) check (payment_fee_percentage_snapshot is null or payment_fee_percentage_snapshot >= 0),
  payment_fee_fixed_snapshot numeric(12, 4) check (payment_fee_fixed_snapshot is null or payment_fee_fixed_snapshot >= 0),
  payment_fee_amount numeric(12, 2) check (payment_fee_amount is null or payment_fee_amount >= 0),
  -- §3 — fully independent from sales_orders.net_sales_profit/sales_
  -- returns.net_sales_profit_adjustment/shipments.net_shipping_*. Gross =
  -- customer_charge - direct_cost (can be negative — §50, negative PROFIT
  -- is allowed, negative INPUT money is not). Net = Gross - payment_fee_
  -- amount.
  gross_adjustment_profit numeric(12, 2),
  net_adjustment_profit numeric(12, 2),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  rejection_reason text,
  notes text,
  row_version bigint not null default 1,
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  approved_by uuid references public.profiles (id) on delete set null,
  rejected_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  approved_at timestamptz,
  rejected_at timestamptz,
  -- §15 — strict lifecycle: pending -> approved OR pending -> rejected,
  -- both terminal/immutable. An approved row must carry a full financial
  -- snapshot (direct_cost supplied, fee resolved); a rejected row must
  -- carry a non-empty reason; a pending row carries neither timestamp.
  constraint sales_order_adjustments_lifecycle_consistent check (
    (status = 'pending' and approved_at is null and rejected_at is null and approved_by is null and rejected_by is null)
    or (
      status = 'approved' and approved_at is not null and approved_by is not null
      and rejected_at is null and rejected_by is null
      and direct_cost is not null
      and payment_fee_version_id is not null
      and payment_fee_amount is not null
      and gross_adjustment_profit is not null
      and net_adjustment_profit is not null
      and adjustment_type_code_snapshot is not null
    )
    or (
      status = 'rejected' and rejected_at is not null and rejected_by is not null
      and approved_at is null and approved_by is null
      and rejection_reason is not null and btrim(rejection_reason) <> ''
    )
  )
);

comment on table public.sales_order_adjustments is
  'Phase 6 — one row per post-sale Service/Adjustment linked to a sales_orders row. Append-only in spirit: the ORIGINAL invoice (sales_orders.subtotal) is never touched; a correction to an APPROVED record goes through sales_order_adjustment_reversals (Part C), never an in-place edit of this row''s financial columns. No hard delete, ever. No direct authenticated INSERT/UPDATE/DELETE/SELECT — every read goes through get_sales_order_adjustment()/list_sales_order_adjustments() (0142), every write through create/update/approve/reject/reverse_sales_order_adjustment() (0139/0140/0141), all SECURITY DEFINER. Adjustment Gross/Net Profit is fully independent from sales_orders.net_sales_profit/sales_returns.net_sales_profit_adjustment/shipments.net_shipping_*.';

create index sales_order_adjustments_sales_order_idx on public.sales_order_adjustments (sales_order_id);
create index sales_order_adjustments_store_date_idx on public.sales_order_adjustments (processing_store_id, adjustment_date);
create index sales_order_adjustments_status_idx on public.sales_order_adjustments (status);
create index sales_order_adjustments_type_idx on public.sales_order_adjustments (adjustment_type_id);

alter table public.sales_order_adjustments enable row level security;
-- Deliberately zero RLS policies for `authenticated` — see the access-model
-- note at the top of this migration.

create trigger sales_order_adjustments_set_updated_at
  before update on public.sales_order_adjustments
  for each row
  execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Part C — sales_order_adjustment_reversals (§19/§20): append-only
-- administrative correction ledger. NOT a customer refund engine — no
-- Refund Ledger/Settlement interaction exists in this phase. UNIQUE(sales_
-- order_adjustment_id) enforces "at most one effective reversal" at the DB
-- level (0141 additionally pre-checks this for a friendly error message
-- before ever hitting the constraint). The original adjustment row is NEVER
-- deleted/rewritten by a reversal (0141 does not touch sales_order_
-- adjustments' financial columns at all) — both the original effect (at
-- adjustment_date, preserved on the parent row) and the reversal effect (at
-- reversal_business_date, this row) remain readable forever; the date is
-- never erased as if the Adjustment never happened.
-- ---------------------------------------------------------------------------
create table public.sales_order_adjustment_reversals (
  id uuid primary key default gen_random_uuid(),
  sales_order_adjustment_id uuid not null unique references public.sales_order_adjustments (id) on delete restrict,
  reversal_business_date date not null,
  reason text not null,
  -- Snapshot of the adjustment's financial state AT THE MOMENT OF REVERSAL
  -- (copied from the parent row, which is otherwise never mutated) — the
  -- historical ledger preserves both what the original effect was and what
  -- got reversed, independent of anything happening to the parent row
  -- later (it cannot happen again — unique constraint above — but the
  -- snapshot makes the ledger self-contained regardless).
  customer_charge_snapshot numeric(12, 2) not null,
  direct_cost_snapshot numeric(12, 2) not null,
  payment_fee_amount_snapshot numeric(12, 2) not null,
  gross_adjustment_profit_snapshot numeric(12, 2) not null,
  net_adjustment_profit_snapshot numeric(12, 2) not null,
  -- The adjustment's row_version at the moment of reversal — recorded for
  -- audit/debugging parity with the concurrency token actually checked by
  -- reverse_sales_order_adjustment() (0141); this table itself carries no
  -- row_version of its own (it is never updated after insert — enforced by
  -- the trigger below).
  expected_row_version bigint not null,
  reversed_by uuid references public.profiles (id) on delete set null,
  reversed_at timestamptz not null default now(),
  constraint sales_order_adjustment_reversals_reason_not_blank check (btrim(reason) <> '')
);

comment on table public.sales_order_adjustment_reversals is
  'Phase 6 (§19/§20) — append-only administrative reversal ledger. UNIQUE(sales_order_adjustment_id) enforces at most one effective reversal per adjustment at the DB level. NO UPDATE/DELETE, ever (trigger-enforced below). NOT a customer refund engine. No direct authenticated INSERT/SELECT — every write goes through reverse_sales_order_adjustment() (0141), every read through get/list_sales_order_adjustments() (0142), which derive the computed effective_status=''reversed'' from this table''s existence rather than the client inferring it.';

create index sales_order_adjustment_reversals_date_idx on public.sales_order_adjustment_reversals (reversal_business_date);

alter table public.sales_order_adjustment_reversals enable row level security;
-- Deliberately zero RLS policies for `authenticated`.

create or replace function public.reject_adjustment_reversal_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'سجلات عكس التعديلات/الخدمات للقراءة فقط بعد إنشائها — لا يمكن تعديلها أو حذفها' using errcode = 'P0001';
end;
$$;

create trigger sales_order_adjustment_reversals_reject_update
  before update on public.sales_order_adjustment_reversals
  for each row
  execute function public.reject_adjustment_reversal_mutation();

create trigger sales_order_adjustment_reversals_reject_delete
  before delete on public.sales_order_adjustment_reversals
  for each row
  execute function public.reject_adjustment_reversal_mutation();

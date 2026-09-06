-- ============================================================================
-- 0238: Phase 11 — Purchases & Suppliers Core (2/4): schema
-- ============================================================================
-- Migrations 0001-0237 are unmodified.
--
-- Four tables:
--   suppliers               GLOBAL master data (not store-scoped), with an
--                           active/disabled lifecycle and row_version
--                           optimistic concurrency — the shape of
--                           adjustment_types (0134) / expense_categories
--                           (0234).
--   purchase_invoices       STORE-SCOPED, business-date, APPEND-ONLY document
--                           ledger. Signed: an invoice is positive, its
--                           reversal negative.
--   purchase_invoice_lines  the goods on a document, one row per inventory
--                           item, each linked 1:1 to the inventory movement it
--                           produced.
--   supplier_payments       STORE-SCOPED, business-date, APPEND-ONLY payment
--                           ledger. Signed: a payment is positive, its
--                           reversal negative.
--
-- WHAT IS DERIVED, NEVER STORED
-- ---------------------------------------------------------------------------
-- There is no `amount_paid`, no `outstanding_balance` and no `status` column
-- anywhere. A supplier liability is always:
--     invoice.gross_total  -  sum(supplier_payments.amount for that invoice)
-- computed live at read time, exactly as inventory balances (0228) and expense
-- totals (0234) are. A cached total is precisely the thing that drifts from
-- its own ledger.
--
-- ACCOUNTING BOUNDARY (Phase 10 vs Phase 11)
-- ---------------------------------------------------------------------------
-- These tables are entirely separate from store_expenses (0234). A purchase is
-- the acquisition of an ASSET; an operating expense is consumption. Nothing
-- here writes store_expenses, and nothing in the expense reporting path reads
-- these tables, so a purchase can never reach net_operating_return or the
-- Phase 10 expense formulas. Acquisition cost recorded here is DOCUMENTARY
-- ONLY in Phase 11: no GL, no COGS, and the sales replacement-cost engine
-- (0074) is untouched.
--
-- Honest limitation, stated rather than papered over: nothing can stop a user
-- from ALSO typing the same supplier invoice into Phase 10 as a free-text
-- expense. That is human double entry, not a schema hole, and no structural
-- guarantee is claimed against it — the UI states the boundary explicitly and
-- the two reports stay disjoint.
-- ---------------------------------------------------------------------------
begin;

-- ---------------------------------------------------------------------------
-- suppliers — global catalogue.
-- ---------------------------------------------------------------------------
create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name_ar text not null,
  name_en text,
  vat_number text,
  contact_person text,
  phone text,
  email text,
  status text not null default 'active' check (status in ('active', 'disabled')),
  notes text,
  row_version bigint not null default 1,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

create unique index suppliers_code_lower_idx on public.suppliers (lower(code));
create index suppliers_status_idx on public.suppliers (status);

comment on table public.suppliers is
  'Phase 11 — global (never store-scoped) supplier catalogue. `code` is unique case-insensitively and permanent once created; a supplier is retired by setting status=''disabled'' (never deleted), so historical purchase documents keep resolving. Written exclusively through the SECURITY DEFINER RPCs in 0239.';

alter table public.suppliers enable row level security;

-- Layer-A: a narrow SELECT policy only. Zero direct-write policies — every
-- mutation goes through 0239's SECURITY DEFINER RPCs.
create policy suppliers_select on public.suppliers
  for select to authenticated
  using (public.has_permission('purchases.view'));

-- ---------------------------------------------------------------------------
-- purchase_invoices — append-only document ledger.
-- ---------------------------------------------------------------------------
create sequence public.purchase_number_seq as bigint start with 1 increment by 1 no cycle;

create or replace function public.generate_purchase_number()
returns text
language sql
as $$
  select 'PUR-' || lpad(nextval('public.purchase_number_seq')::text, 10, '0');
$$;

comment on function public.generate_purchase_number() is
  'Phase 11 — issues the next globally-unique, gap-tolerant, concurrency-safe internal purchase document number (format PUR-0000000001). SEQUENCE-based, so two concurrent postings can never collide. This is OUR document number; the SUPPLIER''s own invoice number is a separate, per-supplier-unique field. VOLATILE. Deliberately NOT granted to authenticated.';

revoke execute on function public.generate_purchase_number() from public;

create table public.purchase_invoices (
  id uuid primary key default gen_random_uuid(),
  purchase_number text not null unique,
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  store_id uuid not null references public.stores (id) on delete restrict,
  business_date date not null,
  entry_kind text not null check (entry_kind in ('invoice', 'reversal')),

  -- The SUPPLIER's own document identity, preserved as given.
  supplier_invoice_number text,
  supplier_invoice_date date,
  -- Historical-label contract (0224 lineage): renaming a supplier or changing
  -- its VAT registration must never rewrite what a historical purchase said.
  supplier_name_snapshot text not null,
  supplier_vat_number_snapshot text,

  -- Signed money. An invoice is positive; its reversal is the exact negation.
  -- gross = net + vat is enforced below; gross is what drives the liability.
  net_total numeric(14, 2) not null,
  vat_total numeric(14, 2) not null,
  gross_total numeric(14, 2) not null,

  notes text,
  reverses_invoice_id uuid references public.purchase_invoices (id) on delete restrict,
  reversal_reason text,
  closed_day_reason text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),

  constraint purchase_invoices_totals_consistent check (gross_total = net_total + vat_total),
  constraint purchase_invoices_invoice_shape check (
    entry_kind <> 'invoice'
    or (gross_total > 0 and reverses_invoice_id is null and reversal_reason is null)
  ),
  constraint purchase_invoices_reversal_shape check (
    entry_kind <> 'reversal'
    or (gross_total < 0 and reverses_invoice_id is not null and reversal_reason is not null)
  )
);

create index purchase_invoices_supplier_idx on public.purchase_invoices (supplier_id);
create index purchase_invoices_store_date_idx on public.purchase_invoices (store_id, business_date);
create index purchase_invoices_reverses_idx on public.purchase_invoices (reverses_invoice_id);

-- At most ONE reversal per invoice.
create unique index purchase_invoices_one_reversal_idx
  on public.purchase_invoices (reverses_invoice_id)
  where entry_kind = 'reversal';

-- The supplier's own invoice number is unique PER SUPPLIER, not globally: two
-- different suppliers may each legitimately issue an invoice numbered "001".
-- Scoped to real invoices (a reversal carries no new supplier document) and to
-- rows that actually supply one.
create unique index purchase_invoices_supplier_invoice_number_idx
  on public.purchase_invoices (supplier_id, lower(supplier_invoice_number))
  where entry_kind = 'invoice' and supplier_invoice_number is not null;

comment on table public.purchase_invoices is
  'Phase 11 — append-only purchase document ledger. There is no stored paid/outstanding/status column: a liability is always gross_total minus the sum of its linked supplier_payments, computed live. A correction is never an UPDATE or DELETE — it is a new entry_kind=''reversal'' document carrying the exact negation and its OWN business_date (§85 Event Date). Acquisition amounts are DOCUMENTARY ONLY in Phase 11: no GL, no COGS, and no effect on net_operating_return, Phase 10 expenses, or the sales replacement-cost engine.';

alter table public.purchase_invoices enable row level security;

-- ---------------------------------------------------------------------------
-- purchase_invoice_lines — the goods, and their 1:1 inventory link.
-- ---------------------------------------------------------------------------
create table public.purchase_invoice_lines (
  id uuid primary key default gen_random_uuid(),
  purchase_invoice_id uuid not null references public.purchase_invoices (id) on delete restrict,
  -- Denormalised from the parent so the RLS policy below is a direct
  -- store-scope test rather than a subquery over another RLS-protected table.
  store_id uuid not null references public.stores (id) on delete restrict,
  inventory_item_id uuid not null references public.inventory_items (id) on delete restrict,
  item_sku_snapshot text not null,
  item_name_snapshot text not null,

  -- Signed, matching the parent document. numeric(12,3) matches
  -- inventory_stock_movements.quantity_delta exactly (0228).
  quantity numeric(12, 3) not null check (quantity <> 0),
  -- Unit cost keeps 4 decimals like every other per-unit rate in this schema
  -- (gold_price_per_gram_snapshot, manufacturing_fee_per_gram_snapshot, 0059).
  unit_net_cost numeric(12, 4) not null check (unit_net_cost >= 0),

  -- Tax AS SUPPLIED. Phase 11 preserves the supplier's own treatment and makes
  -- no recoverability decision of any kind.
  tax_treatment text not null check (tax_treatment in ('standard', 'zero_rated', 'exempt', 'out_of_scope')),
  tax_rate_percent numeric(6, 3) not null check (tax_rate_percent >= 0),

  net_amount numeric(14, 2) not null,
  vat_amount numeric(14, 2) not null,
  gross_amount numeric(14, 2) not null,

  -- Exactly one inventory movement per line, and never shared. This is the
  -- structural guarantee against duplicate or partial stock posting.
  inventory_movement_id uuid not null unique references public.inventory_stock_movements (id) on delete restrict,

  created_at timestamptz not null default now(),

  constraint purchase_invoice_lines_amounts_consistent check (gross_amount = net_amount + vat_amount),
  -- A zero-rated / exempt / out-of-scope line cannot carry VAT, and a
  -- non-standard treatment cannot carry a rate. Standard-rated lines are left
  -- free: the supplier's stated rate is preserved as given, never recomputed.
  constraint purchase_invoice_lines_non_standard_no_vat check (
    tax_treatment = 'standard' or (vat_amount = 0 and tax_rate_percent = 0)
  )
);

create index purchase_invoice_lines_invoice_idx on public.purchase_invoice_lines (purchase_invoice_id);
create index purchase_invoice_lines_item_idx on public.purchase_invoice_lines (inventory_item_id);

comment on table public.purchase_invoice_lines is
  'Phase 11 — the goods on a purchase document. inventory_movement_id is NOT NULL and UNIQUE: every line produced exactly one inventory_stock_movements row (0228) through Phase 9''s own engine, and no movement can be claimed by two lines — the structural guard against duplicate or partial stock posting. Tax fields are stored exactly as the supplier supplied them; Phase 11 never decides recoverability.';

alter table public.purchase_invoice_lines enable row level security;

-- ---------------------------------------------------------------------------
-- supplier_payments — append-only payment ledger.
-- ---------------------------------------------------------------------------
create sequence public.supplier_payment_number_seq as bigint start with 1 increment by 1 no cycle;

create or replace function public.generate_supplier_payment_number()
returns text
language sql
as $$
  select 'SPY-' || lpad(nextval('public.supplier_payment_number_seq')::text, 10, '0');
$$;

comment on function public.generate_supplier_payment_number() is
  'Phase 11 — issues the next globally-unique, concurrency-safe supplier payment number (format SPY-0000000001). SEQUENCE-based. VOLATILE. Deliberately NOT granted to authenticated.';

revoke execute on function public.generate_supplier_payment_number() from public;

create table public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  payment_number text not null unique,
  purchase_invoice_id uuid not null references public.purchase_invoices (id) on delete restrict,
  supplier_id uuid not null references public.suppliers (id) on delete restrict,
  store_id uuid not null references public.stores (id) on delete restrict,
  business_date date not null,
  entry_kind text not null check (entry_kind in ('payment', 'reversal')),

  -- Signed: a payment is positive, its reversal the exact negation.
  amount numeric(14, 2) not null check (amount <> 0),

  -- The smallest evidence-backed manual-payment representation.
  --
  -- public.payment_methods is deliberately NOT reused here: that catalogue
  -- models INCOMING customer collection (it carries processor fee
  -- percentages, collection channels and settlement routes, 0045/0169), and
  -- attaching an outgoing supplier payment to it would import fee semantics
  -- that do not apply and would pollute settlement reporting. Phase 11 has no
  -- bank integration, so a constrained mode plus a free-text reference is the
  -- honest minimum.
  payment_mode text not null check (payment_mode in ('cash', 'bank_transfer', 'cheque', 'other')),
  payment_reference text,

  notes text,
  reverses_payment_id uuid references public.supplier_payments (id) on delete restrict,
  reversal_reason text,
  closed_day_reason text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),

  constraint supplier_payments_payment_shape check (
    entry_kind <> 'payment'
    or (amount > 0 and reverses_payment_id is null and reversal_reason is null)
  ),
  constraint supplier_payments_reversal_shape check (
    entry_kind <> 'reversal'
    or (amount < 0 and reverses_payment_id is not null and reversal_reason is not null)
  )
);

create index supplier_payments_invoice_idx on public.supplier_payments (purchase_invoice_id);
create index supplier_payments_supplier_date_idx on public.supplier_payments (supplier_id, business_date);
create index supplier_payments_store_idx on public.supplier_payments (store_id);

-- At most ONE reversal per payment.
create unique index supplier_payments_one_reversal_idx
  on public.supplier_payments (reverses_payment_id)
  where entry_kind = 'reversal';

comment on table public.supplier_payments is
  'Phase 11 — append-only supplier payment ledger, signed so a reversal nets its original out automatically. Payments may be partial. The amount still outstanding on an invoice is always its gross_total minus sum(amount) here — never a cached column. Correction is by dated reversal only; an invoice cannot be reversed while any unreversed payment remains linked to it (enforced in 0239).';

alter table public.supplier_payments enable row level security;

-- ---------------------------------------------------------------------------
-- Append-only enforcement, at table level, for all three ledgers.
-- ---------------------------------------------------------------------------
create or replace function public.reject_purchase_document_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'سجلات المشتريات والمدفوعات إضافية فقط — لا يمكن تعديل أو حذف مستند مُرحَّل؛ استخدم مستند العكس المؤرَّخ'
    using errcode = 'P0001';
end;
$$;

comment on function public.reject_purchase_document_mutation() is
  'Phase 11 — makes purchase_invoices / purchase_invoice_lines / supplier_payments INSERT-only at the database level: any UPDATE or DELETE is rejected outright, no matter who attempts it or how (including a role that bypasses RLS). Mirrors reject_store_expense_mutation() (0234) and reject_inventory_stock_movement_mutation() (0228).';

create trigger purchase_invoices_reject_update
  before update on public.purchase_invoices
  for each row execute function public.reject_purchase_document_mutation();
create trigger purchase_invoices_reject_delete
  before delete on public.purchase_invoices
  for each row execute function public.reject_purchase_document_mutation();

create trigger purchase_invoice_lines_reject_update
  before update on public.purchase_invoice_lines
  for each row execute function public.reject_purchase_document_mutation();
create trigger purchase_invoice_lines_reject_delete
  before delete on public.purchase_invoice_lines
  for each row execute function public.reject_purchase_document_mutation();

create trigger supplier_payments_reject_update
  before update on public.supplier_payments
  for each row execute function public.reject_purchase_document_mutation();
create trigger supplier_payments_reject_delete
  before delete on public.supplier_payments
  for each row execute function public.reject_purchase_document_mutation();

-- ---------------------------------------------------------------------------
-- Layer-A SELECT policies, store-scoped through the SELF-scoped wrapper.
-- ---------------------------------------------------------------------------
-- my_visible_store_ids() (0017), NOT user_visible_store_ids(uuid) — the latter
-- is deliberately service_role-only, so referencing it inside a policy
-- evaluated as `authenticated` aborts every direct SELECT with "permission
-- denied for function". That exact mistake shipped in 0228 and had to be fixed
-- in 0231; these policies are written correctly from the start.
create policy purchase_invoices_select on public.purchase_invoices
  for select to authenticated
  using (
    public.has_permission('purchases.view')
    and store_id in (select public.my_visible_store_ids())
  );

create policy purchase_invoice_lines_select on public.purchase_invoice_lines
  for select to authenticated
  using (
    public.has_permission('purchases.view')
    and store_id in (select public.my_visible_store_ids())
  );

create policy supplier_payments_select on public.supplier_payments
  for select to authenticated
  using (
    public.has_permission('purchases.view')
    and store_id in (select public.my_visible_store_ids())
  );

commit;

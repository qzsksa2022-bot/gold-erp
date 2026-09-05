-- ============================================================================
-- 0234: Phase 10 — Store Expenses Core (2/4): schema
-- ============================================================================
-- Migrations 0001-0233 are unmodified.
--
-- Two tables:
--   expense_categories — GLOBAL master data (not store-scoped): the list of
--     expense kinds an operator may choose from, with an active/inactive
--     lifecycle and row_version optimistic concurrency, byte-for-byte the
--     shape of adjustment_types (0134).
--   store_expenses     — the STORE-SCOPED, business-date-based, APPEND-ONLY
--     financial ledger. There is no stored "total" column anywhere: the total
--     for any (store, period) is always SUM(amount), computed live, exactly
--     mirroring inventory_stock_movements (0228) and
--     settlement_bank_movement_events (0174).
--
-- The signed-amount ledger (why one table, not two)
-- ---------------------------------------------------------------------------
-- A correction is never an UPDATE and never a DELETE — it is a NEW row with
-- entry_kind='reversal', a NEGATIVE amount, and its OWN business_date. That
-- is the §85 Event Date contract every other domain already follows: the undo
-- lands on the day it actually happened, not on the day of the original
-- entry, so a closed period's reported figure never silently changes after
-- the fact.
--
-- Keeping both kinds in ONE signed ledger (rather than an events table plus a
-- reversals table, as Settlements does) is the Inventory shape (0228), and it
-- is chosen here for the same reason: the period total is then literally
-- SUM(amount) with no join and no second aggregate to keep consistent, and a
-- reversal automatically nets its original out of every period that contains
-- both.
-- ---------------------------------------------------------------------------
begin;

-- ---------------------------------------------------------------------------
-- expense_categories — global catalog.
-- ---------------------------------------------------------------------------
create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name_ar text not null,
  name_en text,
  status text not null default 'active' check (status in ('active', 'disabled')),
  notes text,
  row_version bigint not null default 1,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);

-- Case-insensitive uniqueness, mirroring adjustment_types/inventory_items.
create unique index expense_categories_code_lower_idx on public.expense_categories (lower(code));
create index expense_categories_status_idx on public.expense_categories (status);

comment on table public.expense_categories is
  'Phase 10 — global (never store-scoped) catalog of operating-expense kinds. `code` is unique case-insensitively and permanent once created; a category is retired by setting status=''disabled'' (never deleted), so historical store_expenses rows keep resolving their category label forever. Written exclusively through the SECURITY DEFINER RPCs in 0235.';

alter table public.expense_categories enable row level security;

-- Layer-A: a narrow SELECT policy only. Zero direct-write policies — every
-- mutation goes through 0235's SECURITY DEFINER RPCs, so the base table is
-- unreachable via a raw .insert()/.update()/.delete() regardless of
-- permission (mirrors adjustment_types/inventory_items exactly).
create policy expense_categories_select on public.expense_categories
  for select to authenticated
  using (public.has_permission('expenses.view'));

-- ---------------------------------------------------------------------------
-- store_expenses — append-only, store-scoped, business-date ledger.
-- ---------------------------------------------------------------------------
create sequence public.expense_number_seq as bigint start with 1 increment by 1 no cycle;

create or replace function public.generate_expense_number()
returns text
language sql
as $$
  select 'EXP-' || lpad(nextval('public.expense_number_seq')::text, 10, '0');
$$;

comment on function public.generate_expense_number() is
  'Phase 10 — issues the next globally-unique, gap-tolerant, concurrency-safe expense number (format EXP-0000000001). SEQUENCE-based, so two concurrent recordings can never collide (unlike a MAX()+1 read). VOLATILE. Deliberately NOT granted to `authenticated` — only record_store_expense()/reverse_store_expense() (0235), themselves SECURITY DEFINER, call this.';

revoke execute on function public.generate_expense_number() from public;

create table public.store_expenses (
  id uuid primary key default gen_random_uuid(),
  expense_number text not null unique,
  store_id uuid not null references public.stores (id) on delete restrict,
  expense_category_id uuid not null references public.expense_categories (id) on delete restrict,
  business_date date not null,
  entry_kind text not null check (entry_kind in ('expense', 'reversal')),
  -- Signed: an expense is strictly positive, a reversal strictly negative.
  -- numeric(14, 2) matches every other money column in this schema; `<> 0` is
  -- belt-and-braces alongside the per-kind sign checks below.
  amount numeric(14, 2) not null check (amount <> 0),
  description text,
  -- Reversal-only linkage back to the entry being undone.
  reverses_expense_id uuid references public.store_expenses (id) on delete restrict,
  reversal_reason text,
  -- Set only when the entry was posted into an already-closed business day,
  -- which requires expenses.process_closed_day plus an explicit reason.
  closed_day_reason text,
  -- Category label snapshot (§ historical-label contract, 0224 lineage):
  -- renaming a category must never rewrite what a historical expense was
  -- booked as.
  category_code_snapshot text not null,
  category_name_ar_snapshot text not null,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),

  constraint store_expenses_expense_shape check (
    entry_kind <> 'expense'
    or (amount > 0 and reverses_expense_id is null and reversal_reason is null)
  ),
  constraint store_expenses_reversal_shape check (
    entry_kind <> 'reversal'
    or (amount < 0 and reverses_expense_id is not null and reversal_reason is not null)
  )
);

create index store_expenses_store_date_idx on public.store_expenses (store_id, business_date);
create index store_expenses_category_idx on public.store_expenses (expense_category_id);
create index store_expenses_created_at_idx on public.store_expenses (created_at desc);

-- THE mutual-exclusion invariant of this phase: an expense may be reversed AT
-- MOST ONCE. Enforced as a partial UNIQUE index rather than an application
-- check, so it holds even against a future caller that forgets to lock —
-- exactly the settlement_bank_movement_reversals shape (0174). This is what
-- the concurrency test proves under two genuinely racing sessions.
create unique index store_expenses_one_reversal_per_expense_idx
  on public.store_expenses (reverses_expense_id)
  where entry_kind = 'reversal';

comment on table public.store_expenses is
  'Phase 10 — append-only, store-scoped operating-expense ledger. There is no stored total anywhere: the total for a (store, period) is always sum(amount), computed live (mirrors inventory_stock_movements 0228 / settlement_bank_movement_events 0174). A correction is never an UPDATE or DELETE — it is a new entry_kind=''reversal'' row carrying a NEGATIVE amount and its OWN business_date (§85 Event Date), so a closed period''s reported figure never changes retroactively. INSERT-only forever — the two reject-mutation triggers below make this a DB-level guarantee, not a convention.';

alter table public.store_expenses enable row level security;

-- Append-only enforcement at table level.
create or replace function public.reject_store_expense_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'دفتر مصروفات الفروع سجل إضافي فقط — لا يمكن تعديل أو حذف حركة مسجَّلة؛ استخدم reverse_store_expense() لتسجيل حركة عكس مؤرَّخة'
    using errcode = 'P0001';
end;
$$;

comment on function public.reject_store_expense_mutation() is
  'Phase 10 — makes public.store_expenses INSERT-only at the database level: any UPDATE or DELETE is rejected outright, no matter who attempts it or how. Mirrors reject_inventory_stock_movement_mutation() (0228).';

create trigger store_expenses_reject_update
  before update on public.store_expenses
  for each row execute function public.reject_store_expense_mutation();

create trigger store_expenses_reject_delete
  before delete on public.store_expenses
  for each row execute function public.reject_store_expense_mutation();

-- Layer-A: narrow SELECT policy gated on expenses.view AND store visibility.
--
-- my_visible_store_ids() (0017), NOT user_visible_store_ids(uuid) — the
-- latter is deliberately service_role-only, so referencing it inside a policy
-- evaluated as `authenticated` aborts every direct SELECT with "permission
-- denied for function". That exact mistake shipped in 0228 and had to be
-- fixed in 0231; this policy is written correctly from the start.
create policy store_expenses_select on public.store_expenses
  for select to authenticated
  using (
    public.has_permission('expenses.view')
    and store_id in (select public.my_visible_store_ids())
  );

commit;

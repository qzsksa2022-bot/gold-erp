-- ============================================================================
-- 0044: payment_methods — Phase 2, module 5/6 (part 1: methods)
-- ============================================================================
-- Payment Method is deliberately its own table, separate from Collection
-- Channel (0046) — spec §6: "يجب الفصل تمامًا... ولا تدمجهما في عمود
-- واحد". A sale will later record BOTH independently (e.g. "Mada – Salla
-- Wallet" vs "Mada – Direct"), so merging them now would make that
-- combination unrepresentable later without a schema change.
--
-- The commission/fee percentage/amount is NOT a column here — it lives in
-- payment_method_fee_versions (0045), versioned exactly like manufacturing
-- fees. `fee_model` below only records the SHAPE a fee version for this
-- method is expected to take (percentage / fixed / both / none); it does
-- not itself carry a rate.
--
-- refund_fee_policy is configuration data for a future Returns/Refund
-- engine (spec §8) — NOT built in this phase. Storing it as an enum column
-- here (rather than inventing it later) is exactly what avoids a future
-- `if (paymentMethod.key === 'tabby')` special case in business logic: the
-- refund engine, whenever it is built, reads this column instead.
create table public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  name_ar text not null,
  name_en text,
  fee_model text not null default 'percentage'
    check (fee_model in ('percentage', 'fixed', 'percentage_plus_fixed', 'none')),
  status text not null default 'active' check (status in ('active', 'inactive')),
  supports_refunds boolean not null default true,
  -- full_reversal          — a full refund reverses 100% of the fee charged
  --                           on the original sale (spec §8: Tabby/Tamara).
  -- proportional_reversal  — a partial refund reverses the fee proportional
  --                           to the returned amount (spec §8: Tabby/Tamara
  --                           partial refunds).
  -- non_refundable_fee     — the fee is never reversed regardless of refund.
  -- manual                 — no fixed rule; a human decides case-by-case /
  --                           provider-specific (fallback for anything not
  --                           yet modeled). No refund engine reads this in
  --                           this phase; it is configuration only.
  refund_fee_policy text not null default 'manual'
    check (refund_fee_policy in ('full_reversal', 'proportional_reversal', 'non_refundable_fee', 'manual')),
  sort_order integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.payment_methods is
  'Payment methods (Cash, Mada, Visa, Tabby, Tamara, Bank Transfer, COD, ...). Deliberately separate from collection_channels (0046) — a sale records both independently. Fee RATES live in payment_method_fee_versions (0045), not here; fee_model only describes the shape a version is expected to take.';

create unique index payment_methods_key_lower_idx on public.payment_methods (lower(key));
create index payment_methods_status_idx on public.payment_methods (status);
create index payment_methods_sort_order_idx on public.payment_methods (sort_order);

create trigger payment_methods_set_updated_at
  before update on public.payment_methods
  for each row
  execute function public.set_updated_at();

alter table public.payment_methods enable row level security;

create policy payment_methods_select on public.payment_methods
  for select to authenticated
  using (public.has_permission('payment_methods.view'));

create policy payment_methods_insert on public.payment_methods
  for insert to authenticated
  with check (public.has_permission('payment_methods.manage'));

create policy payment_methods_update on public.payment_methods
  for update to authenticated
  using (public.has_permission('payment_methods.manage'))
  with check (public.has_permission('payment_methods.manage'));

-- No DELETE policy — disable instead.

create trigger payment_methods_audit_trigger
  after insert or update or delete on public.payment_methods
  for each row execute function public.audit_table_changes('payment_method', 'id');

-- ============================================================================
-- 0040: karats — Phase 2 (Financial Master Data), module 1/6
-- ============================================================================
-- Phase 2 begins here. Foundation (0001-0039) is closed and NOT modified by
-- this or any following migration in this phase. Every rule enforced below
-- follows the same defense-in-depth pattern already established: RLS gates
-- SELECT/INSERT/UPDATE by permission, there is deliberately NO DELETE
-- policy for `authenticated` (financial reference data is never hard
-- deleted — see spec §1/§2), and every mutation is covered by the existing
-- generic audit trigger (audit_table_changes(), 0016) so nothing new needs
-- inventing there.
--
-- karats are NOT hardcoded anywhere in business logic — this table is the
-- single source of truth for which purities the business trades in. 18/21/
-- 22/24 are seeded as ordinary editable rows (see supabase/seed.sql), not
-- as constants baked into the schema or application code. An Admin can add
-- a new karat (e.g. a future 9K/14K line) without any code change.
create table public.karats (
  id uuid primary key default gen_random_uuid(),
  -- Short display code, e.g. '18', '21', '22', '24'. Free text (not an
  -- integer column) so it can represent non-numeric future purity labels
  -- (e.g. a hallmark string) without a schema change.
  code text not null unique,
  -- Optional numeric purity identifier (parts per mille, e.g. 21K = 875.000
  -- = 21/24 * 1000). Nullable/advisory only — nothing in this phase reads
  -- it for calculation (the gold-price formula in §11 of the spec looks up
  -- a per-karat price directly, it does not derive one karat's price from
  -- another's via this ratio) — it exists purely as informative metadata
  -- for future display/conversion needs, so it is never a silent source of
  -- truth for money math.
  purity_per_mille numeric(6, 3),
  name_ar text not null,
  name_en text,
  sort_order integer not null default 0,
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.karats is
  'Gold purity/karat catalog. Editable master data, not hardcoded constants. Never hard-deleted (status=inactive instead) once historical prices/fees may reference a row — see daily_gold_prices/manufacturing_fee_versions FKs (on delete restrict).';

-- Prevent duplicate karats (case-insensitive, matches the stores.code
-- precedent from 0005).
create unique index karats_code_lower_idx on public.karats (lower(code));
create index karats_status_idx on public.karats (status);
create index karats_sort_order_idx on public.karats (sort_order);

create trigger karats_set_updated_at
  before update on public.karats
  for each row
  execute function public.set_updated_at();

alter table public.karats enable row level security;

create policy karats_select on public.karats
  for select to authenticated
  using (public.has_permission('karats.view'));

create policy karats_insert on public.karats
  for insert to authenticated
  with check (public.has_permission('karats.manage'));

create policy karats_update on public.karats
  for update to authenticated
  using (public.has_permission('karats.manage'))
  with check (public.has_permission('karats.manage'));

-- No DELETE policy: karats are reference data that may already be pointed
-- to by daily_gold_prices/manufacturing_fee_versions rows; disable instead
-- (spec §1: "لا حذف فعلي لبيانات Master Data التي استُخدمت تاريخيًا").

create trigger karats_audit_trigger
  after insert or update or delete on public.karats
  for each row execute function public.audit_table_changes('karat', 'id');

-- ---------------------------------------------------------------------------
-- Query surface for later phases (spec §16): "current active karats".
-- Plain SECURITY INVOKER function — no privilege escalation needed, RLS on
-- the underlying table already governs who may call this (karats.view).
-- ---------------------------------------------------------------------------
create or replace function public.active_karats()
returns setof public.karats
language sql
stable
as $$
  select * from public.karats
  where status = 'active'
  order by sort_order, code;
$$;

comment on function public.active_karats() is
  'Active karats ordered for display/select inputs. SECURITY INVOKER (default) — relies on the caller already holding karats.view via RLS, same as a plain SELECT would.';

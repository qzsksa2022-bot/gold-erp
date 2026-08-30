-- ============================================================================
-- 0046: collection_channels — Phase 2, module 6/6
-- ============================================================================
-- Independent from payment_methods on purpose (spec §9) — a sale will later
-- record a payment method AND a collection channel as two separate facts
-- ("Mada – Salla Wallet", "Visa – Salla Wallet", "Mada – Direct"), so this
-- must never become a column/enum bolted onto payment_methods. metadata
-- jsonb leaves room for a future channel-specific config (e.g. a Salla API
-- key reference) without a schema change — no Salla integration is built or
-- called in this phase.
create table public.collection_channels (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  name_ar text not null,
  name_en text,
  status text not null default 'active' check (status in ('active', 'inactive')),
  sort_order integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.collection_channels is
  'Collection channels (Direct/Store, Salla Wallet, ...) — deliberately independent from payment_methods (0044); a future sale records both. metadata is reserved for channel-specific config (e.g. a future Salla integration) — unused/unread in this phase.';

create unique index collection_channels_key_lower_idx on public.collection_channels (lower(key));
create index collection_channels_status_idx on public.collection_channels (status);
create index collection_channels_sort_order_idx on public.collection_channels (sort_order);

create trigger collection_channels_set_updated_at
  before update on public.collection_channels
  for each row
  execute function public.set_updated_at();

alter table public.collection_channels enable row level security;

create policy collection_channels_select on public.collection_channels
  for select to authenticated
  using (public.has_permission('collection_channels.view'));

create policy collection_channels_insert on public.collection_channels
  for insert to authenticated
  with check (public.has_permission('collection_channels.manage'));

create policy collection_channels_update on public.collection_channels
  for update to authenticated
  using (public.has_permission('collection_channels.manage'))
  with check (public.has_permission('collection_channels.manage'));

-- No DELETE policy — disable instead.

create trigger collection_channels_audit_trigger
  after insert or update or delete on public.collection_channels
  for each row execute function public.audit_table_changes('collection_channel', 'id');

-- ---------------------------------------------------------------------------
-- Query surface for later phases (spec §16): "active collection channels".
-- ---------------------------------------------------------------------------
create or replace function public.active_collection_channels()
returns setof public.collection_channels
language sql
stable
as $$
  select * from public.collection_channels
  where status = 'active'
  order by sort_order, name_ar;
$$;

comment on function public.active_collection_channels() is
  'Active collection channels for select inputs. SECURITY INVOKER — relies on the caller holding collection_channels.view via RLS.';

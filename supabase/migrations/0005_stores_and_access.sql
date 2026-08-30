-- ============================================================================
-- 0005: stores, user_store_access, and profile store-scoping columns
-- ============================================================================
create table public.stores (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name_ar text not null,
  name_en text,
  status text not null default 'active' check (status in ('active', 'disabled')),
  logo_url text,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.stores is
  'Store branches. Never hard-deleted (status=disabled instead) once historical data may reference them.';

create index stores_status_idx on public.stores (status);
create unique index stores_code_lower_idx on public.stores (lower(code));

create trigger stores_set_updated_at
  before update on public.stores
  for each row
  execute function public.set_updated_at();

-- Now that stores exists, add the store-scoping columns to profiles.
-- store_access_scope:
--   'all'      -> user can see/act on every store (typical for HQ roles).
--   'multiple' -> user is restricted to the stores listed in user_store_access.
--   'single'   -> user is restricted to exactly one store: default_store_id.
-- This is foundation for future modules (Sales, Reports, ...): row-level
-- store scoping will filter through public.user_accessible_store_ids().
alter table public.profiles
  add column store_access_scope text not null default 'single'
    check (store_access_scope in ('all', 'multiple', 'single')),
  add column default_store_id uuid references public.stores (id) on delete set null;

create index profiles_default_store_idx on public.profiles (default_store_id);

-- Explicit store grants, used when store_access_scope in ('single','multiple').
create table public.user_store_access (
  user_id uuid not null references public.profiles (id) on delete cascade,
  store_id uuid not null references public.stores (id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  primary key (user_id, store_id)
);

comment on table public.user_store_access is
  'Explicit per-user store grants used when store_access_scope is single/multiple.';

create index user_store_access_store_idx on public.user_store_access (store_id);

alter table public.stores enable row level security;
alter table public.user_store_access enable row level security;

-- ============================================================================
-- 0007: system_settings
-- ============================================================================
-- Generic key/value settings store, grouped by category, value as jsonb so
-- new settings can be added later without further schema migrations.
create table public.system_settings (
  id uuid primary key default gen_random_uuid(),
  category text not null,
  key text not null,
  value jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null,
  unique (category, key)
);

comment on table public.system_settings is
  'Tenant-wide configuration (branding, locale, security placeholders...), grouped by category.';

create index system_settings_category_idx on public.system_settings (category);

create trigger system_settings_set_updated_at
  before update on public.system_settings
  for each row
  execute function public.set_updated_at();

alter table public.system_settings enable row level security;

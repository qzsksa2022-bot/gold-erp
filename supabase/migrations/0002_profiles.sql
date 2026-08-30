-- ============================================================================
-- 0002: profiles
-- ============================================================================
-- One row per auth.users row. We keep it 1:1 with auth.users(id) so that
-- `profiles.id = auth.uid()` can be used everywhere (RLS policies, joins)
-- without an extra lookup table.
--
-- Design decisions:
--  * `email` and `full_name` are denormalized copies. The source of truth
--    for email/credentials remains Supabase Auth (auth.users); we mirror the
--    email here purely so RLS-scoped queries (profiles, audit log joins,
--    "created by" columns) can read it without a service-role call into the
--    auth schema. Kept in sync by the server action that creates/updates a
--    user (src/features/users/actions.ts).
--  * `last_sign_in_at` is intentionally NOT stored here — it is derivable
--    from auth.users.last_sign_in_at and is fetched on-demand via the
--    service-role admin client when an authorized admin views the users
--    list. Storing it here would just be a stale duplicate.
--  * status/store_access_scope use text + CHECK instead of native Postgres
--    ENUM types: adding a new allowed value later is a simple constraint
--    migration instead of an ALTER TYPE (which has historically had
--    transactional limitations in Postgres).
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  email text not null,
  status text not null default 'active' check (status in ('active', 'suspended')),
  -- store_access_scope / default_store_id are added in 0005 once the
  -- `stores` table exists (avoids a circular forward reference).
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.profiles is
  'Application user profile, 1:1 with auth.users. Source of truth for authorization state.';
comment on column public.profiles.email is
  'Denormalized copy of auth.users.email, kept in sync by user management actions.';

create index profiles_status_idx on public.profiles (status);
create unique index profiles_email_idx on public.profiles (lower(email));

alter table public.profiles enable row level security;

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row
  execute function public.set_updated_at();

-- ============================================================================
-- 0003: permissions, roles, role_permissions
-- ============================================================================
-- permissions: the fixed catalog of granular capability keys (e.g.
-- 'stores.create'). This table is a code-managed catalog — extended only via
-- migrations, never edited through the UI — so every permission check in the
-- app can rely on a stable, reviewable list.
create table public.permissions (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  category text not null,
  description_ar text not null,
  description_en text,
  created_at timestamptz not null default now()
);

comment on table public.permissions is
  'Fixed catalog of granular permission keys. Extended via migrations only.';

create index permissions_category_idx on public.permissions (category);

-- roles: named, manageable bundles of permissions. Roles are data (rows),
-- not hardcoded strings — new roles can be created from the UI. `is_system`
-- protects the seeded default roles (esp. super_admin) from deletion/rename.
create table public.roles (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  name_ar text not null,
  name_en text,
  description_ar text,
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null
);

comment on table public.roles is
  'Manageable roles (bundles of permissions). is_system=true rows are seeded defaults and cannot be deleted.';

create trigger roles_set_updated_at
  before update on public.roles
  for each row
  execute function public.set_updated_at();

-- role_permissions: many-to-many join between roles and permissions.
create table public.role_permissions (
  role_id uuid not null references public.roles (id) on delete cascade,
  permission_id uuid not null references public.permissions (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (role_id, permission_id)
);

create index role_permissions_permission_idx on public.role_permissions (permission_id);

alter table public.permissions enable row level security;
alter table public.roles enable row level security;
alter table public.role_permissions enable row level security;

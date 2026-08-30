-- ============================================================================
-- 0004: user_roles, user_permission_overrides
-- ============================================================================
-- A user can hold one or more roles (architecture supports multiple even
-- though the UI currently assigns a single primary role per user).
create table public.user_roles (
  user_id uuid not null references public.profiles (id) on delete cascade,
  role_id uuid not null references public.roles (id) on delete restrict,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  primary key (user_id, role_id)
);

comment on table public.user_roles is
  'Assigns roles to users (many-to-many). ON DELETE RESTRICT on role_id prevents deleting a role that is still assigned.';

create index user_roles_role_idx on public.user_roles (role_id);

-- Per-user permission overrides layered on top of role-derived permissions.
-- effect='grant'  -> add this permission even if no role grants it.
-- effect='revoke' -> remove this permission even if a role grants it.
-- A (user_id, permission_id) pair can only have ONE row, so a permission can
-- never be simultaneously granted and revoked for the same user (no
-- ambiguity). Precedence is resolved in get_user_permissions(): revoke
-- always wins over role-grants and over an explicit grant of the same key
-- is impossible by construction (single row per pair).
create table public.user_permission_overrides (
  user_id uuid not null references public.profiles (id) on delete cascade,
  permission_id uuid not null references public.permissions (id) on delete cascade,
  effect text not null check (effect in ('grant', 'revoke')),
  reason text,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  primary key (user_id, permission_id)
);

comment on table public.user_permission_overrides is
  'Per-user permission grant/revoke overrides layered on top of role permissions.';

create index user_permission_overrides_permission_idx on public.user_permission_overrides (permission_id);

alter table public.user_roles enable row level security;
alter table public.user_permission_overrides enable row level security;

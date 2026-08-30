-- ============================================================================
-- 0006: audit_logs
-- ============================================================================
-- Append-only log of administrative/security-relevant events. On purpose
-- there is NO insert/update/delete RLS policy granted to the `authenticated`
-- role for this table (see 0009_rls_policies.sql) — every row is written by
-- the trusted SECURITY DEFINER function public.log_audit_event() (0008),
-- which stamps user_id from auth.uid() itself. This means no client, not
-- even an admin, can forge, edit, or delete an audit entry through the API.
create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles (id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  old_values jsonb,
  new_values jsonb,
  reason text,
  ip_address inet,
  user_agent text,
  created_at timestamptz not null default now()
);

comment on table public.audit_logs is
  'Append-only audit trail. Writable only via public.log_audit_event(); no UPDATE/DELETE policy exists for any role.';

create index audit_logs_user_idx on public.audit_logs (user_id);
create index audit_logs_entity_idx on public.audit_logs (entity_type, entity_id);
create index audit_logs_action_idx on public.audit_logs (action);
create index audit_logs_created_at_idx on public.audit_logs (created_at desc);

alter table public.audit_logs enable row level security;

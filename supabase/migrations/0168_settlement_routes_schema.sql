-- ============================================================================
-- 0168: Phase 7 — Settlements Core (2/N): settlement_routes schema + RLS +
-- hardening
-- ============================================================================
-- Migrations 0001-0167 are unmodified.
--
-- settlement_routes answers "من أين تأتي هذه التسوية؟" (item 10) — one of
-- two kinds:
--   payment_collection — payment_method_id REQUIRED, shipping_carrier_id
--     NULL. collection_channel_id is OPTIONAL: NULL means "match this
--     payment method regardless of channel"; set means "match this exact
--     (payment_method_id, collection_channel_id) pair only" (item 36).
--   cod_carrier — shipping_carrier_id REQUIRED, payment_method_id and
--     collection_channel_id both NULL (COD carrier remittance is matched
--     purely on carrier, never on a payment method/channel — item 9).
--
-- No Brand-specific enum anywhere (item 10) — route_kind is exactly the two
-- generic values above, and which payment method/channel/carrier a route
-- targets is pure Master Data, never hardcoded business logic.
--
-- Hardening follows the SAME rigor as adjustment_types (0134/0153), with
-- ONE deliberate improvement applied from day one rather than needing a
-- later hotfix: the updated_by anti-forgery trigger below is written using
-- the CORRECTED pattern Hotfix 6.1.2 (0164) had to retrofit onto
-- adjustment_types — auth.uid() must identify a REAL public.profiles row,
-- or updated_by is pinned to OLD.updated_by; a trusted/direct write can
-- never forge attribution, from the very first migration that creates this
-- table.
--
-- RPC-only writes (mirrors adjustment_types 0134 exactly, NOT payment_
-- methods' direct-RLS-UPDATE pattern) — item 41 groups "route fee versions"
-- explicitly under RPC-only tables, and this migration extends the same
-- posture to settlement_routes itself for a consistent, single write
-- surface across both Settlement Master Data tables. Only a SELECT policy
-- exists; create/update/disable/enable go through 0169's SECURITY DEFINER
-- RPCs alone.
-- ---------------------------------------------------------------------------
create table public.settlement_routes (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  name_ar text not null,
  name_en text,
  route_kind text not null check (route_kind in ('payment_collection', 'cod_carrier')),
  payment_method_id uuid references public.payment_methods (id) on delete restrict,
  collection_channel_id uuid references public.collection_channels (id) on delete restrict,
  shipping_carrier_id uuid references public.shipping_carriers (id) on delete restrict,
  status text not null default 'active' check (status in ('active', 'disabled')),
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  constraint settlement_routes_kind_fields_consistent check (
    (route_kind = 'payment_collection' and payment_method_id is not null and shipping_carrier_id is null)
    or
    (route_kind = 'cod_carrier' and shipping_carrier_id is not null and payment_method_id is null and collection_channel_id is null)
  )
);

comment on table public.settlement_routes is
  'Phase 7 (item 10) — Settlement Route Master Data: "where does this settlement come from?". payment_collection routes match on payment_method_id (+ optional collection_channel_id); cod_carrier routes match on shipping_carrier_id alone. code is permanent once set (0168 trigger below). No hard delete, ever — disable instead. RPC-only writes (create/update/disable/enable_settlement_route, 0169); the sole RLS policy is SELECT.';

create unique index settlement_routes_code_lower_idx on public.settlement_routes (lower(code));
create index settlement_routes_status_idx on public.settlement_routes (status);
create index settlement_routes_kind_idx on public.settlement_routes (route_kind);

-- Deterministic route matching (item 36) — at most one ACTIVE route may
-- claim a given matching key, so Finalization never faces an ambiguous
-- match. A disabled route never blocks a replacement (item 37 — historical
-- labels stay visible, but only an active route may match NEW sources).
create unique index settlement_routes_payment_collection_match_idx
  on public.settlement_routes (payment_method_id, coalesce(collection_channel_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where route_kind = 'payment_collection' and status = 'active';

create unique index settlement_routes_cod_carrier_match_idx
  on public.settlement_routes (shipping_carrier_id)
  where route_kind = 'cod_carrier' and status = 'active';

alter table public.settlement_routes enable row level security;

create policy settlement_routes_select on public.settlement_routes
  for select to authenticated
  using (public.has_permission('settlements.view'));

comment on policy settlement_routes_select on public.settlement_routes is
  'Phase 7 — settlements.view alone (the base module-visibility permission) sees the full route catalog, including disabled routes (historically visible, item 37) — route names/kinds carry no money figure themselves.';

-- ---------------------------------------------------------------------------
-- Identity immutability + no-delete (mirrors adjustment_types_reject_
-- identity_mutation/_reject_delete, 0153, exactly).
-- ---------------------------------------------------------------------------
create or replace function public.settlement_routes_reject_identity_mutation()
returns trigger
language plpgsql
as $$
begin
  if new.code is distinct from old.code then
    raise exception 'رمز مسار التسوية ثابت ولا يمكن تغييره بعد الإنشاء' using errcode = 'P0001';
  end if;
  if new.created_at is distinct from old.created_at then
    raise exception 'تاريخ إنشاء مسار التسوية غير قابل للتعديل' using errcode = 'P0001';
  end if;
  if new.created_by is distinct from old.created_by then
    raise exception 'مُنشئ مسار التسوية غير قابل للتعديل' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger settlement_routes_reject_identity_mutation
  before update on public.settlement_routes
  for each row
  execute function public.settlement_routes_reject_identity_mutation();

create or replace function public.settlement_routes_reject_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'مسارات التسوية لا تُحذف أبدًا — عطّلها بدلًا من ذلك (disable_settlement_route)' using errcode = 'P0001';
end;
$$;

create trigger settlement_routes_reject_delete
  before delete on public.settlement_routes
  for each row
  execute function public.settlement_routes_reject_delete();

-- ---------------------------------------------------------------------------
-- updated_by anti-forgery — CORRECTED pattern from day one (the fix Hotfix
-- 6.1.2/0164 had to retrofit onto adjustment_types). A real, existing
-- profiles row for auth.uid() ⇒ pinned to that real actor; otherwise
-- (auth.uid() null OR not a valid Actor Profile — service_role/direct-SQL/
-- maintenance) ⇒ forced to OLD.updated_by, never a statement-supplied
-- value. See supabase/tests/settlements_phase7.test.sql for the same class
-- of negative-control forgery proof used for 0164.
-- ---------------------------------------------------------------------------
create or replace function public.settlement_routes_enforce_updated_columns()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  new.updated_at := now();

  if v_actor is not null and exists (select 1 from public.profiles where id = v_actor) then
    new.updated_by := v_actor;
  else
    new.updated_by := old.updated_by;
  end if;

  return new;
end;
$$;

comment on function public.settlement_routes_enforce_updated_columns() is
  'Phase 7 — updated_by can never be forged, even via a trusted/service_role direct write, from the very first migration (applies the lesson of Hotfix 6.1.2/0164 to a brand-new table instead of needing a later retrofit).';

revoke execute on function public.settlement_routes_enforce_updated_columns() from public;

create trigger settlement_routes_enforce_updated_columns
  before update on public.settlement_routes
  for each row
  execute function public.settlement_routes_enforce_updated_columns();

-- ---------------------------------------------------------------------------
-- Table-level BEFORE STATEMENT lock (item 13) — makes the Settlement Master
-- Lock unconditional: ANY insert/update/delete statement against
-- settlement_routes takes the EXCLUSIVE lock first, regardless of whether
-- it goes through a sanctioned RPC (mirrors adjustment_types_acquire_lock_
-- before_write, 0153, exactly).
-- ---------------------------------------------------------------------------
grant execute on function public.acquire_settlement_master_lock_exclusive() to service_role;
grant execute on function public.acquire_settlement_master_lock_shared() to service_role;

create or replace function public.settlement_routes_acquire_lock_before_write()
returns trigger
language plpgsql
as $$
begin
  perform public.acquire_settlement_master_lock_exclusive();
  return null;
end;
$$;

create trigger settlement_routes_lock_before_write
  before insert or update or delete on public.settlement_routes
  for each statement
  execute function public.settlement_routes_acquire_lock_before_write();

-- ============================================================================
-- 0114: Phase 5 — Shipping Core (2/9): shipping_carrier_rate_versions
-- ============================================================================
-- Migrations 0001-0113 are unmodified. Versioning philosophy mirrors Phase 2
-- exactly (manufacturing_fee_versions, 0042/0047/0053/0056): NUMERIC, no
-- overlap, one effective version per (carrier, zone, direction) at any
-- given date, at most one FUTURE version at a time, historical rows are
-- immutable (only a create-ends-the-old-one / cancel-a-not-yet-effective-
-- one write path — no raw UPDATE of an already-effective row's base_cost),
-- resolution keyed on public.business_today() when no explicit date is
-- given, trusted SECURITY DEFINER RPCs only.
-- ---------------------------------------------------------------------------
create table public.shipping_carrier_rate_versions (
  id uuid primary key default gen_random_uuid(),
  carrier_id uuid not null references public.shipping_carriers (id) on delete restrict,
  shipping_zone_id uuid not null references public.shipping_zones (id) on delete restrict,
  -- Section 6/9 — outbound (store -> customer) and return (customer -> store)
  -- are genuinely different cost structures for most carriers; kept as two
  -- independent version timelines under the same (carrier, zone) pair
  -- rather than one merged one.
  direction text not null check (direction in ('outbound', 'return')),
  base_cost numeric(10, 2) not null check (base_cost >= 0),
  effective_from date not null,
  -- NULL = open-ended (the currently active/scheduled version for this
  -- exact carrier+zone+direction). Set only by create_shipping_carrier_
  -- rate_version() below when a newer version supersedes it.
  effective_to date,
  status text not null default 'active' check (status in ('active', 'ended', 'cancelled')),
  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);

comment on table public.shipping_carrier_rate_versions is
  'Phase 5 (Section 6) — versioned STANDARD/expected carrier cost per (carrier, zone, direction). Section 31: flat configured cost only in this phase (schema left open to add a weight-based rate later without a breaking change). ''active''=the current open-ended version (at most one per carrier+zone+direction, enforced by shipping_carrier_rate_versions_open_uq below); ''ended''=superseded, still valid history for its own date range; ''cancelled''=a FUTURE version withdrawn before it ever took effect (the only form of "undo") — excluded from date-range resolution and the overlap guard. Writes only via create_shipping_carrier_rate_version()/cancel_shipping_carrier_rate_version() (this migration), both SECURITY DEFINER.';

-- At most one OPEN (effective_to IS NULL) version per (carrier, zone,
-- direction) — the real DB-enforced backstop behind create_shipping_
-- carrier_rate_version()'s own application-level check, mirroring
-- manufacturing_fee_versions' equivalent partial unique index (0047).
create unique index shipping_carrier_rate_versions_open_uq
  on public.shipping_carrier_rate_versions (carrier_id, shipping_zone_id, direction)
  where effective_to is null and status = 'active';

create index shipping_carrier_rate_versions_lookup_idx
  on public.shipping_carrier_rate_versions (carrier_id, shipping_zone_id, direction, effective_from);

alter table public.shipping_carrier_rate_versions enable row level security;

-- Same access model as manufacturing_fee_versions (0042): direct RLS SELECT
-- gated on shipping_rates.view is fine (this is rate CONFIGURATION, not a
-- computed per-shipment profit figure — that sensitivity lives on
-- shipments.expected_carrier_cost/actual_carrier_cost/net_shipping_*
-- instead, gated on sales.view_profit inside get_shipment()/list_shipments(),
-- 0119). INSERT/UPDATE policies exist for defense-in-depth exactly like
-- 0042 documents, but the app always goes through the atomic RPCs below.
create policy shipping_carrier_rate_versions_select on public.shipping_carrier_rate_versions
  for select to authenticated
  using (public.has_permission('shipping_rates.view'));

create policy shipping_carrier_rate_versions_insert on public.shipping_carrier_rate_versions
  for insert to authenticated
  with check (public.has_permission('shipping_rates.manage'));

create policy shipping_carrier_rate_versions_update on public.shipping_carrier_rate_versions
  for update to authenticated
  using (public.has_permission('shipping_rates.manage'))
  with check (public.has_permission('shipping_rates.manage'));

-- ---------------------------------------------------------------------------
-- create_shipping_carrier_rate_version() — byte-for-byte the same shape as
-- create_manufacturing_fee_version() (0066's final form): permission check,
-- exclusive rate lock, required-fields check, non-negative check, lock+
-- inspect the current open version FOR UPDATE, reject a still-future open
-- version or a non-later effective_from, end the old one, insert the new
-- one.
-- ---------------------------------------------------------------------------
create or replace function public.create_shipping_carrier_rate_version(
  p_carrier_id uuid,
  p_shipping_zone_id uuid,
  p_direction text,
  p_base_cost numeric,
  p_effective_from date,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_open record;
  v_today date := public.business_today();
begin
  if not public.has_permission('shipping_rates.manage') then
    raise exception 'ليست لديك صلاحية إدارة تسعير الشحن' using errcode = 'P0001';
  end if;

  perform public.acquire_shipping_rates_lock_exclusive();

  if p_carrier_id is null or p_shipping_zone_id is null or p_direction is null or p_base_cost is null or p_effective_from is null then
    raise exception 'شركة الشحن، المنطقة، الاتجاه، التكلفة، وتاريخ السريان كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_direction not in ('outbound', 'return') then
    raise exception 'اتجاه الشحنة يجب أن يكون outbound أو return' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_base_cost, 'التكلفة الأساسية');

  if p_base_cost < 0 then
    raise exception 'التكلفة الأساسية لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.shipping_carriers where id = p_carrier_id) then
    raise exception 'شركة الشحن غير موجودة' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.shipping_zones where id = p_shipping_zone_id) then
    raise exception 'المنطقة غير موجودة' using errcode = 'P0001';
  end if;

  select * into v_open
  from public.shipping_carrier_rate_versions
  where carrier_id = p_carrier_id and shipping_zone_id = p_shipping_zone_id and direction = p_direction
    and effective_to is null and status = 'active'
  for update;

  if found then
    if v_open.effective_from > v_today then
      raise exception 'يوجد بالفعل إصدار تسعير مستقبلي مجدوَل لهذه التركيبة (يسري اعتبارًا من %) ولم يسرِ بعد — ألغِ الإصدار المستقبلي الحالي أولًا عبر cancel_shipping_carrier_rate_version()', v_open.effective_from
        using errcode = 'P0001';
    end if;

    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار تسعير سارٍ/مجدوَل لهذه التركيبة بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.shipping_carrier_rate_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.shipping_carrier_rate_versions (carrier_id, shipping_zone_id, direction, base_cost, effective_from, effective_to, status, notes, created_by)
  values (p_carrier_id, p_shipping_zone_id, p_direction, p_base_cost, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_shipping_carrier_rate_version(uuid, uuid, text, numeric, date, text) is
  'Phase 5 (Section 6) — atomically ends the (carrier, zone, direction)''s currently open rate version (if the new effective_from is after it) and inserts the new one. At most one FUTURE version per combination. "Is the open version itself still in the future" is judged against public.business_today() (Asia/Riyadh). SECURITY DEFINER.';

revoke execute on function public.create_shipping_carrier_rate_version(uuid, uuid, text, numeric, date, text) from public;
grant execute on function public.create_shipping_carrier_rate_version(uuid, uuid, text, numeric, date, text) to authenticated;

create or replace function public.cancel_shipping_carrier_rate_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_predecessor record;
begin
  if not public.has_permission('shipping_rates.manage') then
    raise exception 'ليست لديك صلاحية إدارة تسعير الشحن' using errcode = 'P0001';
  end if;

  perform public.acquire_shipping_rates_lock_exclusive();

  select * into v_row from public.shipping_carrier_rate_versions where id = p_version_id for update;

  if not found then
    raise exception 'إصدار التسعير غير موجود' using errcode = 'P0001';
  end if;

  if v_row.status <> 'active' then
    raise exception 'هذا الإصدار ليس نشِطًا أصلًا (تم إلغاؤه أو استبداله سابقًا)' using errcode = 'P0001';
  end if;

  if v_row.effective_from <= public.business_today() then
    raise exception 'لا يمكن إلغاء إصدار تسعير سارٍ بالفعل أو مضى تاريخ سريانه — يُسمح فقط بإلغاء إصدار مستقبلي لم يسرِ بعد' using errcode = 'P0001';
  end if;

  update public.shipping_carrier_rate_versions set status = 'cancelled' where id = p_version_id;

  select * into v_predecessor
  from public.shipping_carrier_rate_versions
  where carrier_id = v_row.carrier_id and shipping_zone_id = v_row.shipping_zone_id and direction = v_row.direction
    and status = 'ended' and effective_to = v_row.effective_from - 1
  for update;

  if found then
    update public.shipping_carrier_rate_versions
    set effective_to = null, status = 'active'
    where id = v_predecessor.id;
  end if;
end;
$$;

comment on function public.cancel_shipping_carrier_rate_version(uuid) is
  'Phase 5 (Section 6) — withdraws a rate version that has not taken effect yet, and atomically reopens the exact predecessor it had ended. SECURITY DEFINER.';

revoke execute on function public.cancel_shipping_carrier_rate_version(uuid) from public;
grant execute on function public.cancel_shipping_carrier_rate_version(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- shipping_carrier_rate_for() — resolver, mirrors manufacturing_fee_for_
-- karat_on_date() exactly. Returns NULL (not an exception, not zero) when
-- no configuration exists for this exact date — Section 17 is explicit that
-- callers must NOT assume zero; create_shipment() (0117) is the one that
-- decides what to do with a NULL (manual entry / block).
-- ---------------------------------------------------------------------------
create or replace function public.shipping_carrier_rate_for(
  p_carrier_id uuid,
  p_shipping_zone_id uuid,
  p_direction text,
  p_date date default public.business_today()
)
returns table (version_id uuid, base_cost numeric)
language plpgsql
stable
as $$
begin
  return query
  select v.id, v.base_cost
  from public.shipping_carrier_rate_versions v
  where v.carrier_id = p_carrier_id
    and v.shipping_zone_id = p_shipping_zone_id
    and v.direction = p_direction
    and v.status <> 'cancelled'
    and v.effective_from <= p_date
    and (v.effective_to is null or v.effective_to >= p_date)
  order by v.effective_from desc
  limit 1;
end;
$$;

comment on function public.shipping_carrier_rate_for(uuid, uuid, text, date) is
  'Phase 5 (Section 6/17) — resolves the effective standard/expected carrier rate for (carrier, zone, direction) on a given date (defaults to business_today()). Returns ZERO ROWS (not an exception, not a zero cost) if no configuration exists for that date — Section 17: create_shipment() must not assume zero. STABLE.';

-- Deliberately NOT granted to `authenticated` directly (Section 38: a
-- shipments.create-only actor must not need shipping_rates.view just to
-- preview a rate — calling this raw would silently return zero rows under
-- RLS instead of a clear error). Called internally by create_shipment()/
-- preview_shipment_expected_cost() (0117), both SECURITY DEFINER, which
-- retain implicit EXECUTE as the function owner regardless of this revoke.
revoke execute on function public.shipping_carrier_rate_for(uuid, uuid, text, date) from public;

-- ---------------------------------------------------------------------------
-- Seed — Section 7's CURRENT confirmed return-cost figures only. Deliberately
-- NO outbound rate is seeded for any carrier (Section 7: "إذا لم توجد لدينا
-- تكلفة Outbound مؤكدة: لا تخترعها" — no confirmed outbound figure was given,
-- so none is invented). NO rate at all for STORE_COURIER (Section 7: "لا
-- تخترع تكلفة افتراضية" — a store courier delivery has no external invoice
-- cost by default; create_shipment()'s manual-entry escape hatch is the
-- correct path if a real cost is ever incurred, e.g. fuel reimbursement).
-- Plain INSERTs (not the RPC above) — mirrors supabase/seed.sql's own
-- payment_method_fee_versions/vat_rate_versions seeding convention exactly:
-- migrations/seed run as the superuser with no auth.uid(), so a SECURITY
-- DEFINER RPC's has_permission() check would always fail here. ON CONFLICT
-- targets the SAME partial unique index (shipping_carrier_rate_versions_
-- open_uq) the RPC itself relies on, so re-running this file never
-- duplicates or overwrites an already-configured combination. Figures given
-- are carrier-level only (not zone-specific) — seeded identically for both
-- zones, since no zone-differentiated return cost was specified. This is
-- Configuration, editable later per zone via create_shipping_carrier_rate_
-- version() — never hardcoded in logic.
-- ---------------------------------------------------------------------------
insert into public.shipping_carrier_rate_versions (carrier_id, shipping_zone_id, direction, base_cost, effective_from, notes)
select c.id, z.id, 'return', v.rate, public.business_today(), 'Section 7 — التكلفة التقريبية الحالية للإرجاع (إعداد أولي)'
from public.shipping_carriers c
cross join public.shipping_zones z
join (values ('SMSA', 17.00), ('ARAMEX', 17.00), ('BARQ', 15.00), ('REDBOX', 15.00)) as v(code, rate) on v.code = c.code
where z.code in ('RIYADH', 'OUTSIDE_RIYADH')
on conflict (carrier_id, shipping_zone_id, direction) where (effective_to is null and status = 'active') do nothing;

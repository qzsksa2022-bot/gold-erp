-- ============================================================================
-- 0115: Phase 5 — Shipping Core (3/9): customer_return_shipping_fee_versions
-- ============================================================================
-- Migrations 0001-0114 are unmodified. Same versioning philosophy as 0114 —
-- this is the REVENUE side (what the customer is charged for a return
-- shipment), keyed only by (zone, date), not by carrier (Section 8's
-- current policy is zone-driven only). Explicitly NOT sales_returns.non_
-- shipping_deduction_amount and NOT approved_refund_amount — Section 8 is
-- unambiguous that this is a Shipping Revenue figure, never mixed into
-- Sales Return financial history.
-- ---------------------------------------------------------------------------
create table public.customer_return_shipping_fee_versions (
  id uuid primary key default gen_random_uuid(),
  shipping_zone_id uuid not null references public.shipping_zones (id) on delete restrict,
  fee_amount numeric(10, 2) not null check (fee_amount >= 0),
  effective_from date not null,
  effective_to date,
  status text not null default 'active' check (status in ('active', 'ended', 'cancelled')),
  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);

comment on table public.customer_return_shipping_fee_versions is
  'Phase 5 (Section 8) — versioned STANDARD customer-facing return shipping fee per zone (current policy: Riyadh=35, Outside Riyadh=50 — Section 45''s exact seed). This is Shipping Revenue only, entirely independent from sales_returns.non_shipping_deduction_amount/approved_refund_amount. Writes only via create_customer_return_shipping_fee_version()/cancel_customer_return_shipping_fee_version() (this migration), both SECURITY DEFINER.';

create unique index customer_return_shipping_fee_versions_open_uq
  on public.customer_return_shipping_fee_versions (shipping_zone_id)
  where effective_to is null and status = 'active';

create index customer_return_shipping_fee_versions_lookup_idx
  on public.customer_return_shipping_fee_versions (shipping_zone_id, effective_from);

alter table public.customer_return_shipping_fee_versions enable row level security;

create policy customer_return_shipping_fee_versions_select on public.customer_return_shipping_fee_versions
  for select to authenticated
  using (public.has_permission('shipping_rates.view'));

create policy customer_return_shipping_fee_versions_insert on public.customer_return_shipping_fee_versions
  for insert to authenticated
  with check (public.has_permission('shipping_rates.manage'));

create policy customer_return_shipping_fee_versions_update on public.customer_return_shipping_fee_versions
  for update to authenticated
  using (public.has_permission('shipping_rates.manage'))
  with check (public.has_permission('shipping_rates.manage'));

create or replace function public.create_customer_return_shipping_fee_version(
  p_shipping_zone_id uuid,
  p_fee_amount numeric,
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

  if p_shipping_zone_id is null or p_fee_amount is null or p_effective_from is null then
    raise exception 'المنطقة، قيمة الرسوم، وتاريخ السريان كلها مطلوبة' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_fee_amount, 'قيمة رسوم شحن الإرجاع');

  if p_fee_amount < 0 then
    raise exception 'قيمة رسوم شحن الإرجاع لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.shipping_zones where id = p_shipping_zone_id) then
    raise exception 'المنطقة غير موجودة' using errcode = 'P0001';
  end if;

  select * into v_open
  from public.customer_return_shipping_fee_versions
  where shipping_zone_id = p_shipping_zone_id and effective_to is null and status = 'active'
  for update;

  if found then
    if v_open.effective_from > v_today then
      raise exception 'يوجد بالفعل إصدار رسوم إرجاع مستقبلي مجدوَل لهذه المنطقة (يسري اعتبارًا من %) ولم يسرِ بعد — ألغِ الإصدار المستقبلي الحالي أولًا', v_open.effective_from
        using errcode = 'P0001';
    end if;

    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار رسوم إرجاع سارٍ/مجدوَل لهذه المنطقة بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.customer_return_shipping_fee_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.customer_return_shipping_fee_versions (shipping_zone_id, fee_amount, effective_from, effective_to, status, notes, created_by)
  values (p_shipping_zone_id, p_fee_amount, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_customer_return_shipping_fee_version(uuid, numeric, date, text) is
  'Phase 5 (Section 8) — atomically ends the zone''s currently open customer-return-shipping-fee version and inserts the new one. Same shape as create_shipping_carrier_rate_version() (0114). SECURITY DEFINER.';

revoke execute on function public.create_customer_return_shipping_fee_version(uuid, numeric, date, text) from public;
grant execute on function public.create_customer_return_shipping_fee_version(uuid, numeric, date, text) to authenticated;

create or replace function public.cancel_customer_return_shipping_fee_version(p_version_id uuid)
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

  select * into v_row from public.customer_return_shipping_fee_versions where id = p_version_id for update;

  if not found then
    raise exception 'إصدار رسوم الإرجاع غير موجود' using errcode = 'P0001';
  end if;

  if v_row.status <> 'active' then
    raise exception 'هذا الإصدار ليس نشِطًا أصلًا (تم إلغاؤه أو استبداله سابقًا)' using errcode = 'P0001';
  end if;

  if v_row.effective_from <= public.business_today() then
    raise exception 'لا يمكن إلغاء إصدار رسوم إرجاع سارٍ بالفعل أو مضى تاريخ سريانه' using errcode = 'P0001';
  end if;

  update public.customer_return_shipping_fee_versions set status = 'cancelled' where id = p_version_id;

  select * into v_predecessor
  from public.customer_return_shipping_fee_versions
  where shipping_zone_id = v_row.shipping_zone_id and status = 'ended' and effective_to = v_row.effective_from - 1
  for update;

  if found then
    update public.customer_return_shipping_fee_versions
    set effective_to = null, status = 'active'
    where id = v_predecessor.id;
  end if;
end;
$$;

comment on function public.cancel_customer_return_shipping_fee_version(uuid) is
  'Phase 5 (Section 8) — withdraws a customer-return-shipping-fee version that has not taken effect yet, and atomically reopens the exact predecessor it had ended. SECURITY DEFINER.';

revoke execute on function public.cancel_customer_return_shipping_fee_version(uuid) from public;
grant execute on function public.cancel_customer_return_shipping_fee_version(uuid) to authenticated;

create or replace function public.customer_return_shipping_fee_for(
  p_shipping_zone_id uuid,
  p_date date default public.business_today()
)
returns table (version_id uuid, fee_amount numeric)
language plpgsql
stable
as $$
begin
  return query
  select v.id, v.fee_amount
  from public.customer_return_shipping_fee_versions v
  where v.shipping_zone_id = p_shipping_zone_id
    and v.status <> 'cancelled'
    and v.effective_from <= p_date
    and (v.effective_to is null or v.effective_to >= p_date)
  order by v.effective_from desc
  limit 1;
end;
$$;

comment on function public.customer_return_shipping_fee_for(uuid, date) is
  'Phase 5 (Section 8) — resolves the effective STANDARD customer return-shipping fee for a zone on a given date (defaults to business_today()). Returns ZERO ROWS if no configuration exists — create_shipment() (0117) falls back to requiring an explicit p_customer_shipping_charge in that case, never assumes zero. STABLE.';

-- Deliberately NOT granted to `authenticated` directly — same reasoning as
-- shipping_carrier_rate_for() (0114). Called internally by create_shipment()/
-- preview_shipment_expected_cost() (0117).
revoke execute on function public.customer_return_shipping_fee_for(uuid, date) from public;

-- Seed (Section 8/45) — current confirmed policy: Riyadh=35, Outside
-- Riyadh=50. Same idempotent direct-INSERT convention as 0114.
insert into public.customer_return_shipping_fee_versions (shipping_zone_id, fee_amount, effective_from, notes)
select z.id, v.fee, public.business_today(), 'Section 8 — السياسة الحالية لرسوم شحن الإرجاع (إعداد أولي)'
from public.shipping_zones z
join (values ('RIYADH', 35.00), ('OUTSIDE_RIYADH', 50.00)) as v(code, fee) on v.code = z.code
on conflict (shipping_zone_id) where (effective_to is null and status = 'active') do nothing;

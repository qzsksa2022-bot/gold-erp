-- ============================================================================
-- 0122: Shipping Integrity Patch 5.1 (1/10): close the direct-write bypass
-- on shipping_carrier_rate_versions/customer_return_shipping_fee_versions,
-- add DB-level no-overlap + immutability, reject rate creation against
-- inactive Master Data
-- ============================================================================
-- Migrations 0001-0121 are unmodified (user directive: "لا تعدل migrations
-- من 0001 إلى 0121" / "كل الإصلاحات الجديدة تبدأ من 0122 وما بعده"). This
-- patch does NOT start Settlements/Services-Adjustments/Inventory/Reports/
-- Carrier API — Shipping Core hardening only.
--
-- Patch 5.1 item 1 (the single most important gap): 0114/0115 documented
-- "trusted SECURITY DEFINER RPCs only" as the write path for these two
-- versioning tables, but their own RLS still carried a live INSERT/UPDATE
-- policy for `authenticated` holding shipping_rates.manage — a direct
-- PostgREST POST/PATCH could bypass create_shipping_carrier_rate_version()/
-- create_customer_return_shipping_fee_version() entirely, along with every
-- invariant those RPCs enforce (one-future rule, create/cancel lifecycle,
-- the exclusive rate lock, immutable historical rate semantics, money-scale
-- validation). This is the EXACT gap Financial Integrity Patch 2.1 (0047)
-- already closed once for manufacturing_fee_versions/payment_method_fee_
-- versions — same fix, same reasoning, applied here.
--
-- Item 2: 0114/0115 only enforced "no two OPEN (effective_to IS NULL)
-- versions for the same identity" via a partial unique index — it never
-- prevented two historical, already-closed date ranges from overlapping
-- (e.g. two different rows both claiming 2026-01-01..2026-03-31 for the
-- same carrier/zone/direction). Fixed here with the SAME GIST exclusion
-- constraint philosophy as manufacturing_fee_versions' final form (0042).
--
-- Item 3: a version's identity/value/creation metadata must be permanent
-- once the row exists — mirrors 0047 PART B (versioning value immutability)
-- + 0048 (system-managed created_at/created_by immutability), combined into
-- one trigger per table here since Patch 5.1 asked for both column sets
-- locked down together.
--
-- Item 5: create_shipping_carrier_rate_version()/create_customer_return_
-- shipping_fee_version() checked only that the referenced carrier/zone
-- EXISTS, never that it is currently `active` — a disabled carrier/zone
-- could still receive a brand new rate version. Fixed by re-declaring both
-- functions (CREATE OR REPLACE, identical signature) with an added active-
-- status check. Historical versions already created are untouched — Section
-- 5's own instruction "Version تاريخية قد تبقى بعد تعطيل Master Data
-- طبيعيًا. لا تمسح التاريخ" (a historical version may outlive the Master
-- Data being disabled later — never erase history).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- PART A — close the direct-write RLS path (item 1). SELECT policies
-- (gated by shipping_rates.view) are untouched. No replacement INSERT/
-- UPDATE policy for `authenticated` — the RPCs below are SECURITY DEFINER
-- and bypass RLS entirely when they write, exactly like 0047's fix for
-- manufacturing_fee_versions/payment_method_fee_versions.
-- ---------------------------------------------------------------------------
drop policy shipping_carrier_rate_versions_insert on public.shipping_carrier_rate_versions;
drop policy shipping_carrier_rate_versions_update on public.shipping_carrier_rate_versions;
drop policy customer_return_shipping_fee_versions_insert on public.customer_return_shipping_fee_versions;
drop policy customer_return_shipping_fee_versions_update on public.customer_return_shipping_fee_versions;

comment on table public.shipping_carrier_rate_versions is
  'Phase 5 (Section 6) — versioned STANDARD/expected carrier cost per (carrier, zone, direction). `authenticated` has NO direct INSERT/UPDATE path as of Patch 5.1 (0122) — every write goes through create_shipping_carrier_rate_version()/cancel_shipping_carrier_rate_version() (SECURITY DEFINER) or a trusted bootstrap context (service_role/direct SQL, e.g. supabase/seed.sql). Immutable after creation except effective_to/status (0122 trigger). No two non-cancelled date ranges may overlap for the same (carrier, zone, direction) — enforced by a GIST exclusion constraint (0122), not just the create-RPC''s own end-then-insert discipline.';

comment on table public.customer_return_shipping_fee_versions is
  'Phase 5 (Section 8) — versioned STANDARD customer-facing return shipping fee per zone. `authenticated` has NO direct INSERT/UPDATE path as of Patch 5.1 (0122) — mirrors shipping_carrier_rate_versions exactly. No two non-cancelled date ranges may overlap for the same zone (GIST exclusion, 0122).';

-- ---------------------------------------------------------------------------
-- PART B — DB-level no-overlap (item 2). btree_gist already exists (created
-- `if not exists` by 0042) — repeated here defensively for a database built
-- from a partial/future migration subset.
-- ---------------------------------------------------------------------------
create extension if not exists btree_gist;

alter table public.shipping_carrier_rate_versions
  add constraint shipping_carrier_rate_versions_no_overlap
  exclude using gist (
    carrier_id with =,
    shipping_zone_id with =,
    direction with =,
    daterange(effective_from, effective_to, '[]') with &&
  )
  where (status <> 'cancelled');

comment on constraint shipping_carrier_rate_versions_no_overlap on public.shipping_carrier_rate_versions is
  'Patch 5.1 item 2 — no two non-cancelled date ranges may overlap for the same (carrier_id, shipping_zone_id, direction), enforced at the database level regardless of write path (even a trusted bootstrap/service_role direct INSERT is rejected). Mirrors manufacturing_fee_versions_no_overlap (0042) exactly. `status <> ''cancelled''` (not `status = ''active''`) — an ''ended'' row is still real, permanent history occupying its own range forever; only a withdrawn-before-effective ''cancelled'' row is excluded.';

alter table public.customer_return_shipping_fee_versions
  add constraint customer_return_shipping_fee_versions_no_overlap
  exclude using gist (
    shipping_zone_id with =,
    daterange(effective_from, effective_to, '[]') with &&
  )
  where (status <> 'cancelled');

comment on constraint customer_return_shipping_fee_versions_no_overlap on public.customer_return_shipping_fee_versions is
  'Patch 5.1 item 2 — no two non-cancelled date ranges may overlap for the same shipping_zone_id. Mirrors shipping_carrier_rate_versions_no_overlap immediately above.';

-- ---------------------------------------------------------------------------
-- PART C — immutability (item 3). Identity/value/effective_from AND
-- created_at/created_by are all permanent once the row exists, for ANY
-- writer, including a trusted bootstrap context — the only sanctioned
-- corrections are create_*_version() (end + insert new) or cancel_*_
-- version() (withdraw a future version + reopen its predecessor), both of
-- which only ever touch effective_to/status. Combines 0047 PART B's
-- versioning-value immutability with 0048's created_at/created_by lockdown
-- into one trigger per table (Patch 5.1 explicitly asked for both together).
-- ---------------------------------------------------------------------------
create or replace function public.enforce_shipping_carrier_rate_version_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.carrier_id is distinct from old.carrier_id
    or new.shipping_zone_id is distinct from old.shipping_zone_id
    or new.direction is distinct from old.direction
    or new.base_cost is distinct from old.base_cost
    or new.effective_from is distinct from old.effective_from
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
  then
    raise exception 'لا يمكن تعديل شركة الشحن أو المنطقة أو الاتجاه أو التكلفة أو تاريخ السريان أو بيانات الإنشاء لإصدار تسعير موجود — أنشئ إصدارًا جديدًا عبر create_shipping_carrier_rate_version() بدلًا من ذلك'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.enforce_shipping_carrier_rate_version_immutable() is
  'Patch 5.1 item 3 — carrier_id/shipping_zone_id/direction/base_cost/effective_from/created_by/created_at are permanent once a shipping_carrier_rate_versions row is created — only effective_to/status may ever change (by create_shipping_carrier_rate_version()/cancel_shipping_carrier_rate_version() alone). Applies unconditionally, even to a trusted bootstrap context.';

revoke execute on function public.enforce_shipping_carrier_rate_version_immutable() from public;

create trigger shipping_carrier_rate_versions_enforce_immutable
  before update on public.shipping_carrier_rate_versions
  for each row
  execute function public.enforce_shipping_carrier_rate_version_immutable();

create or replace function public.enforce_customer_return_shipping_fee_version_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.shipping_zone_id is distinct from old.shipping_zone_id
    or new.fee_amount is distinct from old.fee_amount
    or new.effective_from is distinct from old.effective_from
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
  then
    raise exception 'لا يمكن تعديل المنطقة أو قيمة الرسوم أو تاريخ السريان أو بيانات الإنشاء لإصدار رسوم إرجاع موجود — أنشئ إصدارًا جديدًا عبر create_customer_return_shipping_fee_version() بدلًا من ذلك'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.enforce_customer_return_shipping_fee_version_immutable() is
  'Patch 5.1 item 3 — mirrors enforce_shipping_carrier_rate_version_immutable() exactly, for customer_return_shipping_fee_versions.';

revoke execute on function public.enforce_customer_return_shipping_fee_version_immutable() from public;

create trigger customer_return_shipping_fee_versions_enforce_immutable
  before update on public.customer_return_shipping_fee_versions
  for each row
  execute function public.enforce_customer_return_shipping_fee_version_immutable();

-- ---------------------------------------------------------------------------
-- PART D — reject rate creation against inactive Master Data (item 5).
-- CREATE OR REPLACE with the EXACT same signature/body as 0114/0115's
-- versions, plus one new existence+status check each, inserted immediately
-- after the existing carrier/zone existence check.
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
  v_ended_version_id uuid;
  v_today date := public.business_today();
  v_carrier_status text;
  v_zone_status text;
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

  select status into v_carrier_status from public.shipping_carriers where id = p_carrier_id;
  if v_carrier_status is null then
    raise exception 'شركة الشحن غير موجودة' using errcode = 'P0001';
  end if;

  -- Patch 5.1 item 5 — a NEW rate version can never be created for a
  -- disabled carrier. Historical versions already created before the
  -- carrier was disabled remain untouched (never erased/hidden).
  if v_carrier_status <> 'active' then
    raise exception 'لا يمكن إنشاء إصدار تسعير لشركة شحن غير نشطة' using errcode = 'P0001';
  end if;

  select status into v_zone_status from public.shipping_zones where id = p_shipping_zone_id;
  if v_zone_status is null then
    raise exception 'المنطقة غير موجودة' using errcode = 'P0001';
  end if;

  if v_zone_status <> 'active' then
    raise exception 'لا يمكن إنشاء إصدار تسعير لمنطقة غير نشطة' using errcode = 'P0001';
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

    v_ended_version_id := v_open.id;
  end if;

  insert into public.shipping_carrier_rate_versions (carrier_id, shipping_zone_id, direction, base_cost, effective_from, effective_to, status, notes, created_by)
  values (p_carrier_id, p_shipping_zone_id, p_direction, p_base_cost, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  perform public.log_audit_event(
    'shipping_rate.create', 'shipping_carrier_rate_version', v_id, null,
    jsonb_build_object(
      'carrier_id', p_carrier_id, 'shipping_zone_id', p_shipping_zone_id, 'direction', p_direction,
      'base_cost', p_base_cost, 'effective_from', p_effective_from, 'ended_version_id', v_ended_version_id
    ),
    p_notes
  );

  return v_id;
end;
$$;

comment on function public.create_shipping_carrier_rate_version(uuid, uuid, text, numeric, date, text) is
  'Phase 5 (Section 6), hardened by Patch 5.1 (0122): atomically ends the (carrier, zone, direction)''s currently open rate version (if the new effective_from is after it) and inserts the new one. As of 0122, rejects if the carrier or zone is not currently ''active'' (a disabled carrier/zone can keep its historical rate history but never gains a NEW version) and writes a shipping_rate.create audit row. At most one FUTURE version per combination. SECURITY DEFINER.';

revoke execute on function public.create_shipping_carrier_rate_version(uuid, uuid, text, numeric, date, text) from public;
grant execute on function public.create_shipping_carrier_rate_version(uuid, uuid, text, numeric, date, text) to authenticated;

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
  v_ended_version_id uuid;
  v_today date := public.business_today();
  v_zone_status text;
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

  select status into v_zone_status from public.shipping_zones where id = p_shipping_zone_id;
  if v_zone_status is null then
    raise exception 'المنطقة غير موجودة' using errcode = 'P0001';
  end if;

  -- Patch 5.1 item 5 — same reasoning as create_shipping_carrier_rate_version().
  if v_zone_status <> 'active' then
    raise exception 'لا يمكن إنشاء إصدار رسوم إرجاع لمنطقة غير نشطة' using errcode = 'P0001';
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

    v_ended_version_id := v_open.id;
  end if;

  insert into public.customer_return_shipping_fee_versions (shipping_zone_id, fee_amount, effective_from, effective_to, status, notes, created_by)
  values (p_shipping_zone_id, p_fee_amount, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  perform public.log_audit_event(
    'customer_return_shipping_fee.create', 'customer_return_shipping_fee_version', v_id, null,
    jsonb_build_object('shipping_zone_id', p_shipping_zone_id, 'fee_amount', p_fee_amount, 'effective_from', p_effective_from, 'ended_version_id', v_ended_version_id),
    p_notes
  );

  return v_id;
end;
$$;

comment on function public.create_customer_return_shipping_fee_version(uuid, numeric, date, text) is
  'Phase 5 (Section 8), hardened by Patch 5.1 (0122): atomically ends the zone''s currently open customer-return-shipping-fee version and inserts the new one. As of 0122, rejects if the zone is not currently ''active'' and writes a customer_return_shipping_fee.create audit row. SECURITY DEFINER.';

revoke execute on function public.create_customer_return_shipping_fee_version(uuid, numeric, date, text) from public;
grant execute on function public.create_customer_return_shipping_fee_version(uuid, numeric, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- cancel_*_version() re-declared unchanged (CREATE OR REPLACE, byte-for-byte
-- same body as 0114/0115) except for one new audit call each (item 7,
-- shipping_rate.cancel/customer_return_shipping_fee.cancel) — no new
-- business-logic check needed here (a cancel can only ever act on a FUTURE,
-- not-yet-effective version of an already-existing row; nothing about
-- Master Data active/inactive status is relevant to withdrawing a version
-- that was already validly created).
-- ---------------------------------------------------------------------------
create or replace function public.cancel_shipping_carrier_rate_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_predecessor record;
  v_predecessor_id uuid;
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

    v_predecessor_id := v_predecessor.id;
  end if;

  perform public.log_audit_event(
    'shipping_rate.cancel', 'shipping_carrier_rate_version', p_version_id,
    jsonb_build_object('status', 'active', 'effective_from', v_row.effective_from, 'base_cost', v_row.base_cost),
    jsonb_build_object('status', 'cancelled', 'reopened_predecessor_id', v_predecessor_id),
    null
  );
end;
$$;

comment on function public.cancel_shipping_carrier_rate_version(uuid) is
  'Phase 5 (Section 6) — withdraws a rate version that has not taken effect yet, and atomically reopens the exact predecessor it had ended. As of Patch 5.1 (0122): writes a shipping_rate.cancel audit row. SECURITY DEFINER.';

revoke execute on function public.cancel_shipping_carrier_rate_version(uuid) from public;
grant execute on function public.cancel_shipping_carrier_rate_version(uuid) to authenticated;

create or replace function public.cancel_customer_return_shipping_fee_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_predecessor record;
  v_predecessor_id uuid;
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

    v_predecessor_id := v_predecessor.id;
  end if;

  perform public.log_audit_event(
    'customer_return_shipping_fee.cancel', 'customer_return_shipping_fee_version', p_version_id,
    jsonb_build_object('status', 'active', 'effective_from', v_row.effective_from, 'fee_amount', v_row.fee_amount),
    jsonb_build_object('status', 'cancelled', 'reopened_predecessor_id', v_predecessor_id),
    null
  );
end;
$$;

comment on function public.cancel_customer_return_shipping_fee_version(uuid) is
  'Phase 5 (Section 8) — withdraws a customer-return-shipping-fee version that has not taken effect yet, and atomically reopens the exact predecessor it had ended. As of Patch 5.1 (0122): writes a customer_return_shipping_fee.cancel audit row. SECURITY DEFINER.';

revoke execute on function public.cancel_customer_return_shipping_fee_version(uuid) from public;
grant execute on function public.cancel_customer_return_shipping_fee_version(uuid) to authenticated;

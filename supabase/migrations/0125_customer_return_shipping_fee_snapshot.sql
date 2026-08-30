-- ============================================================================
-- 0125: Shipping Integrity Patch 5.1 (4/10): Customer Return Shipping Fee
-- Snapshot on the shipment itself (items 8/9)
-- ============================================================================
-- Migrations 0001-0124 are unmodified.
--
-- Gap (item 8): create_shipment() (0117) always stored the submitted
-- customer_shipping_charge, but for a RETURN shipment it never recorded
-- WHICH customer_return_shipping_fee_versions row (if any) was the standard
-- suggestion at that moment, what that standard amount actually was, or
-- whether the actor overrode it — so a later reviewer looking at an old
-- return shipment charging e.g. 30 SAR has no way to tell whether that was
-- the policy at the time, or a deliberate override, or entered against no
-- configuration at all. Fixed with four new columns, captured ONLY for
-- direction='return' (a real DB CHECK constraint, not just app discipline —
-- outbound shipments never touch these columns, matching Section 8's own
-- "هذا لا يُطبَّق على Outbound").
--
-- Item 9 (Preview/Create Parity): preview_customer_return_shipping_fee()
-- (0117) already returns the standard suggestion + version id; is_override/
-- override_reason are inherently a comparison against what the actor
-- SUBMITS, which the preview call (taken before the amount is finalized)
-- cannot know — so parity here means create_shipment() computes exactly the
-- same standard/version_id the preview call would have shown for the same
-- (zone, date), inside the SAME shared rate-lock window used for the
-- carrier-rate resolution immediately above it, so the two snapshots (rate +
-- fee) are always consistent with one instant in time. If Configuration
-- changes later, an EXISTING return shipment''s snapshot is untouched
-- (immutable historical fact) — only a NEW shipment created after the
-- change would see the new standard amount.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- PART A — new columns + scope/consistency constraints.
-- ---------------------------------------------------------------------------
alter table public.shipments
  add column customer_return_shipping_fee_version_id uuid references public.customer_return_shipping_fee_versions (id) on delete restrict,
  add column customer_return_shipping_fee_standard_amount numeric(10, 2),
  add column customer_return_shipping_charge_is_override boolean not null default false,
  add column customer_return_shipping_charge_override_reason text;

comment on column public.shipments.customer_return_shipping_fee_version_id is
  'Patch 5.1 (Section 8/20, item 8) — the customer_return_shipping_fee_versions row that was the STANDARD suggestion at creation time for a RETURN shipment (NULL for outbound, and NULL for a return created when no configuration existed for that zone/date — "manual, no config" case, never invented).';

comment on column public.shipments.customer_return_shipping_fee_standard_amount is
  'Patch 5.1 (item 8) — the STANDARD fee amount that was suggested at creation time (a snapshot of customer_return_shipping_fee_version_id''s fee_amount at that moment) — permanent even if the version/Configuration later changes. NULL for outbound or "manual, no config".';

comment on column public.shipments.customer_return_shipping_charge_is_override is
  'Patch 5.1 (item 8) — true iff the actor''s submitted customer_shipping_charge differed from the standard suggestion (or no configuration existed at all, in which case this is always true — a manual entry against no policy is inherently an override). Always false for outbound.';

comment on column public.shipments.customer_return_shipping_charge_override_reason is
  'Patch 5.1 (item 8) — mandatory free-text reason whenever customer_return_shipping_charge_is_override is true; NULL otherwise. Captured once at creation, never rewritten (a LATER correction to the charge goes through correct_shipment_customer_charge()/shipment_financial_events, 0118, entirely separate from this creation-time snapshot).';

alter table public.shipments
  add constraint shipments_return_fee_snapshot_outbound_scope check (
    direction = 'return'
    or (
      customer_return_shipping_fee_version_id is null
      and customer_return_shipping_fee_standard_amount is null
      and customer_return_shipping_charge_is_override = false
      and customer_return_shipping_charge_override_reason is null
    )
  );

comment on constraint shipments_return_fee_snapshot_outbound_scope on public.shipments is
  'Patch 5.1 (item 8) — the Customer Return Shipping Fee snapshot columns are only ever populated for direction=return; an outbound shipment must carry all four as null/false. DB-enforced, not just application discipline.';

alter table public.shipments
  add constraint shipments_return_fee_override_reason_required check (
    customer_return_shipping_charge_is_override = false
    or (customer_return_shipping_charge_override_reason is not null and btrim(customer_return_shipping_charge_override_reason) <> '')
  );

comment on constraint shipments_return_fee_override_reason_required on public.shipments is
  'Patch 5.1 (item 8/9) — a return-fee override can never be recorded without a non-empty reason, mirroring shipments_manual_expected_cost_consistent''s shape for the carrier-cost side (0116).';

-- ---------------------------------------------------------------------------
-- PART B — create_shipment(), new trailing parameter (Postgres allows
-- CREATE OR REPLACE to add a parameter only when appended at the end with a
-- default AND every existing parameter is unchanged; this project''s own
-- convention when in doubt is DROP + CREATE, used here for clarity/safety —
-- see e.g. 0093''s drop function public.create_sales_return(...) before its
-- own signature change).
-- ---------------------------------------------------------------------------
drop function if exists public.create_shipment(uuid, uuid, date, text, uuid, uuid, numeric, uuid, text, text, text, text, text, text, boolean, numeric, numeric, text, text, text);

create or replace function public.create_shipment(
  p_sales_order_id uuid,
  p_store_id uuid,
  p_shipment_date date,
  p_direction text,
  p_carrier_id uuid,
  p_shipping_zone_id uuid,
  p_customer_shipping_charge numeric,
  p_sales_return_id uuid default null,
  p_fulfillment_type text default 'delivery',
  p_tracking_number text default null,
  p_external_reference text default null,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_recipient_address text default null,
  p_is_cod boolean default false,
  p_cod_expected_amount numeric default null,
  p_manual_expected_cost numeric default null,
  p_manual_expected_cost_reason text default null,
  p_notes text default null,
  p_closed_day_reason text default null,
  -- Patch 5.1 (item 8/9) — mandatory whenever the submitted p_customer_
  -- shipping_charge differs from the standard return-fee suggestion (or no
  -- configuration exists at all for the zone/date). Ignored for outbound.
  p_customer_return_shipping_charge_override_reason text default null
)
returns table (id uuid, shipment_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_order record;
  v_return record;
  v_carrier record;
  v_zone record;
  v_today date := public.business_today();
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_resolved_rate record;
  v_expected_cost numeric;
  v_rate_version_id uuid;
  v_is_manual boolean := false;
  v_resolved_fee record;
  v_return_fee_version_id uuid;
  v_return_fee_standard_amount numeric;
  v_return_fee_is_override boolean := false;
  v_return_fee_reason text;
  v_net_shipping_expected numeric;
  v_shipment_number text;
  v_shipment_id uuid;
  v_customer_name text;
  v_customer_phone text;
begin
  -- 1-3) authenticate, permission, active user.
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لإنشاء شحنة' using errcode = 'P0001';
  end if;

  if not public.has_permission('shipments.create') then
    raise exception 'ليست لديك صلاحية إنشاء شحنات' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_sales_order_id is null or p_store_id is null or p_shipment_date is null or p_direction is null
     or p_carrier_id is null or p_shipping_zone_id is null or p_customer_shipping_charge is null then
    raise exception 'عملية البيع والمتجر وتاريخ الشحنة والاتجاه وشركة الشحن والمنطقة ورسوم الشحن على العميل كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_direction not in ('outbound', 'return') then
    raise exception 'اتجاه الشحنة يجب أن يكون outbound أو return' using errcode = 'P0001';
  end if;

  if p_fulfillment_type not in ('delivery', 'store_courier', 'pickup', 'other') then
    raise exception 'نوع التنفيذ غير صالح' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_customer_shipping_charge, 'رسوم الشحن على العميل');
  perform public.validate_money_scale(p_cod_expected_amount, 'المبلغ المتوقع تحصيله (COD)');
  perform public.validate_money_scale(p_manual_expected_cost, 'التكلفة المتوقعة اليدوية');

  if p_customer_shipping_charge < 0 then
    raise exception 'رسوم الشحن على العميل لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  -- 4) the target Sale must be VISIBLE to the actor (Returns-style narrow
  -- dependency — see search_sales_orders_for_shipment(), 0120 — not
  -- sales.view).
  select so.id, so.order_number, so.store_id, so.sale_date, so.customer_name, so.customer_phone
    into v_order
    from public.sales_orders so where so.id = p_sales_order_id;

  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  -- 5) processing store must be OPERABLE (new transaction — active store,
  -- within actor's scope).
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'هذا المتجر غير متاح لك لإنشاء شحنات فيه، أو أنه غير نشط' using errcode = 'P0001';
  end if;

  -- 6) validate the return link, if any (Section 23 — a real DB invariant,
  -- not merely a check here: the column-level CHECK constraint on shipments
  -- also enforces direction='return' whenever sales_return_id is set).
  -- Patch 5.1 (item 15/16): `for update` locks the return row so a
  -- concurrent reverse_sales_return() (which also locks this exact row,
  -- 0088/0096/0102) can never interleave with this read — either this
  -- transaction sees the return still 'approved' and commits (and a
  -- concurrent reversal blocks until this commits, then correctly sees the
  -- return has a new shipment attached), or a reversal already committed
  -- first and this transaction correctly sees status='reversed' and is
  -- rejected. status='approved' ONLY is now required for a NEW return
  -- shipment (item 15) — a 'reversed' return can no longer receive a new
  -- shipment (an EXISTING historical shipment against it stays linked,
  -- untouched — this check only gates NEW creation).
  if p_sales_return_id is not null then
    if p_direction <> 'return' then
      raise exception 'شحنة الإرجاع (sales_return_id) يجب أن تكون باتجاه return' using errcode = 'P0001';
    end if;

    select sr.id, sr.sales_order_id, sr.processed_store_id, sr.return_date, sr.status
      into v_return
      from public.sales_returns sr where sr.id = p_sales_return_id
      for update;

    if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
      raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
    end if;

    if v_return.sales_order_id <> p_sales_order_id then
      raise exception 'المرتجع لا ينتمي لعملية البيع المحددة' using errcode = 'P0001';
    end if;

    if v_return.status <> 'approved' then
      raise exception 'لا يمكن إنشاء شحنة إرجاع جديدة لمرتجع ليس معتمَدًا حاليًا (الحالة الحالية: %) — إذا كان قد أُلغي (reversed)، فلا يجوز إنشاء شحنة جديدة له', v_return.status using errcode = 'P0001';
    end if;

    -- Section 10 date-logic check (part) — kept INSIDE this guarded block:
    -- v_return is a generic RECORD, never assigned at all when p_sales_
    -- return_id is null, and PL/pgSQL raises "record is not assigned yet"
    -- the instant any field of an unassigned RECORD is referenced — even
    -- inside a condition an AND would otherwise short-circuit away from —
    -- so this must never be evaluated outside the branch that guarantees
    -- v_return was just populated.
    if p_shipment_date < v_return.return_date then
      raise exception 'تاريخ شحنة الإرجاع (%) لا يمكن أن يسبق تاريخ المرتجع (%)', p_shipment_date, v_return.return_date using errcode = 'P0001';
    end if;
  end if;

  -- 7) active carrier.
  select c.id, c.status into v_carrier from public.shipping_carriers c where c.id = p_carrier_id;
  if v_carrier.id is null or v_carrier.status <> 'active' then
    raise exception 'شركة الشحن غير موجودة أو غير نشطة' using errcode = 'P0001';
  end if;

  -- 8) active zone.
  select z.id, z.status into v_zone from public.shipping_zones z where z.id = p_shipping_zone_id;
  if v_zone.id is null or v_zone.status <> 'active' then
    raise exception 'المنطقة غير موجودة أو غير نشطة' using errcode = 'P0001';
  end if;

  -- 9) never a future date.
  if p_shipment_date > v_today then
    raise exception 'لا يمكن تسجيل شحنة بتاريخ مستقبلي (%)', p_shipment_date using errcode = 'P0001';
  end if;

  -- 10) date logical relative to the sale/return it belongs to. (The
  -- return-date half of this check lives INSIDE the "if p_sales_return_id
  -- is not null" block above at Section 6 — see the comment there for why
  -- it must never be evaluated out here where v_return may be unassigned.)
  if p_shipment_date < v_order.sale_date then
    raise exception 'تاريخ الشحنة (%) لا يمكن أن يسبق تاريخ عملية البيع (%)', p_shipment_date, v_order.sale_date using errcode = 'P0001';
  end if;

  -- 11) Daily Close — shared lock on (processing store, shipment_date),
  -- reusing the SAME daily_closings table/lock helpers Sales/Returns use
  -- (Section 28: "Shared Daily Close Lock").
  perform public.acquire_daily_close_lock_shared(p_store_id, p_shipment_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = p_store_id and dc.business_date = p_shipment_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('shipments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن إنشاء شحنة فيه إلا بصلاحية خاصة (shipments.process_closed_day)', p_shipment_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لإنشاء شحنة في يوم مقفل' using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  -- 12-13) resolve the rate (Section 17) — explicit shipment_date, not
  -- business_today() (a backdated shipment inside the Daily Close window
  -- resolves against the rate that was actually effective on ITS date).
  perform public.acquire_shipping_rates_lock_shared();

  select * into v_resolved_rate from public.shipping_carrier_rate_for(p_carrier_id, p_shipping_zone_id, p_direction, p_shipment_date);

  if v_resolved_rate.version_id is not null then
    v_expected_cost := v_resolved_rate.base_cost;
    v_rate_version_id := v_resolved_rate.version_id;
    v_is_manual := false;
  else
    if p_manual_expected_cost is null or p_manual_expected_cost_reason is null or btrim(p_manual_expected_cost_reason) = '' then
      raise exception 'لا يوجد تسعير شحن معتمد لشركة الشحن/المنطقة/الاتجاه هذا بتاريخ % — أدخل التكلفة المتوقعة يدويًا مع سبب واضح', p_shipment_date using errcode = 'P0001';
    end if;

    if p_manual_expected_cost < 0 then
      raise exception 'التكلفة المتوقعة اليدوية لا يمكن أن تكون سالبة' using errcode = 'P0001';
    end if;

    v_expected_cost := p_manual_expected_cost;
    v_rate_version_id := null;
    v_is_manual := true;
  end if;

  -- 13b) Patch 5.1 (item 8/9) — Customer Return Shipping Fee snapshot,
  -- RETURN direction only, resolved inside the SAME shared shipping-rates
  -- lock window as the carrier rate immediately above, so a return
  -- shipment's fee snapshot and its carrier-rate snapshot always reflect
  -- one consistent instant. Never applies to outbound (Section 8's own
  -- instruction, and shipments_return_fee_snapshot_outbound_scope enforces
  -- it at the DB level regardless).
  if p_direction = 'return' then
    select * into v_resolved_fee from public.customer_return_shipping_fee_for(p_shipping_zone_id, p_shipment_date);

    if v_resolved_fee.version_id is not null then
      v_return_fee_version_id := v_resolved_fee.version_id;
      v_return_fee_standard_amount := v_resolved_fee.fee_amount;

      if p_customer_shipping_charge <> v_return_fee_standard_amount then
        v_return_fee_is_override := true;

        if p_customer_return_shipping_charge_override_reason is null or btrim(p_customer_return_shipping_charge_override_reason) = '' then
          raise exception 'رسوم شحن الإرجاع المُدخلة (%) تختلف عن الرسوم القياسية المعتمدة لهذه المنطقة (%) — يجب إدخال سبب التعديل', p_customer_shipping_charge, v_return_fee_standard_amount
            using errcode = 'P0001';
        end if;

        v_return_fee_reason := p_customer_return_shipping_charge_override_reason;
      else
        v_return_fee_is_override := false;
        v_return_fee_reason := null;
      end if;
    else
      -- No configuration exists for this zone/date at all (Section 17-style
      -- "never assume zero") — a manual entry is allowed, but is ALWAYS
      -- treated as an override with a mandatory reason (never silently
      -- treated as "the standard").
      v_return_fee_version_id := null;
      v_return_fee_standard_amount := null;
      v_return_fee_is_override := true;

      if p_customer_return_shipping_charge_override_reason is null or btrim(p_customer_return_shipping_charge_override_reason) = '' then
        raise exception 'لا يوجد إعداد معتمد لرسوم شحن الإرجاع لهذه المنطقة بتاريخ % — أدخل سببًا (رسوم يدوية بدون إعداد معتمد)', p_shipment_date
          using errcode = 'P0001';
      end if;

      v_return_fee_reason := p_customer_return_shipping_charge_override_reason;
    end if;
  end if;

  -- 14) Shipping P/L (Section 32) — fully independent from Sales P/L.
  v_net_shipping_expected := p_customer_shipping_charge - v_expected_cost;

  -- COD consistency (Section 21).
  if not p_is_cod then
    p_cod_expected_amount := null;
  elsif p_cod_expected_amount is not null and p_cod_expected_amount < 0 then
    raise exception 'المبلغ المتوقع تحصيله (COD) لا يمكن أن يكون سالبًا' using errcode = 'P0001';
  end if;

  -- Recipient snapshot defaults (Section 9/16) — fall back to the Sale's
  -- own customer_name/customer_phone only when not explicitly supplied,
  -- captured once here and never re-read live afterward.
  v_customer_name := coalesce(p_customer_name, v_order.customer_name);
  v_customer_phone := coalesce(p_customer_phone, v_order.customer_phone);

  -- 15) shipment number.
  v_shipment_number := public.generate_shipment_number();

  -- 16) insert.
  insert into public.shipments (
    shipment_number, sales_order_id, sales_return_id, store_id, carrier_id, shipping_zone_id,
    direction, fulfillment_type, tracking_number, external_reference,
    customer_name_snapshot, customer_phone_snapshot, recipient_address_snapshot, shipment_date,
    customer_shipping_charge, carrier_rate_version_id, expected_carrier_cost,
    expected_carrier_cost_is_manual, expected_carrier_cost_manual_reason,
    customer_return_shipping_fee_version_id, customer_return_shipping_fee_standard_amount,
    customer_return_shipping_charge_is_override, customer_return_shipping_charge_override_reason,
    net_shipping_expected, is_cod, cod_expected_amount, current_status, notes,
    created_by, updated_by
  ) values (
    v_shipment_number, p_sales_order_id, p_sales_return_id, p_store_id, p_carrier_id, p_shipping_zone_id,
    p_direction, p_fulfillment_type, p_tracking_number, p_external_reference,
    v_customer_name, v_customer_phone, p_recipient_address, p_shipment_date,
    p_customer_shipping_charge, v_rate_version_id, v_expected_cost,
    v_is_manual, p_manual_expected_cost_reason,
    v_return_fee_version_id, v_return_fee_standard_amount,
    v_return_fee_is_override, v_return_fee_reason,
    v_net_shipping_expected, p_is_cod, p_cod_expected_amount, 'created', p_notes,
    v_actor, v_actor
  )
  returning shipments.id into v_shipment_id;

  -- 17) first status event.
  insert into public.shipment_status_events (shipment_id, status, event_business_date, notes, is_correction, actor)
  values (v_shipment_id, 'created', p_shipment_date, null, false, v_actor);

  -- 18) audit — 'shipment.create' carries the full financial snapshot
  -- (customer_shipping_charge/expected_carrier_cost/net_shipping_expected/
  -- return-fee snapshot), so audit_logs RLS (0121/0124) gates reading it
  -- behind sales.view_profit, exactly like sale.create/return.create do.
  perform public.log_audit_event(
    'shipment.create', 'shipment', v_shipment_id, null,
    jsonb_build_object(
      'shipment_number', v_shipment_number, 'sales_order_id', p_sales_order_id, 'sales_return_id', p_sales_return_id,
      'store_id', p_store_id, 'carrier_id', p_carrier_id, 'shipping_zone_id', p_shipping_zone_id,
      'direction', p_direction, 'shipment_date', p_shipment_date,
      'customer_shipping_charge', p_customer_shipping_charge, 'expected_carrier_cost', v_expected_cost,
      'expected_carrier_cost_is_manual', v_is_manual, 'net_shipping_expected', v_net_shipping_expected,
      'customer_return_shipping_fee_version_id', v_return_fee_version_id,
      'customer_return_shipping_fee_standard_amount', v_return_fee_standard_amount,
      'customer_return_shipping_charge_is_override', v_return_fee_is_override,
      'is_cod', p_is_cod, 'created_on_closed_day', v_used_closed_day_override
    ),
    null
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'shipment.closed_day_override', 'shipment', v_shipment_id, null,
      jsonb_build_object('shipment_number', v_shipment_number, 'shipment_date', p_shipment_date, 'created_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  return query select v_shipment_id, v_shipment_number;
end;
$$;

comment on function public.create_shipment(uuid, uuid, date, text, uuid, uuid, numeric, uuid, text, text, text, text, text, text, boolean, numeric, numeric, text, text, text, text) is
  'Phase 5 (Section 34), extended by Patch 5.1 (0125): the single transactional entry point for creating a Shipment. As of 0125: a RETURN shipment (item 15/16) requires the linked sales_return to be currently ''approved'' (locked FOR UPDATE, closing the race against a concurrent reverse_sales_return() which locks the same row) and additionally resolves+snapshots the Customer Return Shipping Fee (customer_return_shipping_fee_version_id/standard_amount/is_override/override_reason, item 8/9) inside the same shared shipping-rates lock window used for the carrier-rate resolution. Never applies to outbound. SECURITY DEFINER.';

revoke execute on function public.create_shipment(uuid, uuid, date, text, uuid, uuid, numeric, uuid, text, text, text, text, text, text, boolean, numeric, numeric, text, text, text, text) from public;
grant execute on function public.create_shipment(uuid, uuid, date, text, uuid, uuid, numeric, uuid, text, text, text, text, text, text, boolean, numeric, numeric, text, text, text, text) to authenticated;

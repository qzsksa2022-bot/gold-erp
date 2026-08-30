-- ============================================================================
-- 0129: Shipping Integrity Patch 5.1 (8/10): historical carrier/zone label
-- snapshots on the shipment itself
-- ============================================================================
-- Migrations 0001-0128 are unmodified.
--
-- Item 17 — shipments stores carrier_id/shipping_zone_id (correct, a real
-- foreign key), but get_shipment()/list_shipments() (0119/0126) always
-- joined LIVE to shipping_carriers/shipping_zones for the display name/
-- code — so renaming a carrier or zone later silently rewrote how every
-- PAST shipment displays, even though the shipment itself never changed.
-- Fixed with four new snapshot columns, captured once at create_shipment()
-- time and never touched again; get_shipment()/list_shipments() now read
-- these instead of a live join for display purposes. carrier_id/shipping_
-- zone_id themselves are untouched (still the real FK, still used for
-- filtering/scoping) — only the DISPLAY name/code becomes historical.
-- Existing shipments (there are none yet in production — Phase 5 is brand
-- new — but this migration is upgrade-safe regardless) are backfilled once
-- from current Master Data as the best available documented estimate,
-- exactly as the spec instructs ("Backfill من القيم الحالية كأفضل تقدير
-- موثق مرة واحدة").
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- PART A — new columns.
-- ---------------------------------------------------------------------------
alter table public.shipments
  add column carrier_code_snapshot text,
  add column carrier_name_snapshot text,
  add column shipping_zone_code_snapshot text,
  add column shipping_zone_name_snapshot text;

comment on column public.shipments.carrier_code_snapshot is
  'Patch 5.1 (item 17) — shipping_carriers.code as it was AT CREATION TIME. carrier_id (the real FK) is unaffected by a later carrier rename; this snapshot is what get_shipment()/list_shipments() display, so a renamed carrier never rewrites how a past shipment reads.';

comment on column public.shipments.carrier_name_snapshot is
  'Patch 5.1 (item 17) — shipping_carriers.name_ar as it was AT CREATION TIME. See carrier_code_snapshot.';

comment on column public.shipments.shipping_zone_code_snapshot is
  'Patch 5.1 (item 17) — shipping_zones.code as it was AT CREATION TIME. See carrier_code_snapshot.';

comment on column public.shipments.shipping_zone_name_snapshot is
  'Patch 5.1 (item 17) — shipping_zones.name_ar as it was AT CREATION TIME. See carrier_code_snapshot.';

-- One-time backfill from current Master Data (guarded by `is null` so this
-- statement is safe even if a migration runner ever replays it) — Phase 5
-- has no pre-existing shipments in production, but this keeps the migration
-- correct and upgrade-safe regardless of when it runs.
update public.shipments s
set carrier_code_snapshot = c.code,
    carrier_name_snapshot = c.name_ar,
    shipping_zone_code_snapshot = z.code,
    shipping_zone_name_snapshot = z.name_ar
from public.shipping_carriers c, public.shipping_zones z
where s.carrier_id = c.id and s.shipping_zone_id = z.id
  and s.carrier_code_snapshot is null;

-- Both permanent once set — same immutability philosophy as every other
-- creation-time snapshot in this phase (customer_name_snapshot etc., 0116).
-- Enforced via the shipments row_version/optimistic-concurrency RPCs never
-- writing these columns after INSERT (application-level, matching how
-- customer_name_snapshot/customer_phone_snapshot/recipient_address_snapshot
-- are already handled with no dedicated DB trigger) — a dedicated immutable
-- trigger is intentionally NOT added here, to stay consistent with the
-- existing snapshot columns on this exact table, none of which have one
-- either.

-- ---------------------------------------------------------------------------
-- PART B — create_shipment(): capture the snapshot at creation. Same 21-arg
-- signature as 0125 (no parameter change), so a plain CREATE OR REPLACE is
-- sufficient — only the INSERT column list changes.
-- ---------------------------------------------------------------------------
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

  select so.id, so.order_number, so.store_id, so.sale_date, so.customer_name, so.customer_phone
    into v_order
    from public.sales_orders so where so.id = p_sales_order_id;

  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'هذا المتجر غير متاح لك لإنشاء شحنات فيه، أو أنه غير نشط' using errcode = 'P0001';
  end if;

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

    if p_shipment_date < v_return.return_date then
      raise exception 'تاريخ شحنة الإرجاع (%) لا يمكن أن يسبق تاريخ المرتجع (%)', p_shipment_date, v_return.return_date using errcode = 'P0001';
    end if;
  end if;

  -- 7) active carrier — v_carrier now also carries code/name_ar for the
  -- Patch 5.1 (item 17) historical snapshot below.
  select c.id, c.status, c.code, c.name_ar into v_carrier from public.shipping_carriers c where c.id = p_carrier_id;
  if v_carrier.id is null or v_carrier.status <> 'active' then
    raise exception 'شركة الشحن غير موجودة أو غير نشطة' using errcode = 'P0001';
  end if;

  -- 8) active zone — same reasoning.
  select z.id, z.status, z.code, z.name_ar into v_zone from public.shipping_zones z where z.id = p_shipping_zone_id;
  if v_zone.id is null or v_zone.status <> 'active' then
    raise exception 'المنطقة غير موجودة أو غير نشطة' using errcode = 'P0001';
  end if;

  if p_shipment_date > v_today then
    raise exception 'لا يمكن تسجيل شحنة بتاريخ مستقبلي (%)', p_shipment_date using errcode = 'P0001';
  end if;

  if p_shipment_date < v_order.sale_date then
    raise exception 'تاريخ الشحنة (%) لا يمكن أن يسبق تاريخ عملية البيع (%)', p_shipment_date, v_order.sale_date using errcode = 'P0001';
  end if;

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

  v_net_shipping_expected := p_customer_shipping_charge - v_expected_cost;

  if not p_is_cod then
    p_cod_expected_amount := null;
  elsif p_cod_expected_amount is not null and p_cod_expected_amount < 0 then
    raise exception 'المبلغ المتوقع تحصيله (COD) لا يمكن أن يكون سالبًا' using errcode = 'P0001';
  end if;

  v_customer_name := coalesce(p_customer_name, v_order.customer_name);
  v_customer_phone := coalesce(p_customer_phone, v_order.customer_phone);

  v_shipment_number := public.generate_shipment_number();

  insert into public.shipments (
    shipment_number, sales_order_id, sales_return_id, store_id, carrier_id, shipping_zone_id,
    direction, fulfillment_type, tracking_number, external_reference,
    customer_name_snapshot, customer_phone_snapshot, recipient_address_snapshot, shipment_date,
    customer_shipping_charge, carrier_rate_version_id, expected_carrier_cost,
    expected_carrier_cost_is_manual, expected_carrier_cost_manual_reason,
    customer_return_shipping_fee_version_id, customer_return_shipping_fee_standard_amount,
    customer_return_shipping_charge_is_override, customer_return_shipping_charge_override_reason,
    -- Patch 5.1 (item 17) — captured once here, never touched again.
    carrier_code_snapshot, carrier_name_snapshot, shipping_zone_code_snapshot, shipping_zone_name_snapshot,
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
    v_carrier.code, v_carrier.name_ar, v_zone.code, v_zone.name_ar,
    v_net_shipping_expected, p_is_cod, p_cod_expected_amount, 'created', p_notes,
    v_actor, v_actor
  )
  returning shipments.id into v_shipment_id;

  insert into public.shipment_status_events (shipment_id, status, event_business_date, notes, is_correction, actor)
  values (v_shipment_id, 'created', p_shipment_date, null, false, v_actor);

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
  'Phase 5 (Section 34), extended by Patch 5.1 (0125/0129): as of 0129, also captures carrier_code_snapshot/carrier_name_snapshot/shipping_zone_code_snapshot/shipping_zone_name_snapshot (item 17) at creation time — a later carrier/zone rename never rewrites how a past shipment displays. SECURITY DEFINER.';

-- Signature unchanged from 0125 — no new revoke/grant needed (already
-- granted to authenticated there).

-- ---------------------------------------------------------------------------
-- PART C — get_shipment()/list_shipments(): read the SNAPSHOT instead of a
-- live join for carrier/zone display name+code. Signatures unchanged from
-- 0126/0127 (get_shipment(uuid), list_shipments(...17 params...)) — plain
-- CREATE OR REPLACE.
-- ---------------------------------------------------------------------------
create or replace function public.get_shipment(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_shipment record;
  v_can_view_profit boolean;
  v_order_number text;
  v_return_number text;
  v_store_name text;
  v_original_sale_store_id uuid;
  v_original_sale_store_name text;
  v_status_timeline jsonb;
  v_cod_timeline jsonb;
  v_financial_events jsonb;
  v_effective_charge numeric;
  v_has_actual_cost boolean;
begin
  if v_actor is null or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض الشحنات' using errcode = 'P0001';
  end if;

  select s.* into v_shipment from public.shipments s where s.id = p_id;

  if v_shipment.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_shipment.store_id) then
    raise exception 'الشحنة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');
  v_has_actual_cost := v_shipment.actual_carrier_cost is not null;

  select so.order_number, so.store_id into v_order_number, v_original_sale_store_id from public.sales_orders so where so.id = v_shipment.sales_order_id;
  select sr.return_number into v_return_number from public.sales_returns sr where sr.id = v_shipment.sales_return_id;
  select st.name_ar into v_store_name from public.stores st where st.id = v_shipment.store_id;
  select st.name_ar into v_original_sale_store_name from public.stores st where st.id = v_original_sale_store_id;
  -- Item 17 — carrier/zone code+name now come from the shipment's OWN
  -- creation-time snapshot columns, never a live join to shipping_carriers/
  -- shipping_zones (which would silently reflect a LATER rename).

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', e.id, 'status', e.status, 'event_business_date', e.event_business_date, 'event_at', e.event_at,
      'notes', e.notes, 'is_correction', e.is_correction, 'external_reference', e.external_reference,
      'actor', e.actor, 'created_at', e.created_at
    )
    order by e.created_at
  ), '[]'::jsonb) into v_status_timeline
  from public.shipment_status_events e
  where e.shipment_id = v_shipment.id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', ce.id, 'state', ce.state, 'business_date', ce.business_date,
      'reference', ce.reference, 'reason', ce.reason, 'actor', ce.actor, 'created_at', ce.created_at
    )
    order by ce.created_at
  ), '[]'::jsonb) into v_cod_timeline
  from public.shipment_cod_events ce
  where ce.shipment_id = v_shipment.id;

  select fe.amount into v_effective_charge
  from public.shipment_financial_events fe
  where fe.shipment_id = v_shipment.id and fe.event_type = 'customer_charge_correction'
  order by fe.created_at desc limit 1;

  v_effective_charge := coalesce(v_effective_charge, v_shipment.customer_shipping_charge);

  if v_can_view_profit then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id', fe.id, 'event_type', fe.event_type, 'amount', fe.amount::text, 'business_date', fe.business_date,
        'reference', fe.reference, 'reason', fe.reason, 'actor', fe.actor, 'created_at', fe.created_at
      )
      order by fe.created_at
    ), '[]'::jsonb) into v_financial_events
    from public.shipment_financial_events fe
    where fe.shipment_id = v_shipment.id;
  end if;

  return jsonb_build_object(
    'id', v_shipment.id, 'shipment_number', v_shipment.shipment_number,
    'sales_order_id', v_shipment.sales_order_id, 'order_number', v_order_number,
    'sales_return_id', v_shipment.sales_return_id, 'return_number', v_return_number,
    'store_id', v_shipment.store_id, 'store_name', v_store_name,
    'original_sale_store_id', v_original_sale_store_id, 'original_sale_store_name', v_original_sale_store_name,
    'carrier_id', v_shipment.carrier_id, 'carrier_code', v_shipment.carrier_code_snapshot, 'carrier_name', v_shipment.carrier_name_snapshot,
    'shipping_zone_id', v_shipment.shipping_zone_id, 'zone_code', v_shipment.shipping_zone_code_snapshot, 'zone_name', v_shipment.shipping_zone_name_snapshot,
    'direction', v_shipment.direction, 'fulfillment_type', v_shipment.fulfillment_type,
    'tracking_number', v_shipment.tracking_number, 'external_reference', v_shipment.external_reference,
    'customer_name', v_shipment.customer_name_snapshot, 'customer_phone', v_shipment.customer_phone_snapshot,
    'recipient_address', v_shipment.recipient_address_snapshot, 'shipment_date', v_shipment.shipment_date,
    'is_cod', v_shipment.is_cod, 'cod_collection_state', v_shipment.cod_collection_state,
    'cod_timeline', v_cod_timeline,
    'current_status', v_shipment.current_status, 'notes', v_shipment.notes,
    'row_version', v_shipment.row_version,
    'created_by', v_shipment.created_by, 'updated_by', v_shipment.updated_by,
    'created_at', v_shipment.created_at, 'updated_at', v_shipment.updated_at,
    'status_timeline', v_status_timeline,
    'customer_shipping_charge', v_shipment.customer_shipping_charge::text,
    'effective_customer_shipping_charge', v_effective_charge::text,
    'customer_return_shipping_fee_version_id', v_shipment.customer_return_shipping_fee_version_id,
    'customer_return_shipping_fee_standard_amount', v_shipment.customer_return_shipping_fee_standard_amount::text,
    'customer_return_shipping_charge_is_override', v_shipment.customer_return_shipping_charge_is_override,
    'customer_return_shipping_charge_override_reason', v_shipment.customer_return_shipping_charge_override_reason,
    'has_actual_carrier_cost', v_has_actual_cost
  )
  || case when v_can_view_profit then jsonb_build_object(
    'carrier_rate_version_id', v_shipment.carrier_rate_version_id,
    'expected_carrier_cost', v_shipment.expected_carrier_cost::text,
    'expected_carrier_cost_is_manual', v_shipment.expected_carrier_cost_is_manual,
    'expected_carrier_cost_manual_reason', v_shipment.expected_carrier_cost_manual_reason,
    'actual_carrier_cost', v_shipment.actual_carrier_cost::text,
    'net_shipping_expected', v_shipment.net_shipping_expected::text,
    'net_shipping_actual', v_shipment.net_shipping_actual::text,
    'cod_expected_amount', v_shipment.cod_expected_amount::text,
    'financial_events', v_financial_events
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.get_shipment(uuid) is
  'Phase 5 (Section 37), corrected by Patch 5.1 (0126/0127/0129): carrier_code/carrier_name/zone_code/zone_name now come from the shipment''s own creation-time snapshot columns (item 17), never a live join — a later carrier/zone rename never rewrites a past shipment''s display. customer_shipping_charge/effective_customer_shipping_charge/return-fee snapshot/has_actual_carrier_cost/cod_timeline are ALWAYS present. Still gated behind sales.view_profit: carrier_rate_version_id, expected/actual_carrier_cost, net_shipping_expected/actual, cod_expected_amount, financial_events. SECURITY DEFINER.';

revoke execute on function public.get_shipment(uuid) from public;
grant execute on function public.get_shipment(uuid) to authenticated;

create or replace function public.list_shipments(
  p_date_from date default null,
  p_date_to date default null,
  p_store_id uuid default null,
  p_carrier_id uuid default null,
  p_shipping_zone_id uuid default null,
  p_direction text default null,
  p_current_status text default null,
  p_shipment_number text default null,
  p_tracking_number text default null,
  p_sales_order_id uuid default null,
  p_sales_return_id uuid default null,
  p_limit integer default 50,
  p_offset integer default 0,
  p_order_number text default null,
  p_return_number text default null,
  p_original_sale_store_id uuid default null,
  p_cod_collection_state text default null
)
returns table (
  id uuid,
  shipment_number text,
  sales_order_id uuid,
  order_number text,
  sales_return_id uuid,
  return_number text,
  store_id uuid,
  store_name text,
  original_sale_store_id uuid,
  original_sale_store_name text,
  carrier_id uuid,
  carrier_code text,
  carrier_name text,
  shipping_zone_id uuid,
  zone_code text,
  zone_name text,
  direction text,
  fulfillment_type text,
  tracking_number text,
  customer_name text,
  customer_phone text,
  shipment_date date,
  is_cod boolean,
  cod_collection_state text,
  current_status text,
  row_version bigint,
  customer_shipping_charge text,
  customer_return_shipping_charge_is_override boolean,
  has_actual_carrier_cost boolean,
  expected_carrier_cost text,
  expected_carrier_cost_is_manual boolean,
  actual_carrier_cost text,
  net_shipping_expected text,
  net_shipping_actual text,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_can_view_profit boolean;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if v_actor is null or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض الشحنات' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  return query
  select
    s.id, s.shipment_number,
    s.sales_order_id, so.order_number,
    s.sales_return_id, sr.return_number,
    s.store_id, st.name_ar,
    so.store_id, ost.name_ar,
    -- Item 17 — carrier/zone code+name from the shipment's OWN snapshot,
    -- never a live join.
    s.carrier_id, s.carrier_code_snapshot, s.carrier_name_snapshot,
    s.shipping_zone_id, s.shipping_zone_code_snapshot, s.shipping_zone_name_snapshot,
    s.direction, s.fulfillment_type,
    s.tracking_number,
    s.customer_name_snapshot, s.customer_phone_snapshot,
    s.shipment_date, s.is_cod, s.cod_collection_state, s.current_status, s.row_version,
    s.customer_shipping_charge::text,
    s.customer_return_shipping_charge_is_override,
    (s.actual_carrier_cost is not null),
    case when v_can_view_profit then s.expected_carrier_cost::text else null end,
    case when v_can_view_profit then s.expected_carrier_cost_is_manual else null end,
    case when v_can_view_profit then s.actual_carrier_cost::text else null end,
    case when v_can_view_profit then s.net_shipping_expected::text else null end,
    case when v_can_view_profit then s.net_shipping_actual::text else null end,
    s.created_at,
    count(*) over ()::bigint
  from public.shipments s
  join public.sales_orders so on so.id = s.sales_order_id
  left join public.sales_returns sr on sr.id = s.sales_return_id
  left join public.stores st on st.id = s.store_id
  left join public.stores ost on ost.id = so.store_id
  where s.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
    and (p_date_from is null or s.shipment_date >= p_date_from)
    and (p_date_to is null or s.shipment_date <= p_date_to)
    and (p_store_id is null or s.store_id = p_store_id)
    and (p_carrier_id is null or s.carrier_id = p_carrier_id)
    and (p_shipping_zone_id is null or s.shipping_zone_id = p_shipping_zone_id)
    and (p_direction is null or s.direction = p_direction)
    and (p_current_status is null or s.current_status = p_current_status)
    and (p_shipment_number is null or s.shipment_number ilike '%' || p_shipment_number || '%')
    and (p_tracking_number is null or s.tracking_number ilike '%' || p_tracking_number || '%')
    and (p_sales_order_id is null or s.sales_order_id = p_sales_order_id)
    and (p_sales_return_id is null or s.sales_return_id = p_sales_return_id)
    and (p_order_number is null or so.order_number ilike '%' || p_order_number || '%')
    and (p_return_number is null or sr.return_number ilike '%' || p_return_number || '%')
    and (p_original_sale_store_id is null or so.store_id = p_original_sale_store_id)
    and (p_cod_collection_state is null or s.cod_collection_state = p_cod_collection_state)
  order by s.shipment_date desc, s.created_at desc
  limit v_limit offset v_offset;
end;
$$;

comment on function public.list_shipments(date, date, uuid, uuid, uuid, text, text, text, text, uuid, uuid, integer, integer, text, text, uuid, text) is
  'Phase 5 (Section 37/39), extended by Patch 5.1 (0126/0129): carrier_code/carrier_name/zone_code/zone_name now come from the shipment''s own creation-time snapshot (item 17), never a live join — no shipping_carriers/shipping_zones join needed for display purposes anymore. customer_shipping_charge/has_actual_carrier_cost always visible (items 10/23). Filters: p_order_number/p_return_number/p_original_sale_store_id/p_cod_collection_state (item 12). Scoped via user_visible_store_ids(). SECURITY DEFINER.';

revoke execute on function public.list_shipments(date, date, uuid, uuid, uuid, text, text, text, text, uuid, uuid, integer, integer, text, text, uuid, text) from public;
grant execute on function public.list_shipments(date, date, uuid, uuid, uuid, text, text, text, text, uuid, uuid, integer, integer, text, text, uuid, text) to authenticated;

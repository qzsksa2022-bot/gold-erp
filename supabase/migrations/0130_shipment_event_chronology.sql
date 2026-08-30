-- ============================================================================
-- 0130: Shipping Integrity Patch 5.1 (9/10): event business-date chronology
-- ============================================================================
-- Migrations 0001-0129 are unmodified.
--
-- Item 18 — every write RPC already rejected a FUTURE business_date, but
-- none rejected a business_date BEFORE the shipment's own shipment_date
-- (e.g. a status event dated before the shipment existed, or an actual-cost
-- correction dated before the shipment's creation date, or even before an
-- earlier actual-cost event in the same ledger). record_shipment_cod_
-- collection_state() (0127) already got this check when it was written;
-- this migration retrofits the same rule onto the four pre-existing write
-- RPCs (CREATE OR REPLACE, all four signatures UNCHANGED from 0118 — no
-- DROP needed):
--   add_shipment_status_event()        — event_business_date >= shipment_date
--   record_shipment_actual_cost()      — business_date >= shipment_date
--   correct_shipment_actual_cost()     — business_date >= shipment_date AND
--                                         >= the latest existing actual-cost
--                                         event's business_date (never
--                                         backdate a correction before the
--                                         ledger entry it is correcting)
--   correct_shipment_customer_charge() — business_date >= shipment_date
-- All four already reject a future date (Asia/Riyadh, via business_today())
-- — that upper bound is unchanged.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- add_shipment_status_event()
-- ---------------------------------------------------------------------------
create or replace function public.add_shipment_status_event(
  p_shipment_id uuid,
  p_new_status text,
  p_expected_version bigint,
  p_event_business_date date,
  p_notes text default null,
  p_external_reference text default null,
  p_reason text default null
)
returns table (row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_shipment record;
  v_is_normal boolean;
  v_is_correction boolean;
  v_new_row_version bigint;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتحديث حالة الشحنة' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_shipment_id is null or p_new_status is null or p_expected_version is null or p_event_business_date is null then
    raise exception 'الشحنة والحالة الجديدة وإصدار السجل وتاريخ الحدث كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_new_status not in (
    'created', 'ready_for_pickup', 'picked_up', 'in_transit', 'out_for_delivery',
    'delivered', 'delivery_failed', 'customer_refused', 'customer_never_received',
    'returned_to_store', 'cancelled'
  ) then
    raise exception 'حالة الشحنة غير صالحة' using errcode = 'P0001';
  end if;

  select s.* into v_shipment from public.shipments s where s.id = p_shipment_id for update;

  if v_shipment.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_shipment.store_id) then
    raise exception 'الشحنة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if v_shipment.row_version <> p_expected_version then
    raise exception 'تم تعديل هذه الشحنة من قِبل مستخدم آخر — يرجى إعادة تحميل البيانات والمحاولة مجددًا (الإصدار المتوقع %، الإصدار الحالي %)', p_expected_version, v_shipment.row_version
      using errcode = 'P0001';
  end if;

  v_is_normal := public.validate_shipment_status_transition(v_shipment.current_status, p_new_status);
  v_is_correction := not v_is_normal;

  if v_is_normal then
    if not public.has_permission('shipments.update_status') then
      raise exception 'ليست لديك صلاحية تحديث حالة الشحنة' using errcode = 'P0001';
    end if;
  else
    if not public.has_permission('shipments.correct_status') then
      raise exception 'هذا الانتقال (% -> %) يتطلب تصحيح حالة، ولا تملك صلاحية shipments.correct_status', v_shipment.current_status, p_new_status
        using errcode = 'P0001';
    end if;

    if p_reason is null or btrim(p_reason) = '' then
      raise exception 'يجب إدخال سبب لتصحيح حالة الشحنة (الانتقال % -> % ليس ضمن التدفق الطبيعي)', v_shipment.current_status, p_new_status
        using errcode = 'P0001';
    end if;
  end if;

  if p_event_business_date > public.business_today() then
    raise exception 'لا يمكن تسجيل حدث حالة بتاريخ مستقبلي (%)', p_event_business_date using errcode = 'P0001';
  end if;

  -- Patch 5.1 item 18 — chronology lower bound.
  if p_event_business_date < v_shipment.shipment_date then
    raise exception 'لا يمكن أن يكون تاريخ حدث الحالة (%) قبل تاريخ الشحنة نفسها (%)', p_event_business_date, v_shipment.shipment_date using errcode = 'P0001';
  end if;

  insert into public.shipment_status_events (shipment_id, status, event_business_date, notes, is_correction, external_reference, actor)
  values (
    p_shipment_id, p_new_status, p_event_business_date,
    case when v_is_correction then
      'تصحيح: ' || p_reason || case when p_notes is not null and btrim(p_notes) <> '' then ' — ' || p_notes else '' end
    else p_notes end,
    v_is_correction, p_external_reference, v_actor
  );

  v_new_row_version := v_shipment.row_version + 1;

  update public.shipments
  set current_status = p_new_status, updated_by = v_actor, row_version = v_new_row_version
  where id = p_shipment_id;

  perform public.log_audit_event(
    'shipment.status_add', 'shipment', p_shipment_id, jsonb_build_object('current_status', v_shipment.current_status),
    jsonb_build_object(
      'current_status', p_new_status, 'is_correction', v_is_correction,
      'event_business_date', p_event_business_date, 'external_reference', p_external_reference
    ),
    case when v_is_correction then p_reason else null end
  );

  return query select v_new_row_version;
end;
$$;

comment on function public.add_shipment_status_event(uuid, text, bigint, date, text, text, text) is
  'Phase 5 (Section 13/14/35), extended by Patch 5.1 item 18 (0130): event_business_date must now be >= shipments.shipment_date, in addition to the pre-existing "not in the future" bound. Same permission/optimistic-concurrency/store-scope shape as before. SECURITY DEFINER.';

-- Signature unchanged — grants already in place from 0118.

-- ---------------------------------------------------------------------------
-- record_shipment_actual_cost()
-- ---------------------------------------------------------------------------
create or replace function public.record_shipment_actual_cost(
  p_shipment_id uuid,
  p_expected_version bigint,
  p_amount numeric,
  p_business_date date,
  p_reference text default null,
  p_notes text default null,
  p_closed_day_reason text default null
)
returns table (row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_shipment record;
  v_already_recorded boolean;
  v_effective_charge numeric;
  v_new_net_actual numeric;
  v_new_row_version bigint;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتسجيل التكلفة الفعلية' using errcode = 'P0001';
  end if;

  if not public.has_permission('shipments.manage_cost') then
    raise exception 'ليست لديك صلاحية إدارة تكلفة الشحن' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_shipment_id is null or p_expected_version is null or p_amount is null or p_business_date is null then
    raise exception 'الشحنة وإصدار السجل والمبلغ وتاريخ العملية المالية كلها مطلوبة' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_amount, 'التكلفة الفعلية للشحن');

  if p_amount < 0 then
    raise exception 'التكلفة الفعلية للشحن لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  if p_business_date > public.business_today() then
    raise exception 'لا يمكن تسجيل تكلفة فعلية بتاريخ مستقبلي (%)', p_business_date using errcode = 'P0001';
  end if;

  select s.* into v_shipment from public.shipments s where s.id = p_shipment_id for update;

  if v_shipment.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_shipment.store_id) then
    raise exception 'الشحنة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if v_shipment.row_version <> p_expected_version then
    raise exception 'تم تعديل هذه الشحنة من قِبل مستخدم آخر — يرجى إعادة تحميل البيانات والمحاولة مجددًا (الإصدار المتوقع %، الإصدار الحالي %)', p_expected_version, v_shipment.row_version
      using errcode = 'P0001';
  end if;

  -- Patch 5.1 item 18 — chronology lower bound.
  if p_business_date < v_shipment.shipment_date then
    raise exception 'لا يمكن أن يكون تاريخ التكلفة الفعلية (%) قبل تاريخ الشحنة نفسها (%)', p_business_date, v_shipment.shipment_date using errcode = 'P0001';
  end if;

  select exists (
    select 1 from public.shipment_financial_events fe
    where fe.shipment_id = p_shipment_id and fe.event_type in ('actual_cost_recorded', 'actual_cost_correction')
  ) into v_already_recorded;

  if v_already_recorded then
    raise exception 'تم تسجيل تكلفة فعلية لهذه الشحنة سابقًا — استخدم تصحيح التكلفة الفعلية (correct_shipment_actual_cost) بدلًا من ذلك' using errcode = 'P0001';
  end if;

  perform public.acquire_daily_close_lock_shared(v_shipment.store_id, p_business_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = v_shipment.store_id and dc.business_date = p_business_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('shipments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن تسجيل تكلفة فعلية فيه إلا بصلاحية خاصة (shipments.process_closed_day)', p_business_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتسجيل تكلفة فعلية في يوم مقفل' using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  insert into public.shipment_financial_events (shipment_id, event_type, amount, business_date, reference, reason, actor)
  values (p_shipment_id, 'actual_cost_recorded', p_amount, p_business_date, p_reference, p_notes, v_actor);

  select fe.amount into v_effective_charge
  from public.shipment_financial_events fe
  where fe.shipment_id = p_shipment_id and fe.event_type = 'customer_charge_correction'
  order by fe.created_at desc limit 1;

  v_effective_charge := coalesce(v_effective_charge, v_shipment.customer_shipping_charge);
  v_new_net_actual := v_effective_charge - p_amount;
  v_new_row_version := v_shipment.row_version + 1;

  update public.shipments
  set actual_carrier_cost = p_amount, net_shipping_actual = v_new_net_actual,
      updated_by = v_actor, row_version = v_new_row_version
  where id = p_shipment_id;

  perform public.log_audit_event(
    'shipment.cost_record', 'shipment', p_shipment_id, null,
    jsonb_build_object(
      'amount', p_amount, 'business_date', p_business_date, 'reference', p_reference,
      'net_shipping_actual', v_new_net_actual, 'recorded_on_closed_day', v_used_closed_day_override
    ),
    null
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'shipment.closed_day_override', 'shipment', p_shipment_id, null,
      jsonb_build_object('business_date', p_business_date, 'action', 'cost_record'),
      p_closed_day_reason
    );
  end if;

  return query select v_new_row_version;
end;
$$;

comment on function public.record_shipment_actual_cost(uuid, bigint, numeric, date, text, text, text) is
  'Phase 5 (Section 18/36), extended by Patch 5.1 item 18 (0130): p_business_date must now be >= shipments.shipment_date. Same permission/Daily-Close/scope/concurrency shape as before. SECURITY DEFINER.';

-- ---------------------------------------------------------------------------
-- correct_shipment_actual_cost() — also enforced against the LATEST existing
-- actual-cost ledger entry''s own business_date (never backdate a correction
-- before the entry it is correcting).
-- ---------------------------------------------------------------------------
create or replace function public.correct_shipment_actual_cost(
  p_shipment_id uuid,
  p_expected_version bigint,
  p_amount numeric,
  p_business_date date,
  p_reason text,
  p_reference text default null,
  p_closed_day_reason text default null
)
returns table (row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_shipment record;
  v_already_recorded boolean;
  v_latest_cost_event_date date;
  v_effective_charge numeric;
  v_new_net_actual numeric;
  v_new_row_version bigint;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتصحيح التكلفة الفعلية' using errcode = 'P0001';
  end if;

  if not public.has_permission('shipments.manage_cost') then
    raise exception 'ليست لديك صلاحية إدارة تكلفة الشحن' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_shipment_id is null or p_expected_version is null or p_amount is null or p_business_date is null then
    raise exception 'الشحنة وإصدار السجل والمبلغ وتاريخ العملية المالية كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'يجب إدخال سبب لتصحيح التكلفة الفعلية' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_amount, 'التكلفة الفعلية للشحن');

  if p_amount < 0 then
    raise exception 'التكلفة الفعلية للشحن لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  if p_business_date > public.business_today() then
    raise exception 'لا يمكن تسجيل تصحيح بتاريخ مستقبلي (%)', p_business_date using errcode = 'P0001';
  end if;

  select s.* into v_shipment from public.shipments s where s.id = p_shipment_id for update;

  if v_shipment.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_shipment.store_id) then
    raise exception 'الشحنة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if v_shipment.row_version <> p_expected_version then
    raise exception 'تم تعديل هذه الشحنة من قِبل مستخدم آخر — يرجى إعادة تحميل البيانات والمحاولة مجددًا (الإصدار المتوقع %، الإصدار الحالي %)', p_expected_version, v_shipment.row_version
      using errcode = 'P0001';
  end if;

  -- Patch 5.1 item 18 — chronology lower bound: never before the shipment
  -- itself, and never before the LATEST existing actual-cost ledger entry
  -- (whether the original recording or a prior correction) — a correction
  -- must always extend the ledger's timeline forward, never insert itself
  -- earlier than an entry it is meant to correct.
  if p_business_date < v_shipment.shipment_date then
    raise exception 'لا يمكن أن يكون تاريخ التصحيح (%) قبل تاريخ الشحنة نفسها (%)', p_business_date, v_shipment.shipment_date using errcode = 'P0001';
  end if;

  select max(fe.business_date) into v_latest_cost_event_date
  from public.shipment_financial_events fe
  where fe.shipment_id = p_shipment_id and fe.event_type in ('actual_cost_recorded', 'actual_cost_correction');

  if v_latest_cost_event_date is not null and p_business_date < v_latest_cost_event_date then
    raise exception 'لا يمكن أن يكون تاريخ التصحيح (%) قبل تاريخ آخر عملية تكلفة فعلية مسجَّلة لهذه الشحنة (%)', p_business_date, v_latest_cost_event_date using errcode = 'P0001';
  end if;

  select exists (
    select 1 from public.shipment_financial_events fe
    where fe.shipment_id = p_shipment_id and fe.event_type in ('actual_cost_recorded', 'actual_cost_correction')
  ) into v_already_recorded;

  if not v_already_recorded then
    raise exception 'لا توجد تكلفة فعلية مسجَّلة لهذه الشحنة بعد — استخدم تسجيل التكلفة الفعلية (record_shipment_actual_cost) أولًا' using errcode = 'P0001';
  end if;

  perform public.acquire_daily_close_lock_shared(v_shipment.store_id, p_business_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = v_shipment.store_id and dc.business_date = p_business_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('shipments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن تصحيح تكلفة فعلية فيه إلا بصلاحية خاصة (shipments.process_closed_day)', p_business_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتصحيح تكلفة فعلية في يوم مقفل' using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  insert into public.shipment_financial_events (shipment_id, event_type, amount, business_date, reference, reason, actor)
  values (p_shipment_id, 'actual_cost_correction', p_amount, p_business_date, p_reference, p_reason, v_actor);

  select fe.amount into v_effective_charge
  from public.shipment_financial_events fe
  where fe.shipment_id = p_shipment_id and fe.event_type = 'customer_charge_correction'
  order by fe.created_at desc limit 1;

  v_effective_charge := coalesce(v_effective_charge, v_shipment.customer_shipping_charge);
  v_new_net_actual := v_effective_charge - p_amount;
  v_new_row_version := v_shipment.row_version + 1;

  update public.shipments
  set actual_carrier_cost = p_amount, net_shipping_actual = v_new_net_actual,
      updated_by = v_actor, row_version = v_new_row_version
  where id = p_shipment_id;

  perform public.log_audit_event(
    'shipment.cost_correct', 'shipment', p_shipment_id,
    jsonb_build_object('actual_carrier_cost', v_shipment.actual_carrier_cost, 'net_shipping_actual', v_shipment.net_shipping_actual),
    jsonb_build_object(
      'amount', p_amount, 'business_date', p_business_date, 'reference', p_reference,
      'net_shipping_actual', v_new_net_actual, 'corrected_on_closed_day', v_used_closed_day_override
    ),
    p_reason
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'shipment.closed_day_override', 'shipment', p_shipment_id, null,
      jsonb_build_object('business_date', p_business_date, 'action', 'cost_correct'),
      p_closed_day_reason
    );
  end if;

  return query select v_new_row_version;
end;
$$;

comment on function public.correct_shipment_actual_cost(uuid, bigint, numeric, date, text, text, text) is
  'Phase 5 (Section 18/36), extended by Patch 5.1 item 18 (0130): p_business_date must now be >= shipments.shipment_date AND >= the latest existing actual-cost ledger entry''s own business_date (never backdate a correction before the entry it corrects). Same permission/Daily-Close/scope/concurrency shape as before. SECURITY DEFINER.';

-- ---------------------------------------------------------------------------
-- correct_shipment_customer_charge()
-- ---------------------------------------------------------------------------
create or replace function public.correct_shipment_customer_charge(
  p_shipment_id uuid,
  p_expected_version bigint,
  p_amount numeric,
  p_business_date date,
  p_reason text,
  p_reference text default null,
  p_closed_day_reason text default null
)
returns table (row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_shipment record;
  v_new_net_expected numeric;
  v_new_net_actual numeric;
  v_new_row_version bigint;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتصحيح رسوم الشحن على العميل' using errcode = 'P0001';
  end if;

  if not public.has_permission('shipments.manage_cost') then
    raise exception 'ليست لديك صلاحية إدارة تكلفة/رسوم الشحن' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_shipment_id is null or p_expected_version is null or p_amount is null or p_business_date is null then
    raise exception 'الشحنة وإصدار السجل والمبلغ وتاريخ العملية المالية كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'يجب إدخال سبب لتصحيح رسوم الشحن على العميل' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_amount, 'رسوم الشحن على العميل');

  if p_amount < 0 then
    raise exception 'رسوم الشحن على العميل لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  if p_business_date > public.business_today() then
    raise exception 'لا يمكن تسجيل تصحيح بتاريخ مستقبلي (%)', p_business_date using errcode = 'P0001';
  end if;

  select s.* into v_shipment from public.shipments s where s.id = p_shipment_id for update;

  if v_shipment.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_shipment.store_id) then
    raise exception 'الشحنة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if v_shipment.row_version <> p_expected_version then
    raise exception 'تم تعديل هذه الشحنة من قِبل مستخدم آخر — يرجى إعادة تحميل البيانات والمحاولة مجددًا (الإصدار المتوقع %، الإصدار الحالي %)', p_expected_version, v_shipment.row_version
      using errcode = 'P0001';
  end if;

  -- Patch 5.1 item 18 — chronology lower bound.
  if p_business_date < v_shipment.shipment_date then
    raise exception 'لا يمكن أن يكون تاريخ التصحيح (%) قبل تاريخ الشحنة نفسها (%)', p_business_date, v_shipment.shipment_date using errcode = 'P0001';
  end if;

  perform public.acquire_daily_close_lock_shared(v_shipment.store_id, p_business_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = v_shipment.store_id and dc.business_date = p_business_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('shipments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن تصحيح رسوم الشحن على العميل فيه إلا بصلاحية خاصة (shipments.process_closed_day)', p_business_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتصحيح رسوم الشحن على العميل في يوم مقفل' using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  insert into public.shipment_financial_events (shipment_id, event_type, amount, business_date, reference, reason, actor)
  values (p_shipment_id, 'customer_charge_correction', p_amount, p_business_date, p_reference, p_reason, v_actor);

  v_new_net_expected := p_amount - v_shipment.expected_carrier_cost;
  v_new_net_actual := case when v_shipment.actual_carrier_cost is not null then p_amount - v_shipment.actual_carrier_cost else null end;
  v_new_row_version := v_shipment.row_version + 1;

  update public.shipments
  set net_shipping_expected = v_new_net_expected, net_shipping_actual = v_new_net_actual,
      updated_by = v_actor, row_version = v_new_row_version
  where id = p_shipment_id;

  perform public.log_audit_event(
    'shipment.charge_correct', 'shipment', p_shipment_id,
    jsonb_build_object(
      'customer_shipping_charge_snapshot', v_shipment.customer_shipping_charge,
      'net_shipping_expected', v_shipment.net_shipping_expected, 'net_shipping_actual', v_shipment.net_shipping_actual
    ),
    jsonb_build_object(
      'amount', p_amount, 'business_date', p_business_date, 'reference', p_reference,
      'net_shipping_expected', v_new_net_expected, 'net_shipping_actual', v_new_net_actual,
      'corrected_on_closed_day', v_used_closed_day_override
    ),
    p_reason
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'shipment.closed_day_override', 'shipment', p_shipment_id, null,
      jsonb_build_object('business_date', p_business_date, 'action', 'charge_correct'),
      p_closed_day_reason
    );
  end if;

  return query select v_new_row_version;
end;
$$;

comment on function public.correct_shipment_customer_charge(uuid, bigint, numeric, date, text, text, text) is
  'Phase 5 (Section 20/33), extended by Patch 5.1 item 18 (0130): p_business_date must now be >= shipments.shipment_date. Same permission/Daily-Close/scope/concurrency shape as before. SECURITY DEFINER.';

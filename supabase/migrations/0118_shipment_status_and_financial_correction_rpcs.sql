-- ============================================================================
-- 0118: Phase 5 — Shipping Core (6/9): add_shipment_status_event(),
-- record_shipment_actual_cost(), correct_shipment_actual_cost(),
-- correct_shipment_customer_charge()
-- ============================================================================
-- Migrations 0001-0117 are unmodified.
--
-- All four RPCs here mutate an EXISTING shipment (never create one), so —
-- per the established Sales/Returns convention (0075's own comment block:
-- "changes the store-scope check from user_operable_store_ids() to user_
-- visible_store_ids() so a store disabled after a Sale was created no
-- longer blocks correcting that historical Sale") — every one of them uses
-- user_visible_store_ids(), not user_operable_store_ids(). Every one also
-- follows the SAME optimistic-concurrency shape as update_sales_order()
-- (0075): lock the shipment row `for update` FIRST, THEN compare row_version
-- against p_expected_version (never the reverse — locking first guarantees
-- the row_version being compared is the latest committed value), reject a
-- stale caller with a clear Arabic Conflict message, then row_version+1 on
-- success.
--
-- Design decision — "effective customer shipping charge": shipments.
-- customer_shipping_charge (0116) is an immutable creation-time snapshot
-- (Section 20) and is NEVER overwritten here. The three financial RPCs
-- below instead maintain shipments.net_shipping_expected/net_shipping_
-- actual as CACHES of the current effective figures (mirroring how
-- shipments.actual_carrier_cost is documented in 0116 as "the amount of the
-- latest actual_cost_recorded/actual_cost_correction row") — recomputed
-- from the latest customer_charge_correction event (if any) and the latest
-- actual-cost event (if any) every time either ledger gets a new row. Full
-- point-in-time history always remains reconstructable from shipment_
-- financial_events regardless of what the cache currently shows.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- add_shipment_status_event() — Section 35.
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

  -- Lock FIRST, then compare row_version against the just-locked (therefore
  -- latest-committed) row (0075's fix for the classic Lost-Update gap).
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

  -- Append-only status event. `notes` carries the free-text note for a
  -- normal transition; for a correction, the MANDATORY p_reason is stored
  -- in `notes` too (this table has no separate reason column — the event
  -- IS the append-only reason record), prefixed so it reads unambiguously
  -- in the timeline even alongside an optional p_notes.
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

  -- 'shipment.status_add' — deliberately ungated in audit_logs RLS (0121):
  -- a status/tracking event carries no financial figures, unlike
  -- shipment.create/cost_record/cost_correct/charge_correct.
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
  'Phase 5 (Section 13/14/35) — appends a status_event and transactionally advances shipments.current_status (the cache). A NORMAL forward transition (validate_shipment_status_transition(), 0116) needs only shipments.update_status; any other transition (including re-appending the current status, or moving off a terminal status) is a CORRECTION — needs shipments.correct_status AND a non-empty p_reason, and is tagged is_correction=true. Optimistic concurrency via row_version, same lock-then-compare shape as update_sales_order() (0075). Store-scope: user_visible_store_ids() (this mutates an EXISTING shipment, not a new one). No Daily Close gating — a status/tracking update carries no financial figures. SECURITY DEFINER.';

revoke execute on function public.add_shipment_status_event(uuid, text, bigint, date, text, text, text) from public;
grant execute on function public.add_shipment_status_event(uuid, text, bigint, date, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- record_shipment_actual_cost() — Section 18/36: the FIRST-time recording of
-- the real carrier invoice amount. Rejects if one already exists (use
-- correct_shipment_actual_cost() instead).
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

  select exists (
    select 1 from public.shipment_financial_events fe
    where fe.shipment_id = p_shipment_id and fe.event_type in ('actual_cost_recorded', 'actual_cost_correction')
  ) into v_already_recorded;

  if v_already_recorded then
    raise exception 'تم تسجيل تكلفة فعلية لهذه الشحنة سابقًا — استخدم تصحيح التكلفة الفعلية (correct_shipment_actual_cost) بدلًا من ذلك' using errcode = 'P0001';
  end if;

  -- Daily Close — shared lock + gating on the COST's own business_date
  -- (Section 28), which may differ from shipments.shipment_date.
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

  -- Effective customer charge = latest customer_charge_correction, else the
  -- immutable creation-time snapshot (see this migration's header comment).
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

  -- 'shipment.cost_record' carries a financial figure -> gated behind
  -- sales.view_profit in audit_logs RLS (0121), like shipment.create.
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
  'Phase 5 (Section 18/36) — records the FIRST real carrier invoice amount for a shipment. Rejects if any actual-cost event already exists for it (use correct_shipment_actual_cost() instead — this keeps "first recording" vs "correction" as two distinct, unambiguous operations rather than one upsert). Appends shipment_financial_events(event_type=actual_cost_recorded), updates the shipments.actual_carrier_cost/net_shipping_actual caches, gated on shipments.manage_cost, Daily Close checked against p_business_date (not shipment_date), user_visible_store_ids() scope, optimistic concurrency via row_version. SECURITY DEFINER.';

revoke execute on function public.record_shipment_actual_cost(uuid, bigint, numeric, date, text, text, text) from public;
grant execute on function public.record_shipment_actual_cost(uuid, bigint, numeric, date, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- correct_shipment_actual_cost() — Section 18/36: mandatory-reason
-- correction to an ALREADY-recorded actual cost. Never overwrites/deletes
-- the prior event — appends a new one.
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
  'Phase 5 (Section 18/36) — mandatory-reason correction to an ALREADY-recorded actual carrier cost. Requires a prior actual_cost_recorded/actual_cost_correction event to exist (else use record_shipment_actual_cost() first). NEVER overwrites the prior shipment_financial_events row — appends a new event_type=actual_cost_correction row, then recomputes the shipments.actual_carrier_cost/net_shipping_actual caches from it. Same permission/scope/lock/Daily-Close shape as record_shipment_actual_cost(). SECURITY DEFINER.';

revoke execute on function public.correct_shipment_actual_cost(uuid, bigint, numeric, date, text, text, text) from public;
grant execute on function public.correct_shipment_actual_cost(uuid, bigint, numeric, date, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- correct_shipment_customer_charge() — Section 20/33: mandatory-reason
-- correction to the ORIGINAL customer_shipping_charge snapshot. The
-- original shipments.customer_shipping_charge column is NEVER overwritten
-- (Section 20 — "explicit snapshot"); only the append-only ledger + the
-- net_shipping_expected/net_shipping_actual caches change.
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

  -- Never touches sales_returns financial history (Section 8/20) — this is
  -- Shipping Revenue only, and never overwrites shipments.customer_shipping_
  -- charge itself (immutable creation-time snapshot).
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
  'Phase 5 (Section 20/33) — mandatory-reason correction to the customer-facing shipping charge. shipments.customer_shipping_charge (the creation-time snapshot) is NEVER overwritten; only shipment_financial_events(event_type=customer_charge_correction) gains a new row and the net_shipping_expected/net_shipping_actual caches are recomputed from it (against the unchanged expected/actual carrier cost). Entirely Shipping Revenue — never touches sales_returns.non_shipping_deduction_amount or any Sales Return financial history. Same permission (shipments.manage_cost)/scope/lock/Daily-Close shape as the actual-cost RPCs. SECURITY DEFINER.';

revoke execute on function public.correct_shipment_customer_charge(uuid, bigint, numeric, date, text, text, text) from public;
grant execute on function public.correct_shipment_customer_charge(uuid, bigint, numeric, date, text, text, text) to authenticated;

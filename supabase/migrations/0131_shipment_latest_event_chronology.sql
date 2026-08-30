-- ============================================================================
-- 0131: Final Shipping Hotfix 5.1.1 (1/2): monotonic chronology relative to
-- the LATEST existing event of the same stream, not just shipment_date
-- ============================================================================
-- Migrations 0001-0130 are unmodified.
--
-- Gap found on source-level review of 0130 (Patch 5.1 item 18): 0130 added
-- a chronology lower bound to every Shipping write RPC, but for
-- add_shipment_status_event()/record_shipment_cod_collection_state() that
-- bound was ONLY "event_business_date >= shipments.shipment_date" — it
-- never compared a new event against the LATEST event already recorded in
-- ITS OWN stream. correct_shipment_actual_cost() (0118/0130) already got
-- this right (it also checks against the latest actual-cost ledger entry's
-- own business_date, "never backdate a correction before the entry it is
-- correcting") -- this migration retrofits the identical rule onto the two
-- append-only event streams that were missed: shipment_status_events and
-- shipment_cod_events. Without this, two status events (or two COD events)
-- for the same shipment could be inserted in reverse chronological order as
-- long as both individually cleared the shipment_date floor -- e.g. a
-- "delivered" event dated 2026-08-10 followed later by an "in_transit"
-- event dated 2026-08-05, both >= shipment_date, silently corrupting the
-- append-only timeline's own ordering guarantee.
--
-- Both functions' signatures are UNCHANGED from 0118/0127/0130 -- no DROP
-- needed (this project's convention: DROP only when a signature changes).
-- The comparison is strictly "<" (reject only STRICTLY earlier than the
-- latest existing event), so multiple events on the SAME business_date
-- remain allowed (e.g. "created" and "picked_up" recorded the same day) --
-- identical tolerance to correct_shipment_actual_cost()'s own bound.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- add_shipment_status_event() — now also checked against the latest
-- existing shipment_status_events.event_business_date for this shipment.
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
  v_latest_status_event_date date;
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

  -- Patch 5.1 item 18 — chronology lower bound (shipment_date floor).
  if p_event_business_date < v_shipment.shipment_date then
    raise exception 'لا يمكن أن يكون تاريخ حدث الحالة (%) قبل تاريخ الشحنة نفسها (%)', p_event_business_date, v_shipment.shipment_date using errcode = 'P0001';
  end if;

  -- Hotfix 5.1.1 item 6 — chronology lower bound against the LATEST
  -- existing status event, not just shipment_date. Mirrors correct_
  -- shipment_actual_cost()'s own "never backdate before the latest ledger
  -- entry" rule (0130), retrofitted onto the status stream.
  select max(se.event_business_date) into v_latest_status_event_date
  from public.shipment_status_events se
  where se.shipment_id = p_shipment_id;

  if v_latest_status_event_date is not null and p_event_business_date < v_latest_status_event_date then
    raise exception 'لا يمكن أن يكون تاريخ حدث الحالة (%) قبل تاريخ آخر حدث حالة مسجَّل لهذه الشحنة (%)', p_event_business_date, v_latest_status_event_date using errcode = 'P0001';
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
  'Phase 5 (Section 13/14/35), extended by Patch 5.1 item 18 (0130) and Hotfix 5.1.1 item 6 (0131): event_business_date must be >= shipments.shipment_date AND >= the latest existing shipment_status_events.event_business_date for this shipment (never insert a status event earlier than one already recorded). Same permission/optimistic-concurrency/store-scope shape as before. SECURITY DEFINER.';

-- Signature unchanged — grants already in place from 0118.

-- ---------------------------------------------------------------------------
-- record_shipment_cod_collection_state() — now also checked against the
-- latest existing shipment_cod_events.business_date for this shipment.
-- ---------------------------------------------------------------------------
create or replace function public.record_shipment_cod_collection_state(
  p_shipment_id uuid,
  p_expected_version bigint,
  p_new_state text,
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
  v_new_row_version bigint;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_latest_cod_event_date date;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتحديث حالة تحصيل الدفع عند الاستلام' using errcode = 'P0001';
  end if;

  if not public.has_permission('shipments.manage_cost') then
    raise exception 'ليست لديك صلاحية إدارة تكلفة/تحصيل الشحن' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_shipment_id is null or p_expected_version is null or p_new_state is null or p_business_date is null then
    raise exception 'الشحنة وإصدار السجل وحالة التحصيل الجديدة وتاريخ العملية كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_new_state not in ('expected', 'collected', 'not_collected', 'unknown') then
    raise exception 'حالة تحصيل الدفع عند الاستلام غير صالحة' using errcode = 'P0001';
  end if;

  if p_business_date > public.business_today() then
    raise exception 'لا يمكن تسجيل حالة تحصيل بتاريخ مستقبلي (%)', p_business_date using errcode = 'P0001';
  end if;

  -- Lock FIRST, then compare row_version (same lost-update fix as every
  -- other Shipping write RPC, 0075's original pattern).
  select s.* into v_shipment from public.shipments s where s.id = p_shipment_id for update;

  if v_shipment.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_shipment.store_id) then
    raise exception 'الشحنة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if v_shipment.row_version <> p_expected_version then
    raise exception 'تم تعديل هذه الشحنة من قِبل مستخدم آخر — يرجى إعادة تحميل البيانات والمحاولة مجددًا (الإصدار المتوقع %، الإصدار الحالي %)', p_expected_version, v_shipment.row_version
      using errcode = 'P0001';
  end if;

  if not v_shipment.is_cod then
    raise exception 'هذه الشحنة ليست دفعًا عند الاستلام (COD) — لا يمكن تسجيل حالة تحصيل لها' using errcode = 'P0001';
  end if;

  -- Item 18 (business-date chronology): a COD collection event can never
  -- be dated before the shipment itself.
  if p_business_date < v_shipment.shipment_date then
    raise exception 'لا يمكن أن يكون تاريخ حالة التحصيل (%) قبل تاريخ الشحنة نفسها (%)', p_business_date, v_shipment.shipment_date using errcode = 'P0001';
  end if;

  -- Hotfix 5.1.1 item 6 — chronology lower bound against the LATEST
  -- existing COD event, not just shipment_date. Mirrors add_shipment_
  -- status_event()'s equivalent fix above, applied to the COD stream.
  select max(ce.business_date) into v_latest_cod_event_date
  from public.shipment_cod_events ce
  where ce.shipment_id = p_shipment_id;

  if v_latest_cod_event_date is not null and p_business_date < v_latest_cod_event_date then
    raise exception 'لا يمكن أن يكون تاريخ حالة التحصيل (%) قبل تاريخ آخر حالة تحصيل مسجَّلة لهذه الشحنة (%)', p_business_date, v_latest_cod_event_date using errcode = 'P0001';
  end if;

  -- Daily Close — shared lock + gating on the COD EVENT's own business_date
  -- (Section 28-style, same as record_shipment_actual_cost(), 0118).
  perform public.acquire_daily_close_lock_shared(v_shipment.store_id, p_business_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = v_shipment.store_id and dc.business_date = p_business_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('shipments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن تسجيل حالة تحصيل فيه إلا بصلاحية خاصة (shipments.process_closed_day)', p_business_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتسجيل حالة تحصيل في يوم مقفل' using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  insert into public.shipment_cod_events (shipment_id, state, business_date, reference, reason, actor)
  values (p_shipment_id, p_new_state, p_business_date, p_reference, p_notes, v_actor);

  v_new_row_version := v_shipment.row_version + 1;

  update public.shipments
  set cod_collection_state = p_new_state, updated_by = v_actor, row_version = v_new_row_version
  where id = p_shipment_id;

  -- 'shipment.cod_state_record' — deliberately UNGATED in audit_logs RLS
  -- (0121/0124's gated list is unchanged by this migration): this event
  -- never carries a money figure — cod_expected_amount was already fixed
  -- at creation (and stays profit-gated there) — only a state string/date/
  -- reference, exactly like shipment.status_add.
  perform public.log_audit_event(
    'shipment.cod_state_record', 'shipment', p_shipment_id, jsonb_build_object('cod_collection_state', v_shipment.cod_collection_state),
    jsonb_build_object(
      'cod_collection_state', p_new_state, 'business_date', p_business_date, 'reference', p_reference,
      'recorded_on_closed_day', v_used_closed_day_override
    ),
    p_notes
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'shipment.closed_day_override', 'shipment', p_shipment_id, null,
      jsonb_build_object('business_date', p_business_date, 'action', 'cod_state_record'),
      p_closed_day_reason
    );
  end if;

  return query select v_new_row_version;
end;
$$;

comment on function public.record_shipment_cod_collection_state(uuid, bigint, text, date, text, text, text) is
  'Patch 5.1 (item 13/14, 0127), extended by Hotfix 5.1.1 item 6 (0131): p_business_date must be >= shipments.shipment_date AND >= the latest existing shipment_cod_events.business_date for this shipment. Same permission/Daily-Close/scope/concurrency shape as before. SECURITY DEFINER.';

-- Signature unchanged — grants already in place from 0127.

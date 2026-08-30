-- ============================================================================
-- 0139: Phase 6 — Services / Adjustments Core (7/11): create_sales_order_
-- adjustment() + update_sales_order_adjustment() (pending edit)
-- ============================================================================
-- Migrations 0001-0138 are unmodified.

-- ---------------------------------------------------------------------------
-- create_sales_order_adjustment() — §36. Creates a PENDING record only.
-- direct_cost is accepted but NOT required (nullable while pending, §9).
-- participates_in_settlement is REQUIRED explicit input (§13) — never
-- inferred/hardcoded from payment_method/brand.
-- ---------------------------------------------------------------------------
create or replace function public.create_sales_order_adjustment(
  p_sales_order_id uuid,
  p_adjustment_type_id uuid,
  p_processing_store_id uuid,
  p_adjustment_date date,
  p_payment_method_id uuid,
  p_collection_channel_id uuid,
  p_participates_in_settlement boolean,
  p_customer_charge numeric,
  p_direct_cost numeric default null,
  p_notes text default null,
  p_closed_day_reason text default null
)
returns table (id uuid, adjustment_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_order record;
  v_type record;
  v_payment_method record;
  v_collection_channel record;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_number text;
  v_id uuid;
  v_today date := public.business_today();
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء تعديل/خدمة' using errcode = 'P0001';
  end if;

  if p_participates_in_settlement is null then
    raise exception 'يجب تحديد ما إذا كان هذا التعديل/الخدمة ضمن التسوية بشكل صريح' using errcode = 'P0001';
  end if;
  if p_customer_charge is null or p_customer_charge < 0 then
    raise exception 'قيمة تحصيل العميل يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
  end if;
  if p_direct_cost is not null and p_direct_cost < 0 then
    raise exception 'التكلفة المباشرة يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
  end if;
  if p_adjustment_date is null then
    raise exception 'تاريخ التعديل/الخدمة مطلوب' using errcode = 'P0001';
  end if;
  if p_adjustment_date > v_today then
    raise exception 'تاريخ التعديل/الخدمة لا يمكن أن يكون في المستقبل' using errcode = 'P0001';
  end if;

  -- §23 — Original Sales Order only needs to be VISIBLE (not operable).
  select * into v_order from public.sales_orders where sales_orders.id = p_sales_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير مرئية لك' using errcode = 'P0001';
  end if;

  -- §23 — Processing Store needs to be OPERABLE for a NEW record.
  -- Cross-store (order at Store A, processing at Store B) is explicitly
  -- allowed as long as the actor can see A and operate B.
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_processing_store_id) then
    raise exception 'المتجر المُعالِج غير متاح لك للعمل عليه' using errcode = 'P0001';
  end if;

  select * into v_type from public.adjustment_types where adjustment_types.id = p_adjustment_type_id;
  if v_type.id is null then
    raise exception 'نوع التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if v_type.status <> 'active' then
    raise exception 'نوع التعديل/الخدمة "%" غير نشط — لا يمكن استخدامه في تعديل/خدمة جديد', v_type.name_ar using errcode = 'P0001';
  end if;

  select * into v_payment_method from public.payment_methods where payment_methods.id = p_payment_method_id;
  if v_payment_method.id is null then
    raise exception 'طريقة الدفع غير موجودة' using errcode = 'P0001';
  end if;
  if v_payment_method.status <> 'active' then
    raise exception 'طريقة الدفع "%" غير نشطة — لا يمكن استخدامها في تعديل/خدمة جديد', v_payment_method.name_ar using errcode = 'P0001';
  end if;

  select * into v_collection_channel from public.collection_channels where collection_channels.id = p_collection_channel_id;
  if v_collection_channel.id is null then
    raise exception 'قناة التحصيل غير موجودة' using errcode = 'P0001';
  end if;
  if v_collection_channel.status <> 'active' then
    raise exception 'قناة التحصيل "%" غير نشطة — لا يمكن استخدامها في تعديل/خدمة جديد', v_collection_channel.name_ar using errcode = 'P0001';
  end if;

  -- Daily Close (§22) — shared lock on (processing store, adjustment_date),
  -- reusing the SAME daily_closings table/lock helpers Sales/Returns/
  -- Shipping use (0065).
  perform public.acquire_daily_close_lock_shared(p_processing_store_id, p_adjustment_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = p_processing_store_id and dc.business_date = p_adjustment_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('adjustments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن إنشاء تعديل/خدمة فيه إلا بصلاحية خاصة (adjustments.process_closed_day)', p_adjustment_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لإنشاء تعديل/خدمة في يوم مقفل' using errcode = 'P0001';
    end if;
    v_used_closed_day_override := true;
  end if;

  v_number := public.generate_adjustment_number();

  insert into public.sales_order_adjustments (
    adjustment_number, sales_order_id, adjustment_type_id, processing_store_id, adjustment_date,
    payment_method_id, collection_channel_id, participates_in_settlement,
    customer_charge, direct_cost, notes, status,
    created_by, updated_by
  ) values (
    v_number, p_sales_order_id, p_adjustment_type_id, p_processing_store_id, p_adjustment_date,
    p_payment_method_id, p_collection_channel_id, p_participates_in_settlement,
    round(p_customer_charge, 2), case when p_direct_cost is null then null else round(p_direct_cost, 2) end,
    nullif(btrim(coalesce(p_notes, '')), ''), 'pending',
    v_actor, v_actor
  )
  returning sales_order_adjustments.id into v_id;

  perform public.log_audit_event(
    'adjustment.create', 'sales_order_adjustment', v_id, null,
    jsonb_build_object(
      'adjustment_number', v_number, 'sales_order_id', p_sales_order_id, 'adjustment_type_id', p_adjustment_type_id,
      'processing_store_id', p_processing_store_id, 'adjustment_date', p_adjustment_date,
      'customer_charge', round(p_customer_charge, 2), 'direct_cost', p_direct_cost,
      'participates_in_settlement', p_participates_in_settlement
    )
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'adjustment.closed_day_override', 'sales_order_adjustment', v_id, null,
      jsonb_build_object('adjustment_number', v_number, 'adjustment_date', p_adjustment_date, 'created_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := v_id;
  adjustment_number := v_number;
  return next;
end;
$$;

comment on function public.create_sales_order_adjustment(uuid, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text) is
  'Phase 6 (§36) — creates a PENDING Service/Adjustment linked to an existing Sales Order. Original invoice (sales_orders.subtotal) is never touched. Requires adjustments.create. SECURITY DEFINER.';

revoke execute on function public.create_sales_order_adjustment(uuid, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text) from public;
grant execute on function public.create_sales_order_adjustment(uuid, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- update_sales_order_adjustment() — §16. Only a PENDING record may be
-- edited; row_version optimistic concurrency, same pattern as
-- update_sales_order()/correct_shipment_customer_charge(). sales_order_id
-- is intentionally NOT accepted as a parameter — the order link is
-- immutable once created (mirrors sales_orders.store_id/sale_date staying
-- unchangeable, §18-style reasoning: never move a financial record between
-- orders).
-- ---------------------------------------------------------------------------
create or replace function public.update_sales_order_adjustment(
  p_id uuid,
  p_expected_version bigint,
  p_adjustment_type_id uuid,
  p_processing_store_id uuid,
  p_adjustment_date date,
  p_payment_method_id uuid,
  p_collection_channel_id uuid,
  p_participates_in_settlement boolean,
  p_customer_charge numeric,
  p_direct_cost numeric default null,
  p_notes text default null,
  p_closed_day_reason text default null
)
returns table (id uuid, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old record;
  v_order record;
  v_type record;
  v_payment_method record;
  v_collection_channel record;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_new_row_version bigint;
  v_today date := public.business_today();
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء/تعديل تعديل/خدمة' using errcode = 'P0001';
  end if;

  select * into v_old from public.sales_order_adjustments where sales_order_adjustments.id = p_id for update;
  if v_old.id is null then
    raise exception 'التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if v_old.status <> 'pending' then
    raise exception 'لا يمكن تعديل تعديل/خدمة بعد اعتماده أو رفضه — التصحيح بعد الاعتماد يتم عبر آلية العكس الإداري' using errcode = 'P0001';
  end if;
  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لحفظ التعديل' using errcode = 'P0001';
  end if;
  if v_old.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا السجل من جهة أخرى — أعد تحميل الصفحة وحاول مرة أخرى (تعارض الإصدارات)' using errcode = 'P0001';
  end if;

  if p_participates_in_settlement is null then
    raise exception 'يجب تحديد ما إذا كان هذا التعديل/الخدمة ضمن التسوية بشكل صريح' using errcode = 'P0001';
  end if;
  if p_customer_charge is null or p_customer_charge < 0 then
    raise exception 'قيمة تحصيل العميل يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
  end if;
  if p_direct_cost is not null and p_direct_cost < 0 then
    raise exception 'التكلفة المباشرة يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
  end if;
  if p_adjustment_date is null then
    raise exception 'تاريخ التعديل/الخدمة مطلوب' using errcode = 'P0001';
  end if;
  if p_adjustment_date > v_today then
    raise exception 'تاريخ التعديل/الخدمة لا يمكن أن يكون في المستقبل' using errcode = 'P0001';
  end if;

  select * into v_order from public.sales_orders where sales_orders.id = v_old.sales_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير مرئية لك' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_processing_store_id) then
    raise exception 'المتجر المُعالِج غير متاح لك للعمل عليه' using errcode = 'P0001';
  end if;

  select * into v_type from public.adjustment_types where adjustment_types.id = p_adjustment_type_id;
  if v_type.id is null then
    raise exception 'نوع التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if v_type.status <> 'active' then
    raise exception 'نوع التعديل/الخدمة "%" غير نشط — لا يمكن استخدامه', v_type.name_ar using errcode = 'P0001';
  end if;

  select * into v_payment_method from public.payment_methods where payment_methods.id = p_payment_method_id;
  if v_payment_method.id is null or v_payment_method.status <> 'active' then
    raise exception 'طريقة الدفع غير موجودة أو غير نشطة' using errcode = 'P0001';
  end if;

  select * into v_collection_channel from public.collection_channels where collection_channels.id = p_collection_channel_id;
  if v_collection_channel.id is null or v_collection_channel.status <> 'active' then
    raise exception 'قناة التحصيل غير موجودة أو غير نشطة' using errcode = 'P0001';
  end if;

  perform public.acquire_daily_close_lock_shared(p_processing_store_id, p_adjustment_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = p_processing_store_id and dc.business_date = p_adjustment_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('adjustments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن حفظ تعديل/خدمة فيه إلا بصلاحية خاصة (adjustments.process_closed_day)', p_adjustment_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لحفظ تعديل/خدمة في يوم مقفل' using errcode = 'P0001';
    end if;
    v_used_closed_day_override := true;
  end if;

  v_new_row_version := v_old.row_version + 1;

  update public.sales_order_adjustments
  set adjustment_type_id = p_adjustment_type_id,
      processing_store_id = p_processing_store_id,
      adjustment_date = p_adjustment_date,
      payment_method_id = p_payment_method_id,
      collection_channel_id = p_collection_channel_id,
      participates_in_settlement = p_participates_in_settlement,
      customer_charge = round(p_customer_charge, 2),
      direct_cost = case when p_direct_cost is null then null else round(p_direct_cost, 2) end,
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_order_adjustments.id = p_id;

  perform public.log_audit_event(
    'adjustment.update', 'sales_order_adjustment', p_id,
    jsonb_build_object('customer_charge', v_old.customer_charge, 'direct_cost', v_old.direct_cost, 'row_version', v_old.row_version),
    jsonb_build_object('customer_charge', round(p_customer_charge, 2), 'direct_cost', p_direct_cost, 'row_version', v_new_row_version)
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'adjustment.closed_day_override', 'sales_order_adjustment', p_id, null,
      jsonb_build_object('adjustment_date', p_adjustment_date, 'updated_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := p_id;
  row_version := v_new_row_version;
  return next;
end;
$$;

comment on function public.update_sales_order_adjustment(uuid, bigint, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text) is
  'Phase 6 (§16) — edits a PENDING Service/Adjustment only, with row_version optimistic concurrency. sales_order_id is immutable (not accepted). Requires adjustments.create. SECURITY DEFINER.';

revoke execute on function public.update_sales_order_adjustment(uuid, bigint, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text) from public;
grant execute on function public.update_sales_order_adjustment(uuid, bigint, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text) to authenticated;

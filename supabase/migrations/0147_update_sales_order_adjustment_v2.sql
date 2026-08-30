-- ============================================================================
-- 0147: Phase 6 Integrity Patch 6.1 (4/13): update_sales_order_adjustment()
-- v2 — direct_cost removed entirely, money-scale rejection, sale-date floor,
-- zero-charge normalization, payment_reference, adjustments type lock
-- ============================================================================
-- Migrations 0001-0146 are unmodified.
--
-- Patch 6.1 item 2 — "لا تجعل general operational update هي المسؤولة عن
-- التكلفة": this general-purpose PENDING edit RPC no longer accepts
-- direct_cost as a parameter AT ALL (a NEW, narrower contract — the 0139
-- original 11-argument signature accepted an optional p_direct_cost; that
-- signature is dropped below). Whatever direct_cost the record already
-- carries is always preserved untouched by this RPC — the ONLY way to set/
-- change it is set_pending_sales_order_adjustment_direct_cost() (0145),
-- regardless of whether the caller holds adjustments.manage_cost.
-- ---------------------------------------------------------------------------
drop function if exists public.update_sales_order_adjustment(uuid, bigint, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text);

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
  p_notes text default null,
  p_closed_day_reason text default null,
  p_payment_reference text default null
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
  v_is_free boolean;
  v_payment_method_id uuid;
  v_collection_channel_id uuid;
  v_payment_reference text;
  v_participates boolean;
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

  if p_customer_charge is null or p_customer_charge < 0 then
    raise exception 'قيمة تحصيل العميل يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
  end if;
  perform public.validate_money_scale(p_customer_charge, 'قيمة تحصيل العميل');
  v_is_free := round(p_customer_charge, 2) = 0;

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

  if p_adjustment_date < v_order.sale_date then
    raise exception 'تاريخ التعديل/الخدمة لا يمكن أن يسبق تاريخ عملية البيع الأصلية (%)', v_order.sale_date using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_processing_store_id) then
    raise exception 'المتجر المُعالِج غير متاح لك للعمل عليه' using errcode = 'P0001';
  end if;

  perform public.acquire_adjustments_lock_shared();

  select * into v_type from public.adjustment_types where adjustment_types.id = p_adjustment_type_id;
  if v_type.id is null then
    raise exception 'نوع التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if v_type.status <> 'active' then
    raise exception 'نوع التعديل/الخدمة "%" غير نشط — لا يمكن استخدامه', v_type.name_ar using errcode = 'P0001';
  end if;

  if v_is_free then
    v_payment_method_id := null;
    v_collection_channel_id := null;
    v_payment_reference := null;
    v_participates := false;
  else
    if p_participates_in_settlement is null then
      raise exception 'يجب تحديد ما إذا كان هذا التعديل/الخدمة ضمن التسوية بشكل صريح' using errcode = 'P0001';
    end if;
    if p_payment_method_id is null then
      raise exception 'طريقة الدفع مطلوبة لتعديل/خدمة بقيمة تحصيل أكبر من صفر' using errcode = 'P0001';
    end if;
    if p_collection_channel_id is null then
      raise exception 'قناة التحصيل مطلوبة لتعديل/خدمة بقيمة تحصيل أكبر من صفر' using errcode = 'P0001';
    end if;

    select * into v_payment_method from public.payment_methods where payment_methods.id = p_payment_method_id;
    if v_payment_method.id is null or v_payment_method.status <> 'active' then
      raise exception 'طريقة الدفع غير موجودة أو غير نشطة' using errcode = 'P0001';
    end if;

    select * into v_collection_channel from public.collection_channels where collection_channels.id = p_collection_channel_id;
    if v_collection_channel.id is null or v_collection_channel.status <> 'active' then
      raise exception 'قناة التحصيل غير موجودة أو غير نشطة' using errcode = 'P0001';
    end if;

    v_payment_method_id := p_payment_method_id;
    v_collection_channel_id := p_collection_channel_id;
    v_payment_reference := nullif(btrim(coalesce(p_payment_reference, '')), '');
    v_participates := p_participates_in_settlement;
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

  -- direct_cost is intentionally ABSENT from this SET list — it is never
  -- touched by this RPC (item 2). set_pending_sales_order_adjustment_
  -- direct_cost() (0145) is the only path.
  update public.sales_order_adjustments
  set adjustment_type_id = p_adjustment_type_id,
      processing_store_id = p_processing_store_id,
      adjustment_date = p_adjustment_date,
      payment_method_id = v_payment_method_id,
      collection_channel_id = v_collection_channel_id,
      payment_reference = v_payment_reference,
      participates_in_settlement = v_participates,
      customer_charge = round(p_customer_charge, 2),
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_order_adjustments.id = p_id;

  perform public.log_audit_event(
    'adjustment.update', 'sales_order_adjustment', p_id,
    jsonb_build_object('customer_charge', v_old.customer_charge, 'row_version', v_old.row_version),
    jsonb_build_object('customer_charge', round(p_customer_charge, 2), 'row_version', v_new_row_version, 'is_free_service', v_is_free)
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

comment on function public.update_sales_order_adjustment(uuid, bigint, uuid, uuid, date, uuid, uuid, boolean, numeric, text, text, text) is
  'Phase 6 (§16) + Patch 6.1 items 2/7/8/9/10/11/14 — edits a PENDING Service/Adjustment. direct_cost is NEVER accepted here (set_pending_sales_order_adjustment_direct_cost, 0145, is the only path, for ANY caller including adjustments.manage_cost holders). customer_charge rejects overprecision. adjustment_date must be within [sale_date, business_today()]. customer_charge=0 forces payment_method_id/collection_channel_id/payment_reference to NULL and participates_in_settlement to false. sales_order_id is immutable (not accepted). Requires adjustments.create. SECURITY DEFINER.';

revoke execute on function public.update_sales_order_adjustment(uuid, bigint, uuid, uuid, date, uuid, uuid, boolean, numeric, text, text, text) from public;
grant execute on function public.update_sales_order_adjustment(uuid, bigint, uuid, uuid, date, uuid, uuid, boolean, numeric, text, text, text) to authenticated;

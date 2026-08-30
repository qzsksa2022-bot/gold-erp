-- ============================================================================
-- 0140: Phase 6 — Services / Adjustments Core (8/11): approve_sales_order_
-- adjustment() (full 20-step procedure, §17) + reject_sales_order_
-- adjustment() (§18)
-- ============================================================================
-- Migrations 0001-0139 are unmodified.
--
-- Preview (0138) is explicitly NOT the source of truth — this function
-- recomputes fee/gross/net authoritatively in the DB from the CURRENT
-- state of every master-data input, exactly as of THIS moment, using the
-- SAME canonical payment_fee_for_method_on_date() engine (0056).
-- ---------------------------------------------------------------------------
create or replace function public.approve_sales_order_adjustment(
  p_id uuid,
  p_expected_version bigint,
  p_closed_day_reason text default null
)
returns table (id uuid, adjustment_number text, row_version bigint, net_adjustment_profit text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_adj record;
  v_order record;
  v_type record;
  v_payment_method record;
  v_collection_channel record;
  v_fee record;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_fee_amount numeric;
  v_gross numeric;
  v_net numeric;
  v_new_row_version bigint;
  v_today date := public.business_today();
begin
  -- 1) auth -> require adjustments.approve AND adjustments.manage_cost
  -- (0133's own documented design: approval is the moment direct_cost/fee/
  -- gross/net are computed and permanently locked in — manage_cost is the
  -- distinct permission over that financial snapshot, kept separate from
  -- approve itself so a future custom role could hold one without the
  -- other; the default roles (super_admin/admin/supervisor) are always
  -- granted both together, so this never changes their behavior).
  if v_actor is null or not public.has_permission('adjustments.approve') or not public.has_permission('adjustments.manage_cost') then
    raise exception 'ليست لديك صلاحية اعتماد التعديلات/الخدمات (تتطلب adjustments.approve و adjustments.manage_cost معًا)' using errcode = 'P0001';
  end if;

  -- 2) lock Adjustment
  select * into v_adj from public.sales_order_adjustments where sales_order_adjustments.id = p_id for update;
  if v_adj.id is null then
    raise exception 'التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;

  -- 3) expected row_version
  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب للاعتماد' using errcode = 'P0001';
  end if;
  if v_adj.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا السجل من جهة أخرى — أعد تحميل الصفحة وحاول مرة أخرى (تعارض الإصدارات)' using errcode = 'P0001';
  end if;

  -- 4) status must be pending
  if v_adj.status <> 'pending' then
    raise exception 'لا يمكن اعتماد تعديل/خدمة إلا في حالة "قيد الانتظار"' using errcode = 'P0001';
  end if;

  -- 5) lock/validate linked Sales Order
  select * into v_order from public.sales_orders where sales_orders.id = v_adj.sales_order_id for share;
  if v_order.id is null then
    raise exception 'عملية البيع المرتبطة غير موجودة' using errcode = 'P0001';
  end if;

  -- 6) order visible to actor
  if not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير مرئية لك' using errcode = 'P0001';
  end if;

  -- 7) processing store valid — operable for the approver too
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_adj.processing_store_id) then
    raise exception 'المتجر المُعالِج غير متاح لك للعمل عليه' using errcode = 'P0001';
  end if;

  -- 8) adjustment_date logical
  if v_adj.adjustment_date > v_today then
    raise exception 'تاريخ التعديل/الخدمة لا يمكن أن يكون في المستقبل' using errcode = 'P0001';
  end if;

  -- 9) Daily Close on (processing store, adjustment_date)
  perform public.acquire_daily_close_lock_shared(v_adj.processing_store_id, v_adj.adjustment_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = v_adj.processing_store_id and dc.business_date = v_adj.adjustment_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('adjustments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن اعتماد تعديل/خدمة فيه إلا بصلاحية خاصة (adjustments.process_closed_day)', v_adj.adjustment_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لاعتماد تعديل/خدمة في يوم مقفل' using errcode = 'P0001';
    end if;
    v_used_closed_day_override := true;
  end if;

  -- 10) validate active Adjustment Type
  select * into v_type from public.adjustment_types where adjustment_types.id = v_adj.adjustment_type_id;
  if v_type.id is null then
    raise exception 'نوع التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if v_type.status <> 'active' then
    raise exception 'نوع التعديل/الخدمة "%" غير نشط حاليًا — لا يمكن اعتماد تعديل بنوع معطّل', v_type.name_ar using errcode = 'P0001';
  end if;

  -- 11) validate Payment Method / Collection Channel
  select * into v_payment_method from public.payment_methods where payment_methods.id = v_adj.payment_method_id;
  if v_payment_method.id is null or v_payment_method.status <> 'active' then
    raise exception 'طريقة الدفع غير موجودة أو غير نشطة حاليًا' using errcode = 'P0001';
  end if;

  select * into v_collection_channel from public.collection_channels where collection_channels.id = v_adj.collection_channel_id;
  if v_collection_channel.id is null or v_collection_channel.status <> 'active' then
    raise exception 'قناة التحصيل غير موجودة أو غير نشطة حاليًا' using errcode = 'P0001';
  end if;

  -- 12) acquire required financial master shared lock
  perform public.acquire_financial_master_lock_shared();

  -- 13) resolve Payment Fee Version by explicit adjustment_date (raises
  -- P0001 itself if no configuration covers that date — approval fails
  -- loudly rather than silently defaulting to 0).
  select * into v_fee from public.payment_fee_for_method_on_date(v_adj.payment_method_id, v_adj.adjustment_date);

  -- 14) require direct_cost not null
  if v_adj.direct_cost is null then
    raise exception 'يجب إدخال التكلفة المباشرة قبل اعتماد هذا التعديل/الخدمة' using errcode = 'P0001';
  end if;

  -- 15) compute Fee/Gross/Net authoritatively in the DB
  v_fee_amount := round(v_adj.customer_charge * v_fee.percentage_fee / 100 + v_fee.fixed_fee, 2);
  v_gross := v_adj.customer_charge - v_adj.direct_cost;
  v_net := v_gross - v_fee_amount;

  v_new_row_version := v_adj.row_version + 1;

  -- 16/17) snapshot all financial/master labels + mark approved
  update public.sales_order_adjustments
  set status = 'approved',
      approved_by = v_actor,
      approved_at = now(),
      adjustment_type_code_snapshot = v_type.code,
      adjustment_type_name_ar_snapshot = v_type.name_ar,
      adjustment_type_name_en_snapshot = v_type.name_en,
      payment_method_name_snapshot = v_payment_method.name_ar,
      collection_channel_name_snapshot = v_collection_channel.name_ar,
      payment_fee_version_id = v_fee.fee_version_id,
      payment_fee_percentage_snapshot = v_fee.percentage_fee,
      payment_fee_fixed_snapshot = v_fee.fixed_fee,
      payment_fee_amount = v_fee_amount,
      gross_adjustment_profit = v_gross,
      net_adjustment_profit = v_net,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_order_adjustments.id = p_id;

  -- 18) audit
  perform public.log_audit_event(
    'adjustment.approve', 'sales_order_adjustment', p_id,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object(
      'status', 'approved', 'customer_charge', v_adj.customer_charge, 'direct_cost', v_adj.direct_cost,
      'payment_fee_amount', v_fee_amount, 'gross_adjustment_profit', v_gross, 'net_adjustment_profit', v_net,
      'row_version', v_new_row_version
    )
  );

  -- 19) closed-day override audit entry, if used
  if v_used_closed_day_override then
    perform public.log_audit_event(
      'adjustment.closed_day_override', 'sales_order_adjustment', p_id, null,
      jsonb_build_object('adjustment_date', v_adj.adjustment_date, 'approved_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  -- 20) commit (implicit — end of function, transaction managed by caller)
  id := p_id;
  adjustment_number := v_adj.adjustment_number;
  row_version := v_new_row_version;
  net_adjustment_profit := v_net::text;
  return next;
end;
$$;

comment on function public.approve_sales_order_adjustment(uuid, bigint, text) is
  'Phase 6 (§17) — full 20-step approval procedure. Recomputes payment_fee/gross_adjustment_profit/net_adjustment_profit authoritatively from CURRENT master data (never trusts preview_sales_order_adjustment''s output). Snapshots type/payment method/collection channel labels. Terminal/immutable once approved. Requires BOTH adjustments.approve AND adjustments.manage_cost (0133) — the default roles are always granted both together. SECURITY DEFINER.';

revoke execute on function public.approve_sales_order_adjustment(uuid, bigint, text) from public;
grant execute on function public.approve_sales_order_adjustment(uuid, bigint, text) to authenticated;

-- ---------------------------------------------------------------------------
-- reject_sales_order_adjustment() — §18. Terminal/immutable, mandatory
-- reason, pending only.
-- ---------------------------------------------------------------------------
create or replace function public.reject_sales_order_adjustment(
  p_id uuid,
  p_expected_version bigint,
  p_reason text
)
returns table (id uuid, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_adj record;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_new_row_version bigint;
begin
  if v_actor is null or not public.has_permission('adjustments.approve') then
    raise exception 'ليست لديك صلاحية رفض التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  if v_reason = '' then
    raise exception 'يجب إدخال سبب الرفض' using errcode = 'P0001';
  end if;

  select * into v_adj from public.sales_order_adjustments where sales_order_adjustments.id = p_id for update;
  if v_adj.id is null then
    raise exception 'التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب للرفض' using errcode = 'P0001';
  end if;
  if v_adj.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا السجل من جهة أخرى — أعد تحميل الصفحة وحاول مرة أخرى (تعارض الإصدارات)' using errcode = 'P0001';
  end if;
  if v_adj.status <> 'pending' then
    raise exception 'لا يمكن رفض تعديل/خدمة إلا في حالة "قيد الانتظار"' using errcode = 'P0001';
  end if;

  v_new_row_version := v_adj.row_version + 1;

  update public.sales_order_adjustments
  set status = 'rejected', rejected_by = v_actor, rejected_at = now(), rejection_reason = v_reason, row_version = v_new_row_version, updated_by = v_actor
  where sales_order_adjustments.id = p_id;

  perform public.log_audit_event(
    'adjustment.reject', 'sales_order_adjustment', p_id,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', 'rejected', 'row_version', v_new_row_version),
    v_reason
  );

  id := p_id;
  row_version := v_new_row_version;
  return next;
end;
$$;

comment on function public.reject_sales_order_adjustment(uuid, bigint, text) is
  'Phase 6 (§18) — rejects a PENDING Service/Adjustment with a mandatory reason. Terminal/immutable once rejected — no re-submission path in this phase (a new record can always be created instead). Requires adjustments.approve (same permission as approve, mirrors Returns'' approve/reject symmetry). SECURITY DEFINER.';

revoke execute on function public.reject_sales_order_adjustment(uuid, bigint, text) from public;
grant execute on function public.reject_sales_order_adjustment(uuid, bigint, text) to authenticated;

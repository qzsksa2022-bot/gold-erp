-- ============================================================================
-- 0094: Returns Integrity Patch 4.1 (3/7): update_pending_sales_return()
-- ============================================================================
-- Migrations 0001-0093 are unmodified. Same shape change as create_sales_
-- return() (0093): p_items is now jsonb (per-item condition/reason/notes),
-- and the same Business Inputs (collection_state, deduction, approved
-- refund, refund-difference-reason) become editable here too, with the
-- identical speculative-total validation. sale_date_snapshot/source_sale_
-- row_version are NOT touched here — only refresh_pending_sales_return_
-- from_sale() (0093) ever re-snapshots the Sale basis (Section 4). The
-- double-return check is the same Section 5 change as create: blocks only
-- on an EFFECTIVE claim, not on another pending return's mere reference.
create or replace function public.update_pending_sales_return(
  p_return_id uuid,
  p_scenario text,
  p_items jsonb,
  p_collection_state text,
  p_approved_refund_amount numeric,
  p_expected_version bigint,
  p_non_shipping_deduction_amount numeric default 0,
  p_deduction_reason text default null,
  p_refund_difference_reason text default null,
  p_scenario_notes text default null,
  p_closed_day_reason text default null
)
returns table (id uuid, return_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old_return record;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_item jsonb;
  v_item_id uuid;
  v_condition text;
  v_soi record;
  v_max_line_no integer;
  v_new_row_version bigint;
  v_speculative_original numeric := 0;
  v_speculative_revenue_reversal numeric;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتعديل مرتجع' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.create') then
    raise exception 'ليست لديك صلاحية تعديل مرتجعات' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لحفظ التعديل' using errcode = 'P0001';
  end if;

  select * into v_old_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_old_return.id is null or not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_old_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_old_return.status <> 'pending' then
    raise exception 'لا يمكن تعديل مرتجع تمت معالجته بالفعل (الحالة الحالية: %)', v_old_return.status using errcode = 'P0001';
  end if;

  if v_old_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الحفظ.' using errcode = 'P0001';
  end if;

  if p_scenario is null then
    raise exception 'السيناريو مطلوب' using errcode = 'P0001';
  end if;

  if p_scenario = 'other' and (p_scenario_notes is null or btrim(p_scenario_notes) = '') then
    raise exception 'يجب إدخال ملاحظات عند اختيار سيناريو "أخرى"' using errcode = 'P0001';
  end if;

  if p_collection_state is null then
    raise exception 'حالة تحصيل المبلغ الأصلي مطلوبة' using errcode = 'P0001';
  end if;

  if p_approved_refund_amount is null or p_approved_refund_amount < 0 then
    raise exception 'قيمة الاسترداد المعتمد مطلوبة ويجب ألا تكون سالبة' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_approved_refund_amount, 'قيمة الاسترداد المعتمد');
  perform public.validate_money_scale(p_non_shipping_deduction_amount, 'قيمة الاستقطاع');

  if p_non_shipping_deduction_amount is null or p_non_shipping_deduction_amount < 0 then
    raise exception 'قيمة الاستقطاع يجب ألا تكون سالبة' using errcode = 'P0001';
  end if;

  if p_non_shipping_deduction_amount > 0 and (p_deduction_reason is null or btrim(p_deduction_reason) = '') then
    raise exception 'يجب إدخال سبب الاستقطاع عندما تكون قيمته أكبر من صفر' using errcode = 'P0001';
  end if;

  if p_scenario = 'customer_never_received' and p_collection_state = 'not_collected' and p_approved_refund_amount <> 0 then
    raise exception 'عندما لم يستلم العميل البضاعة ولم يتم تحصيل المبلغ الأصلي، يجب أن تكون قيمة الاسترداد المعتمد صفرًا' using errcode = 'P0001';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'يجب أن يحتوي المرتجع على بند واحد على الأقل' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_items) e
    group by (e->>'sales_order_item_id') having count(*) > 1
  ) then
    raise exception 'يوجد بند مكرر في قائمة البنود المراد إرجاعها' using errcode = 'P0001';
  end if;

  perform public.acquire_returns_order_lock_exclusive(v_old_return.sales_order_id);

  perform public.acquire_daily_close_lock_shared(v_old_return.processed_store_id, v_old_return.return_date);

  select exists(
    select 1 from public.daily_closings
    where store_id = v_old_return.processed_store_id and business_date = v_old_return.return_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('returns.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن تعديل مرتجع فيه إلا بصلاحية خاصة (returns.process_closed_day)', v_old_return.return_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتعديل مرتجع في يوم مقفل (%)', v_old_return.return_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_item_id := (v_item->>'sales_order_item_id')::uuid;

    select * into v_soi from public.sales_order_items soi
    where soi.id = v_item_id and soi.sales_order_id = v_old_return.sales_order_id and soi.status = 'active';

    if v_soi.id is null then
      raise exception 'البند غير موجود ضمن عملية البيع هذه، أو تمت إزالته (id: %)', v_item_id using errcode = 'P0001';
    end if;

    -- An item already active in THIS return doesn't need the effective-
    -- claim check repeated (it can't be effective while its own return is
    -- still pending); a newly-added item does.
    if not exists (select 1 from public.sales_return_items sri where sri.sales_return_id = p_return_id and sri.sales_order_item_id = v_item_id and sri.status = 'active') then
      if exists (select 1 from public.sales_return_items sri where sri.sales_order_item_id = v_item_id and sri.is_effective = true) then
        raise exception 'تم إرجاع هذا البند بالفعل ضمن مرتجع معتمد آخر (id: %)', v_item_id using errcode = 'P0001';
      end if;
    end if;

    v_speculative_original := v_speculative_original + v_soi.sale_price;
  end loop;

  v_speculative_revenue_reversal := round(v_speculative_original, 2) - p_non_shipping_deduction_amount;

  if p_non_shipping_deduction_amount > round(v_speculative_original, 2) then
    raise exception 'قيمة الاستقطاع (%) لا يمكن أن تتجاوز إجمالي مبلغ البيع الأصلي للبنود المرتجعة (%)', p_non_shipping_deduction_amount, round(v_speculative_original, 2) using errcode = 'P0001';
  end if;

  if p_approved_refund_amount <> v_speculative_revenue_reversal and (p_refund_difference_reason is null or btrim(p_refund_difference_reason) = '') then
    raise exception 'قيمة الاسترداد المعتمد (%) تختلف عن صافي عكس الإيراد المتوقع (%) — يجب إدخال سبب الفرق', p_approved_refund_amount, v_speculative_revenue_reversal using errcode = 'P0001';
  end if;

  -- Drop items no longer in the set — pending-edit membership only
  -- (Section 5/6): status='removed' here means "consciously dropped before
  -- any decision", never used to release an effective claim (nothing here
  -- is ever effective while the return is still pending).
  update public.sales_return_items sri
  set status = 'removed', removed_at = now(), removed_by = v_actor
  where sri.sales_return_id = p_return_id
    and sri.status = 'active'
    and sri.sales_order_item_id <> all(
      select (e->>'sales_order_item_id')::uuid from jsonb_array_elements(p_items) e
    );

  select coalesce(max(line_no), 0) into v_max_line_no from public.sales_return_items where sales_return_id = p_return_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_item_id := (v_item->>'sales_order_item_id')::uuid;
    v_condition := coalesce(nullif(btrim(v_item->>'condition'), ''), 'unknown');

    if exists (select 1 from public.sales_return_items sri where sri.sales_return_id = p_return_id and sri.sales_order_item_id = v_item_id and sri.status = 'active') then
      -- Unchanged membership: update only the editable per-item business
      -- fields (condition/reason/notes), never the frozen *_snapshot cost
      -- figures (Section 4's "already-captured figure does not silently
      -- drift" reasoning applies identically to Patch 4.1's new columns).
      update public.sales_return_items
      set condition = v_condition,
          item_return_reason = nullif(btrim(coalesce(v_item->>'item_return_reason', '')), ''),
          item_notes = nullif(btrim(coalesce(v_item->>'item_notes', '')), '')
      where sales_return_id = p_return_id and sales_order_item_id = v_item_id and status = 'active';
      continue;
    end if;

    select * into v_soi from public.sales_order_items soi where soi.id = v_item_id;

    v_max_line_no := v_max_line_no + 1;

    begin
      insert into public.sales_return_items (
        sales_return_id, sales_order_item_id, line_no,
        category_name_ar_snapshot, karat_code_snapshot, karat_name_ar_snapshot,
        weight_grams_snapshot, sale_price_snapshot,
        gold_component_cost_snapshot, manufacturing_component_cost_snapshot,
        base_cost_snapshot, vat_cost_snapshot, total_cost_snapshot, gross_profit_snapshot,
        item_calculation_version_snapshot,
        condition, item_return_reason, item_notes,
        created_by
      ) values (
        p_return_id, v_item_id, v_max_line_no,
        v_soi.category_name_ar_snapshot, v_soi.karat_code_snapshot, v_soi.karat_name_ar_snapshot,
        v_soi.weight_grams, v_soi.sale_price,
        v_soi.gold_component_cost, v_soi.manufacturing_component_cost,
        v_soi.base_cost, v_soi.vat_cost, v_soi.total_cost, v_soi.gross_profit,
        v_soi.calculation_version,
        v_condition, nullif(btrim(coalesce(v_item->>'item_return_reason', '')), ''), nullif(btrim(coalesce(v_item->>'item_notes', '')), ''),
        v_actor
      );
    exception when unique_violation then
      raise exception 'تم إرجاع هذا البند بالفعل ضمن مرتجع معتمد آخر (id: %)', v_item_id using errcode = 'P0001';
    end;
  end loop;

  v_new_row_version := v_old_return.row_version + 1;

  update public.sales_returns
  set scenario = p_scenario,
      scenario_notes = nullif(btrim(coalesce(p_scenario_notes, '')), ''),
      collection_state = p_collection_state,
      approved_refund_amount = p_approved_refund_amount,
      non_shipping_deduction_amount = p_non_shipping_deduction_amount,
      deduction_reason = nullif(btrim(coalesce(p_deduction_reason, '')), ''),
      refund_difference_reason = nullif(btrim(coalesce(p_refund_difference_reason, '')), ''),
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  perform public.log_audit_event(
    'return.update', 'sales_return', p_return_id,
    jsonb_build_object(
      'scenario', v_old_return.scenario, 'row_version', v_old_return.row_version,
      'collection_state', v_old_return.collection_state, 'approved_refund_amount', v_old_return.approved_refund_amount,
      'non_shipping_deduction_amount', v_old_return.non_shipping_deduction_amount
    ),
    jsonb_build_object(
      'scenario', p_scenario, 'row_version', v_new_row_version,
      'collection_state', p_collection_state, 'approved_refund_amount', p_approved_refund_amount,
      'non_shipping_deduction_amount', p_non_shipping_deduction_amount
    )
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'return.closed_day_override', 'sales_return', p_return_id, null,
      jsonb_build_object('return_number', v_old_return.return_number, 'return_date', v_old_return.return_date, 'edited_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := p_return_id;
  return_number := v_old_return.return_number;
  return next;
end;
$$;

comment on function public.update_pending_sales_return(uuid, text, jsonb, text, numeric, bigint, numeric, text, text, text, text) is
  'Patch 4.1 — p_items is now jsonb (Section 3). collection_state/approved_refund_amount/non_shipping_deduction_amount/deduction_reason/refund_difference_reason (Section 1/2) become editable here too, with the same speculative-total validation create_sales_return() (0093) applies. sale_date_snapshot/source_sale_row_version are untouched (only refresh_pending_sales_return_from_sale(), 0093, re-snapshots the Sale basis). Double-return check blocks only on an EFFECTIVE claim (Section 5). SECURITY DEFINER.';

drop function if exists public.update_pending_sales_return(uuid, text, uuid[], text, text, bigint);

revoke execute on function public.update_pending_sales_return(uuid, text, jsonb, text, numeric, bigint, numeric, text, text, text, text) from public;
grant execute on function public.update_pending_sales_return(uuid, text, jsonb, text, numeric, bigint, numeric, text, text, text, text) to authenticated;

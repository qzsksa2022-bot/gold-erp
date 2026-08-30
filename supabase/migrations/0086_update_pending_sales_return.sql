-- ============================================================================
-- 0086: Phase 4 — Returns Core (5/10): update_pending_sales_return()
-- ============================================================================
-- Migrations 0001-0085 are unmodified.
--
-- Only a 'pending' return may be edited — an approved/rejected/reversed
-- return is a closed lifecycle chapter, corrected only by reject/reverse +
-- opening a fresh return, never by mutating a decided one. processed_
-- store_id and return_date are immutable once set (mirrors sales_orders.
-- store_id/sale_date — spec item 18's reasoning applies identically here:
-- never move a financial-adjacent record between store/day after the fact).
-- Scenario/scenario_notes and the item set (add/remove among the SAME
-- order's active items) are the only editable fields, guarded by real
-- optimistic concurrency (row_version/p_expected_version, same mechanism as
-- update_sales_order(), 0075).
--
-- Snapshot policy: an item that STAYS in the set across this edit keeps its
-- ORIGINAL snapshot untouched (captured whenever it was first added to this
-- return, by create_sales_return() or an earlier edit) — never re-read from
-- the current sales_order_items row. Only a NEWLY added item gets a fresh
-- snapshot, taken now. This mirrors sales_order_items'' own table comment
-- (0082): "fixed at INSERT time... never re-read afterward" applied
-- literally — if the underlying Sale is financially edited while one of its
-- items is claimed by a still-pending return (allowed; only an APPROVED
-- return locks the Sale, 0084), this return's already-captured figure for
-- that item does not silently drift; reject and re-create is the correct
-- path if a genuinely stale snapshot must be discarded.
create or replace function public.update_pending_sales_return(
  p_return_id uuid,
  p_scenario text,
  p_item_ids uuid[],
  p_scenario_notes text default null,
  p_closed_day_reason text default null,
  p_expected_version bigint default null
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
  v_item_id uuid;
  v_soi record;
  v_max_line_no integer;
  v_new_row_version bigint;
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

  if p_item_ids is null or array_length(p_item_ids, 1) is null or array_length(p_item_ids, 1) = 0 then
    raise exception 'يجب أن يحتوي المرتجع على بند واحد على الأقل' using errcode = 'P0001';
  end if;

  if exists (select 1 from unnest(p_item_ids) x group by x having count(*) > 1) then
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

  -- Every incoming item id must belong to the SAME order this return
  -- already targets — sales_order_id itself is not editable here.
  foreach v_item_id in array p_item_ids
  loop
    if not exists (
      select 1 from public.sales_order_items soi
      where soi.id = v_item_id and soi.sales_order_id = v_old_return.sales_order_id and soi.status = 'active'
    ) then
      raise exception 'البند غير موجود ضمن عملية البيع هذه، أو تمت إزالته (id: %)', v_item_id using errcode = 'P0001';
    end if;
  end loop;

  -- Drop items no longer in the set — soft-remove only, never delete.
  update public.sales_return_items sri
  set status = 'removed', removed_at = now(), removed_by = v_actor
  where sri.sales_return_id = p_return_id
    and sri.status = 'active'
    and sri.sales_order_item_id <> all(p_item_ids);

  select coalesce(max(line_no), 0) into v_max_line_no from public.sales_return_items where sales_return_id = p_return_id;

  -- Add newly-selected items not already active in this return — fresh
  -- snapshot, taken now. An item already active in this return (unchanged
  -- across this edit) is left completely untouched.
  foreach v_item_id in array p_item_ids
  loop
    if exists (select 1 from public.sales_return_items sri where sri.sales_return_id = p_return_id and sri.sales_order_item_id = v_item_id and sri.status = 'active') then
      continue;
    end if;

    if exists (select 1 from public.sales_return_items sri where sri.sales_order_item_id = v_item_id and sri.status = 'active') then
      raise exception 'هذا البند مرتبط بالفعل بمرتجع آخر نشط (قيد المراجعة أو معتمد) (id: %)', v_item_id using errcode = 'P0001';
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
        created_by
      ) values (
        p_return_id, v_item_id, v_max_line_no,
        v_soi.category_name_ar_snapshot, v_soi.karat_code_snapshot, v_soi.karat_name_ar_snapshot,
        v_soi.weight_grams, v_soi.sale_price,
        v_soi.gold_component_cost, v_soi.manufacturing_component_cost,
        v_soi.base_cost, v_soi.vat_cost, v_soi.total_cost, v_soi.gross_profit,
        v_soi.calculation_version,
        v_actor
      );
    exception when unique_violation then
      raise exception 'هذا البند مرتبط بالفعل بمرتجع آخر نشط (قيد المراجعة أو معتمد) (id: %)', v_item_id using errcode = 'P0001';
    end;
  end loop;

  v_new_row_version := v_old_return.row_version + 1;

  update public.sales_returns
  set scenario = p_scenario,
      scenario_notes = nullif(btrim(coalesce(p_scenario_notes, '')), ''),
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  perform public.log_audit_event(
    'return.update', 'sales_return', p_return_id,
    jsonb_build_object('scenario', v_old_return.scenario, 'row_version', v_old_return.row_version),
    jsonb_build_object('scenario', p_scenario, 'row_version', v_new_row_version)
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

comment on function public.update_pending_sales_return(uuid, text, uuid[], text, text, bigint) is
  'Edits a still-''pending'' return only (rejects any other status) — scenario/scenario_notes and the item set (add/remove among the SAME order''s active items) are editable; processed_store_id/return_date/sales_order_id are immutable once set. Real optimistic concurrency (row_version/p_expected_version, same mechanism as update_sales_order(), 0075). An item unchanged across the edit keeps its ORIGINAL snapshot untouched; only a newly-added item gets a fresh snapshot taken now. SECURITY DEFINER.';

revoke execute on function public.update_pending_sales_return(uuid, text, uuid[], text, text, bigint) from public;
grant execute on function public.update_pending_sales_return(uuid, text, uuid[], text, text, bigint) to authenticated;

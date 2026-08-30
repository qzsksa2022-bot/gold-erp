-- ============================================================================
-- 0145: Phase 6 Integrity Patch 6.1 (2/13): dedicated direct_cost RPC
-- ============================================================================
-- Migrations 0001-0144 are unmodified.
--
-- Patch 6.1 item 2 — the ONLY sanctioned way to set/change a PENDING
-- adjustment's direct_cost. Neither create_sales_order_adjustment() (0146)
-- nor update_sales_order_adjustment() (0147) manage direct_cost as a general
-- operational field any more (0146 requires adjustments.manage_cost even to
-- supply an INITIAL value at creation; 0147 never accepts a change to it at
-- all) — this dedicated RPC is the single, auditable, permission-scoped path
-- for correcting/supplying a Pending record's cost.
-- ---------------------------------------------------------------------------
create or replace function public.set_pending_sales_order_adjustment_direct_cost(
  p_id uuid,
  p_expected_version bigint,
  p_direct_cost numeric,
  p_closed_day_reason text default null
)
returns table (id uuid, row_version bigint, direct_cost text, has_direct_cost boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_adj record;
  v_order record;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_new_row_version bigint;
  v_rounded numeric;
begin
  if v_actor is null or not public.has_permission('adjustments.manage_cost') then
    raise exception 'ليست لديك صلاحية إدارة التكلفة المباشرة لتعديل/خدمة' using errcode = 'P0001';
  end if;

  if p_direct_cost is null then
    raise exception 'قيمة التكلفة المباشرة مطلوبة' using errcode = 'P0001';
  end if;
  if p_direct_cost < 0 then
    raise exception 'التكلفة المباشرة يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
  end if;
  -- Patch 6.1 item 7 — reject overprecision outright (never silently round).
  perform public.validate_money_scale(p_direct_cost, 'التكلفة المباشرة');

  select * into v_adj from public.sales_order_adjustments where sales_order_adjustments.id = p_id for update;
  if v_adj.id is null then
    raise exception 'التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if v_adj.status <> 'pending' then
    raise exception 'لا يمكن تعديل التكلفة المباشرة إلا لتعديل/خدمة قيد الانتظار' using errcode = 'P0001';
  end if;
  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لحفظ التكلفة' using errcode = 'P0001';
  end if;
  if v_adj.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا السجل من جهة أخرى — أعد تحميل الصفحة وحاول مرة أخرى (تعارض الإصدارات)' using errcode = 'P0001';
  end if;

  -- §23-style scope: the linked order must be visible, the processing store
  -- must be OPERABLE — this is an active financial-management action on the
  -- record, same class as create/update, not a passive historical read.
  select * into v_order from public.sales_orders where sales_orders.id = v_adj.sales_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير مرئية لك' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_adj.processing_store_id) then
    raise exception 'المتجر المُعالِج غير متاح لك للعمل عليه' using errcode = 'P0001';
  end if;

  perform public.acquire_daily_close_lock_shared(v_adj.processing_store_id, v_adj.adjustment_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = v_adj.processing_store_id and dc.business_date = v_adj.adjustment_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('adjustments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن حفظ التكلفة المباشرة فيه إلا بصلاحية خاصة (adjustments.process_closed_day)', v_adj.adjustment_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لحفظ تكلفة مباشرة في يوم مقفل' using errcode = 'P0001';
    end if;
    v_used_closed_day_override := true;
  end if;

  v_rounded := round(p_direct_cost, 2);
  v_new_row_version := v_adj.row_version + 1;

  update public.sales_order_adjustments
  set direct_cost = v_rounded,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_order_adjustments.id = p_id;

  perform public.log_audit_event(
    'adjustment.cost_set', 'sales_order_adjustment', p_id,
    jsonb_build_object('direct_cost', v_adj.direct_cost, 'row_version', v_adj.row_version),
    jsonb_build_object('direct_cost', v_rounded, 'row_version', v_new_row_version)
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'adjustment.closed_day_override', 'sales_order_adjustment', p_id, null,
      jsonb_build_object('adjustment_date', v_adj.adjustment_date, 'cost_set_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := p_id;
  row_version := v_new_row_version;
  direct_cost := v_rounded::text;
  has_direct_cost := true;
  return next;
end;
$$;

comment on function public.set_pending_sales_order_adjustment_direct_cost(uuid, bigint, numeric, text) is
  'Patch 6.1 item 2 — the ONLY sanctioned way to set/correct a PENDING adjustment''s direct_cost. Requires adjustments.manage_cost alone (does NOT require adjustments.approve/adjustments.create). Pending-only, optimistic row_version, money-scale-validated, Daily-Close-gated. Neither create_sales_order_adjustment() (0146) nor update_sales_order_adjustment() (0147) accept a general-purpose cost change any more. SECURITY DEFINER.';

revoke execute on function public.set_pending_sales_order_adjustment_direct_cost(uuid, bigint, numeric, text) from public;
grant execute on function public.set_pending_sales_order_adjustment_direct_cost(uuid, bigint, numeric, text) to authenticated;

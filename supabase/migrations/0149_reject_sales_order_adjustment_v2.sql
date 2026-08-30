-- ============================================================================
-- 0149: Phase 6 Integrity Patch 6.1 (6/13): reject_sales_order_adjustment()
-- v2 — closes the cross-store scope bypass (item 13)
-- ============================================================================
-- Migrations 0001-0148 are unmodified. Same signature as 0140's original —
-- CREATE OR REPLACE in place.
--
-- The ORIGINAL reject_sales_order_adjustment() never checked store
-- visibility at all — being SECURITY DEFINER, an actor holding adjustments.
-- approve plus a known adjustment UUID could reject a PENDING record whose
-- linked Sale/processing store were both completely outside their visible
-- scope. This migration adds the same two checks get_sales_order_
-- adjustment() (0151) and reverse_sales_order_adjustment() (0141) already
-- perform: the linked Sale's store and the processing store must BOTH be
-- VISIBLE (not necessarily operable — reject is a terminal decision on an
-- existing record, not new work, same reasoning 0141 already documents for
-- reversal).
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
  v_order record;
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

  -- item 13 — store-scope check, closing the cross-store bypass: BOTH the
  -- linked Sale's store and the processing store must be visible.
  select * into v_order from public.sales_orders where sales_orders.id = v_adj.sales_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير مرئية لك' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_adj.processing_store_id) then
    raise exception 'المتجر المُعالِج غير مرئي لك' using errcode = 'P0001';
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
  'Phase 6 (§18) + Patch 6.1 item 13 — rejects a PENDING Service/Adjustment with a mandatory reason. Now requires BOTH the linked Sale''s store AND the processing store to be VISIBLE to the actor (closes the cross-store scope bypass — a SECURITY DEFINER RPC with a known UUID could previously reject a record entirely outside the actor''s scope). Requires adjustments.approve. SECURITY DEFINER.';

revoke execute on function public.reject_sales_order_adjustment(uuid, bigint, text) from public;
grant execute on function public.reject_sales_order_adjustment(uuid, bigint, text) to authenticated;

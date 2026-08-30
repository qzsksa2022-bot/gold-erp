-- ============================================================================
-- 0108: Phase 4 — Final Hotfix 4.2.1 (3/7): finalize_sales_return_refund(),
-- reopen_sales_return_refund_reconciliation()
-- ============================================================================
-- Migrations 0001-0107 are unmodified. Signatures unchanged from 0103 —
-- the ONLY change in both bodies is how actual_refunded_total is computed:
-- Section 4 — "effective" (not-reversed) is now derived from ABSENCE in
-- sales_return_refund_event_reversals (0106/0107), never from the legacy
-- e.status column, which stops being written to by any RPC after 0107 (it
-- stays frozen at 'active' for every event recorded from now on, and holds
-- its historical value for pre-existing rows — a legacy compatibility
-- column only, never a source of truth going forward).
create or replace function public.finalize_sales_return_refund(
  p_return_id uuid,
  p_expected_version bigint,
  p_variance_reason text default null
)
returns table (id uuid, return_number text, actual_refunded_total text, refund_variance text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_return record;
  v_actual_total numeric;
  v_variance numeric;
  v_stored_reason text;
  v_new_row_version bigint;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لإغلاق تسوية الاسترداد' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.record_refund') then
    raise exception 'ليست لديك صلاحية إغلاق تسوية الاسترداد' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لإغلاق تسوية الاسترداد' using errcode = 'P0001';
  end if;

  select * into v_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_return.status not in ('approved', 'reversed') then
    raise exception 'لا يمكن إغلاق تسوية استرداد إلا لمرتجع معتمد (الحالة الحالية: %)', v_return.status using errcode = 'P0001';
  end if;

  if v_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل إغلاق التسوية.' using errcode = 'P0001';
  end if;

  if v_return.refund_finalized_at is not null then
    raise exception 'تم إغلاق تسوية استرداد هذا المرتجع بالفعل بتاريخ %', v_return.refund_finalized_at using errcode = 'P0001';
  end if;

  -- Hotfix 4.2.1 (Section 4) — an event counts toward the total only if NO
  -- row references it in sales_return_refund_event_reversals. Computed
  -- AFTER the parent-row lock is held — no refund event can be recorded/
  -- reversed concurrently between this SELECT and the UPDATE below
  -- (Section 5), so the finalized snapshot is guaranteed accurate at the
  -- instant it is written.
  select coalesce(sum(e.amount), 0) into v_actual_total
  from public.sales_return_refund_events e
  where e.sales_return_id = p_return_id
    and not exists (select 1 from public.sales_return_refund_event_reversals rev where rev.refund_event_id = e.id);

  v_variance := coalesce(v_return.approved_refund_amount, 0) - v_actual_total;

  if v_variance <> 0 and (p_variance_reason is null or btrim(p_variance_reason) = '') then
    raise exception 'إجمالي المسترد فعليًا (%) يختلف عن قيمة الاسترداد المعتمد (%) — يجب إدخال سبب الفرق لإغلاق التسوية', v_actual_total, coalesce(v_return.approved_refund_amount, 0) using errcode = 'P0001';
  end if;

  v_stored_reason := case when v_variance = 0 then null else nullif(btrim(p_variance_reason), '') end;
  v_new_row_version := v_return.row_version + 1;

  update public.sales_returns
  set refund_finalized_at = now(),
      refund_finalized_by = v_actor,
      refund_final_variance_reason = v_stored_reason,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  insert into public.sales_return_refund_reconciliation_events (
    sales_return_id, event_type, actual_refunded_total, approved_refund_amount, variance, reason, actor
  ) values (
    p_return_id, 'finalized', v_actual_total, v_return.approved_refund_amount, v_variance, v_stored_reason, v_actor
  );

  perform public.log_audit_event(
    'return.refund_finalized', 'sales_return', p_return_id,
    jsonb_build_object('row_version', v_return.row_version, 'refund_finalized_at', null),
    jsonb_build_object(
      'row_version', v_new_row_version, 'approved_refund_amount', v_return.approved_refund_amount,
      'actual_refunded_total', v_actual_total, 'refund_variance', v_variance,
      'refund_final_variance_reason', v_stored_reason, 'actor', v_actor, 'refund_finalized_at', now()
    )
  );

  id := p_return_id;
  return_number := v_return.return_number;
  actual_refunded_total := v_actual_total::text;
  refund_variance := v_variance::text;
  return next;
end;
$$;

comment on function public.finalize_sales_return_refund(uuid, bigint, text) is
  'Patch 4.1/4.2/Hotfix 4.2.1 (Sections 3/4/5/11) — declares refund reconciliation for one return complete. Hotfix 4.2.1: actual_refunded_total now sums every sales_return_refund_events row that has NO matching sales_return_refund_event_reversals row (0106/0107) — the append-only-derived effective set, never the legacy status column. Locks the parent return row FOR UPDATE first. Writes a permanent row to sales_return_refund_reconciliation_events. Terminal until reopen_sales_return_refund_reconciliation() clears refund_finalized_at. Usable on ''approved'' OR ''reversed''. SECURITY DEFINER.';

revoke execute on function public.finalize_sales_return_refund(uuid, bigint, text) from public;
grant execute on function public.finalize_sales_return_refund(uuid, bigint, text) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.reopen_sales_return_refund_reconciliation(
  p_return_id uuid,
  p_expected_version bigint,
  p_reason text
)
returns table (id uuid, return_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_return record;
  v_actual_total numeric;
  v_variance numeric;
  v_new_row_version bigint;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لإعادة فتح تسوية الاسترداد' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.record_refund') then
    raise exception 'ليست لديك صلاحية إعادة فتح تسوية الاسترداد' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لإعادة فتح التسوية' using errcode = 'P0001';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'يجب إدخال سبب إعادة فتح التسوية' using errcode = 'P0001';
  end if;

  select * into v_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل إعادة فتح التسوية.' using errcode = 'P0001';
  end if;

  if v_return.refund_finalized_at is null then
    raise exception 'تسوية استرداد هذا المرتجع ليست مُغلَقة أصلًا — لا حاجة لإعادة فتحها' using errcode = 'P0001';
  end if;

  select coalesce(sum(e.amount), 0) into v_actual_total
  from public.sales_return_refund_events e
  where e.sales_return_id = p_return_id
    and not exists (select 1 from public.sales_return_refund_event_reversals rev where rev.refund_event_id = e.id);

  v_variance := coalesce(v_return.approved_refund_amount, 0) - v_actual_total;
  v_new_row_version := v_return.row_version + 1;

  insert into public.sales_return_refund_reconciliation_events (
    sales_return_id, event_type, actual_refunded_total, approved_refund_amount, variance, reason, actor
  ) values (
    p_return_id, 'reopened', v_actual_total, v_return.approved_refund_amount, v_variance, p_reason, v_actor
  );

  update public.sales_returns
  set refund_finalized_at = null,
      refund_finalized_by = null,
      refund_final_variance_reason = null,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  perform public.log_audit_event(
    'return.refund_reconciliation_reopened', 'sales_return', p_return_id,
    jsonb_build_object(
      'row_version', v_return.row_version, 'refund_finalized_at', v_return.refund_finalized_at,
      'refund_final_variance_reason', v_return.refund_final_variance_reason
    ),
    jsonb_build_object(
      'row_version', v_new_row_version, 'refund_finalized_at', null,
      'actual_refunded_total_at_reopen', v_actual_total, 'approved_refund_amount_at_reopen', v_return.approved_refund_amount,
      'variance_at_reopen', v_variance, 'actor', v_actor
    ),
    p_reason
  );

  id := p_return_id;
  return_number := v_return.return_number;
  return next;
end;
$$;

comment on function public.reopen_sales_return_refund_reconciliation(uuid, bigint, text) is
  'Patch 4.2/Hotfix 4.2.1 (Section 4) — the explicit, reason-required, audited escape hatch from a Finalized refund reconciliation. Hotfix 4.2.1: actual_refunded_total snapshot at reopen now uses the append-only-derived effective set (0106/0107), same as finalize. Clears ONLY sales_returns.refund_finalized_at/by/refund_final_variance_reason; the prior finalization is never erased. SECURITY DEFINER.';

revoke execute on function public.reopen_sales_return_refund_reconciliation(uuid, bigint, text) from public;
grant execute on function public.reopen_sales_return_refund_reconciliation(uuid, bigint, text) to authenticated;

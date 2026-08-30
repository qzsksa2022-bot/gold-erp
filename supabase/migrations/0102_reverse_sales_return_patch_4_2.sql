-- ============================================================================
-- 0102: Final Returns Integrity Patch 4.2 (4/7): reverse_sales_return()
-- ============================================================================
-- Migrations 0001-0101 are unmodified. Same signature as 0096 — Section 6
-- (business-date chronology) adds two new lower-bound checks; everything
-- else in the body is unchanged.
--
-- Section 6 — a reversal's business date could previously be dated before
-- the very return it reverses was approved, or even before the return's own
-- return_date, as long as it was not in the future — accounting nonsense
-- (a transaction cannot be reversed on a date earlier than it happened).
-- Fix: reversal_business_date must be >= the Riyadh business date of
-- approved_at (converted explicitly via `at time zone 'Asia/Riyadh'`,
-- exactly like business_today(), 0056) AND >= return_date. The existing
-- "not in the future" upper bound is unchanged.
create or replace function public.reverse_sales_return(
  p_return_id uuid,
  p_expected_version bigint,
  p_reversal_reason text,
  p_reversal_business_date date default null,
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
  v_business_date date;
  v_approved_business_date date;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_new_row_version bigint;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول للتراجع عن مرتجع' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.reverse') then
    raise exception 'ليست لديك صلاحية التراجع عن مرتجعات معتمدة' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب للتراجع عن المرتجع' using errcode = 'P0001';
  end if;

  if p_reversal_reason is null or btrim(p_reversal_reason) = '' then
    raise exception 'يجب إدخال سبب التراجع عن المرتجع' using errcode = 'P0001';
  end if;

  v_business_date := coalesce(p_reversal_business_date, public.business_today());

  if v_business_date > public.business_today() then
    raise exception 'لا يمكن أن يكون تاريخ عملية التراجع في المستقبل (%)', v_business_date using errcode = 'P0001';
  end if;

  select * into v_old_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_old_return.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_old_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_old_return.status <> 'approved' then
    raise exception 'لا يمكن التراجع إلا عن مرتجع معتمد (الحالة الحالية: %)', v_old_return.status using errcode = 'P0001';
  end if;

  if v_old_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل التراجع.' using errcode = 'P0001';
  end if;

  -- Section 6 — chronology: a reversal can never be dated before the
  -- approval it reverses, nor before the return's own return_date. Riyadh
  -- business date, explicitly (matches business_today()'s own conversion,
  -- 0056), never the database server's own timezone.
  v_approved_business_date := (v_old_return.approved_at at time zone 'Asia/Riyadh')::date;

  if v_business_date < v_approved_business_date then
    raise exception 'لا يمكن أن يكون تاريخ التراجع (%) قبل تاريخ اعتماد المرتجع (%)', v_business_date, v_approved_business_date using errcode = 'P0001';
  end if;

  if v_business_date < v_old_return.return_date then
    raise exception 'لا يمكن أن يكون تاريخ التراجع (%) قبل تاريخ المرتجع نفسه (%)', v_business_date, v_old_return.return_date using errcode = 'P0001';
  end if;

  perform public.acquire_returns_order_lock_exclusive(v_old_return.sales_order_id);

  -- Section 9 — independent business date, own Daily Close check.
  perform public.acquire_daily_close_lock_shared(v_old_return.processed_store_id, v_business_date);

  select exists(
    select 1 from public.daily_closings
    where store_id = v_old_return.processed_store_id and business_date = v_business_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('returns.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن التراجع عن مرتجع فيه إلا بصلاحية خاصة (returns.process_closed_day)', v_business_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب للتراجع عن مرتجع في يوم مقفل (%)', v_business_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  -- Section 6 — release the effective claim WITHOUT touching membership
  -- (status stays 'active'); every historical figure and item stays intact.
  update public.sales_return_items
  set is_effective = false
  where sales_return_id = p_return_id and status = 'active' and is_effective = true;

  v_new_row_version := v_old_return.row_version + 1;

  update public.sales_returns
  set status = 'reversed',
      reversed_at = now(),
      reversed_by = v_actor,
      reversal_reason = p_reversal_reason,
      reversal_business_date = v_business_date,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  perform public.log_audit_event(
    'return.reverse', 'sales_return', p_return_id,
    jsonb_build_object(
      'status', v_old_return.status, 'row_version', v_old_return.row_version,
      'sales_revenue_reversal_amount', v_old_return.sales_revenue_reversal_amount,
      'payment_fee_reversal_amount', v_old_return.payment_fee_reversal_amount,
      'net_sales_profit_adjustment', v_old_return.net_sales_profit_adjustment
    ),
    jsonb_build_object(
      'status', 'reversed', 'row_version', v_new_row_version,
      'reversal_reason', p_reversal_reason, 'reversal_business_date', v_business_date,
      'actor', v_actor, 'reversed_at', now()
    )
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'return.closed_day_override', 'sales_return', p_return_id, null,
      jsonb_build_object('return_number', v_old_return.return_number, 'reversal_business_date', v_business_date, 'reversed_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := p_return_id;
  return_number := v_old_return.return_number;
  return next;
end;
$$;

comment on function public.reverse_sales_return(uuid, bigint, text, date, text) is
  'Patch 4.1/4.2 (Sections 6/9/13) — reverses an ''approved'' return. Patch 4.2 (0102): reversal_business_date must now be >= the Riyadh business date of approved_at AND >= return_date (Section 6 chronology), in addition to the pre-existing "not in the future" bound. No longer soft-removes sales_return_items — only is_effective flips back to false. Store scope VISIBLE (Section 13). SECURITY DEFINER.';

revoke execute on function public.reverse_sales_return(uuid, bigint, text, date, text) from public;
grant execute on function public.reverse_sales_return(uuid, bigint, text, date, text) to authenticated;

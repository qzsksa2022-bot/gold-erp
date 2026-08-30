-- ============================================================================
-- 0071: Phase 3 — Sales Integrity Patch 3.1 (7/7 locks): close_sales_day()
-- acquires the EXCLUSIVE daily-close advisory lock
-- ============================================================================
-- Migrations 0001-0070 are unmodified. CREATE OR REPLACE of close_sales_day()
-- (0064) — every validation rule, error message, and business flow is
-- byte-for-byte unchanged EXCEPT one new line: immediately before the
-- existing "is this day already closed" check, this function now calls
-- acquire_daily_close_lock_exclusive(p_store_id, p_business_date) (0065).
--
-- This is the other half of spec item 5's fix: create_sales_order() (0068)
-- and update_sales_order() (0069) both hold the SHARED counterpart for this
-- exact (store, date) for their entire transaction. Acquiring the EXCLUSIVE
-- lock here means this call now waits for every currently in-flight
-- create/update for this exact day to commit or roll back BEFORE it reads
-- daily_closings and BEFORE it inserts the closing row — so the race
-- described in spec item 5 (a Sale's daily_closings check and a concurrent
-- Close's commit interleaving such that the Sale is saved on a day that is
-- actually already closed) is now impossible: either the Sale's whole
-- transaction (which holds the SHARED lock throughout) fully commits before
-- Close can even begin its own check, or Close's EXCLUSIVE acquisition
-- blocks until it does. Does not serialize this Close against a Sale for a
-- DIFFERENT (store, date), or against another Close for a different day —
-- only against genuinely conflicting in-flight work on this exact day.
create or replace function public.close_sales_day(
  p_store_id uuid,
  p_business_date date,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_today date := public.business_today();
  v_id uuid;
  v_already_closed boolean;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لإغلاق يوم المبيعات' using errcode = 'P0001';
  end if;

  if not public.has_permission('sales.close_day') then
    raise exception 'ليست لديك صلاحية إغلاق يوم المبيعات' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_store_id is null or p_business_date is null then
    raise exception 'المتجر وتاريخ العمل كلاهما مطلوبان' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'هذا المتجر غير متاح لك، أو أنه غير نشط' using errcode = 'P0001';
  end if;

  if p_business_date > v_today then
    raise exception 'لا يمكن إغلاق تاريخ عمل مستقبلي (%)', p_business_date using errcode = 'P0001';
  end if;

  -- Patch 3.1 item 5 — EXCLUSIVE daily-close lock. Waits for every in-flight
  -- create_sales_order()/update_sales_order() (0068/0069) holding the
  -- SHARED counterpart for this exact (store, date) to finish first.
  perform public.acquire_daily_close_lock_exclusive(p_store_id, p_business_date);

  select exists(
    select 1 from public.daily_closings
    where store_id = p_store_id and business_date = p_business_date
  ) into v_already_closed;

  if v_already_closed then
    raise exception 'اليوم % مغلق بالفعل لهذا المتجر', p_business_date using errcode = 'P0001';
  end if;

  insert into public.daily_closings (store_id, business_date, closed_by, notes)
  values (p_store_id, p_business_date, v_actor, nullif(btrim(coalesce(p_notes, '')), ''))
  returning daily_closings.id into v_id;

  perform public.log_audit_event(
    'daily_closing.create', 'daily_closing', v_id, null,
    jsonb_build_object('store_id', p_store_id, 'business_date', p_business_date)
  );

  return v_id;
end;
$$;

comment on function public.close_sales_day(uuid, date, text) is
  'Closes a store''s business day for Sales (spec §19) — requires sales.close_day, the store within the actor''s OPERABLE scope, and a non-future business_date. Rejects (does not silently no-op) if the day is already closed. As of 0071 (Patch 3.1 item 5): acquires acquire_daily_close_lock_exclusive() (0065) before checking daily_closings, waiting out any in-flight create_sales_order()/update_sales_order() holding the SHARED counterpart for this exact day first — closes the create/update-vs-close race. No Reopen/Hard Delete function exists in Phase 3 by design. SECURITY DEFINER.';

revoke execute on function public.close_sales_day(uuid, date, text) from public;
grant execute on function public.close_sales_day(uuid, date, text) to authenticated;

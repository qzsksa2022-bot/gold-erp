-- ============================================================================
-- 0064: Phase 3 — Sales Core (7/8): close_sales_day()
-- ============================================================================
-- Migrations 0001-0063 are unmodified.
--
-- daily_closings (0059) has no direct-write RLS policy — this SECURITY
-- DEFINER function is the exclusive way a row is ever created. No Reopen,
-- no Hard Delete in Phase 3 (spec §19) — there is deliberately no companion
-- "reopen"/"delete" RPC at all.
--
-- Design decision on re-closing an already-closed day (spec §31 lists this
-- as "duplicate close rejected/idempotent per design" — either is
-- acceptable as long as documented): this function REJECTS it with a clear
-- error rather than silently succeeding a second time. Closing is a
-- deliberate, audited action (closed_by/closed_at/notes) — a second close
-- attempt is far more likely to be a mistake (or a UI double-submit) than a
-- genuine intent to "re-close," and the unique(store_id, business_date)
-- constraint on daily_closings (0059) makes silent idempotency impossible
-- to distinguish from that mistake anyway without inspecting who/when the
-- first close happened, which a loud error surfaces naturally.
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

  -- Never a future Business Date (spec §19) — judged against
  -- public.business_today() (Asia/Riyadh), the same centralized resolver
  -- every other "today" default in this project uses since 0056/0057.
  if p_business_date > v_today then
    raise exception 'لا يمكن إغلاق تاريخ عمل مستقبلي (%)', p_business_date using errcode = 'P0001';
  end if;

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
  'Closes a store''s business day for Sales (spec §19) — requires sales.close_day, the store within the actor''s OPERABLE scope, and a non-future business_date (public.business_today()). Rejects (does not silently no-op) if the day is already closed. No Reopen/Hard Delete function exists in Phase 3 by design. SECURITY DEFINER — daily_closings has no direct-write RLS policy (0059), so this is the exclusive writer.';

revoke execute on function public.close_sales_day(uuid, date, text) from public;
grant execute on function public.close_sales_day(uuid, date, text) to authenticated;

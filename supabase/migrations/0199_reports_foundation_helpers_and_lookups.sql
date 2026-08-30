-- ============================================================================
-- Phase 8 — Reports, Dashboard & Exports — Foundation (0199)
-- ============================================================================
-- FREEZE: migrations 0001-0198 are the approved, frozen baseline (Phase 7 —
-- Settlements — officially accepted and closed). This migration adds ONLY
-- new objects; it touches zero existing rows/functions from 0001-0198.
--
-- This migration lays the shared foundation every later Phase 8 migration
-- (0200-0204) builds on:
--   Part A — the canonical Riyadh Week contract (Saturday -> Friday, §5),
--            documented centrally instead of being reinvented per-RPC.
--   Part B — trend-bucket helpers (day/week/month granularity + zero-filled
--            buckets, §19/§73) and comparison-period helpers (§18).
--   Part C — an internal store-filter resolver (§8: explicit unauthorized
--            filter is REJECTED, never silently ignored) reused by every
--            report/dashboard RPC in 0200-0204.
--   Part D — narrow, reports.view-gated metadata lookup RPCs (§49) so the
--            browser never needs stores.view/payment_methods.view/etc. just
--            to populate a report's filter dropdowns, and historical
--            (disabled) master-data rows stay selectable for old data
--            (§7/§23/§50).
--
-- No new permission keys: dashboard.view / dashboard.view_financials /
-- reports.view / reports.export_pdf / reports.export_excel already exist in
-- supabase/seed.sql (seeded ahead of need, exactly like settlements.view/
-- manage pre-existed Phase 7 -- see 0167's own header for this established
-- project convention). Migrations are always re-applied in full on every
-- upgrade; seed.sql is NOT re-run on an upgrade of an existing database, so
-- any permission key a real upgrade needs must come from a migration, not
-- seed.sql -- these five do not need to, because they were already added to
-- seed.sql in an earlier, already-approved phase and therefore already
-- exist on any database that ran seed.sql at any point after that phase.
-- §11 of this phase's spec: "أضف فقط إذا غير موجودة" -- nothing new is
-- needed, so nothing new is added.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Part A — Riyadh Week contract (§5): Saturday -> Friday, defined once,
-- centrally, in terms of business_today()'s own Asia/Riyadh semantics. Pure
-- date arithmetic (no further timezone conversion needed once the caller
-- already has a business `date`), so IMMUTABLE is correct here -- unlike
-- business_today() itself (STABLE, depends on now()).
-- ---------------------------------------------------------------------------
create or replace function public.riyadh_week_start(p_date date default public.business_today())
returns date
language sql
immutable
as $$
  -- Postgres extract(dow from date): 0=Sunday .. 6=Saturday. Days to walk
  -- back to the most recent Saturday: dow=6(Sat)->0, dow=0(Sun)->1,
  -- dow=1(Mon)->2, ..., dow=5(Fri)->6 -- i.e. (dow + 1) % 7.
  select p_date - (((extract(dow from p_date)::int + 1) % 7));
$$;

comment on function public.riyadh_week_start(date) is
  'Phase 8 §5 -- the canonical Week contract for this project: Saturday -> Friday. Returns the Saturday that starts the week containing p_date (default business_today()). Use this (and riyadh_week_end()) instead of ad-hoc per-report week math -- every Weekly report/chart/dashboard bucket must agree on the same week boundaries.';

create or replace function public.riyadh_week_end(p_date date default public.business_today())
returns date
language sql
immutable
as $$
  select public.riyadh_week_start(p_date) + 6;
$$;

comment on function public.riyadh_week_end(date) is
  'Phase 8 §5 -- the Friday that ends the Saturday->Friday week containing p_date. Pairs with riyadh_week_start().';

revoke execute on function public.riyadh_week_start(date) from public;
grant execute on function public.riyadh_week_start(date) to authenticated, service_role;
revoke execute on function public.riyadh_week_end(date) from public;
grant execute on function public.riyadh_week_end(date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Part B.1 — deterministic trend granularity (§19): short range -> day,
-- medium -> week, long -> month. Thresholds are a documented, fixed
-- server-side decision (not client-configurable) so a Screen chart and a
-- PDF/Excel export of the SAME range always agree.
-- ---------------------------------------------------------------------------
create or replace function public.report_trend_granularity(p_date_from date, p_date_to date)
returns text
language sql
immutable
as $$
  select case
    when p_date_to - p_date_from <= 31 then 'day'
    when p_date_to - p_date_from <= 180 then 'week'
    else 'month'
  end;
$$;

comment on function public.report_trend_granularity(date, date) is
  'Phase 8 §19 -- deterministic server-side trend bucket granularity: <=31 days -> day, <=180 days -> week, otherwise -> month. Fixed thresholds, never client-supplied, so Screen/PDF/Excel of the same range always pick the same granularity.';

revoke execute on function public.report_trend_granularity(date, date) from public;
grant execute on function public.report_trend_granularity(date, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Part B.2 — zero-filled date buckets (§73: "Trend series يجب تعيد Missing
-- Dates كـzero buckets"). Callers LEFT JOIN their aggregated data onto this
-- so a day/week/month with no activity still produces a real, present
-- bucket_start/bucket_end row with zero values -- never a gap in the series.
-- ---------------------------------------------------------------------------
create or replace function public.report_date_buckets(p_date_from date, p_date_to date, p_granularity text default null)
returns table (bucket_start date, bucket_end date, bucket_label text)
language plpgsql
immutable
as $$
declare
  v_gran text := coalesce(p_granularity, public.report_trend_granularity(p_date_from, p_date_to));
  v_start date;
begin
  if p_date_from is null or p_date_to is null then
    raise exception 'date_from/date_to مطلوبة' using errcode = 'P0001';
  end if;
  if p_date_from > p_date_to then
    raise exception 'date_from يجب أن يكون قبل أو يساوي date_to' using errcode = 'P0001';
  end if;
  if v_gran not in ('day', 'week', 'month') then
    raise exception 'granularity غير صالحة: % (المسموح: day/week/month)', v_gran using errcode = 'P0001';
  end if;

  if v_gran = 'day' then
    return query
      select gs::date, gs::date, to_char(gs, 'YYYY-MM-DD')
      from generate_series(p_date_from::timestamp, p_date_to::timestamp, interval '1 day') gs;
  elsif v_gran = 'week' then
    v_start := public.riyadh_week_start(p_date_from);
    return query
      select gs::date, least((gs::date + 6), p_date_to), to_char(gs, 'YYYY-MM-DD')
      from generate_series(v_start::timestamp, p_date_to::timestamp, interval '7 days') gs;
  else
    v_start := date_trunc('month', p_date_from)::date;
    return query
      select gs::date, least((gs + interval '1 month' - interval '1 day')::date, p_date_to), to_char(gs, 'YYYY-MM')
      from generate_series(v_start::timestamp, p_date_to::timestamp, interval '1 month') gs;
  end if;
end;
$$;

comment on function public.report_date_buckets(date, date, text) is
  'Phase 8 §19/§73 -- zero-filled trend buckets for [date_from, date_to] at the given (or auto-derived) granularity. Every bucket in range is returned even if the underlying data has none -- callers LEFT JOIN aggregated data onto this result, never the reverse, so a day/week/month with zero activity still appears as a real zero-value point.';

revoke execute on function public.report_date_buckets(date, date, text) from public;
grant execute on function public.report_date_buckets(date, date, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Part B.3 — comparison period (§18): "Custom Range vs immediately
-- preceding equal-length range". Monthly/Yearly reports (0204) use their
-- own calendar-aware previous-period logic instead (previous CALENDAR
-- month/year, which may have a different day count) -- this generic helper
-- is for the Dashboard and any range-based comparison, not calendar-unit
-- reports.
-- ---------------------------------------------------------------------------
create or replace function public.report_previous_period(p_date_from date, p_date_to date, out prev_date_from date, out prev_date_to date)
language sql
immutable
as $$
  select p_date_from - (p_date_to - p_date_from + 1), p_date_from - 1;
$$;

comment on function public.report_previous_period(date, date) is
  'Phase 8 §18 -- the immediately-preceding, equal-length comparison period for [date_from, date_to] (e.g. a 7-day range compares against the 7 days immediately before it). Used by the Dashboard''s generic period comparison. Monthly/Yearly reports use their own calendar-aware previous-period logic instead (see 0204).';

revoke execute on function public.report_previous_period(date, date) from public;
grant execute on function public.report_previous_period(date, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Part B.4 — null-safe percentage change (§18: "إذا previous = 0 لا تنتج
-- Infinity/NaN ... percentage_change = null"). Denominator uses abs(previous)
-- so a negative previous value still yields a sign-meaningful percentage
-- (e.g. previous=-100, current=-50 is a 50% IMPROVEMENT, not -50%).
-- ---------------------------------------------------------------------------
create or replace function public.report_pct_change(p_current numeric, p_previous numeric)
returns numeric
language sql
immutable
as $$
  select case
    when p_previous is null or p_previous = 0 then null
    else round((p_current - p_previous) / abs(p_previous) * 100, 2)
  end;
$$;

comment on function public.report_pct_change(numeric, numeric) is
  'Phase 8 §18/§43 -- null-safe percentage change: NULL (never Infinity/NaN) when p_previous is NULL or zero. Denominator is abs(p_previous) so a negative baseline still yields a sign-meaningful percentage.';

revoke execute on function public.report_pct_change(numeric, numeric) from public;
grant execute on function public.report_pct_change(numeric, numeric) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Part C — internal store-filter resolver (§8): every report/dashboard RPC
-- in 0200-0204 calls this exactly once. NULL/empty p_store_ids means "every
-- store the actor can see" (the actor's full visible scope, returned as-is
-- -- never silently narrowed). A NON-empty p_store_ids containing ANY store
-- outside the actor's visible scope is REJECTED outright (the "أفضل" /
-- preferred option in §8, not the "ignore" fallback) -- an explicit,
-- unauthorized filter never silently degrades to "whatever you can see
-- anyway", which could mislead an actor into believing a filtered total is
-- narrower than it actually is.
-- ---------------------------------------------------------------------------
create or replace function public._report_resolve_store_filter(p_actor uuid, p_store_ids uuid[])
returns uuid[]
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_visible uuid[];
  v_invalid uuid[];
begin
  select coalesce(array_agg(sid), array[]::uuid[]) into v_visible
  from public.user_visible_store_ids(p_actor) sid;

  if p_store_ids is null or array_length(p_store_ids, 1) is null then
    return v_visible;
  end if;

  select coalesce(array_agg(x), array[]::uuid[]) into v_invalid
  from unnest(p_store_ids) x
  where not (x = any(v_visible));

  if array_length(v_invalid, 1) > 0 then
    raise exception 'أحد المتاجر المطلوبة في الفلتر خارج نطاق رؤيتك' using errcode = 'P0001';
  end if;

  return p_store_ids;
end;
$$;

comment on function public._report_resolve_store_filter(uuid, uuid[]) is
  'Phase 8 §8 (internal) -- resolves a report''s store_ids filter against the actor''s user_visible_store_ids(): NULL/empty filter -> the actor''s full visible scope; a filter naming ANY store outside that scope -> explicit rejection (never silent narrowing/ignoring). Called from every report/dashboard RPC in 0200-0204. Not directly callable by authenticated (revoked from public, no explicit grant -- security definer callers run as this function''s owner).';

revoke execute on function public._report_resolve_store_filter(uuid, uuid[]) from public;

-- ---------------------------------------------------------------------------
-- Part D — narrow, reports.view-gated metadata lookup RPCs (§49). Every
-- lookup includes DISABLED/inactive rows -- Historical Stores (§7) and
-- historical categories/karats/payment methods/channels/carriers/
-- adjustment types/settlement routes (§23/§50) must stay selectable so a
-- filter can still target old data referencing a since-disabled row.
-- Minimum metadata only (id/code/name/status) -- never a hidden dependency
-- on that domain's own *.view permission (§49).
-- ---------------------------------------------------------------------------
create or replace function public.report_visible_stores_lookup()
returns table (id uuid, code text, name_ar text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض التقارير' using errcode = 'P0001';
  end if;
  return query
    select s.id, s.code, s.name_ar, s.status
    from public.stores s
    where exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = s.id)
    order by s.name_ar;
end;
$$;

comment on function public.report_visible_stores_lookup() is
  'Phase 8 §49/§8 -- store filter options for report/dashboard UIs: every store the actor may VIEW (active or disabled, §7 Historical Stores), minimum metadata. Gated on reports.view only -- never requires stores.view.';

revoke execute on function public.report_visible_stores_lookup() from public;
grant execute on function public.report_visible_stores_lookup() to authenticated;

create or replace function public.report_categories_lookup()
returns table (id uuid, code text, name_ar text, parent_id uuid, status text)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if auth.uid() is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض التقارير' using errcode = 'P0001';
  end if;
  return query
    select c.id, c.code, c.name_ar, c.parent_id, c.status
    from public.product_categories c
    order by c.sort_order, c.name_ar;
end;
$$;

comment on function public.report_categories_lookup() is
  'Phase 8 §49/§23 -- category filter options (including disabled/historical categories, hierarchy via parent_id). Gated on reports.view only.';

revoke execute on function public.report_categories_lookup() from public;
grant execute on function public.report_categories_lookup() to authenticated;

create or replace function public.report_karats_lookup()
returns table (id uuid, code text, name_ar text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if auth.uid() is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض التقارير' using errcode = 'P0001';
  end if;
  return query select k.id, k.code, k.name_ar, k.status from public.karats k order by k.sort_order, k.name_ar;
end;
$$;

comment on function public.report_karats_lookup() is 'Phase 8 §49 -- karat filter options (including disabled/historical). Gated on reports.view only.';
revoke execute on function public.report_karats_lookup() from public;
grant execute on function public.report_karats_lookup() to authenticated;

create or replace function public.report_payment_methods_lookup()
returns table (id uuid, key text, name_ar text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if auth.uid() is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض التقارير' using errcode = 'P0001';
  end if;
  return query select p.id, p.key, p.name_ar, p.status from public.payment_methods p order by p.name_ar;
end;
$$;

comment on function public.report_payment_methods_lookup() is 'Phase 8 §49 -- payment method filter options (including disabled/historical). Gated on reports.view only.';
revoke execute on function public.report_payment_methods_lookup() from public;
grant execute on function public.report_payment_methods_lookup() to authenticated;

create or replace function public.report_collection_channels_lookup()
returns table (id uuid, key text, name_ar text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if auth.uid() is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض التقارير' using errcode = 'P0001';
  end if;
  return query select c.id, c.key, c.name_ar, c.status from public.collection_channels c order by c.sort_order, c.name_ar;
end;
$$;

comment on function public.report_collection_channels_lookup() is 'Phase 8 §49 -- collection channel filter options (including disabled/historical). Gated on reports.view only.';
revoke execute on function public.report_collection_channels_lookup() from public;
grant execute on function public.report_collection_channels_lookup() to authenticated;

create or replace function public.report_shipping_carriers_lookup()
returns table (id uuid, code text, name_ar text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if auth.uid() is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض التقارير' using errcode = 'P0001';
  end if;
  return query select c.id, c.code, c.name_ar, c.status from public.shipping_carriers c order by c.name_ar;
end;
$$;

comment on function public.report_shipping_carriers_lookup() is 'Phase 8 §49 -- carrier filter options (including disabled/historical). Gated on reports.view only.';
revoke execute on function public.report_shipping_carriers_lookup() from public;
grant execute on function public.report_shipping_carriers_lookup() to authenticated;

create or replace function public.report_adjustment_types_lookup()
returns table (id uuid, code text, name_ar text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if auth.uid() is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض التقارير' using errcode = 'P0001';
  end if;
  return query select t.id, t.code, t.name_ar, t.status from public.adjustment_types t order by t.sort_order, t.name_ar;
end;
$$;

comment on function public.report_adjustment_types_lookup() is 'Phase 8 §49 -- adjustment type filter options (including disabled/historical). Gated on reports.view only.';
revoke execute on function public.report_adjustment_types_lookup() from public;
grant execute on function public.report_adjustment_types_lookup() to authenticated;

create or replace function public.report_settlement_routes_lookup()
returns table (id uuid, code text, name_ar text, route_kind text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if auth.uid() is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض التقارير' using errcode = 'P0001';
  end if;
  return query select r.id, r.code, r.name_ar, r.route_kind, r.status from public.settlement_routes r order by r.name_ar;
end;
$$;

comment on function public.report_settlement_routes_lookup() is 'Phase 8 §49 -- settlement route filter options (including disabled/historical). Gated on reports.view only.';
revoke execute on function public.report_settlement_routes_lookup() from public;
grant execute on function public.report_settlement_routes_lookup() to authenticated;

create or replace function public.report_employees_lookup()
returns table (id uuid, full_name text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if auth.uid() is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض التقارير' using errcode = 'P0001';
  end if;
  -- Every profile that has ever been a Sale's salesperson_id OR created_by
  -- on a Sale/Return/Shipment/Adjustment -- "employee" for reporting
  -- purposes is defined by real sales/operational attribution, not by role.
  return query
    select distinct p.id, p.full_name, p.status
    from public.profiles p
    where exists (select 1 from public.sales_orders so where so.salesperson_id = p.id)
       or exists (select 1 from public.sales_orders so where so.created_by = p.id)
    order by p.full_name;
end;
$$;

comment on function public.report_employees_lookup() is 'Phase 8 §25/§49 -- employee filter options: every profile with real Sales attribution (salesperson_id or created_by on a sales_orders row), including now-inactive accounts (historical attribution must stay filterable). Gated on reports.view only.';
revoke execute on function public.report_employees_lookup() from public;
grant execute on function public.report_employees_lookup() to authenticated;

commit;

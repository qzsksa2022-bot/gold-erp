-- ============================================================================
-- 0056: Final Integrity Hotfix 2.2.1 (2/2) — centralized Asia/Riyadh Business
-- Date, used instead of current_date in Manufacturing/Payment Fee
-- versioning logic
-- ============================================================================
-- Gap closed here (hotfix item 3): every date comparison in the fee-
-- versioning logic (create_manufacturing_fee_version()/create_payment_
-- method_fee_version()'s "is the open version itself still in the future"
-- check added by 0053, cancel_manufacturing_fee_version()/cancel_payment_
-- method_fee_version()'s "is this version already effective" check from
-- 0047, and manufacturing_fee_for_karat_on_date()/payment_fee_for_method_
-- on_date()'s default `p_date` parameter from 0042/0045) used Postgres'
-- own `current_date`, which resolves against the DATABASE SERVER's
-- configured timezone (UTC on this project's Postgres instances -- `SHOW
-- timezone` -- and on a real Supabase project) -- NOT this business'
-- operating timezone, Asia/Riyadh (UTC+3, no DST -- see src/lib/date.ts's
-- APP_TIMEZONE, the app-layer equivalent of what this migration adds at
-- the database layer). During the ~3-hour window each day where the UTC
-- calendar date and the Riyadh calendar date genuinely differ (a Riyadh
-- "day" runs 21:00 UTC to 20:59 UTC the next day), `current_date` silently
-- answers the WRONG question for a business rule that is inherently about
-- "today, in Riyadh" -- e.g. a fee version scheduled `effective_from =
-- <tomorrow in Riyadh>` could be misjudged as already-effective (or
-- vice-versa) purely because the database server's clock/timezone setting
-- does not know or care what timezone this business operates in.
--
-- Fix: a single centralized public.business_today() function, and every
-- fee-versioning function above re-declared (CREATE OR REPLACE, same
-- signature, same SECURITY/search_path/REVOKE/GRANT properties as before --
-- this migration changes ONLY the date source, never behavior/
-- authorization otherwise) to call it instead of `current_date`.
--
-- Scope, deliberately narrow (matches the hotfix request precisely): this
-- migration touches ONLY the Manufacturing Fee / Payment Method Fee
-- versioning functions named above. It does NOT touch daily_gold_prices'
-- functions (gold_price_for_karat_on_date()'s `p_date default current_date`,
-- gold_prices_missing_for_date()'s equivalent, or save_daily_gold_price()/
-- save_daily_gold_prices_bulk(), which do not reference current_date at
-- all) -- those were not named in this hotfix's scope, and changing them
-- was not requested. If the same Riyadh-business-date correction is wanted
-- there too, that is a separate, explicit follow-up request; business_
-- today() below is written as general-purpose (no dependency on anything
-- fee-versioning-specific) so applying it elsewhere later is a small,
-- mechanical change, not a redesign.
-- ---------------------------------------------------------------------------
create or replace function public.business_today()
returns date
language sql
stable
as $$
  select (now() at time zone 'Asia/Riyadh')::date;
$$;

comment on function public.business_today() is
  'The current business date in this project''s operating timezone, Asia/Riyadh (UTC+3, no DST -- matches src/lib/date.ts''s APP_TIMEZONE exactly). Use this instead of Postgres'' own current_date/now()::date for any business-facing "what day is it" decision -- current_date resolves against the DATABASE SERVER''s timezone setting (UTC on this project''s Postgres instances), which is NOT necessarily this business'' calendar day. STABLE (not IMMUTABLE): consistent within one statement/transaction (now() is fixed per transaction), correctly re-evaluated on the next one. As of 0056, used by create_manufacturing_fee_version()/create_payment_method_fee_version()/cancel_manufacturing_fee_version()/cancel_payment_method_fee_version()/manufacturing_fee_for_karat_on_date()/payment_fee_for_method_on_date() -- see migration 0056 header comment for why the scope stops there for now.';

-- ---------------------------------------------------------------------------
-- manufacturing_fee_for_karat_on_date() / payment_fee_for_method_on_date():
-- only the default parameter value changes (current_date -> business_
-- today()) -- resolution logic (status <> 'cancelled', effective_from <=
-- p_date <= effective_to-or-open) is byte-for-byte unchanged from 0042/0045.
-- A caller passing an explicit p_date is entirely unaffected either way.
-- ---------------------------------------------------------------------------
create or replace function public.manufacturing_fee_for_karat_on_date(p_karat_id uuid, p_date date default public.business_today())
returns numeric
language plpgsql
stable
as $$
declare
  v_fee numeric;
begin
  select fee_per_gram into v_fee
  from public.manufacturing_fee_versions
  where karat_id = p_karat_id
    and status <> 'cancelled'
    and effective_from <= p_date
    and (effective_to is null or effective_to >= p_date)
  order by effective_from desc
  limit 1;

  if v_fee is null then
    raise exception 'لا توجد مصنعية معتمدة لهذا العيار بتاريخ %', p_date using errcode = 'P0001';
  end if;

  return v_fee;
end;
$$;

comment on function public.manufacturing_fee_for_karat_on_date(uuid, date) is
  'Manufacturing fee per gram applicable to a karat on a date, resolved from manufacturing_fee_versions. Raises P0001 (not NULL/0) if no active version covers that date. As of 0056: default p_date is public.business_today() (Asia/Riyadh calendar date), not Postgres'' current_date (the database server''s own timezone) -- see migration 0056 header comment.';

create or replace function public.payment_fee_for_method_on_date(p_payment_method_id uuid, p_date date default public.business_today())
returns table (fee_version_id uuid, percentage_fee numeric, fixed_fee numeric)
language plpgsql
stable
as $$
declare
  v_row record;
begin
  select v.id, v.percentage_fee, v.fixed_fee
  into v_row
  from public.payment_method_fee_versions v
  where v.payment_method_id = p_payment_method_id
    and v.status <> 'cancelled'
    and v.effective_from <= p_date
    and (v.effective_to is null or v.effective_to >= p_date)
  order by v.effective_from desc
  limit 1;

  if v_row.id is null then
    raise exception 'لا توجد نسبة/رسوم معتمدة لطريقة الدفع هذه بتاريخ %', p_date using errcode = 'P0001';
  end if;

  fee_version_id := v_row.id;
  percentage_fee := v_row.percentage_fee;
  fixed_fee := v_row.fixed_fee;
  return next;
end;
$$;

comment on function public.payment_fee_for_method_on_date(uuid, date) is
  'Fee configuration (percentage_fee, fixed_fee) applicable to a payment method on a date. Raises P0001 if no active version covers that date. As of 0056: default p_date is public.business_today() (Asia/Riyadh), not current_date -- see migration 0056 header comment.';

-- ---------------------------------------------------------------------------
-- create_manufacturing_fee_version() / create_payment_method_fee_version():
-- only the 0053 "is the open version itself still in the future" check's
-- comparison changes (current_date -> business_today()) -- every other line
-- is byte-for-byte identical to 0053's version.
-- ---------------------------------------------------------------------------
create or replace function public.create_manufacturing_fee_version(
  p_karat_id uuid,
  p_fee_per_gram numeric,
  p_effective_from date,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_open record;
  v_today date := public.business_today();
begin
  if not public.has_permission('manufacturing_fees.manage') then
    raise exception 'ليست لديك صلاحية إدارة المصنعية' using errcode = 'P0001';
  end if;

  if p_karat_id is null or p_fee_per_gram is null or p_effective_from is null then
    raise exception 'العيار، قيمة المصنعية، وتاريخ السريان كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_fee_per_gram < 0 then
    raise exception 'قيمة المصنعية لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  select * into v_open
  from public.manufacturing_fee_versions
  where karat_id = p_karat_id and effective_to is null and status = 'active'
  for update;

  if found then
    if v_open.effective_from > v_today then
      raise exception 'يوجد بالفعل إصدار مصنعية مستقبلي مجدوَل لهذا العيار (يسري اعتبارًا من %) ولم يسرِ بعد — لا يمكن جدولة إصدار مستقبلي آخر فوقه. ألغِ الإصدار المستقبلي الحالي عبر cancel_manufacturing_fee_version() أولًا، ثم أنشئ الإصدار الجديد.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار مصنعية سارٍ/مجدوَل لهذا العيار بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق. لإلغاء إصدار مستقبلي لم يسرِ بعد، استخدم cancel_manufacturing_fee_version أولًا.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.manufacturing_fee_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.manufacturing_fee_versions (karat_id, fee_per_gram, effective_from, effective_to, status, notes, created_by)
  values (p_karat_id, p_fee_per_gram, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_manufacturing_fee_version(uuid, numeric, date, text) is
  'Atomically ends the karat''s currently open manufacturing fee version (if the new effective_from is after it) and inserts the new one. At most one Future Version per karat (0053) -- cancel it first via cancel_manufacturing_fee_version(). As of 0056: "is the open version itself still in the future" is judged against public.business_today() (Asia/Riyadh), not current_date. SECURITY DEFINER (0047).';

revoke execute on function public.create_manufacturing_fee_version(uuid, numeric, date, text) from public;
grant execute on function public.create_manufacturing_fee_version(uuid, numeric, date, text) to authenticated;

create or replace function public.create_payment_method_fee_version(
  p_payment_method_id uuid,
  p_percentage_fee numeric,
  p_fixed_fee numeric,
  p_effective_from date,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_open record;
  v_today date := public.business_today();
begin
  if not public.has_permission('payment_methods.manage') then
    raise exception 'ليست لديك صلاحية إدارة طرق الدفع' using errcode = 'P0001';
  end if;

  if p_payment_method_id is null or p_effective_from is null then
    raise exception 'طريقة الدفع وتاريخ السريان مطلوبان' using errcode = 'P0001';
  end if;

  p_percentage_fee := coalesce(p_percentage_fee, 0);
  p_fixed_fee := coalesce(p_fixed_fee, 0);

  if p_percentage_fee < 0 or p_fixed_fee < 0 then
    raise exception 'قيم العمولة لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  select * into v_open
  from public.payment_method_fee_versions
  where payment_method_id = p_payment_method_id and effective_to is null and status = 'active'
  for update;

  if found then
    if v_open.effective_from > v_today then
      raise exception 'يوجد بالفعل إصدار عمولة مستقبلي مجدوَل لهذه الطريقة (يسري اعتبارًا من %) ولم يسرِ بعد — لا يمكن جدولة إصدار مستقبلي آخر فوقه. ألغِ الإصدار المستقبلي الحالي عبر cancel_payment_method_fee_version() أولًا، ثم أنشئ الإصدار الجديد.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار عمولة سارٍ/مجدوَل لهذه الطريقة بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق. لإلغاء إصدار مستقبلي لم يسرِ بعد، استخدم cancel_payment_method_fee_version أولًا.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.payment_method_fee_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.payment_method_fee_versions
    (payment_method_id, percentage_fee, fixed_fee, effective_from, effective_to, status, notes, created_by)
  values
    (p_payment_method_id, p_percentage_fee, p_fixed_fee, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) is
  'Atomically ends the payment method''s currently open fee version (if the new effective_from is after it) and inserts the new one. At most one Future Version per payment method (0053) -- cancel it first via cancel_payment_method_fee_version(). As of 0056: "is the open version itself still in the future" is judged against public.business_today() (Asia/Riyadh), not current_date. SECURITY DEFINER (0047).';

revoke execute on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) from public;
grant execute on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- cancel_manufacturing_fee_version() / cancel_payment_method_fee_version():
-- only the "is this version already effective" comparison changes
-- (current_date -> business_today()) -- every other line, including the
-- predecessor-reopen logic, is byte-for-byte identical to 0047's version.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_manufacturing_fee_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_predecessor record;
begin
  if not public.has_permission('manufacturing_fees.manage') then
    raise exception 'ليست لديك صلاحية إدارة المصنعية' using errcode = 'P0001';
  end if;

  select * into v_row from public.manufacturing_fee_versions where id = p_version_id for update;

  if not found then
    raise exception 'إصدار المصنعية غير موجود' using errcode = 'P0001';
  end if;

  if v_row.status <> 'active' then
    raise exception 'هذا الإصدار ليس نشِطًا أصلًا (تم إلغاؤه أو استبداله سابقًا)' using errcode = 'P0001';
  end if;

  if v_row.effective_from <= public.business_today() then
    raise exception 'لا يمكن إلغاء إصدار مصنعية سارٍ بالفعل أو مضى تاريخ سريانه — يُسمح فقط بإلغاء إصدار مستقبلي لم يسرِ بعد' using errcode = 'P0001';
  end if;

  update public.manufacturing_fee_versions set status = 'cancelled' where id = p_version_id;

  select * into v_predecessor
  from public.manufacturing_fee_versions
  where karat_id = v_row.karat_id and status = 'ended' and effective_to = v_row.effective_from - 1
  for update;

  if found then
    update public.manufacturing_fee_versions
    set effective_to = null, status = 'active'
    where id = v_predecessor.id;
  end if;
end;
$$;

comment on function public.cancel_manufacturing_fee_version(uuid) is
  'Withdraws a manufacturing fee version that has not taken effect yet, and atomically reopens the exact predecessor it had ended (0047). As of 0056: "already effective" is judged against public.business_today() (Asia/Riyadh), not current_date. SECURITY DEFINER.';

revoke execute on function public.cancel_manufacturing_fee_version(uuid) from public;
grant execute on function public.cancel_manufacturing_fee_version(uuid) to authenticated;

create or replace function public.cancel_payment_method_fee_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_predecessor record;
begin
  if not public.has_permission('payment_methods.manage') then
    raise exception 'ليست لديك صلاحية إدارة طرق الدفع' using errcode = 'P0001';
  end if;

  select * into v_row from public.payment_method_fee_versions where id = p_version_id for update;

  if not found then
    raise exception 'إصدار العمولة غير موجود' using errcode = 'P0001';
  end if;

  if v_row.status <> 'active' then
    raise exception 'هذا الإصدار ليس نشِطًا أصلًا (تم إلغاؤه أو استبداله سابقًا)' using errcode = 'P0001';
  end if;

  if v_row.effective_from <= public.business_today() then
    raise exception 'لا يمكن إلغاء إصدار عمولة سارٍ بالفعل أو مضى تاريخ سريانه — يُسمح فقط بإلغاء إصدار مستقبلي لم يسرِ بعد' using errcode = 'P0001';
  end if;

  update public.payment_method_fee_versions set status = 'cancelled' where id = p_version_id;

  select * into v_predecessor
  from public.payment_method_fee_versions
  where payment_method_id = v_row.payment_method_id and status = 'ended' and effective_to = v_row.effective_from - 1
  for update;

  if found then
    update public.payment_method_fee_versions
    set effective_to = null, status = 'active'
    where id = v_predecessor.id;
  end if;
end;
$$;

comment on function public.cancel_payment_method_fee_version(uuid) is
  'Withdraws a payment fee version that has not taken effect yet, and atomically reopens the exact predecessor it had ended (0047). As of 0056: "already effective" is judged against public.business_today() (Asia/Riyadh), not current_date. SECURITY DEFINER. Mirrors cancel_manufacturing_fee_version() exactly.';

revoke execute on function public.cancel_payment_method_fee_version(uuid) from public;
grant execute on function public.cancel_payment_method_fee_version(uuid) to authenticated;

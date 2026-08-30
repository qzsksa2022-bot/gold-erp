-- ============================================================================
-- 0066: Phase 3 — Sales Integrity Patch 3.1 (2/7): exclusive financial-master
-- lock on every financial-master WRITER
-- ============================================================================
-- Migrations 0001-0065 are unmodified. Spec item 7: "Gold Price أو
-- Manufacturing/VAT/Payment Fee يجب ألا يتغيّر في منتصف بناء Snapshots لنفس
-- الـ Order" — the exclusive-lock half of that fix, covering "ALL actual
-- write paths, especially direct/RPC writes for gold prices" as required.
--
-- Every function below is reproduced CREATE OR REPLACE with its EXACT
-- existing body from its last migration (0054 for the two gold-price
-- functions, 0056 for the two fee-version functions, 0058 for the VAT
-- function) — same signature, same SECURITY/search_path/REVOKE/GRANT
-- properties, same validation order, same error messages — with exactly ONE
-- new line inserted immediately after each function's existing
-- has_permission() check:
--   perform public.acquire_financial_master_lock_exclusive();
-- Acquired AFTER the permission check (so an unauthorized caller is
-- rejected before ever touching the lock — no reason to make an
-- unprivileged actor wait on, or be blocked by, a lock they were never
-- going to be allowed to use) and BEFORE any read/validate/write of the
-- target table, so the exclusive hold covers this function's entire
-- remaining body, including its own internal `for update` guard on the
-- currently-open version.
--
-- Scope, deliberately excludes cancel_manufacturing_fee_version() /
-- cancel_payment_method_fee_version() / cancel_vat_rate_version(): all three
-- can only ever act on a version whose effective_from is STRICTLY IN THE
-- FUTURE relative to public.business_today() (each already enforces this
-- itself — "لا يمكن إلغاء إصدار ... سارٍ بالفعل أو مضى تاريخ سريانه"), and
-- create_sales_order()/update_sales_order() already reject any sale_date
-- after business_today() (0061/0063, unchanged by this patch). A concurrent
-- Sale can therefore never be resolving snapshots against a version that a
-- concurrent cancel could simultaneously withdraw — cancelling only ever
-- touches a version no in-flight Sale could legally be reading yet. Adding
-- the lock there would only add contention with zero corresponding
-- correctness benefit, so it is intentionally omitted; this reasoning is
-- recorded here rather than silently leaving the three cancel_* functions
-- unmentioned.
--
-- save_daily_gold_price() / save_daily_gold_prices_bulk() are (and remain)
-- SECURITY INVOKER — acquire_financial_master_lock_exclusive() is GRANTed to
-- `authenticated` directly (0065) for exactly this reason: a SECURITY
-- INVOKER caller cannot rely on an owner-only EXECUTE grant.
-- ---------------------------------------------------------------------------
create or replace function public.save_daily_gold_price(
  p_price_date date,
  p_karat_id uuid,
  p_price_per_gram numeric,
  p_notes text default null
)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
  v_karat_status text;
  v_row_exists boolean;
begin
  if not public.has_permission('gold_prices.edit') then
    raise exception 'ليست لديك صلاحية تعديل أسعار الذهب' using errcode = 'P0001';
  end if;

  perform public.acquire_financial_master_lock_exclusive();

  if p_price_date is null or p_karat_id is null or p_price_per_gram is null then
    raise exception 'التاريخ والعيار والسعر كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_price_per_gram <= 0 then
    raise exception 'السعر يجب أن يكون رقمًا موجبًا' using errcode = 'P0001';
  end if;

  v_karat_status := public.karat_status_for_price_entry(p_karat_id);
  if v_karat_status is null then
    raise exception 'عيار غير موجود' using errcode = 'P0001';
  end if;

  select true into v_row_exists from public.daily_gold_prices
    where price_date = p_price_date and karat_id = p_karat_id;

  if v_karat_status <> 'active' and v_row_exists is null then
    raise exception 'لا يمكن تسجيل سعر جديد لعيار غير نشط' using errcode = 'P0001';
  end if;

  insert into public.daily_gold_prices
    (price_date, karat_id, price_per_gram, source_type, is_manual_override, notes, created_by, updated_by)
  values
    (p_price_date, p_karat_id, p_price_per_gram, 'manual', true, p_notes, auth.uid(), auth.uid())
  on conflict (price_date, karat_id) do update
    set price_per_gram = excluded.price_per_gram,
        source_type = 'manual',
        is_manual_override = true,
        notes = excluded.notes,
        updated_by = auth.uid(),
        updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.save_daily_gold_price(date, uuid, numeric, text) is
  'Upserts one (price_date, karat_id) price row via an explicit column list -- created_by/created_at set on first insert only, never touched again on a later same-day correction. Always stamps source_type=manual/is_manual_override=true (also enforced unconditionally by the daily_gold_prices_enforce_source_integrity trigger, 0051 -- belt and suspenders). As of 0054: rejects creating a BRAND NEW price row for an inactive karat (a pre-existing row for that (date, karat) pair may still be corrected via the same ON CONFLICT path -- only genuinely new rows for an inactive karat are blocked). Karat status is read via karat_status_for_price_entry() (SECURITY DEFINER), not a raw SELECT, so this check is correct regardless of whether the caller separately holds karats.view. As of 0066 (Patch 3.1 item 7): acquires the EXCLUSIVE financial-master advisory lock (acquire_financial_master_lock_exclusive(), 0065) immediately after the permission check, so this write can never commit in the middle of a concurrent Sale''s multi-item snapshot resolution.';

create or replace function public.save_daily_gold_prices_bulk(
  p_price_date date,
  p_entries jsonb
)
returns setof uuid
language plpgsql
as $$
declare
  v_entry jsonb;
  v_karat_id uuid;
  v_price numeric;
  v_notes text;
  v_seen uuid[] := '{}'::uuid[];
  v_id uuid;
  v_karat_status text;
  v_row_exists boolean;
begin
  if not public.has_permission('gold_prices.edit') then
    raise exception 'ليست لديك صلاحية تعديل أسعار الذهب' using errcode = 'P0001';
  end if;

  perform public.acquire_financial_master_lock_exclusive();

  if p_price_date is null then
    raise exception 'التاريخ مطلوب' using errcode = 'P0001';
  end if;

  if p_entries is null or jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) = 0 then
    raise exception 'لا توجد أسعار لحفظها' using errcode = 'P0001';
  end if;

  -- Validation pass FIRST, before any write.
  for v_entry in select * from jsonb_array_elements(p_entries)
  loop
    if v_entry ->> 'karat_id' is null then
      raise exception 'كل سطر يجب أن يحدد karat_id' using errcode = 'P0001';
    end if;

    v_karat_id := (v_entry ->> 'karat_id')::uuid;

    if v_karat_id = any(v_seen) then
      raise exception 'يوجد عيار مكرر في نفس الطلب (karat_id: %)', v_karat_id using errcode = 'P0001';
    end if;
    v_seen := array_append(v_seen, v_karat_id);

    v_karat_status := public.karat_status_for_price_entry(v_karat_id);
    if v_karat_status is null then
      raise exception 'عيار غير موجود (karat_id: %)', v_karat_id using errcode = 'P0001';
    end if;

    -- As of 0054: an inactive karat may only receive this write if a price
    -- row for this exact (price_date, karat_id) already exists (a genuine
    -- correction) -- never a brand-new row.
    if v_karat_status <> 'active' then
      select true into v_row_exists from public.daily_gold_prices
        where price_date = p_price_date and karat_id = v_karat_id;
      if v_row_exists is null then
        raise exception 'لا يمكن تسجيل سعر جديد لعيار غير نشط (karat_id: %)', v_karat_id using errcode = 'P0001';
      end if;
    end if;

    if v_entry ->> 'price_per_gram' is null then
      raise exception 'السعر مطلوب لكل عيار (karat_id: %)', v_karat_id using errcode = 'P0001';
    end if;

    v_price := (v_entry ->> 'price_per_gram')::numeric;
    if v_price <= 0 then
      raise exception 'السعر يجب أن يكون رقمًا موجبًا لكل عيار (karat_id: %)', v_karat_id using errcode = 'P0001';
    end if;
  end loop;

  -- Write pass: same explicit-column upsert shape as save_daily_gold_price().
  for v_entry in select * from jsonb_array_elements(p_entries)
  loop
    v_karat_id := (v_entry ->> 'karat_id')::uuid;
    v_price := (v_entry ->> 'price_per_gram')::numeric;
    v_notes := v_entry ->> 'notes';

    insert into public.daily_gold_prices
      (price_date, karat_id, price_per_gram, source_type, is_manual_override, notes, created_by, updated_by)
    values
      (p_price_date, v_karat_id, v_price, 'manual', true, v_notes, auth.uid(), auth.uid())
    on conflict (price_date, karat_id) do update
      set price_per_gram = excluded.price_per_gram,
          source_type = 'manual',
          is_manual_override = true,
          notes = excluded.notes,
          updated_by = auth.uid(),
          updated_at = now()
    returning id into v_id;

    return next v_id;
  end loop;

  return;
end;
$$;

comment on function public.save_daily_gold_prices_bulk(date, jsonb) is
  'Atomic "save today''s prices" entry point -- validates every entry (karat exists AND, as of 0054, is active OR a row already exists for this exact date/karat; no duplicate karat in the payload; price > 0) before writing any row; one failing entry rolls back the whole call. Always forces source_type=manual/is_manual_override=true (also enforced unconditionally by the daily_gold_prices_enforce_source_integrity trigger, 0051). Karat status read via karat_status_for_price_entry() (SECURITY DEFINER) -- see that function''s comment for why a raw SELECT would have been wrong here. SECURITY INVOKER (default) -- RLS + has_permission(''gold_prices.edit'') govern as usual. As of 0066 (Patch 3.1 item 7): acquires the EXCLUSIVE financial-master advisory lock immediately after the permission check, covering the entire validate+write call.';

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

  perform public.acquire_financial_master_lock_exclusive();

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
  'Atomically ends the karat''s currently open manufacturing fee version (if the new effective_from is after it) and inserts the new one. At most one Future Version per karat (0053) -- cancel it first via cancel_manufacturing_fee_version(). As of 0056: "is the open version itself still in the future" is judged against public.business_today() (Asia/Riyadh), not current_date. SECURITY DEFINER (0047). As of 0066 (Patch 3.1 item 7): acquires the EXCLUSIVE financial-master advisory lock immediately after the permission check.';

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

  perform public.acquire_financial_master_lock_exclusive();

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
  'Atomically ends the payment method''s currently open fee version (if the new effective_from is after it) and inserts the new one. At most one Future Version per payment method (0053) -- cancel it first via cancel_payment_method_fee_version(). As of 0056: "is the open version itself still in the future" is judged against public.business_today() (Asia/Riyadh), not current_date. SECURITY DEFINER (0047). As of 0066 (Patch 3.1 item 7): acquires the EXCLUSIVE financial-master advisory lock immediately after the permission check.';

revoke execute on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) from public;
grant execute on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) to authenticated;

create or replace function public.create_vat_rate_version(
  p_rate_percent numeric,
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
  if not public.has_permission('vat_rates.manage') then
    raise exception 'ليست لديك صلاحية إدارة ضريبة القيمة المضافة' using errcode = 'P0001';
  end if;

  perform public.acquire_financial_master_lock_exclusive();

  if p_rate_percent is null or p_effective_from is null then
    raise exception 'نسبة الضريبة وتاريخ السريان كلاهما مطلوبان' using errcode = 'P0001';
  end if;

  if p_rate_percent < 0 or p_rate_percent > 100 then
    raise exception 'نسبة ضريبة القيمة المضافة يجب أن تكون بين 0 و 100' using errcode = 'P0001';
  end if;

  select * into v_open
  from public.vat_rate_versions
  where effective_to is null and status = 'active'
  for update;

  if found then
    if v_open.effective_from > v_today then
      raise exception 'يوجد بالفعل إصدار ضريبة مستقبلي مجدوَل (يسري اعتبارًا من %) ولم يسرِ بعد — لا يمكن جدولة إصدار مستقبلي آخر فوقه. ألغِ الإصدار المستقبلي الحالي عبر cancel_vat_rate_version() أولًا، ثم أنشئ الإصدار الجديد.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار ضريبة سارٍ/مجدوَل بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق. لإلغاء إصدار مستقبلي لم يسرِ بعد، استخدم cancel_vat_rate_version أولًا.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.vat_rate_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.vat_rate_versions (rate_percent, effective_from, effective_to, status, notes, created_by)
  values (p_rate_percent, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_vat_rate_version(numeric, date, text) is
  'Atomically ends the currently open VAT version (if the new effective_from is after it) and inserts the new one — the only sanctioned way to change the VAT rate. At most one Future Version system-wide (cancel it first via cancel_vat_rate_version()). "Still future"/"already effective" are judged against public.business_today() (Asia/Riyadh), not current_date. SECURITY DEFINER — this table has no direct-write RLS policy at all, so this function is the exclusive write path. As of 0066 (Patch 3.1 item 7): acquires the EXCLUSIVE financial-master advisory lock immediately after the permission check.';

revoke execute on function public.create_vat_rate_version(numeric, date, text) from public;
grant execute on function public.create_vat_rate_version(numeric, date, text) to authenticated;

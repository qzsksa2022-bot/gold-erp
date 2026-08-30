-- ============================================================================
-- 0054: Financial Integrity Patch 2.2 (4/4) — active-karat check for prices
-- ============================================================================
-- Spec item 4. save_daily_gold_prices_bulk() (0050) validates that each
-- karat_id exists (`select true into v_karat_exists from public.karats
-- where id = v_karat_id`) but never checked whether that karat is still
-- `active` -- a disabled karat could still receive a brand-new daily price
-- row through the normal operational entry flow, which is a modeling
-- contradiction: disabling a karat is meant to stop new usage of it (0047
-- already enforces exactly this same principle for manufacturing fee
-- versions and payment fee versions -- "a version can never be created for
-- an inactive karat/payment method"). Fixed here for both bulk and
-- single-karat save (save_daily_gold_price(), 0041, has the identical gap
-- and gets the identical fix for consistency -- the spec named the bulk
-- function specifically, but leaving the single-karat RPC with a different,
-- weaker rule than its own sibling would just be a second, narrower version
-- of the same gap).
--
-- Scope, precisely: this blocks creating a NEW price row (a price_date this
-- karat has never had a row for) for an inactive karat. It does NOT block
-- correcting an EXISTING price row that already exists for a date before
-- the karat was disabled (ON CONFLICT DO UPDATE still succeeds for a
-- pre-existing row) -- reading and correcting history stays unaffected,
-- matching the exact same "don't block history/authorized corrections"
-- constraint spec item 1 stated explicitly for the source-integrity fix
-- above.
--
-- Both save functions are (and remain) SECURITY INVOKER -- authorization is
-- via has_permission('gold_prices.edit'), not via table-level RLS visibility
-- into karats. A plain `select status from public.karats where id = ...`
-- would run under the CALLER's own RLS as an invoker function, which would
-- silently return NULL (misread as "karat not found") for an actor who
-- legitimately holds gold_prices.edit but not karats.view (a real,
-- pre-existing test actor in financial_master_data.test.sql exercises
-- exactly this permission split) -- gold price editing must not be secretly
-- coupled to also holding karats.view. karat_status_for_price_entry() below
-- is a narrow-scope SECURITY DEFINER wrapper (same pattern as
-- am_i_super_admin() from Foundation 0015: a self-scoped read exposed to
-- `authenticated` specifically so a caller without direct table visibility
-- can still get this one narrow, safe fact) used by both functions instead
-- of a raw SELECT against karats.
create or replace function public.karat_status_for_price_entry(p_karat_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select status from public.karats where id = p_karat_id;
$$;

comment on function public.karat_status_for_price_entry(uuid) is
  'Narrow-scope SECURITY DEFINER read: the status of one karat by id, bypassing RLS -- used internally by save_daily_gold_price()/save_daily_gold_prices_bulk() (both SECURITY INVOKER) so an actor holding gold_prices.edit but not karats.view still gets a correct active/inactive/not-found answer, instead of a false "not found" from an invoker-scoped SELECT hitting the karats.view RLS policy. Returns NULL if the karat does not exist at all. Not a general-purpose karats reader -- exposes only the single status column, nothing else.';

revoke execute on function public.karat_status_for_price_entry(uuid) from public;
grant execute on function public.karat_status_for_price_entry(uuid) to authenticated;

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
  'Upserts one (price_date, karat_id) price row via an explicit column list -- created_by/created_at set on first insert only, never touched again on a later same-day correction. Always stamps source_type=manual/is_manual_override=true (also enforced unconditionally by the daily_gold_prices_enforce_source_integrity trigger, 0051 -- belt and suspenders). As of 0054: rejects creating a BRAND NEW price row for an inactive karat (a pre-existing row for that (date, karat) pair may still be corrected via the same ON CONFLICT path -- only genuinely new rows for an inactive karat are blocked). Karat status is read via karat_status_for_price_entry() (SECURITY DEFINER), not a raw SELECT, so this check is correct regardless of whether the caller separately holds karats.view.';

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
  'Atomic "save today''s prices" entry point -- validates every entry (karat exists AND, as of 0054, is active OR a row already exists for this exact date/karat; no duplicate karat in the payload; price > 0) before writing any row; one failing entry rolls back the whole call. Always forces source_type=manual/is_manual_override=true (also enforced unconditionally by the daily_gold_prices_enforce_source_integrity trigger, 0051). Karat status read via karat_status_for_price_entry() (SECURITY DEFINER) -- see that function''s comment for why a raw SELECT would have been wrong here. SECURITY INVOKER (default) -- RLS + has_permission(''gold_prices.edit'') govern as usual.';

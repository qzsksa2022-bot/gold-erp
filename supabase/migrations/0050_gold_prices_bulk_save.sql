-- ============================================================================
-- 0050: Financial Integrity Patch 2.1 (4/4) — atomic bulk gold price save
-- ============================================================================
-- Spec item 5. The "أسعار اليوم" fast-entry form (0041, src/features/gold-
-- prices/actions.ts) previously called save_daily_gold_price() once PER
-- KARAT in a loop — if karat #3 of 5 failed (a race, a transient DB error,
-- a validation edge case), karats #1-2 were already committed while #4-5
-- never ran, leaving that day's price set in an inconsistent, partially-
-- saved state with no way to tell from the UI alone. A single plpgsql
-- function is one statement from Postgres's point of view: any exception
-- anywhere inside it rolls back every write the function had already made
-- in that same call, so "all of today's prices save, or none do" is now
-- true by construction, not by the caller's discipline.
create or replace function public.save_daily_gold_prices_bulk(
  p_price_date date,
  -- JSON array of {"karat_id": "<uuid>", "price_per_gram": <number>,
  -- "notes": "<text, optional>"}. Deliberately does NOT accept a
  -- source_type/is_manual_override field from the caller at all -- see the
  -- write pass below, which always hardcodes source_type='manual',
  -- is_manual_override=true regardless of what p_entries contains, so an
  -- ordinary authenticated user can never fabricate source_type='external_api'
  -- through this entry point (spec: "لا تسمح لمستخدم عادي بتلفيق
  -- source=external_api").
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
  v_karat_exists boolean;
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

  -- Validation pass FIRST, before any write -- every entry must be fully
  -- valid (karat id present and real, no duplicate karat within this same
  -- payload, price present and strictly positive) before a single row is
  -- touched. (Postgres would roll back a mid-loop failure in the write pass
  -- below regardless, since the whole function is one statement -- this
  -- separate pass exists to fail fast with a clear, specific message before
  -- any work happens, not because correctness depends on it.)
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

    select true into v_karat_exists from public.karats where id = v_karat_id;
    if v_karat_exists is null then
      raise exception 'عيار غير موجود (karat_id: %)', v_karat_id using errcode = 'P0001';
    end if;

    if v_entry ->> 'price_per_gram' is null then
      raise exception 'السعر مطلوب لكل عيار (karat_id: %)', v_karat_id using errcode = 'P0001';
    end if;

    v_price := (v_entry ->> 'price_per_gram')::numeric;
    if v_price <= 0 then
      raise exception 'السعر يجب أن يكون رقمًا موجبًا لكل عيار (karat_id: %)', v_karat_id using errcode = 'P0001';
    end if;
  end loop;

  -- Write pass: same explicit-column upsert shape as save_daily_gold_price()
  -- (0041) per row -- created_by/created_at only ever set on first insert,
  -- updated_by/updated_at always reflect this call, source_type/is_manual_
  -- override are always forced to 'manual'/true.
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
  'Atomic "save today''s prices" entry point -- validates every entry (karat exists, no duplicate karat in the payload, price > 0) before writing any row, and being one plpgsql function means one failing entry rolls back the whole call, never leaving a partially-saved day. Always forces source_type=manual/is_manual_override=true, ignoring anything else the caller might pass. SECURITY INVOKER (default, matching save_daily_gold_price()) -- RLS + has_permission(''gold_prices.edit'') govern as usual; no privilege escalation needed since daily_gold_prices RLS INSERT/UPDATE policies are unchanged by this patch.';

-- No REVOKE/GRANT needed: this is SECURITY INVOKER, same trust model as the
-- pre-existing save_daily_gold_price() (0041), which never revoked default
-- PUBLIC EXECUTE either -- the permission check inside the function body,
-- backed by RLS on the underlying table, is what actually gates this.

-- save_daily_gold_price() (0041, single-karat) is left exactly as it was --
-- not removed, not redirected -- it remains a valid, independently useful
-- RPC (e.g. a future single-price correction UI). Only src/features/gold-
-- prices/actions.ts's saveTodayGoldPricesAction (the bulk "أسعار اليوم" form
-- handler) is changed, in application code, to call the new bulk function
-- once instead of looping the single-karat one per entry.

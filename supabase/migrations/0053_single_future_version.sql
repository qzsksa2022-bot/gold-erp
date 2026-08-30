-- ============================================================================
-- 0053: Financial Integrity Patch 2.2 (3/4) — at most one Future Version
-- ============================================================================
-- Spec item 3. The bug, in the user's own literal scenario: Current=8 ->
-- schedule Future=10 (effective 1 Sep) -> schedule ANOTHER Future=12
-- (effective 1 Oct), which the pre-existing create_*_version() logic
-- happily accepted (it only ever compared the new effective_from against
-- the currently OPEN version's effective_from, with no concept of "is that
-- open version itself already in the future"). The result: 8 ended 31 Aug,
-- 10 ended 30 Sep (even though 10 never actually took effect for a single
-- day), 12 open from 1 Oct. Two real problems followed structurally from
-- that: (a) the Current/Upcoming UI (Patch 2.1 item 8) only ever treats the
-- single OPEN row as "Upcoming", so 12 would display as Upcoming while the
-- real next value (10) silently fell into History looking like a normal
-- past, already-ended version -- even though it never started; (b)
-- cancel_*_version() only operates on status='active' rows (by design --
-- see 0047), but 10 is now status='ended', so it could no longer be
-- cancelled at all despite never having taken effect.
--
-- Fix: create_manufacturing_fee_version()/create_payment_method_fee_version()
-- (0042/0045, re-declared SECURITY DEFINER in 0047, re-declared again here
-- with the SAME security properties -- CREATE OR REPLACE preserves prior
-- REVOKE/GRANT for an unchanged signature, but every prior redeclaration in
-- this project restates them explicitly, and this one keeps that
-- convention) now reject creating ANY new version outright the moment the
-- currently open version is itself still in the future (effective_from >
-- current_date) -- regardless of what effective_from the new attempt uses.
-- The only sanctioned way forward at that point is exactly what 0047 already
-- built for this: cancel_*_version() the existing future version first
-- (which atomically reopens its predecessor), and only then schedule a new
-- one. This makes "at most one Future Version per karat/payment method" a
-- real DB invariant, which in turn makes the Patch 2.1 Current/Upcoming UI
-- resolution logic (unchanged by this migration -- see
-- src/features/manufacturing-fees/queries.ts /
-- src/features/payment-methods/queries.ts) correct again: there is
-- structurally never more than one non-current, non-cancelled version to
-- call "Upcoming", and it is always the single open row.
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
    if v_open.effective_from > current_date then
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
  'Atomically ends the karat''s currently open manufacturing fee version (if the new effective_from is after it) and inserts the new one. As of 0053: rejects outright if the currently open version is itself still in the future (effective_from > current_date) -- at most one Future Version per karat, cancel it first via cancel_manufacturing_fee_version(). SECURITY DEFINER (0047) -- has_permission() is the sole authorization gate for this operation, in addition to RLS still governing SELECT.';

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
    if v_open.effective_from > current_date then
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
  'Atomically ends the payment method''s currently open fee version (if the new effective_from is after it) and inserts the new one. As of 0053: rejects outright if the currently open version is itself still in the future (effective_from > current_date) -- at most one Future Version per payment method, cancel it first via cancel_payment_method_fee_version(). SECURITY DEFINER (0047). The shape/active-method invariants (0047 PART C) still fire as a BEFORE INSERT trigger on the underlying table.';

revoke execute on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) from public;
grant execute on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) to authenticated;

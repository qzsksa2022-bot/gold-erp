-- ============================================================================
-- 0171: Phase 7 — Settlements Core (5/N): settlement_route_fee_versions
-- create/cancel RPCs + resolver
-- ============================================================================
-- Migrations 0001-0170 are unmodified. Mirrors create_payment_method_fee_
-- version()/cancel_payment_method_fee_version() (final forms: 0066/0056)
-- almost verbatim — same "close old open version, insert new" / "cancel a
-- strictly-future not-yet-effective version, reopen predecessor" logic,
-- same acquire_..._lock_exclusive() position (immediately after the
-- permission check, before any read/validate/write), same asymmetry
-- (cancel does NOT take the lock — it can only touch a strictly-future
-- version nothing could legally be reading yet, same reasoning as 0066).
-- ---------------------------------------------------------------------------
create or replace function public.create_settlement_route_fee_version(
  p_settlement_route_id uuid,
  p_effective_from date,
  p_transaction_fee_strategy text,
  p_transaction_fee_model text default null,
  p_percentage_fee numeric default null,
  p_fixed_fee numeric default null,
  p_batch_fee_fixed numeric default 0,
  p_cod_fee_reversal_policy text default null,
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
  if not public.has_permission('settlements.manage_routes') then
    raise exception 'ليست لديك صلاحية إدارة مسارات التسوية' using errcode = 'P0001';
  end if;

  perform public.acquire_settlement_master_lock_exclusive();

  if p_settlement_route_id is null or p_effective_from is null then
    raise exception 'مسار التسوية وتاريخ السريان مطلوبان' using errcode = 'P0001';
  end if;

  p_batch_fee_fixed := coalesce(p_batch_fee_fixed, 0);
  if p_batch_fee_fixed < 0 then
    raise exception 'رسوم الدفعة لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;
  perform public.validate_money_scale(p_batch_fee_fixed, 'رسوم الدفعة');
  if p_percentage_fee is not null and p_percentage_fee < 0 then
    raise exception 'نسبة الرسوم لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;
  if p_fixed_fee is not null then
    if p_fixed_fee < 0 then
      raise exception 'قيمة الرسوم الثابتة لا يمكن أن تكون سالبة' using errcode = 'P0001';
    end if;
    perform public.validate_money_scale(p_fixed_fee, 'الرسوم الثابتة');
  end if;

  select * into v_open
  from public.settlement_route_fee_versions
  where settlement_route_id = p_settlement_route_id and effective_to is null and status = 'active'
  for update;

  if found then
    if v_open.effective_from > v_today then
      raise exception 'يوجد بالفعل إصدار رسوم مستقبلي مجدوَل لهذا المسار (يسري اعتبارًا من %) ولم يسرِ بعد — ألغِه أولًا عبر cancel_settlement_route_fee_version()', v_open.effective_from
        using errcode = 'P0001';
    end if;
    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار رسوم سارٍ/مجدوَل لهذا المسار بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.settlement_route_fee_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.settlement_route_fee_versions (
    settlement_route_id, effective_from, effective_to, transaction_fee_strategy, transaction_fee_model,
    percentage_fee, fixed_fee, batch_fee_fixed, cod_fee_reversal_policy, status, notes, created_by
  )
  values (
    p_settlement_route_id, p_effective_from, null, p_transaction_fee_strategy, p_transaction_fee_model,
    p_percentage_fee, p_fixed_fee, p_batch_fee_fixed, p_cod_fee_reversal_policy, 'active', p_notes, auth.uid()
  )
  returning id into v_id;

  perform public.log_audit_event(
    'settlement_route_fee_version.create', 'settlement_route_fee_version', v_id, null,
    jsonb_build_object(
      'settlement_route_id', p_settlement_route_id, 'effective_from', p_effective_from,
      'transaction_fee_strategy', p_transaction_fee_strategy, 'transaction_fee_model', p_transaction_fee_model,
      'percentage_fee', p_percentage_fee, 'fixed_fee', p_fixed_fee, 'batch_fee_fixed', p_batch_fee_fixed,
      'cod_fee_reversal_policy', p_cod_fee_reversal_policy
    )
  );

  return v_id;
end;
$$;

comment on function public.create_settlement_route_fee_version(uuid, date, text, text, numeric, numeric, numeric, text, text) is
  'Phase 7 (items 11/12) — creates a new fee-version for a Settlement Route, closing out any still-open version. Requires settlements.manage_routes. SECURITY DEFINER.';

revoke execute on function public.create_settlement_route_fee_version(uuid, date, text, text, numeric, numeric, numeric, text, text) from public;
grant execute on function public.create_settlement_route_fee_version(uuid, date, text, text, numeric, numeric, numeric, text, text) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.cancel_settlement_route_fee_version(p_version_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_predecessor record;
begin
  if not public.has_permission('settlements.manage_routes') then
    raise exception 'ليست لديك صلاحية إدارة مسارات التسوية' using errcode = 'P0001';
  end if;

  select * into v_row from public.settlement_route_fee_versions where id = p_version_id for update;

  if not found then
    raise exception 'إصدار رسوم التسوية غير موجود' using errcode = 'P0001';
  end if;

  if v_row.status <> 'active' then
    raise exception 'هذا الإصدار ليس نشِطًا أصلًا (تم إلغاؤه أو استبداله سابقًا)' using errcode = 'P0001';
  end if;

  if v_row.effective_from <= public.business_today() then
    raise exception 'لا يمكن إلغاء إصدار رسوم سارٍ بالفعل أو مضى تاريخ سريانه — يُسمح فقط بإلغاء إصدار مستقبلي لم يسرِ بعد' using errcode = 'P0001';
  end if;

  update public.settlement_route_fee_versions set status = 'cancelled' where id = p_version_id;

  select * into v_predecessor
  from public.settlement_route_fee_versions
  where settlement_route_id = v_row.settlement_route_id and status = 'ended' and effective_to = v_row.effective_from - 1
  for update;

  if found then
    update public.settlement_route_fee_versions
    set effective_to = null, status = 'active'
    where id = v_predecessor.id;
  end if;

  perform public.log_audit_event(
    'settlement_route_fee_version.cancel', 'settlement_route_fee_version', p_version_id,
    jsonb_build_object('status', 'active'), jsonb_build_object('status', 'cancelled')
  );
end;
$$;

comment on function public.cancel_settlement_route_fee_version(uuid) is
  'Phase 7 — cancels a STRICTLY-FUTURE, not-yet-effective fee version, reopening its predecessor if one exists. Deliberately does NOT take the Settlement Master Lock (mirrors cancel_payment_method_fee_version, 0056 — a future version nothing could legally be reading yet). Requires settlements.manage_routes. SECURITY DEFINER.';

revoke execute on function public.cancel_settlement_route_fee_version(uuid) from public;
grant execute on function public.cancel_settlement_route_fee_version(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Resolver — the historical fee version covering a given route on a given
-- date. Raises if none covers it (mirrors payment_fee_for_method_on_date,
-- 0056 — a route with NO fee version at all is a configuration error that
-- must fail loudly at Finalization, never silently default to zero fees).
-- ---------------------------------------------------------------------------
create or replace function public.settlement_route_fee_for_route_on_date(p_settlement_route_id uuid, p_date date default public.business_today())
returns table (
  fee_version_id uuid, transaction_fee_strategy text, transaction_fee_model text,
  percentage_fee numeric, fixed_fee numeric, batch_fee_fixed numeric, cod_fee_reversal_policy text
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select v.id, v.transaction_fee_strategy, v.transaction_fee_model, v.percentage_fee, v.fixed_fee, v.batch_fee_fixed, v.cod_fee_reversal_policy
  from public.settlement_route_fee_versions v
  where v.settlement_route_id = p_settlement_route_id
    and v.status <> 'cancelled'
    and v.effective_from <= p_date
    and (v.effective_to is null or v.effective_to >= p_date)
  order by v.effective_from desc
  limit 1;
$$;

comment on function public.settlement_route_fee_for_route_on_date(uuid, date) is
  'Phase 7 — resolves the historical fee-version configuration covering a route on a given date. Empty result (no row) means no fee version covers that date — the caller (finalize_settlement_batch) must reject rather than silently default.';

revoke execute on function public.settlement_route_fee_for_route_on_date(uuid, date) from public;
grant execute on function public.settlement_route_fee_for_route_on_date(uuid, date) to authenticated;

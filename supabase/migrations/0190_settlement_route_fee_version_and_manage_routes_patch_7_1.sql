-- ============================================================================
-- 0190: Phase 7 — Integrity Patch 7.1 (7/N): fixed_fee scale contract
-- (§18), COD source_snapshot rejected at fee-version CREATION (§19),
-- settlements.manage_routes-only narrow lookups (§23).
-- ============================================================================
-- Migrations 0001-0189 are FROZEN.
--
-- §18 — settlement_route_fee_versions.fixed_fee is numeric(12,4) (0170)
-- but create_settlement_route_fee_version() (0171) validated p_fixed_fee
-- with validate_money_scale() — hardcoded to reject anything past 2
-- decimal places (0092), silently making 4dp unreachable through the RPC
-- even though the column itself supports it. Fix: a new generalized scale
-- validator, validate_money_scale_n(value, label, max_scale), used here
-- with max_scale=4 for p_fixed_fee. batch_fee_fixed (numeric(12,2)) keeps
-- the original 2dp validate_money_scale() unchanged.
--
-- §19 — 0170's creation-time trigger (enforce_settlement_route_fee_version_
-- invariants) never looked at route_kind when transaction_fee_strategy=
-- 'source_snapshot', so a cod_carrier route could be given source_snapshot
-- at CREATION with no error anywhere — 0178's finalize_settlement_batch()
-- rejected it only much later, at Finalization. Moved here to the earliest
-- possible point: create_settlement_route_fee_version() itself now reads
-- the route's own route_kind and rejects source_snapshot for cod_carrier
-- immediately (finalize's own defensive check, 0185, is left in place —
-- belt and suspenders, never a substitute for this earlier rejection).
--
-- §23 — settlements.manage_routes alone must fully manage Settlement
-- Routes without any unrelated Domain permission. Adds four narrow lookup
-- RPCs gated ONLY on settlements.manage_routes, returning the minimum
-- master data needed: active payment methods / collection channels /
-- shipping carriers (for the route-creation picker, replacing queries.ts's
-- direct reads of payment_methods/collection_channels/shipping_carriers,
-- which depend on THOSE tables' own unrelated .view permissions), and the
-- fee-version history for a route (replacing the direct read of
-- settlement_route_fee_versions, which depends on settlements.view_
-- financials, item 40's DIFFERENT permission — the exact hidden
-- dependency §23 names).
-- ============================================================================
create or replace function public.validate_money_scale_n(p_value numeric, p_label text, p_max_scale integer)
returns void
language plpgsql
immutable
as $$
begin
  if p_value is not null and scale(p_value) > p_max_scale then
    raise exception '% يجب ألا يحتوي على أكثر من % منازل عشرية (القيمة المُدخلة: %)', p_label, p_max_scale, p_value using errcode = 'P0001';
  end if;
end;
$$;

comment on function public.validate_money_scale_n(numeric, text, integer) is
  'Patch 7.1 §18 — generalized sibling of validate_money_scale() (0092, hardcoded to 2dp) with a caller-supplied max_scale. Used by create_settlement_route_fee_version() for p_fixed_fee (numeric(12,4) column, max_scale=4) — 0171''s original call used the hardcoded-2dp validator, contradicting the column''s own declared 4dp precision.';

revoke execute on function public.validate_money_scale_n(numeric, text, integer) from public;
grant execute on function public.validate_money_scale_n(numeric, text, integer) to authenticated;

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
  v_route record;
  v_today date := public.business_today();
begin
  if not public.has_permission('settlements.manage_routes') then
    raise exception 'ليست لديك صلاحية إدارة مسارات التسوية' using errcode = 'P0001';
  end if;

  perform public.acquire_settlement_master_lock_exclusive();

  if p_settlement_route_id is null or p_effective_from is null then
    raise exception 'مسار التسوية وتاريخ السريان مطلوبان' using errcode = 'P0001';
  end if;

  select * into v_route from public.settlement_routes r where r.id = p_settlement_route_id;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;

  -- §19 — reject source_snapshot for a COD-carrier route at the earliest
  -- possible point (creation), never merely at Finalization.
  if v_route.route_kind = 'cod_carrier' and p_transaction_fee_strategy = 'source_snapshot' then
    raise exception 'استراتيجية source_snapshot غير صالحة لمسار COD ناقل — لا يوجد لقطة رسوم على مستوى المصدر لأحداث COD، استخدم route_formula أو none' using errcode = 'P0001';
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
    -- §18 — 4dp, matching the column's own declared precision (numeric(12,4), 0170) — NOT the 2dp validate_money_scale().
    perform public.validate_money_scale_n(p_fixed_fee, 'الرسوم الثابتة', 4);
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
  'Phase 7.1 patch (§18/§19) — same signature as 0171. Rejects transaction_fee_strategy=''source_snapshot'' for a cod_carrier route immediately at creation (§19 — 0178/0185''s Finalize-time rejection remains as defense in depth). p_fixed_fee validated to 4dp via validate_money_scale_n() (§18), matching the column''s own numeric(12,4) precision. Requires settlements.manage_routes. SECURITY DEFINER.';

revoke execute on function public.create_settlement_route_fee_version(uuid, date, text, text, numeric, numeric, numeric, text, text) from public;
grant execute on function public.create_settlement_route_fee_version(uuid, date, text, text, numeric, numeric, numeric, text, text) to authenticated;

-- ============================================================================
-- §23 — settlements.manage_routes-only narrow lookups.
-- ============================================================================
create or replace function public.settlement_route_payment_method_lookups()
returns table (id uuid, key text, name_ar text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select pm.id, pm.key, pm.name_ar
  from public.payment_methods pm
  where public.has_permission('settlements.manage_routes')
    and pm.status = 'active'
  order by pm.name_ar;
$$;

comment on function public.settlement_route_payment_method_lookups() is
  'Patch 7.1 §23 — active payment-method picker for the Settlement Route creation/edit form, gated ONLY on settlements.manage_routes (never payment_methods.view — the hidden dependency queries.ts previously had by reading public.payment_methods directly).';

revoke execute on function public.settlement_route_payment_method_lookups() from public;
grant execute on function public.settlement_route_payment_method_lookups() to authenticated;

create or replace function public.settlement_route_collection_channel_lookups()
returns table (id uuid, key text, name_ar text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select cc.id, cc.key, cc.name_ar
  from public.collection_channels cc
  where public.has_permission('settlements.manage_routes')
    and cc.status = 'active'
  order by cc.sort_order, cc.name_ar;
$$;

comment on function public.settlement_route_collection_channel_lookups() is
  'Patch 7.1 §23 — active collection-channel picker for the Settlement Route form, gated ONLY on settlements.manage_routes (never collection_channels.view).';

revoke execute on function public.settlement_route_collection_channel_lookups() from public;
grant execute on function public.settlement_route_collection_channel_lookups() to authenticated;

create or replace function public.settlement_route_carrier_lookups()
returns table (id uuid, code text, name_ar text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select sc.id, sc.code, sc.name_ar
  from public.shipping_carriers sc
  where public.has_permission('settlements.manage_routes')
    and sc.status = 'active'
  order by sc.name_ar;
$$;

comment on function public.settlement_route_carrier_lookups() is
  'Patch 7.1 §23 — active shipping-carrier picker for the Settlement Route form, gated ONLY on settlements.manage_routes (never shipping_rates.view/shipping_carriers.view).';

revoke execute on function public.settlement_route_carrier_lookups() from public;
grant execute on function public.settlement_route_carrier_lookups() to authenticated;

create or replace function public.list_settlement_route_fee_versions_for_management(p_settlement_route_id uuid)
returns table (
  id uuid,
  effective_from date,
  effective_to date,
  transaction_fee_strategy text,
  transaction_fee_model text,
  percentage_fee text,
  fixed_fee text,
  batch_fee_fixed text,
  cod_fee_reversal_policy text,
  status text,
  notes text,
  created_by_name text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if not public.has_permission('settlements.manage_routes') then
    raise exception 'ليست لديك صلاحية إدارة مسارات التسوية' using errcode = 'P0001';
  end if;

  return query
  select
    v.id, v.effective_from, v.effective_to, v.transaction_fee_strategy, v.transaction_fee_model,
    v.percentage_fee::text, v.fixed_fee::text, v.batch_fee_fixed::text, v.cod_fee_reversal_policy, v.status, v.notes,
    (select p.full_name from public.profiles p where p.id = v.created_by), v.created_at
  from public.settlement_route_fee_versions v
  where v.settlement_route_id = p_settlement_route_id
  order by v.effective_from desc;
end;
$$;

comment on function public.list_settlement_route_fee_versions_for_management(uuid) is
  'Patch 7.1 §23 — fee-version history for the route-management screen, gated ONLY on settlements.manage_routes (never settlements.view_financials — the hidden dependency queries.ts previously had by reading public.settlement_route_fee_versions directly, which carries that table''s own settlements.view_financials-gated RLS policy, 0170). This is CONFIGURATION history (what a manager sets), a distinct concern from settlements.view_financials (a TRANSACTION result-visibility permission, item 40) — a manage_routes actor needs to see what they themselves configured to manage it. SECURITY DEFINER.';

revoke execute on function public.list_settlement_route_fee_versions_for_management(uuid) from public;
grant execute on function public.list_settlement_route_fee_versions_for_management(uuid) to authenticated;

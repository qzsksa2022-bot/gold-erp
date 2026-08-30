-- ============================================================================
-- 0191: Phase 7 — Integrity Patch 7.1 (8/N): list_settlement_batches()
-- complete filters + source_count (§25), get_settlement_batch()/
-- list_settlement_batches() original-vs-effective cancelled semantics
-- (§26).
-- ============================================================================
-- Migrations 0001-0190 are FROZEN. This migration DROPS and recreates both
-- functions (their signatures AND output column sets both change — a
-- straightforward CREATE OR REPLACE cannot do either) — safe because both
-- are read-only RPCs with no dependent table/trigger; every caller (UI,
-- tests) is updated alongside this migration.
--
-- §25 — new filters: p_route_kind, p_payment_method_id, p_collection_
-- channel_id, p_shipping_carrier_id, p_effective_status[] (draft/finalized/
-- reconciled/cancelled — 'cancelled' now genuinely filterable, not just a
-- badge derived client-side), p_store_id (matches a batch with at least
-- one line whose primary OR secondary store is p_store_id), p_has_variance
-- (requires settlements.view_financials — gated per §25's own instruction,
-- since "has a nonzero variance" is itself financial information). p_search
-- now also matches provider_statement_reference (previously settlement_
-- number only). source_count is now returned (line count, operational —
-- not gated behind view_financials, mirrors item 40's operational tier).
--
-- §26 — every money figure once split cleanly into ORIGINAL (the immutable
-- historical fact, frozen by settlement_batches_reject_financial_mutation
-- since 0172 — NEVER zeroed by a cancellation, which per 0175/0181 never
-- touches settlement_batches/settlement_batch_lines at all) vs EFFECTIVE
-- (the batch''s CURRENT contribution to the business: identical to the
-- original figures unless cancelled, in which case 0.00 — a cancelled
-- batch contributes nothing to any forward-looking total, but its history
-- remains fully readable). The old flat gross_source_impact/provider_fee_
-- impact/batch_fee_snapshot/expected_bank_settlement/actual_bank_movement/
-- variance columns (0182/0186, ambiguous about which meaning they carried
-- for a cancelled batch) are replaced by explicitly-named original_*/
-- effective_*/historical_* columns below.
-- ============================================================================
drop function if exists public.list_settlement_batches(text[], uuid, date, date, text, integer, integer);
drop function if exists public.get_settlement_batch(uuid);

create function public.list_settlement_batches(
  p_status text[] default null,
  p_settlement_route_id uuid default null,
  p_date_from date default null,
  p_date_to date default null,
  p_search text default null,
  p_route_kind text default null,
  p_payment_method_id uuid default null,
  p_collection_channel_id uuid default null,
  p_shipping_carrier_id uuid default null,
  p_effective_status text[] default null,
  p_store_id uuid default null,
  p_has_variance boolean default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid,
  settlement_number text,
  settlement_route_id uuid,
  route_code text,
  route_name_ar text,
  route_kind text,
  settlement_date date,
  status text,
  effective_status text,
  provider_statement_reference text,
  source_count integer,
  original_gross_source_impact text,
  original_provider_fee_impact text,
  original_batch_fee text,
  original_expected_bank_settlement text,
  effective_expected_settlement_contribution text,
  effective_actual_settlement_contribution text,
  effective_variance_contribution text,
  row_version bigint,
  created_at timestamptz,
  finalized_at timestamptz,
  reconciled_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_view_financials boolean;
begin
  if v_actor is null or not public.has_permission('settlements.view') then
    raise exception 'ليست لديك صلاحية عرض التسويات' using errcode = 'P0001';
  end if;
  v_can_view_financials := public.has_permission('settlements.view_financials');

  -- §25 — has_variance leaks financial information (whether a real
  -- mismatch exists), so it is refused outright without view_financials
  -- rather than silently ignored (silently ignoring a filter the caller
  -- explicitly asked for could itself mislead the UI into showing an
  -- unfiltered list as if it were filtered).
  if p_has_variance is not null and not v_can_view_financials then
    raise exception 'يتطلب ترشيح الفروقات المالية صلاحية settlements.view_financials' using errcode = 'P0001';
  end if;

  return query
  with base as (
    select
      b.*, r.code as r_code, r.name_ar as r_name_ar, r.route_kind as r_route_kind,
      r.payment_method_id as r_payment_method_id, r.collection_channel_id as r_collection_channel_id,
      r.shipping_carrier_id as r_shipping_carrier_id,
      (cx.settlement_batch_id is not null) as is_cancelled,
      coalesce((select count(*) from public.settlement_batch_lines l where l.settlement_batch_id = b.id), 0)::integer as src_count,
      bm.actual as actual_amt
    from public.settlement_batches b
    join public.settlement_routes r on r.id = b.settlement_route_id
    left join public.settlement_batch_cancellations cx on cx.settlement_batch_id = b.id
    left join lateral (
      select
        coalesce((select sum(e.amount) from public.settlement_bank_movement_events e where e.settlement_batch_id = b.id), 0)
        + coalesce((
            select sum(rv.amount_impact)
            from public.settlement_bank_movement_reversals rv
            join public.settlement_bank_movement_events e2 on e2.id = rv.bank_movement_event_id
            where e2.settlement_batch_id = b.id
          ), 0) as actual
    ) bm on true
  ),
  scoped as (
    select
      base.*,
      case when base.is_cancelled then 'cancelled' else base.status end as eff_status,
      case when base.is_cancelled then 0::numeric else base.expected_bank_settlement end as eff_expected,
      case when base.is_cancelled or base.expected_bank_settlement is null then 0::numeric else coalesce(base.actual_amt, 0) end as eff_actual,
      case
        when base.is_cancelled or base.expected_bank_settlement is null then 0::numeric
        else coalesce(base.actual_amt, 0) - base.expected_bank_settlement
      end as eff_variance
    from base
  )
  select
    scoped.id, scoped.settlement_number, scoped.settlement_route_id,
    coalesce(scoped.route_code_snapshot, scoped.r_code), coalesce(scoped.route_name_ar_snapshot, scoped.r_name_ar), coalesce(scoped.route_kind_snapshot, scoped.r_route_kind),
    scoped.settlement_date, scoped.status, scoped.eff_status,
    scoped.provider_statement_reference,
    scoped.src_count,
    case when v_can_view_financials then scoped.gross_source_impact::text end,
    case when v_can_view_financials then scoped.provider_fee_impact::text end,
    case when v_can_view_financials then scoped.batch_fee_snapshot::text end,
    case when v_can_view_financials then scoped.expected_bank_settlement::text end,
    case when v_can_view_financials then scoped.eff_expected::text end,
    case when v_can_view_financials then scoped.eff_actual::text end,
    case when v_can_view_financials then scoped.eff_variance::text end,
    scoped.row_version, scoped.created_at, scoped.finalized_at, scoped.reconciled_at
  from scoped
  where (p_status is null or scoped.status = any (p_status))
    and (p_effective_status is null or scoped.eff_status = any (p_effective_status))
    and (p_settlement_route_id is null or scoped.settlement_route_id = p_settlement_route_id)
    and (p_route_kind is null or coalesce(scoped.route_kind_snapshot, scoped.r_route_kind) = p_route_kind)
    and (p_payment_method_id is null or coalesce(scoped.payment_method_id_snapshot, scoped.r_payment_method_id) = p_payment_method_id)
    and (p_collection_channel_id is null or coalesce(scoped.collection_channel_id_snapshot, scoped.r_collection_channel_id) = p_collection_channel_id)
    and (p_shipping_carrier_id is null or coalesce(scoped.shipping_carrier_id_snapshot, scoped.r_shipping_carrier_id) = p_shipping_carrier_id)
    and (p_date_from is null or scoped.settlement_date >= p_date_from)
    and (p_date_to is null or scoped.settlement_date <= p_date_to)
    and (
      p_search is null or btrim(p_search) = ''
      or scoped.settlement_number ilike '%' || btrim(p_search) || '%'
      or scoped.provider_statement_reference ilike '%' || btrim(p_search) || '%'
    )
    and (
      p_store_id is null
      or exists (
        select 1 from public.settlement_batch_lines l
        where l.settlement_batch_id = scoped.id
          and (l.primary_store_id = p_store_id or l.secondary_store_id = p_store_id)
      )
    )
    and (p_has_variance is null or (p_has_variance = (scoped.eff_variance <> 0)))
    and public._settlement_batch_all_stores_visible(scoped.id, v_actor)
  order by scoped.settlement_date desc, scoped.settlement_number desc
  limit greatest(coalesce(p_limit, 50), 1)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

comment on function public.list_settlement_batches(text[], uuid, date, date, text, text, uuid, uuid, uuid, text[], uuid, boolean, integer, integer) is
  'Phase 7.1 patch (§25/§26) — complete filter set (route kind/payment method/channel/carrier/effective status incl. cancelled/store/has_variance, the last gated on settlements.view_financials) + server-side source_count. original_*/effective_* columns replace the old ambiguous flat figures (§26) — original_* is the permanent historical fact (never zeroed by cancellation); effective_* is the batch''s CURRENT contribution (0.00 once cancelled). Still applies _settlement_batch_all_stores_visible() (§6, 0186). Requires settlements.view. SECURITY DEFINER.';

revoke execute on function public.list_settlement_batches(text[], uuid, date, date, text, text, uuid, uuid, uuid, text[], uuid, boolean, integer, integer) from public;
grant execute on function public.list_settlement_batches(text[], uuid, date, date, text, text, uuid, uuid, uuid, text[], uuid, boolean, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
create function public.get_settlement_batch(p_settlement_batch_id uuid)
returns table (
  id uuid,
  settlement_number text,
  settlement_route_id uuid,
  route_code text,
  route_name_ar text,
  route_name_en text,
  route_kind text,
  settlement_date date,
  status text,
  effective_status text,
  provider_statement_reference text,
  notes text,
  payment_method_name text,
  collection_channel_name text,
  shipping_carrier_name text,
  transaction_fee_strategy text,
  transaction_percentage_fee text,
  transaction_fixed_fee text,
  original_batch_fee text,
  is_batch_fee_override boolean,
  configured_batch_fee text,
  override_reason text,
  original_gross_source_impact text,
  original_provider_fee_impact text,
  original_expected_before_batch_fee text,
  original_expected_bank_settlement text,
  historical_actual_bank_movement text,
  original_variance text,
  effective_expected_settlement_contribution text,
  effective_actual_settlement_contribution text,
  effective_variance_contribution text,
  settlement_calculation_version integer,
  row_version bigint,
  finalized_at timestamptz,
  finalized_by_name text,
  reconciled_at timestamptz,
  reconciled_by_name text,
  variance_reason text,
  cancelled_at timestamptz,
  cancelled_by_name text,
  cancellation_reason text,
  lines jsonb,
  bank_movements jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_can_view_financials boolean;
  v_batch record;
  v_cancel record;
  v_actual numeric;
  v_lines jsonb;
  v_movements jsonb;
  v_is_cancelled boolean;
  v_eff_expected numeric;
  v_eff_actual numeric;
  v_eff_variance numeric;
  v_orig_variance numeric;
begin
  if v_actor is null or not public.has_permission('settlements.view') then
    raise exception 'ليست لديك صلاحية عرض التسويات' using errcode = 'P0001';
  end if;
  v_can_view_financials := public.has_permission('settlements.view_financials');

  select b.*, r.code as r_code, r.name_ar as r_name_ar, r.route_kind as r_route_kind
  into v_batch
  from public.settlement_batches b
  join public.settlement_routes r on r.id = b.settlement_route_id
  where b.id = p_settlement_batch_id;

  if v_batch.id is null then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;

  if not public._settlement_batch_all_stores_visible(p_settlement_batch_id, v_actor) then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;

  select * into v_cancel from public.settlement_batch_cancellations c where c.settlement_batch_id = p_settlement_batch_id;
  v_is_cancelled := v_cancel.id is not null;

  if v_can_view_financials then
    select
      coalesce((select sum(e.amount) from public.settlement_bank_movement_events e where e.settlement_batch_id = p_settlement_batch_id), 0)
      + coalesce((
          select sum(rv.amount_impact)
          from public.settlement_bank_movement_reversals rv
          join public.settlement_bank_movement_events e2 on e2.id = rv.bank_movement_event_id
          where e2.settlement_batch_id = p_settlement_batch_id
        ), 0)
    into v_actual;

    v_orig_variance := case when v_batch.expected_bank_settlement is null then null else coalesce(v_actual, 0) - v_batch.expected_bank_settlement end;

    -- §26 — effective_* collapses to 0.00 once cancelled; original_*/
    -- historical_* (above) are NEVER touched by cancellation.
    if v_is_cancelled then
      v_eff_expected := 0;
      v_eff_actual := 0;
      v_eff_variance := 0;
    else
      v_eff_expected := v_batch.expected_bank_settlement;
      v_eff_actual := coalesce(v_actual, 0);
      v_eff_variance := v_orig_variance;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
        'id', l.id, 'source_kind', l.source_kind, 'source_number', l.source_number_snapshot,
        'source_business_date', l.source_business_date,
        'primary_store_name', l.primary_store_name_snapshot, 'secondary_store_name', l.secondary_store_name_snapshot,
        'gross_collection_impact', l.gross_collection_impact::text, 'provider_fee_impact', l.provider_fee_impact::text,
        'expected_settlement_impact', l.expected_settlement_impact::text, 'provider_fee_source', l.provider_fee_source
      ) order by l.source_business_date, l.source_number_snapshot), '[]'::jsonb)
    into v_lines
    from public.settlement_batch_lines l
    where l.settlement_batch_id = p_settlement_batch_id;

    select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'movement_business_date', e.movement_business_date, 'amount', e.amount::text,
        'bank_reference', e.bank_reference, 'notes', e.notes,
        'reversed', exists (select 1 from public.settlement_bank_movement_reversals r where r.bank_movement_event_id = e.id),
        'reversal_amount_impact', (select r.amount_impact::text from public.settlement_bank_movement_reversals r where r.bank_movement_event_id = e.id)
      ) order by e.movement_business_date, e.created_at), '[]'::jsonb)
    into v_movements
    from public.settlement_bank_movement_events e
    where e.settlement_batch_id = p_settlement_batch_id;
  else
    v_actual := null; v_orig_variance := null; v_eff_expected := null; v_eff_actual := null; v_eff_variance := null;
    v_lines := '[]'::jsonb;
    v_movements := '[]'::jsonb;
  end if;

  return query select
    v_batch.id, v_batch.settlement_number, v_batch.settlement_route_id,
    coalesce(v_batch.route_code_snapshot, v_batch.r_code), coalesce(v_batch.route_name_ar_snapshot, v_batch.r_name_ar), v_batch.route_name_en_snapshot,
    coalesce(v_batch.route_kind_snapshot, v_batch.r_route_kind),
    v_batch.settlement_date, v_batch.status,
    case when v_is_cancelled then 'cancelled' else v_batch.status end,
    v_batch.provider_statement_reference, v_batch.notes,
    v_batch.payment_method_name_snapshot, v_batch.collection_channel_name_snapshot, v_batch.shipping_carrier_name_snapshot,
    case when v_can_view_financials then v_batch.transaction_fee_strategy_snapshot end,
    case when v_can_view_financials then v_batch.transaction_percentage_fee_snapshot::text end,
    case when v_can_view_financials then v_batch.transaction_fixed_fee_snapshot::text end,
    case when v_can_view_financials then v_batch.batch_fee_snapshot::text end,
    v_batch.is_batch_fee_override,
    case when v_can_view_financials then v_batch.configured_batch_fee_snapshot::text end,
    v_batch.override_reason,
    case when v_can_view_financials then v_batch.gross_source_impact::text end,
    case when v_can_view_financials then v_batch.provider_fee_impact::text end,
    case when v_can_view_financials then v_batch.expected_before_batch_fee::text end,
    case when v_can_view_financials then v_batch.expected_bank_settlement::text end,
    case when v_can_view_financials then v_actual::text end,
    case when v_can_view_financials then v_orig_variance::text end,
    case when v_can_view_financials then v_eff_expected::text end,
    case when v_can_view_financials then v_eff_actual::text end,
    case when v_can_view_financials then v_eff_variance::text end,
    v_batch.settlement_calculation_version, v_batch.row_version,
    v_batch.finalized_at, (select p.full_name from public.profiles p where p.id = v_batch.finalized_by),
    v_batch.reconciled_at, (select p.full_name from public.profiles p where p.id = v_batch.reconciled_by),
    v_batch.variance_reason,
    v_cancel.created_at, (select p.full_name from public.profiles p where p.id = v_cancel.created_by), v_cancel.reason,
    v_lines, v_movements,
    v_batch.created_at, v_batch.updated_at;
end;
$$;

comment on function public.get_settlement_batch(uuid) is
  'Phase 7.1 patch (§6/§26) — whole-batch all-or-nothing store privacy (§6, unchanged from 0186). original_*/historical_* columns are the permanent historical facts (never zeroed by cancellation); effective_* columns collapse to 0.00 once cancelled, matching list_settlement_batches()''s own contract (§26). Still requires settlements.view (+ settlements.view_financials for every money/line/movement field). SECURITY DEFINER.';

revoke execute on function public.get_settlement_batch(uuid) from public;
grant execute on function public.get_settlement_batch(uuid) to authenticated;

-- ============================================================================
-- 0182: Phase 7 — Settlements Core (16/N): list_settlement_batches() +
-- get_settlement_batch() + settlement_store_filter_lookups()
-- ============================================================================
-- Migrations 0001-0181 are unmodified.
--
-- settlement_batches/settlement_batch_lines/settlement_bank_movement_events/
-- _reversals/settlement_source_claims/settlement_batch_cancellations ALL have
-- zero SELECT RLS policies (item 41) — these three functions are the ENTIRE
-- read surface for the module, all SECURITY DEFINER.
--
-- item 40 — `settlements.view` alone is OPERATIONAL-only visibility: batch
-- existence, route/date/status, effective_status (see below). Every money
-- figure (gross/fee/batch-fee/expected/actual/variance, line-level amounts,
-- bank-movement amounts) requires the stricter `settlements.view_financials`
-- and is returned as SQL NULL otherwise — never a zero or empty string,
-- which would be indistinguishable from a genuine zero-value figure.
--
-- item 17 — effective_status is ALWAYS derived here (EXISTS a cancellation
-- row => 'cancelled', else the real status column) — the client is never
-- allowed to infer it itself from status + a separate cancelled flag.
--
-- item 21 — cross-store privacy at the LINE level (get_settlement_batch()
-- only): a line is included only if the actor can see its primary_store_id
-- OR (when set) its secondary_store_id, mirroring the exact "Original Sale
-- Store + Processing Store, either visible" rule the Source Adapter (0176)
-- already applies at discovery time. The batch HEADER itself is never
-- store-scoped (a route is not store-specific), consistent with item 20 —
-- only line-level detail can leak a specific store's business.
--
-- actual_bank_movement/variance are computed LIVE here (never stored, same
-- live-computation the RPCs in 0180 use), so a batch/line list always
-- reflects the current bank-movement ledger even seconds after a new
-- movement/reversal was recorded.
-- ---------------------------------------------------------------------------
create or replace function public.list_settlement_batches(
  p_status text[] default null,
  p_settlement_route_id uuid default null,
  p_date_from date default null,
  p_date_to date default null,
  p_search text default null,
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
  gross_source_impact text,
  provider_fee_impact text,
  batch_fee_snapshot text,
  expected_bank_settlement text,
  actual_bank_movement text,
  variance text,
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

  return query
  select
    b.id, b.settlement_number, b.settlement_route_id,
    coalesce(b.route_code_snapshot, r.code), coalesce(b.route_name_ar_snapshot, r.name_ar), coalesce(b.route_kind_snapshot, r.route_kind),
    b.settlement_date, b.status,
    case when cx.settlement_batch_id is not null then 'cancelled' else b.status end,
    b.provider_statement_reference,
    case when v_can_view_financials then b.gross_source_impact::text end,
    case when v_can_view_financials then b.provider_fee_impact::text end,
    case when v_can_view_financials then b.batch_fee_snapshot::text end,
    case when v_can_view_financials then b.expected_bank_settlement::text end,
    case when v_can_view_financials then bm.actual::text end,
    case when v_can_view_financials and b.expected_bank_settlement is not null then (coalesce(bm.actual, 0) - b.expected_bank_settlement)::text end,
    b.row_version, b.created_at, b.finalized_at, b.reconciled_at
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
  where (p_status is null or b.status = any (p_status))
    and (p_settlement_route_id is null or b.settlement_route_id = p_settlement_route_id)
    and (p_date_from is null or b.settlement_date >= p_date_from)
    and (p_date_to is null or b.settlement_date <= p_date_to)
    and (p_search is null or btrim(p_search) = '' or b.settlement_number ilike '%' || btrim(p_search) || '%')
  order by b.settlement_date desc, b.settlement_number desc
  limit greatest(coalesce(p_limit, 50), 1)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

comment on function public.list_settlement_batches(text[], uuid, date, date, text, integer, integer) is
  'Phase 7 (item 40/46) — settlement batch list. Money figures NULL unless settlements.view_financials. effective_status derived from cancellation existence, never a client-side inference. Requires settlements.view. SECURITY DEFINER.';

revoke execute on function public.list_settlement_batches(text[], uuid, date, date, text, integer, integer) from public;
grant execute on function public.list_settlement_batches(text[], uuid, date, date, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.get_settlement_batch(p_settlement_batch_id uuid)
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
  batch_fee_snapshot text,
  is_batch_fee_override boolean,
  configured_batch_fee_snapshot text,
  override_reason text,
  gross_source_impact text,
  provider_fee_impact text,
  expected_before_batch_fee text,
  expected_bank_settlement text,
  actual_bank_movement text,
  variance text,
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

  select * into v_cancel from public.settlement_batch_cancellations c where c.settlement_batch_id = p_settlement_batch_id;

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

    select coalesce(jsonb_agg(jsonb_build_object(
        'id', l.id, 'source_kind', l.source_kind, 'source_number', l.source_number_snapshot,
        'source_business_date', l.source_business_date,
        'primary_store_name', l.primary_store_name_snapshot, 'secondary_store_name', l.secondary_store_name_snapshot,
        'gross_collection_impact', l.gross_collection_impact::text, 'provider_fee_impact', l.provider_fee_impact::text,
        'expected_settlement_impact', l.expected_settlement_impact::text, 'provider_fee_source', l.provider_fee_source
      ) order by l.source_business_date, l.source_number_snapshot), '[]'::jsonb)
    into v_lines
    from public.settlement_batch_lines l
    where l.settlement_batch_id = p_settlement_batch_id
      and (
        exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = l.primary_store_id)
        or (l.secondary_store_id is not null and exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = l.secondary_store_id))
      );

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
    v_actual := null;
    v_lines := '[]'::jsonb;
    v_movements := '[]'::jsonb;
  end if;

  return query select
    v_batch.id, v_batch.settlement_number, v_batch.settlement_route_id,
    coalesce(v_batch.route_code_snapshot, v_batch.r_code), coalesce(v_batch.route_name_ar_snapshot, v_batch.r_name_ar), v_batch.route_name_en_snapshot,
    coalesce(v_batch.route_kind_snapshot, v_batch.r_route_kind),
    v_batch.settlement_date, v_batch.status,
    case when v_cancel.id is not null then 'cancelled' else v_batch.status end,
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
    case when v_can_view_financials and v_batch.expected_bank_settlement is not null then (coalesce(v_actual, 0) - v_batch.expected_bank_settlement)::text end,
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
  'Phase 7 (item 21/40/47) — full settlement batch detail. Money figures/lines/bank-movements are NULL/empty unless settlements.view_financials. Lines are further filtered to only those whose primary or secondary store the actor can see (item 21 cross-store privacy) — a line belonging to an invisible store is silently omitted, never surfaced with redacted amounts. Requires settlements.view. SECURITY DEFINER.';

revoke execute on function public.get_settlement_batch(uuid) from public;
grant execute on function public.get_settlement_batch(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- settlement_store_filter_lookups() — store picker for the /settlements list
-- page filter (mirrors settlement_route_filter_lookups, 0169), scoped to
-- ONLY the stores the actor can already see (item 20/21) — never the full
-- store catalog regardless of settlements.view.
-- ---------------------------------------------------------------------------
create or replace function public.settlement_store_filter_lookups()
returns table (id uuid, code text, name_ar text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select s.id, s.code, s.name_ar
  from public.stores s
  where public.has_permission('settlements.view')
    and exists (select 1 from public.user_visible_store_ids(auth.uid()) sid where sid = s.id)
  order by s.name_ar;
$$;

comment on function public.settlement_store_filter_lookups() is
  'Phase 7 — store picker for the /settlements list-page filter, scoped to the actor''s own visible stores. Requires settlements.view.';

revoke execute on function public.settlement_store_filter_lookups() from public;
grant execute on function public.settlement_store_filter_lookups() to authenticated;

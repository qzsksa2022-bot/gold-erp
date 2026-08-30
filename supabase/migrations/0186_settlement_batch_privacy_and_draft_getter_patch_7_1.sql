-- ============================================================================
-- 0186: Phase 7 — Integrity Patch 7.1 (3/N): batch all-or-nothing store
-- privacy (§6), draft-only narrow edit getter (§7), create-only store
-- lookup (§24 partial).
-- ============================================================================
-- Migrations 0001-0185 are FROZEN.
--
-- §6 (CRITICAL) — 0182's get_settlement_batch() only hid INDIVIDUAL lines
-- whose store(s) were invisible (via an OR-based OR-filter on the lines
-- query) while still returning the batch HEADER and every AGGREGATE total
-- (gross/fee/expected/actual/variance) computed over ALL lines including
-- the hidden ones — a partial-batch leak. 0182's list_settlement_batches()
-- didn't apply store scope AT ALL. Both are rebuilt here on ONE shared
-- predicate: a batch (once it has lines — i.e. finalized/reconciled/
-- cancelled; a draft has none yet, see §7) is visible in EITHER function
-- only if the actor can see every line's primary store AND (when set) its
-- secondary store. If even ONE line fails that, the batch does not exist
-- for this actor — not the header, not any aggregate, not the line count.
-- ============================================================================
create or replace function public._settlement_batch_all_stores_visible(p_settlement_batch_id uuid, p_actor uuid)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  -- Vacuously true for a batch with zero lines (a draft — nothing to hide
  -- yet, see §7's own separate privacy contract for drafts).
  select not exists (
    select 1 from public.settlement_batch_lines l
    where l.settlement_batch_id = p_settlement_batch_id
      and (
        not exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = l.primary_store_id)
        or (
          l.secondary_store_id is not null
          and not exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = l.secondary_store_id)
        )
      )
  );
$$;

comment on function public._settlement_batch_all_stores_visible(uuid, uuid) is
  'Patch 7.1 §6 — the ONE shared all-or-nothing store-visibility predicate for a settlement batch, used identically by list_settlement_batches() and get_settlement_batch() below. TRUE only if the actor can see every line''s primary store AND (when set) its secondary store; TRUE vacuously for a batch with no lines yet (draft). Internal only.';

revoke execute on function public._settlement_batch_all_stores_visible(uuid, uuid) from public;

-- ---------------------------------------------------------------------------
-- list_settlement_batches() — same signature/output as 0182, now applies
-- the shared predicate. A batch failing it is simply excluded from the
-- list — not shown with redacted fields, not counted, not present at all.
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
    and public._settlement_batch_all_stores_visible(b.id, v_actor)
  order by b.settlement_date desc, b.settlement_number desc
  limit greatest(coalesce(p_limit, 50), 1)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

comment on function public.list_settlement_batches(text[], uuid, date, date, text, integer, integer) is
  'Phase 7.1 patch (§6) — same signature as 0182. Now applies _settlement_batch_all_stores_visible() (§6) — a batch with even one invisible-store line is excluded from the list entirely, not shown with hidden financials. Money figures NULL unless settlements.view_financials (item 40, unchanged). Requires settlements.view. SECURITY DEFINER.';

revoke execute on function public.list_settlement_batches(text[], uuid, date, date, text, integer, integer) from public;
grant execute on function public.list_settlement_batches(text[], uuid, date, date, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_settlement_batch() — same signature/output as 0182. The whole batch
-- now fails closed (raises the SAME "not found" error a genuinely missing
-- batch would) if _settlement_batch_all_stores_visible() is false — no
-- header, no aggregate, no line, no count. Once that gate passes, EVERY
-- line is by definition visible, so the old per-line OR-filter is removed
-- (it would otherwise be dead code that could never exclude anything and
-- risked masking a future regression).
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

  -- §6 — whole-batch fail-closed. Deliberately the SAME error/message as
  -- "does not exist" above — never distinguishable from a genuinely
  -- missing id, so a known UUID cannot be used to probe for existence.
  if not public._settlement_batch_all_stores_visible(p_settlement_batch_id, v_actor) then
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

    -- §6 — every line, unconditionally: the batch-level gate above already
    -- proved every line's store(s) are visible to this actor.
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
  'Phase 7.1 patch (§6) — same signature as 0182. The WHOLE batch (header, every aggregate, every line) fails closed with the same not-found error a missing id would raise, unless _settlement_batch_all_stores_visible() is true — no partial-line leak. Money/lines/bank-movements still additionally require settlements.view_financials (item 40, unchanged). Requires settlements.view. SECURITY DEFINER.';

revoke execute on function public.get_settlement_batch(uuid) from public;
grant execute on function public.get_settlement_batch(uuid) to authenticated;

-- ============================================================================
-- §7 — Draft privacy: a settlements.create-only actor may access ONLY the
-- drafts they created, via this narrow getter — never settlements.view.
-- ============================================================================
create or replace function public.get_draft_settlement_batch_for_edit(p_id uuid)
returns table (
  id uuid,
  settlement_number text,
  settlement_route_id uuid,
  route_code text,
  route_name_ar text,
  route_kind text,
  settlement_date date,
  status text,
  provider_statement_reference text,
  notes text,
  row_version bigint,
  created_by uuid,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_row record;
begin
  if v_actor is null or not public.has_permission('settlements.create') then
    raise exception 'ليست لديك صلاحية إنشاء/تعديل تسوية' using errcode = 'P0001';
  end if;

  select b.*, r.code as r_code, r.name_ar as r_name_ar, r.route_kind as r_route_kind
  into v_row
  from public.settlement_batches b
  join public.settlement_routes r on r.id = b.settlement_route_id
  where b.id = p_id;

  if v_row.id is null or v_row.status <> 'draft' then
    raise exception 'مسودة التسوية غير موجودة' using errcode = 'P0001';
  end if;

  -- §7 — an actor without settlements.view (the operational/full read
  -- permission) may only reach a draft THEY created; settlements.view
  -- holders can already reach any draft via get_settlement_batch() (0186)
  -- and are not further restricted here either.
  if not public.has_permission('settlements.view') and v_row.created_by is distinct from v_actor then
    raise exception 'مسودة التسوية غير موجودة' using errcode = 'P0001';
  end if;

  return query select
    v_row.id, v_row.settlement_number, v_row.settlement_route_id,
    v_row.r_code, v_row.r_name_ar, v_row.r_route_kind,
    v_row.settlement_date, v_row.status, v_row.provider_statement_reference, v_row.notes,
    v_row.row_version, v_row.created_by, v_row.created_at;
end;
$$;

comment on function public.get_draft_settlement_batch_for_edit(uuid) is
  'Patch 7.1 §7 — narrow draft-only getter. Requires settlements.create. A create-only actor (no settlements.view) may access ONLY a draft they themselves created (created_by = auth.uid()) — a known UUID belonging to someone else''s draft raises the same not-found error, never leaking existence. A settlements.view holder is unrestricted (matches get_settlement_batch()). Returns operational fields only — a draft carries no financial snapshot yet (item 18/0172), so there is nothing to redact.';

revoke execute on function public.get_draft_settlement_batch_for_edit(uuid) from public;
grant execute on function public.get_draft_settlement_batch_for_edit(uuid) to authenticated;

-- ============================================================================
-- §24 (partial) — a create-gated store lookup for the create-only workflow
-- (source discovery's store filter, currently only reachable via
-- settlement_store_filter_lookups(), 0182, which requires settlements.view
-- — the exact hidden dependency §24 flags). This is the SAME store set
-- (the actor's own visible stores) under a settlements.create gate instead.
-- ============================================================================
create or replace function public.settlement_create_store_lookups()
returns table (id uuid, code text, name_ar text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select s.id, s.code, s.name_ar
  from public.stores s
  where public.has_permission('settlements.create')
    and exists (select 1 from public.user_visible_store_ids(auth.uid()) sid where sid = s.id)
  order by s.name_ar;
$$;

comment on function public.settlement_create_store_lookups() is
  'Patch 7.1 §24 — store picker for the create-only draft/source-discovery workflow, gated on settlements.create alone (mirrors settlement_store_filter_lookups(), 0182, which requires settlements.view instead — that one remains for the list-page filter, unchanged).';

revoke execute on function public.settlement_create_store_lookups() from public;
grant execute on function public.settlement_create_store_lookups() to authenticated;

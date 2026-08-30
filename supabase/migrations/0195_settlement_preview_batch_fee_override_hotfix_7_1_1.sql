-- ============================================================================
-- 0195: Phase 7 — Final Integrity Hotfix 7.1.1 (4/N): preview_settlement_
-- batch() must accept a batch-fee override so Preview/Finalize stay in
-- parity (§9).
-- ============================================================================
-- Migrations 0001-0194 are FROZEN.
--
-- §9 (CRITICAL) — finalize_settlement_batch() (0185) has accepted
-- p_batch_fee_override/p_override_reason since Phase 7 itself (0178) — a
-- caller may override the route's configured batch fee at Finalization,
-- gated on settlements.override_batch_fee. preview_settlement_batch() never
-- accepted either parameter, so the UI's own override fields (lifted into
-- the Preview Key by Patch 7.1 §16 specifically so an override edit would
-- flip Preview to "stale" — see settlement-draft-workspace.tsx) had NO WAY
-- to actually change what Preview displayed: a user could preview with the
-- configured default fee, enter an override in the Finalize dialog, and
-- Finalize would silently apply a DIFFERENT batch fee than anything Preview
-- ever showed — a real Preview/Finalize parity break for the one field
-- explicitly designed to diverge from the route's default.
--
-- Fix: preview_settlement_batch() gains the SAME two trailing parameters,
-- validated with the SAME rules finalize_settlement_batch() already
-- enforces (settlements.override_batch_fee, mandatory nonblank reason,
-- non-negative, exact 2dp via validate_money_scale()) — never a laxer
-- client-observable precheck than what Finalize itself will enforce. Return
-- shape gains three new columns (configured_batch_fee, effective_batch_fee,
-- batch_fee_overridden) replacing the old single `batch_fee` column, which
-- was ambiguous about whether it reflected the configured default or a
-- pending override — RETURNS TABLE composition cannot be changed via CREATE
-- OR REPLACE, so this is an explicit DROP + CREATE; the new trailing
-- parameters would ALSO have created a distinct overload on their own
-- (Postgres distinguishes by full parameter-type list), so the DROP below
-- is required either way, not merely a style choice.
-- ============================================================================
drop function if exists public.preview_settlement_batch(uuid, date, date, jsonb, date);

create function public.preview_settlement_batch(
  p_settlement_route_id uuid,
  p_source_date_from date,
  p_source_date_to date,
  p_selected_sources jsonb,
  p_settlement_date date default null,
  p_batch_fee_override numeric default null,
  p_override_reason text default null
)
returns table (
  lines jsonb,
  gross_source_impact text,
  provider_fee_impact text,
  expected_before_batch_fee text,
  configured_batch_fee text,
  effective_batch_fee text,
  batch_fee_overridden boolean,
  expected_bank_settlement text,
  fee_version_resolved boolean,
  transaction_fee_strategy text
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_route record;
  v_fee record;
  v_gross numeric := 0;
  v_fee_total numeric := 0;
  v_configured_batch_fee numeric := 0;
  v_effective_batch_fee numeric;
  v_lines jsonb;
  v_effective_date date;
  v_selected_count integer;
  v_matched_count integer;
begin
  if v_actor is null or not public.has_permission('settlements.create') then
    raise exception 'ليست لديك صلاحية إنشاء تسوية' using errcode = 'P0001';
  end if;
  if p_source_date_from is null or p_source_date_to is null then
    raise exception 'نطاق تاريخ المصادر مطلوب' using errcode = 'P0001';
  end if;
  if p_selected_sources is null or jsonb_typeof(p_selected_sources) <> 'array' or jsonb_array_length(p_selected_sources) = 0 then
    raise exception 'يجب اختيار مصدر واحد على الأقل للمعاينة' using errcode = 'P0001';
  end if;
  v_selected_count := jsonb_array_length(p_selected_sources);

  select * into v_route from public.settlement_routes where id = p_settlement_route_id;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;

  v_effective_date := coalesce(p_settlement_date, public.business_today());

  select * into v_fee from public.settlement_route_fee_for_route_on_date(p_settlement_route_id, v_effective_date);

  -- §15 (Patch 7.1, unchanged) — strict match: every selected token must
  -- resolve to a currently-valid, unclaimed candidate or the WHOLE preview
  -- fails.
  select count(*) into v_matched_count
  from public._settlement_unsettled_source_candidates(p_settlement_route_id, p_source_date_from, p_source_date_to, v_actor) c
  where exists (
      select 1 from jsonb_array_elements(p_selected_sources) t
      where (t ->> 'source_kind') = c.source_kind and (t ->> 'source_event_id')::uuid = c.source_event_id
    )
    and not exists (
      select 1 from public.settlement_source_claims cl
      where cl.released_at is null and cl.source_kind = c.source_kind and cl.source_event_id = c.source_event_id
    );

  if v_matched_count <> v_selected_count then
    raise exception 'بعض المصادر المختارة لم تعد صالحة للمعاينة (تغيّرت حالتها، أو أصبحت غير متاحة، أو مُطالَبًا بها ضمن دفعة أخرى) — أعد تحميل قائمة المصادر وحاول مجددًا' using errcode = 'P0001';
  end if;

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'source_kind', c.source_kind,
      'source_event_id', c.source_event_id,
      'source_number', c.source_number,
      'source_business_date', c.source_business_date,
      'store_display', c.store_display,
      'source_label', c.source_label,
      'gross_collection_impact', c.gross_collection_impact::text,
      'provider_fee_impact',
        public._settlement_resolve_line_fee(
          c.source_kind, c.gross_collection_impact, c.provider_fee_impact,
          v_fee.transaction_fee_strategy, v_fee.transaction_fee_model,
          v_fee.percentage_fee, v_fee.fixed_fee, v_fee.cod_fee_reversal_policy
        )::text,
      'expected_settlement_impact',
        (c.gross_collection_impact - public._settlement_resolve_line_fee(
          c.source_kind, c.gross_collection_impact, c.provider_fee_impact,
          v_fee.transaction_fee_strategy, v_fee.transaction_fee_model,
          v_fee.percentage_fee, v_fee.fixed_fee, v_fee.cod_fee_reversal_policy
        ))::text
    ) order by c.source_business_date, c.source_number), '[]'::jsonb),
    coalesce(sum(c.gross_collection_impact), 0),
    coalesce(sum(public._settlement_resolve_line_fee(
      c.source_kind, c.gross_collection_impact, c.provider_fee_impact,
      v_fee.transaction_fee_strategy, v_fee.transaction_fee_model,
      v_fee.percentage_fee, v_fee.fixed_fee, v_fee.cod_fee_reversal_policy
    )), 0)
  into v_lines, v_gross, v_fee_total
  from public._settlement_unsettled_source_candidates(p_settlement_route_id, p_source_date_from, p_source_date_to, v_actor) c
  where exists (
      select 1 from jsonb_array_elements(p_selected_sources) t
      where (t ->> 'source_kind') = c.source_kind
        and (t ->> 'source_event_id')::uuid = c.source_event_id
    )
    and not exists (
      select 1 from public.settlement_source_claims cl
      where cl.released_at is null and cl.source_kind = c.source_kind and cl.source_event_id = c.source_event_id
    );

  if v_fee.fee_version_id is not null then
    v_configured_batch_fee := coalesce(v_fee.batch_fee_fixed, 0);
  end if;

  -- §9 — same validation contract finalize_settlement_batch() (0185)
  -- already enforces for p_batch_fee_override/p_override_reason: requires
  -- settlements.override_batch_fee, a mandatory nonblank reason, a
  -- non-negative amount, exact 2dp. A caller lacking the permission or
  -- supplying an invalid override gets a clean rejection HERE, at Preview
  -- time — never a silent fallback to the configured default that would
  -- itself create a NEW parity break.
  if p_batch_fee_override is not null then
    if not public.has_permission('settlements.override_batch_fee') then
      raise exception 'ليست لديك صلاحية تجاوز رسوم الدفعة الافتراضية' using errcode = 'P0001';
    end if;
    if p_override_reason is null or btrim(p_override_reason) = '' then
      raise exception 'يجب إدخال سبب لتجاوز رسوم الدفعة الافتراضية' using errcode = 'P0001';
    end if;
    if p_batch_fee_override < 0 then
      raise exception 'رسوم الدفعة لا يمكن أن تكون سالبة' using errcode = 'P0001';
    end if;
    perform public.validate_money_scale(p_batch_fee_override, 'رسوم الدفعة');
  end if;

  v_effective_batch_fee := coalesce(p_batch_fee_override, v_configured_batch_fee);

  return query
  select
    v_lines,
    v_gross::text,
    v_fee_total::text,
    (v_gross - v_fee_total)::text,
    v_configured_batch_fee::text,
    v_effective_batch_fee::text,
    (p_batch_fee_override is not null),
    (v_gross - v_fee_total - v_effective_batch_fee)::text,
    (v_fee.fee_version_id is not null),
    v_fee.transaction_fee_strategy;
end;
$$;

comment on function public.preview_settlement_batch(uuid, date, date, jsonb, date, numeric, text) is
  'Hotfix 7.1.1 (§9) — supersedes 0185''s 5-arg version (DROP+CREATE — new trailing p_batch_fee_override/p_override_reason params AND new output columns configured_batch_fee/effective_batch_fee/batch_fee_overridden replacing the old ambiguous single batch_fee column). Override validated with the EXACT SAME rules finalize_settlement_batch() (0185) enforces (settlements.override_batch_fee, mandatory reason, non-negative, 2dp) — for identical inputs against identical DB state, effective_batch_fee here and the snapshot finalize_settlement_batch() commits are always equal. Still DISPLAY-ONLY/NOT authoritative — finalize_settlement_batch() independently re-resolves everything. Requires settlements.create (+ settlements.override_batch_fee only when an override is supplied).';

revoke execute on function public.preview_settlement_batch(uuid, date, date, jsonb, date, numeric, text) from public;
grant execute on function public.preview_settlement_batch(uuid, date, date, jsonb, date, numeric, text) to authenticated;

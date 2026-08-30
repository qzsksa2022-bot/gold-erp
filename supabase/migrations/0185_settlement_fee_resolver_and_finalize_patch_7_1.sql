-- ============================================================================
-- 0185: Phase 7 — Integrity Patch 7.1 (2/N): shared fee resolver,
-- finalize_settlement_batch() + preview_settlement_batch() rewrite.
-- ============================================================================
-- Migrations 0001-0184 are FROZEN. This migration:
--   §14 — extracts ONE canonical fee resolver, public._settlement_resolve_
--     line_fee(), used by BOTH preview_settlement_batch() (0176) and
--     finalize_settlement_batch() (0178), so the two can never again
--     compute a route_formula fee differently (0176's old preview simply
--     summed the candidate's OWN provider_fee_impact — which for
--     route_formula strategy is always 0, since _settlement_unsettled_
--     source_candidates() never computes route fees itself — while
--     finalize computed the real route_formula fee only at Finalization.
--     A COD route_formula batch could preview fee=0 and finalize a real
--     nonzero fee: the exact bug named in Patch 7.1 §14).
--   §17 — route_formula fee: full NUMERIC precision through the percentage
--     + fixed components, ONE explicit final round(...,2) at the very end
--     — no more `round(abs(gross)*pct/100, 2) + fixed_fee` (which rounds
--     the percentage component ALONE before adding the fixed component,
--     early-rounding).
--   §15 — Preview strict matching: selected-token count must equal
--     resolved-candidate count, exactly mirroring finalize's own existing
--     layer-1 check (0178) — ANY stale/invalid/claimed/mismatched token
--     fails the WHOLE preview, never a silent partial preview.
--   §10 — settlement_date <= business_today() (defensive re-check at
--     Finalize — Create/Update Draft's own enforcement is migration 0186)
--     AND every selected source's source_business_date <= settlement_date
--     (a batch can never contain a source dated after the batch itself).
--   §11 — Daily Close is now keyed on settlement_date (the date
--     Finalization's financial effect is actually dated), for EVERY
--     distinct store touched by the batch (primary + secondary, across
--     every matched line) — not source_business_date per line (the old,
--     wrong contract, 0178).
--   §20/§21 (finalize side) — the old ad-hoc "last collected event ever"
--     lookup and per-source-kind secondary-store lookup are DELETED
--     entirely; both now come straight from _settlement_unsettled_source_
--     candidates()'s own fee_lookup_date/secondary_store_id/secondary_
--     store_display columns (0184) — eliminating the duplication, not
--     just moving the bug.
-- Same public signatures as 0176/0178 (CREATE OR REPLACE, no new/removed
-- parameters) — every existing caller (UI, tests) keeps working unchanged.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Widen settlement_batches_calc_version_consistent to also allow
-- settlement_calculation_version = 2 — every batch finalized from this
-- migration forward is stamped 2 (finalized under the Patch 7.1-corrected
-- fee/date/COD logic below); every batch already finalized under 0178's
-- pre-patch logic keeps its permanent historical 1 (settlement_batch_lines/
-- settlement_batches financial facts are immutable once non-draft, per
-- 0172/0173 — this migration never touches an existing row's stamped
-- value, only widens what a FUTURE write may set).
-- ---------------------------------------------------------------------------
alter table public.settlement_batches
  drop constraint settlement_batches_calc_version_consistent;
alter table public.settlement_batches
  add constraint settlement_batches_calc_version_consistent check (
    (status in ('finalized', 'reconciled') and settlement_calculation_version in (1, 2))
    or (status = 'draft' and settlement_calculation_version is null)
  );

comment on constraint settlement_batches_calc_version_consistent on public.settlement_batches is
  'Patch 7.1 — widened to allow 2 alongside the original 1. 1 = finalized under 0178''s pre-Patch-7.1 logic (early-rounded route_formula fee, source-date-keyed Daily Close, ad-hoc COD fee-pairing). 2 = finalized under this migration''s corrected logic. Never recomputed on an existing (immutable) row.';

-- ---------------------------------------------------------------------------
-- §14/§17 — the shared canonical fee resolver. IMMUTABLE (pure function of
-- its inputs, no table access — same discipline as compute_sales_return_
-- fee_reversal_v2(), 0109), so it can be called identically from a STABLE
-- preview function and a VOLATILE finalize function with no risk of drift.
-- ---------------------------------------------------------------------------
create or replace function public._settlement_resolve_line_fee(
  p_source_kind text,
  p_gross numeric,
  p_source_snapshot_fee numeric,
  p_transaction_fee_strategy text,
  p_transaction_fee_model text,
  p_percentage_fee numeric,
  p_fixed_fee numeric,
  p_cod_fee_reversal_policy text
)
returns numeric
language plpgsql
immutable
as $$
declare
  v_magnitude numeric := 0;
begin
  if p_transaction_fee_strategy = 'source_snapshot' then
    return coalesce(p_source_snapshot_fee, 0);
  elsif p_transaction_fee_strategy = 'none' then
    return 0;
  end if;

  -- route_formula (§17): accumulate BOTH components at full precision
  -- first, round exactly ONCE at the end — the single explicit monetary
  -- rounding boundary for this magnitude.
  if p_transaction_fee_model in ('percentage', 'percentage_plus_fixed') then
    v_magnitude := v_magnitude + (abs(p_gross) * coalesce(p_percentage_fee, 0) / 100);
  end if;
  if p_transaction_fee_model in ('fixed', 'percentage_plus_fixed') then
    v_magnitude := v_magnitude + coalesce(p_fixed_fee, 0);
  end if;
  v_magnitude := round(v_magnitude, 2);

  if p_source_kind = 'cod_reversal' then
    if p_cod_fee_reversal_policy = 'none' then
      return 0;
    else
      return -v_magnitude;
    end if;
  end if;

  return case when p_gross < 0 then -v_magnitude else v_magnitude end;
end;
$$;

comment on function public._settlement_resolve_line_fee(text, numeric, numeric, text, text, numeric, numeric, text) is
  'Patch 7.1 §14/§17 — the ONE canonical per-line fee computation, shared by preview_settlement_batch() and finalize_settlement_batch() so they can never drift. route_formula: full-precision percentage+fixed accumulation, single final round(...,2). source_snapshot: reuses the source''s own snapshot fee as-is. none: zero. cod_reversal mirrors the paired collection''s magnitude (sign flipped), gated by cod_fee_reversal_policy. IMMUTABLE — no table access, every input pre-resolved by the caller.';

revoke execute on function public._settlement_resolve_line_fee(text, numeric, numeric, text, text, numeric, numeric, text) from public;

-- ---------------------------------------------------------------------------
-- preview_settlement_batch() — §14 (route_formula parity) + §15 (strict
-- all-or-nothing selected-source matching). Same signature as 0176.
-- ---------------------------------------------------------------------------
create or replace function public.preview_settlement_batch(
  p_settlement_route_id uuid,
  p_source_date_from date,
  p_source_date_to date,
  p_selected_sources jsonb,
  p_settlement_date date default null
)
returns table (
  lines jsonb,
  gross_source_impact text,
  provider_fee_impact text,
  expected_before_batch_fee text,
  batch_fee text,
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
  v_batch_fee numeric := 0;
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

  -- §15 — strict match: count how many of the resolved (unclaimed) candidate
  -- rows are actually referenced by a selected token. If ANY selected token
  -- fails to match a currently-valid candidate, the WHOLE preview fails —
  -- never a silent partial preview over the rest.
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
    v_batch_fee := coalesce(v_fee.batch_fee_fixed, 0);
  end if;

  return query
  select
    v_lines,
    v_gross::text,
    v_fee_total::text,
    (v_gross - v_fee_total)::text,
    v_batch_fee::text,
    (v_gross - v_fee_total - v_batch_fee)::text,
    (v_fee.fee_version_id is not null),
    v_fee.transaction_fee_strategy;
end;
$$;

comment on function public.preview_settlement_batch(uuid, date, date, jsonb, date) is
  'Phase 7.1 patch (§14/§15) — DISPLAY-ONLY preview, now sharing _settlement_resolve_line_fee() with finalize_settlement_batch() for exact route_formula parity (§14), and strict all-or-nothing selected-source matching (§15: any stale/invalid/claimed token fails the WHOLE preview). NOT authoritative — finalize_settlement_batch() independently re-resolves everything. Requires settlements.create.';

revoke execute on function public.preview_settlement_batch(uuid, date, date, jsonb, date) from public;
grant execute on function public.preview_settlement_batch(uuid, date, date, jsonb, date) to authenticated;

-- ---------------------------------------------------------------------------
-- finalize_settlement_batch() — §10/§11/§14/§17/§20/§21. Same signature as
-- 0178.
-- ---------------------------------------------------------------------------
create or replace function public.finalize_settlement_batch(
  p_settlement_batch_id uuid,
  p_expected_version bigint,
  p_selected_sources jsonb,
  p_batch_fee_override numeric default null,
  p_override_reason text default null,
  p_closed_day_reason text default null
)
returns table (id uuid, settlement_number text, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_batch record;
  v_route record;
  v_batch_fee record;
  v_pm_name_ar text;
  v_cc_name_ar text;
  v_carrier_name_ar text;
  v_selected_count integer;
  v_matched_count integer;
  v_needs_closed_override boolean := false;
  v_gross_total numeric := 0;
  v_fee_total numeric := 0;
  v_batch_fee_amount numeric := 0;
  v_line record;
  v_fee record;
  v_line_fee numeric;
  v_dc_store record;
  v_today date;
begin
  if v_actor is null or not public.has_permission('settlements.finalize') then
    raise exception 'ليست لديك صلاحية اعتماد دفعة تسوية' using errcode = 'P0001';
  end if;

  if p_selected_sources is null or jsonb_typeof(p_selected_sources) <> 'array' or jsonb_array_length(p_selected_sources) = 0 then
    raise exception 'يجب اختيار مصدر واحد على الأقل لاعتماد الدفعة' using errcode = 'P0001';
  end if;
  v_selected_count := jsonb_array_length(p_selected_sources);

  select * into v_batch from public.settlement_batches b where b.id = p_settlement_batch_id for update;
  if v_batch.id is null then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;
  if v_batch.status <> 'draft' then
    raise exception 'دفعة التسوية هذه ليست في حالة مسودة — لا يمكن اعتمادها' using errcode = 'P0001';
  end if;
  if p_expected_version is null or v_batch.row_version <> p_expected_version then
    raise exception 'تم تعديل دفعة التسوية هذه من قِبل مستخدم آخر — يرجى إعادة التحميل والمحاولة مجددًا' using errcode = 'P0001';
  end if;

  -- §10 — settlement_date can never be in the future, re-checked here
  -- defensively (Create/Update Draft, 0186, already enforce this going
  -- forward — this covers any draft that predates that enforcement).
  v_today := public.business_today();
  if v_batch.settlement_date > v_today then
    raise exception 'تاريخ التسوية (%) لا يمكن أن يكون في المستقبل' , v_batch.settlement_date using errcode = 'P0001';
  end if;

  -- Settlement Master SHARED lock — unchanged from 0178.
  perform public.acquire_settlement_master_lock_shared();

  select * into v_route from public.settlement_routes r where r.id = v_batch.settlement_route_id;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;
  if v_route.status <> 'active' then
    raise exception 'تم تعطيل مسار التسوية منذ إنشاء المسودة — لا يمكن اعتماد دفعة عليه' using errcode = 'P0001';
  end if;

  select * into v_batch_fee from public.settlement_route_fee_for_route_on_date(v_route.id, v_batch.settlement_date);
  if v_batch_fee.fee_version_id is null then
    raise exception 'لا يوجد إصدار رسوم يغطي تاريخ % لهذا المسار — أنشئ إصدار رسوم أولًا عبر create_settlement_route_fee_version()', v_batch.settlement_date using errcode = 'P0001';
  end if;

  if v_route.payment_method_id is not null then
    select pm.name_ar into v_pm_name_ar from public.payment_methods pm where pm.id = v_route.payment_method_id;
  end if;
  if v_route.collection_channel_id is not null then
    select cc.name_ar into v_cc_name_ar from public.collection_channels cc where cc.id = v_route.collection_channel_id;
  end if;
  if v_route.shipping_carrier_id is not null then
    select sc.name_ar into v_carrier_name_ar from public.shipping_carriers sc where sc.id = v_route.shipping_carrier_id;
  end if;

  -- Layer 1 double-claim/staleness check — unchanged shape from 0178, plus
  -- §10's new chronology guard (no source dated after the batch itself).
  select count(*) into v_matched_count
  from public._settlement_unsettled_source_candidates(v_route.id, date '-infinity', date 'infinity', v_actor) c
  where exists (
      select 1 from jsonb_array_elements(p_selected_sources) t
      where (t ->> 'source_kind') = c.source_kind and (t ->> 'source_event_id')::uuid = c.source_event_id
    )
    and not exists (
      select 1 from public.settlement_source_claims cl
      where cl.released_at is null and cl.source_kind = c.source_kind and cl.source_event_id = c.source_event_id
    );

  if v_matched_count <> v_selected_count then
    raise exception 'بعض المصادر المختارة لم تعد متاحة للتسوية (تغيّرت حالتها، أو أصبحت مُطالَبًا بها ضمن دفعة أخرى) — أعد تحميل قائمة المصادر غير المسوّاة وحاول مجددًا' using errcode = 'P0001';
  end if;

  if exists (
    select 1
    from public._settlement_unsettled_source_candidates(v_route.id, date '-infinity', date 'infinity', v_actor) c
    where exists (
        select 1 from jsonb_array_elements(p_selected_sources) t
        where (t ->> 'source_kind') = c.source_kind and (t ->> 'source_event_id')::uuid = c.source_event_id
      )
      and c.source_business_date > v_batch.settlement_date
  ) then
    raise exception 'أحد المصادر المختارة بتاريخ لاحق لتاريخ التسوية نفسه — لا يمكن أن تتضمن دفعة تسوية مصدرًا مؤرَّخًا بعدها' using errcode = 'P0001';
  end if;

  -- §11 — Daily Close is keyed on settlement_date (the date Finalization's
  -- OWN financial effect is dated), for EVERY distinct store touched by any
  -- matched line (primary + secondary), checked ONCE per store here —
  -- replacing 0178's wrong per-line check on source_business_date.
  for v_dc_store in
    select distinct store_id from (
      select c.primary_store_id as store_id
      from public._settlement_unsettled_source_candidates(v_route.id, date '-infinity', date 'infinity', v_actor) c
      where exists (
          select 1 from jsonb_array_elements(p_selected_sources) t
          where (t ->> 'source_kind') = c.source_kind and (t ->> 'source_event_id')::uuid = c.source_event_id
        )
      union
      select c.secondary_store_id as store_id
      from public._settlement_unsettled_source_candidates(v_route.id, date '-infinity', date 'infinity', v_actor) c
      where c.secondary_store_id is not null
        and exists (
          select 1 from jsonb_array_elements(p_selected_sources) t
          where (t ->> 'source_kind') = c.source_kind and (t ->> 'source_event_id')::uuid = c.source_event_id
        )
    ) x
  loop
    perform public.acquire_daily_close_lock_shared(v_dc_store.store_id, v_batch.settlement_date);
    if exists (
      select 1 from public.daily_closings dc
      where dc.store_id = v_dc_store.store_id and dc.business_date = v_batch.settlement_date
    ) then
      v_needs_closed_override := true;
    end if;
  end loop;

  for v_line in
    select c.source_kind, c.source_event_id, c.source_number, c.source_business_date,
           c.primary_store_id, c.store_display, c.source_label,
           c.gross_collection_impact as gross, c.provider_fee_impact as source_fee,
           c.fee_lookup_date, c.secondary_store_id, c.secondary_store_display
    from public._settlement_unsettled_source_candidates(v_route.id, date '-infinity', date 'infinity', v_actor) c
    where exists (
        select 1 from jsonb_array_elements(p_selected_sources) t
        where (t ->> 'source_kind') = c.source_kind and (t ->> 'source_event_id')::uuid = c.source_event_id
      )
      and not exists (
        select 1 from public.settlement_source_claims cl
        where cl.released_at is null and cl.source_kind = c.source_kind and cl.source_event_id = c.source_event_id
      )
  loop
    select * into v_fee from public.settlement_route_fee_for_route_on_date(v_route.id, v_line.fee_lookup_date);
    if v_fee.fee_version_id is null then
      raise exception 'لا يوجد إصدار رسوم يغطي تاريخ % للمصدر % — لا يمكن اعتماد الدفعة', v_line.fee_lookup_date, v_line.source_number using errcode = 'P0001';
    end if;
    if v_route.route_kind = 'cod_carrier' and v_fee.transaction_fee_strategy = 'source_snapshot' then
      raise exception 'استراتيجية source_snapshot غير صالحة لمسار COD ناقل (المصدر %) — كوّن إصدار رسوم بـ route_formula أو none بدلًا من ذلك', v_line.source_number using errcode = 'P0001';
    end if;

    v_line_fee := public._settlement_resolve_line_fee(
      v_line.source_kind, v_line.gross, v_line.source_fee,
      v_fee.transaction_fee_strategy, v_fee.transaction_fee_model,
      v_fee.percentage_fee, v_fee.fixed_fee, v_fee.cod_fee_reversal_policy
    );

    insert into public.settlement_batch_lines (
      settlement_batch_id, source_kind, source_event_id, source_number_snapshot, source_business_date,
      primary_store_id, secondary_store_id, primary_store_name_snapshot, secondary_store_name_snapshot,
      payment_method_id_snapshot, payment_method_name_snapshot,
      collection_channel_id_snapshot, collection_channel_name_snapshot,
      shipping_carrier_id_snapshot, shipping_carrier_name_snapshot,
      gross_collection_impact, provider_fee_impact, expected_settlement_impact,
      provider_fee_source, source_fee_version_id, route_fee_version_id, source_metadata
    ) values (
      p_settlement_batch_id, v_line.source_kind, v_line.source_event_id, v_line.source_number, v_line.source_business_date,
      v_line.primary_store_id, v_line.secondary_store_id, v_line.store_display, v_line.secondary_store_display,
      v_route.payment_method_id, v_pm_name_ar,
      v_route.collection_channel_id, v_cc_name_ar,
      v_route.shipping_carrier_id, v_carrier_name_ar,
      v_line.gross, v_line_fee, v_line.gross - v_line_fee,
      v_fee.transaction_fee_strategy,
      case
        when v_fee.transaction_fee_strategy = 'source_snapshot' and v_line.source_kind = 'sale'
          then (select so_.payment_fee_version_id from public.sales_orders so_ where so_.id = v_line.source_event_id)
        when v_fee.transaction_fee_strategy = 'source_snapshot' and v_line.source_kind = 'adjustment_approved'
          then (select soa_.payment_fee_version_id from public.sales_order_adjustments soa_ where soa_.id = v_line.source_event_id)
        else null
      end,
      v_fee.fee_version_id,
      jsonb_build_object('source_label', v_line.source_label)
    );

    insert into public.settlement_source_claims (settlement_batch_id, source_kind, source_event_id, claimed_by)
    values (p_settlement_batch_id, v_line.source_kind, v_line.source_event_id, v_actor);

    v_gross_total := v_gross_total + v_line.gross;
    v_fee_total := v_fee_total + v_line_fee;
  end loop;

  if v_needs_closed_override then
    if not public.has_permission('settlements.process_closed_day') then
      raise exception 'يقع تاريخ التسوية % في يوم مقفل لأحد متاجر المصادر المختارة — يتطلب صلاحية خاصة (settlements.process_closed_day)', v_batch.settlement_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لاعتماد تسوية في يوم مقفل' using errcode = 'P0001';
    end if;
  end if;

  v_batch_fee_amount := coalesce(v_batch_fee.batch_fee_fixed, 0);
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

  update public.settlement_batches b
  set
    status = 'finalized',
    route_code_snapshot = v_route.code,
    route_name_ar_snapshot = v_route.name_ar,
    route_name_en_snapshot = v_route.name_en,
    route_kind_snapshot = v_route.route_kind,
    payment_method_id_snapshot = v_route.payment_method_id,
    payment_method_name_snapshot = v_pm_name_ar,
    collection_channel_id_snapshot = v_route.collection_channel_id,
    collection_channel_name_snapshot = v_cc_name_ar,
    shipping_carrier_id_snapshot = v_route.shipping_carrier_id,
    shipping_carrier_name_snapshot = v_carrier_name_ar,
    route_fee_version_id_snapshot = v_batch_fee.fee_version_id,
    transaction_fee_strategy_snapshot = v_batch_fee.transaction_fee_strategy,
    transaction_percentage_fee_snapshot = v_batch_fee.percentage_fee,
    transaction_fixed_fee_snapshot = v_batch_fee.fixed_fee,
    batch_fee_snapshot = coalesce(p_batch_fee_override, v_batch_fee_amount),
    is_batch_fee_override = (p_batch_fee_override is not null),
    configured_batch_fee_snapshot = v_batch_fee_amount,
    override_reason = p_override_reason,
    gross_source_impact = v_gross_total,
    provider_fee_impact = v_fee_total,
    expected_before_batch_fee = v_gross_total - v_fee_total,
    expected_bank_settlement = (v_gross_total - v_fee_total) - coalesce(p_batch_fee_override, v_batch_fee_amount),
    settlement_calculation_version = 2,
    finalized_at = now(),
    finalized_by = v_actor,
    row_version = b.row_version + 1
  where b.id = p_settlement_batch_id;

  perform public.log_audit_event(
    'settlement.finalize', 'settlement_batch', p_settlement_batch_id, null,
    jsonb_build_object(
      'settlement_number', v_batch.settlement_number, 'lines_count', v_matched_count,
      'gross_source_impact', v_gross_total::text, 'provider_fee_impact', v_fee_total::text,
      'batch_fee', coalesce(p_batch_fee_override, v_batch_fee_amount)::text,
      'expected_bank_settlement', ((v_gross_total - v_fee_total) - coalesce(p_batch_fee_override, v_batch_fee_amount))::text,
      'settlement_calculation_version', 2
    )
  );

  if v_needs_closed_override then
    perform public.log_audit_event(
      'settlement.closed_day_override', 'settlement_batch', p_settlement_batch_id, null,
      jsonb_build_object('settlement_number', v_batch.settlement_number, 'settlement_date', v_batch.settlement_date), p_closed_day_reason
    );
  end if;
  if p_batch_fee_override is not null then
    perform public.log_audit_event(
      'settlement.batch_fee_override', 'settlement_batch', p_settlement_batch_id,
      jsonb_build_object('configured_batch_fee', v_batch_fee_amount::text),
      jsonb_build_object('override_batch_fee', p_batch_fee_override::text),
      p_override_reason
    );
  end if;

  return query select p_settlement_batch_id, v_batch.settlement_number, v_batch.row_version + 1;
end;
$$;

comment on function public.finalize_settlement_batch(uuid, bigint, jsonb, numeric, text, text) is
  'Phase 7.1 patch (§10/§11/§14/§17/§20/§21) — same public contract as 0178. Rejects a future settlement_date and any selected source dated after settlement_date (§10). Daily Close is now checked per DISTINCT store (primary+secondary) on settlement_date, once each, not per-line on source_business_date (§11). Fee computation delegates to the shared _settlement_resolve_line_fee() (§14/§17, same function preview_settlement_batch uses). COD reversal fee-lookup-date and cross-store secondary-store snapshot now come directly from _settlement_unsettled_source_candidates() (0184) instead of ad-hoc re-derivation (§20/§21 — eliminates the ‘‘last collected event ever'''' mispairing bug at its root). settlement_calculation_version=2 for every batch finalized under this corrected logic (version 1 remains permanently on every batch finalized under the pre-Patch-7.1 logic — historical rows never touched). SECURITY DEFINER.';

revoke execute on function public.finalize_settlement_batch(uuid, bigint, jsonb, numeric, text, text) from public;
grant execute on function public.finalize_settlement_batch(uuid, bigint, jsonb, numeric, text, text) to authenticated;

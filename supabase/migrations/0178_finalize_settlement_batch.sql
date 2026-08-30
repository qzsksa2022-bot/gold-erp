-- ============================================================================
-- 0178: Phase 7 — Settlements Core (12/N): finalize_settlement_batch()
-- ============================================================================
-- Migrations 0001-0177 are unmodified.
--
-- THE authority function of this module (item 23). Atomic, all-or-nothing —
-- Postgres itself guarantees this: any raised exception anywhere in this
-- function aborts the WHOLE enclosing transaction, so a partially-inserted
-- settlement_batch_lines/settlement_source_claims set can never be observed.
--
-- Governing principle (item 1) reasserted here in code, not just comments:
-- this function NEVER recomputes a source's own money figures. It only
-- re-resolves them FROM DB (via the SAME private candidate resolver
-- list_unsettled_settlement_sources()/preview_settlement_batch() already use
-- — 0176 — so all three call sites can never drift apart on the single most
-- error-prone piece of logic in this module) and applies the Settlement
-- Route's OWN fee configuration (source_snapshot reuse vs. route_formula
-- computation) on top, per item 11.
--
-- Client-supplied amounts are NEVER trusted (item 1/23): p_selected_sources
-- carries ONLY {source_kind, source_event_id} tokens (exactly like preview_
-- settlement_batch, 0176), never a money figure. Every figure written to
-- settlement_batch_lines/settlement_batches is resolved fresh, here, from
-- current DB state.
--
-- Concurrency-double-claim safety has TWO independent layers, deliberately:
--   1) A pre-loop count check (matched vs. selected) that rejects STALE
--      selections (a source that was valid at preview time but changed/
--      disappeared since) with a clear, actionable error.
--   2) The settlement_source_claims_active_unique_idx partial unique index
--      (0173) itself, which is the REAL DB-level race guard — if a
--      concurrent Finalization claims the exact same source between this
--      function's SELECT and its INSERT, the unique_violation on INSERT
--      aborts this whole transaction (Postgres unique-violation errors
--      propagate as a normal exception, so it is caught by nothing special
--      here — it simply aborts, and the caller sees a clear "المصدر محجوز
--      بالفعل" style message via the errcode/constraint name; a friendlier
--      wrapper message is not layered on top here, matching how every other
--      partial-unique-index race in this codebase surfaces (e.g. adjustment
--      approval races) — see supabase/tests/settlements_phase7.test.sql for
--      the dblink proof this genuinely blocks, not just documents, the
--      race).
--
-- route_formula fee computation (item 11, judgment call documented here
-- explicitly since the governing spec does not spell out the exact formula
-- sign/rounding beyond "%/fixed configuration"):
--   magnitude = round(|gross| * percentage_fee/100, 2) + fixed_fee, per the
--   version's transaction_fee_model (percentage / fixed / percentage_plus_
--   fixed component selection — 'none' magnitude is never reached, since a
--   'none'-strategy line is handled separately as a flat zero).
--   - Ordinary lines (sale/return/return_reversal/adjustment/adjustment_
--     reversal, and cod_collection): fee sign follows the gross sign — a
--     positive (charge) gross gets a positive fee (reduces expected); a
--     negative (refund/reversal) gross gets a negative fee (a credit,
--     increases expected) — the exact same convention already established
--     for source_snapshot rows (item 3), so route_formula and source_
--     snapshot rows combine consistently within one batch.
--   - cod_reversal is the one documented exception: it mirrors the ORIGINAL
--     collection's fee (resolved at the collection's OWN business date, not
--     the reversal's — the fee actually charged does not change
--     retroactively just because the fee-version table has since moved on),
--     gated by that version's cod_fee_reversal_policy ('full'/'proportional'
--     both apply the full magnitude — no partial-COD concept exists at
--     shipment granularity, per 0176's own documented limitation; 'none'
--     applies zero).
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
  -- Plain text, not record — a route's own shape (settlement_routes_kind_
  -- fields_consistent, 0168) guarantees at least one of payment_method_id/
  -- collection_channel_id/shipping_carrier_id is ALWAYS null (a
  -- payment_collection route never has shipping_carrier_id; a cod_carrier
  -- route never has payment_method_id or collection_channel_id), so the
  -- corresponding record here would stay genuinely unassigned (not merely
  -- NULL-valued) on every single call — referencing an unassigned record's
  -- field raises "record ... is not assigned yet", not a NULL. Only
  -- .name_ar was ever read from these below, so a plain nullable text
  -- variable (defaulting to NULL, exactly the desired snapshot value when
  -- that FK is genuinely absent) sidesteps the whole class of bug.
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
  v_fee_lookup_date date;
  v_fee record;
  v_line_fee numeric;
  v_magnitude numeric;
  v_secondary_store_id uuid;
  v_secondary_store_name text;
  v_orig_collection_date date;
  v_shipment_id uuid;
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

  -- Settlement Master SHARED lock — taken before resolving route/fee-version
  -- so a concurrent Master Data write (0169/0171, which take the EXCLUSIVE
  -- counterpart) can never be observed half-written here (item 13/0167).
  perform public.acquire_settlement_master_lock_shared();

  select * into v_route from public.settlement_routes r where r.id = v_batch.settlement_route_id;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;
  if v_route.status <> 'active' then
    raise exception 'تم تعطيل مسار التسوية منذ إنشاء المسودة — لا يمكن اعتماد دفعة عليه' using errcode = 'P0001';
  end if;

  -- Batch-level (display/audit) fee-version snapshot, resolved at the
  -- batch's OWN settlement_date — item 38's snapshot, distinct from the
  -- per-line resolution below (which uses each source's own business date).
  select * into v_batch_fee from public.settlement_route_fee_for_route_on_date(v_route.id, v_batch.settlement_date);
  if v_batch_fee.fee_version_id is null then
    raise exception 'لا يوجد إصدار رسوم يغطي تاريخ % لهذا المسار — أنشئ إصدار رسوم أولًا عبر create_settlement_route_fee_version()', v_batch.settlement_date using errcode = 'P0001';
  end if;

  -- Table aliases + qualified `id` below are load-bearing, not style: this
  -- function's RETURNS TABLE clause declares `id` as an implicit PL/pgSQL
  -- variable in scope for the whole function body, so a bare `where id =
  -- ...` here is ambiguous between that OUT parameter and the queried
  -- table's own id column — PostgreSQL raises "column reference \"id\" is
  -- ambiguous" on every call that reaches this point (i.e. every route with
  -- a payment_method_id/collection_channel_id/shipping_carrier_id set,
  -- which is every route that exists per settlement_routes_kind_fields_
  -- consistent, 0168) unless every column is qualified by a table alias.
  if v_route.payment_method_id is not null then
    select pm.name_ar into v_pm_name_ar from public.payment_methods pm where pm.id = v_route.payment_method_id;
  end if;
  if v_route.collection_channel_id is not null then
    select cc.name_ar into v_cc_name_ar from public.collection_channels cc where cc.id = v_route.collection_channel_id;
  end if;
  if v_route.shipping_carrier_id is not null then
    select sc.name_ar into v_carrier_name_ar from public.shipping_carriers sc where sc.id = v_route.shipping_carrier_id;
  end if;

  -- Re-resolve every selected source FROM DB (never trust client amounts) and
  -- reject if any selected token is no longer a valid/unclaimed candidate —
  -- layer 1 of the double-claim safety net (see header).
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

  for v_line in
    select c.source_kind, c.source_event_id, c.source_number, c.source_business_date,
           c.primary_store_id, c.store_display, c.source_label,
           c.gross_collection_impact as gross, c.provider_fee_impact as source_fee
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
    -- Daily Close (item 23) — shared lock + check for this line's own
    -- (store, business_date). Many lines commonly share the same pair; the
    -- shared advisory lock is cheap/reentrant to re-acquire.
    perform public.acquire_daily_close_lock_shared(v_line.primary_store_id, v_line.source_business_date);
    if exists (
      select 1 from public.daily_closings dc
      where dc.store_id = v_line.primary_store_id and dc.business_date = v_line.source_business_date
    ) then
      v_needs_closed_override := true;
    end if;

    v_secondary_store_id := null;
    v_secondary_store_name := null;
    v_fee_lookup_date := v_line.source_business_date;

    if v_line.source_kind = 'cod_reversal' then
      select e.shipment_id into v_shipment_id from public.shipment_cod_events e where e.id = v_line.source_event_id;
      select prior.business_date into v_orig_collection_date
        from public.shipment_cod_events prior
        where prior.shipment_id = v_shipment_id and prior.state = 'collected'
        order by prior.created_at desc
        limit 1;
      v_fee_lookup_date := coalesce(v_orig_collection_date, v_line.source_business_date);
    end if;

    if v_line.source_kind = 'adjustment_approved' then
      select so.store_id into v_secondary_store_id
      from public.sales_order_adjustments a
      join public.sales_orders so on so.id = a.sales_order_id
      where a.id = v_line.source_event_id;
    elsif v_line.source_kind = 'adjustment_reversal' then
      select so.store_id into v_secondary_store_id
      from public.sales_order_adjustment_reversals ar
      join public.sales_order_adjustments a on a.id = ar.sales_order_adjustment_id
      join public.sales_orders so on so.id = a.sales_order_id
      where ar.id = v_line.source_event_id;
    end if;
    if v_secondary_store_id is not null then
      if v_secondary_store_id = v_line.primary_store_id then
        v_secondary_store_id := null;
      else
        select s.name_ar into v_secondary_store_name from public.stores s where s.id = v_secondary_store_id;
      end if;
    end if;

    select * into v_fee from public.settlement_route_fee_for_route_on_date(v_route.id, v_fee_lookup_date);
    if v_fee.fee_version_id is null then
      raise exception 'لا يوجد إصدار رسوم يغطي تاريخ % للمصدر % — لا يمكن اعتماد الدفعة', v_fee_lookup_date, v_line.source_number using errcode = 'P0001';
    end if;
    if v_route.route_kind = 'cod_carrier' and v_fee.transaction_fee_strategy = 'source_snapshot' then
      raise exception 'استراتيجية source_snapshot غير صالحة لمسار COD ناقل (المصدر %) — كوّن إصدار رسوم بـ route_formula أو none بدلًا من ذلك', v_line.source_number using errcode = 'P0001';
    end if;

    if v_fee.transaction_fee_strategy = 'source_snapshot' then
      v_line_fee := v_line.source_fee;
    elsif v_fee.transaction_fee_strategy = 'none' then
      v_line_fee := 0;
    else -- route_formula
      v_magnitude := 0;
      if v_fee.transaction_fee_model in ('percentage', 'percentage_plus_fixed') then
        v_magnitude := v_magnitude + round(abs(v_line.gross) * coalesce(v_fee.percentage_fee, 0) / 100, 2);
      end if;
      if v_fee.transaction_fee_model in ('fixed', 'percentage_plus_fixed') then
        v_magnitude := v_magnitude + coalesce(v_fee.fixed_fee, 0);
      end if;

      if v_line.source_kind = 'cod_reversal' then
        if v_fee.cod_fee_reversal_policy = 'none' then
          v_line_fee := 0;
        else
          v_line_fee := -v_magnitude;
        end if;
      else
        v_line_fee := case when v_line.gross < 0 then -v_magnitude else v_magnitude end;
      end if;
    end if;

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
      v_line.primary_store_id, v_secondary_store_id, v_line.store_display, v_secondary_store_name,
      v_route.payment_method_id, v_pm_name_ar,
      v_route.collection_channel_id, v_cc_name_ar,
      v_route.shipping_carrier_id, v_carrier_name_ar,
      v_line.gross, v_line_fee, v_line.gross - v_line_fee,
      v_fee.transaction_fee_strategy,
      -- so_/soa_ aliases below are load-bearing, not style — same `id`
      -- ambiguity against this function's RETURNS TABLE `id` OUT parameter
      -- documented above.
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

    -- Layer 2 of the double-claim safety net — see header. Raises
    -- unique_violation (aborting the whole transaction) if a concurrent
    -- Finalization claimed this exact source first.
    insert into public.settlement_source_claims (settlement_batch_id, source_kind, source_event_id, claimed_by)
    values (p_settlement_batch_id, v_line.source_kind, v_line.source_event_id, v_actor);

    v_gross_total := v_gross_total + v_line.gross;
    v_fee_total := v_fee_total + v_line_fee;
  end loop;

  if v_needs_closed_override then
    if not public.has_permission('settlements.process_closed_day') then
      raise exception 'أحد المصادر المختارة يقع في يوم مقفل لمتجره — يتطلب صلاحية خاصة (settlements.process_closed_day)' using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لاعتماد تسوية تتضمن يومًا مقفلًا' using errcode = 'P0001';
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
    settlement_calculation_version = 1,
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
      'expected_bank_settlement', ((v_gross_total - v_fee_total) - coalesce(p_batch_fee_override, v_batch_fee_amount))::text
    )
  );

  if v_needs_closed_override then
    perform public.log_audit_event(
      'settlement.closed_day_override', 'settlement_batch', p_settlement_batch_id, null,
      jsonb_build_object('settlement_number', v_batch.settlement_number), p_closed_day_reason
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
  'Phase 7 (item 23) — THE Finalization authority function. Re-resolves every selected source and its fee treatment from DB state (never trusts client-supplied amounts), snapshots route/fee-version/batch-figures onto settlement_batches permanently (item 38), writes one immutable settlement_batch_lines row + one settlement_source_claims row per source, sets status=finalized. Atomic (Postgres transaction semantics). Requires settlements.finalize (+ settlements.process_closed_day for a closed-day source, + settlements.override_batch_fee for a batch fee override). SECURITY DEFINER.';

revoke execute on function public.finalize_settlement_batch(uuid, bigint, jsonb, numeric, text, text) from public;
grant execute on function public.finalize_settlement_batch(uuid, bigint, jsonb, numeric, text, text) to authenticated;

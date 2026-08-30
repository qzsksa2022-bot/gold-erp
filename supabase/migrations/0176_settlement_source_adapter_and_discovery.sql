-- ============================================================================
-- 0176: Phase 7 — Settlements Core (10/N): Settlement Source Adapter +
-- list_unsettled_settlement_sources() + preview_settlement_batch()
-- ============================================================================
-- Migrations 0001-0175 are unmodified.
--
-- item 4 — the unified Settlement Source Adapter over the REAL existing
-- schema (confirmed by direct inspection, not assumed names):
--   A) Sale         -> public.sales_orders (subtotal = amount collected,
--                      payment_fee_amount = fee snapshot, both already
--                      committed at Sale time — Phase 3).
--   B) Return Refund -> public.sales_returns, status='approved'
--                      (sales_revenue_reversal_amount/payment_fee_reversal_
--                      amount, committed at approval — Phase 4/Patch 4.2).
--   C) Return Refund
--      Reversal      -> public.sales_returns, status='reversed' (the
--                      return ITSELF administratively reversed via
--                      reverse_sales_return() — undoes B's settlement
--                      effect; NOT the same concept as
--                      sales_return_refund_event_reversals, which corrects
--                      an ACTUAL cash-refund event, not a settlement
--                      source).
--   D) Approved
--      Adjustment    -> public.sales_order_adjustments, status='approved'
--                      AND participates_in_settlement=true (Phase 6).
--   E) Adjustment
--      Reversal      -> public.sales_order_adjustment_reversals (Phase 6/
--                      Hotfix 6.1.1).
--   F) COD Collection -> public.shipment_cod_events, state='collected'
--                      (Phase 5/0127) — the event itself carries NO money
--                      figure (confirmed — Shipping has no COD-fee
--                      concept); the amount is public.shipments.
--                      cod_expected_amount, the shipment's own fixed value.
--   G) COD Reversal   -> public.shipment_cod_events, state='not_collected'
--                      preceded by an earlier 'collected' event for the
--                      SAME shipment (the ledger has no distinct
--                      "reversal" event type of its own — this is the
--                      documented interpretation of "reversal" within the
--                      existing 4-state ledger).
--
-- item 5 — NO double counting for COD: the Sale source (A) EXCLUDES any
-- sales_order with a linked outbound shipment where is_cod = true (never
-- inferred from a payment method name) — that sale's money movement is
-- represented ENTIRELY by the COD source (F/G) instead.
--
-- ============================================================================
-- SIGN CONVENTION (item 3) — worked out precisely against the governing
-- spec's own numeric examples (section 56/57/58), because several of the
-- underlying source columns carry a DIFFERENT sign convention than
-- Settlements' own gross_collection_impact/provider_fee_impact:
--
--   provider_fee_impact meaning: POSITIVE = a fee that REDUCES the amount
--   expected from the processor/carrier. NEGATIVE = a fee CREDIT/reversal
--   that INCREASES the amount expected. expected = gross - provider_fee.
--
--   A) Sale:              gross = +subtotal.                    fee = +payment_fee_amount.
--   B) Return Refund:      gross = -sales_revenue_reversal_amount.  fee = -payment_fee_reversal_amount.
--      (sales_revenue_reversal_amount/payment_fee_reversal_amount are
--      stored as POSITIVE magnitudes on sales_returns — both are NEGATED
--      here: refund = money owed back (negative gross); a fee being
--      credited back INCREASES expected, i.e. NEGATIVE provider_fee_impact.
--      Verified: gross=-100, fee=-8 -> expected = -100 - (-8) = -92,
--      matching the spec's own worked example exactly.)
--   C) Return Refund
--      Reversal:          gross = +sales_revenue_reversal_amount.  fee = +payment_fee_reversal_amount.
--      (Exact negation of B — undoing the refund restores both to positive.)
--   D) Approved
--      Adjustment:        gross = +customer_charge.               fee = +payment_fee_amount.
--   E) Adjustment
--      Reversal:          gross = customer_charge_reversal_amount (used AS-IS —
--                          already stored NEGATIVE per the Adjustments
--                          module's OWN sign convention, Hotfix 6.1.1/0150:
--                          customer_charge_reversal_amount = -customer_
--                          charge_snapshot).
--                          fee = -payment_fee_reversal_amount (payment_fee_
--                          reversal_amount is stored POSITIVE on this
--                          table per the SAME 0150 convention -- a fee
--                          being credited back must be NEGATED to become
--                          Settlements'' provider_fee_impact, exactly
--                          mirroring B above. Verified: gross=-100,
--                          fee=-2.50 -> expected = -100-(-2.50) = -97.50,
--                          matching the spec''s own worked example exactly
--                          -- this is the single most error-prone
--                          translation in this migration, hence documented
--                          this explicitly.)
--   F) COD Collection:    gross = +cod_expected_amount.  fee = per route fee
--                          version (route_formula) or 0 (none) -- COD has
--                          NO source-level fee snapshot to reuse, so
--                          source_snapshot is never valid for a cod_carrier
--                          route (rejected explicitly at Finalization).
--   G) COD Reversal:      gross = -cod_expected_amount.  fee = -(F's fee) if
--                          cod_fee_reversal_policy IN ('full','proportional'),
--                          else 0 if 'none'. (No partial-COD concept exists
--                          at shipment granularity in the current Shipping
--                          schema, so 'full'/'proportional' are treated
--                          identically here -- documented limitation.)
-- ============================================================================
-- item 20 — store scope per source kind (never widened by the route
-- itself): Sales/Returns -> original Sale's store (sales_orders.store_id)
-- visible to the actor. Adjustments -> original Sale's store OR the
-- Adjustment's own processing_store_id, either visible (mirrors Phase 6's
-- own "Original Sale Store + Processing Store" contract). COD -> the
-- Canonical Shipment scope, shipments.store_id (processing store),
-- confirmed the sole access-control column used by list_shipments/
-- get_shipment (0126/0129).
--
-- The candidate-resolution logic (route matching, date range, store
-- visibility, no-double-COD-counting) is factored into ONE private helper,
-- public._settlement_unsettled_source_candidates(), shared by BOTH
-- list_unsettled_settlement_sources() (below) and preview_settlement_batch()
-- (further below) — deliberately, so the two can never drift apart on the
-- single most error-prone piece of logic in this migration (the Sign
-- Convention). The helper carries primary_store_id (the SAME store each
-- branch already joins for store_display) so callers can apply a real
-- per-source store filter, rather than the earlier placeholder stub.
-- ---------------------------------------------------------------------------
create or replace function public._settlement_unsettled_source_candidates(
  p_settlement_route_id uuid,
  p_source_date_from date,
  p_source_date_to date,
  p_actor uuid
)
returns table (
  source_kind text,
  source_event_id uuid,
  source_number text,
  source_business_date date,
  primary_store_id uuid,
  store_display text,
  source_label text,
  gross_collection_impact numeric,
  provider_fee_impact numeric,
  expected_settlement_impact numeric
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  with route as (
    select * from public.settlement_routes r where r.id = p_settlement_route_id
  ),
  candidates as (
    -- A) Sale
    select
      'sale'::text as source_kind, so.id as source_event_id, so.order_number as source_number,
      so.sale_date as source_business_date, so.store_id as primary_store_id, s.name_ar as store_display,
      ('بيع ' || so.order_number) as source_label,
      so.subtotal as gross_collection_impact, so.payment_fee_amount as provider_fee_impact,
      (so.subtotal - so.payment_fee_amount) as expected_settlement_impact
    from route r
    join public.sales_orders so on true
    join public.stores s on s.id = so.store_id
    where r.route_kind = 'payment_collection'
      and so.payment_method_id = r.payment_method_id
      and (r.collection_channel_id is null or so.collection_channel_id = r.collection_channel_id)
      and so.sale_date between p_source_date_from and p_source_date_to
      and not exists (select 1 from public.shipments sh where sh.sales_order_id = so.id and sh.direction = 'outbound' and sh.is_cod = true)
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = so.store_id)

    union all
    -- B) Return Refund
    select
      'return_refund', sr.id, sr.return_number, sr.return_date, so.store_id, s.name_ar,
      ('استرداد ' || sr.return_number),
      -sr.sales_revenue_reversal_amount, -sr.payment_fee_reversal_amount,
      (-sr.sales_revenue_reversal_amount) - (-sr.payment_fee_reversal_amount)
    from route r
    join public.sales_returns sr on true
    join public.sales_orders so on so.id = sr.sales_order_id
    join public.stores s on s.id = so.store_id
    where r.route_kind = 'payment_collection'
      and sr.status = 'approved'
      and sr.payment_method_id = r.payment_method_id
      and r.collection_channel_id is null
      and sr.return_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = so.store_id)

    union all
    -- C) Return Refund Reversal
    select
      'return_refund_reversal', sr.id, sr.return_number, coalesce(sr.reversal_business_date, sr.return_date), so.store_id, s.name_ar,
      ('عكس استرداد ' || sr.return_number),
      sr.sales_revenue_reversal_amount, sr.payment_fee_reversal_amount,
      sr.sales_revenue_reversal_amount - sr.payment_fee_reversal_amount
    from route r
    join public.sales_returns sr on true
    join public.sales_orders so on so.id = sr.sales_order_id
    join public.stores s on s.id = so.store_id
    where r.route_kind = 'payment_collection'
      and sr.status = 'reversed'
      and sr.payment_method_id = r.payment_method_id
      and r.collection_channel_id is null
      and coalesce(sr.reversal_business_date, sr.return_date) between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = so.store_id)

    union all
    -- D) Approved Adjustment
    select
      'adjustment_approved', a.id, a.adjustment_number, a.adjustment_date, a.processing_store_id, s.name_ar,
      ('تعديل/خدمة ' || a.adjustment_number),
      a.customer_charge, a.payment_fee_amount, a.customer_charge - a.payment_fee_amount
    from route r
    join public.sales_order_adjustments a on true
    join public.sales_orders so on so.id = a.sales_order_id
    join public.stores s on s.id = a.processing_store_id
    where r.route_kind = 'payment_collection'
      and a.status = 'approved'
      and a.participates_in_settlement = true
      and a.payment_method_id = r.payment_method_id
      and (r.collection_channel_id is null or a.collection_channel_id = r.collection_channel_id)
      and a.adjustment_date between p_source_date_from and p_source_date_to
      and (
        exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = so.store_id)
        or exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = a.processing_store_id)
      )

    union all
    -- E) Adjustment Reversal
    select
      'adjustment_reversal', ar.id, a.adjustment_number, ar.reversal_business_date, a.processing_store_id, s.name_ar,
      ('عكس تعديل/خدمة ' || a.adjustment_number),
      ar.customer_charge_reversal_amount, -ar.payment_fee_reversal_amount,
      ar.customer_charge_reversal_amount - (-ar.payment_fee_reversal_amount)
    from route r
    join public.sales_order_adjustment_reversals ar on true
    join public.sales_order_adjustments a on a.id = ar.sales_order_adjustment_id
    join public.sales_orders so on so.id = a.sales_order_id
    join public.stores s on s.id = a.processing_store_id
    where r.route_kind = 'payment_collection'
      and a.participates_in_settlement = true
      and a.payment_method_id = r.payment_method_id
      and (r.collection_channel_id is null or a.collection_channel_id = r.collection_channel_id)
      and ar.reversal_business_date between p_source_date_from and p_source_date_to
      and (
        exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = so.store_id)
        or exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = a.processing_store_id)
      )

    union all
    -- F) COD Collection
    select
      'cod_collection', e.id, sh.shipment_number, e.business_date, sh.store_id, s.name_ar,
      ('تحصيل COD ' || sh.shipment_number),
      sh.cod_expected_amount, 0::numeric, sh.cod_expected_amount
    from route r
    join public.shipment_cod_events e on true
    join public.shipments sh on sh.id = e.shipment_id
    join public.stores s on s.id = sh.store_id
    where r.route_kind = 'cod_carrier'
      and sh.is_cod = true
      and e.state = 'collected'
      and sh.carrier_id = r.shipping_carrier_id
      and e.business_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sh.store_id)

    union all
    -- G) COD Reversal — a 'not_collected' event for a shipment that had an
    -- earlier 'collected' event.
    select
      'cod_reversal', e.id, sh.shipment_number, e.business_date, sh.store_id, s.name_ar,
      ('عكس تحصيل COD ' || sh.shipment_number),
      -sh.cod_expected_amount, 0::numeric, -sh.cod_expected_amount
    from route r
    join public.shipment_cod_events e on true
    join public.shipments sh on sh.id = e.shipment_id
    join public.stores s on s.id = sh.store_id
    where r.route_kind = 'cod_carrier'
      and sh.is_cod = true
      and e.state = 'not_collected'
      and sh.carrier_id = r.shipping_carrier_id
      and e.business_date between p_source_date_from and p_source_date_to
      and exists (
        select 1 from public.shipment_cod_events prior
        where prior.shipment_id = e.shipment_id and prior.state = 'collected' and prior.created_at < e.created_at
      )
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sh.store_id)
  )
  select * from candidates;
$$;

comment on function public._settlement_unsettled_source_candidates(uuid, date, date, uuid) is
  'Phase 7 (item 4/5/20) — PRIVATE shared candidate resolver behind list_unsettled_settlement_sources()/preview_settlement_batch(). Route existence is NOT validated here (an unknown route id simply yields zero rows via the `route` CTE); callers validate it themselves. Not granted to authenticated — internal only.';

revoke execute on function public._settlement_unsettled_source_candidates(uuid, date, date, uuid) from public;

-- ---------------------------------------------------------------------------
create or replace function public.list_unsettled_settlement_sources(
  p_settlement_route_id uuid,
  p_source_date_from date,
  p_source_date_to date,
  p_store_id uuid default null,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  source_kind text,
  source_event_id uuid,
  source_number text,
  source_business_date date,
  store_display text,
  source_label text,
  gross_collection_impact text,
  provider_fee_impact text,
  expected_settlement_impact text
)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_route record;
begin
  if v_actor is null or not public.has_permission('settlements.create') then
    raise exception 'ليست لديك صلاحية إنشاء تسوية' using errcode = 'P0001';
  end if;
  if p_source_date_from is null or p_source_date_to is null then
    raise exception 'نطاق تاريخ المصادر مطلوب' using errcode = 'P0001';
  end if;

  select * into v_route from public.settlement_routes where id = p_settlement_route_id;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;

  return query
  select
    c.source_kind, c.source_event_id, c.source_number, c.source_business_date, c.store_display, c.source_label,
    c.gross_collection_impact::text, c.provider_fee_impact::text, c.expected_settlement_impact::text
  from public._settlement_unsettled_source_candidates(p_settlement_route_id, p_source_date_from, p_source_date_to, v_actor) c
  where (p_store_id is null or c.primary_store_id = p_store_id)
    and not exists (
      select 1 from public.settlement_source_claims cl
      where cl.released_at is null and cl.source_kind = c.source_kind and cl.source_event_id = c.source_event_id
    )
    and (p_search is null or btrim(p_search) = '' or c.source_number ilike '%' || btrim(p_search) || '%')
  order by c.source_business_date, c.source_number
  limit greatest(coalesce(p_limit, 50), 1)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

comment on function public.list_unsettled_settlement_sources(uuid, date, date, uuid, text, integer, integer) is
  'Phase 7 (item 19) — Settlement Source Discovery. Returns ONLY settlement-relevant figures (gross/fee/expected as TEXT) -- never gold cost, manufacturing, VAT cost, product gross profit, sales net profit, adjustment direct cost, or shipping P/L. Excludes sources already actively claimed by another batch (item 25). p_store_id filters candidates by their real resolved store (item 20). Requires settlements.create.';

revoke execute on function public.list_unsettled_settlement_sources(uuid, date, date, uuid, text, integer, integer) from public;
grant execute on function public.list_unsettled_settlement_sources(uuid, date, date, uuid, text, integer, integer) to authenticated;

-- ============================================================================
-- preview_settlement_batch() — item 22: "Preview للعرض فقط. Finalization
-- تعيد حل كل شيء DB-side." A DISPLAY-ONLY projection over a caller-selected
-- subset of the SAME candidate rows list_unsettled_settlement_sources()
-- would show (re-resolved from DB here too, never trusting client-supplied
-- amounts — only the client-supplied SELECTION of which source_kind/
-- source_event_id tokens to include is trusted). Returns the matched line
-- breakdown (as JSONB, since this is a single-row summary function) plus
-- gross/fee/batch-fee/expected totals. NOT authoritative: finalize_
-- settlement_batch() (0178) independently re-resolves every source, the
-- fee version, and the batch fee from DB state at Finalization time and can
-- legitimately produce different figures if anything changed since preview.
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

  select * into v_route from public.settlement_routes where id = p_settlement_route_id;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;

  v_effective_date := coalesce(p_settlement_date, public.business_today());

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'source_kind', c.source_kind,
      'source_event_id', c.source_event_id,
      'source_number', c.source_number,
      'source_business_date', c.source_business_date,
      'store_display', c.store_display,
      'source_label', c.source_label,
      'gross_collection_impact', c.gross_collection_impact::text,
      'provider_fee_impact', c.provider_fee_impact::text,
      'expected_settlement_impact', c.expected_settlement_impact::text
    ) order by c.source_business_date, c.source_number), '[]'::jsonb),
    coalesce(sum(c.gross_collection_impact), 0),
    coalesce(sum(c.provider_fee_impact), 0)
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

  select * into v_fee from public.settlement_route_fee_for_route_on_date(p_settlement_route_id, v_effective_date);

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
  'Phase 7 (item 22) — DISPLAY-ONLY preview of a prospective batch over a caller-selected subset of unsettled sources. Re-resolves every selected source and the route''s fee version from DB (never trusts client-supplied amounts), but is NOT authoritative — finalize_settlement_batch() independently re-resolves everything at Finalization and is the sole source of truth. p_selected_sources is a JSONB array of {"source_kind","source_event_id"} tokens. Requires settlements.create.';

revoke execute on function public.preview_settlement_batch(uuid, date, date, jsonb, date) from public;
grant execute on function public.preview_settlement_batch(uuid, date, date, jsonb, date) to authenticated;

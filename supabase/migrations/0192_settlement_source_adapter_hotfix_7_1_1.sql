-- ============================================================================
-- 0192: Phase 7 — Final Integrity Hotfix 7.1.1 (1/N): historical Return
-- Fee-Reversal timeline (§1), original Sale route/channel for Fee-Reversal
-- (§3), Source Discovery store filter primary-OR-secondary (§15), NULL
-- collection_channel_id semantics documentation (§8).
-- ============================================================================
-- Migrations 0001-0191 are FROZEN and byte-for-byte unmodified (Hotfix
-- 7.1.1 §0). All new work starts at 0192.
--
-- ============================================================================
-- §1 (CRITICAL) — Return Fee-Reversal must be a HISTORICAL EVENT, not a
-- current-state view.
-- ============================================================================
-- The bug fixed here: 0184's return_fee_reversal candidate required
-- sr.status = 'approved', and return_fee_reversal_reversal required
-- sr.status = 'reversed' — mutually exclusive on the SAME current-state
-- column, so the ORIGINAL fee credit silently vanished from the discovery/
-- claim timeline the instant an administrative reverse_sales_return()
-- flipped status to 'reversed', even if that original credit had never been
-- settled. The fee credit became a real financial fact at APPROVAL time
-- (compute_sales_return_fee_reversal_v2(), 0109) and must remain visible
-- (and claimable, until actually claimed) regardless of what happens to the
-- return administratively afterward — Settlement Claims (0173), not
-- sales_returns.status, are what already correctly determine "unsettled":
-- source_kind='return_fee_reversal' and source_kind='return_fee_reversal_
-- reversal' are two DIFFERENT source_kind values keyed on the SAME sr.id, so
-- claiming one never affects the other's own independent claim state.
--
-- Fix:
--   'return_fee_reversal' now fires whenever sr.approved_at is not null
--       (the return WAS approved at some point in its history — true for
--       both 'approved' and 'reversed' status, false only for 'pending'/
--       'rejected', which never had a fee credit at all) AND the fee amount
--       is a real nonzero figure. Still dated at the real, permanent
--       approved_at (never re-derived, never touched by a later reversal).
--   'return_fee_reversal_reversal' now fires independently whenever
--       sr.reversal_business_date is not null (a real, permanent column
--       ONLY ever set by reverse_sales_return()'s own administrative-
--       reversal path, 0092/0096/0102 — never null while approved-only,
--       never re-cleared afterward) AND the fee amount is nonzero. Still
--       dated at the real reversal_business_date.
-- Both conditions are now independent of sr.status and independent of each
-- other — a return that was approved then reversed produces BOTH sources
-- (net settlement impact = 0 if neither is yet claimed), exactly the
-- Approval-then-Reversal-before-Settlement scenario the spec requires. If
-- the original was already claimed before the reversal happened, only the
-- reversal source appears (claim filtering, unchanged, already does this
-- correctly via settlement_source_claims — no change needed there). If the
-- batch holding that original claim is later cancelled (releasing the
-- claim), the original reappears in discovery again, since this candidate
-- resolver is a live, unconditional recomputation over sr.approved_at/
-- payment_fee_reversal_amount/reversal_business_date — never any cached or
-- status-derived state.
--
-- ============================================================================
-- §3 (CRITICAL) — Return Fee-Reversal route must use the ORIGINAL SALE'S
-- collection channel, not a hardcoded NULL.
-- ============================================================================
-- The bug fixed here: 0184's return_fee_reversal/_reversal candidates
-- matched via `sr.payment_method_id = r.payment_method_id AND r.collection_
-- channel_id is null` — forcing every fee-reversal source to require a
-- route with NO channel configured, regardless of what channel the
-- original sale actually collected on. The fee being credited back was
-- originally charged on the original Sale's OWN payment_method_id +
-- collection_channel_id (sales_orders, both NOT NULL, 0059) — sr.payment_
-- method_id is already a same-value snapshot of the original sale's method,
-- but sales_returns carries no channel column of its own at all, so this
-- was silently impossible to route-match correctly before now.
--
-- Fix: both candidates now JOIN sales_orders via sr.sales_order_id and
-- match on so.payment_method_id + `r.collection_channel_id is not distinct
-- from so.collection_channel_id` (the same exact-match discipline §4 of
-- Patch 7.1/migration 0184 already established elsewhere) — the ORIGINAL
-- SALE'S route, never the Refund Event's own refund_method_id (that is a
-- DIFFERENT, independent source — return_refund_event/_reversal — which
-- correctly keeps using the refund event's own method + implicit NULL
-- channel, unchanged by this migration; a refund ledger row carries no
-- channel column, so it can only ever match a NULL-channel route, exactly
-- as before).
-- ============================================================================
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
  expected_settlement_impact numeric,
  fee_lookup_date date,
  secondary_store_id uuid,
  secondary_store_display text
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  with route as (
    select * from public.settlement_routes r where r.id = p_settlement_route_id
  ),
  cod_timeline as (
    select
      e.id, e.shipment_id, e.state, e.business_date, e.created_at,
      lag(e.state) over (partition by e.shipment_id order by e.business_date, e.created_at, e.id) as prev_state,
      lag(e.id) over (partition by e.shipment_id order by e.business_date, e.created_at, e.id) as prev_id,
      lag(e.business_date) over (partition by e.shipment_id order by e.business_date, e.created_at, e.id) as prev_business_date
    from public.shipment_cod_events e
  ),
  candidates as (
    -- A) Sale
    select
      'sale'::text as source_kind, so.id as source_event_id, so.order_number as source_number,
      so.sale_date as source_business_date, so.store_id as primary_store_id, s.name_ar as store_display,
      ('بيع ' || so.order_number) as source_label,
      so.subtotal as gross_collection_impact, so.payment_fee_amount as provider_fee_impact,
      (so.subtotal - so.payment_fee_amount) as expected_settlement_impact,
      so.sale_date as fee_lookup_date, null::uuid as secondary_store_id, null::text as secondary_store_display
    from route r
    join public.sales_orders so on true
    join public.stores s on s.id = so.store_id
    where r.route_kind = 'payment_collection'
      and so.payment_method_id = r.payment_method_id
      and r.collection_channel_id is not distinct from so.collection_channel_id
      and so.sale_date between p_source_date_from and p_source_date_to
      and not exists (select 1 from public.shipments sh where sh.sales_order_id = so.id and sh.direction = 'outbound' and sh.is_cod = true)
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = so.store_id)

    union all
    -- B) Return Refund Event — §1 (unchanged from 0184): the ACTUAL cash
    -- refund ledger, never gated by sales_returns.status.
    select
      'return_refund_event', e.id, sr.return_number, e.refund_business_date, sr.processed_store_id, s.name_ar,
      ('استرداد فعلي ' || sr.return_number),
      -e.amount, 0::numeric, -e.amount,
      e.refund_business_date, null::uuid, null::text
    from route r
    join public.sales_return_refund_events e on true
    join public.sales_returns sr on sr.id = e.sales_return_id
    join public.stores s on s.id = sr.processed_store_id
    where r.route_kind = 'payment_collection'
      and e.refund_method_id = r.payment_method_id
      and r.collection_channel_id is null
      and e.refund_business_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sr.processed_store_id)

    union all
    -- C) Return Refund Event Reversal — §1 (unchanged from 0184).
    select
      'return_refund_event_reversal', rev.id, sr.return_number, rev.reversal_business_date, sr.processed_store_id, s.name_ar,
      ('عكس استرداد فعلي ' || sr.return_number),
      e.amount, 0::numeric, e.amount,
      rev.reversal_business_date, null::uuid, null::text
    from route r
    join public.sales_return_refund_event_reversals rev on true
    join public.sales_return_refund_events e on e.id = rev.refund_event_id
    join public.sales_returns sr on sr.id = rev.sales_return_id
    join public.stores s on s.id = sr.processed_store_id
    where r.route_kind = 'payment_collection'
      and e.refund_method_id = r.payment_method_id
      and r.collection_channel_id is null
      and rev.reversal_business_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sr.processed_store_id)

    union all
    -- D) Return Fee Reversal — §1/§3: historical event (approved_at is not
    -- null, independent of current status), routed via the ORIGINAL SALE'S
    -- own payment method + collection channel (join sales_orders, exact
    -- IS NOT DISTINCT FROM channel match).
    select
      'return_fee_reversal', sr.id, sr.return_number, (sr.approved_at at time zone 'Asia/Riyadh')::date, sr.processed_store_id, s.name_ar,
      ('استرداد عمولة ' || sr.return_number),
      0::numeric, -sr.payment_fee_reversal_amount, sr.payment_fee_reversal_amount,
      (sr.approved_at at time zone 'Asia/Riyadh')::date, null::uuid, null::text
    from route r
    join public.sales_returns sr on true
    join public.sales_orders so on so.id = sr.sales_order_id
    join public.stores s on s.id = sr.processed_store_id
    where r.route_kind = 'payment_collection'
      and sr.approved_at is not null
      and sr.payment_fee_reversal_amount is not null and sr.payment_fee_reversal_amount <> 0
      and so.payment_method_id = r.payment_method_id
      and r.collection_channel_id is not distinct from so.collection_channel_id
      and (sr.approved_at at time zone 'Asia/Riyadh')::date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sr.processed_store_id)

    union all
    -- E) Return Fee Reversal Reversal — §1/§3: independent historical event
    -- (reversal_business_date is not null — set ONLY by the administrative
    -- reverse_sales_return() path, never independently of it), SAME
    -- original-sale route as D.
    select
      'return_fee_reversal_reversal', sr.id, sr.return_number, sr.reversal_business_date, sr.processed_store_id, s.name_ar,
      ('عكس استرداد عمولة ' || sr.return_number),
      0::numeric, sr.payment_fee_reversal_amount, -sr.payment_fee_reversal_amount,
      sr.reversal_business_date, null::uuid, null::text
    from route r
    join public.sales_returns sr on true
    join public.sales_orders so on so.id = sr.sales_order_id
    join public.stores s on s.id = sr.processed_store_id
    where r.route_kind = 'payment_collection'
      and sr.reversal_business_date is not null
      and sr.payment_fee_reversal_amount is not null and sr.payment_fee_reversal_amount <> 0
      and so.payment_method_id = r.payment_method_id
      and r.collection_channel_id is not distinct from so.collection_channel_id
      and sr.reversal_business_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sr.processed_store_id)

    union all
    -- F) Approved Adjustment (unchanged from 0184).
    select
      'adjustment_approved', a.id, a.adjustment_number, a.adjustment_date, a.processing_store_id, s.name_ar,
      ('تعديل/خدمة ' || a.adjustment_number),
      a.customer_charge, a.payment_fee_amount, a.customer_charge - a.payment_fee_amount,
      a.adjustment_date,
      case when so.store_id <> a.processing_store_id then so.store_id else null end,
      case when so.store_id <> a.processing_store_id then so2.name_ar else null end
    from route r
    join public.sales_order_adjustments a on true
    join public.sales_orders so on so.id = a.sales_order_id
    join public.stores s on s.id = a.processing_store_id
    left join public.stores so2 on so2.id = so.store_id
    where r.route_kind = 'payment_collection'
      and a.status = 'approved'
      and a.participates_in_settlement = true
      and a.payment_method_id = r.payment_method_id
      and r.collection_channel_id is not distinct from a.collection_channel_id
      and a.adjustment_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = so.store_id)
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = a.processing_store_id)

    union all
    -- G) Adjustment Reversal (unchanged from 0184).
    select
      'adjustment_reversal', ar.id, a.adjustment_number, ar.reversal_business_date, a.processing_store_id, s.name_ar,
      ('عكس تعديل/خدمة ' || a.adjustment_number),
      ar.customer_charge_reversal_amount, -ar.payment_fee_reversal_amount,
      ar.customer_charge_reversal_amount - (-ar.payment_fee_reversal_amount),
      ar.reversal_business_date,
      case when so.store_id <> a.processing_store_id then so.store_id else null end,
      case when so.store_id <> a.processing_store_id then so2.name_ar else null end
    from route r
    join public.sales_order_adjustment_reversals ar on true
    join public.sales_order_adjustments a on a.id = ar.sales_order_adjustment_id
    join public.sales_orders so on so.id = a.sales_order_id
    join public.stores s on s.id = a.processing_store_id
    left join public.stores so2 on so2.id = so.store_id
    where r.route_kind = 'payment_collection'
      and a.participates_in_settlement = true
      and a.payment_method_id = r.payment_method_id
      and r.collection_channel_id is not distinct from a.collection_channel_id
      and ar.reversal_business_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = so.store_id)
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = a.processing_store_id)

    union all
    -- H) COD Collection (unchanged from 0184).
    select
      'cod_collection', ct.id, sh.shipment_number, ct.business_date, sh.store_id, s.name_ar,
      ('تحصيل COD ' || sh.shipment_number),
      sh.cod_expected_amount, 0::numeric, sh.cod_expected_amount,
      ct.business_date, null::uuid, null::text
    from route r
    join cod_timeline ct on true
    join public.shipments sh on sh.id = ct.shipment_id
    join public.stores s on s.id = sh.store_id
    where r.route_kind = 'cod_carrier'
      and sh.is_cod = true
      and sh.cod_expected_amount is not null
      and sh.carrier_id = r.shipping_carrier_id
      and ct.state = 'collected'
      and ct.prev_state is distinct from 'collected'
      and ct.business_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sh.store_id)

    union all
    -- I) COD Reversal (unchanged from 0184).
    select
      'cod_reversal', ct.id, sh.shipment_number, ct.business_date, sh.store_id, s.name_ar,
      ('عكس تحصيل COD ' || sh.shipment_number),
      -sh.cod_expected_amount, 0::numeric, -sh.cod_expected_amount,
      coalesce(ct.prev_business_date, ct.business_date), null::uuid, null::text
    from route r
    join cod_timeline ct on true
    join public.shipments sh on sh.id = ct.shipment_id
    join public.stores s on s.id = sh.store_id
    where r.route_kind = 'cod_carrier'
      and sh.is_cod = true
      and sh.cod_expected_amount is not null
      and sh.carrier_id = r.shipping_carrier_id
      and ct.state = 'not_collected'
      and ct.prev_state = 'collected'
      and ct.business_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sh.store_id)
  )
  select * from candidates;
$$;

comment on function public._settlement_unsettled_source_candidates(uuid, date, date, uuid) is
  'Hotfix 7.1.1 (§1/§3) — supersedes 0184''s body under the SAME name/signature/output columns. return_fee_reversal now fires whenever sr.approved_at is not null (a historical fact, independent of current status); return_fee_reversal_reversal now fires independently whenever sr.reversal_business_date is not null — both keyed to the SAME sr.id under DIFFERENT source_kind values, so they coexist in discovery/claims exactly like any other independent source pair, and claim-release (batch cancellation) correctly makes either reappear on its own. Both are routed via the ORIGINAL SALE''s own payment_method_id + collection_channel_id (join sales_orders, exact IS NOT DISTINCT FROM channel match) — never a hardcoded NULL channel, never the independent cash Refund Event''s own refund_method_id. Not granted to authenticated — internal only.';

revoke execute on function public._settlement_unsettled_source_candidates(uuid, date, date, uuid) from public;

-- ============================================================================
-- §15 — Source Discovery store filter must match PRIMARY OR SECONDARY store,
-- not primary alone. list_unsettled_settlement_sources() (0176, never
-- touched since) filtered `p_store_id is null or c.primary_store_id =
-- p_store_id` — a cross-store Adjustment whose ORIGINAL sale store is what
-- the actor filtered by (but whose PROCESSING store is the resolved
-- primary_store_id) was invisible to that filter even though the actor can
-- see it (visibility, unchanged, already correctly requires BOTH stores
-- visible per Patch 7.1 §5/migration 0184). Same signature/output as 0176 —
-- CREATE OR REPLACE, no new columns.
-- ============================================================================
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
  where (p_store_id is null or c.primary_store_id = p_store_id or c.secondary_store_id = p_store_id)
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
  'Hotfix 7.1.1 (§15) — same signature as 0176. p_store_id now matches a candidate whose PRIMARY OR SECONDARY store equals it (a cross-store Adjustment now surfaces under either store''s filter) — visibility (which stores an actor may see at all) is unchanged, still requires BOTH primary and secondary visible (Patch 7.1 §5, migration 0184). Requires settlements.create.';

revoke execute on function public.list_unsettled_settlement_sources(uuid, date, date, uuid, text, integer, integer) from public;
grant execute on function public.list_unsettled_settlement_sources(uuid, date, date, uuid, text, integer, integer) to authenticated;

-- ============================================================================
-- §8 — documentation only (no behavior change): settlement_routes.collection_
-- channel_id NULL means "matches sources with NO collection channel of
-- their own only" (Return Fee-Reversal/Refund-Event sources, which carry no
-- channel column at all) — it is NEVER a wildcard that matches every
-- channel. This has been the actual DB matching behavior since Patch 7.1
-- (migration 0184's IS NOT DISTINCT FROM predicate); this comment merely
-- documents it at the schema level so a future reader of settlement_routes
-- (0168, frozen) does not have to reconstruct the semantics from RPC bodies
-- alone. The corresponding UI copy fix ("بدون قناة تحصيل" instead of "كل
-- القنوات") ships in this same Hotfix, in settlement-route-form-dialog.tsx
-- and master-data/settlement-routes/page.tsx — application code, not a
-- migration.
-- ============================================================================
comment on column public.settlement_routes.collection_channel_id is
  'Hotfix 7.1.1 (§8) — NULL means this route matches ONLY sources carrying NO collection channel of their own (Return Fee-Reversal/Refund-Event sources — sales_return_refund_events/sales_returns have no channel column at all). It is NEVER a wildcard matching every channel: a Sale/Adjustment always carries a real, non-null collection_channel_id (sales_orders.collection_channel_id/sales_order_adjustments.collection_channel_id are both NOT NULL), so a NULL-channel route can never match either. Matching everywhere in this module uses exact `IS NOT DISTINCT FROM` semantics (Patch 7.1 §4, migration 0184) — never `channel IS NULL OR channel = route.channel`.';

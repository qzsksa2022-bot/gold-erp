-- ============================================================================
-- 0198: Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2 (2/2):
-- Return Fee-Reversal route matching now uses sales_returns' OWN basis
-- snapshot columns (0197), never a live sales_orders join
-- ============================================================================
-- Migrations 0001-0197 are UNCHANGED (byte-for-byte). CREATE OR REPLACE of
-- _settlement_unsettled_source_candidates() under the EXACT SAME name/
-- signature/output columns as 0192 — every candidate branch other than D
-- (return_fee_reversal) and E (return_fee_reversal_reversal) is BYTE-FOR-
-- BYTE identical to 0192's body.
--
-- REVISION (Hotfix 7.1.3): this file's comments were corrected in place
-- (0198 had not yet been accepted into the frozen baseline). The matching
-- LOGIC below is UNCHANGED — it already read exclusively from sales_
-- returns' own two columns, which is and remains correct. What was wrong
-- was the ORIGINAL comment's claim that those two columns are "permanently
-- frozen at Return-creation time" — sales_returns.payment_method_id never
-- was that (it is re-synced, while a Return is still pending, by the
-- pre-existing, sanctioned refresh_pending_sales_return_from_sale(),
-- 0100), and collection_channel_id_snapshot (0197) is deliberately built
-- to move in LOCKSTEP with it through that same sanctioned path — see
-- 0197's Part E for the corrected mechanism. Both freeze only once the
-- Return leaves the pending lifecycle (approved/rejected/reversed), not at
-- creation.
--
-- The fix (§7 of the Hotfix 7.1.2 spec, semantics corrected by 7.1.3):
-- candidates D/E no longer join sales_orders at all. Route matching for
-- both now reads exclusively from sales_returns' own two Sale-derived-
-- basis snapshot columns:
--   r.payment_method_id      = sr.payment_method_id                (0082/0100, pre-existing)
--   r.collection_channel_id IS NOT DISTINCT FROM sr.collection_channel_id_snapshot  (0197)
-- Both track the SAME Sale-state basis, always moving together (0197's
-- guard trigger keeps them coherent), and both freeze together once the
-- Return leaves the pending lifecycle — so a LATER edit to the original
-- Sale's payment method or collection channel (permitted once the Return
-- is reversed, 0084) can never again retroactively change which
-- settlement route an already-decided Return's fee-reversal events
-- resolve to, while a Sale edit legitimately absorbed via a sanctioned
-- pending refresh correctly DOES move both together, before that point.
--
-- Everything else from Hotfix 7.1.1 (0192) is preserved exactly: return_
-- fee_reversal still fires whenever sr.approved_at is not null (a
-- permanent historical fact, independent of current status);
-- return_fee_reversal_reversal still fires independently whenever sr.
-- reversal_business_date is not null; both still coexist under different
-- source_kind values keyed to the same sr.id; return_refund_event/
-- _reversal (the actual cash refund ledger) are completely untouched —
-- still refund_method_id + implicit NULL channel, never sales_returns'
-- snapshot columns at all (spec §8, unchanged contract).
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
    -- A) Sale (unchanged from 0192/0184).
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
    -- B) Return Refund Event — §1 (unchanged since 0184): the ACTUAL cash
    -- refund ledger, never gated by sales_returns.status, never routed via
    -- any sales_returns snapshot column — refund_method_id + implicit NULL
    -- channel only (Hotfix 7.1.2 §8 — this contract is NOT changed here).
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
    -- C) Return Refund Event Reversal — §1 (unchanged since 0184).
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
    -- D) Return Fee Reversal — Hotfix 7.1.2 §1/§2/§7 (supersedes 0192's
    -- candidate D): historical event (sr.approved_at is not null,
    -- independent of current status, unchanged from 0192), routed via the
    -- RETURN'S OWN basis snapshot columns — no sales_orders join at all.
    -- sr.approved_at is not null here means the Return has already left
    -- the pending lifecycle, so both snapshot columns are already frozen
    -- (0197's guard trigger) by the time this candidate can ever match —
    -- a later edit to the Sale can never move this event to a different
    -- route.
    select
      'return_fee_reversal', sr.id, sr.return_number, (sr.approved_at at time zone 'Asia/Riyadh')::date, sr.processed_store_id, s.name_ar,
      ('استرداد عمولة ' || sr.return_number),
      0::numeric, -sr.payment_fee_reversal_amount, sr.payment_fee_reversal_amount,
      (sr.approved_at at time zone 'Asia/Riyadh')::date, null::uuid, null::text
    from route r
    join public.sales_returns sr on true
    join public.stores s on s.id = sr.processed_store_id
    where r.route_kind = 'payment_collection'
      and sr.approved_at is not null
      and sr.payment_fee_reversal_amount is not null and sr.payment_fee_reversal_amount <> 0
      and sr.payment_method_id = r.payment_method_id
      and r.collection_channel_id is not distinct from sr.collection_channel_id_snapshot
      and (sr.approved_at at time zone 'Asia/Riyadh')::date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sr.processed_store_id)

    union all
    -- E) Return Fee Reversal Reversal — Hotfix 7.1.2 §1/§2/§7 (supersedes
    -- 0192's candidate E): independent historical event (sr.reversal_
    -- business_date is not null, unchanged from 0192; implies approved_at
    -- is also not null, 0084/0102), SAME already-frozen snapshot-based
    -- route as D — never the Sale's live route.
    select
      'return_fee_reversal_reversal', sr.id, sr.return_number, sr.reversal_business_date, sr.processed_store_id, s.name_ar,
      ('عكس استرداد عمولة ' || sr.return_number),
      0::numeric, sr.payment_fee_reversal_amount, -sr.payment_fee_reversal_amount,
      sr.reversal_business_date, null::uuid, null::text
    from route r
    join public.sales_returns sr on true
    join public.stores s on s.id = sr.processed_store_id
    where r.route_kind = 'payment_collection'
      and sr.reversal_business_date is not null
      and sr.payment_fee_reversal_amount is not null and sr.payment_fee_reversal_amount <> 0
      and sr.payment_method_id = r.payment_method_id
      and r.collection_channel_id is not distinct from sr.collection_channel_id_snapshot
      and sr.reversal_business_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sr.processed_store_id)

    union all
    -- F) Approved Adjustment (unchanged from 0192/0184).
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
    -- G) Adjustment Reversal (unchanged from 0192/0184).
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
    -- H) COD Collection (unchanged from 0192/0184).
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
    -- I) COD Reversal (unchanged from 0192/0184).
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
  'Hotfix 7.1.2/7.1.3 (§1/§2/§7) — supersedes 0192''s body under the SAME name/signature/output columns. return_fee_reversal/_reversal route via sales_returns'' OWN Sale-derived-basis snapshot columns (payment_method_id, pre-existing 0082/0100, re-synced only by the sanctioned refresh_pending_sales_return_from_sale() while pending; collection_channel_id_snapshot, 0197, kept in lockstep with it through that same sanctioned path) instead of a live join to sales_orders — both freeze together once the Return leaves the pending lifecycle (approved/rejected/reversed), so a later edit to the original Sale''s payment method/collection channel (permitted once the Return is reversed, 0084) can never again retroactively move an already-decided Return''s fee-reversal events to a different settlement route. Historical-event gating (approved_at/reversal_business_date IS NOT NULL) unchanged from 0192 — both candidates only ever match a Return that has already left the pending lifecycle, i.e. after its basis snapshot columns are already frozen. return_refund_event/_reversal (the actual cash refund ledger) remain completely untouched — refund_method_id + implicit NULL channel only, never a sales_returns snapshot column. Not granted to authenticated — internal only.';

revoke execute on function public._settlement_unsettled_source_candidates(uuid, date, date, uuid) from public;

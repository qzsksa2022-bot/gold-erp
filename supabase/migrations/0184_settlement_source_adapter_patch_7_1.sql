-- ============================================================================
-- 0184: Phase 7 — Integrity Patch 7.1 (1/N): Settlement Source Adapter
-- rebuild — actual cash refund ledger, fee-reversal as an independent
-- source, exact route/channel matching, AND-based cross-store visibility,
-- COD state-transition detection.
-- ============================================================================
-- Migrations 0001-0183 are FROZEN and byte-for-byte unmodified (Patch 7.1
-- §0). This migration supersedes public._settlement_unsettled_source_
-- candidates() (0176) with a corrected implementation under the SAME name.
-- Its signature (input args) is unchanged, but its OUTPUT ROW SHAPE gains
-- new columns (fee_lookup_date, secondary_store_id, secondary_store_
-- display) that finalize_settlement_batch() (0178) needs to stop
-- re-deriving COD fee-pairing and cross-store secondary-store lookups
-- itself (the single most error-prone duplication this module has —
-- eliminating it, not just moving it, is the point of this migration).
-- Postgres does not allow CREATE OR REPLACE to change a function's OUTPUT
-- columns, so this is a DROP + CREATE — safe here because this helper is
-- PRIVATE (revoke ... from public in 0176, "internal only" per its own
-- comment, never granted to authenticated, called only from
-- list_unsettled_settlement_sources()/preview_settlement_batch() (0176,
-- both read its columns BY NAME and need no edits — see below) and
-- finalize_settlement_batch() (0178, superseded separately in 0185, which
-- DOES need the new columns).
--
-- ============================================================================
-- §1 (CRITICAL) — Returns Settlement Source must use the Actual Cash
-- Refund Ledger, not sales_returns.status.
-- ============================================================================
-- The bug fixed here: 0176's return_refund/return_refund_reversal
-- candidates were built from sales_returns.status ('approved'/'reversed')
-- using sales_revenue_reversal_amount/payment_fee_reversal_amount — a
-- TARGET the Returns module itself documents as distinct from what cash
-- actually moved (record_sales_return_refund()/sales_return_refund_events,
-- 0089/0106/0107). Actual cash may be less/more than the target, may be
-- split across several dated events on different payment methods, and the
-- events may not even exist yet when a return is approved. Worse: 0176's
-- return_refund_reversal candidate fired on sales_returns.status='reversed'
-- alone — meaning reverse_sales_return() (the ADMINISTRATIVE undo of an
-- approval, 0088/0096/0102), which never touches sales_return_refund_events
-- at all (confirmed: it only flips sales_returns.status/sales_return_items.
-- is_effective — see 0102's body), could fabricate a positive Settlement
-- Cash source for money that was never actually refunded in the first
-- place, exactly the failure Patch 7.1 §1 names explicitly.
--
-- Fix: gross cash sourcing now comes EXCLUSIVELY from the two real
-- append-only ledgers (0106/0107):
--   'return_refund_event'          <- public.sales_return_refund_events
--       one row per ACTUAL refund event, unconditionally (never gated by
--       the parent sales_returns.status — an actual cash refund already
--       happened and must be settled regardless of what later happens
--       administratively to the return header). gross = -e.amount (money
--       paid out). fee = 0 here (the transaction fee reversal is NOT
--       1:1 with a refund event — see §2 below, its own independent
--       source). source_business_date = e.refund_business_date (the
--       event's OWN date, per Patch 7.1 §1 — never the return's own
--       return_date/approved_at). Route match uses e.refund_method_id
--       (the event's OWN actual method — per §1/§3-E, deliberately NOT
--       sr.payment_method_id, which is the ORIGINAL sale's method and may
--       differ).
--   'return_refund_event_reversal' <- public.sales_return_refund_event_
--       reversals (0106) — the ONLY legitimate way an actual refund gets
--       undone (reverse_sales_return_refund_event(), 0107 — a real
--       correction to a specific cash event, never the administrative
--       reverse_sales_return()). gross = +e.amount (restores the
--       original event's own amount — §3-C: reversing ONE of several
--       split events restores only THAT event's amount, never the return's
--       full target). Route match STILL uses the ORIGINAL event's
--       e.refund_method_id (the reversal row itself carries no method —
--       §3-E's "Method B" requirement). source_business_date =
--       rev.reversal_business_date (the reversal's OWN date — a real,
--       validated column, 0092/0097).
-- Store scope (both): sr.processed_store_id — the Returns module's own
-- canonical access-control anchor for a refund event (confirmed:
-- record_sales_return_refund()/reverse_sales_return_refund_event(), 0107,
-- check user_visible_store_ids() against v_return.processed_store_id, NOT
-- the original sale's store_id) — corrected from 0176's so.store_id, which
-- was inconsistent with the Returns module's own contract. Patch 7.1 did
-- not ask for a NEW cross-store (Original+Processing, AND) policy for
-- Returns the way it did for Adjustments (§5) — sales_return_refund_events
-- has no "original store vs processing store" duality of its own; this is
-- a single-store correction, not a new privacy model.
--
-- ============================================================================
-- §2 — Return Fee-Reversal: an INDEPENDENT deterministic source, no
-- invented per-event allocation.
-- ============================================================================
-- Investigated (Patch 7.1 §2 requirement): sales_returns.payment_fee_
-- reversal_amount is computed ONCE, at approval time, on the CUMULATIVE
-- approved_refund_amount basis across the whole order (compute_sales_
-- return_fee_reversal_v2(), 0109) — an aggregate belonging to the RETURN
-- header, with NO table anywhere linking it to a specific sales_return_
-- refund_events row. There is no canonical one-to-one (or any-to-one)
-- mapping to actual refund events for this project to consume — inventing
-- a proportional split (by event count, by amount ratio, etc.) across
-- refund events would be exactly the fabrication Patch 7.1 §2 forbids.
--
-- Design (documented per §2's own instruction to "apply the safest
-- contract after inspecting the Returns source" when no such mapping
-- exists): represent it as its OWN settlement source, tied to the Return's
-- financial snapshot (sales_returns row itself, not any refund event),
-- keyed by sr.id (source_event_id) with its own source_kind — never
-- conflated with the cash sources above.
--   'return_fee_reversal'          — appears while sr.status = 'approved'
--       AND payment_fee_reversal_amount is a real nonzero figure. This is
--       the fee CREDIT recognized at approval (gross=0, fee=
--       -payment_fee_reversal_amount => expected = +payment_fee_reversal_
--       amount, the same "fee credit increases expected" sign convention
--       0176 already established for every other reversal-shaped source).
--       Dated at (sr.approved_at at time zone 'Asia/Riyadh')::date — a
--       REAL, existing, already-committed domain date (the instant this
--       fee credit became a financial fact per approve_sales_return(),
--       0109), never invented/guessed. Route match uses sr.payment_
--       method_id (the ORIGINAL sale's method — the fee being credited
--       back was originally charged on THAT method/processor, not
--       whatever method a later, independent cash refund event happens to
--       use — a deliberate, documented judgment call).
--   'return_fee_reversal_reversal'  — appears while sr.status = 'reversed'
--       (the SAME administrative reverse_sales_return() action), undoing
--       ONLY the fee-credit source above (gross=0, fee=
--       +payment_fee_reversal_amount => expected = -payment_fee_reversal_
--       amount). Dated at sr.reversal_business_date — a real, existing,
--       independently-validated column (0092/0096/0102: must be >=
--       approval date, >= return_date, never in the future). This mirrors
--       0176's OLD return_refund_reversal candidate's status-driven shape,
--       but now scoped correctly to ONLY the fee-credit figure — never the
--       cash figure, which §1 above established must never come from
--       administrative status at all.
-- Both gated on payment_fee_reversal_amount is not null and <> 0 (a
-- non_refundable_fee-policy return, or one whose reversal was fully
-- absorbed by an earlier return on the same order, contributes nothing —
-- correctly no source at all, never a spurious zero-value row).
--
-- ============================================================================
-- §4 (CRITICAL) — exact route/channel matching, no NULL-as-wildcard.
-- ============================================================================
-- Every payment_collection branch below now uses
-- `r.collection_channel_id is not distinct from <source>.collection_channel_id`
-- instead of `(r.collection_channel_id is null or <source>.collection_
-- channel_id = r.collection_channel_id)`. sales_orders.collection_channel_id
-- and sales_order_adjustments.collection_channel_id are BOTH `not null`
-- (confirmed: 0059:106, 0135:71) — so a route with collection_channel_id
-- IS NULL can now never match a Sale/Adjustment (which always carries a
-- real channel); a route with a specific channel matches ONLY that exact
-- channel. sales_return_refund_events/sales_returns carry no channel
-- column at all — their "source channel" is implicitly NULL, so per this
-- same IS NOT DISTINCT FROM contract they match Method+NULL-channel routes
-- only (exactly Patch 7.1 §4's own worked example: "Refund Events without
-- a collection channel -> match Method+NULL routes only").
--
-- ============================================================================
-- §5 (CRITICAL) — cross-store Adjustment visibility: AND, not OR.
-- ============================================================================
-- 0176 required EITHER the original Sale's store OR the Adjustment's own
-- processing_store_id to be visible — meaning an actor who can see only
-- ONE of the two stores could see (and settle) a cross-store Adjustment
-- whose OTHER store's business is entirely invisible to them. Fixed to
-- require BOTH visible (when they are the same store this reduces to one
-- real check, exactly as specified — no branch needed, the AND of the same
-- boolean condition evaluated twice is that condition). Applied here to
-- discovery/preview (both go through this shared helper); finalize
-- re-resolution (0178) already goes through this same helper so it is
-- fixed for free; batch list/read privacy is a SEPARATE fix, migration
-- 0186 (get_settlement_batch()/list_settlement_batches(), 0182, do not
-- call this helper at all — item 21's line-level OR-privacy is its own
-- independent bug).
--
-- ============================================================================
-- §20/§21/§22 — COD adapter: genuine state transitions, not every event.
-- ============================================================================
-- 0176 treated every state='collected' event as a NEW Collection and every
-- state='not_collected' event (with ANY earlier 'collected' event, however
-- far back) as a Reversal — so collected->collected double-counted a
-- Collection, and a not_collected event always found SOME prior collected
-- event via `order by created_at desc limit 1` regardless of how many
-- collect/reverse cycles happened in between (the exact re-collection
-- mispairing bug Patch 7.1 §21 names).
--
-- Fix: public.shipment_cod_events (0127) has exactly 4 states ('expected',
-- 'collected', 'not_collected', 'unknown') and no distinct "reversal event
-- type" of its own — the only signal is the SEQUENCE of states. Using
-- window function lag() ordered by (business_date, created_at, id) [id as
-- the final deterministic tiebreak — the table has no other ordering
-- column; business_date+created_at is the same ordering get_shipment(),
-- 0127, already uses for its own timeline] per shipment_id:
--   'cod_collection' <- a row whose state='collected' AND whose
--       IMMEDIATELY PRECEDING event (or no prior event at all) is NOT
--       'collected' — i.e. a genuine transition INTO collected. A second
--       consecutive 'collected' row (collected->collected) has a
--       'collected' predecessor, so it produces NO source (§22-A).
--   'cod_reversal'    <- a row whose state='not_collected' AND whose
--       IMMEDIATELY PRECEDING event is 'collected' — a genuine transition
--       OUT of collected. Its paired collection is, by construction, that
--       SAME immediately-preceding row (lag() over the correct partition/
--       order), never "the last collected event across all history" —
--       this is what correctly resolves re-collection (§21/§22-C: not_
--       collected->collected->not_collected->collected pairs each
--       reversal with its OWN immediately-prior collection, never
--       cross-pairing a later collection back to an earlier reversal).
--       Its fee_lookup_date (new output column, consumed by 0185) is that
--       SAME paired collection's OWN business_date — never re-derived by
--       a separate "last collected ever" query in finalize.
-- Any other adjacent pair (repeated not_collected, expected/unknown noise,
-- not_collected->expected, etc.) matches neither predicate -> no source,
-- per §22-A/B/C/D/E's own requirement list.
-- ---------------------------------------------------------------------------

-- Widen source_kind to allow the new kinds, WITHOUT removing the old ones
-- (settlement_batch_lines/settlement_source_claims are permanent,
-- insert-only, immutable historical records per 0173 — any settlement
-- already finalized under 0176's old adapter used 'return_refund'/
-- 'return_refund_reversal' and must remain valid forever; this migration
-- only stops NEW rows of those two old kinds from ever being produced
-- again, by no longer emitting them from the candidate resolver below).
alter table public.settlement_batch_lines
  drop constraint settlement_batch_lines_source_kind_check;
alter table public.settlement_batch_lines
  add constraint settlement_batch_lines_source_kind_check check (
    source_kind in (
      'sale', 'return_refund', 'return_refund_reversal',
      'adjustment_approved', 'adjustment_reversal', 'cod_collection', 'cod_reversal',
      'return_refund_event', 'return_refund_event_reversal',
      'return_fee_reversal', 'return_fee_reversal_reversal'
    )
  );

comment on constraint settlement_batch_lines_source_kind_check on public.settlement_batch_lines is
  'Patch 7.1 §1/§2 — widened to add the 4 new source kinds sourced from the actual refund ledger + independent fee-reversal source. ''return_refund''/''return_refund_reversal'' are RETAINED (never removed) solely so pre-Patch-7.1 finalized settlement_batch_lines rows (immutable, insert-only) stay valid — _settlement_unsettled_source_candidates() (0184+) never emits either kind again.';

alter table public.settlement_source_claims
  drop constraint settlement_source_claims_source_kind_check;
alter table public.settlement_source_claims
  add constraint settlement_source_claims_source_kind_check check (
    source_kind in (
      'sale', 'return_refund', 'return_refund_reversal',
      'adjustment_approved', 'adjustment_reversal', 'cod_collection', 'cod_reversal',
      'return_refund_event', 'return_refund_event_reversal',
      'return_fee_reversal', 'return_fee_reversal_reversal'
    )
  );

comment on constraint settlement_source_claims_source_kind_check on public.settlement_source_claims is
  'Patch 7.1 §1/§2 — mirrors settlement_batch_lines_source_kind_check above; same rationale.';

-- ---------------------------------------------------------------------------
drop function if exists public._settlement_unsettled_source_candidates(uuid, date, date, uuid);

create function public._settlement_unsettled_source_candidates(
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
    -- §20/§21 — genuine state transitions per shipment, deterministically
    -- ordered (business_date, created_at, id — the only columns available;
    -- id is the final tiebreak, matching get_shipment()'s own timeline
    -- ordering convention of business_date+created_at as the primary key).
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
    -- B) Return Refund Event — §1: the ACTUAL cash refund ledger, never
    -- gated by sales_returns.status (an actual refund is a fact regardless
    -- of the return header's later administrative fate).
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
    -- C) Return Refund Event Reversal — §1/§3-C/§3-D/§3-E: sourced
    -- EXCLUSIVELY from sales_return_refund_event_reversals (the only real
    -- correction path for an actual refund event); route match uses the
    -- ORIGINAL event's OWN refund_method_id (§3-E), never any method on
    -- the reversal row (it has none) nor the original sale's method.
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
    -- D) Return Fee Reversal — §2: independent source tied to the Return's
    -- own financial snapshot, dated at approval (a real domain date), route
    -- matched via the ORIGINAL sale's payment method (the fee being
    -- credited was charged on that method).
    select
      'return_fee_reversal', sr.id, sr.return_number, (sr.approved_at at time zone 'Asia/Riyadh')::date, sr.processed_store_id, s.name_ar,
      ('استرداد عمولة ' || sr.return_number),
      0::numeric, -sr.payment_fee_reversal_amount, sr.payment_fee_reversal_amount,
      (sr.approved_at at time zone 'Asia/Riyadh')::date, null::uuid, null::text
    from route r
    join public.sales_returns sr on true
    join public.stores s on s.id = sr.processed_store_id
    where r.route_kind = 'payment_collection'
      and sr.status = 'approved'
      and sr.payment_fee_reversal_amount is not null and sr.payment_fee_reversal_amount <> 0
      and sr.payment_method_id = r.payment_method_id
      and r.collection_channel_id is null
      and (sr.approved_at at time zone 'Asia/Riyadh')::date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sr.processed_store_id)

    union all
    -- E) Return Fee Reversal Reversal — §2: undoes ONLY the fee-credit
    -- source above, on the SAME administrative reverse_sales_return()
    -- action, dated at its own real/validated reversal_business_date.
    select
      'return_fee_reversal_reversal', sr.id, sr.return_number, sr.reversal_business_date, sr.processed_store_id, s.name_ar,
      ('عكس استرداد عمولة ' || sr.return_number),
      0::numeric, sr.payment_fee_reversal_amount, -sr.payment_fee_reversal_amount,
      sr.reversal_business_date, null::uuid, null::text
    from route r
    join public.sales_returns sr on true
    join public.stores s on s.id = sr.processed_store_id
    where r.route_kind = 'payment_collection'
      and sr.status = 'reversed'
      and sr.payment_fee_reversal_amount is not null and sr.payment_fee_reversal_amount <> 0
      and sr.payment_method_id = r.payment_method_id
      and r.collection_channel_id is null
      and sr.reversal_business_date between p_source_date_from and p_source_date_to
      and exists (select 1 from public.user_visible_store_ids(p_actor) sid where sid = sr.processed_store_id)

    union all
    -- F) Approved Adjustment — §4 exact channel match, §5 AND cross-store.
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
    -- G) Adjustment Reversal — same §4/§5 fixes as F.
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
    -- H) COD Collection — §20: a genuine transition INTO 'collected'.
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
    -- I) COD Reversal — §20/§21: a genuine transition OUT of 'collected'
    -- into 'not_collected'; fee_lookup_date is the SAME paired (lag())
    -- collection's own business_date, never a separate "last collected
    -- ever" lookup.
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
  'Phase 7.1 patch (§1/§2/§4/§5/§20/§21/§22) — PRIVATE shared candidate resolver, DROP+CREATE-superseding 0176''s version (output columns changed: +fee_lookup_date/+secondary_store_id/+secondary_store_display). Returns cash sources exclusively from sales_return_refund_events/_reversals (never sales_returns.status), an independent return_fee_reversal/_reversal source keyed to the Return header, exact IS NOT DISTINCT FROM route/channel matching, AND-based (both-visible) cross-store Adjustment scope, and COD sources derived from genuine lag()-based state transitions. Not granted to authenticated — internal only. Consumed automatically (no edits needed) by list_unsettled_settlement_sources()/preview_settlement_batch() (0176, both select columns by name); finalize_settlement_batch() is superseded separately in 0185 to consume the new columns.';

revoke execute on function public._settlement_unsettled_source_candidates(uuid, date, date, uuid) from public;

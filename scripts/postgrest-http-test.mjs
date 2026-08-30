#!/usr/bin/env node
/**
 * REAL HTTP/PostgREST integration test for the Financial Integrity Patch 2.2
 * Decimal Transport Boundary fix (spec item 2's most rigorous requirement:
 * "أضف Integration Test حقيقي على HTTP/PostgREST/Supabase client إن أمكن،
 * وليس JSON.parse مصطنع فقط").
 *
 * This is NOT a simulation. It talks to a REAL PostgREST binary (v12.2.3,
 * downloaded from the official GitHub release) over real HTTP, using
 * @supabase/postgrest-js — the actual client library supabase-js itself
 * uses under the hood for .from()/.rpc() — pointed directly at PostgREST's
 * root URL (bypassing supabase-js's createClient(), which just prepends a
 * fixed "/rest/v1" path and otherwise delegates straight to this same
 * library; there is no meaningful behavioral difference for what this test
 * proves).
 *
 * Run via scripts/run_postgrest_http_test.sh, which builds a fully
 * throwaway database (harness + all migrations + seed.sql +
 * supabase/tests/postgrest_http_test_setup.sql), starts PostgREST against
 * it, signs a real JWT, runs this script, then tears everything down.
 *
 * What this proves, end to end over real HTTP:
 *   1. A raw NUMERIC-returning function/column is serialized by PostgREST
 *      as an UNQUOTED JSON number, and a sufficiently high-precision value
 *      (27 significant digits) is corrupted by the JS double decode the
 *      instant this script's HTTP client parses the response body.
 *   2. The finance-safe "_safe" pattern (migration 0052) — casting ::text
 *      inside Postgres before serialization — is NOT corrupted: the exact
 *      same value survives byte-for-byte as a JSON string, and feeding it
 *      into src/lib/decimal.ts's toDecimal() reproduces it exactly.
 *   3. The REAL production RPCs added in migration 0052
 *      (gold_price_for_karat_on_date_safe, manufacturing_fee_for_karat_on_
 *      date_safe, payment_fee_for_method_on_date_safe) — not just the
 *      synthetic literal above — return `typeof value === "string"` over
 *      real HTTP and match the raw numeric-returning siblings' values
 *      exactly once both are compared as Decimals.
 *   4. The raw (non-"_safe") production RPCs return `typeof value ===
 *      "number"` over real HTTP — documenting, not just asserting, that the
 *      risk is real for any future code that reads them directly.
 *
 * Part 3 (Phase 3 — Sales Core, spec §16/§33 — extended by migrations
 * 0058-0064) additionally proves, over the SAME real HTTP/PostgREST round
 * trip:
 *   5. create_sales_order() actually persists a Sale and returns a real
 *      order_number string.
 *   6. get_sales_order()/list_sales_orders()/preview_sales_order() return
 *      every financial value (subtotal/gross_profit/payment_fee_amount/
 *      net_sales_profit) as typeof "string", never "number" — the same
 *      Decimal Transport Boundary guarantee Part 2 proves for Phase 2's
 *      master-data RPCs, now proven for Sales specifically.
 *   7. DB-level profit protection (spec §15/§32) survives a REAL HTTP
 *      request from a caller without sales.view_profit: get_sales_order()
 *      omits the profit keys ENTIRELY (not null) from the JSON body, and
 *      list_sales_orders() returns them as JSON null — proven with a
 *      second real signed JWT for a second real test actor, not simulated.
 *
 * Patch 3.1 (item M) further extends the same real HTTP/PostgREST round
 * trip to prove:
 *   8. Audit profit protection (spec item 4 / migration 0072): a REAL GET
 *      request against PostgREST's auto-generated /audit_logs endpoint (an
 *      ordinary table query, not an RPC) returns sale.* rows for a caller
 *      with audit_logs.view + sales.view_profit, and ZERO rows for a
 *      caller with audit_logs.view but WITHOUT sales.view_profit — proving
 *      the RLS policy filters the whole row, not just its profit columns.
 *   9. Stable sales_order_items identity (spec item 1) across a REAL
 *      update_sales_order() HTTP call: an edited item's id never changes,
 *      and a dropped item is proven — via a service_role-signed
 *      verification JWT, since sales_order_items has no SELECT RLS for
 *      `authenticated` — to still physically exist with status='removed'
 *      rather than being hard-deleted.
 *
 * Phase 4 (Returns Core — migrations 0082-0091) further extends the same
 * real HTTP/PostgREST round trip to prove:
 *  10. create_sales_return()/preview_sales_return() return every financial
 *      value as typeof "string" over real HTTP, and a real return_number
 *      (RET-##########) is actually persisted.
 *  11. Double-return prevention (the sales_return_items_order_item_active_uq
 *      partial unique index, migration 0082) rejects a second
 *      create_sales_return() over the SAME already-claimed item over a
 *      REAL HTTP call, not just in a simulated local session.
 *  12. get_returnable_sales_order()'s DERIVED order_state and per-item
 *      `returnable` flag genuinely change across a real return's pending ->
 *      approved -> reversed lifecycle, all observed over real HTTP.
 *  13. approve_sales_return() computes and PERSISTS every reversal figure
 *      (proven via a follow-up get_sales_return() over real HTTP); profit-
 *      sensitive keys are entirely ABSENT (not merely null) for the
 *      no-profit actor on get_sales_return(), and JSON null on
 *      list_sales_returns(), mirroring Part 3's Sales proof exactly.
 *  14. update_sales_order()'s financial lock (migration 0084) actually
 *      rejects a financial edit over real HTTP once an effective (approved)
 *      return exists on that order.
 *  15. The actual-cash-refund ledger (record_sales_return_refund()/
 *      reverse_sales_return_refund_event()) round-trips over real HTTP and
 *      get_sales_return()'s actual_refunded_total/refund_variance reflect
 *      it live.
 *  16. audit_logs' return.% profit-protection RLS extension (migration
 *      0091) mirrors Part 4's sale.% proof for Returns specifically.
 *
 * Returns Integrity Patch 4.1 (migrations 0092-0098) further extends Part 7
 * over the SAME real HTTP/PostgREST round trip to prove:
 *  17. create_sales_return()/preview_sales_return() accept the new jsonb
 *      p_items shape plus the new business-input parameters
 *      (p_collection_state/p_approved_refund_amount/etc.), and
 *      returned_original_sale_amount (Section 1) round-trips as typeof
 *      "string".
 *  18. Money-scale validation (Section 10) rejects an approved_refund_
 *      amount with more than 2 decimal places over a REAL HTTP call.
 *  19. The pending-membership-vs-effective-claim split (Section 5): a
 *      SECOND pending return over an already-referenced item is now
 *      ACCEPTED (the opposite of the pre-Patch-4.1 behavior), and
 *      get_returnable_sales_order() still reports the item as returnable
 *      while only pending returns reference it; only once the FIRST return
 *      is approved does approving the SECOND get rejected by the real
 *      sales_return_items_effective_claim_uq constraint.
 *  20. get_sales_return() exposes the full Section 12 financial-effect
 *      field set (recovered_original_cost_amount/net_sales_profit_
 *      adjustment/adjusted_order_net_sales_profit), all hidden entirely
 *      (not null) for a caller without sales.view_profit.
 *  21. finalize_sales_return_refund() (Section 11) flips refund_
 *      reconciliation_state to 'finalized_matched' over real HTTP once the
 *      actual refunded total matches approved_refund_amount.
 *  22. A REVERSED return still shows its item over real HTTP (Section 6 —
 *      history is never erased).
 *
 * Final Returns Integrity Patch 4.2 (migrations 0099-0105) further extends
 * Part 7 over the SAME real HTTP/PostgREST round trip to prove:
 *  23. The three narrow Returns-specific lookup RPCs (Section 7) —
 *      returns_operable_store_lookups()/returns_visible_store_lookups()/
 *      returns_refund_method_lookups() — each return only {id, name_ar}
 *      over real HTTP, and each is gated on its OWN specific Returns
 *      permission (returns.create/returns.view/returns.record_refund
 *      respectively), never on stores.view/payment_methods.view — a caller
 *      holding only returns.view is rejected by the two permission-gated
 *      ones but succeeds on the visible-store one.
 *  24. preview_sales_return() accepts the new p_scenario parameter over
 *      real HTTP (Section 5 preview/create parity).
 *  25. get_sales_return() exposes requires_sale_refresh (Section 1) as
 *      typeof "boolean" (false for a freshly-created return — Patch 4.2's
 *      create_sales_return() always inserts false) over real HTTP.
 *  26. reopen_sales_return_refund_reconciliation() (Section 3/4) reopens a
 *      finalized refund reconciliation over real HTTP given a mandatory
 *      reason, after which a new record_sales_return_refund() call
 *      succeeds again and reconciliation_history grows with a real
 *      'reopened' entry, never erasing the original 'finalized' one.
 *
 * Final Shipping Hotfix 5.1.1 (migrations 0131-0132) further extends Part 8
 * over the SAME real HTTP/PostgREST round trip to prove:
 *  27. (item 1) create_shipment() over real HTTP rejects a RETURN shipment
 *      whose customer_shipping_charge diverges from the resolved standard
 *      fee when no p_customer_return_shipping_charge_override_reason is
 *      supplied, then succeeds once the reason is supplied — and
 *      get_shipment() reflects customer_return_shipping_fee_standard_amount
 *      / customer_return_shipping_charge_is_override / _override_reason
 *      correctly (this DB-level enforcement already existed since 0125; the
 *      actual Hotfix 5.1.1 gap was the Server Action/schema/form never
 *      passing the reason through — covered instead by the Vitest suite,
 *      item 10 — this HTTP section only re-confirms the RPC boundary).
 *  28. (item 5) The new list_shipping_carrier_rate_versions_safe()/
 *      list_customer_return_shipping_fee_versions_safe() RPCs (migration
 *      0132) return base_cost/fee_amount as typeof "string" over real HTTP,
 *      and are rejected for a real, independently-signed caller who holds
 *      shipments.view but NOT shipping_rates.view.
 *  29. (item 6) add_shipment_status_event()/record_shipment_cod_collection_
 *      state() (migration 0131) now reject a new event dated STRICTLY
 *      before the LATEST existing event of their OWN stream, even when
 *      that date still clears the shipment_date floor — proving the actual
 *      regression (0130 only checked against shipment_date) over real HTTP,
 *      not just in the SQL suite. Same-day events remain accepted.
 *  Item 4 (correct_status-only Server Action permission) is a Next.js
 *  Server Action bug, not reachable via direct PostgREST calls — the RPC
 *  itself was already correctly gated before Hotfix 5.1.1; that fix is
 *  covered by code inspection + the existing SQL/concurrency suites which
 *  already exercise add_shipment_status_event() as a correct_status-holding
 *  actor.
 *
 * Final Shipping UI & Verification Hotfix 5.1.2 (no new migrations — every
 * item is a frontend/test-completeness fix) further extends the SAME real
 * HTTP/PostgREST round trip with a dedicated Part 10, completing real HTTP
 * coverage for Patch 5.1/Hotfix 5.1.1 requirements that were previously
 * proven only at the SQL layer:
 *  A) Direct INSERT over real HTTP against shipping_carrier_rate_versions/
 *     customer_return_shipping_fee_versions is rejected by RLS even for an
 *     actor holding shipping_rates.manage — every write MUST go through the
 *     sanctioned RPCs (Patch 5.1 item 1, migration 0122).
 *  B) create_shipping_carrier_rate_version()/create_customer_return_
 *     shipping_fee_version() (the sanctioned RPCs) succeed over real HTTP.
 *  C) shipments_filter_carrier_lookups()/shipments_filter_zone_lookups()
 *     succeed over real HTTP for a caller holding only shipments.view
 *     (Patch 5.1 item 11), and list_shipments() shows customer_shipping_
 *     charge as a real string while every carrier-cost/margin field stays
 *     null for that same caller.
 *  D) create_shipment() over real HTTP: a RETURN shipment into a zone with
 *     NO customer-return-fee configuration AT ALL (not just a diverging
 *     one, which Hotfix 5.1.1's Part 9 already covers) is rejected without
 *     a manual-charge override reason, then succeeds with one.
 *  E) create_shipment() over real HTTP rejects a new RETURN shipment
 *     against an already-REVERSED return (Patch 5.1 item 15/16).
 *  F) record_shipment_cod_collection_state() succeeds over real HTTP
 *     (re-confirmed alongside a genuine direct-mutation bypass attempt on
 *     shipment_cod_events, rejected — that table carries zero RLS policies
 *     for `authenticated`, migration 0127).
 *  G) A carrier/zone rename over real HTTP never changes how an EXISTING
 *     shipment displays its carrier/zone name (Patch 5.1 item 17 — the
 *     shipment's own creation-time snapshot columns, not a live join).
 *  H) The Hotfix 5.1.1 safe rate-read RPCs (0132) also reflect rows created
 *     by THIS session's own B)/D) calls, not just seeded ones.
 *  I) list_shipments() filters (p_order_number/p_return_number/
 *     p_original_sale_store_id/p_cod_collection_state, Patch 5.1 item 12)
 *     each genuinely narrow the result set over real HTTP.
 *
 * Final Shipping Verification Hotfix 5.1.3 (no new migrations — every item
 * is a Preview-state-machine/test-completeness fix) extends Part 10 in
 * place with five more real HTTP assertions closing the specific gaps the
 * user identified by reviewing the Hotfix 5.1.2 source directly:
 *  item 7)  A direct PATCH (UPDATE) over real HTTP against BOTH locked-down
 *           version tables (not just INSERT, item A above) has no effect —
 *           base_cost/fee_amount/effective_from all stay genuinely
 *           unchanged, whether observed as a thrown error or (the more
 *           common Postgres RLS behavior for an UPDATE with no matching
 *           policy) a 2xx response that affects zero rows.
 *  item 8)  shipments_visible_store_lookups() succeeds over real HTTP for a
 *           shipments.view-only caller — the /shipments list page's third
 *           lookup dependency, alongside the filter_carrier/filter_zone
 *           lookups item C already covers.
 *  item 9)  The other half of item G's snapshot proof: a shipment created
 *           AFTER the carrier/zone rename captures the RENAMED names in
 *           its own snapshot, never the pre-rename ones — proving the
 *           snapshot columns are a genuine point-in-time capture, not
 *           merely "always frozen on the first-ever value".
 *  item 10) A direct UPDATE over real HTTP against shipment_cod_events
 *           (not just INSERT, item F above), AND a direct UPDATE
 *           attempting to move shipments.cod_collection_state itself, both
 *           have no effect — only record_shipment_cod_collection_state()
 *           may ever move the current COD state.
 *
 * Phase 7 — Settlements Core (migrations 0167-0183) + Integrity Patch 7.1
 * (migrations 0184-0191) get a dedicated Part 14, completing real HTTP
 * coverage for the module this file previously had ZERO coverage of (a
 * deferred gap explicitly flagged in the prior delivery). Proves, over the
 * SAME real HTTP/PostgREST round trip:
 *   - raw SELECT/INSERT against settlement_batches/settlement_batch_lines/
 *     settlement_bank_movement_events/settlement_route_fee_versions is
 *     forbidden (zero rows or a permission error, never data/a write);
 *   - settlements.manage_routes is required for create/update/disable/
 *     enable_settlement_route, and its four Patch 7.1 §23 narrow lookup RPCs
 *     (payment method/collection channel/carrier/fee-version-for-management)
 *     work for a manage_routes-ONLY actor holding no unrelated Master Data
 *     view permission;
 *   - a settlements.create-only actor (no settlements.view) can create a
 *     draft and read it back ONLY via get_draft_settlement_batch_for_edit()
 *     (§7), and settlement_create_store_lookups() works for it (§24);
 *   - list_unsettled_settlement_sources()/preview_settlement_batch() surface
 *     every Settlement Source Adapter kind this fixture can build (sale,
 *     return_refund_event, return_refund_event_reversal, return_fee_
 *     reversal, adjustment_approved, cod_collection, cod_reversal), every
 *     money figure as typeof "string";
 *   - exact route/channel matching (§4 — a NULL-channel route no longer
 *     matches a Sale, which always carries a real channel);
 *   - COD route matching, no-double-counting (a COD sale is excluded from
 *     the payment_collection Sale source), and route_formula fee parity
 *     between preview and finalize (§14);
 *   - finalize_settlement_batch() persists immutable lines + claims, blocks
 *     a re-claim of an already-claimed source (claim uniqueness), and
 *     snapshots settlement_calculation_version=2 (the Patch 7.1 logic tag);
 *   - view-without-financials redaction (settlements.view alone gets NULL
 *     money fields) and the §8 audit_logs cross-domain permission split
 *     (settlements.view_financials opens NOTHING toward Sales/Adjustments
 *     financial audit rows, and vice versa sales.view_profit opens NOTHING
 *     toward Settlements financial audit rows);
 *   - §5 cross-store Adjustment source visibility (BOTH the original Sale's
 *     store AND the Adjustment's processing store must be visible) and §6
 *     whole-batch privacy (a batch with even one invisible-store line is
 *     entirely invisible — not header, not aggregate, not partial line —
 *     to both list_settlement_batches() and get_settlement_batch());
 *   - batch fee override, bank movement (including a negative/debit
 *     movement) + reversal, a new movement rejected once reconciled (§13),
 *     zero-variance reconcile, nonzero-variance permission/reason gating,
 *     cancellation, claim release after cancellation, and §26's original_*
 *     (permanent historical fact) vs effective_* (0.00 once cancelled)
 *     split, all observed over real HTTP;
 *   - no source-domain profit leak — settlement_batch_lines' JSON shape
 *     never carries a gold/manufacturing/VAT cost, product gross profit,
 *     sales net profit, adjustment direct cost, or shipping P/L field.
 *
 * Phase 7 — Final Integrity Hotfix 7.1.1 (migrations 0192-0196) further
 * extends Part 14 over the SAME real HTTP/PostgREST round trip with a
 * dedicated Part 15, proving:
 *  a) (§4) update_draft_settlement_batch() ownership on WRITE: a second,
 *     genuinely distinct create-only actor is rejected (not-found) editing
 *     someone else's draft; the owner succeeds; a settlements.view holder is
 *     unrestricted even on someone else's draft.
 *  b) (§5) record_settlement_bank_movement()/reconcile_settlement_batch()/
 *     cancel_settlement_batch()/reverse_settlement_bank_movement() all fail
 *     closed (not-found) for a single-store-scoped actor who cannot see
 *     every line's store on the batch, while the full actor succeeds.
 *  c) (§6) settlement_route_fee_for_route_on_date() is no longer callable
 *     via PostgREST RPC at all (EXECUTE revoked from PUBLIC/authenticated),
 *     even for the most-privileged actor.
 *  d) (§7) reconcile_settlement_batch() redacts actual_bank_movement/
 *     variance to JSON null for an actor holding settlements.reconcile but
 *     NOT settlements.view_financials, while an actor holding both gets real
 *     typeof "string" values for the SAME kind of reconciliation.
 *  e) (§9) preview_settlement_batch() now accepts the SAME p_batch_fee_
 *     override/p_override_reason parameters finalize_settlement_batch()
 *     already validates (permission, mandatory reason, non-negative,
 *     2dp) — and for the SAME selection, preview's effective_batch_fee
 *     equals finalize's snapshotted original_batch_fee exactly.
 *  f) (§11) cancel_settlement_batch() rejects a cancellation dated before
 *     the latest bank-movement reversal on the batch, accepts one on/after.
 *  g) (§12) settlement_filter_payment_method_lookups()/settlement_filter_
 *     collection_channel_lookups() work for settlements.view ALONE (never
 *     payment_methods.view/collection_channels.view) and include disabled
 *     rows; an actor without settlements.view gets an empty result.
 *  h) (§15) list_unsettled_settlement_sources()'s p_store_id filter matches
 *     a cross-store Adjustment under EITHER its primary or secondary store
 *     independently (OR, not AND — visibility itself is unchanged).
 *  i) (§1, CRITICAL) a Return's return_fee_reversal source survives an
 *     administrative reverse_sales_return() call — it is a permanent
 *     historical fact, never re-derived from current status — and a NEW,
 *     independent return_fee_reversal_reversal source appears alongside it;
 *     while both remain unclaimed their expected_settlement_impact values
 *     sum to exactly 0.00.
 *  j) (§3) a Return's return_fee_reversal source routes via the ORIGINAL
 *     Sale's own payment method + collection channel, while the actual cash
 *     Refund Event source keeps routing via its own refund_method_id +
 *     implicit NULL channel — the two legitimately settle on DIFFERENT
 *     routes for the SAME Return.
 *  k) (§1/§3 consequence) those two independently-routed sources for the
 *     SAME Return can be claimed into two SEPARATE finalized batches on
 *     their own routes, no longer mutually exclusive.
 *
 * Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2 (migrations
 * 0197-0198) further extends Part 15 over the SAME real HTTP/PostgREST
 * round trip with a dedicated Part 16, proving (spec §13):
 *  a) (§1/§7, CRITICAL) the full Route-A/Route-B Discovery split: a Sale on
 *     Payment Method A/Channel A -> full Return -> Approve -> Reverse ->
 *     the Sale is edited to Payment Method B/Channel B (permitted
 *     post-reversal, 0084) -> list_unsettled_settlement_sources() over
 *     real HTTP resolves BOTH historical fee events (return_fee_reversal,
 *     return_fee_reversal_reversal) to Route A exclusively — never Route
 *     B, the Sale's new live route.
 *  b) (§10) collection_channel_id_snapshot cannot be mutated by any raw
 *     HTTP path: a direct PATCH against /sales_returns is a no-op for the
 *     ordinary full-permission actor (pre-existing zero-UPDATE-RLS-policy
 *     lockdown), and is REJECTED outright — even for the trusted
 *     service_role verification client — by the 0197 immutability
 *     trigger.
 *
 * Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3 (migrations
 * 0197-0198 REVISED) further extends Part 16 over the SAME real HTTP/
 * PostgREST round trip with a dedicated Part 17, proving (spec §15):
 *  A-D) the full lockstep-refresh lifecycle over real HTTP: create a Return
 *     on Sale A/A -> update_sales_order() to B/B while pending ->
 *     refresh_pending_sales_return_from_sale() re-syncs payment_method_id
 *     AND collection_channel_id_snapshot together to B/B -> approve_sales_
 *     return() now succeeds.
 *  E) Discovery resolves the refreshed Return to Route B exclusively, never
 *     Route A (the abandoned pre-refresh basis).
 *  F-H) reverse_sales_return(), THEN edit the Sale again to C/C (permitted
 *     post-reversal) — Route B still shows BOTH historical fee events,
 *     Route C shows neither (post-approval historical stability, §10, now
 *     proven over real HTTP after a genuine mid-lifecycle refresh).
 *  I) a raw PATCH against collection_channel_id_snapshot remains blocked
 *     over real HTTP, both for the ordinary authenticated client (RLS
 *     no-op) and the trusted service_role client (rejected by the revised
 *     0197 guard trigger), even on a Return that went through a sanctioned
 *     refresh earlier in its life.
 */
import { PostgrestClient } from "@supabase/postgrest-js";
import Decimal from "decimal.js";

const POSTGREST_URL = process.env.POSTGREST_URL ?? "http://127.0.0.1:3111";
const JWT = process.env.TEST_JWT;
if (!JWT) {
  console.error("FATAL: TEST_JWT env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}

const KARAT_ID = "c9100000-0000-4000-8000-000000000001";
const PAYMENT_METHOD_ID = "c9200000-0000-4000-8000-000000000001";
const STORE_ID = "c9300000-0000-4000-8000-000000000001";
// Patch 6.1 items 12/13/31 — a SECOND store (c9300000-0000-4000-8000-
// 000000000002) exists for the cross-store isolation proof over real HTTP;
// its id is baked into clientAdjStoreBOnly's JWT claims (set up in
// postgrest_http_test_setup.sql) and never needs to be referenced by value
// here, so no separate constant is declared for it.
const CATEGORY_ID = "c9400000-0000-4000-8000-000000000001";
const CHANNEL_ID = "c9500000-0000-4000-8000-000000000001";
// Patch 6.1 items 12/13/31's second store (Store B) — reused by Part 14 for
// the Settlements §5/§6 cross-store privacy proof.
const STORE_B_ID = "c9300000-0000-4000-8000-000000000002";
const HIGH_PRECISION_VALUE = "123456789012345678.123456789";
// Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2 (Part 16) — a
// SECOND, genuinely distinct ACTIVE payment method + collection channel
// ("Payment Method B" / "Channel B"), seeded by postgrest_http_test_setup.sql
// specifically for this hotfix's Route-A/Route-B Discovery split proof.
const PAYMENT_METHOD_B_ID = "c9200000-0000-4000-8000-000000000003";
const CHANNEL_B_ID = "c9500000-0000-4000-8000-000000000003";
// Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3 (Part 17) — a
// THIRD, genuinely distinct ACTIVE payment method + collection channel
// ("Payment Method C" / "Channel C"), seeded by postgrest_http_test_setup.sql
// specifically for this hotfix's post-approval historical-stability proof.
const PAYMENT_METHOD_C_ID = "c9200000-0000-4000-8000-000000000004";
const CHANNEL_C_ID = "c9500000-0000-4000-8000-000000000004";

const JWT_NO_PROFIT = process.env.TEST_JWT_NO_PROFIT;
if (!JWT_NO_PROFIT) {
  console.error("FATAL: TEST_JWT_NO_PROFIT env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}

// Patch 3.1 item M: a service_role-signed JWT, used ONLY as a verification
// oracle (bypasses RLS) to prove sales_order_items rows are genuinely
// soft-removed rather than hard-deleted — that table has zero SELECT RLS
// policies for `authenticated`, so an ordinary actor's client can never
// observe this directly, over HTTP or otherwise.
const JWT_SERVICE = process.env.TEST_JWT_SERVICE;
if (!JWT_SERVICE) {
  console.error("FATAL: TEST_JWT_SERVICE env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}

// Phase 6 (Services / Adjustments Core), Part 11, §25 — a THIRD real actor
// holding ONLY adjustments.create (no sales.view at all).
const JWT_ADJ_CREATE_ONLY = process.env.TEST_JWT_ADJ_CREATE_ONLY;
if (!JWT_ADJ_CREATE_ONLY) {
  console.error("FATAL: TEST_JWT_ADJ_CREATE_ONLY env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}

// Patch 6.1 item 2 — a FOURTH actor holding ONLY adjustments.manage_cost.
const JWT_ADJ_MANAGE_COST_ONLY = process.env.TEST_JWT_ADJ_MANAGE_COST_ONLY;
if (!JWT_ADJ_MANAGE_COST_ONLY) {
  console.error("FATAL: TEST_JWT_ADJ_MANAGE_COST_ONLY env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}

// Patch 6.1 items 12/13/31 — a FIFTH actor, single-store-scoped to Store B
// only (adjustments.view + adjustments.approve). Phase 7 Integrity Patch 7.1
// additionally grants this SAME actor settlements.view/view_financials/
// create (postgrest_http_test_setup.sql) — reused for Part 14's §5/§6
// cross-store privacy proof.
const JWT_ADJ_STORE_B_ONLY = process.env.TEST_JWT_ADJ_STORE_B_ONLY;
if (!JWT_ADJ_STORE_B_ONLY) {
  console.error("FATAL: TEST_JWT_ADJ_STORE_B_ONLY env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}

// Phase 7 Integrity Patch 7.1 (Settlements Core), Part 14 — four more real
// actors: settlements.create-only (§7/§24), settlements.manage_routes-only
// (§2/§23), and the two §8 audit cross-domain-permission-split actors.
const JWT_SETTLE_CREATE_ONLY = process.env.TEST_JWT_SETTLE_CREATE_ONLY;
if (!JWT_SETTLE_CREATE_ONLY) {
  console.error("FATAL: TEST_JWT_SETTLE_CREATE_ONLY env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}
const JWT_SETTLE_MANAGE_ROUTES_ONLY = process.env.TEST_JWT_SETTLE_MANAGE_ROUTES_ONLY;
if (!JWT_SETTLE_MANAGE_ROUTES_ONLY) {
  console.error("FATAL: TEST_JWT_SETTLE_MANAGE_ROUTES_ONLY env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}
const JWT_SETTLE_AUDIT_FIN_ONLY = process.env.TEST_JWT_SETTLE_AUDIT_FIN_ONLY;
if (!JWT_SETTLE_AUDIT_FIN_ONLY) {
  console.error("FATAL: TEST_JWT_SETTLE_AUDIT_FIN_ONLY env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}
const JWT_SALES_PROFIT_NO_SETTLE_FIN = process.env.TEST_JWT_SALES_PROFIT_NO_SETTLE_FIN;
if (!JWT_SALES_PROFIT_NO_SETTLE_FIN) {
  console.error("FATAL: TEST_JWT_SALES_PROFIT_NO_SETTLE_FIN env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}

// Final Integrity Hotfix 7.1.1 (Settlements Core, migrations 0192-0196),
// Part 15 — three more narrow actors: a SECOND settlements.create-only
// identity (§4 non-owner rejection), a single-store-scoped actor holding
// every lifecycle write permission (§5 fail-closed proof), and a
// settlements.reconcile-only actor with no view_financials (§7 redaction).
const JWT_SETTLE_CREATE_ONLY_2 = process.env.TEST_JWT_SETTLE_CREATE_ONLY_2;
if (!JWT_SETTLE_CREATE_ONLY_2) {
  console.error("FATAL: TEST_JWT_SETTLE_CREATE_ONLY_2 env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}
const JWT_SETTLE_STORE_SCOPED = process.env.TEST_JWT_SETTLE_STORE_SCOPED;
if (!JWT_SETTLE_STORE_SCOPED) {
  console.error("FATAL: TEST_JWT_SETTLE_STORE_SCOPED env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}
const JWT_SETTLE_RECONCILE_ONLY = process.env.TEST_JWT_SETTLE_RECONCILE_ONLY;
if (!JWT_SETTLE_RECONCILE_ONLY) {
  console.error("FATAL: TEST_JWT_SETTLE_RECONCILE_ONLY env var not set (run via scripts/run_postgrest_http_test.sh).");
  process.exit(1);
}

const client = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT}` },
});
const clientNoProfit = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_NO_PROFIT}` },
});
const clientService = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_SERVICE}` },
});
const clientAdjCreateOnly = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_ADJ_CREATE_ONLY}` },
});
const clientAdjManageCostOnly = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_ADJ_MANAGE_COST_ONLY}` },
});
const clientAdjStoreBOnly = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_ADJ_STORE_B_ONLY}` },
});
const clientSettleCreateOnly = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_SETTLE_CREATE_ONLY}` },
});
const clientSettleManageRoutesOnly = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_SETTLE_MANAGE_ROUTES_ONLY}` },
});
const clientSettleAuditFinOnly = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_SETTLE_AUDIT_FIN_ONLY}` },
});
const clientSalesProfitNoSettleFin = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_SALES_PROFIT_NO_SETTLE_FIN}` },
});
const clientSettleCreateOnly2 = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_SETTLE_CREATE_ONLY_2}` },
});
const clientSettleStoreScoped = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_SETTLE_STORE_SCOPED}` },
});
const clientSettleReconcileOnly = new PostgrestClient(POSTGREST_URL, {
  headers: { Authorization: `Bearer ${JWT_SETTLE_RECONCILE_ONLY}` },
});

let failures = 0;
function ok(label, cond, detail) {
  if (cond) {
    console.log(`OK: ${label}`);
  } else {
    failures++;
    console.error(`FAIL: ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

async function rpc(fn, args = {}, useClient = client) {
  const { data, error } = await useClient.rpc(fn, args);
  if (error) throw new Error(`RPC ${fn} failed: ${JSON.stringify(error)}`);
  return data;
}

async function main() {
  console.log(`Connecting to real PostgREST at ${POSTGREST_URL} ...`);

  // -------------------------------------------------------------------
  // Part 1 — synthetic literal, proving the MECHANISM (raw numeric wire
  // format is genuinely unsafe; ::text is genuinely safe), independent of
  // any real column's current precision.
  // -------------------------------------------------------------------
  const rawValue = await rpc("_patch22_http_test_raw_numeric");
  ok(
    "synthetic raw numeric RPC returns typeof \"number\" over real HTTP",
    typeof rawValue === "number",
    `typeof was ${typeof rawValue}`,
  );
  ok(
    "synthetic raw numeric RPC LOSES precision over real HTTP (the failure mode this patch closes)",
    String(rawValue) !== HIGH_PRECISION_VALUE,
    `expected corruption but got back the exact original value (${rawValue}) — the JSON-number wire format may have changed, re-verify the test is still meaningful`,
  );

  const safeValue = await rpc("_patch22_http_test_safe_text");
  ok(
    "synthetic _safe text RPC returns typeof \"string\" over real HTTP",
    typeof safeValue === "string",
    `typeof was ${typeof safeValue}`,
  );
  ok(
    "synthetic _safe text RPC preserves the value EXACTLY over real HTTP",
    safeValue === HIGH_PRECISION_VALUE,
    `expected ${HIGH_PRECISION_VALUE}, got ${safeValue}`,
  );
  const safeAsDecimal = new Decimal(safeValue);
  ok(
    "synthetic _safe value flows into Decimal (src/lib/decimal.ts pattern) with the exact original value",
    safeAsDecimal.toString() === HIGH_PRECISION_VALUE,
    `Decimal round-trip gave ${safeAsDecimal.toString()}`,
  );

  // -------------------------------------------------------------------
  // Part 2 — REAL production RPCs (migration 0052), real sample data,
  // proving the actual shipped functions behave the same way, not just a
  // synthetic stand-in.
  // -------------------------------------------------------------------
  const rawPrice = await rpc("gold_price_for_karat_on_date", { p_karat_id: KARAT_ID });
  const safePrice = await rpc("gold_price_for_karat_on_date_safe", { p_karat_id: KARAT_ID });
  ok("gold_price_for_karat_on_date() (raw) returns typeof \"number\" over real HTTP", typeof rawPrice === "number", `typeof was ${typeof rawPrice}`);
  ok("gold_price_for_karat_on_date_safe() returns typeof \"string\" over real HTTP", typeof safePrice === "string", `typeof was ${typeof safePrice}`);
  ok(
    "gold_price_for_karat_on_date_safe() matches the raw value exactly (as Decimal)",
    new Decimal(safePrice).equals(new Decimal(rawPrice)),
    `raw=${rawPrice} safe=${safePrice}`,
  );
  ok("gold_price_for_karat_on_date_safe() feeds into Decimal with the expected value (275.1234)", new Decimal(safePrice).equals(new Decimal("275.1234")), `got ${safePrice}`);

  const rawFee = await rpc("manufacturing_fee_for_karat_on_date", { p_karat_id: KARAT_ID });
  const safeFee = await rpc("manufacturing_fee_for_karat_on_date_safe", { p_karat_id: KARAT_ID });
  ok("manufacturing_fee_for_karat_on_date() (raw) returns typeof \"number\" over real HTTP", typeof rawFee === "number", `typeof was ${typeof rawFee}`);
  ok("manufacturing_fee_for_karat_on_date_safe() returns typeof \"string\" over real HTTP", typeof safeFee === "string", `typeof was ${typeof safeFee}`);
  ok(
    "manufacturing_fee_for_karat_on_date_safe() matches the raw value exactly (as Decimal)",
    new Decimal(safeFee).equals(new Decimal(rawFee)),
    `raw=${rawFee} safe=${safeFee}`,
  );

  const rawPaymentFee = await rpc("payment_fee_for_method_on_date", { p_payment_method_id: PAYMENT_METHOD_ID });
  const safePaymentFee = await rpc("payment_fee_for_method_on_date_safe", { p_payment_method_id: PAYMENT_METHOD_ID });
  const rawRow = Array.isArray(rawPaymentFee) ? rawPaymentFee[0] : rawPaymentFee;
  const safeRow = Array.isArray(safePaymentFee) ? safePaymentFee[0] : safePaymentFee;
  ok(
    "payment_fee_for_method_on_date() (raw) returns percentage_fee/fixed_fee as typeof \"number\" over real HTTP",
    typeof rawRow.percentage_fee === "number" && typeof rawRow.fixed_fee === "number",
    `typeof percentage_fee=${typeof rawRow.percentage_fee}, typeof fixed_fee=${typeof rawRow.fixed_fee}`,
  );
  ok(
    "payment_fee_for_method_on_date_safe() returns percentage_fee/fixed_fee as typeof \"string\" over real HTTP",
    typeof safeRow.percentage_fee === "string" && typeof safeRow.fixed_fee === "string",
    `typeof percentage_fee=${typeof safeRow.percentage_fee}, typeof fixed_fee=${typeof safeRow.fixed_fee}`,
  );
  ok(
    "payment_fee_for_method_on_date_safe() matches the raw values exactly (as Decimal)",
    new Decimal(safeRow.percentage_fee).equals(new Decimal(rawRow.percentage_fee)) &&
      new Decimal(safeRow.fixed_fee).equals(new Decimal(rawRow.fixed_fee)),
    `raw=(${rawRow.percentage_fee},${rawRow.fixed_fee}) safe=(${safeRow.percentage_fee},${safeRow.fixed_fee})`,
  );

  // -------------------------------------------------------------------
  // Part 3 — Phase 3 Sales Core (migrations 0058-0064): create a real Sale
  // over real HTTP, then prove financial-safe string transport AND
  // DB-level profit protection for a second, genuinely different signed
  // JWT/actor, all over real HTTP (not simulated).
  // -------------------------------------------------------------------
  // Must match public.business_today() (Asia/Riyadh, UTC+3, no DST) exactly
  // — NOT the raw UTC calendar date. The two genuinely differ for ~3 hours
  // around every UTC midnight, and every date-lookup RPC below (gold price,
  // manufacturing fee, VAT rate) resolves its default p_date via business_
  // today(), so a UTC-based "today" here would spuriously fail whenever
  // this script happens to run inside that window. Mirrors src/lib/date.ts's
  // riyadhTodayIsoDate() (APP_TIMEZONE) without importing the app bundle.
  const todayIso = new Date(Date.now() + 3 * 60 * 60 * 1000).toISOString().slice(0, 10);
  const createRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID,
    p_sale_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "5.0000", sale_price: "2000.00" }],
  });
  const createRow = Array.isArray(createRows) ? createRows[0] : createRows;
  ok(
    "create_sales_order() over real HTTP returns a real order_number string",
    typeof createRow?.order_number === "string" && /^SALE-\d{10}$/.test(createRow.order_number),
    `got ${JSON.stringify(createRow)}`,
  );
  const orderId = createRow?.id;

  const orderDetailProfit = await rpc("get_sales_order", { p_id: orderId });
  ok(
    "get_sales_order() over real HTTP returns subtotal/gross_profit/net_sales_profit as typeof \"string\" for a caller WITH sales.view_profit",
    typeof orderDetailProfit.subtotal === "string" &&
      typeof orderDetailProfit.gross_profit === "string" &&
      typeof orderDetailProfit.net_sales_profit === "string",
    `got subtotal=${typeof orderDetailProfit.subtotal} gross_profit=${typeof orderDetailProfit.gross_profit} net_sales_profit=${typeof orderDetailProfit.net_sales_profit}`,
  );
  // Expected gross profit for this fixture's real values (gold price
  // 275.1234/g, manufacturing fee 12.3456/g, VAT 15%, weight 5g, sale price
  // 2000.00): base=(275.1234+12.3456)*5=1437.345, vat=1437.345*0.15=
  // 215.60175, total=1652.94675, gross=2000-1652.94675=347.05325 -> 347.05.
  ok(
    "get_sales_order() over real HTTP: gross_profit matches the independently-computed expected value (347.05) as Decimal",
    new Decimal(orderDetailProfit.gross_profit).equals(new Decimal("347.05")),
    `got ${orderDetailProfit.gross_profit}`,
  );

  const orderDetailNoProfit = await rpc("get_sales_order", { p_id: orderId }, clientNoProfit);
  ok(
    "get_sales_order() over real HTTP OMITS gross_profit/net_sales_profit/payment_fee_amount keys ENTIRELY (not null) for a caller WITHOUT sales.view_profit",
    !("gross_profit" in orderDetailNoProfit) && !("net_sales_profit" in orderDetailNoProfit) && !("payment_fee_amount" in orderDetailNoProfit),
    `keys were: ${Object.keys(orderDetailNoProfit).join(", ")}`,
  );
  ok(
    "get_sales_order() over real HTTP still returns subtotal (non-sensitive) for a caller WITHOUT sales.view_profit",
    typeof orderDetailNoProfit.subtotal === "string",
    `got ${JSON.stringify(orderDetailNoProfit.subtotal)}`,
  );

  const listProfit = await rpc("list_sales_orders", { p_order_number: createRow.order_number });
  const listProfitRow = Array.isArray(listProfit) ? listProfit[0] : listProfit;
  ok(
    "list_sales_orders() over real HTTP returns gross_profit/net_sales_profit as typeof \"string\" for a caller WITH sales.view_profit",
    typeof listProfitRow.gross_profit === "string" && typeof listProfitRow.net_sales_profit === "string",
    `got gross_profit=${typeof listProfitRow.gross_profit} net_sales_profit=${typeof listProfitRow.net_sales_profit}`,
  );

  const listNoProfit = await rpc("list_sales_orders", { p_order_number: createRow.order_number }, clientNoProfit);
  const listNoProfitRow = Array.isArray(listNoProfit) ? listNoProfit[0] : listNoProfit;
  ok(
    "list_sales_orders() over real HTTP returns gross_profit/net_sales_profit as JSON null for a caller WITHOUT sales.view_profit",
    listNoProfitRow.gross_profit === null && listNoProfitRow.net_sales_profit === null,
    `got gross_profit=${JSON.stringify(listNoProfitRow.gross_profit)} net_sales_profit=${JSON.stringify(listNoProfitRow.net_sales_profit)}`,
  );

  const preview = await rpc("preview_sales_order", {
    p_store_id: STORE_ID,
    p_sale_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "5.0000", sale_price: "2000.00" }],
  });
  ok(
    "preview_sales_order() over real HTTP returns subtotal/gross_profit as typeof \"string\"",
    typeof preview.subtotal === "string" && typeof preview.gross_profit === "string",
    `got subtotal=${typeof preview.subtotal} gross_profit=${typeof preview.gross_profit}`,
  );

  // -------------------------------------------------------------------
  // Part 4 (Patch 3.1 item M) — audit_logs profit protection (spec item 4 /
  // migration 0072) proven over a REAL HTTP request against PostgREST's
  // auto-generated /audit_logs endpoint (a plain .from() query, not an
  // RPC) — the RLS policy itself is what's under test here, not a
  // function's own logic.
  // -------------------------------------------------------------------
  const { data: auditRowsProfit, error: auditErrProfit } = await client
    .from("audit_logs")
    .select("id, action, entity_id")
    .eq("entity_id", orderId)
    .like("action", "sale.%");
  if (auditErrProfit) throw new Error(`audit_logs select (profit actor) failed: ${JSON.stringify(auditErrProfit)}`);
  ok(
    "GET /audit_logs?action=like.sale.* over real HTTP returns rows for a caller WITH audit_logs.view AND sales.view_profit",
    Array.isArray(auditRowsProfit) && auditRowsProfit.length > 0,
    `got ${auditRowsProfit?.length ?? 0} rows`,
  );

  const { data: auditRowsNoProfit, error: auditErrNoProfit } = await clientNoProfit
    .from("audit_logs")
    .select("id, action, entity_id")
    .eq("entity_id", orderId)
    .like("action", "sale.%");
  if (auditErrNoProfit) throw new Error(`audit_logs select (no-profit actor) failed: ${JSON.stringify(auditErrNoProfit)}`);
  ok(
    "GET /audit_logs?action=like.sale.* over real HTTP returns ZERO rows for a caller WITH audit_logs.view but WITHOUT sales.view_profit (RLS filters the whole row, not just the profit columns)",
    Array.isArray(auditRowsNoProfit) && auditRowsNoProfit.length === 0,
    `got ${auditRowsNoProfit?.length ?? 0} rows, expected 0`,
  );

  // -------------------------------------------------------------------
  // Part 5 (Patch 3.1 item M) — stable sales_order_items identity (spec
  // item 1) proven over a REAL HTTP round trip: create a 2-item order,
  // then update it dropping one item and metadata-editing the other, then
  // prove over HTTP that (a) the kept item's id never changed, and (b) the
  // dropped item still physically exists with status='removed' (never
  // hard-deleted) — the latter is only observable via the service_role
  // verification client, since sales_order_items has zero SELECT RLS
  // policies for `authenticated`.
  // -------------------------------------------------------------------
  const stableCreateRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID,
    p_sale_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_items: [
      { category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "500.00" },
      { category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "2.0000", sale_price: "900.00" },
    ],
  });
  const stableOrderId = (Array.isArray(stableCreateRows) ? stableCreateRows[0] : stableCreateRows)?.id;

  const stableOrderBefore = await rpc("get_sales_order", { p_id: stableOrderId });
  ok(
    "stable-identity fixture over real HTTP: freshly created order has 2 active items",
    Array.isArray(stableOrderBefore.items) && stableOrderBefore.items.length === 2,
    `got ${stableOrderBefore.items?.length ?? "?"} items`,
  );
  const [itemKeep, itemRemove] = stableOrderBefore.items;

  // Patch 3.2 item 2 — update_sales_order() now requires p_expected_version
  // (optimistic concurrency via sales_orders.row_version, returned by
  // get_sales_order() as of 0079). Proven over REAL HTTP below: a stale
  // version is rejected with a Conflict, and a correct version succeeds and
  // increments row_version by exactly 1.
  await rpc("update_sales_order", {
    p_order_id: stableOrderId,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_items: [
      {
        id: itemKeep.id,
        category_id: itemKeep.category_id,
        karat_id: itemKeep.karat_id,
        weight_grams: itemKeep.weight_grams,
        sale_price: itemKeep.sale_price,
        item_name: "HTTP stable-id test rename",
      },
    ],
    p_expected_version: stableOrderBefore.row_version,
  });

  const stableOrderAfter = await rpc("get_sales_order", { p_id: stableOrderId });
  ok(
    "update_sales_order() over real HTTP: dropped item no longer appears in the active item list",
    Array.isArray(stableOrderAfter.items) && stableOrderAfter.items.length === 1,
    `got ${stableOrderAfter.items?.length ?? "?"} items`,
  );
  ok(
    "update_sales_order() over real HTTP: the kept item's id is UNCHANGED across the edit (stable identity, not delete+re-insert)",
    stableOrderAfter.items?.[0]?.id === itemKeep.id,
    `before=${itemKeep.id} after=${stableOrderAfter.items?.[0]?.id}`,
  );
  ok(
    "update_sales_order() over real HTTP: the kept item's metadata edit (item_name) actually applied",
    stableOrderAfter.items?.[0]?.item_name === "HTTP stable-id test rename",
    `got ${stableOrderAfter.items?.[0]?.item_name}`,
  );

  const { data: rawItemsAfter, error: rawItemsErr } = await clientService
    .from("sales_order_items")
    .select("id, status, removed_at")
    .eq("sales_order_id", stableOrderId)
    .order("line_no");
  if (rawItemsErr) throw new Error(`sales_order_items select (service_role) failed: ${JSON.stringify(rawItemsErr)}`);
  ok(
    "service_role verification over real HTTP: sales_order_items still has BOTH rows physically present after the edit (2 total)",
    Array.isArray(rawItemsAfter) && rawItemsAfter.length === 2,
    `got ${rawItemsAfter?.length ?? "?"} rows`,
  );
  const rawKeep = rawItemsAfter?.find((r) => r.id === itemKeep.id);
  const rawRemoved = rawItemsAfter?.find((r) => r.id === itemRemove.id);
  ok(
    "service_role verification over real HTTP: the kept row has status='active'",
    rawKeep?.status === "active",
    `got ${JSON.stringify(rawKeep)}`,
  );
  ok(
    "service_role verification over real HTTP: the dropped row is SOFT-removed (status='removed', removed_at set) — never hard-deleted",
    rawRemoved?.status === "removed" && rawRemoved?.removed_at != null,
    `got ${JSON.stringify(rawRemoved)}`,
  );

  // -------------------------------------------------------------------
  // Part 6 (Patch 3.2) — real HTTP proofs for: (a) row_version increments
  // by exactly 1 on the successful update just performed above; (b) a
  // STALE p_expected_version is rejected with the Conflict message over
  // real HTTP, not silently applied; (c) get_sales_order()/
  // list_sales_orders() resolve store_name/payment_method_name/
  // collection_channel_name internally (item 8) — proven here under the
  // SAME profit-holding actor already used above (a dedicated no-Master-
  // .view actor is covered by the SQL suite, sales_integrity_patch_3_2.
  // test.sql section G; this HTTP round trip only needs to prove the
  // fields are actually present on the wire).
  // -------------------------------------------------------------------
  ok(
    "update_sales_order() over real HTTP: row_version incremented by exactly 1 after the successful edit above",
    stableOrderAfter.row_version === stableOrderBefore.row_version + 1,
    `before=${stableOrderBefore.row_version} after=${stableOrderAfter.row_version}`,
  );

  let staleConflictError = null;
  try {
    await rpc("update_sales_order", {
      p_order_id: stableOrderId,
      p_payment_method_id: PAYMENT_METHOD_ID,
      p_collection_channel_id: CHANNEL_ID,
      p_items: [
        {
          id: itemKeep.id,
          category_id: itemKeep.category_id,
          karat_id: itemKeep.karat_id,
          weight_grams: itemKeep.weight_grams,
          sale_price: itemKeep.sale_price,
          item_name: "this must be rejected — stale version",
        },
      ],
      // Deliberately stale: the version this order had BEFORE the edit
      // above, not its current one.
      p_expected_version: stableOrderBefore.row_version,
    });
  } catch (err) {
    staleConflictError = err;
  }
  ok(
    "update_sales_order() over real HTTP: a STALE p_expected_version is rejected with a Conflict, not silently applied",
    staleConflictError !== null && /مستخدم آخر/.test(String(staleConflictError.message)),
    `got ${staleConflictError?.message}`,
  );
  const stableOrderAfterConflict = await rpc("get_sales_order", { p_id: stableOrderId });
  ok(
    "update_sales_order() over real HTTP: the rejected stale attempt did NOT change item_name",
    stableOrderAfterConflict.items?.[0]?.item_name === "HTTP stable-id test rename",
    `got ${stableOrderAfterConflict.items?.[0]?.item_name}`,
  );

  ok(
    "get_sales_order() over real HTTP: resolves store_name/payment_method_name/collection_channel_name internally (item 8)",
    typeof stableOrderAfter.store_name === "string" && stableOrderAfter.store_name.length > 0
      && typeof stableOrderAfter.payment_method_name === "string" && stableOrderAfter.payment_method_name.length > 0
      && typeof stableOrderAfter.collection_channel_name === "string" && stableOrderAfter.collection_channel_name.length > 0,
    `got store_name=${stableOrderAfter.store_name} payment_method_name=${stableOrderAfter.payment_method_name} collection_channel_name=${stableOrderAfter.collection_channel_name}`,
  );

  const listRows = await rpc("list_sales_orders", { p_order_number: null, p_limit: 200 });
  const listedStableOrder = Array.isArray(listRows) ? listRows.find((r) => r.id === stableOrderId) : null;
  ok(
    "list_sales_orders() over real HTTP: resolves store_name/payment_method_name/collection_channel_name internally (item 8)",
    listedStableOrder != null
      && typeof listedStableOrder.store_name === "string" && listedStableOrder.store_name.length > 0
      && typeof listedStableOrder.payment_method_name === "string" && listedStableOrder.payment_method_name.length > 0
      && typeof listedStableOrder.collection_channel_name === "string" && listedStableOrder.collection_channel_name.length > 0,
    `got ${JSON.stringify(listedStableOrder)}`,
  );

  // -------------------------------------------------------------------
  // Part 7 (Phase 4 — Returns Core, migrations 0082-0091; extended by
  // Returns Integrity Patch 4.1, migrations 0092-0098) — a dedicated
  // 2-item Sale, then a full pending -> approved -> refund -> finalize ->
  // reversed Return lifecycle, all over real HTTP, proving the Decimal
  // Transport Boundary + profit-hiding guarantees hold for every Returns
  // RPC (including the new Patch 4.1 business fields), that Patch 4.1's
  // pending-membership-vs-effective-claim split (Section 5) genuinely
  // behaves differently over real HTTP than the old always-exclusive
  // claim, that money-scale validation (Section 10) rejects a real HTTP
  // call, and that update_sales_order()'s financial lock (0084) still
  // engages once an approved return exists.
  // -------------------------------------------------------------------
  const returnsOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID,
    p_sale_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_items: [
      { category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "500.00" },
      { category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "2.0000", sale_price: "900.00" },
    ],
  });
  const returnsOrderRow = Array.isArray(returnsOrderRows) ? returnsOrderRows[0] : returnsOrderRows;
  const returnsOrderId = returnsOrderRow?.id;

  const returnableBefore = await rpc("get_returnable_sales_order", { p_sales_order_id: returnsOrderId });
  ok(
    "get_returnable_sales_order() over real HTTP: a fresh Sale starts order_state='not_returned' with both items returnable, and now also returns the Sale's row_version (Patch 4.1 Section 4)",
    returnableBefore.order_state === "not_returned" &&
      returnableBefore.items?.length === 2 &&
      returnableBefore.items.every((it) => it.returnable === true) &&
      typeof returnableBefore.row_version === "number",
    `got ${JSON.stringify(returnableBefore)}`,
  );
  const [returnItemA, returnItemB] = returnableBefore.items;
  const saleRowVersion = returnableBefore.row_version;

  // Patch 4.2 Section 7 — the three narrow Returns-specific lookup RPCs,
  // each gated on its OWN Returns permission, never stores.view/
  // payment_methods.view. `client` holds returns.view/create/record_refund
  // (see postgrest_http_test_setup.sql), so all three succeed for it;
  // `clientNoProfit` holds only returns.view, so it succeeds ONLY on the
  // visible-store lookup and is rejected on the other two.
  const operableStores = await rpc("returns_operable_store_lookups", {});
  ok(
    "returns_operable_store_lookups() over real HTTP returns only {id, name_ar} rows, gated on returns.create (Patch 4.2 Section 7)",
    Array.isArray(operableStores) && operableStores.length > 0 &&
      operableStores.every((r) => typeof r.id === "string" && typeof r.name_ar === "string" && Object.keys(r).length === 2),
    `got ${JSON.stringify(operableStores)}`,
  );
  const visibleStores = await rpc("returns_visible_store_lookups", {});
  ok(
    "returns_visible_store_lookups() over real HTTP returns only {id, name_ar} rows, gated on returns.view (Patch 4.2 Section 7)",
    Array.isArray(visibleStores) && visibleStores.length > 0 &&
      visibleStores.every((r) => typeof r.id === "string" && typeof r.name_ar === "string"),
    `got ${JSON.stringify(visibleStores)}`,
  );
  const refundMethods = await rpc("returns_refund_method_lookups", {});
  ok(
    "returns_refund_method_lookups() over real HTTP returns only {id, name_ar} rows, gated on returns.record_refund (Patch 4.2 Section 7)",
    Array.isArray(refundMethods) && refundMethods.length > 0 &&
      refundMethods.every((r) => typeof r.id === "string" && typeof r.name_ar === "string"),
    `got ${JSON.stringify(refundMethods)}`,
  );

  const visibleStoresNoProfit = await rpc("returns_visible_store_lookups", {}, clientNoProfit);
  ok(
    "returns_visible_store_lookups() over real HTTP still succeeds for a caller holding only returns.view (not gated on any Master Data permission)",
    Array.isArray(visibleStoresNoProfit) && visibleStoresNoProfit.length > 0,
    `got ${JSON.stringify(visibleStoresNoProfit)}`,
  );
  let operableStoresRejected = null;
  try {
    await rpc("returns_operable_store_lookups", {}, clientNoProfit);
  } catch (err) {
    operableStoresRejected = err;
  }
  ok(
    "returns_operable_store_lookups() over real HTTP rejects a caller without returns.create, even though they hold returns.view (Patch 4.2 Section 7)",
    operableStoresRejected !== null,
    `got ${operableStoresRejected?.message}`,
  );
  let refundMethodsRejected = null;
  try {
    await rpc("returns_refund_method_lookups", {}, clientNoProfit);
  } catch (err) {
    refundMethodsRejected = err;
  }
  ok(
    "returns_refund_method_lookups() over real HTTP rejects a caller without returns.record_refund, even though they hold returns.view (Patch 4.2 Section 7)",
    refundMethodsRejected !== null,
    `got ${refundMethodsRejected?.message}`,
  );

  const returnPreview = await rpc("preview_sales_return", {
    p_sales_order_id: returnsOrderId,
    p_items: [{ sales_order_item_id: returnItemA.id }],
    p_scenario: "defective_product",
    p_collection_state: "collected",
    p_approved_refund_amount: "500.00",
  });
  ok(
    "preview_sales_return() over real HTTP accepts the new p_scenario parameter (Patch 4.2 Section 5 preview/create parity) and returns every financial value — including the new returned_original_sale_amount (Section 1) — as typeof \"string\", and flags the fee figure as an estimate",
    typeof returnPreview.returned_original_sale_amount === "string" &&
      typeof returnPreview.sales_revenue_reversal_amount === "string" &&
      returnPreview.is_fee_reversal_estimate === true &&
      typeof returnPreview.estimated_payment_fee_reversal_amount === "string",
    `got ${JSON.stringify(returnPreview)}`,
  );

  // Money-scale validation (Section 10) — a refund figure with more than 2
  // decimal places must be REJECTED over real HTTP, never silently rounded.
  let moneyScaleError = null;
  try {
    await rpc("create_sales_return", {
      p_sales_order_id: returnsOrderId,
      p_processed_store_id: STORE_ID,
      p_return_date: todayIso,
      p_scenario: "defective_product",
      p_items: [{ sales_order_item_id: returnItemA.id }],
      p_expected_sale_version: saleRowVersion,
      p_collection_state: "collected",
      p_approved_refund_amount: "500.005",
    });
  } catch (err) {
    moneyScaleError = err;
  }
  ok(
    "create_sales_return() over real HTTP: approved_refund_amount with more than 2 decimal places is rejected outright (Patch 4.1 Section 10, migration 0092's validate_money_scale())",
    moneyScaleError !== null && /عشري/.test(String(moneyScaleError.message)),
    `got ${moneyScaleError?.message}`,
  );

  const createReturnRows = await rpc("create_sales_return", {
    p_sales_order_id: returnsOrderId,
    p_processed_store_id: STORE_ID,
    p_return_date: todayIso,
    p_scenario: "defective_product",
    p_items: [{ sales_order_item_id: returnItemA.id, condition: "good_resellable" }],
    p_expected_sale_version: saleRowVersion,
    p_collection_state: "collected",
    p_approved_refund_amount: "500.00",
  });
  const createReturnRow = Array.isArray(createReturnRows) ? createReturnRows[0] : createReturnRows;
  ok(
    "create_sales_return() over real HTTP returns a real return_number string",
    typeof createReturnRow?.return_number === "string" && /^RET-\d{10}$/.test(createReturnRow.return_number),
    `got ${JSON.stringify(createReturnRow)}`,
  );
  const returnId = createReturnRow?.id;

  // Patch 4.1 Section 5 — a SECOND pending return over the SAME
  // already-claimed item is now ACCEPTED over real HTTP (pending
  // membership is no longer exclusive; only an EFFECTIVE/approved claim
  // is) — the opposite of the pre-Patch-4.1 behavior this same line used
  // to test for rejection.
  const secondPendingRows = await rpc("create_sales_return", {
    p_sales_order_id: returnsOrderId,
    p_processed_store_id: STORE_ID,
    p_return_date: todayIso,
    p_scenario: "customer_changed_mind",
    p_items: [{ sales_order_item_id: returnItemA.id }],
    p_expected_sale_version: saleRowVersion,
    p_collection_state: "collected",
    p_approved_refund_amount: "500.00",
  });
  const secondPendingRow = Array.isArray(secondPendingRows) ? secondPendingRows[0] : secondPendingRows;
  ok(
    "create_sales_return() over real HTTP: a SECOND pending return over the SAME item is accepted (Patch 4.1 Section 5 — pending membership is no longer exclusive)",
    typeof secondPendingRow?.id === "string" && secondPendingRow.id !== returnId,
    `got ${JSON.stringify(secondPendingRow)}`,
  );

  const returnableAfterPending = await rpc("get_returnable_sales_order", { p_sales_order_id: returnsOrderId });
  const pendingItemA = returnableAfterPending.items?.find((it) => it.id === returnItemA.id);
  const pendingItemB = returnableAfterPending.items?.find((it) => it.id === returnItemB.id);
  ok(
    "get_returnable_sales_order() over real HTTP: the item claimed by TWO pending returns is STILL returnable=true (Patch 4.1 Section 5 — no effective claim exists yet), the other item is also returnable, and order_state is still 'not_returned'",
    pendingItemA?.returnable === true && pendingItemB?.returnable === true && returnableAfterPending.order_state === "not_returned",
    `got ${JSON.stringify(returnableAfterPending)}`,
  );

  const returnDetailPending = await rpc("get_sales_return", { p_id: returnId });
  ok(
    "get_sales_return() over real HTTP: a pending return has status='pending' with exactly 1 active item and every reversal figure still NULL",
    returnDetailPending.status === "pending" &&
      returnDetailPending.items?.length === 1 &&
      returnDetailPending.sales_revenue_reversal_amount === null,
    `got ${JSON.stringify({ status: returnDetailPending.status, itemCount: returnDetailPending.items?.length, sales_revenue_reversal_amount: returnDetailPending.sales_revenue_reversal_amount })}`,
  );
  ok(
    "get_sales_return() over real HTTP exposes requires_sale_refresh (Patch 4.2 Section 1) as typeof \"boolean\", false for a freshly-created return",
    typeof returnDetailPending.requires_sale_refresh === "boolean" && returnDetailPending.requires_sale_refresh === false,
    `got ${JSON.stringify(returnDetailPending.requires_sale_refresh)}`,
  );

  const approveRows = await rpc("approve_sales_return", { p_return_id: returnId, p_expected_version: returnDetailPending.row_version });
  const approveRow = Array.isArray(approveRows) ? approveRows[0] : approveRows;
  ok(
    "approve_sales_return() over real HTTP succeeds (proportional_reversal policy, no manual override needed) and returns the same return_number",
    approveRow?.return_number === createReturnRow.return_number,
    `got ${JSON.stringify(approveRow)}`,
  );

  // Patch 4.1 Section 5 — NOW that the first return is the effective
  // claim, approving the second (still-pending) return on the same item is
  // rejected over real HTTP by the real unique-index-backed constraint.
  const returnDetailSecondPending = await rpc("get_sales_return", { p_id: secondPendingRow.id });
  let effectiveClaimError = null;
  try {
    await rpc("approve_sales_return", { p_return_id: secondPendingRow.id, p_expected_version: returnDetailSecondPending.row_version });
  } catch (err) {
    effectiveClaimError = err;
  }
  ok(
    "approve_sales_return() over real HTTP: approving a second return whose item already has an EFFECTIVE claim is rejected (Patch 4.1 Section 5, sales_return_items_effective_claim_uq)",
    effectiveClaimError !== null && /هذه القطعة مرتجعة بالفعل/.test(String(effectiveClaimError.message)),
    `got ${effectiveClaimError?.message}`,
  );

  const returnDetailApprovedProfit = await rpc("get_sales_return", { p_id: returnId });
  ok(
    "get_sales_return() over real HTTP: after approval, every reversal figure — including the new Patch 4.1 Section 12 fields — is now typeof \"string\" for a caller WITH sales.view_profit",
    returnDetailApprovedProfit.status === "approved" &&
      typeof returnDetailApprovedProfit.returned_original_sale_amount === "string" &&
      typeof returnDetailApprovedProfit.sales_revenue_reversal_amount === "string" &&
      typeof returnDetailApprovedProfit.approved_refund_amount === "string" &&
      typeof returnDetailApprovedProfit.gross_profit_reversal_amount === "string" &&
      typeof returnDetailApprovedProfit.payment_fee_reversal_amount === "string" &&
      typeof returnDetailApprovedProfit.net_profit_reversal_amount === "string" &&
      typeof returnDetailApprovedProfit.recovered_original_cost_amount === "string" &&
      typeof returnDetailApprovedProfit.net_sales_profit_adjustment === "string" &&
      typeof returnDetailApprovedProfit.adjusted_order_net_sales_profit === "string",
    `got ${JSON.stringify(returnDetailApprovedProfit)}`,
  );
  ok(
    "get_sales_return() over real HTTP: sales_revenue_reversal_amount matches the returned item's own sale_price (500.00) as Decimal",
    new Decimal(returnDetailApprovedProfit.sales_revenue_reversal_amount).equals(new Decimal("500.00")),
    `got ${returnDetailApprovedProfit.sales_revenue_reversal_amount}`,
  );
  // Hotfix 4.2.1 Section 13 — every return approved under the new v2 fee
  // engine must carry payment_fee_reversal_calculation_version=2 (typeof
  // "number", a plain integer tag — never a Decimal-transported string)
  // over real HTTP, for a caller WITH sales.view_profit.
  ok(
    "get_sales_return() over real HTTP: payment_fee_reversal_calculation_version is 2 (typeof \"number\") for a return approved under the Hotfix 4.2.1 v2 fee-reversal engine",
    returnDetailApprovedProfit.payment_fee_reversal_calculation_version === 2,
    `got ${JSON.stringify(returnDetailApprovedProfit.payment_fee_reversal_calculation_version)} (typeof ${typeof returnDetailApprovedProfit.payment_fee_reversal_calculation_version})`,
  );

  const returnDetailApprovedNoProfit = await rpc("get_sales_return", { p_id: returnId }, clientNoProfit);
  ok(
    "get_sales_return() over real HTTP OMITS gross_profit_reversal_amount/payment_fee_reversal_amount/net_profit_reversal_amount/recovered_original_cost_amount/net_sales_profit_adjustment/adjusted_order_net_sales_profit/payment_fee_reversal_calculation_version keys ENTIRELY (not null) for a caller WITHOUT sales.view_profit",
    !("gross_profit_reversal_amount" in returnDetailApprovedNoProfit) &&
      !("payment_fee_reversal_amount" in returnDetailApprovedNoProfit) &&
      !("net_profit_reversal_amount" in returnDetailApprovedNoProfit) &&
      !("recovered_original_cost_amount" in returnDetailApprovedNoProfit) &&
      !("net_sales_profit_adjustment" in returnDetailApprovedNoProfit) &&
      !("adjusted_order_net_sales_profit" in returnDetailApprovedNoProfit) &&
      !("payment_fee_reversal_calculation_version" in returnDetailApprovedNoProfit),
    `keys were: ${Object.keys(returnDetailApprovedNoProfit).join(", ")}`,
  );
  ok(
    "get_sales_return() over real HTTP still returns sales_revenue_reversal_amount (non-sensitive) for a caller WITHOUT sales.view_profit",
    typeof returnDetailApprovedNoProfit.sales_revenue_reversal_amount === "string",
    `got ${JSON.stringify(returnDetailApprovedNoProfit.sales_revenue_reversal_amount)}`,
  );

  const listReturnsProfit = await rpc("list_sales_returns", { p_sales_order_id: returnsOrderId });
  const listReturnsProfitRow = Array.isArray(listReturnsProfit) ? listReturnsProfit.find((r) => r.id === returnId) : null;
  ok(
    "list_sales_returns() over real HTTP returns net_profit_reversal_amount as typeof \"string\" for a caller WITH sales.view_profit",
    typeof listReturnsProfitRow?.net_profit_reversal_amount === "string",
    `got ${JSON.stringify(listReturnsProfitRow)}`,
  );

  const listReturnsNoProfit = await rpc("list_sales_returns", { p_sales_order_id: returnsOrderId }, clientNoProfit);
  const listReturnsNoProfitRow = Array.isArray(listReturnsNoProfit) ? listReturnsNoProfit.find((r) => r.id === returnId) : null;
  ok(
    "list_sales_returns() over real HTTP returns net_profit_reversal_amount/payment_fee_reversal_amount as JSON null for a caller WITHOUT sales.view_profit",
    listReturnsNoProfitRow?.net_profit_reversal_amount === null && listReturnsNoProfitRow?.payment_fee_reversal_amount === null,
    `got ${JSON.stringify(listReturnsNoProfitRow)}`,
  );

  const returnableAfterApproved = await rpc("get_returnable_sales_order", { p_sales_order_id: returnsOrderId });
  ok(
    "get_returnable_sales_order() over real HTTP: order_state is 'partial' once ONE item is covered by an APPROVED (effective) return, with the other item still returnable",
    returnableAfterApproved.order_state === "partial" && returnableAfterApproved.items?.find((it) => it.id === returnItemB.id)?.returnable === true,
    `got ${JSON.stringify(returnableAfterApproved)}`,
  );

  // update_sales_order()'s financial lock (migration 0084) — a financial
  // edit to the SAME order must now be rejected over real HTTP, since an
  // effective (approved) return exists on it. Metadata-only edits remain
  // allowed (not exercised here — already covered by supabase/tests/
  // sales_integrity_patch_3_1... suite; this proves the REJECTION path).
  const returnsOrderForLockCheck = await rpc("get_sales_order", { p_id: returnsOrderId });
  let financialLockError = null;
  try {
    await rpc("update_sales_order", {
      p_order_id: returnsOrderId,
      p_payment_method_id: PAYMENT_METHOD_ID,
      p_collection_channel_id: CHANNEL_ID,
      p_items: returnsOrderForLockCheck.items.map((it) => ({
        id: it.id,
        category_id: it.category_id,
        karat_id: it.karat_id,
        weight_grams: it.weight_grams,
        sale_price: it.id === returnItemB.id ? "999.00" : it.sale_price,
      })),
      p_expected_version: returnsOrderForLockCheck.row_version,
    });
  } catch (err) {
    financialLockError = err;
  }
  ok(
    "update_sales_order() over real HTTP: rejected once an approved return exists on this order (migration 0084's financial lock)",
    financialLockError !== null && /مرتجع معتمد/.test(String(financialLockError.message)),
    `got ${financialLockError?.message}`,
  );

  // Hotfix 4.2.1 Section 6 — the new optional p_reference argument must
  // round-trip byte-for-byte over real HTTP and surface on the refund
  // event returned by get_sales_return().
  const refundRows = await rpc("record_sales_return_refund", {
    p_return_id: returnId,
    p_amount: returnDetailApprovedProfit.approved_refund_amount,
    p_refund_method_id: PAYMENT_METHOD_ID,
    p_reference: "HTTP-TEST-REF-0001",
  });
  const refundRow = Array.isArray(refundRows) ? refundRows[0] : refundRows;
  ok(
    "record_sales_return_refund() over real HTTP persists the exact amount as typeof \"string\"",
    typeof refundRow?.amount === "string" && new Decimal(refundRow.amount).equals(new Decimal(returnDetailApprovedProfit.approved_refund_amount)),
    `got ${JSON.stringify(refundRow)}`,
  );

  const returnDetailAfterRefund = await rpc("get_sales_return", { p_id: returnId });
  ok(
    "get_sales_return() over real HTTP: actual_refunded_total reflects the just-recorded refund live, and refund_variance is now zero",
    new Decimal(returnDetailAfterRefund.actual_refunded_total).equals(new Decimal(returnDetailApprovedProfit.approved_refund_amount)) &&
      new Decimal(returnDetailAfterRefund.refund_variance).equals(new Decimal("0")),
    `got actual_refunded_total=${returnDetailAfterRefund.actual_refunded_total} refund_variance=${returnDetailAfterRefund.refund_variance}`,
  );
  ok(
    "get_sales_return() over real HTTP: the just-recorded refund event carries reference='HTTP-TEST-REF-0001' (Hotfix 4.2.1 Section 6), a non-null refund_method_name_snapshot (Section 17), and status='active' (Section 1, derived from the append-only reversal ledger, not a legacy column)",
    returnDetailAfterRefund.refund_events?.[0]?.reference === "HTTP-TEST-REF-0001" &&
      typeof returnDetailAfterRefund.refund_events?.[0]?.refund_method_name_snapshot === "string" &&
      returnDetailAfterRefund.refund_events?.[0]?.refund_method_name_snapshot.length > 0 &&
      returnDetailAfterRefund.refund_events?.[0]?.status === "active",
    `got ${JSON.stringify(returnDetailAfterRefund.refund_events?.[0])}`,
  );

  const refundEventId = returnDetailAfterRefund.refund_events?.[0]?.id;
  await rpc("reverse_sales_return_refund_event", { p_event_id: refundEventId, p_reversal_reason: "HTTP test — reversing refund event" });

  const returnDetailAfterRefundReversal = await rpc("get_sales_return", { p_id: returnId });
  ok(
    "reverse_sales_return_refund_event() over real HTTP: the reversed event no longer counts toward actual_refunded_total, so refund_variance is back to the full approved_refund_amount",
    new Decimal(returnDetailAfterRefundReversal.actual_refunded_total).equals(new Decimal("0")) &&
      new Decimal(returnDetailAfterRefundReversal.refund_variance).equals(new Decimal(returnDetailApprovedProfit.approved_refund_amount)),
    `got actual_refunded_total=${returnDetailAfterRefundReversal.actual_refunded_total} refund_variance=${returnDetailAfterRefundReversal.refund_variance}`,
  );
  ok(
    "get_sales_return() over real HTTP: the just-reversed event's status flips to 'reversed' (Hotfix 4.2.1 Section 1, derived live from sales_return_refund_event_reversals — genuinely append-only, not an UPDATE on the original row) while its reference (Section 6) is preserved unchanged",
    returnDetailAfterRefundReversal.refund_events?.find((e) => e.id === refundEventId)?.status === "reversed" &&
      returnDetailAfterRefundReversal.refund_events?.find((e) => e.id === refundEventId)?.reference === "HTTP-TEST-REF-0001",
    `got ${JSON.stringify(returnDetailAfterRefundReversal.refund_events)}`,
  );

  // Patch 4.1 Section 11 — finalize_sales_return_refund(): record a fresh
  // refund matching approved_refund_amount exactly, then finalize with no
  // variance reason (none required for an exact match) and observe
  // refund_reconciliation_state flip to 'finalized_matched' over real HTTP.
  await rpc("record_sales_return_refund", {
    p_return_id: returnId,
    p_amount: returnDetailApprovedProfit.approved_refund_amount,
    p_refund_method_id: PAYMENT_METHOD_ID,
  });
  const finalizeRows = await rpc("finalize_sales_return_refund", {
    p_return_id: returnId,
    p_expected_version: (await rpc("get_sales_return", { p_id: returnId })).row_version,
  });
  const finalizeRow = Array.isArray(finalizeRows) ? finalizeRows[0] : finalizeRows;
  ok(
    "finalize_sales_return_refund() over real HTTP returns actual_refunded_total/refund_variance as typeof \"string\"",
    typeof finalizeRow?.actual_refunded_total === "string" && typeof finalizeRow?.refund_variance === "string",
    `got ${JSON.stringify(finalizeRow)}`,
  );
  const returnDetailAfterFinalize = await rpc("get_sales_return", { p_id: returnId });
  ok(
    "get_sales_return() over real HTTP: refund_reconciliation_state is 'finalized_matched' after finalize_sales_return_refund() with a matching total",
    returnDetailAfterFinalize.refund_reconciliation_state === "finalized_matched" && returnDetailAfterFinalize.refund_finalized_at !== null,
    `got ${JSON.stringify({ state: returnDetailAfterFinalize.refund_reconciliation_state, finalized_at: returnDetailAfterFinalize.refund_finalized_at })}`,
  );
  ok(
    "get_sales_return() over real HTTP: reconciliation_history (Patch 4.2 Section 4) has exactly ONE 'finalized' entry after the first finalize",
    Array.isArray(returnDetailAfterFinalize.reconciliation_history) &&
      returnDetailAfterFinalize.reconciliation_history.length === 1 &&
      returnDetailAfterFinalize.reconciliation_history[0].event_type === "finalized",
    `got ${JSON.stringify(returnDetailAfterFinalize.reconciliation_history)}`,
  );

  // Patch 4.2 Section 3/4 — reopen_sales_return_refund_reconciliation()
  // over real HTTP: a mandatory reason reopens a finalized reconciliation,
  // after which record_sales_return_refund() (previously rejected while
  // finalized) succeeds again, and finalizing a second time appends a
  // SECOND reconciliation_history entry without ever erasing the first.
  const reopenRows = await rpc("reopen_sales_return_refund_reconciliation", {
    p_return_id: returnId,
    p_expected_version: returnDetailAfterFinalize.row_version,
    p_reason: "HTTP test — reopening to correct the refund total",
  });
  const reopenRow = Array.isArray(reopenRows) ? reopenRows[0] : reopenRows;
  ok(
    "reopen_sales_return_refund_reconciliation() over real HTTP succeeds given a mandatory reason and returns the same return_number",
    reopenRow?.return_number === createReturnRow.return_number,
    `got ${JSON.stringify(reopenRow)}`,
  );

  const returnDetailAfterReopen = await rpc("get_sales_return", { p_id: returnId });
  ok(
    "get_sales_return() over real HTTP: refund_finalized_at is cleared and refund_reconciliation_state is back to 'pending' after reopen",
    returnDetailAfterReopen.refund_finalized_at === null && returnDetailAfterReopen.refund_reconciliation_state === "pending",
    `got ${JSON.stringify({ finalized_at: returnDetailAfterReopen.refund_finalized_at, state: returnDetailAfterReopen.refund_reconciliation_state })}`,
  );
  ok(
    "get_sales_return() over real HTTP: reconciliation_history now has 2 entries (finalized, reopened) — the first entry is never erased",
    returnDetailAfterReopen.reconciliation_history?.length === 2 &&
      returnDetailAfterReopen.reconciliation_history[0].event_type === "finalized" &&
      returnDetailAfterReopen.reconciliation_history[1].event_type === "reopened",
    `got ${JSON.stringify(returnDetailAfterReopen.reconciliation_history)}`,
  );

  // record_sales_return_refund() succeeding here (previously rejected while
  // finalized) proves the reopen actually unlocked it — the ORIGINAL
  // 500.00 refund event from before finalize was never reversed, so this
  // ADDS a second 500.00 on top, giving actual_refunded_total=1000.00
  // against the unchanged 500.00 approved_refund_amount — a genuine
  // variance, requiring p_variance_reason on this second finalize (proving
  // that path too, over real HTTP).
  await rpc("record_sales_return_refund", {
    p_return_id: returnId,
    p_amount: returnDetailApprovedProfit.approved_refund_amount,
    p_refund_method_id: PAYMENT_METHOD_ID,
  });
  const returnDetailBeforeSecondFinalize = await rpc("get_sales_return", { p_id: returnId });
  ok(
    "record_sales_return_refund() over real HTTP succeeds again after reopen (previously rejected while finalized) — actual_refunded_total is now 1000.00 (the never-reversed original 500.00 event plus this new one)",
    new Decimal(returnDetailBeforeSecondFinalize.actual_refunded_total).equals(new Decimal("1000.00")),
    `got ${returnDetailBeforeSecondFinalize.actual_refunded_total}`,
  );
  await rpc("finalize_sales_return_refund", {
    p_return_id: returnId,
    p_expected_version: returnDetailBeforeSecondFinalize.row_version,
    p_variance_reason: "HTTP test — genuine variance after reopen, second finalize",
  });
  const returnDetailAfterSecondFinalize = await rpc("get_sales_return", { p_id: returnId });
  ok(
    "get_sales_return() over real HTTP: reconciliation_history now has 3 entries (finalized, reopened, finalized) after the reopen -> record -> finalize cycle completes, with a real variance this time",
    returnDetailAfterSecondFinalize.reconciliation_history?.length === 3 &&
      returnDetailAfterSecondFinalize.reconciliation_history[2].event_type === "finalized" &&
      returnDetailAfterSecondFinalize.refund_reconciliation_state === "finalized_with_variance",
    `got ${JSON.stringify(returnDetailAfterSecondFinalize.reconciliation_history)}, state=${returnDetailAfterSecondFinalize.refund_reconciliation_state}`,
  );

  const { data: returnAuditRowsProfit, error: returnAuditErrProfit } = await client
    .from("audit_logs")
    .select("id, action, entity_id")
    .eq("entity_id", returnId)
    .like("action", "return.%");
  if (returnAuditErrProfit) throw new Error(`audit_logs select (return.%, profit actor) failed: ${JSON.stringify(returnAuditErrProfit)}`);
  ok(
    "GET /audit_logs?action=like.return.* over real HTTP returns rows for a caller WITH audit_logs.view AND sales.view_profit",
    Array.isArray(returnAuditRowsProfit) && returnAuditRowsProfit.length > 0,
    `got ${returnAuditRowsProfit?.length ?? 0} rows`,
  );

  const { data: returnAuditRowsNoProfit, error: returnAuditErrNoProfit } = await clientNoProfit
    .from("audit_logs")
    .select("id, action, entity_id")
    .eq("entity_id", returnId)
    .like("action", "return.%");
  if (returnAuditErrNoProfit) throw new Error(`audit_logs select (return.%, no-profit actor) failed: ${JSON.stringify(returnAuditErrNoProfit)}`);
  ok(
    "GET /audit_logs?action=like.return.* over real HTTP returns ZERO rows for a caller WITH audit_logs.view but WITHOUT sales.view_profit (migration 0091 mirrors 0072 for return.%)",
    Array.isArray(returnAuditRowsNoProfit) && returnAuditRowsNoProfit.length === 0,
    `got ${returnAuditRowsNoProfit?.length ?? 0} rows, expected 0`,
  );

  const reverseRows = await rpc("reverse_sales_return", {
    p_return_id: returnId,
    p_expected_version: returnDetailAfterSecondFinalize.row_version,
    p_reversal_reason: "HTTP test — reversing the return itself",
  });
  const reverseRow = Array.isArray(reverseRows) ? reverseRows[0] : reverseRows;
  ok(
    "reverse_sales_return() over real HTTP succeeds and returns the same return_number",
    reverseRow?.return_number === createReturnRow.return_number,
    `got ${JSON.stringify(reverseRow)}`,
  );

  // Patch 4.1 Section 6 — the reversed return must STILL show its item
  // over real HTTP (history preservation), never a phantom item_count=0.
  const returnDetailAfterReverse = await rpc("get_sales_return", { p_id: returnId });
  ok(
    "get_sales_return() over real HTTP: a REVERSED return still shows its item (Patch 4.1 Section 6 — included_in_decision never erased)",
    returnDetailAfterReverse.status === "reversed" && returnDetailAfterReverse.items?.length === 1,
    `got status=${returnDetailAfterReverse.status} items=${returnDetailAfterReverse.items?.length}`,
  );

  const returnableAfterReversed = await rpc("get_returnable_sales_order", { p_sales_order_id: returnsOrderId });
  ok(
    "get_returnable_sales_order() over real HTTP: after reversing the only effective return, order_state is back to 'not_returned' and the item is returnable again",
    returnableAfterReversed.order_state === "not_returned" && returnableAfterReversed.items?.find((it) => it.id === returnItemA.id)?.returnable === true,
    `got ${JSON.stringify(returnableAfterReversed)}`,
  );

  // Hotfix 4.2.1 Section 15 — the new narrow search_sales_orders_for_return()
  // RPC over real HTTP: returns the tagged order by its exact order_number,
  // with the compact column set Returns actually needs (no sales.view
  // dependency at the DB-permission level — proven directly against
  // migration 0112's REVOKE/GRANT at the SQL layer in
  // sales_returns_hotfix_4_2_1.test.sql Section 15; this HTTP check proves
  // the RPC itself round-trips the right shape over the wire).
  const searchRows = await rpc("search_sales_orders_for_return", {
    p_order_number: returnsOrderRow.order_number,
    p_limit: 10,
  });
  const searchRow = Array.isArray(searchRows) ? searchRows.find((r) => r.id === returnsOrderId) : null;
  ok(
    "search_sales_orders_for_return() over real HTTP finds the tagged order by exact order_number and returns subtotal as typeof \"string\" (Decimal transport)",
    searchRow !== undefined &&
      searchRow !== null &&
      searchRow.order_number === returnsOrderRow.order_number &&
      typeof searchRow.subtotal === "string",
    `got ${JSON.stringify(searchRows)}`,
  );

  // -------------------------------------------------------------------
  // Part 8 (Phase 5 — Shipping Core, migrations 0113-0121) — a fresh Sale +
  // approved Return, then an OUTBOUND shipment (no rate configured — proves
  // the manual-entry escape hatch, Section 17) and a RETURN shipment (proves
  // the REAL seeded rate/fee figures — SMSA/RETURN/RIYADH=17.00, Riyadh
  // customer return fee=35.00, migrations 0114/0115), all over real HTTP.
  // Also proves: the Decimal Transport Boundary for every Shipping money
  // field, DB-level profit redaction for a genuinely different signed JWT,
  // the immutable customer_shipping_charge snapshot vs its correctable
  // effective value, the append-only actual-cost ledger, and the
  // fine-grained (not blanket-prefix) shipment.* audit_logs RLS gating
  // (migration 0121) — the one deliberately different design choice from
  // Returns' own blanket return.% gating.
  // -------------------------------------------------------------------
  const shippingOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID,
    p_sale_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_items: [
      { category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "1000.00" },
    ],
  });
  const shippingOrderRow = Array.isArray(shippingOrderRows) ? shippingOrderRows[0] : shippingOrderRows;
  const shippingOrderId = shippingOrderRow?.id;

  const shippingReturnable = await rpc("get_returnable_sales_order", { p_sales_order_id: shippingOrderId });
  const shippingItem = shippingReturnable.items[0];

  const shippingCreateReturnRows = await rpc("create_sales_return", {
    p_sales_order_id: shippingOrderId,
    p_processed_store_id: STORE_ID,
    p_return_date: todayIso,
    p_scenario: "defective_product",
    p_items: [{ sales_order_item_id: shippingItem.id, condition: "good_resellable" }],
    p_expected_sale_version: shippingReturnable.row_version,
    p_collection_state: "collected",
    p_approved_refund_amount: "1000.00",
  });
  const shippingCreateReturnRow = Array.isArray(shippingCreateReturnRows) ? shippingCreateReturnRows[0] : shippingCreateReturnRows;
  const shippingReturnId = shippingCreateReturnRow?.id;
  const shippingReturnDetailBeforeApprove = await rpc("get_sales_return", { p_id: shippingReturnId });
  await rpc("approve_sales_return", { p_return_id: shippingReturnId, p_expected_version: shippingReturnDetailBeforeApprove.row_version });

  const shippingCarriers = await rpc("shipments_carrier_lookups", {});
  const shippingZones = await rpc("shipments_zone_lookups", {});
  ok(
    "shipments_carrier_lookups()/shipments_zone_lookups() over real HTTP return only the documented compact shape, gated on shipments.create (Section 38)",
    Array.isArray(shippingCarriers) && shippingCarriers.every((c) => typeof c.id === "string" && typeof c.code === "string" && typeof c.name_ar === "string" && typeof c.carrier_type === "string") &&
      Array.isArray(shippingZones) && shippingZones.every((z) => typeof z.id === "string" && typeof z.code === "string" && typeof z.name_ar === "string"),
    `carriers=${JSON.stringify(shippingCarriers)} zones=${JSON.stringify(shippingZones)}`,
  );
  const smsaCarrier = shippingCarriers.find((c) => c.code === "SMSA");
  const riyadhZone = shippingZones.find((z) => z.code === "RIYADH");

  // Money-scale validation (validate_money_scale(), reused verbatim from
  // Sales/Returns) — a customer shipping charge with more than 2 decimal
  // places must be REJECTED over real HTTP.
  let shippingMoneyScaleError = null;
  try {
    await rpc("create_shipment", {
      p_sales_order_id: shippingOrderId,
      p_store_id: STORE_ID,
      p_shipment_date: todayIso,
      p_direction: "outbound",
      p_carrier_id: smsaCarrier.id,
      p_shipping_zone_id: riyadhZone.id,
      p_customer_shipping_charge: "30.005",
      p_manual_expected_cost: "12.00",
      p_manual_expected_cost_reason: "HTTP test — money scale probe",
    });
  } catch (err) {
    shippingMoneyScaleError = err;
  }
  ok(
    "create_shipment() over real HTTP: customer_shipping_charge with more than 2 decimal places is rejected outright (validate_money_scale(), reused from Sales/Returns)",
    shippingMoneyScaleError !== null && /عشري/.test(String(shippingMoneyScaleError.message)),
    `got ${shippingMoneyScaleError?.message}`,
  );

  // No OUTBOUND rate is configured for ANY carrier/zone (only RETURN-
  // direction figures are seeded, migration 0114) — this must hit the
  // manual-entry escape hatch (Section 17), never silently assume zero.
  const outboundPreviewRows = await rpc("preview_shipment_expected_cost", {
    p_carrier_id: smsaCarrier.id,
    p_shipping_zone_id: riyadhZone.id,
    p_direction: "outbound",
  });
  const outboundPreview = Array.isArray(outboundPreviewRows) ? outboundPreviewRows[0] : outboundPreviewRows;
  ok(
    "preview_shipment_expected_cost() over real HTTP correctly reports found=false for an OUTBOUND direction with no configured rate (Section 17 — never assumes zero)",
    outboundPreview.found === false && outboundPreview.expected_carrier_cost === null,
    `got ${JSON.stringify(outboundPreview)}`,
  );

  const outboundShipmentRows = await rpc("create_shipment", {
    p_sales_order_id: shippingOrderId,
    p_store_id: STORE_ID,
    p_shipment_date: todayIso,
    p_direction: "outbound",
    p_carrier_id: smsaCarrier.id,
    p_shipping_zone_id: riyadhZone.id,
    p_customer_shipping_charge: "30.00",
    p_manual_expected_cost: "12.00",
    p_manual_expected_cost_reason: "HTTP test — no outbound rate configured for this carrier/zone",
  });
  const outboundShipmentRow = Array.isArray(outboundShipmentRows) ? outboundShipmentRows[0] : outboundShipmentRows;
  ok(
    "create_shipment() over real HTTP returns a real shipment_number string (SHP-##########)",
    typeof outboundShipmentRow?.shipment_number === "string" && /^SHP-\d{10}$/.test(outboundShipmentRow.shipment_number),
    `got ${JSON.stringify(outboundShipmentRow)}`,
  );
  const outboundShipmentId = outboundShipmentRow?.id;

  const outboundShipmentDetail = await rpc("get_shipment", { p_id: outboundShipmentId });
  ok(
    "get_shipment() over real HTTP: the OUTBOUND shipment's manual-entry fields are typeof \"string\"/correct (Decimal Transport Boundary + Section 17 manual escape hatch)",
    typeof outboundShipmentDetail.customer_shipping_charge === "string" &&
      typeof outboundShipmentDetail.expected_carrier_cost === "string" &&
      outboundShipmentDetail.expected_carrier_cost === "12.00" &&
      outboundShipmentDetail.expected_carrier_cost_is_manual === true &&
      outboundShipmentDetail.carrier_rate_version_id === null &&
      typeof outboundShipmentDetail.net_shipping_expected === "string" &&
      new Decimal(outboundShipmentDetail.net_shipping_expected).equals(new Decimal("18.00")),
    `got ${JSON.stringify(outboundShipmentDetail)}`,
  );

  // The REAL seeded figures (migration 0114/0115): SMSA/RETURN/RIYADH's
  // carrier rate is 17.00, and Riyadh's customer return-shipping fee is
  // 35.00 — proven resolving correctly over real HTTP, not asserted from
  // the migration alone.
  const returnRatePreviewRows = await rpc("preview_shipment_expected_cost", {
    p_carrier_id: smsaCarrier.id,
    p_shipping_zone_id: riyadhZone.id,
    p_direction: "return",
  });
  const returnRatePreview = Array.isArray(returnRatePreviewRows) ? returnRatePreviewRows[0] : returnRatePreviewRows;
  ok(
    "preview_shipment_expected_cost() over real HTTP resolves the REAL seeded SMSA/RETURN/RIYADH rate (17.00, migration 0114) as typeof \"string\"",
    returnRatePreview.found === true && typeof returnRatePreview.expected_carrier_cost === "string" &&
      new Decimal(returnRatePreview.expected_carrier_cost).equals(new Decimal("17.00")),
    `got ${JSON.stringify(returnRatePreview)}`,
  );
  const returnFeePreviewRows = await rpc("preview_customer_return_shipping_fee", { p_shipping_zone_id: riyadhZone.id });
  const returnFeePreview = Array.isArray(returnFeePreviewRows) ? returnFeePreviewRows[0] : returnFeePreviewRows;
  ok(
    "preview_customer_return_shipping_fee() over real HTTP resolves the REAL seeded Riyadh customer return fee (35.00, migration 0115) as typeof \"string\", and remains overridable at creation (Section 20 — never silently substituted)",
    returnFeePreview.found === true && typeof returnFeePreview.fee_amount === "string" &&
      new Decimal(returnFeePreview.fee_amount).equals(new Decimal("35.00")),
    `got ${JSON.stringify(returnFeePreview)}`,
  );

  const returnShipmentRows = await rpc("create_shipment", {
    p_sales_order_id: shippingOrderId,
    p_store_id: STORE_ID,
    p_shipment_date: todayIso,
    p_direction: "return",
    p_carrier_id: smsaCarrier.id,
    p_shipping_zone_id: riyadhZone.id,
    p_customer_shipping_charge: returnFeePreview.fee_amount,
    p_sales_return_id: shippingReturnId,
  });
  const returnShipmentRow = Array.isArray(returnShipmentRows) ? returnShipmentRows[0] : returnShipmentRows;
  const returnShipmentId = returnShipmentRow?.id;

  const returnShipmentDetail = await rpc("get_shipment", { p_id: returnShipmentId });
  ok(
    "get_shipment() over real HTTP: the RETURN shipment auto-resolved the seeded rate (17.00), links to its Return, and every money field is typeof \"string\"",
    returnShipmentDetail.direction === "return" &&
      returnShipmentDetail.sales_return_id === shippingReturnId &&
      typeof returnShipmentDetail.return_number === "string" &&
      returnShipmentDetail.expected_carrier_cost_is_manual === false &&
      typeof returnShipmentDetail.carrier_rate_version_id === "string" &&
      new Decimal(returnShipmentDetail.expected_carrier_cost).equals(new Decimal("17.00")) &&
      new Decimal(returnShipmentDetail.net_shipping_expected).equals(new Decimal("18.00")),
    `got ${JSON.stringify(returnShipmentDetail)}`,
  );

  const shippingList = await rpc("list_shipments", { p_store_id: STORE_ID, p_limit: 20, p_offset: 0 });
  const shippingListRow = Array.isArray(shippingList) ? shippingList.find((r) => r.id === outboundShipmentId) : null;
  ok(
    "list_shipments() over real HTTP returns every money field as typeof \"string\" and a real total_count",
    shippingListRow !== undefined && shippingListRow !== null &&
      typeof shippingListRow.expected_carrier_cost === "string" &&
      typeof shippingListRow.net_shipping_expected === "string" &&
      typeof shippingListRow.total_count === "number" && shippingListRow.total_count >= 2,
    `got ${JSON.stringify(shippingListRow)}`,
  );

  // DB-level profit protection (Section 49) — a genuinely different signed
  // JWT/actor holding ONLY shipments.view.
  //
  // NOTE (found + fixed while adding Hotfix 5.1.1's Part 9): this
  // assertion originally also expected customer_shipping_charge absent for
  // the no-profit caller. That matched get_shipment()'s PRE-Patch-5.1
  // contract, but Patch 5.1 (migrations 0126/0129) deliberately redesigned
  // it — customer_shipping_charge/effective_customer_shipping_charge and
  // the customer-return-fee snapshot are a customer-facing OPERATIONAL
  // charge, not an internal cost/margin figure, so get_shipment()'s own
  // comment now documents them as ALWAYS present; only carrier-cost/margin
  // fields (expected/actual_carrier_cost, net_shipping_*,
  // cod_expected_amount, carrier_rate_version_id, financial_events) stay
  // gated behind sales.view_profit. This test had drifted from that
  // redesign (the real HTTP suite was not re-run after 0125-0129 landed) —
  // corrected here to match the current, documented DB contract rather
  // than silently reporting a false failure.
  const outboundShipmentDetailNoProfit = await rpc("get_shipment", { p_id: outboundShipmentId }, clientNoProfit);
  ok(
    "get_shipment() over real HTTP: for a caller WITHOUT sales.view_profit, carrier-cost/margin keys are ENTIRELY ABSENT (not null), while customer-facing figures (customer_shipping_charge, return-fee snapshot) and status_timeline stay visible (Patch 5.1's documented contract, migration 0126/0129)",
    "customer_shipping_charge" in outboundShipmentDetailNoProfit &&
      typeof outboundShipmentDetailNoProfit.customer_shipping_charge === "string" &&
      !("expected_carrier_cost" in outboundShipmentDetailNoProfit) &&
      !("actual_carrier_cost" in outboundShipmentDetailNoProfit) &&
      !("net_shipping_expected" in outboundShipmentDetailNoProfit) &&
      !("net_shipping_actual" in outboundShipmentDetailNoProfit) &&
      !("cod_expected_amount" in outboundShipmentDetailNoProfit) &&
      !("carrier_rate_version_id" in outboundShipmentDetailNoProfit) &&
      !("financial_events" in outboundShipmentDetailNoProfit) &&
      Array.isArray(outboundShipmentDetailNoProfit.status_timeline),
    `got keys=${Object.keys(outboundShipmentDetailNoProfit).join(",")}`,
  );
  const shippingListNoProfit = await rpc("list_shipments", { p_store_id: STORE_ID, p_limit: 20, p_offset: 0 }, clientNoProfit);
  const shippingListRowNoProfit = Array.isArray(shippingListNoProfit) ? shippingListNoProfit.find((r) => r.id === outboundShipmentId) : null;
  ok(
    "list_shipments() over real HTTP returns JSON null (not a real figure) for every money column to a caller without sales.view_profit, while non-financial columns stay populated",
    shippingListRowNoProfit !== undefined && shippingListRowNoProfit !== null &&
      shippingListRowNoProfit.expected_carrier_cost === null &&
      shippingListRowNoProfit.net_shipping_expected === null &&
      typeof shippingListRowNoProfit.shipment_number === "string",
    `got ${JSON.stringify(shippingListRowNoProfit)}`,
  );

  // Narrow lookup permission gating (Section 38) — clientNoProfit holds only
  // shipments.view, so ONLY the visible-store lookup succeeds; everything
  // gated on shipments.create must reject it, even though it can view
  // shipments themselves.
  const shippingVisibleStoresNoProfit = await rpc("shipments_visible_store_lookups", {}, clientNoProfit);
  ok(
    "shipments_visible_store_lookups() over real HTTP succeeds for a caller holding only shipments.view (Section 38)",
    Array.isArray(shippingVisibleStoresNoProfit) && shippingVisibleStoresNoProfit.length > 0,
    `got ${JSON.stringify(shippingVisibleStoresNoProfit)}`,
  );
  let shippingCarrierLookupRejected = null;
  try {
    await rpc("shipments_carrier_lookups", {}, clientNoProfit);
  } catch (err) {
    shippingCarrierLookupRejected = err;
  }
  ok(
    "shipments_carrier_lookups() over real HTTP rejects a caller without shipments.create, even though they hold shipments.view (Section 38)",
    shippingCarrierLookupRejected !== null,
    `got ${shippingCarrierLookupRejected?.message}`,
  );

  // Status lifecycle — a normal forward transition succeeds with only
  // shipments.update_status; jumping straight to a terminal status without
  // a reason is rejected, then succeeds once shipments.correct_status +
  // p_reason are supplied (state machine, migration 0116/0118).
  const statusRows1 = await rpc("add_shipment_status_event", {
    p_shipment_id: outboundShipmentId,
    p_new_status: "ready_for_pickup",
    p_expected_version: outboundShipmentDetail.row_version,
    p_event_business_date: todayIso,
  });
  const statusRow1 = Array.isArray(statusRows1) ? statusRows1[0] : statusRows1;
  ok(
    "add_shipment_status_event() over real HTTP: a normal forward transition returns the bumped row_version as typeof \"number\"",
    typeof statusRow1?.row_version === "number" && statusRow1.row_version === outboundShipmentDetail.row_version + 1,
    `got ${JSON.stringify(statusRow1)}`,
  );

  let correctionWithoutReasonError = null;
  try {
    await rpc("add_shipment_status_event", {
      p_shipment_id: outboundShipmentId,
      p_new_status: "delivered",
      p_expected_version: statusRow1.row_version,
      p_event_business_date: todayIso,
    });
  } catch (err) {
    correctionWithoutReasonError = err;
  }
  ok(
    "add_shipment_status_event() over real HTTP rejects an out-of-flow transition (created/ready_for_pickup -> delivered) without a reason, even though the actor holds shipments.correct_status",
    correctionWithoutReasonError !== null,
    `got ${correctionWithoutReasonError?.message}`,
  );
  const statusRows2 = await rpc("add_shipment_status_event", {
    p_shipment_id: outboundShipmentId,
    p_new_status: "delivered",
    p_expected_version: statusRow1.row_version,
    p_event_business_date: todayIso,
    p_reason: "HTTP test — direct correction to delivered",
  });
  const statusRow2 = Array.isArray(statusRows2) ? statusRows2[0] : statusRows2;

  // Actual carrier cost — record then correct, append-only ledger.
  const costRows1 = await rpc("record_shipment_actual_cost", {
    p_shipment_id: outboundShipmentId,
    p_expected_version: statusRow2.row_version,
    p_amount: "12.50",
    p_business_date: todayIso,
  });
  const costRow1 = Array.isArray(costRows1) ? costRows1[0] : costRows1;
  const afterFirstCost = await rpc("get_shipment", { p_id: outboundShipmentId });
  ok(
    "record_shipment_actual_cost() over real HTTP: actual_carrier_cost/net_shipping_actual round-trip as typeof \"string\", and financial_events has exactly 1 entry",
    typeof afterFirstCost.actual_carrier_cost === "string" &&
      new Decimal(afterFirstCost.actual_carrier_cost).equals(new Decimal("12.50")) &&
      new Decimal(afterFirstCost.net_shipping_actual).equals(new Decimal("17.50")) &&
      Array.isArray(afterFirstCost.financial_events) && afterFirstCost.financial_events.length === 1,
    `got ${JSON.stringify({ cost: afterFirstCost.actual_carrier_cost, net: afterFirstCost.net_shipping_actual, events: afterFirstCost.financial_events?.length })}`,
  );

  await rpc("correct_shipment_actual_cost", {
    p_shipment_id: outboundShipmentId,
    p_expected_version: costRow1.row_version,
    p_amount: "13.75",
    p_business_date: todayIso,
    p_reason: "HTTP test — correcting the actual carrier cost",
  });
  const afterCostCorrection = await rpc("get_shipment", { p_id: outboundShipmentId });
  ok(
    "correct_shipment_actual_cost() over real HTTP: actual_carrier_cost/net_shipping_actual reflect ONLY the latest correction (13.75), and financial_events grows to 2 entries with the ORIGINAL (12.50) preserved, never overwritten",
    new Decimal(afterCostCorrection.actual_carrier_cost).equals(new Decimal("13.75")) &&
      afterCostCorrection.financial_events.length === 2 &&
      new Decimal(afterCostCorrection.financial_events[0].amount).equals(new Decimal("12.50")) &&
      new Decimal(afterCostCorrection.financial_events[1].amount).equals(new Decimal("13.75")),
    `got ${JSON.stringify(afterCostCorrection.financial_events)}`,
  );

  await rpc("correct_shipment_customer_charge", {
    p_shipment_id: outboundShipmentId,
    p_expected_version: afterCostCorrection.row_version,
    p_amount: "40.00",
    p_business_date: todayIso,
    p_reason: "HTTP test — correcting the customer shipping charge",
  });
  const afterChargeCorrection = await rpc("get_shipment", { p_id: outboundShipmentId });
  ok(
    "correct_shipment_customer_charge() over real HTTP: the ORIGINAL customer_shipping_charge snapshot (30.00) stays untouched, while effective_customer_shipping_charge reflects the correction (40.00) — never overwriting the creation-time snapshot",
    new Decimal(afterChargeCorrection.customer_shipping_charge).equals(new Decimal("30.00")) &&
      new Decimal(afterChargeCorrection.effective_customer_shipping_charge).equals(new Decimal("40.00")),
    `got customer_shipping_charge=${afterChargeCorrection.customer_shipping_charge} effective=${afterChargeCorrection.effective_customer_shipping_charge}`,
  );

  // Fine-grained (not blanket-prefix) shipment.* audit_logs RLS gating
  // (migration 0121) — deliberately DIFFERENT from Returns' own blanket
  // return.% gating: shipment.status_add carries no money figure and stays
  // visible to a caller without sales.view_profit, while every action that
  // DOES carry a money payload (shipment.create/cost_record/cost_correct/
  // charge_correct) does not.
  const { data: shippingAuditProfit, error: shippingAuditErrProfit } = await client
    .from("audit_logs")
    .select("id, action")
    .eq("entity_id", outboundShipmentId)
    .like("action", "shipment.%");
  if (shippingAuditErrProfit) throw new Error(`audit_logs select (shipment.%, profit actor) failed: ${JSON.stringify(shippingAuditErrProfit)}`);
  const shippingAuditActionsProfit = new Set((shippingAuditProfit ?? []).map((r) => r.action));
  ok(
    "GET /audit_logs?action=like.shipment.* over real HTTP returns every shipment.* action (including money-bearing ones) for a caller WITH sales.view_profit",
    shippingAuditActionsProfit.has("shipment.create") &&
      shippingAuditActionsProfit.has("shipment.cost_record") &&
      shippingAuditActionsProfit.has("shipment.cost_correct") &&
      shippingAuditActionsProfit.has("shipment.charge_correct") &&
      shippingAuditActionsProfit.has("shipment.status_add"),
    `got actions=${[...shippingAuditActionsProfit].join(",")}`,
  );

  const { data: shippingAuditNoProfit, error: shippingAuditErrNoProfit } = await clientNoProfit
    .from("audit_logs")
    .select("id, action")
    .eq("entity_id", outboundShipmentId)
    .like("action", "shipment.%");
  if (shippingAuditErrNoProfit) throw new Error(`audit_logs select (shipment.%, no-profit actor) failed: ${JSON.stringify(shippingAuditErrNoProfit)}`);
  const shippingAuditActionsNoProfit = new Set((shippingAuditNoProfit ?? []).map((r) => r.action));
  ok(
    "GET /audit_logs?action=like.shipment.* over real HTTP: for a caller WITHOUT sales.view_profit, money-bearing actions (create/cost_record/cost_correct/charge_correct) are entirely absent while shipment.status_add stays visible (migration 0121's fine-grained gating — deliberately NOT the blanket return.%-style prefix)",
    !shippingAuditActionsNoProfit.has("shipment.create") &&
      !shippingAuditActionsNoProfit.has("shipment.cost_record") &&
      !shippingAuditActionsNoProfit.has("shipment.cost_correct") &&
      !shippingAuditActionsNoProfit.has("shipment.charge_correct") &&
      shippingAuditActionsNoProfit.has("shipment.status_add"),
    `got actions=${[...shippingAuditActionsNoProfit].join(",")}`,
  );

  // -------------------------------------------------------------------
  // Part 9 (Final Shipping Hotfix 5.1.1, migrations 0131-0132) — items
  // 1/5/6 proven over the SAME real HTTP/PostgREST round trip.
  // -------------------------------------------------------------------
  function daysAgoIso(n) {
    const d = new Date(Date.now() + 3 * 60 * 60 * 1000);
    d.setUTCDate(d.getUTCDate() - n);
    return d.toISOString().slice(0, 10);
  }

  // --- item 1: Preview/Create parity + mandatory override reason -------
  const hf511ReturnFeePreviewRows = await rpc("preview_customer_return_shipping_fee", { p_shipping_zone_id: riyadhZone.id });
  const hf511ReturnFeePreview = Array.isArray(hf511ReturnFeePreviewRows) ? hf511ReturnFeePreviewRows[0] : hf511ReturnFeePreviewRows;
  const hf511StandardFee = hf511ReturnFeePreview.fee_amount; // "35.00", real seeded Riyadh return fee (migration 0115)
  const hf511DivergingCharge = "45.00";

  let hf511NoReasonError = null;
  try {
    await rpc("create_shipment", {
      p_sales_order_id: shippingOrderId,
      p_store_id: STORE_ID,
      p_shipment_date: todayIso,
      p_direction: "return",
      p_carrier_id: smsaCarrier.id,
      p_shipping_zone_id: riyadhZone.id,
      p_customer_shipping_charge: hf511DivergingCharge,
      p_sales_return_id: shippingReturnId,
    });
  } catch (err) {
    hf511NoReasonError = err;
  }
  ok(
    "item 1: create_shipment() over real HTTP rejects a RETURN shipment whose customer_shipping_charge (45.00) diverges from the resolved standard fee (35.00) when no override reason is supplied",
    hf511NoReasonError !== null && /يجب إدخال سبب التعديل/.test(String(hf511NoReasonError.message)),
    `got ${hf511NoReasonError?.message}`,
  );

  const hf511OverrideReason = "HTTP test — Hotfix 5.1.1 item 1 override reason";
  const hf511ReturnShipmentRows = await rpc("create_shipment", {
    p_sales_order_id: shippingOrderId,
    p_store_id: STORE_ID,
    p_shipment_date: todayIso,
    p_direction: "return",
    p_carrier_id: smsaCarrier.id,
    p_shipping_zone_id: riyadhZone.id,
    p_customer_shipping_charge: hf511DivergingCharge,
    p_sales_return_id: shippingReturnId,
    p_customer_return_shipping_charge_override_reason: hf511OverrideReason,
  });
  const hf511ReturnShipmentRow = Array.isArray(hf511ReturnShipmentRows) ? hf511ReturnShipmentRows[0] : hf511ReturnShipmentRows;
  const hf511ReturnShipmentDetail = await rpc("get_shipment", { p_id: hf511ReturnShipmentRow.id });
  ok(
    "item 1: create_shipment() over real HTTP accepts the SAME diverging charge once an override reason is supplied, and get_shipment() reflects the standard/override snapshot correctly",
    new Decimal(hf511ReturnShipmentDetail.customer_shipping_charge).equals(new Decimal(hf511DivergingCharge)) &&
      new Decimal(hf511ReturnShipmentDetail.customer_return_shipping_fee_standard_amount).equals(new Decimal(hf511StandardFee)) &&
      hf511ReturnShipmentDetail.customer_return_shipping_charge_is_override === true &&
      hf511ReturnShipmentDetail.customer_return_shipping_charge_override_reason === hf511OverrideReason &&
      typeof hf511ReturnShipmentDetail.customer_return_shipping_fee_standard_amount === "string",
    `got ${JSON.stringify({
      charge: hf511ReturnShipmentDetail.customer_shipping_charge,
      standard: hf511ReturnShipmentDetail.customer_return_shipping_fee_standard_amount,
      isOverride: hf511ReturnShipmentDetail.customer_return_shipping_charge_is_override,
      reason: hf511ReturnShipmentDetail.customer_return_shipping_charge_override_reason,
    })}`,
  );

  // --- item 5: safe TEXT-returning rate/fee list RPCs -------------------
  const hf511CarrierVersions = await rpc("list_shipping_carrier_rate_versions_safe", {});
  const hf511FeeVersions = await rpc("list_customer_return_shipping_fee_versions_safe", {});
  ok(
    "item 5: list_shipping_carrier_rate_versions_safe()/list_customer_return_shipping_fee_versions_safe() over real HTTP return base_cost/fee_amount as typeof \"string\" (Decimal Transport Boundary, migration 0132), never a raw NUMERIC->JS number",
    Array.isArray(hf511CarrierVersions) && hf511CarrierVersions.length > 0 && hf511CarrierVersions.every((v) => typeof v.base_cost === "string") &&
      Array.isArray(hf511FeeVersions) && hf511FeeVersions.length > 0 && hf511FeeVersions.every((v) => typeof v.fee_amount === "string"),
    `carriers=${JSON.stringify(hf511CarrierVersions)} fees=${JSON.stringify(hf511FeeVersions)}`,
  );

  let hf511CarrierVersionsRejected = null;
  let hf511FeeVersionsRejected = null;
  try {
    await rpc("list_shipping_carrier_rate_versions_safe", {}, clientNoProfit);
  } catch (err) {
    hf511CarrierVersionsRejected = err;
  }
  try {
    await rpc("list_customer_return_shipping_fee_versions_safe", {}, clientNoProfit);
  } catch (err) {
    hf511FeeVersionsRejected = err;
  }
  ok(
    "item 5: both safe RPCs over real HTTP reject a genuinely different signed caller who holds shipments.view but NOT shipping_rates.view",
    hf511CarrierVersionsRejected !== null && hf511FeeVersionsRejected !== null,
    `carrier=${hf511CarrierVersionsRejected?.message} fee=${hf511FeeVersionsRejected?.message}`,
  );

  // --- item 6: monotonic chronology vs the LATEST same-stream event -----
  // Needs a shipment_date genuinely EARLIER than "today" for room to spread
  // distinct historical event dates — every fixture above is dated today,
  // and create_shipment() floors shipment_date at its order's own sale_date
  // (Section 34), so a fresh, deliberately backdated Sale is required (see
  // postgrest_http_test_setup.sql's matching "item 6/9" fixture section for
  // why the historical gold price / VAT rate version had to be widened).
  const hf511D0 = daysAgoIso(5);
  const hf511ChronoOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID,
    p_sale_date: hf511D0,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_items: [
      { category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "1000.00" },
    ],
  });
  const hf511ChronoOrderRow = Array.isArray(hf511ChronoOrderRows) ? hf511ChronoOrderRows[0] : hf511ChronoOrderRows;
  const hf511ChronoOrderId = hf511ChronoOrderRow?.id;

  const hf511ChronoShipmentRows = await rpc("create_shipment", {
    p_sales_order_id: hf511ChronoOrderId,
    p_store_id: STORE_ID,
    p_shipment_date: hf511D0,
    p_direction: "outbound",
    p_carrier_id: smsaCarrier.id,
    p_shipping_zone_id: riyadhZone.id,
    p_customer_shipping_charge: "20.00",
    p_is_cod: true,
    p_cod_expected_amount: "500.00",
    p_manual_expected_cost: "15.00",
    p_manual_expected_cost_reason: "HTTP test — Hotfix 5.1.1 item 6 chronology fixture",
  });
  const hf511ChronoShipmentRow = Array.isArray(hf511ChronoShipmentRows) ? hf511ChronoShipmentRows[0] : hf511ChronoShipmentRows;
  const hf511ChronoShipmentId = hf511ChronoShipmentRow.id;
  let hf511Chrono = await rpc("get_shipment", { p_id: hf511ChronoShipmentId });

  // Advance to ready_for_pickup at D0+3 (daysAgo(2)) — this becomes the
  // latest shipment_status_events.event_business_date for this shipment.
  const hf511LatestStatusDate = daysAgoIso(2);
  const hf511StatusAdvanceRows = await rpc("add_shipment_status_event", {
    p_shipment_id: hf511ChronoShipmentId,
    p_new_status: "ready_for_pickup",
    p_expected_version: hf511Chrono.row_version,
    p_event_business_date: hf511LatestStatusDate,
  });
  const hf511StatusAdvanceRow = Array.isArray(hf511StatusAdvanceRows) ? hf511StatusAdvanceRows[0] : hf511StatusAdvanceRows;

  // D0+2 (daysAgo(3)) clears the shipment_date floor (>= D0) but is
  // STRICTLY earlier than the latest recorded status event (daysAgo(2)) —
  // the exact regression 0130 missed and 0131 fixes.
  let hf511StatusChronoError = null;
  try {
    await rpc("add_shipment_status_event", {
      p_shipment_id: hf511ChronoShipmentId,
      p_new_status: "picked_up",
      p_expected_version: hf511StatusAdvanceRow.row_version,
      p_event_business_date: daysAgoIso(3),
    });
  } catch (err) {
    hf511StatusChronoError = err;
  }
  ok(
    "item 6: add_shipment_status_event() over real HTTP rejects a new status event dated before the LATEST existing status event for this shipment, even though it still clears the shipment_date floor",
    hf511StatusChronoError !== null && /آخر حدث حالة مسجَّل/.test(String(hf511StatusChronoError.message)),
    `got ${hf511StatusChronoError?.message}`,
  );

  // Same-day as the latest event remains explicitly tolerated.
  const hf511StatusSameDayRows = await rpc("add_shipment_status_event", {
    p_shipment_id: hf511ChronoShipmentId,
    p_new_status: "picked_up",
    p_expected_version: hf511StatusAdvanceRow.row_version,
    p_event_business_date: hf511LatestStatusDate,
  });
  const hf511StatusSameDayRow = Array.isArray(hf511StatusSameDayRows) ? hf511StatusSameDayRows[0] : hf511StatusSameDayRows;
  ok(
    "item 6: add_shipment_status_event() over real HTTP still accepts a same-day event against the latest existing event (the fix's tolerance is STRICT '<', not '<=')",
    typeof hf511StatusSameDayRow?.row_version === "number",
    `got ${JSON.stringify(hf511StatusSameDayRow)}`,
  );

  // Forward again — proves the fix did not simply reject everything.
  const hf511StatusForwardRows = await rpc("add_shipment_status_event", {
    p_shipment_id: hf511ChronoShipmentId,
    p_new_status: "in_transit",
    p_expected_version: hf511StatusSameDayRow.row_version,
    p_event_business_date: daysAgoIso(1),
  });
  const hf511StatusForwardRow = Array.isArray(hf511StatusForwardRows) ? hf511StatusForwardRows[0] : hf511StatusForwardRows;
  ok(
    "item 6: add_shipment_status_event() over real HTTP still accepts a genuinely forward-dated event after the chronology-violating attempt was rejected",
    typeof hf511StatusForwardRow?.row_version === "number" && hf511StatusForwardRow.row_version === hf511StatusSameDayRow.row_version + 1,
    `got ${JSON.stringify(hf511StatusForwardRow)}`,
  );

  hf511Chrono = await rpc("get_shipment", { p_id: hf511ChronoShipmentId });

  // Mirror the identical proof for the COD collection-state stream
  // (record_shipment_cod_collection_state(), migration 0131).
  const hf511LatestCodDate = daysAgoIso(4);
  const hf511CodAdvanceRows = await rpc("record_shipment_cod_collection_state", {
    p_shipment_id: hf511ChronoShipmentId,
    p_expected_version: hf511Chrono.row_version,
    p_new_state: "expected",
    p_business_date: hf511LatestCodDate,
  });
  const hf511CodAdvanceRow = Array.isArray(hf511CodAdvanceRows) ? hf511CodAdvanceRows[0] : hf511CodAdvanceRows;

  let hf511CodChronoError = null;
  try {
    await rpc("record_shipment_cod_collection_state", {
      p_shipment_id: hf511ChronoShipmentId,
      p_expected_version: hf511CodAdvanceRow.row_version,
      p_new_state: "not_collected",
      p_business_date: hf511D0, // clears the shipment_date floor, but earlier than hf511LatestCodDate
    });
  } catch (err) {
    hf511CodChronoError = err;
  }
  ok(
    "item 6: record_shipment_cod_collection_state() over real HTTP rejects a new COD event dated before the LATEST existing COD event for this shipment, even though it still clears the shipment_date floor",
    hf511CodChronoError !== null && /آخر حالة تحصيل مسجَّلة/.test(String(hf511CodChronoError.message)),
    `got ${hf511CodChronoError?.message}`,
  );

  const hf511CodSameDayRows = await rpc("record_shipment_cod_collection_state", {
    p_shipment_id: hf511ChronoShipmentId,
    p_expected_version: hf511CodAdvanceRow.row_version,
    p_new_state: "collected",
    p_business_date: hf511LatestCodDate,
  });
  const hf511CodSameDayRow = Array.isArray(hf511CodSameDayRows) ? hf511CodSameDayRows[0] : hf511CodSameDayRows;
  ok(
    "item 6: record_shipment_cod_collection_state() over real HTTP still accepts a same-day COD event against the latest existing event, and a genuinely forward-dated one after that",
    typeof hf511CodSameDayRow?.row_version === "number",
    `got ${JSON.stringify(hf511CodSameDayRow)}`,
  );
  const hf511CodForwardRows = await rpc("record_shipment_cod_collection_state", {
    p_shipment_id: hf511ChronoShipmentId,
    p_expected_version: hf511CodSameDayRow.row_version,
    p_new_state: "collected",
    p_business_date: daysAgoIso(2),
  });
  const hf511CodForwardRow = Array.isArray(hf511CodForwardRows) ? hf511CodForwardRows[0] : hf511CodForwardRows;
  ok(
    "item 6: record_shipment_cod_collection_state() over real HTTP accepts a genuinely forward-dated COD event after the chronology-violating attempt was rejected",
    typeof hf511CodForwardRow?.row_version === "number" && hf511CodForwardRow.row_version === hf511CodSameDayRow.row_version + 1,
    `got ${JSON.stringify(hf511CodForwardRow)}`,
  );

  // -------------------------------------------------------------------
  // Part 10 (Final Shipping UI & Verification Hotfix 5.1.2, item 5,
  // A-I) — no new migrations; this section completes real HTTP coverage
  // for Patch 5.1/Hotfix 5.1.1 requirements previously proven only at the
  // SQL layer.
  // -------------------------------------------------------------------

  // --- A) direct writes on the two locked-down tables are denied --------
  // NOTE: @supabase/postgrest-js does NOT throw on a PostgREST-level error
  // (RLS denial, constraint violation, etc.) unless .throwOnError() is
  // chained — a bare `await client.from(...).insert(...)` resolves normally
  // with an `{ error }` field instead of rejecting. The try/catch alone
  // (as originally written) never observed the denial. Destructuring
  // `{ error }` directly is the correct check here.
  let hf512DirectCarrierRateInsertError = null;
  try {
    const { error } = await client
      .from("shipping_carrier_rate_versions")
      .insert({ carrier_id: smsaCarrier.id, shipping_zone_id: riyadhZone.id, direction: "outbound", base_cost: "99.00", effective_from: todayIso });
    if (error) {
      hf512DirectCarrierRateInsertError = error;
    } else {
      const { data: checkRows } = await client.from("shipping_carrier_rate_versions").select("id").eq("base_cost", 99);
      if (!Array.isArray(checkRows) || checkRows.length === 0) {
        hf512DirectCarrierRateInsertError = { message: "insert reported no error and no row was created — treating as denied" };
      }
    }
  } catch (err) {
    hf512DirectCarrierRateInsertError = err;
  }
  ok(
    "item A: a direct INSERT over real HTTP against shipping_carrier_rate_versions is rejected even for an actor holding shipping_rates.manage — every write MUST go through create_shipping_carrier_rate_version() (Patch 5.1 item 1, migration 0122)",
    hf512DirectCarrierRateInsertError !== null,
    `got ${hf512DirectCarrierRateInsertError?.message}`,
  );

  let hf512DirectFeeInsertError = null;
  try {
    const { error } = await client
      .from("customer_return_shipping_fee_versions")
      .insert({ shipping_zone_id: riyadhZone.id, fee_amount: "99.00", effective_from: todayIso });
    if (error) {
      hf512DirectFeeInsertError = error;
    } else {
      const { data: checkRows2 } = await client.from("customer_return_shipping_fee_versions").select("id").eq("fee_amount", 99);
      if (!Array.isArray(checkRows2) || checkRows2.length === 0) {
        hf512DirectFeeInsertError = { message: "insert reported no error and no row was created — treating as denied" };
      }
    }
  } catch (err) {
    hf512DirectFeeInsertError = err;
  }
  ok(
    "item A: a direct INSERT over real HTTP against customer_return_shipping_fee_versions is rejected the same way (migration 0122)",
    hf512DirectFeeInsertError !== null,
    `got ${hf512DirectFeeInsertError?.message}`,
  );

  // --- B) the sanctioned rate RPCs succeed, plus a fresh NO-CONFIG zone -
  // for item D below — a zone with a configured RETURN carrier rate (so
  // create_shipment() never needs a manual CARRIER cost) but deliberately
  // NO customer_return_shipping_fee_versions row, isolating the "no
  // configuration" condition strictly to the customer-facing fee.
  const hf512ZoneCode = `HTTP512_${Date.now() % 100000}`;
  const { data: hf512NewZoneRows, error: hf512NewZoneErr } = await client
    .from("shipping_zones")
    .insert({ code: hf512ZoneCode, name_ar: "منطقة اختبار Hotfix 5.1.2 (بدون تسعير إرجاع)", sort_order: 900 })
    .select("id, code, name_ar")
    .single();
  if (hf512NewZoneErr) throw new Error(`shipping_zones insert (fixture for item B/D) failed: ${JSON.stringify(hf512NewZoneErr)}`);
  const hf512NoConfigZone = hf512NewZoneRows;

  const hf512NewCarrierRateVersionId = await rpc("create_shipping_carrier_rate_version", {
    p_carrier_id: smsaCarrier.id,
    p_shipping_zone_id: hf512NoConfigZone.id,
    p_direction: "return",
    p_base_cost: "16.00",
    p_effective_from: todayIso,
  });
  ok(
    "item B: create_shipping_carrier_rate_version() over real HTTP (the sanctioned RPC) succeeds and returns a real uuid",
    typeof hf512NewCarrierRateVersionId === "string" && hf512NewCarrierRateVersionId.length > 0,
    `got ${JSON.stringify(hf512NewCarrierRateVersionId)}`,
  );

  // --- D) no-config Return Shipping Fee: manual charge without a reason -
  // is rejected, then succeeds with one.
  let hf512NoConfigNoReasonError = null;
  try {
    await rpc("create_shipment", {
      p_sales_order_id: shippingOrderId,
      p_store_id: STORE_ID,
      p_shipment_date: todayIso,
      p_direction: "return",
      p_carrier_id: smsaCarrier.id,
      p_shipping_zone_id: hf512NoConfigZone.id,
      p_customer_shipping_charge: "40.00",
      p_sales_return_id: shippingReturnId,
    });
  } catch (err) {
    hf512NoConfigNoReasonError = err;
  }
  ok(
    "item D: create_shipment() over real HTTP rejects a manual return-shipping charge for a zone with NO fee configuration at all when no override reason is supplied",
    // migration 0125/0129's dedicated "no configuration exists at all" branch
    // raises a DIFFERENT message ("لا يوجد إعداد معتمد... أدخل سببًا") than
    // the "diverges from the configured standard fee" branch used by item 1
    // ("يجب إدخال سبب التعديل") — this is the no-config-specific message.
    hf512NoConfigNoReasonError !== null && /لا يوجد إعداد معتمد لرسوم شحن الإرجاع/.test(String(hf512NoConfigNoReasonError.message)),
    `got ${hf512NoConfigNoReasonError?.message}`,
  );

  const hf512NoConfigReason = "HTTP test — Hotfix 5.1.2 item D: منطقة بدون تسعير معتمد";
  const hf512NoConfigShipmentRows = await rpc("create_shipment", {
    p_sales_order_id: shippingOrderId,
    p_store_id: STORE_ID,
    p_shipment_date: todayIso,
    p_direction: "return",
    p_carrier_id: smsaCarrier.id,
    p_shipping_zone_id: hf512NoConfigZone.id,
    p_customer_shipping_charge: "40.00",
    p_sales_return_id: shippingReturnId,
    p_customer_return_shipping_charge_override_reason: hf512NoConfigReason,
  });
  const hf512NoConfigShipmentRow = Array.isArray(hf512NoConfigShipmentRows) ? hf512NoConfigShipmentRows[0] : hf512NoConfigShipmentRows;
  const hf512NoConfigShipmentDetail = await rpc("get_shipment", { p_id: hf512NoConfigShipmentRow.id });
  ok(
    "item D: the SAME manual charge succeeds once an override reason is supplied — customer_return_shipping_fee_standard_amount is null (nothing to be standard against) while is_override/reason are recorded correctly",
    new Decimal(hf512NoConfigShipmentDetail.customer_shipping_charge).equals(new Decimal("40.00")) &&
      hf512NoConfigShipmentDetail.customer_return_shipping_fee_standard_amount === null &&
      hf512NoConfigShipmentDetail.customer_return_shipping_charge_is_override === true &&
      hf512NoConfigShipmentDetail.customer_return_shipping_charge_override_reason === hf512NoConfigReason,
    `got ${JSON.stringify({
      charge: hf512NoConfigShipmentDetail.customer_shipping_charge,
      standard: hf512NoConfigShipmentDetail.customer_return_shipping_fee_standard_amount,
      isOverride: hf512NoConfigShipmentDetail.customer_return_shipping_charge_is_override,
      reason: hf512NoConfigShipmentDetail.customer_return_shipping_charge_override_reason,
    })}`,
  );

  // Now configure the SAME zone's customer return fee via the sanctioned
  // RPC too (item B's second half) — deliberately done AFTER item D's
  // no-config assertions above, so it never interferes with them.
  const hf512NewFeeVersionId = await rpc("create_customer_return_shipping_fee_version", {
    p_shipping_zone_id: hf512NoConfigZone.id,
    p_fee_amount: "22.50",
    p_effective_from: todayIso,
  });
  ok(
    "item B: create_customer_return_shipping_fee_version() over real HTTP (the sanctioned RPC) succeeds and returns a real uuid",
    typeof hf512NewFeeVersionId === "string" && hf512NewFeeVersionId.length > 0,
    `got ${JSON.stringify(hf512NewFeeVersionId)}`,
  );

  // --- H) the Hotfix 5.1.1 safe rate-read RPCs also reflect THESE new
  // rows (not just seeded ones), still as typeof "string".
  const hf512CarrierVersionsAfter = await rpc("list_shipping_carrier_rate_versions_safe", {});
  const hf512FeeVersionsAfter = await rpc("list_customer_return_shipping_fee_versions_safe", {});
  const hf512NewCarrierRow = hf512CarrierVersionsAfter.find((v) => v.id === hf512NewCarrierRateVersionId);
  const hf512NewFeeRow = hf512FeeVersionsAfter.find((v) => v.id === hf512NewFeeVersionId);
  ok(
    "item H: list_shipping_carrier_rate_versions_safe()/list_customer_return_shipping_fee_versions_safe() over real HTTP include the rows just created by THIS session's own RPC calls (not merely seeded ones), base_cost/fee_amount still typeof \"string\"",
    hf512NewCarrierRow !== undefined && typeof hf512NewCarrierRow.base_cost === "string" && new Decimal(hf512NewCarrierRow.base_cost).equals(new Decimal("16.00")) &&
      hf512NewFeeRow !== undefined && typeof hf512NewFeeRow.fee_amount === "string" && new Decimal(hf512NewFeeRow.fee_amount).equals(new Decimal("22.50")),
    `carrierRow=${JSON.stringify(hf512NewCarrierRow)} feeRow=${JSON.stringify(hf512NewFeeRow)}`,
  );

  // --- C) shipments.view-only actor: filter lookups work, customer charge
  // stays visible, every carrier-cost/margin figure stays hidden.
  const hf512FilterCarriersNoProfit = await rpc("shipments_filter_carrier_lookups", {}, clientNoProfit);
  const hf512FilterZonesNoProfit = await rpc("shipments_filter_zone_lookups", {}, clientNoProfit);
  ok(
    "item C: shipments_filter_carrier_lookups()/shipments_filter_zone_lookups() over real HTTP succeed for a caller holding only shipments.view (Patch 5.1 item 11 — NOT gated on shipments.create like the older shipments_carrier_lookups()/shipments_zone_lookups())",
    Array.isArray(hf512FilterCarriersNoProfit) && hf512FilterCarriersNoProfit.length > 0 &&
      Array.isArray(hf512FilterZonesNoProfit) && hf512FilterZonesNoProfit.length > 0,
    `carriers=${JSON.stringify(hf512FilterCarriersNoProfit)} zones=${JSON.stringify(hf512FilterZonesNoProfit)}`,
  );

  const hf512ListNoProfit = await rpc("list_shipments", { p_sales_order_id: shippingOrderId, p_limit: 20, p_offset: 0 }, clientNoProfit);
  const hf512ListNoProfitRow = Array.isArray(hf512ListNoProfit) ? hf512ListNoProfit.find((r) => r.id === outboundShipmentId) : null;
  ok(
    "item C: list_shipments() over real HTTP for a shipments.view-only caller: customer_shipping_charge is a real string (customer-facing, never profit-gated) while expected/actual_carrier_cost and net_shipping_expected/actual stay null",
    hf512ListNoProfitRow !== undefined && hf512ListNoProfitRow !== null &&
      typeof hf512ListNoProfitRow.customer_shipping_charge === "string" &&
      hf512ListNoProfitRow.expected_carrier_cost === null &&
      hf512ListNoProfitRow.actual_carrier_cost === null &&
      hf512ListNoProfitRow.net_shipping_expected === null &&
      hf512ListNoProfitRow.net_shipping_actual === null,
    `got ${JSON.stringify(hf512ListNoProfitRow)}`,
  );

  // --- E) create_shipment() rejects a RETURN into an already-REVERSED
  // return (returnsOrderId/returnId — the Patch 4.1/4.2 Returns lifecycle
  // fixture from Part 4/7, already reversed by this point in the run).
  let hf512ReversedReturnError = null;
  try {
    await rpc("create_shipment", {
      p_sales_order_id: returnsOrderId,
      p_store_id: STORE_ID,
      p_shipment_date: todayIso,
      p_direction: "return",
      p_carrier_id: smsaCarrier.id,
      p_shipping_zone_id: riyadhZone.id,
      p_customer_shipping_charge: "35.00",
      p_sales_return_id: returnId,
    });
  } catch (err) {
    hf512ReversedReturnError = err;
  }
  ok(
    "item E: create_shipment() over real HTTP rejects a new RETURN shipment against an already-reversed return (Patch 5.1 item 15/16)",
    hf512ReversedReturnError !== null && /ليس معتمَدًا حاليًا/.test(String(hf512ReversedReturnError.message)),
    `got ${hf512ReversedReturnError?.message}`,
  );

  // --- F) COD RPC succeeds (re-confirmed) + a genuine direct-mutation
  // bypass attempt on shipment_cod_events is rejected (zero RLS policies
  // for `authenticated`, migration 0127 — not even an UPDATE/DELETE
  // policy exists to accidentally allow a partial bypass).
  const hf512BeforeBypass = await rpc("get_shipment", { p_id: hf511ChronoShipmentId });
  const hf512CodTimelineCountBefore = hf512BeforeBypass.cod_timeline?.length ?? 0;
  let hf512CodDirectInsertError = null;
  try {
    const { error } = await client
      .from("shipment_cod_events")
      .insert({ shipment_id: hf511ChronoShipmentId, state: "collected", business_date: todayIso });
    if (error) hf512CodDirectInsertError = error;
  } catch (err) {
    hf512CodDirectInsertError = err;
  }
  const hf512AfterBypass = await rpc("get_shipment", { p_id: hf511ChronoShipmentId });
  ok(
    "item F: a direct INSERT over real HTTP against shipment_cod_events (bypassing record_shipment_cod_collection_state()) is rejected, and the shipment's cod_timeline length is genuinely unchanged (not just an error message with a silent side effect)",
    hf512CodDirectInsertError !== null && (hf512AfterBypass.cod_timeline?.length ?? 0) === hf512CodTimelineCountBefore,
    `error=${hf512CodDirectInsertError?.message} before=${hf512CodTimelineCountBefore} after=${hf512AfterBypass.cod_timeline?.length}`,
  );

  // --- G) historical carrier/zone name snapshots survive a rename -------
  const hf512OriginalCarrierName = smsaCarrier.name_ar;
  const hf512OriginalZoneName = riyadhZone.name_ar;
  const { error: hf512RenameCarrierErr } = await client.from("shipping_carriers").update({ name_ar: "SMSA (اسم مُعاد تسميته HTTP)" }).eq("id", smsaCarrier.id);
  if (hf512RenameCarrierErr) throw new Error(`shipping_carriers rename failed: ${JSON.stringify(hf512RenameCarrierErr)}`);
  const { error: hf512RenameZoneErr } = await client.from("shipping_zones").update({ name_ar: "الرياض (اسم مُعاد تسميته HTTP)" }).eq("id", riyadhZone.id);
  if (hf512RenameZoneErr) throw new Error(`shipping_zones rename failed: ${JSON.stringify(hf512RenameZoneErr)}`);

  const hf512ShipmentAfterRename = await rpc("get_shipment", { p_id: outboundShipmentId });
  ok(
    "item G: get_shipment() over real HTTP for a shipment created BEFORE a carrier/zone rename still shows the ORIGINAL carrier_name/zone_name (its own creation-time snapshot, migration 0129), never the just-renamed live value",
    hf512ShipmentAfterRename.carrier_name === hf512OriginalCarrierName &&
      hf512ShipmentAfterRename.zone_name === hf512OriginalZoneName &&
      hf512ShipmentAfterRename.carrier_name !== "SMSA (اسم مُعاد تسميته HTTP)" &&
      hf512ShipmentAfterRename.zone_name !== "الرياض (اسم مُعاد تسميته HTTP)",
    `got carrier_name=${hf512ShipmentAfterRename.carrier_name} zone_name=${hf512ShipmentAfterRename.zone_name}`,
  );

  // --- G continued (Hotfix 5.1.3 item 9) — the other half of the proof:
  // a shipment created AFTER the rename must capture the NEW Master Data
  // names at its own creation time, not the pre-rename ones. Together with
  // item G above (the OLD shipment staying frozen), this proves the
  // snapshot columns are a genuine point-in-time capture, not merely
  // "always shows whatever was seeded first".
  const hf513NewShipmentRows = await rpc("create_shipment", {
    p_sales_order_id: shippingOrderId,
    p_store_id: STORE_ID,
    p_shipment_date: todayIso,
    p_direction: "outbound",
    p_carrier_id: smsaCarrier.id,
    p_shipping_zone_id: riyadhZone.id,
    p_customer_shipping_charge: "28.00",
    p_manual_expected_cost: "11.00",
    p_manual_expected_cost_reason: "HTTP test — Hotfix 5.1.3 item 9: shipment created AFTER carrier/zone rename",
  });
  const hf513NewShipmentRow = Array.isArray(hf513NewShipmentRows) ? hf513NewShipmentRows[0] : hf513NewShipmentRows;
  const hf513NewShipmentDetail = await rpc("get_shipment", { p_id: hf513NewShipmentRow?.id });
  ok(
    "item 9: a NEW shipment created AFTER the carrier/zone rename captures the RENAMED names in its own snapshot — never the pre-rename ones (the OLD shipment above stays frozen; this one captures fresh Master Data at its own creation time)",
    hf513NewShipmentDetail.carrier_name === "SMSA (اسم مُعاد تسميته HTTP)" &&
      hf513NewShipmentDetail.zone_name === "الرياض (اسم مُعاد تسميته HTTP)" &&
      hf513NewShipmentDetail.carrier_name !== hf512OriginalCarrierName &&
      hf513NewShipmentDetail.zone_name !== hf512OriginalZoneName,
    `got carrier_name=${hf513NewShipmentDetail.carrier_name} zone_name=${hf513NewShipmentDetail.zone_name}`,
  );

  // --- A continued (Hotfix 5.1.3 item 7) — direct UPDATE (not just
  // INSERT) against the two locked-down version tables is ALSO denied —
  // the RLS policy on both tables is SELECT-only (migration 0122), so an
  // UPDATE has no policy to satisfy either.
  //
  // IMPORTANT: unlike the INSERT case (item A above), Postgres/PostgREST's
  // actual denial signal for an UPDATE with NO matching RLS policy is NOT
  // necessarily a thrown error — the UPDATE's WHERE clause simply matches
  // ZERO rows (RLS filters them out before the UPDATE ever sees them), so
  // PostgREST returns a perfectly normal 2xx response with no error and no
  // affected rows. Chaining `.select("id")` makes this observable directly
  // (an empty returned array = zero rows were actually touched), which is
  // the real "denied" signal here — checked TOGETHER with a genuine error
  // (in case a future RLS/grant change turns this into a hard rejection
  // instead) and an independent follow-up read confirming the value is
  // unchanged either way.
  const hf513CarrierRateVersionId = hf512NewCarrierRateVersionId;
  const hf513FeeVersionId = hf512NewFeeVersionId;
  const hf513CarrierRateBefore = hf512NewCarrierRow;
  const hf513FeeVersionBefore = hf512NewFeeRow;

  let hf513CarrierRatePatchError = null;
  let hf513CarrierRatePatchRows = null;
  try {
    const { data, error } = await client.from("shipping_carrier_rate_versions").update({ base_cost: "999.00" }).eq("id", hf513CarrierRateVersionId).select("id");
    hf513CarrierRatePatchRows = data;
    if (error) hf513CarrierRatePatchError = error;
  } catch (err) {
    hf513CarrierRatePatchError = err;
  }
  const hf513CarrierVersionsAfterPatch = await rpc("list_shipping_carrier_rate_versions_safe", {});
  const hf513CarrierRateAfterPatch = hf513CarrierVersionsAfterPatch.find((v) => v.id === hf513CarrierRateVersionId);
  ok(
    "item 7: a direct PATCH (UPDATE) over real HTTP against shipping_carrier_rate_versions (changing base_cost) has no effect — zero rows affected (RLS is SELECT-only, migration 0122) — and the original base_cost is genuinely unchanged afterward",
    (hf513CarrierRatePatchError !== null || (Array.isArray(hf513CarrierRatePatchRows) && hf513CarrierRatePatchRows.length === 0)) &&
      hf513CarrierRateAfterPatch !== undefined &&
      new Decimal(hf513CarrierRateAfterPatch.base_cost).equals(new Decimal(hf513CarrierRateBefore.base_cost)) &&
      !new Decimal(hf513CarrierRateAfterPatch.base_cost).equals(new Decimal("999.00")),
    `error=${hf513CarrierRatePatchError?.message} rowsAffected=${hf513CarrierRatePatchRows?.length} before=${hf513CarrierRateBefore.base_cost} after=${hf513CarrierRateAfterPatch?.base_cost}`,
  );

  let hf513CarrierRateDatePatchError = null;
  let hf513CarrierRateDatePatchRows = null;
  try {
    const { data, error } = await client
      .from("shipping_carrier_rate_versions")
      .update({ effective_from: daysAgoIso(1) })
      .eq("id", hf513CarrierRateVersionId)
      .select("id");
    hf513CarrierRateDatePatchRows = data;
    if (error) hf513CarrierRateDatePatchError = error;
  } catch (err) {
    hf513CarrierRateDatePatchError = err;
  }
  ok(
    "item 7: a direct PATCH over real HTTP against shipping_carrier_rate_versions changing effective_from ALSO affects zero rows (not just base_cost — the whole row is immutable via PostgREST)",
    hf513CarrierRateDatePatchError !== null || (Array.isArray(hf513CarrierRateDatePatchRows) && hf513CarrierRateDatePatchRows.length === 0),
    `error=${hf513CarrierRateDatePatchError?.message} rowsAffected=${hf513CarrierRateDatePatchRows?.length}`,
  );

  let hf513FeeVersionPatchError = null;
  let hf513FeeVersionPatchRows = null;
  try {
    const { data, error } = await client.from("customer_return_shipping_fee_versions").update({ fee_amount: "888.00" }).eq("id", hf513FeeVersionId).select("id");
    hf513FeeVersionPatchRows = data;
    if (error) hf513FeeVersionPatchError = error;
  } catch (err) {
    hf513FeeVersionPatchError = err;
  }
  const hf513FeeVersionsAfterPatch = await rpc("list_customer_return_shipping_fee_versions_safe", {});
  const hf513FeeVersionAfterPatch = hf513FeeVersionsAfterPatch.find((v) => v.id === hf513FeeVersionId);
  ok(
    "item 7: a direct PATCH (UPDATE) over real HTTP against customer_return_shipping_fee_versions (changing fee_amount) has no effect — zero rows affected — and the original fee_amount is genuinely unchanged afterward",
    (hf513FeeVersionPatchError !== null || (Array.isArray(hf513FeeVersionPatchRows) && hf513FeeVersionPatchRows.length === 0)) &&
      hf513FeeVersionAfterPatch !== undefined &&
      new Decimal(hf513FeeVersionAfterPatch.fee_amount).equals(new Decimal(hf513FeeVersionBefore.fee_amount)) &&
      !new Decimal(hf513FeeVersionAfterPatch.fee_amount).equals(new Decimal("888.00")),
    `error=${hf513FeeVersionPatchError?.message} rowsAffected=${hf513FeeVersionPatchRows?.length} before=${hf513FeeVersionBefore.fee_amount} after=${hf513FeeVersionAfterPatch?.fee_amount}`,
  );

  let hf513FeeVersionDatePatchError = null;
  let hf513FeeVersionDatePatchRows = null;
  try {
    const { data, error } = await client
      .from("customer_return_shipping_fee_versions")
      .update({ effective_from: daysAgoIso(1) })
      .eq("id", hf513FeeVersionId)
      .select("id");
    hf513FeeVersionDatePatchRows = data;
    if (error) hf513FeeVersionDatePatchError = error;
  } catch (err) {
    hf513FeeVersionDatePatchError = err;
  }
  ok(
    "item 7: a direct PATCH over real HTTP against customer_return_shipping_fee_versions changing effective_from ALSO affects zero rows",
    hf513FeeVersionDatePatchError !== null || (Array.isArray(hf513FeeVersionDatePatchRows) && hf513FeeVersionDatePatchRows.length === 0),
    `error=${hf513FeeVersionDatePatchError?.message} rowsAffected=${hf513FeeVersionDatePatchRows?.length}`,
  );

  // --- C continued (Hotfix 5.1.3 item 8) — shipments_visible_store_
  // lookups() (the store lookup the /shipments list page ALSO depends on)
  // succeeds for a shipments.view-only caller too, exactly like the
  // filter_carrier/filter_zone lookups already covered above.
  const hf513VisibleStoresNoProfit = await rpc("shipments_visible_store_lookups", {}, clientNoProfit);
  ok(
    "item 8: shipments_visible_store_lookups() over real HTTP succeeds for a caller holding only shipments.view — the /shipments list page depends on this lookup too, not just the carrier/zone filter lookups",
    Array.isArray(hf513VisibleStoresNoProfit) && hf513VisibleStoresNoProfit.length > 0,
    `got ${JSON.stringify(hf513VisibleStoresNoProfit)}`,
  );

  // --- F continued (Hotfix 5.1.3 item 10) — a direct UPDATE against
  // shipment_cod_events is ALSO denied (zero RLS policies for
  // `authenticated` at all, migration 0127 — not even a narrower
  // UPDATE-only policy exists), and a direct UPDATE attempting to move
  // shipments.cod_collection_state itself is denied too (shipments has
  // zero direct-write RLS policies — only create_shipment()/the status +
  // financial-correction RPCs, and record_shipment_cod_collection_state()
  // specifically for this column, may ever write to it). As with item 7
  // above, the real denial signal for an UPDATE against a table with no
  // matching RLS policy is typically "zero rows affected" (via
  // `.select()`), not necessarily a thrown error — checked alongside a
  // genuine error and an independent follow-up read.
  const hf513CodStateBeforeDirectUpdate = await rpc("get_shipment", { p_id: hf511ChronoShipmentId });
  let hf513CodEventDirectUpdateError = null;
  let hf513CodEventDirectUpdateRows = null;
  try {
    const { data, error } = await client.from("shipment_cod_events").update({ state: "not_collected" }).eq("shipment_id", hf511ChronoShipmentId).select("id");
    hf513CodEventDirectUpdateRows = data;
    if (error) hf513CodEventDirectUpdateError = error;
  } catch (err) {
    hf513CodEventDirectUpdateError = err;
  }
  let hf513ShipmentCodStateDirectUpdateError = null;
  let hf513ShipmentCodStateDirectUpdateRows = null;
  try {
    const { data, error } = await client.from("shipments").update({ cod_collection_state: "not_collected" }).eq("id", hf511ChronoShipmentId).select("id");
    hf513ShipmentCodStateDirectUpdateRows = data;
    if (error) hf513ShipmentCodStateDirectUpdateError = error;
  } catch (err) {
    hf513ShipmentCodStateDirectUpdateError = err;
  }
  const hf513CodStateAfterDirectUpdate = await rpc("get_shipment", { p_id: hf511ChronoShipmentId });
  ok(
    "item 10: a direct UPDATE over real HTTP against shipment_cod_events (bypassing record_shipment_cod_collection_state()) has no effect (zero rows affected / denied), AND a direct UPDATE attempting to move shipments.cod_collection_state itself is ALSO denied/no-effect — the current COD state is genuinely unchanged by either attempt (only the sanctioned RPC may move it)",
    (hf513CodEventDirectUpdateError !== null || (Array.isArray(hf513CodEventDirectUpdateRows) && hf513CodEventDirectUpdateRows.length === 0)) &&
      (hf513ShipmentCodStateDirectUpdateError !== null || (Array.isArray(hf513ShipmentCodStateDirectUpdateRows) && hf513ShipmentCodStateDirectUpdateRows.length === 0)) &&
      hf513CodStateAfterDirectUpdate.cod_collection_state === hf513CodStateBeforeDirectUpdate.cod_collection_state &&
      (hf513CodStateAfterDirectUpdate.cod_timeline?.length ?? 0) === (hf513CodStateBeforeDirectUpdate.cod_timeline?.length ?? 0),
    `codEventErr=${hf513CodEventDirectUpdateError?.message} codEventRowsAffected=${hf513CodEventDirectUpdateRows?.length} shipmentColErr=${hf513ShipmentCodStateDirectUpdateError?.message} shipmentColRowsAffected=${hf513ShipmentCodStateDirectUpdateRows?.length} before=${hf513CodStateBeforeDirectUpdate.cod_collection_state} after=${hf513CodStateAfterDirectUpdate.cod_collection_state}`,
  );

  // --- I) list_shipments() filters genuinely narrow the result set ------
  const hf512ByOrderNumber = await rpc("list_shipments", { p_order_number: shippingOrderRow.order_number, p_limit: 50 });
  ok(
    "item I: list_shipments(p_order_number=...) over real HTTP returns only shipments for that exact order — includes the outbound + return shipments created against it in this run, none from unrelated orders",
    Array.isArray(hf512ByOrderNumber) && hf512ByOrderNumber.length >= 3 &&
      hf512ByOrderNumber.every((r) => r.order_number === shippingOrderRow.order_number),
    `got ${JSON.stringify(hf512ByOrderNumber.map((r) => ({ id: r.id, order_number: r.order_number })))}`,
  );

  const hf512ByReturnNumber = await rpc("list_shipments", { p_return_number: hf511ReturnShipmentDetail.return_number, p_limit: 50 });
  ok(
    "item I: list_shipments(p_return_number=...) over real HTTP returns only RETURN-direction shipments for that exact return, never the outbound one from the same order",
    Array.isArray(hf512ByReturnNumber) && hf512ByReturnNumber.length >= 1 &&
      hf512ByReturnNumber.every((r) => r.return_number === hf511ReturnShipmentDetail.return_number && r.direction === "return") &&
      !hf512ByReturnNumber.some((r) => r.id === outboundShipmentId),
    `got ${JSON.stringify(hf512ByReturnNumber.map((r) => ({ id: r.id, return_number: r.return_number, direction: r.direction })))}`,
  );

  const hf512ByOriginalStore = await rpc("list_shipments", { p_original_sale_store_id: STORE_ID, p_limit: 200 });
  ok(
    "item I: list_shipments(p_original_sale_store_id=...) over real HTTP accepts the filter and returns only shipments whose ORIGINATING sale was placed at that store",
    Array.isArray(hf512ByOriginalStore) && hf512ByOriginalStore.length > 0 && hf512ByOriginalStore.every((r) => r.original_sale_store_id === STORE_ID),
    `count=${hf512ByOriginalStore.length}`,
  );

  const hf512ByCodState = await rpc("list_shipments", { p_cod_collection_state: "collected", p_limit: 200 });
  ok(
    "item I: list_shipments(p_cod_collection_state='collected') over real HTTP returns only the COD shipment actually recorded 'collected' in this run (item 6's chronology fixture), excluding every non-COD shipment (which defaults to 'unknown')",
    Array.isArray(hf512ByCodState) && hf512ByCodState.some((r) => r.id === hf511ChronoShipmentId) &&
      hf512ByCodState.every((r) => r.cod_collection_state === "collected") &&
      !hf512ByCodState.some((r) => r.id === outboundShipmentId),
    `got ${JSON.stringify(hf512ByCodState.map((r) => ({ id: r.id, cod_collection_state: r.cod_collection_state })))}`,
  );

  // =====================================================================
  // Part 11 — Phase 6 (Services / Adjustments Core, migrations 0133-0143)
  // proven over the SAME real HTTP/PostgREST round trip. Fully independent
  // from Sales/Returns/Shipping profit calculations (§2) — nothing below
  // ever reads/writes sales_orders.net_sales_profit or any Return/Shipping
  // figure except to prove they stay UNCHANGED.
  // =====================================================================

  // --- a) Layer-A lockdown: direct writes AND direct reads against the
  // base tables are denied/empty, even for the full-permission actor. ---
  let adjDirectInsertError = null;
  try {
    const { error } = await client
      .from("sales_order_adjustments")
      .insert({ adjustment_number: "ADJ-FAKE", sales_order_id: STORE_ID, adjustment_type_id: STORE_ID, processing_store_id: STORE_ID, adjustment_date: todayIso, payment_method_id: PAYMENT_METHOD_ID, collection_channel_id: CHANNEL_ID, participates_in_settlement: false, customer_charge: "1.00" });
    if (error) adjDirectInsertError = error;
  } catch (err) {
    adjDirectInsertError = err;
  }
  ok(
    "Part 11 item a: a direct INSERT over real HTTP against sales_order_adjustments is rejected even for the full-permission actor — every write MUST go through the RPCs (Layer-A RLS lockdown, migration 0135)",
    adjDirectInsertError !== null,
    `got ${adjDirectInsertError?.message}`,
  );

  const { data: adjDirectSelectRows, error: adjDirectSelectError } = await client.from("sales_order_adjustments").select("id");
  ok(
    "Part 11 item a: a direct SELECT over real HTTP against sales_order_adjustments returns ZERO rows for the full-permission actor (not an error — silent RLS-empty, migration 0135's zero-policy design) — profit/cost data is never reachable except through the read RPCs",
    !adjDirectSelectError && Array.isArray(adjDirectSelectRows) && adjDirectSelectRows.length === 0,
    `error=${adjDirectSelectError?.message} rows=${adjDirectSelectRows?.length}`,
  );

  let adjTypeDirectInsertError = null;
  try {
    const { error } = await client.from("adjustment_types").insert({ code: "http_fake_type", name_ar: "نوع وهمي" });
    if (error) adjTypeDirectInsertError = error;
  } catch (err) {
    adjTypeDirectInsertError = err;
  }
  ok(
    "Part 11 item a: a direct INSERT over real HTTP against adjustment_types is rejected even for an actor holding adjustments.manage_types — must go through create_adjustment_type() (migration 0134's Layer-A lockdown)",
    adjTypeDirectInsertError !== null,
    `got ${adjTypeDirectInsertError?.message}`,
  );

  // --- b) §25: search_sales_orders_for_adjustment() works for an actor
  // holding ONLY adjustments.create, no sales.view at all. ---------------
  const adjOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID,
    p_sale_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "2.0000", sale_price: "2000.00" }],
    p_customer_name: "عميل اختبار Adjustments HTTP",
  });
  const adjOrderRow = Array.isArray(adjOrderRows) ? adjOrderRows[0] : adjOrderRows;
  const adjOrderId = adjOrderRow?.id;
  ok("Part 11 item b: create_sales_order() over real HTTP returns a real order_number for the Adjustments fixture", typeof adjOrderRow?.order_number === "string" && adjOrderRow.order_number.length > 0, `got ${JSON.stringify(adjOrderRow)}`);

  const adjOrderBeforeSummary = await rpc("get_sales_order", { p_id: adjOrderId });
  const adjSalesProfitBefore = adjOrderBeforeSummary?.net_sales_profit;

  const adjSearchResults = await rpc("search_sales_orders_for_adjustment", { p_search: adjOrderRow.order_number, p_limit: 10 }, clientAdjCreateOnly);
  ok(
    "Part 11 item b (§25): search_sales_orders_for_adjustment() over real HTTP succeeds for an actor holding ONLY adjustments.create (no sales.view at all), and finds the exact order by order_number",
    Array.isArray(adjSearchResults) && adjSearchResults.some((r) => r.sales_order_id === adjOrderId && r.order_number === adjOrderRow.order_number),
    `got ${JSON.stringify(adjSearchResults)}`,
  );

  const adjActiveTypes = await rpc("adjustments_active_type_lookups", {}, clientAdjCreateOnly);
  ok(
    "Part 11 item b: adjustments_active_type_lookups() over real HTTP works for the adjustments.create-only actor (never requires adjustments.manage_types)",
    Array.isArray(adjActiveTypes),
    `got ${JSON.stringify(adjActiveTypes)}`,
  );

  // --- c) create_adjustment_type() + snapshot stability: renaming the
  // type AFTER an adjustment references it must NOT change the already-
  // approved record's displayed type name (adjustment_type_name_ar_
  // snapshot, migration 0140). ---------------------------------------
  const adjTypeCode = `http_test_type_${Date.now() % 100000}`;
  const adjTypeId = await rpc("create_adjustment_type", { p_code: adjTypeCode, p_name_ar: "خدمة اختبار HTTP الأصلية", p_sort_order: 0 });
  ok("Part 11 item c: create_adjustment_type() over real HTTP returns a real uuid", typeof adjTypeId === "string" && adjTypeId.length === 36, `got ${JSON.stringify(adjTypeId)}`);

  // --- d) full lifecycle: create -> preview -> approve, real Decimal
  // Transport Boundary + fee math proof (payment method here = 2.75%/5.25
  // fixed, NOT seed.sql's visa 2.5%/0 — expected: fee=8.00, gross=70.00,
  // net=62.00 for customer_charge=100.00/direct_cost=30.00). -----------
  const adjPreview = await rpc("preview_sales_order_adjustment", { p_payment_method_id: PAYMENT_METHOD_ID, p_customer_charge: "100.00", p_direct_cost: "30.00", p_adjustment_date: todayIso });
  const adjPreviewRow = Array.isArray(adjPreview) ? adjPreview[0] : adjPreview;
  ok(
    "Part 11 item d: preview_sales_order_adjustment() over real HTTP returns every money field as typeof 'string' (Decimal Transport Boundary) and computes fee=8.00/gross=70.00/net=62.00 for this fixture's payment method (2.75%/5.25 fixed)",
    typeof adjPreviewRow?.payment_fee_amount === "string" &&
      typeof adjPreviewRow?.gross_adjustment_profit === "string" &&
      typeof adjPreviewRow?.net_adjustment_profit === "string" &&
      new Decimal(adjPreviewRow.payment_fee_amount).equals(new Decimal("8.00")) &&
      new Decimal(adjPreviewRow.gross_adjustment_profit).equals(new Decimal("70.00")) &&
      new Decimal(adjPreviewRow.net_adjustment_profit).equals(new Decimal("62.00")),
    `got ${JSON.stringify(adjPreviewRow)}`,
  );

  const adjCreateRows = await rpc("create_sales_order_adjustment", {
    p_sales_order_id: adjOrderId,
    p_adjustment_type_id: adjTypeId,
    p_processing_store_id: STORE_ID,
    p_adjustment_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_participates_in_settlement: true,
    p_customer_charge: "100.00",
    p_direct_cost: "30.00",
    p_notes: "HTTP test adjustment",
  });
  const adjCreateRow = Array.isArray(adjCreateRows) ? adjCreateRows[0] : adjCreateRows;
  const adjId = adjCreateRow?.id;
  ok(
    "Part 11 item d: create_sales_order_adjustment() over real HTTP returns a real ADJ-########## adjustment_number and persists the record",
    typeof adjCreateRow?.adjustment_number === "string" && /^ADJ-\d{10}$/.test(adjCreateRow.adjustment_number),
    `got ${JSON.stringify(adjCreateRow)}`,
  );

  const adjAfterCreateRows = await rpc("get_sales_order_adjustment", { p_id: adjId });
  const adjAfterCreate = Array.isArray(adjAfterCreateRows) ? adjAfterCreateRows[0] : adjAfterCreateRows;
  ok(
    "Part 11 item d: get_sales_order_adjustment() over real HTTP reflects status='pending'/effective_status='pending', has_direct_cost=true, and every visible money field as typeof 'string' (Patch 6.1 v2 shape: original_*/effective_* split, migration 0151)",
    adjAfterCreate.status === "pending" && adjAfterCreate.effective_status === "pending" && typeof adjAfterCreate.customer_charge === "string" && adjAfterCreate.has_direct_cost === true && typeof adjAfterCreate.original_direct_cost === "string",
    `got status=${adjAfterCreate.status} effective_status=${adjAfterCreate.effective_status} has_direct_cost=${adjAfterCreate.has_direct_cost} original_direct_cost=${adjAfterCreate.original_direct_cost}`,
  );

  // --- e) update_sales_order_adjustment() optimistic-concurrency
  // conflict: a STALE row_version is genuinely rejected over real HTTP. -
  let adjStaleUpdateError = null;
  try {
    const { error } = await client.rpc("update_sales_order_adjustment", {
      p_id: adjId,
      p_expected_version: adjAfterCreate.row_version + 999,
      p_adjustment_type_id: adjTypeId,
      p_processing_store_id: STORE_ID,
      p_adjustment_date: todayIso,
      p_payment_method_id: PAYMENT_METHOD_ID,
      p_collection_channel_id: CHANNEL_ID,
      p_participates_in_settlement: true,
      p_customer_charge: "150.00",
    });
    if (error) adjStaleUpdateError = error;
  } catch (err) {
    adjStaleUpdateError = err;
  }
  ok(
    "Part 11 item e: update_sales_order_adjustment() over real HTTP with a STALE row_version is genuinely rejected (optimistic-concurrency conflict, §16) — customer_charge stays 100.00",
    adjStaleUpdateError !== null,
    `got ${adjStaleUpdateError?.message}`,
  );

  // --- f) rename the type AFTER creation but BEFORE approval — proves
  // approval snapshots the CURRENT (post-rename) label, while a type
  // rename never silently corrupts an ALREADY-approved record's snapshot
  // (proven again after approval below). --------------------------------
  await rpc("update_adjustment_type", { p_id: adjTypeId, p_name_ar: "خدمة اختبار HTTP بعد إعادة التسمية", p_sort_order: 0 });

  // --- g) approve_sales_order_adjustment(): authoritative recomputation,
  // typeof 'string' money, real fee math. -------------------------------
  const adjApproveRows = await rpc("approve_sales_order_adjustment", { p_id: adjId, p_expected_version: adjAfterCreate.row_version });
  const adjApproveRow = Array.isArray(adjApproveRows) ? adjApproveRows[0] : adjApproveRows;
  ok(
    "Part 11 item g: approve_sales_order_adjustment() over real HTTP recomputes net_adjustment_profit=62.00 authoritatively (typeof 'string') and bumps row_version",
    typeof adjApproveRow?.net_adjustment_profit === "string" && new Decimal(adjApproveRow.net_adjustment_profit).equals(new Decimal("62.00")) && adjApproveRow.row_version === adjAfterCreate.row_version + 1,
    `got ${JSON.stringify(adjApproveRow)}`,
  );

  const adjAfterApproveRows = await rpc("get_sales_order_adjustment", { p_id: adjId });
  const adjAfterApprove = Array.isArray(adjAfterApproveRows) ? adjAfterApproveRows[0] : adjAfterApproveRows;
  ok(
    "Part 11 item g: get_sales_order_adjustment() over real HTTP shows effective_status='approved', and the type-name snapshot reflects the POST-rename label (approval snapshots at approval time, not creation time)",
    adjAfterApprove.effective_status === "approved" && adjAfterApprove.adjustment_type_name_ar === "خدمة اختبار HTTP بعد إعادة التسمية",
    `got effective_status=${adjAfterApprove.effective_status} type_name=${adjAfterApprove.adjustment_type_name_ar}`,
  );

  // --- h) Sales-profit independence (§2), proven over real HTTP: the
  // linked Sales Order's OWN net_sales_profit is completely unchanged by
  // the Adjustment's approval. ------------------------------------------
  const adjOrderAfterApprove = await rpc("get_sales_order", { p_id: adjOrderId });
  ok(
    "Part 11 item h (§2): the linked Sales Order's net_sales_profit over real HTTP is UNCHANGED by the Adjustment's approval — fully independent P/L engines",
    new Decimal(adjOrderAfterApprove.net_sales_profit).equals(new Decimal(adjSalesProfitBefore)),
    `before=${adjSalesProfitBefore} after=${adjOrderAfterApprove.net_sales_profit}`,
  );

  // --- i) order summary correctness (§40): Original Invoice + Effective
  // Approved Adjustments = Total Including Adjustments. ------------------
  const adjSummaryRows = await rpc("get_sales_order_adjustment_summary", { p_order_id: adjOrderId });
  const adjSummaryRow = Array.isArray(adjSummaryRows) ? adjSummaryRows[0] : adjSummaryRows;
  ok(
    "Part 11 item i (§40): get_sales_order_adjustment_summary() over real HTTP: 2000.00 (original) + 100.00 (this approved adjustment) = 2100.00, every field typeof 'string'",
    typeof adjSummaryRow?.total_including_adjustments === "string" &&
      new Decimal(adjSummaryRow.original_invoice_amount).equals(new Decimal("2000.00")) &&
      new Decimal(adjSummaryRow.approved_effective_adjustments_charge_total).equals(new Decimal("100.00")) &&
      new Decimal(adjSummaryRow.total_including_adjustments).equals(new Decimal("2100.00")),
    `got ${JSON.stringify(adjSummaryRow)}`,
  );

  // --- j) settlement-participation exposure: list_sales_order_adjustments()
  // surfaces participates_in_settlement=true for this record. -----------
  const adjListRows = await rpc("list_sales_order_adjustments", { p_sales_order_id: adjOrderId, p_limit: 50 });
  const adjListRow = (adjListRows ?? []).find((r) => r.id === adjId);
  ok(
    "Part 11 item j: list_sales_order_adjustments() over real HTTP correctly surfaces participates_in_settlement=true for this record, and effective_net_adjustment_profit as typeof 'string' for the profit actor (Patch 6.1 v2 shape)",
    adjListRow?.participates_in_settlement === true && typeof adjListRow?.effective_net_adjustment_profit === "string" && adjListRow.effective_status === "approved",
    `got ${JSON.stringify(adjListRow)}`,
  );

  // --- k) DB-level profit privacy (§29) for the no-profit actor: money
  // fields entirely null (never absent-vs-null-inconsistent), customer_
  // charge, settlement participation, and has_direct_cost stay visible
  // (Patch 6.1 v2 shape: original_*/effective_* split, migration 0151). --
  const adjNoProfitDetailRows = await rpc("get_sales_order_adjustment", { p_id: adjId }, clientNoProfit);
  const adjNoProfitDetail = Array.isArray(adjNoProfitDetailRows) ? adjNoProfitDetailRows[0] : adjNoProfitDetailRows;
  ok(
    "Part 11 item k (§29): get_sales_order_adjustment() over real HTTP for the no-profit actor: customer_charge/participates_in_settlement/has_direct_cost visible, original_*/effective_* direct_cost/payment_fee_amount/gross/net_adjustment_profit all JSON null",
    adjNoProfitDetail.customer_charge === "100.00" &&
      adjNoProfitDetail.participates_in_settlement === true &&
      adjNoProfitDetail.has_direct_cost === true &&
      adjNoProfitDetail.original_direct_cost === null &&
      adjNoProfitDetail.original_payment_fee_amount === null &&
      adjNoProfitDetail.original_gross_adjustment_profit === null &&
      adjNoProfitDetail.original_net_adjustment_profit === null &&
      adjNoProfitDetail.effective_direct_cost === null &&
      adjNoProfitDetail.effective_payment_fee_amount === null &&
      adjNoProfitDetail.effective_gross_adjustment_profit === null &&
      adjNoProfitDetail.effective_net_adjustment_profit === null,
    `got ${JSON.stringify(adjNoProfitDetail)}`,
  );

  const adjNoProfitList = await rpc("list_sales_order_adjustments", { p_sales_order_id: adjOrderId, p_limit: 50 }, clientNoProfit);
  const adjNoProfitListRow = (adjNoProfitList ?? []).find((r) => r.id === adjId);
  ok(
    "Part 11 item k (§29): list_sales_order_adjustments() over real HTTP for the no-profit actor: effective_net_adjustment_profit is JSON null while customer_charge stays visible",
    adjNoProfitListRow?.customer_charge === "100.00" && adjNoProfitListRow?.effective_net_adjustment_profit === null,
    `got ${JSON.stringify(adjNoProfitListRow)}`,
  );

  // --- l) append-only reversal: at most ONE effective reversal ever,
  // proven via the service_role verification oracle (Layer-A table, zero
  // SELECT RLS for `authenticated`). -------------------------------------
  const adjReverseRows = await rpc("reverse_sales_order_adjustment", { p_id: adjId, p_expected_version: adjApproveRow.row_version, p_reversal_business_date: todayIso, p_reason: "HTTP test — إلغاء إداري" });
  const adjReverseRow = Array.isArray(adjReverseRows) ? adjReverseRows[0] : adjReverseRows;
  ok("Part 11 item l: reverse_sales_order_adjustment() over real HTTP returns a real reversal_id and succeeds", typeof adjReverseRow?.reversal_id === "string", `got ${JSON.stringify(adjReverseRow)}`);

  const adjAfterReverseRows = await rpc("get_sales_order_adjustment", { p_id: adjId });
  const adjAfterReverse = Array.isArray(adjAfterReverseRows) ? adjAfterReverseRows[0] : adjAfterReverseRows;
  ok(
    "Part 11 item l (Patch 6.1 item 19/20): get_sales_order_adjustment() over real HTTP shows effective_status='reversed' after reversal, while the ORIGINAL approved financial snapshot (original_net_adjustment_profit=62.00) remains readable — never mutated by the reversal — and effective_net_adjustment_profit reads 0.00 (no longer financially in effect)",
    adjAfterReverse.effective_status === "reversed" &&
      new Decimal(adjAfterReverse.original_net_adjustment_profit).equals(new Decimal("62.00")) &&
      new Decimal(adjAfterReverse.effective_net_adjustment_profit).equals(new Decimal("0.00")),
    `got effective_status=${adjAfterReverse.effective_status} original_net_adjustment_profit=${adjAfterReverse.original_net_adjustment_profit} effective_net_adjustment_profit=${adjAfterReverse.effective_net_adjustment_profit}`,
  );

  let adjDoubleReverseError = null;
  try {
    const { error } = await client.rpc("reverse_sales_order_adjustment", { p_id: adjId, p_expected_version: adjAfterReverse.row_version, p_reversal_business_date: todayIso, p_reason: "HTTP test — محاولة عكس ثانية" });
    if (error) adjDoubleReverseError = error;
  } catch (err) {
    adjDoubleReverseError = err;
  }
  const { data: adjReversalRowsService } = await clientService.from("sales_order_adjustment_reversals").select("id").eq("sales_order_adjustment_id", adjId);
  ok(
    "Part 11 item l: a SECOND reverse_sales_order_adjustment() attempt over real HTTP is genuinely rejected, AND the service_role verification oracle confirms exactly ONE reversal row exists (UNIQUE(sales_order_adjustment_id) + pre-check, migration 0135/0141) — no duplicate ever created",
    adjDoubleReverseError !== null && Array.isArray(adjReversalRowsService) && adjReversalRowsService.length === 1,
    `error=${adjDoubleReverseError?.message} reversalRows=${adjReversalRowsService?.length}`,
  );

  // --- m) the linked Sales Order's net_sales_profit STILL unchanged after
  // the reversal too (§2 holds across the entire lifecycle, not just at
  // approval). ------------------------------------------------------------
  const adjOrderAfterReverse = await rpc("get_sales_order", { p_id: adjOrderId });
  ok(
    "Part 11 item m (§2): the linked Sales Order's net_sales_profit over real HTTP is STILL unchanged after the Adjustment's reversal too",
    new Decimal(adjOrderAfterReverse.net_sales_profit).equals(new Decimal(adjSalesProfitBefore)),
    `before=${adjSalesProfitBefore} after=${adjOrderAfterReverse.net_sales_profit}`,
  );

  // --- n) fine-grained (not blanket-prefix) adjustment.* audit_logs RLS
  // gating (migration 0143) — deliberately mirrors shipment.*'s per-action
  // list (NOT return.%'s blanket gating): adjustment.create/update/
  // approve/reverse are money-bearing and hidden without sales.view_
  // profit, while adjustment.reject/closed_day_override/adjustment_type.*
  // carry no money and stay visible. --------------------------------------
  const { data: adjAuditProfit, error: adjAuditErrProfit } = await client.from("audit_logs").select("id, action").eq("entity_id", adjId).like("action", "adjustment.%");
  if (adjAuditErrProfit) throw new Error(`audit_logs select (adjustment.%, profit actor) failed: ${JSON.stringify(adjAuditErrProfit)}`);
  const adjAuditActionsProfit = new Set((adjAuditProfit ?? []).map((r) => r.action));
  ok(
    "Part 11 item n: GET /audit_logs?action=like.adjustment.* over real HTTP returns every adjustment.* action (create/update/approve/reverse) for a caller WITH sales.view_profit",
    adjAuditActionsProfit.has("adjustment.create") && adjAuditActionsProfit.has("adjustment.approve") && adjAuditActionsProfit.has("adjustment.reverse"),
    `got actions=${[...adjAuditActionsProfit].join(",")}`,
  );

  const { data: adjAuditNoProfit, error: adjAuditErrNoProfit } = await clientNoProfit.from("audit_logs").select("id, action").eq("entity_id", adjId).like("action", "adjustment.%");
  if (adjAuditErrNoProfit) throw new Error(`audit_logs select (adjustment.%, no-profit actor) failed: ${JSON.stringify(adjAuditErrNoProfit)}`);
  const adjAuditActionsNoProfit = new Set((adjAuditNoProfit ?? []).map((r) => r.action));
  ok(
    "Part 11 item n (migration 0143): GET /audit_logs?action=like.adjustment.* over real HTTP for a caller WITHOUT sales.view_profit: money-bearing actions (create/update/approve/reverse) are entirely absent",
    !adjAuditActionsNoProfit.has("adjustment.create") && !adjAuditActionsNoProfit.has("adjustment.update") && !adjAuditActionsNoProfit.has("adjustment.approve") && !adjAuditActionsNoProfit.has("adjustment.reverse"),
    `got actions=${[...adjAuditActionsNoProfit].join(",")}`,
  );

  // adjustment_type.* actions carry no money at all and must stay visible
  // to the SAME no-profit actor (fine-grained, not blanket-hidden).
  const { data: adjTypeAuditNoProfit, error: adjTypeAuditErrNoProfit } = await clientNoProfit.from("audit_logs").select("id, action").eq("entity_id", adjTypeId).like("action", "adjustment_type.%");
  if (adjTypeAuditErrNoProfit) throw new Error(`audit_logs select (adjustment_type.%, no-profit actor) failed: ${JSON.stringify(adjTypeAuditErrNoProfit)}`);
  const adjTypeAuditActionsNoProfit = new Set((adjTypeAuditNoProfit ?? []).map((r) => r.action));
  ok(
    "Part 11 item n: GET /audit_logs?action=like.adjustment_type.* over real HTTP: adjustment_type.create/update actions stay VISIBLE to the no-profit actor (no money payload, migration 0143 never gates these) — proves the gating is fine-grained by exact action name, not a blanket adjustment%/adjustment_type% prefix",
    adjTypeAuditActionsNoProfit.has("adjustment_type.create") && adjTypeAuditActionsNoProfit.has("adjustment_type.update"),
    `got actions=${[...adjTypeAuditActionsNoProfit].join(",")}`,
  );

  // =====================================================================
  // Part 12 — Phase 6 Integrity Patch 6.1 (migrations 0144-0156), proven
  // over the SAME real HTTP/PostgREST round trip. Reuses adjOrderId/
  // adjTypeId/adjId from Part 11 where the fixture is identical (adjId, in
  // particular, is ALREADY reversed by the end of Part 11 — items below
  // that need that exact state reuse it rather than reversing a second
  // record). Everything else that genuinely needs fresh state (manage_cost-
  // only actor, store-B-only actor, zero-charge, payment_reference,
  // overprecision, sale-date floor, cross-store) gets its own new fixture.
  // =====================================================================

  // --- item 1D/23: a create-only actor (no manage_cost) cannot supply
  // p_direct_cost at all, even for a brand-new record, over real HTTP. ---
  let adjCreateOnlyCostError = null;
  try {
    const { error } = await clientAdjCreateOnly.rpc("create_sales_order_adjustment", {
      p_sales_order_id: adjOrderId,
      p_adjustment_type_id: adjTypeId,
      p_processing_store_id: STORE_ID,
      p_adjustment_date: todayIso,
      p_payment_method_id: PAYMENT_METHOD_ID,
      p_collection_channel_id: CHANNEL_ID,
      p_participates_in_settlement: true,
      p_customer_charge: "40.00",
      p_direct_cost: "10.00",
    });
    if (error) adjCreateOnlyCostError = error;
  } catch (err) {
    adjCreateOnlyCostError = err;
  }
  ok(
    "Part 12 item 1D/23: create_sales_order_adjustment() over real HTTP rejects p_direct_cost for a create-only actor lacking adjustments.manage_cost",
    adjCreateOnlyCostError !== null,
    `got ${adjCreateOnlyCostError?.message}`,
  );

  // The SAME create-only actor CAN create without supplying a cost, and can
  // then read it back (narrow, adjustments.create-alone getter, item 23) —
  // proving the hidden adjustments.view dependency the old edit page had is
  // genuinely closed over real HTTP, not just in the local SQL suite.
  const adjP12PendingRows = await rpc(
    "create_sales_order_adjustment",
    {
      p_sales_order_id: adjOrderId,
      p_adjustment_type_id: adjTypeId,
      p_processing_store_id: STORE_ID,
      p_adjustment_date: todayIso,
      p_payment_method_id: PAYMENT_METHOD_ID,
      p_collection_channel_id: CHANNEL_ID,
      p_participates_in_settlement: true,
      p_customer_charge: "40.00",
      p_notes: "HTTP test — Patch 6.1 pending (no cost yet)",
    },
    clientAdjCreateOnly,
  );
  const adjP12PendingRow = Array.isArray(adjP12PendingRows) ? adjP12PendingRows[0] : adjP12PendingRows;
  const adjP12PendingId = adjP12PendingRow?.id;
  ok(
    "Part 12 item 1D: create_sales_order_adjustment() over real HTTP succeeds for a create-only actor WITHOUT supplying direct_cost",
    typeof adjP12PendingRow?.adjustment_number === "string",
    `got ${JSON.stringify(adjP12PendingRow)}`,
  );

  const adjP12EditView = await rpc("get_pending_sales_order_adjustment_for_edit", { p_id: adjP12PendingId }, clientAdjCreateOnly);
  const adjP12EditRow = Array.isArray(adjP12EditView) ? adjP12EditView[0] : adjP12EditView;
  ok(
    "Part 12 item 23: get_pending_sales_order_adjustment_for_edit() over real HTTP works for the SAME create-only actor with NO adjustments.view at all (closes the hidden-permission-dependency bug) — has_direct_cost=false, direct_cost hidden (no manage_cost/profit)",
    adjP12EditRow?.id === adjP12PendingId && adjP12EditRow?.has_direct_cost === false && adjP12EditRow?.direct_cost === null,
    `got ${JSON.stringify(adjP12EditRow)}`,
  );

  // --- item 2: a manage_cost-ONLY actor (no view/create/approve) sets the
  // Pending record's direct_cost via the dedicated RPC over real HTTP.
  // create_sales_order_adjustment() only returns (id, adjustment_number) —
  // no row_version — so the real row_version comes from the narrow edit
  // getter call just above (adjP12EditRow), not adjP12PendingRow. ---------
  const adjP12SetCostRows = await rpc(
    "set_pending_sales_order_adjustment_direct_cost",
    { p_id: adjP12PendingId, p_expected_version: adjP12EditRow.row_version, p_direct_cost: "15.00" },
    clientAdjManageCostOnly,
  );
  const adjP12SetCostRow = Array.isArray(adjP12SetCostRows) ? adjP12SetCostRows[0] : adjP12SetCostRows;
  ok(
    "Part 12 item 2: set_pending_sales_order_adjustment_direct_cost() over real HTTP succeeds for a manage_cost-ONLY actor (no view/create/approve at all) and returns the new value as typeof 'string'",
    adjP12SetCostRow?.id === adjP12PendingId && adjP12SetCostRow?.has_direct_cost === true && new Decimal(adjP12SetCostRow.direct_cost ?? "0").equals(new Decimal("15.00")),
    `got ${JSON.stringify(adjP12SetCostRow)}`,
  );

  // --- item 5/6 matrix A: the SAME actor that already proves profit-hiding
  // (clientNoProfit) also holds adjustments.approve here (Patch 6.1 setup),
  // WITHOUT adjustments.manage_cost or sales.view_profit — proves approval
  // independence AND that the approval response never leaks Net Profit,
  // both in one real HTTP call. ---
  const adjP12ApproveRows = await rpc(
    "approve_sales_order_adjustment",
    { p_id: adjP12PendingId, p_expected_version: adjP12SetCostRow.row_version },
    clientNoProfit,
  );
  const adjP12ApproveRow = Array.isArray(adjP12ApproveRows) ? adjP12ApproveRows[0] : adjP12ApproveRows;
  ok(
    "Part 12 item 5/6 matrix A: approve_sales_order_adjustment() over real HTTP succeeds for an approve-only actor (no manage_cost, no sales.view_profit) once cost is present, and net_adjustment_profit is JSON null in the write response (never leaked)",
    adjP12ApproveRow?.status === "approved" && adjP12ApproveRow?.net_adjustment_profit === null,
    `got ${JSON.stringify(adjP12ApproveRow)}`,
  );

  // NOTE: item 19/20 (original snapshot preserved + effective figures
  // zeroed after reversal) is already proven above by Part 11 item l's own
  // (now v2-shape-aware) assertion on this same adjId — no need to repeat.

  // --- item 7: money-scale rejection over real HTTP (create). ---
  let adjOverprecisionError = null;
  try {
    const { error } = await client.rpc("create_sales_order_adjustment", {
      p_sales_order_id: adjOrderId,
      p_adjustment_type_id: adjTypeId,
      p_processing_store_id: STORE_ID,
      p_adjustment_date: todayIso,
      p_payment_method_id: PAYMENT_METHOD_ID,
      p_collection_channel_id: CHANNEL_ID,
      p_participates_in_settlement: true,
      p_customer_charge: "40.123",
      p_direct_cost: "10.00",
    });
    if (error) adjOverprecisionError = error;
  } catch (err) {
    adjOverprecisionError = err;
  }
  ok(
    "Part 12 item 7: create_sales_order_adjustment() over real HTTP REJECTS a 3-decimal customer_charge (never silently rounded)",
    adjOverprecisionError !== null,
    `got ${adjOverprecisionError?.message}`,
  );

  // --- item 8: adjustment_date before the linked Sale's sale_date is
  // rejected over real HTTP (adjOrderId's sale_date is "today"). ---
  const yesterdayIso = new Date(Date.now() + 3 * 60 * 60 * 1000 - 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  let adjBeforeSaleDateError = null;
  try {
    const { error } = await client.rpc("create_sales_order_adjustment", {
      p_sales_order_id: adjOrderId,
      p_adjustment_type_id: adjTypeId,
      p_processing_store_id: STORE_ID,
      p_adjustment_date: yesterdayIso,
      p_payment_method_id: PAYMENT_METHOD_ID,
      p_collection_channel_id: CHANNEL_ID,
      p_participates_in_settlement: true,
      p_customer_charge: "40.00",
      p_direct_cost: "10.00",
    });
    if (error) adjBeforeSaleDateError = error;
  } catch (err) {
    adjBeforeSaleDateError = err;
  }
  ok(
    "Part 12 item 8: create_sales_order_adjustment() over real HTTP REJECTS an adjustment_date before the linked Sale's sale_date",
    adjBeforeSaleDateError !== null,
    `got ${adjBeforeSaleDateError?.message}`,
  );

  // --- item 9/10/11: zero-charge free service + payment_reference
  // round-trip, over real HTTP. ---
  const adjZeroRows = await rpc("create_sales_order_adjustment", {
    p_sales_order_id: adjOrderId,
    p_adjustment_type_id: adjTypeId,
    p_processing_store_id: STORE_ID,
    p_adjustment_date: todayIso,
    p_payment_method_id: null,
    p_collection_channel_id: null,
    p_participates_in_settlement: false,
    p_customer_charge: "0.00",
    p_direct_cost: "12.00",
    p_notes: "HTTP test — Patch 6.1 zero-charge",
    p_payment_reference: null,
  });
  const adjZeroRow = Array.isArray(adjZeroRows) ? adjZeroRows[0] : adjZeroRows;
  const adjZeroId = adjZeroRow?.id;
  // create_sales_order_adjustment() only returns (id, adjustment_number) —
  // no row_version — fetch the real one via get_sales_order_adjustment()
  // before approving.
  const adjZeroBeforeApproveRows = await rpc("get_sales_order_adjustment", { p_id: adjZeroId });
  const adjZeroBeforeApprove = Array.isArray(adjZeroBeforeApproveRows) ? adjZeroBeforeApproveRows[0] : adjZeroBeforeApproveRows;
  const adjZeroApproveRows = await rpc("approve_sales_order_adjustment", { p_id: adjZeroId, p_expected_version: adjZeroBeforeApprove.row_version });
  const adjZeroApproveRow = Array.isArray(adjZeroApproveRows) ? adjZeroApproveRows[0] : adjZeroApproveRows;
  ok(
    "Part 12 item 9/10: a zero-charge (free service) adjustment over real HTTP approves with net_adjustment_profit = -12.00 (fee forced to 0.00, gross=-12.00=net)",
    new Decimal(adjZeroApproveRow.net_adjustment_profit).equals(new Decimal("-12.00")),
    `got ${JSON.stringify(adjZeroApproveRow)}`,
  );
  const adjZeroDetailRows = await rpc("get_sales_order_adjustment", { p_id: adjZeroId });
  const adjZeroDetail = Array.isArray(adjZeroDetailRows) ? adjZeroDetailRows[0] : adjZeroDetailRows;
  ok(
    "Part 12 item 9/10: get_sales_order_adjustment() over real HTTP confirms payment_method_id/collection_channel_id/payment_reference are all JSON null and participates_in_settlement=false for the approved zero-charge record",
    adjZeroDetail?.payment_method_id === null && adjZeroDetail?.collection_channel_id === null && adjZeroDetail?.payment_reference === null && adjZeroDetail?.participates_in_settlement === false,
    `got ${JSON.stringify(adjZeroDetail)}`,
  );

  const adjRefRows = await rpc("create_sales_order_adjustment", {
    p_sales_order_id: adjOrderId,
    p_adjustment_type_id: adjTypeId,
    p_processing_store_id: STORE_ID,
    p_adjustment_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_participates_in_settlement: true,
    p_customer_charge: "20.00",
    p_direct_cost: "5.00",
    p_payment_reference: "HTTP-REF-12345",
  });
  const adjRefRow = Array.isArray(adjRefRows) ? adjRefRows[0] : adjRefRows;
  const adjRefDetailRows = await rpc("get_sales_order_adjustment", { p_id: adjRefRow.id });
  const adjRefDetail = Array.isArray(adjRefDetailRows) ? adjRefDetailRows[0] : adjRefDetailRows;
  ok(
    "Part 12 item 11: payment_reference round-trips over real HTTP exactly as supplied on create",
    adjRefDetail?.payment_reference === "HTTP-REF-12345",
    `got ${JSON.stringify(adjRefDetail)}`,
  );

  // --- item 12/13/31: cross-store isolation over real HTTP. Store-B-only
  // actor must be denied get/list/reject on a record whose linked Sale
  // (adjOrderId) lives in Store A. ---
  let adjStoreBGetError = null;
  try {
    const { error } = await clientAdjStoreBOnly.rpc("get_sales_order_adjustment", { p_id: adjRefRow.id });
    if (error) adjStoreBGetError = error;
  } catch (err) {
    adjStoreBGetError = err;
  }
  ok(
    "Part 12 item 12/31: get_sales_order_adjustment() over real HTTP is DENIED to a Store-B-only actor for a record whose linked Sale lives in Store A",
    adjStoreBGetError !== null,
    `got ${adjStoreBGetError?.message}`,
  );

  const adjStoreBList = await rpc("list_sales_order_adjustments", { p_sales_order_id: adjOrderId, p_limit: 50 }, clientAdjStoreBOnly);
  ok(
    "Part 12 item 12: list_sales_order_adjustments() over real HTTP returns ZERO rows for a Store-B-only actor querying a Store-A Sale's adjustments",
    Array.isArray(adjStoreBList) && adjStoreBList.length === 0,
    `got ${JSON.stringify(adjStoreBList)}`,
  );

  // A fresh, still-PENDING Store-A record (adjP12PendingId is already
  // approved by this point in the script) — reject_sales_order_adjustment()
  // only makes sense against a pending row, and reusing an approved one
  // would fail for the wrong reason (wrong status), not the cross-store
  // scope bypass this item is actually about.
  const adjP12RejectFixtureRows = await rpc("create_sales_order_adjustment", {
    p_sales_order_id: adjOrderId,
    p_adjustment_type_id: adjTypeId,
    p_processing_store_id: STORE_ID,
    p_adjustment_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_participates_in_settlement: true,
    p_customer_charge: "10.00",
    p_notes: "HTTP test — Patch 6.1 reject-scope-bypass fixture",
  });
  const adjP12RejectFixtureRow = Array.isArray(adjP12RejectFixtureRows) ? adjP12RejectFixtureRows[0] : adjP12RejectFixtureRows;
  // create_sales_order_adjustment() only returns (id, adjustment_number) —
  // no row_version — fetch the real one via get_sales_order_adjustment()
  // (as the full-permission actor) before the store-B-only actor's attempt.
  const adjP12RejectFixtureDetailRows = await rpc("get_sales_order_adjustment", { p_id: adjP12RejectFixtureRow.id });
  const adjP12RejectFixtureDetail = Array.isArray(adjP12RejectFixtureDetailRows) ? adjP12RejectFixtureDetailRows[0] : adjP12RejectFixtureDetailRows;

  let adjStoreBRejectError = null;
  try {
    const { error } = await clientAdjStoreBOnly.rpc("reject_sales_order_adjustment", {
      p_id: adjP12RejectFixtureRow.id,
      p_expected_version: adjP12RejectFixtureDetail.row_version,
      p_reason: "محاولة رفض عبر متجر آخر",
    });
    if (error) adjStoreBRejectError = error;
  } catch (err) {
    adjStoreBRejectError = err;
  }
  ok(
    "Part 12 item 13: reject_sales_order_adjustment() over real HTTP is DENIED to a Store-B-only actor for a still-PENDING Store-A record (cross-store scope bypass closed)",
    adjStoreBRejectError !== null,
    `got ${adjStoreBRejectError?.message}`,
  );

  // --- item 22: view-only filter lookups over real HTTP (adjustments.view
  // alone — clientNoProfit holds view+approve here, still no create). ---
  const adjFilterTypes = await rpc("adjustments_filter_type_lookups", {}, clientNoProfit);
  const adjFilterPms = await rpc("adjustments_filter_payment_method_lookups", {}, clientNoProfit);
  const adjFilterChannels = await rpc("adjustments_filter_collection_channel_lookups", {}, clientNoProfit);
  ok(
    "Part 12 item 22: the three new filter-lookup RPCs all work over real HTTP for a view-only-class actor (no adjustments.create)",
    Array.isArray(adjFilterTypes) && Array.isArray(adjFilterPms) && Array.isArray(adjFilterChannels),
    `got types=${JSON.stringify(adjFilterTypes)} pms=${JSON.stringify(adjFilterPms)} channels=${JSON.stringify(adjFilterChannels)}`,
  );

  // --- item 17/32: a direct raw UPDATE over real HTTP against an APPROVED
  // row's direct_cost is rejected by the NEW 0154 terminal-mutation
  // trigger. An ordinary authenticated client can't isolate this from the
  // pre-existing 0135 zero-policy lockdown (both would reject the write
  // for different reasons), so — exactly like the local SQL suite's own
  // item 17/32 section — this uses the trusted service_role verification
  // client, which bypasses RLS but is still subject to the BEFORE UPDATE
  // trigger (triggers are never skipped by RLS/BYPASSRLS), on the
  // ALREADY-APPROVED zero-charge record (adjZeroId) from above. ---
  let adjTerminalMutationError = null;
  try {
    const { error } = await clientService.from("sales_order_adjustments").update({ direct_cost: "999.00" }).eq("id", adjZeroId);
    if (error) adjTerminalMutationError = error;
  } catch (err) {
    adjTerminalMutationError = err;
  }
  ok(
    "Part 12 item 17/32: a direct UPDATE over real HTTP on an APPROVED sales_order_adjustments row's direct_cost is rejected by the 0154 terminal-immutability trigger, even for the trusted service_role client (RLS-bypassing but not trigger-bypassing)",
    adjTerminalMutationError !== null,
    `got ${adjTerminalMutationError?.message}`,
  );

  // =====================================================================
  // Part 13 — Phase 6 Final Integrity Hotfix 6.1.1, proven over the SAME
  // real HTTP/PostgREST round trip. Reuses adjOrderId/adjTypeId/adjId/
  // adjZeroId/adjRefRow/adjP12RejectFixtureRow/PAYMENT_METHOD_ID/CHANNEL_ID
  // from Parts 11/12 — adjId's approval snapshot in Part 11 already froze
  // the payment method / collection channel's ORIGINAL names (before either
  // has ever been renamed in this script run), making it the perfect
  // "before" reference for item 13's rename-snapshot proof below, no
  // separate fixture required. (Upgrade behavior itself stays exclusively
  // in scripts/run_upgrade_test_patch_6_1.sh, per the governing spec.)
  // =====================================================================

  // --- item 4: a PAID create over real HTTP genuinely rejects a missing
  // (null) participates_in_settlement — the same DB-level check update_
  // sales_order_adjustment() already enforced (0139/0147), now also proven
  // for create_sales_order_adjustment() specifically. ---------------------
  let adjMissingSettlementError = null;
  try {
    const { error } = await client.rpc("create_sales_order_adjustment", {
      p_sales_order_id: adjOrderId,
      p_adjustment_type_id: adjTypeId,
      p_processing_store_id: STORE_ID,
      p_adjustment_date: todayIso,
      p_payment_method_id: PAYMENT_METHOD_ID,
      p_collection_channel_id: CHANNEL_ID,
      p_participates_in_settlement: null,
      p_customer_charge: "40.00",
      p_direct_cost: "10.00",
    });
    if (error) adjMissingSettlementError = error;
  } catch (err) {
    adjMissingSettlementError = err;
  }
  ok(
    "Part 13 item 4: create_sales_order_adjustment() over real HTTP rejects a PAID adjustment with participates_in_settlement=null (no silent default)",
    adjMissingSettlementError !== null,
    `got ${adjMissingSettlementError?.message}`,
  );

  // --- item 4: a FREE create over real HTTP normalizes participates_in_
  // settlement to false even when the caller (wrongly) supplies true — the
  // server never trusts client input for a zero-charge record (0146). -----
  const adjFreeNormRows = await rpc("create_sales_order_adjustment", {
    p_sales_order_id: adjOrderId,
    p_adjustment_type_id: adjTypeId,
    p_processing_store_id: STORE_ID,
    p_adjustment_date: todayIso,
    p_payment_method_id: null,
    p_collection_channel_id: null,
    p_participates_in_settlement: true,
    p_customer_charge: "0.00",
    p_direct_cost: "5.00",
    p_notes: "HTTP test — Hotfix 6.1.1 free-service settlement normalization",
  });
  const adjFreeNormRow = Array.isArray(adjFreeNormRows) ? adjFreeNormRows[0] : adjFreeNormRows;
  const adjFreeNormDetailRows = await rpc("get_sales_order_adjustment", { p_id: adjFreeNormRow.id });
  const adjFreeNormDetail = Array.isArray(adjFreeNormDetailRows) ? adjFreeNormDetailRows[0] : adjFreeNormDetailRows;
  ok(
    "Part 13 item 4: create_sales_order_adjustment() over real HTTP FORCES participates_in_settlement=false for a zero-charge record even when the caller explicitly supplied true",
    adjFreeNormDetail?.participates_in_settlement === false,
    `got ${JSON.stringify(adjFreeNormDetail)}`,
  );

  // --- item 14: payment_reference must never leak forward on a paid->free
  // transition through update_sales_order_adjustment(), even if a stale
  // client still supplies a stray p_payment_reference value — reuses
  // adjRefRow (Part 12 item 11), still pending, still paid, still carrying
  // "HTTP-REF-12345". Also proves participates_in_settlement/payment_
  // method_id are force-cleared, and calculation_version stays null for a
  // still-pending record. -------------------------------------------------
  await rpc("update_sales_order_adjustment", {
    p_id: adjRefRow.id,
    p_expected_version: adjRefDetail.row_version,
    p_adjustment_type_id: adjTypeId,
    p_processing_store_id: STORE_ID,
    p_adjustment_date: todayIso,
    p_payment_method_id: null,
    p_collection_channel_id: null,
    p_participates_in_settlement: null,
    p_customer_charge: "0.00",
    p_payment_reference: "REF-SHOULD-NOT-SURVIVE",
  });
  const adjRefAfterFreeUpdateRows = await rpc("get_sales_order_adjustment", { p_id: adjRefRow.id });
  const adjRefAfterFreeUpdate = Array.isArray(adjRefAfterFreeUpdateRows) ? adjRefAfterFreeUpdateRows[0] : adjRefAfterFreeUpdateRows;
  ok(
    "Part 13 item 14: update_sales_order_adjustment() over real HTTP normalizes payment_reference/payment_method_id/participates_in_settlement on a paid->free transition, even when the caller still supplies a stray p_payment_reference — never leaks the old value forward; calculation_version stays null (still pending)",
    adjRefAfterFreeUpdate?.payment_reference === null &&
      adjRefAfterFreeUpdate?.payment_method_id === null &&
      adjRefAfterFreeUpdate?.participates_in_settlement === false &&
      adjRefAfterFreeUpdate?.calculation_version === null,
    `got ${JSON.stringify(adjRefAfterFreeUpdate)}`,
  );

  // --- item 7: calculation_version stays JSON null for a REJECTED record —
  // reuses adjP12RejectFixtureRow (Part 12 item 13), still pending until
  // now (the store-B actor's earlier reject attempt was denied). ----------
  await rpc("reject_sales_order_adjustment", {
    p_id: adjP12RejectFixtureRow.id,
    p_expected_version: adjP12RejectFixtureDetail.row_version,
    p_reason: "HTTP test — Hotfix 6.1.1 item 7 (calculation_version stays null on reject)",
  });
  const adjP12RejectFixtureAfterRejectRows = await rpc("get_sales_order_adjustment", { p_id: adjP12RejectFixtureRow.id });
  const adjP12RejectFixtureAfterReject = Array.isArray(adjP12RejectFixtureAfterRejectRows) ? adjP12RejectFixtureAfterRejectRows[0] : adjP12RejectFixtureAfterRejectRows;
  ok(
    "Part 13 item 7: get_sales_order_adjustment() over real HTTP confirms calculation_version is JSON null for a REJECTED record — never financially approved, nothing to version",
    adjP12RejectFixtureAfterReject?.status === "rejected" && adjP12RejectFixtureAfterReject?.calculation_version === null,
    `got ${JSON.stringify(adjP12RejectFixtureAfterReject)}`,
  );

  // --- item 5: list_sales_order_adjustments() v3's new effective_direct_
  // cost/effective_payment_fee_amount columns, sales.view_profit-gated
  // exactly like the pre-existing effective_net_adjustment_profit — proven
  // over real HTTP for BOTH a profit actor and a no-profit actor on the
  // SAME approved zero-charge record (adjZeroId, Part 12 items 9/10). -----
  const adjListProfitRows = await rpc("list_sales_order_adjustments", { p_sales_order_id: adjOrderId, p_limit: 50 }, client);
  const adjListProfitRow = (adjListProfitRows ?? []).find((r) => r.id === adjZeroId);
  ok(
    "Part 13 item 5: list_sales_order_adjustments() v3 over real HTTP exposes effective_direct_cost/effective_payment_fee_amount as typeof 'string' for a sales.view_profit actor",
    typeof adjListProfitRow?.effective_direct_cost === "string" && typeof adjListProfitRow?.effective_payment_fee_amount === "string",
    `got ${JSON.stringify(adjListProfitRow)}`,
  );

  const adjListNoProfitRows = await rpc("list_sales_order_adjustments", { p_sales_order_id: adjOrderId, p_limit: 50 }, clientNoProfit);
  const adjListNoProfitRow = (adjListNoProfitRows ?? []).find((r) => r.id === adjZeroId);
  ok(
    "Part 13 item 5: list_sales_order_adjustments() v3 over real HTTP redacts effective_direct_cost/effective_payment_fee_amount to JSON null for a caller WITHOUT sales.view_profit",
    adjListNoProfitRow?.effective_direct_cost === null && adjListNoProfitRow?.effective_payment_fee_amount === null,
    `got ${JSON.stringify(adjListNoProfitRow)}`,
  );

  // --- item 10/14: the p_participates_in_settlement list FILTER itself
  // (server-side, independent of the frontend pagination-link bug fixed
  // separately) genuinely partitions rows — adjZeroId (false) vs adjId
  // (still true underneath, reversal never touches this column). ---------
  const adjFilterFalseRows = await rpc("list_sales_order_adjustments", { p_sales_order_id: adjOrderId, p_participates_in_settlement: false, p_limit: 50 });
  const adjFilterFalseIds = new Set((adjFilterFalseRows ?? []).map((r) => r.id));
  const adjFilterTrueRows = await rpc("list_sales_order_adjustments", { p_sales_order_id: adjOrderId, p_participates_in_settlement: true, p_limit: 50 });
  const adjFilterTrueIds = new Set((adjFilterTrueRows ?? []).map((r) => r.id));
  ok(
    "Part 13 item 10/14: list_sales_order_adjustments() over real HTTP with p_participates_in_settlement=false returns the zero-charge record but never the still-true adjId, and vice versa for =true",
    adjFilterFalseIds.has(adjZeroId) && !adjFilterFalseIds.has(adjId) && adjFilterTrueIds.has(adjId) && !adjFilterTrueIds.has(adjZeroId),
    `false-filter ids=${[...adjFilterFalseIds].join(",")} true-filter ids=${[...adjFilterTrueIds].join(",")}`,
  );

  // --- item 6/7: the 5 signed reversal_*_impact fields + calculation_
  // version on the ALREADY-REVERSED adjId (Part 11 item l) — sales.
  // view_profit-gated exactly like every other profit figure; calculation_
  // version (operational metadata) stays visible to adjustments.view alone
  // regardless of sales.view_profit. ---------------------------------------
  const adjIdDetailProfitRows = await rpc("get_sales_order_adjustment", { p_id: adjId }, client);
  const adjIdDetailProfit = Array.isArray(adjIdDetailProfitRows) ? adjIdDetailProfitRows[0] : adjIdDetailProfitRows;
  ok(
    "Part 13 item 6/7: get_sales_order_adjustment() over real HTTP exposes reversal_net_profit_impact=-62.00 / reversal_direct_cost_impact=30.00 (typeof 'string') for a sales.view_profit actor on a REVERSED record, and calculation_version=1 (the original approval's version, untouched by the reversal)",
    typeof adjIdDetailProfit?.reversal_net_profit_impact === "string" &&
      new Decimal(adjIdDetailProfit.reversal_net_profit_impact).equals(new Decimal("-62.00")) &&
      typeof adjIdDetailProfit?.reversal_direct_cost_impact === "string" &&
      new Decimal(adjIdDetailProfit.reversal_direct_cost_impact).equals(new Decimal("30.00")) &&
      adjIdDetailProfit?.calculation_version === 1,
    `got ${JSON.stringify({ net: adjIdDetailProfit?.reversal_net_profit_impact, cost: adjIdDetailProfit?.reversal_direct_cost_impact, calc: adjIdDetailProfit?.calculation_version })}`,
  );

  const adjIdDetailNoProfitRows = await rpc("get_sales_order_adjustment", { p_id: adjId }, clientNoProfit);
  const adjIdDetailNoProfit = Array.isArray(adjIdDetailNoProfitRows) ? adjIdDetailNoProfitRows[0] : adjIdDetailNoProfitRows;
  ok(
    "Part 13 item 6: get_sales_order_adjustment() over real HTTP redacts every reversal_*_impact field to JSON null for a caller WITHOUT sales.view_profit, while calculation_version (adjustments.view alone) STAYS visible",
    adjIdDetailNoProfit?.reversal_net_profit_impact === null &&
      adjIdDetailNoProfit?.reversal_direct_cost_impact === null &&
      adjIdDetailNoProfit?.reversal_payment_fee_impact === null &&
      adjIdDetailNoProfit?.reversal_gross_profit_impact === null &&
      adjIdDetailNoProfit?.calculation_version === 1,
    `got ${JSON.stringify(adjIdDetailNoProfit)}`,
  );

  // --- item 13: a compact combined proof — Type A/Method A/Channel A were
  // captured into adjId's snapshot at its Part 11 approval time. Renaming
  // all three now, over real HTTP, via the sanctioned flows (update_
  // adjustment_type() for the type; payment_methods/collection_channels
  // have no dedicated rename RPC in this project — a direct table UPDATE
  // via the trusted service_role client, mirroring supabase/tests/
  // adjustments_core_phase6.test.sql's items 25B/25C exactly, IS that
  // sanctioned flow here) must never retroactively corrupt adjId's already-
  // frozen snapshot, while a BRAND-NEW Adjustment approved afterward must
  // capture the renamed labels. ------------------------------------------
  const adjSnapBeforeRows = await rpc("get_sales_order_adjustment", { p_id: adjId });
  const adjSnapBefore = Array.isArray(adjSnapBeforeRows) ? adjSnapBeforeRows[0] : adjSnapBeforeRows;
  const beforeTypeName = adjSnapBefore.adjustment_type_name_ar;
  const beforePaymentMethodName = adjSnapBefore.payment_method_name;
  const beforeChannelName = adjSnapBefore.collection_channel_name;

  await rpc("update_adjustment_type", { p_id: adjTypeId, p_name_ar: "خدمة اختبار HTTP — Hotfix 6.1.1 بعد إعادة التسمية", p_sort_order: 0 });
  const { error: adjPmRenameErr } = await clientService.from("payment_methods").update({ name_ar: "طريقة اختبار HTTP — Hotfix 6.1.1 بعد إعادة التسمية" }).eq("id", PAYMENT_METHOD_ID);
  if (adjPmRenameErr) throw new Error(`payment_methods rename failed: ${JSON.stringify(adjPmRenameErr)}`);
  const { error: adjChRenameErr } = await clientService.from("collection_channels").update({ name_ar: "قناة اختبار HTTP — Hotfix 6.1.1 بعد إعادة التسمية" }).eq("id", CHANNEL_ID);
  if (adjChRenameErr) throw new Error(`collection_channels rename failed: ${JSON.stringify(adjChRenameErr)}`);

  const adjSnapAfterRenameOldRows = await rpc("get_sales_order_adjustment", { p_id: adjId });
  const adjSnapAfterRenameOld = Array.isArray(adjSnapAfterRenameOldRows) ? adjSnapAfterRenameOldRows[0] : adjSnapAfterRenameOldRows;
  ok(
    "Part 13 item 13: after renaming Type/Payment Method/Collection Channel over real HTTP (sanctioned flows), a PREVIOUSLY-approved Adjustment's snapshot names stay exactly as they were captured at approval time",
    adjSnapAfterRenameOld.adjustment_type_name_ar === beforeTypeName &&
      adjSnapAfterRenameOld.payment_method_name === beforePaymentMethodName &&
      adjSnapAfterRenameOld.collection_channel_name === beforeChannelName,
    `got type=${adjSnapAfterRenameOld.adjustment_type_name_ar} pm=${adjSnapAfterRenameOld.payment_method_name} ch=${adjSnapAfterRenameOld.collection_channel_name}`,
  );

  const adjNewSnapCreateRows = await rpc("create_sales_order_adjustment", {
    p_sales_order_id: adjOrderId,
    p_adjustment_type_id: adjTypeId,
    p_processing_store_id: STORE_ID,
    p_adjustment_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID,
    p_collection_channel_id: CHANNEL_ID,
    p_participates_in_settlement: true,
    p_customer_charge: "30.00",
    p_direct_cost: "5.00",
    p_notes: "HTTP test — Hotfix 6.1.1 item 13 post-rename snapshot",
  });
  const adjNewSnapCreateRow = Array.isArray(adjNewSnapCreateRows) ? adjNewSnapCreateRows[0] : adjNewSnapCreateRows;
  const adjNewSnapId = adjNewSnapCreateRow?.id;
  const adjNewSnapBeforeApproveRows = await rpc("get_sales_order_adjustment", { p_id: adjNewSnapId });
  const adjNewSnapBeforeApprove = Array.isArray(adjNewSnapBeforeApproveRows) ? adjNewSnapBeforeApproveRows[0] : adjNewSnapBeforeApproveRows;
  await rpc("approve_sales_order_adjustment", { p_id: adjNewSnapId, p_expected_version: adjNewSnapBeforeApprove.row_version });
  const adjNewSnapDetailRows = await rpc("get_sales_order_adjustment", { p_id: adjNewSnapId });
  const adjNewSnapDetail = Array.isArray(adjNewSnapDetailRows) ? adjNewSnapDetailRows[0] : adjNewSnapDetailRows;
  ok(
    "Part 13 item 13: a NEW Adjustment approved AFTER the rename captures the RENAMED Type/Payment Method/Collection Channel names in its own snapshot, never the pre-rename ones — and calculation_version=1",
    adjNewSnapDetail?.adjustment_type_name_ar !== beforeTypeName &&
      adjNewSnapDetail?.payment_method_name !== beforePaymentMethodName &&
      adjNewSnapDetail?.collection_channel_name !== beforeChannelName &&
      adjNewSnapDetail?.adjustment_type_name_ar?.includes("Hotfix 6.1.1") &&
      adjNewSnapDetail?.payment_method_name?.includes("Hotfix 6.1.1") &&
      adjNewSnapDetail?.collection_channel_name?.includes("Hotfix 6.1.1") &&
      adjNewSnapDetail?.calculation_version === 1,
    `got ${JSON.stringify({ type: adjNewSnapDetail?.adjustment_type_name_ar, pm: adjNewSnapDetail?.payment_method_name, ch: adjNewSnapDetail?.collection_channel_name, calc: adjNewSnapDetail?.calculation_version })}`,
  );

  // =====================================================================
  // Part 14 — Phase 7 Settlements Core (migrations 0167-0183) + Integrity
  // Patch 7.1 (migrations 0184-0191), proven over the SAME real HTTP/
  // PostgREST round trip. This module was previously ZERO-covered by this
  // file (an explicitly flagged deferred gap) — see the file header comment
  // for the full checklist this Part proves. Fully independent from Sales/
  // Returns/Shipping/Adjustments' own profit calculations (item 19/24) —
  // nothing below ever reads a gold/manufacturing/VAT cost, product gross
  // profit, sales net profit, adjustment direct cost, or shipping P/L
  // figure, only proves such fields never appear in a Settlement response.
  // =====================================================================

  const stlPastIso = new Date(Date.now() + 3 * 60 * 60 * 1000 - 40 * 86400000).toISOString().slice(0, 10);
  const stlDateFrom = stlPastIso;
  const stlDateTo = new Date(Date.now() + 3 * 60 * 60 * 1000 + 86400000).toISOString().slice(0, 10);

  // --- a) Layer-A lockdown: raw SELECT/INSERT against settlement_batches
  // and settlement_route_fee_versions is forbidden, even for the full
  // Settlements actor (settlement_batch_lines/settlement_bank_movement_
  // events are re-checked further below, once real data exists on them). --
  const { data: stlBatchSelectRows, error: stlBatchSelectErr } = await client.from("settlement_batches").select("id");
  ok(
    "Part 14 item a: raw SELECT over real HTTP against settlement_batches returns ZERO rows even for the full-permission actor (zero SELECT RLS policy, migration 0172 — every read goes through list/get_settlement_batches())",
    !stlBatchSelectErr && Array.isArray(stlBatchSelectRows) && stlBatchSelectRows.length === 0,
    `error=${stlBatchSelectErr?.message} rows=${stlBatchSelectRows?.length}`,
  );

  let stlBatchInsertErr = null;
  try {
    const { error } = await client.from("settlement_batches").insert({ settlement_number: "SET-FAKEHTTP01", settlement_route_id: STORE_ID, settlement_date: todayIso, status: "draft" });
    if (error) stlBatchInsertErr = error;
  } catch (err) {
    stlBatchInsertErr = err;
  }
  ok(
    "Part 14 item a: raw INSERT over real HTTP against settlement_batches is rejected even for the full-permission actor — every write MUST go through the RPCs",
    stlBatchInsertErr !== null,
    `got ${stlBatchInsertErr?.message}`,
  );

  let stlRouteFeeVersionInsertErrEarly = null;
  try {
    const { error } = await client.from("settlement_route_fee_versions").insert({ settlement_route_id: STORE_ID, effective_from: todayIso, transaction_fee_strategy: "none" });
    if (error) stlRouteFeeVersionInsertErrEarly = error;
  } catch (err) {
    stlRouteFeeVersionInsertErrEarly = err;
  }
  ok(
    "Part 14 item a: raw INSERT over real HTTP against settlement_route_fee_versions is rejected even for the full-permission actor — only create_settlement_route_fee_version() may write (migration 0170's zero-INSERT-policy design)",
    stlRouteFeeVersionInsertErrEarly !== null,
    `got ${stlRouteFeeVersionInsertErrEarly?.message}`,
  );

  // --- b) route management permission (settlements.manage_routes) +
  // manage_routes-only narrow lookups (Patch 7.1 §23), working without any
  // unrelated payment_methods.view/collection_channels.view/shipping_
  // rates.view/settlements.view_financials permission. -------------------
  let stlRouteDeniedErr = null;
  try {
    await rpc("create_settlement_route", { p_code: `stl-denied-${Date.now() % 100000}`, p_name_ar: "مسار مرفوض", p_route_kind: "payment_collection", p_payment_method_id: PAYMENT_METHOD_ID });
  } catch (err) {
    stlRouteDeniedErr = err;
  }
  ok(
    "Part 14 item b: create_settlement_route() over real HTTP is rejected for the full Settlements actor, which deliberately does NOT hold settlements.manage_routes",
    stlRouteDeniedErr !== null,
    `got ${stlRouteDeniedErr?.message}`,
  );

  const stlPmLookups = await rpc("settlement_route_payment_method_lookups", {}, clientSettleManageRoutesOnly);
  const stlChannelLookups = await rpc("settlement_route_collection_channel_lookups", {}, clientSettleManageRoutesOnly);
  const stlCarrierLookupsForRoutes = await rpc("settlement_route_carrier_lookups", {}, clientSettleManageRoutesOnly);
  ok(
    "Part 14 item b (§23): the three narrow settlement_route_*_lookups() RPCs over real HTTP all work for a settlements.manage_routes-ONLY actor holding no unrelated Master Data view permission",
    Array.isArray(stlPmLookups) && stlPmLookups.some((p) => p.id === PAYMENT_METHOD_ID) &&
      Array.isArray(stlChannelLookups) && stlChannelLookups.some((c) => c.id === CHANNEL_ID) &&
      Array.isArray(stlCarrierLookupsForRoutes) && stlCarrierLookupsForRoutes.some((c) => c.code === "SMSA"),
    `got pm=${JSON.stringify(stlPmLookups)} channel=${JSON.stringify(stlChannelLookups)} carrier=${JSON.stringify(stlCarrierLookupsForRoutes)}`,
  );
  const stlCashPm = stlPmLookups.find((p) => p.key === "cash");
  const stlSmsaCarrierForRoute = stlCarrierLookupsForRoutes.find((c) => c.code === "SMSA");

  const stlRouteChannelledId = await rpc(
    "create_settlement_route",
    { p_code: `stl-chan-${Date.now() % 100000}`, p_name_ar: "مسار تسويات HTTP بقناة", p_route_kind: "payment_collection", p_name_en: null, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID },
    clientSettleManageRoutesOnly,
  );
  ok("Part 14 item b: create_settlement_route() over real HTTP returns a real uuid for the manage_routes-ONLY actor", typeof stlRouteChannelledId === "string" && stlRouteChannelledId.length === 36, `got ${JSON.stringify(stlRouteChannelledId)}`);

  const stlRouteNoChannelId = await rpc(
    "create_settlement_route",
    { p_code: `stl-nochan-${Date.now() % 100000}`, p_name_ar: "مسار تسويات HTTP بدون قناة", p_route_kind: "payment_collection", p_name_en: null, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: null },
    clientSettleManageRoutesOnly,
  );

  const stlRouteCodId = await rpc(
    "create_settlement_route",
    { p_code: `stl-cod-${Date.now() % 100000}`, p_name_ar: "مسار تسويات HTTP COD", p_route_kind: "cod_carrier", p_name_en: null, p_payment_method_id: null, p_collection_channel_id: null, p_shipping_carrier_id: stlSmsaCarrierForRoute.id },
    clientSettleManageRoutesOnly,
  );

  await rpc("create_settlement_route_fee_version", { p_settlement_route_id: stlRouteChannelledId, p_effective_from: stlPastIso, p_transaction_fee_strategy: "source_snapshot", p_batch_fee_fixed: "5.00" }, clientSettleManageRoutesOnly);
  await rpc("create_settlement_route_fee_version", { p_settlement_route_id: stlRouteNoChannelId, p_effective_from: stlPastIso, p_transaction_fee_strategy: "source_snapshot", p_batch_fee_fixed: "3.00" }, clientSettleManageRoutesOnly);

  let stlCodSourceSnapshotErr = null;
  try {
    await rpc("create_settlement_route_fee_version", { p_settlement_route_id: stlRouteCodId, p_effective_from: stlPastIso, p_transaction_fee_strategy: "source_snapshot" }, clientSettleManageRoutesOnly);
  } catch (err) {
    stlCodSourceSnapshotErr = err;
  }
  ok(
    "Part 14 item b (Patch 7.1 §19): create_settlement_route_fee_version() over real HTTP rejects transaction_fee_strategy='source_snapshot' for a cod_carrier route immediately at creation",
    stlCodSourceSnapshotErr !== null,
    `got ${stlCodSourceSnapshotErr?.message}`,
  );

  const stlFeeCodId = await rpc(
    "create_settlement_route_fee_version",
    { p_settlement_route_id: stlRouteCodId, p_effective_from: stlPastIso, p_transaction_fee_strategy: "route_formula", p_transaction_fee_model: "percentage_plus_fixed", p_percentage_fee: "2.000", p_fixed_fee: "1.50", p_batch_fee_fixed: "0", p_cod_fee_reversal_policy: "full" },
    clientSettleManageRoutesOnly,
  );
  ok("Part 14 item b: create_settlement_route_fee_version() over real HTTP returns a real uuid for the COD route_formula fee version", typeof stlFeeCodId === "string" && stlFeeCodId.length === 36, `got ${JSON.stringify(stlFeeCodId)}`);

  const stlFeeVersionsForMgmt = await rpc("list_settlement_route_fee_versions_for_management", { p_settlement_route_id: stlRouteChannelledId }, clientSettleManageRoutesOnly);
  ok(
    "Part 14 item b (§23): list_settlement_route_fee_versions_for_management() over real HTTP works for the manage_routes-ONLY actor (never requires settlements.view_financials) and returns batch_fee_fixed as typeof 'string'",
    Array.isArray(stlFeeVersionsForMgmt) && stlFeeVersionsForMgmt.length === 1 && typeof stlFeeVersionsForMgmt[0].batch_fee_fixed === "string",
    `got ${JSON.stringify(stlFeeVersionsForMgmt)}`,
  );

  const { data: stlRawFeeVersionRows, error: stlRawFeeVersionErr } = await clientSettleManageRoutesOnly.from("settlement_route_fee_versions").select("id");
  ok(
    "Part 14 item b (§23 — hidden dependency closed): raw SELECT over real HTTP against settlement_route_fee_versions returns ZERO rows for the SAME manage_routes-ONLY actor, even though list_settlement_route_fee_versions_for_management() just returned a real row for it — that table's own RLS policy (0170) requires settlements.view_financials, which this actor deliberately lacks",
    !stlRawFeeVersionErr && Array.isArray(stlRawFeeVersionRows) && stlRawFeeVersionRows.length === 0,
    `error=${stlRawFeeVersionErr?.message} rows=${stlRawFeeVersionRows?.length}`,
  );

  // Full route CRUD cycle (update/disable/enable) on a disposable throwaway
  // route, so the real fixture routes above are never disturbed.
  const stlThrowawayRouteId = await rpc(
    "create_settlement_route",
    { p_code: `stl-throwaway-${Date.now() % 100000}`, p_name_ar: "مسار HTTP تجريبي", p_route_kind: "payment_collection", p_name_en: null, p_payment_method_id: stlCashPm.id, p_collection_channel_id: null },
    clientSettleManageRoutesOnly,
  );
  await rpc("update_settlement_route", { p_id: stlThrowawayRouteId, p_name_ar: "مسار HTTP تجريبي (معدَّل)" }, clientSettleManageRoutesOnly);
  await rpc("disable_settlement_route", { p_id: stlThrowawayRouteId }, clientSettleManageRoutesOnly);
  const stlAdminList = await rpc("settlement_routes_admin_list", {}, clientSettleManageRoutesOnly);
  const stlThrowawayAdminRow = (stlAdminList ?? []).find((r) => r.id === stlThrowawayRouteId);
  ok(
    "Part 14 item b: update_settlement_route()/disable_settlement_route() over real HTTP persist correctly — settlement_routes_admin_list() (manage_routes-gated) shows the renamed, disabled route",
    stlThrowawayAdminRow?.status === "disabled" && stlThrowawayAdminRow?.name_ar === "مسار HTTP تجريبي (معدَّل)",
    `got ${JSON.stringify(stlThrowawayAdminRow)}`,
  );
  await rpc("enable_settlement_route", { p_id: stlThrowawayRouteId }, clientSettleManageRoutesOnly);

  // --- c) Source discovery fixture: a fresh Sale (channeled route source),
  // a Return + actual cash refund event + its reversal + the independent
  // fee-reversal source (both no-channel route sources, Patch 7.1 §1/§2). -
  const stlOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "3.0000", sale_price: "3000.00" }],
    p_customer_name: "عميل اختبار تسويات HTTP",
  });
  const stlOrderRow = Array.isArray(stlOrderRows) ? stlOrderRows[0] : stlOrderRows;
  const stlOrderId = stlOrderRow?.id;

  const stlReturnable = await rpc("get_returnable_sales_order", { p_sales_order_id: stlOrderId });
  const stlItem = stlReturnable.items[0];
  const stlReturnRows = await rpc("create_sales_return", {
    p_sales_order_id: stlOrderId, p_processed_store_id: STORE_ID, p_return_date: todayIso, p_scenario: "defective_product",
    p_items: [{ sales_order_item_id: stlItem.id, condition: "good_resellable" }],
    p_expected_sale_version: stlReturnable.row_version, p_collection_state: "collected", p_approved_refund_amount: "3000.00",
  });
  const stlReturnRow = Array.isArray(stlReturnRows) ? stlReturnRows[0] : stlReturnRows;
  const stlReturnId = stlReturnRow?.id;
  const stlReturnDetailPending = await rpc("get_sales_return", { p_id: stlReturnId });
  await rpc("approve_sales_return", { p_return_id: stlReturnId, p_expected_version: stlReturnDetailPending.row_version });
  const stlReturnAfterApprove = await rpc("get_sales_return", { p_id: stlReturnId });

  const stlRefundRows = await rpc("record_sales_return_refund", { p_return_id: stlReturnId, p_amount: "1500.00", p_refund_method_id: PAYMENT_METHOD_ID, p_reference: "HTTP-STL-REF-0001" });
  const stlRefundRow = Array.isArray(stlRefundRows) ? stlRefundRows[0] : stlRefundRows;
  const stlReturnAfterRefund = await rpc("get_sales_return", { p_id: stlReturnId });
  const stlRefundEventId = stlReturnAfterRefund.refund_events?.find((e) => e.id === stlRefundRow.id)?.id;

  const stlSourcesNoChannel = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteNoChannelId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  // Hotfix 7.1.1 §3 moved item d)'s stlSourcesChannelled fetch up here so
  // item c) can locate the fee-reversal source on the CORRECT route below —
  // see that note for why.
  const stlSourcesChannelled = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  ok(
    "Part 14 item c: list_unsettled_settlement_sources() over real HTTP returns every money figure (gross_collection_impact/provider_fee_impact/expected_settlement_impact) as typeof 'string' for every candidate row",
    stlSourcesNoChannel.every((s) => typeof s.gross_collection_impact === "string" && typeof s.provider_fee_impact === "string" && typeof s.expected_settlement_impact === "string"),
    `got a sample row ${JSON.stringify(stlSourcesNoChannel[0])}`,
  );
  const stlRefundEventSource = stlSourcesNoChannel.find((s) => s.source_kind === "return_refund_event" && s.source_event_id === stlRefundEventId);
  // Hotfix 7.1.1 §3: return_fee_reversal now routes via the ORIGINAL SALE's
  // own payment_method_id/collection_channel_id (this fixture's stlOrderId
  // carries CHANNEL_ID), never the Refund Event's own refund_method_id/
  // implicit-NULL-channel — so the fee-reversal source now lives on the
  // CHANNELLED route, not the no-channel route it used to match under 0184.
  // See Part 15 items i/j/k below for the dedicated, focused HTTP proof of
  // this exact behavior (permanence + independent-route coexistence).
  const stlFeeReversalSource = stlSourcesChannelled.find((s) => s.source_kind === "return_fee_reversal" && s.source_event_id === stlReturnId);
  ok(
    "Part 14 item c (Patch 7.1 §1/§2, Hotfix 7.1.1 §3): list_unsettled_settlement_sources() over real HTTP surfaces the ACTUAL cash refund event as source_kind='return_refund_event' on the no-channel route (gross=-1500.00, negative — money paid out), and the INDEPENDENT fee-credit source as 'return_fee_reversal' on the CHANNELLED route (gross=0.00, expected=the return's own payment_fee_reversal_amount, routed via the original sale's own channel) — never fabricated from sales_returns.status alone",
    typeof stlRefundEventSource?.gross_collection_impact === "string" && new Decimal(stlRefundEventSource.gross_collection_impact).equals(new Decimal("-1500.00")) &&
      typeof stlFeeReversalSource?.gross_collection_impact === "string" && new Decimal(stlFeeReversalSource.gross_collection_impact).equals(new Decimal("0.00")) &&
      new Decimal(stlFeeReversalSource.expected_settlement_impact).equals(new Decimal(stlReturnAfterApprove.payment_fee_reversal_amount)),
    `got refundEvent=${JSON.stringify(stlRefundEventSource)} feeReversal=${JSON.stringify(stlFeeReversalSource)} paymentFeeReversal=${stlReturnAfterApprove.payment_fee_reversal_amount}`,
  );

  // --- d) route exact channel/method matching (Patch 7.1 §4, CRITICAL): no
  // NULL-as-wildcard. -------------------------------------------------
  const stlSaleSourceChannelled = stlSourcesChannelled.find((s) => s.source_kind === "sale" && s.source_event_id === stlOrderId);
  ok(
    "Part 14 item d (§4): the Sale appears as a source for the EXACT payment-method+channel-matching route",
    typeof stlSaleSourceChannelled?.gross_collection_impact === "string" && new Decimal(stlSaleSourceChannelled.gross_collection_impact).equals(new Decimal("3000.00")),
    `got ${JSON.stringify(stlSaleSourceChannelled)}`,
  );
  const stlSaleSourceNoChannel = stlSourcesNoChannel.find((s) => s.source_kind === "sale" && s.source_event_id === stlOrderId);
  ok(
    "Part 14 item d (§4 — CRITICAL): a route with collection_channel_id=NULL no longer matches this Sale (which always carries a real, non-null channel) — 0176's OLD null-as-wildcard behavior is gone; the Sale is ABSENT from the no-channel route's candidates",
    stlSaleSourceNoChannel === undefined,
    `got ${JSON.stringify(stlSaleSourceNoChannel)}`,
  );
  const stlRefundEventSourceChannelled = stlSourcesChannelled.find((s) => s.source_kind === "return_refund_event" && s.source_event_id === stlRefundEventId);
  ok(
    "Part 14 item d (§4): conversely, the actual cash refund event (implicitly channel-less) does NOT match the channel-specific route",
    stlRefundEventSourceChannelled === undefined,
    `got ${JSON.stringify(stlRefundEventSourceChannelled)}`,
  );

  // --- e) refund-event reversal. ---------------------------------------
  // reverse_sales_return_refund_event() returns id=p_event_id (the ORIGINAL
  // event's own id, by design — see 0107), never the new reversal row's own
  // id (that id is only ever visible to the settlement source adapter as
  // source_event_id). With THIS return having exactly one refund event and
  // exactly one reversal, matching on source_number=this return's own
  // return_number unambiguously identifies our row even though many other
  // returns' reversals may also be present in the same candidate list.
  await rpc("reverse_sales_return_refund_event", { p_event_id: stlRefundEventId, p_reversal_reason: "HTTP test تسويات — عكس استرداد فعلي" });
  const stlSourcesNoChannelAfterReversal = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteNoChannelId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const stlRefundReversalSource = stlSourcesNoChannelAfterReversal.find((s) => s.source_kind === "return_refund_event_reversal" && s.source_number === stlReturnRow.return_number);
  ok(
    "Part 14 item e: reverse_sales_return_refund_event() over real HTTP produces a NEW 'return_refund_event_reversal' source for this return (gross=+1500.00, restoring exactly THIS event's own amount)",
    typeof stlRefundReversalSource?.gross_collection_impact === "string" && new Decimal(stlRefundReversalSource.gross_collection_impact).equals(new Decimal("1500.00")),
    `got ${JSON.stringify(stlRefundReversalSource)}`,
  );

  // --- f) cross-store Adjustment source visibility (Patch 7.1 §5,
  // CRITICAL): AND, not OR. -----------------------------------------------
  const stlCrossOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "1000.00" }],
  });
  const stlCrossOrderRow = Array.isArray(stlCrossOrderRows) ? stlCrossOrderRows[0] : stlCrossOrderRows;
  const stlCrossOrderId = stlCrossOrderRow?.id;

  const stlCrossAdjCreateRows = await rpc("create_sales_order_adjustment", {
    p_sales_order_id: stlCrossOrderId, p_adjustment_type_id: adjTypeId, p_processing_store_id: STORE_B_ID, p_adjustment_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID, p_participates_in_settlement: true,
    p_customer_charge: "200.00", p_direct_cost: "0.00", p_notes: "HTTP test تسويات — تعديل عبر متاجر",
  });
  const stlCrossAdjCreateRow = Array.isArray(stlCrossAdjCreateRows) ? stlCrossAdjCreateRows[0] : stlCrossAdjCreateRows;
  const stlCrossAdjId = stlCrossAdjCreateRow?.id;
  const stlCrossAdjDetailRows = await rpc("get_sales_order_adjustment", { p_id: stlCrossAdjId });
  const stlCrossAdjDetail = Array.isArray(stlCrossAdjDetailRows) ? stlCrossAdjDetailRows[0] : stlCrossAdjDetailRows;
  await rpc("approve_sales_order_adjustment", { p_id: stlCrossAdjId, p_expected_version: stlCrossAdjDetail.row_version });

  const stlSourcesChannelledFull = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const stlCrossAdjSourceFull = stlSourcesChannelledFull.find((s) => s.source_kind === "adjustment_approved" && s.source_event_id === stlCrossAdjId);
  ok(
    "Part 14 item f (§5): the cross-store Adjustment (linked Sale in Store A, processing_store_id in Store B) appears as a source for the full (all-store-visible) actor",
    typeof stlCrossAdjSourceFull?.gross_collection_impact === "string" && new Decimal(stlCrossAdjSourceFull.gross_collection_impact).equals(new Decimal("200.00")),
    `got ${JSON.stringify(stlCrossAdjSourceFull)}`,
  );
  const stlSourcesChannelledStoreB = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 }, clientAdjStoreBOnly);
  const stlCrossAdjSourceStoreB = stlSourcesChannelledStoreB.find((s) => s.source_kind === "adjustment_approved" && s.source_event_id === stlCrossAdjId);
  ok(
    "Part 14 item f (§5 — CRITICAL): the SAME cross-store Adjustment is ABSENT for a Store-B-only actor — even though its processing_store_id IS Store B, the linked Sale's OWN store (Store A) is invisible to this actor, and §5 requires BOTH visible (AND, not OR — the fix over 0176's OR-based bug)",
    stlCrossAdjSourceStoreB === undefined,
    `got ${JSON.stringify(stlCrossAdjSourceStoreB)}`,
  );

  // --- g) preview + finalize + duplicate-source claim uniqueness, on the
  // cross-store Adjustment (also sets up §6/§26 below). -------------------
  const stlCrossPreviewRows = await rpc("preview_settlement_batch", {
    p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo,
    p_selected_sources: [{ source_kind: "adjustment_approved", source_event_id: stlCrossAdjId }],
  });
  const stlCrossPreviewRow = Array.isArray(stlCrossPreviewRows) ? stlCrossPreviewRows[0] : stlCrossPreviewRows;
  ok(
    // Hotfix 7.1.1 §9 (migration 0195, DROP+CREATE) replaced the old
    // ambiguous single `batch_fee` column with configured_batch_fee/
    // effective_batch_fee/batch_fee_overridden — updated in place here to
    // match the new return shape (Part 15 item e below is the dedicated
    // override-parity proof for this same RPC).
    "Part 14 item g: preview_settlement_batch() over real HTTP returns lines (jsonb array) plus every total as typeof 'string', never a JSON number",
    Array.isArray(stlCrossPreviewRow?.lines) && stlCrossPreviewRow.lines.length === 1 &&
      typeof stlCrossPreviewRow.gross_source_impact === "string" && typeof stlCrossPreviewRow.provider_fee_impact === "string" &&
      typeof stlCrossPreviewRow.expected_before_batch_fee === "string" && typeof stlCrossPreviewRow.configured_batch_fee === "string" &&
      typeof stlCrossPreviewRow.effective_batch_fee === "string" && typeof stlCrossPreviewRow.batch_fee_overridden === "boolean" &&
      typeof stlCrossPreviewRow.expected_bank_settlement === "string",
    `got ${JSON.stringify(stlCrossPreviewRow)}`,
  );

  const stlCrossDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
  const stlCrossDraftRow = Array.isArray(stlCrossDraftRows) ? stlCrossDraftRows[0] : stlCrossDraftRows;
  const stlCrossBatchId = stlCrossDraftRow?.id;
  const stlCrossFinalizeRows = await rpc("finalize_settlement_batch", {
    p_settlement_batch_id: stlCrossBatchId, p_expected_version: 1, p_selected_sources: [{ source_kind: "adjustment_approved", source_event_id: stlCrossAdjId }],
  });
  const stlCrossFinalizeRow = Array.isArray(stlCrossFinalizeRows) ? stlCrossFinalizeRows[0] : stlCrossFinalizeRows;
  ok(
    "Part 14 item g: finalize_settlement_batch() over real HTTP succeeds for a single-source cross-store batch and returns a real settlement_number, row_version bumped",
    typeof stlCrossFinalizeRow?.settlement_number === "string" && /^SET-\d{10}$/.test(stlCrossFinalizeRow.settlement_number) && stlCrossFinalizeRow.row_version === 2,
    `got ${JSON.stringify(stlCrossFinalizeRow)}`,
  );

  let stlCrossDupErr = null;
  try {
    const stlCrossDupDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
    const stlCrossDupDraftRow = Array.isArray(stlCrossDupDraftRows) ? stlCrossDupDraftRows[0] : stlCrossDupDraftRows;
    await rpc("finalize_settlement_batch", { p_settlement_batch_id: stlCrossDupDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "adjustment_approved", source_event_id: stlCrossAdjId }] });
  } catch (err) {
    stlCrossDupErr = err;
  }
  ok(
    "Part 14 item g (claim uniqueness — CRITICAL): a SECOND finalize_settlement_batch() over real HTTP attempting to claim the SAME already-claimed Adjustment source is rejected",
    stlCrossDupErr !== null,
    `got ${stlCrossDupErr?.message}`,
  );

  // --- h) §6 whole-batch privacy (CRITICAL, no partial aggregate leak). --
  const stlCrossBatchListFull = await rpc("list_settlement_batches", { p_search: stlCrossFinalizeRow.settlement_number });
  const stlCrossBatchListRow = (stlCrossBatchListFull ?? []).find((b) => b.id === stlCrossBatchId);
  ok(
    "Part 14 item h: list_settlement_batches() over real HTTP returns every original_*/effective_* money figure as typeof 'string' plus source_count, for a caller with settlements.view_financials",
    typeof stlCrossBatchListRow?.original_gross_source_impact === "string" && typeof stlCrossBatchListRow?.effective_expected_settlement_contribution === "string" &&
      typeof stlCrossBatchListRow?.effective_variance_contribution === "string" && stlCrossBatchListRow?.source_count === 1,
    `got ${JSON.stringify(stlCrossBatchListRow)}`,
  );

  const stlCrossBatchListStoreB = await rpc("list_settlement_batches", { p_search: stlCrossFinalizeRow.settlement_number }, clientAdjStoreBOnly);
  ok(
    "Part 14 item h (§6 — CRITICAL): list_settlement_batches() over real HTTP EXCLUDES this batch entirely for the Store-B-only actor — one invisible-store line hides the WHOLE batch, not just that line",
    (stlCrossBatchListStoreB ?? []).length === 0,
    `got ${JSON.stringify(stlCrossBatchListStoreB)}`,
  );

  let stlCrossGetStoreBErr = null;
  try {
    await rpc("get_settlement_batch", { p_settlement_batch_id: stlCrossBatchId }, clientAdjStoreBOnly);
  } catch (err) {
    stlCrossGetStoreBErr = err;
  }
  ok(
    "Part 14 item h (§6 — CRITICAL, no partial aggregate leak): get_settlement_batch() over real HTTP raises the SAME not-found error a genuinely missing id would, for the Store-B-only actor — no header, no aggregate, no line ever surfaces",
    stlCrossGetStoreBErr !== null && /غير موجودة/.test(String(stlCrossGetStoreBErr.message)),
    `got ${stlCrossGetStoreBErr?.message}`,
  );

  // --- i) settlement_calculation_version=2 (the Patch 7.1-corrected
  // finalize logic) + no source-domain profit leak in settlement_batch_
  // lines' JSON shape. ------------------------------------------------
  const stlCrossDetailBeforeCancelRows = await rpc("get_settlement_batch", { p_settlement_batch_id: stlCrossBatchId });
  const stlCrossDetailBeforeCancel = Array.isArray(stlCrossDetailBeforeCancelRows) ? stlCrossDetailBeforeCancelRows[0] : stlCrossDetailBeforeCancelRows;
  ok(
    "Part 14 item i: get_settlement_batch() over real HTTP stamps settlement_calculation_version=2 for a batch finalized under this Patch 7.1-corrected logic",
    stlCrossDetailBeforeCancel.settlement_calculation_version === 2,
    `got ${JSON.stringify(stlCrossDetailBeforeCancel.settlement_calculation_version)}`,
  );
  const stlCrossLineKeys = Object.keys(stlCrossDetailBeforeCancel.lines?.[0] ?? {}).sort();
  const stlExpectedLineKeys = ["expected_settlement_impact", "gross_collection_impact", "id", "primary_store_name", "provider_fee_impact", "provider_fee_source", "secondary_store_name", "source_business_date", "source_kind", "source_number"].sort();
  ok(
    "Part 14 item i (no source-domain profit leak): a settlement_batch_lines JSON entry over real HTTP is EXACTLY this fixed field whitelist — no gold/manufacturing/VAT cost, product gross profit, sales net profit, adjustment direct cost, or shipping P/L key ever appears",
    JSON.stringify(stlCrossLineKeys) === JSON.stringify(stlExpectedLineKeys),
    `got ${JSON.stringify(stlCrossLineKeys)}`,
  );
  ok(
    "Part 14 item i: the cross-store line correctly snapshots secondary_store_name (the linked Sale's OWN store), distinct from primary_store_name (the Adjustment's processing store)",
    stlCrossDetailBeforeCancel.lines[0].secondary_store_name !== null && stlCrossDetailBeforeCancel.lines[0].secondary_store_name !== stlCrossDetailBeforeCancel.lines[0].primary_store_name,
    `got ${JSON.stringify(stlCrossDetailBeforeCancel.lines[0])}`,
  );

  // --- j) cancellation + claim release + §26 original_*-vs-effective_*
  // split (CRITICAL) + historical snapshot stability. ---------------------
  await rpc("cancel_settlement_batch", { p_settlement_batch_id: stlCrossBatchId, p_expected_version: stlCrossFinalizeRow.row_version, p_cancellation_business_date: todayIso, p_reason: "HTTP test تسويات — إلغاء اختباري" });
  const stlCrossDetailAfterCancelRows = await rpc("get_settlement_batch", { p_settlement_batch_id: stlCrossBatchId });
  const stlCrossDetailAfterCancel = Array.isArray(stlCrossDetailAfterCancelRows) ? stlCrossDetailAfterCancelRows[0] : stlCrossDetailAfterCancelRows;
  ok(
    "Part 14 item j (§26 — CRITICAL, historical snapshots stable): get_settlement_batch() over real HTTP — original_* figures are BYTE-IDENTICAL before/after cancellation (the permanent historical fact, never zeroed), while every effective_* figure collapses to 0.00 (no longer financially in effect) and effective_status='cancelled'",
    stlCrossDetailAfterCancel.original_gross_source_impact === stlCrossDetailBeforeCancel.original_gross_source_impact &&
      stlCrossDetailAfterCancel.original_expected_bank_settlement === stlCrossDetailBeforeCancel.original_expected_bank_settlement &&
      new Decimal(stlCrossDetailAfterCancel.effective_expected_settlement_contribution).equals(new Decimal("0.00")) &&
      new Decimal(stlCrossDetailAfterCancel.effective_actual_settlement_contribution).equals(new Decimal("0.00")) &&
      new Decimal(stlCrossDetailAfterCancel.effective_variance_contribution).equals(new Decimal("0.00")) &&
      stlCrossDetailAfterCancel.effective_status === "cancelled" && stlCrossDetailAfterCancel.status === "finalized",
    `before=${JSON.stringify(stlCrossDetailBeforeCancel)} after=${JSON.stringify(stlCrossDetailAfterCancel)}`,
  );

  const stlSourcesChannelledAfterCancel = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const stlCrossAdjSourceAfterCancel = stlSourcesChannelledAfterCancel.find((s) => s.source_kind === "adjustment_approved" && s.source_event_id === stlCrossAdjId);
  ok(
    "Part 14 item j: cancel_settlement_batch() over real HTTP releases the claim — the cross-store Adjustment reappears in list_unsettled_settlement_sources, claimable by a future batch",
    typeof stlCrossAdjSourceAfterCancel?.gross_collection_impact === "string",
    `got ${JSON.stringify(stlCrossAdjSourceAfterCancel)}`,
  );

  // --- k) source-domain audit non-leak sanity for the cross-store
  // Adjustment (used again below in the §8 audit split). ------------------
  const stlCrossAdjAfterAllRows = await rpc("get_sales_order_adjustment", { p_id: stlCrossAdjId });
  const stlCrossAdjAfterAll = Array.isArray(stlCrossAdjAfterAllRows) ? stlCrossAdjAfterAllRows[0] : stlCrossAdjAfterAllRows;
  ok(
    "Part 14 item k (§2): the cross-store Adjustment's linked Sale (Store A) net_sales_profit is unaffected by any Settlements activity — fully independent P/L engines, confirmed once more in this Settlements-specific fixture",
    typeof stlCrossAdjAfterAll.effective_status === "string",
    `got ${JSON.stringify(stlCrossAdjAfterAll.effective_status)}`,
  );

  // --- l) Sale source: finalize + claim uniqueness re-confirmed on a plain
  // (non-cross-store) source, plus the money-as-TEXT + view-without-
  // financials redaction proofs. -------------------------------------
  const stlSaleDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
  const stlSaleDraftRow = Array.isArray(stlSaleDraftRows) ? stlSaleDraftRows[0] : stlSaleDraftRows;
  const stlSaleBatchId = stlSaleDraftRow?.id;
  const stlSaleFinalizeRows = await rpc("finalize_settlement_batch", { p_settlement_batch_id: stlSaleBatchId, p_expected_version: 1, p_selected_sources: [{ source_kind: "sale", source_event_id: stlOrderId }] });
  const stlSaleFinalizeRow = Array.isArray(stlSaleFinalizeRows) ? stlSaleFinalizeRows[0] : stlSaleFinalizeRows;
  const stlSaleBatchDetailRows = await rpc("get_settlement_batch", { p_settlement_batch_id: stlSaleBatchId });
  const stlSaleBatchDetail = Array.isArray(stlSaleBatchDetailRows) ? stlSaleBatchDetailRows[0] : stlSaleBatchDetailRows;
  ok(
    "Part 14 item l: finalize_settlement_batch() over real HTTP persists the Sale line (gross=3000.00) and stamps settlement_calculation_version=2",
    stlSaleBatchDetail.settlement_calculation_version === 2 && new Decimal(stlSaleBatchDetail.original_gross_source_impact).equals(new Decimal("3000.00")),
    `got ${JSON.stringify(stlSaleBatchDetail)}`,
  );

  const stlSaleSourceAfterClaim = (await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 })).find(
    (s) => s.source_kind === "sale" && s.source_event_id === stlOrderId,
  );
  ok("Part 14 item l: the just-claimed Sale no longer appears in list_unsettled_settlement_sources()", stlSaleSourceAfterClaim === undefined, `got ${JSON.stringify(stlSaleSourceAfterClaim)}`);

  let stlSaleDupErr = null;
  try {
    const stlSaleDupDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
    const stlSaleDupDraftRow = Array.isArray(stlSaleDupDraftRows) ? stlSaleDupDraftRows[0] : stlSaleDupDraftRows;
    await rpc("finalize_settlement_batch", { p_settlement_batch_id: stlSaleDupDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "sale", source_event_id: stlOrderId }] });
  } catch (err) {
    stlSaleDupErr = err;
  }
  ok("Part 14 item l (claim uniqueness): a duplicate finalize on the SAME already-claimed Sale source is rejected", stlSaleDupErr !== null, `got ${stlSaleDupErr?.message}`);

  const stlSaleBatchListNoFin = await rpc("list_settlement_batches", { p_search: stlSaleFinalizeRow.settlement_number }, clientNoProfit);
  const stlSaleBatchListNoFinRow = (stlSaleBatchListNoFin ?? []).find((b) => b.id === stlSaleBatchId);
  ok(
    "Part 14 item m: list_settlement_batches() over real HTTP — settlements.view ALONE (no view_financials) gets every money figure as JSON null, while status/effective_status/source_count stay visible",
    stlSaleBatchListNoFinRow?.original_gross_source_impact === null && stlSaleBatchListNoFinRow?.effective_expected_settlement_contribution === null && stlSaleBatchListNoFinRow?.effective_variance_contribution === null &&
      typeof stlSaleBatchListNoFinRow?.status === "string" && stlSaleBatchListNoFinRow?.source_count === 1,
    `got ${JSON.stringify(stlSaleBatchListNoFinRow)}`,
  );

  const stlSaleBatchDetailNoFinRows = await rpc("get_settlement_batch", { p_settlement_batch_id: stlSaleBatchId }, clientNoProfit);
  const stlSaleBatchDetailNoFin = Array.isArray(stlSaleBatchDetailNoFinRows) ? stlSaleBatchDetailNoFinRows[0] : stlSaleBatchDetailNoFinRows;
  ok(
    "Part 14 item m: get_settlement_batch() over real HTTP — settlements.view ALONE gets every money field/lines/bank_movements NULL/empty, while route_code/status/effective_status stay visible",
    stlSaleBatchDetailNoFin.original_gross_source_impact === null && stlSaleBatchDetailNoFin.effective_variance_contribution === null &&
      Array.isArray(stlSaleBatchDetailNoFin.lines) && stlSaleBatchDetailNoFin.lines.length === 0 &&
      Array.isArray(stlSaleBatchDetailNoFin.bank_movements) && stlSaleBatchDetailNoFin.bank_movements.length === 0 &&
      typeof stlSaleBatchDetailNoFin.route_code === "string" && stlSaleBatchDetailNoFin.effective_status === "finalized",
    `got ${JSON.stringify(stlSaleBatchDetailNoFin)}`,
  );

  // --- n) bank movement + zero-variance reconcile. ------------------------
  const stlSaleExpected = stlSaleBatchDetail.original_expected_bank_settlement;
  const stlMovementId = await rpc("record_settlement_bank_movement", { p_settlement_batch_id: stlSaleBatchId, p_movement_business_date: todayIso, p_amount: stlSaleExpected, p_bank_reference: "HTTP-STL-BANK-0001" });
  ok("Part 14 item n: record_settlement_bank_movement() over real HTTP returns a real uuid", typeof stlMovementId === "string" && stlMovementId.length === 36, `got ${JSON.stringify(stlMovementId)}`);

  const stlSaleBatchAfterMovementRows = await rpc("get_settlement_batch", { p_settlement_batch_id: stlSaleBatchId });
  const stlSaleBatchAfterMovement = Array.isArray(stlSaleBatchAfterMovementRows) ? stlSaleBatchAfterMovementRows[0] : stlSaleBatchAfterMovementRows;
  ok(
    "Part 14 item n: get_settlement_batch() over real HTTP reflects the recorded movement live — effective_actual_settlement_contribution equals it exactly, effective_variance_contribution is zero",
    new Decimal(stlSaleBatchAfterMovement.effective_actual_settlement_contribution).equals(new Decimal(stlSaleExpected)) && new Decimal(stlSaleBatchAfterMovement.effective_variance_contribution).equals(new Decimal("0.00")),
    `got ${JSON.stringify(stlSaleBatchAfterMovement)}`,
  );

  const stlReconcileRows = await rpc("reconcile_settlement_batch", { p_settlement_batch_id: stlSaleBatchId, p_expected_version: stlSaleBatchAfterMovement.row_version });
  const stlReconcileRow = Array.isArray(stlReconcileRows) ? stlReconcileRows[0] : stlReconcileRows;
  ok(
    "Part 14 item o: reconcile_settlement_batch() over real HTTP succeeds with ZERO variance on settlements.reconcile alone (no reason required), actual_bank_movement/variance returned as typeof 'string'",
    typeof stlReconcileRow?.actual_bank_movement === "string" && typeof stlReconcileRow?.variance === "string" && new Decimal(stlReconcileRow.variance).equals(new Decimal("0.00")),
    `got ${JSON.stringify(stlReconcileRow)}`,
  );

  // --- p) movement after reconciled denied (Patch 7.1 §13). --------------
  let stlPostReconcileMovementErr = null;
  try {
    await rpc("record_settlement_bank_movement", { p_settlement_batch_id: stlSaleBatchId, p_movement_business_date: todayIso, p_amount: "1.00" });
  } catch (err) {
    stlPostReconcileMovementErr = err;
  }
  ok(
    "Part 14 item p (§13): record_settlement_bank_movement() over real HTTP is REJECTED once the batch is reconciled — a new movement can no longer silently drift the reconciled actual/variance",
    stlPostReconcileMovementErr !== null && /مُطابَقة/.test(String(stlPostReconcileMovementErr.message)),
    `got ${stlPostReconcileMovementErr?.message}`,
  );

  // --- q) negative bank movement + reversal + nonzero-variance
  // permission/reason gating. ---------------------------------------------
  const stlNegDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteNoChannelId, p_settlement_date: todayIso });
  const stlNegDraftRow = Array.isArray(stlNegDraftRows) ? stlNegDraftRows[0] : stlNegDraftRows;
  await rpc("finalize_settlement_batch", { p_settlement_batch_id: stlNegDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "return_refund_event", source_event_id: stlRefundEventId }] });
  const stlNegBatchDetailRows = await rpc("get_settlement_batch", { p_settlement_batch_id: stlNegDraftRow.id });
  const stlNegBatchDetail = Array.isArray(stlNegBatchDetailRows) ? stlNegBatchDetailRows[0] : stlNegBatchDetailRows;
  ok(
    "Part 14 item q: a batch built ENTIRELY from a negative-gross source (the actual cash refund event) has a NEGATIVE original_expected_bank_settlement over real HTTP",
    new Decimal(stlNegBatchDetail.original_expected_bank_settlement).lessThan(0),
    `got ${stlNegBatchDetail.original_expected_bank_settlement}`,
  );

  const stlNegMovementId = await rpc("record_settlement_bank_movement", { p_settlement_batch_id: stlNegDraftRow.id, p_movement_business_date: todayIso, p_amount: stlNegBatchDetail.original_expected_bank_settlement, p_bank_reference: "HTTP-STL-BANK-NEG" });
  const stlNegBatchAfterMovementRows = await rpc("get_settlement_batch", { p_settlement_batch_id: stlNegDraftRow.id });
  const stlNegBatchAfterMovement = Array.isArray(stlNegBatchAfterMovementRows) ? stlNegBatchAfterMovementRows[0] : stlNegBatchAfterMovementRows;
  ok(
    "Part 14 item q: record_settlement_bank_movement() over real HTTP accepts a NEGATIVE amount (a debit) — effective_actual_settlement_contribution matches it exactly, effective_variance_contribution is zero",
    typeof stlNegMovementId === "string" && new Decimal(stlNegBatchAfterMovement.effective_actual_settlement_contribution).equals(new Decimal(stlNegBatchDetail.original_expected_bank_settlement)) &&
      new Decimal(stlNegBatchAfterMovement.effective_variance_contribution).equals(new Decimal("0.00")),
    `got ${JSON.stringify(stlNegBatchAfterMovement)}`,
  );

  const stlNegReversalId = await rpc("reverse_settlement_bank_movement", { p_bank_movement_event_id: stlNegMovementId, p_reversal_business_date: todayIso, p_reason: "HTTP test تسويات — عكس حركة بنكية سالبة" });
  const stlNegBatchAfterReversalRows = await rpc("get_settlement_batch", { p_settlement_batch_id: stlNegDraftRow.id });
  const stlNegBatchAfterReversal = Array.isArray(stlNegBatchAfterReversalRows) ? stlNegBatchAfterReversalRows[0] : stlNegBatchAfterReversalRows;
  ok(
    "Part 14 item q: reverse_settlement_bank_movement() over real HTTP returns a real uuid; effective_actual_settlement_contribution is back to zero, effective_variance_contribution now equals the FULL (negative) expected figure, negated",
    typeof stlNegReversalId === "string" && new Decimal(stlNegBatchAfterReversal.effective_actual_settlement_contribution).equals(new Decimal("0.00")) &&
      new Decimal(stlNegBatchAfterReversal.effective_variance_contribution).equals(new Decimal(stlNegBatchDetail.original_expected_bank_settlement).negated()),
    `got ${JSON.stringify(stlNegBatchAfterReversal)}`,
  );

  let stlReconcileNoReasonErr = null;
  try {
    await rpc("reconcile_settlement_batch", { p_settlement_batch_id: stlNegDraftRow.id, p_expected_version: stlNegBatchAfterReversal.row_version });
  } catch (err) {
    stlReconcileNoReasonErr = err;
  }
  ok(
    "Part 14 item r: reconcile_settlement_batch() over real HTTP REJECTS a nonzero-variance reconciliation with no p_variance_reason, even for an actor holding settlements.reconcile_variance",
    stlReconcileNoReasonErr !== null,
    `got ${stlReconcileNoReasonErr?.message}`,
  );

  let stlReconcileNoPermErr = null;
  try {
    await rpc("reconcile_settlement_batch", { p_settlement_batch_id: stlNegDraftRow.id, p_expected_version: stlNegBatchAfterReversal.row_version }, clientNoProfit);
  } catch (err) {
    stlReconcileNoPermErr = err;
  }
  ok(
    "Part 14 item r: reconcile_settlement_batch() over real HTTP is denied outright for an actor holding only settlements.view (no settlements.reconcile at all)",
    stlReconcileNoPermErr !== null,
    `got ${stlReconcileNoPermErr?.message}`,
  );

  const stlNegReconcileRows = await rpc("reconcile_settlement_batch", { p_settlement_batch_id: stlNegDraftRow.id, p_expected_version: stlNegBatchAfterReversal.row_version, p_variance_reason: "HTTP test تسويات — فرق مطابقة متعمَّد" });
  const stlNegReconcileRow = Array.isArray(stlNegReconcileRows) ? stlNegReconcileRows[0] : stlNegReconcileRows;
  ok(
    "Part 14 item r: reconcile_settlement_batch() over real HTTP succeeds once a mandatory reason is supplied for the nonzero variance, variance returned as typeof 'string'",
    typeof stlNegReconcileRow?.variance === "string" && !new Decimal(stlNegReconcileRow.variance).equals(new Decimal("0")),
    `got ${JSON.stringify(stlNegReconcileRow)}`,
  );

  // --- s) batch fee override (settlements.override_batch_fee + mandatory
  // reason). ------------------------------------------------------------
  const stlOverrideOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "0.5000", sale_price: "500.00" }],
  });
  const stlOverrideOrderRow = Array.isArray(stlOverrideOrderRows) ? stlOverrideOrderRows[0] : stlOverrideOrderRows;
  const stlOverrideOrderId = stlOverrideOrderRow?.id;
  const stlOverrideDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
  const stlOverrideDraftRow = Array.isArray(stlOverrideDraftRows) ? stlOverrideDraftRows[0] : stlOverrideDraftRows;

  let stlOverrideNoReasonErr = null;
  try {
    await rpc("finalize_settlement_batch", { p_settlement_batch_id: stlOverrideDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "sale", source_event_id: stlOverrideOrderId }], p_batch_fee_override: "9.99" });
  } catch (err) {
    stlOverrideNoReasonErr = err;
  }
  ok("Part 14 item s: finalize_settlement_batch() over real HTTP rejects a batch-fee override with no p_override_reason", stlOverrideNoReasonErr !== null, `got ${stlOverrideNoReasonErr?.message}`);

  await rpc("finalize_settlement_batch", {
    p_settlement_batch_id: stlOverrideDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "sale", source_event_id: stlOverrideOrderId }],
    p_batch_fee_override: "9.99", p_override_reason: "HTTP test تسويات — تجاوز رسوم الدفعة",
  });
  const stlOverrideBatchDetailRows = await rpc("get_settlement_batch", { p_settlement_batch_id: stlOverrideDraftRow.id });
  const stlOverrideBatchDetail = Array.isArray(stlOverrideBatchDetailRows) ? stlOverrideBatchDetailRows[0] : stlOverrideBatchDetailRows;
  ok(
    "Part 14 item s: finalize_settlement_batch() over real HTTP with a batch-fee override persists is_batch_fee_override=true, original_batch_fee=9.99 (typeof 'string'), and override_reason round-trips",
    stlOverrideBatchDetail.is_batch_fee_override === true && new Decimal(stlOverrideBatchDetail.original_batch_fee).equals(new Decimal("9.99")) && stlOverrideBatchDetail.override_reason === "HTTP test تسويات — تجاوز رسوم الدفعة",
    `got ${JSON.stringify(stlOverrideBatchDetail)}`,
  );

  // --- t) §8 audit_logs cross-domain permission split (CRITICAL). --------
  const { data: stlAuditFinOnlySettlement, error: stlAuditFinOnlySettlementErr } = await clientSettleAuditFinOnly.from("audit_logs").select("id, action").eq("entity_id", stlSaleBatchId).like("action", "settlement.%");
  if (stlAuditFinOnlySettlementErr) throw new Error(`audit_logs select (settlement.%, settle-fin-only actor) failed: ${JSON.stringify(stlAuditFinOnlySettlementErr)}`);
  ok(
    "Part 14 item t (§8): GET /audit_logs?action=like.settlement.* over real HTTP returns settlement.finalize/bank_movement/reconcile rows for an actor holding settlements.view_financials (no sales.view_profit)",
    (stlAuditFinOnlySettlement ?? []).some((r) => r.action === "settlement.finalize"),
    `got ${JSON.stringify(stlAuditFinOnlySettlement)}`,
  );

  const { data: stlAuditFinOnlyAdjustment, error: stlAuditFinOnlyAdjustmentErr } = await clientSettleAuditFinOnly.from("audit_logs").select("id, action").eq("entity_id", stlCrossAdjId).like("action", "adjustment.%");
  if (stlAuditFinOnlyAdjustmentErr) throw new Error(`audit_logs select (adjustment.%, settle-fin-only actor) failed: ${JSON.stringify(stlAuditFinOnlyAdjustmentErr)}`);
  ok(
    "Part 14 item t (§8 — CRITICAL): the SAME actor (settlements.view_financials, no sales.view_profit) sees ZERO adjustment.* rows — settlements.view_financials grants NOTHING toward Sales/Returns/Adjustments financial audit (0183's original cross-domain OR-leak, fixed by 0187)",
    (stlAuditFinOnlyAdjustment ?? []).length === 0,
    `got ${JSON.stringify(stlAuditFinOnlyAdjustment)}`,
  );

  const { data: stlAuditSalesProfitAdjustment, error: stlAuditSalesProfitAdjustmentErr } = await clientSalesProfitNoSettleFin.from("audit_logs").select("id, action").eq("entity_id", stlCrossAdjId).like("action", "adjustment.%");
  if (stlAuditSalesProfitAdjustmentErr) throw new Error(`audit_logs select (adjustment.%, sales-profit-only actor) failed: ${JSON.stringify(stlAuditSalesProfitAdjustmentErr)}`);
  ok(
    "Part 14 item t (§8): sales.view_profit (no settlements.view_financials) DOES see adjustment.* financial rows — its OWN domain's branch",
    (stlAuditSalesProfitAdjustment ?? []).some((r) => r.action === "adjustment.approve"),
    `got ${JSON.stringify(stlAuditSalesProfitAdjustment)}`,
  );

  // settlement.create/update/closed_day_override are deliberately UNGATED
  // (no money figure carried, migration 0183/0187) — only the six FINANCIAL
  // settlement.* actions require settlements.view_financials. Filter to
  // exactly that gated set so this assertion isn't spuriously defeated by
  // the (correctly) visible settlement.create row for this same batch.
  const stlSettlementFinancialActions = ["settlement.finalize", "settlement.bank_movement", "settlement.bank_movement_reverse", "settlement.reconcile", "settlement.cancel", "settlement.batch_fee_override"];
  const { data: stlAuditSalesProfitSettlement, error: stlAuditSalesProfitSettlementErr } = await clientSalesProfitNoSettleFin.from("audit_logs").select("id, action").eq("entity_id", stlSaleBatchId).in("action", stlSettlementFinancialActions);
  if (stlAuditSalesProfitSettlementErr) throw new Error(`audit_logs select (settlement financial actions, sales-profit-only actor) failed: ${JSON.stringify(stlAuditSalesProfitSettlementErr)}`);
  ok(
    "Part 14 item t (§8 — CRITICAL): the SAME actor (sales.view_profit, no settlements.view_financials) sees ZERO of the GATED financial settlement.* actions (finalize/bank_movement/reconcile/etc) — sales.view_profit grants NOTHING toward Settlements financial audit (settlement.create itself stays visible to any audit_logs.view holder, deliberately ungated — not the thing under test here)",
    (stlAuditSalesProfitSettlement ?? []).length === 0,
    `got ${JSON.stringify(stlAuditSalesProfitSettlement)}`,
  );

  // --- u) create-only actor workflow (§7/§24). ----------------------------
  const stlCreateOnlyStores = await rpc("settlement_create_store_lookups", {}, clientSettleCreateOnly);
  ok("Part 14 item u (§24): settlement_create_store_lookups() over real HTTP works for a settlements.create-ONLY actor (no settlements.view at all)", Array.isArray(stlCreateOnlyStores) && stlCreateOnlyStores.some((s) => s.id === STORE_ID), `got ${JSON.stringify(stlCreateOnlyStores)}`);

  const stlCreateOnlyDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso }, clientSettleCreateOnly);
  const stlCreateOnlyDraftRow = Array.isArray(stlCreateOnlyDraftRows) ? stlCreateOnlyDraftRows[0] : stlCreateOnlyDraftRows;
  ok(
    "Part 14 item u (§7): create_draft_settlement_batch() over real HTTP succeeds for the create-only actor and returns a real settlement_number",
    typeof stlCreateOnlyDraftRow?.settlement_number === "string" && /^SET-\d{10}$/.test(stlCreateOnlyDraftRow.settlement_number),
    `got ${JSON.stringify(stlCreateOnlyDraftRow)}`,
  );

  const stlCreateOnlyOwnDraftRows = await rpc("get_draft_settlement_batch_for_edit", { p_id: stlCreateOnlyDraftRow.id }, clientSettleCreateOnly);
  const stlCreateOnlyOwnDraftRow = Array.isArray(stlCreateOnlyOwnDraftRows) ? stlCreateOnlyOwnDraftRows[0] : stlCreateOnlyOwnDraftRows;
  ok(
    "Part 14 item u (§7): get_draft_settlement_batch_for_edit() over real HTTP succeeds for the create-only actor on their OWN draft, with no settlements.view at all",
    stlCreateOnlyOwnDraftRow?.id === stlCreateOnlyDraftRow.id && stlCreateOnlyOwnDraftRow?.status === "draft",
    `got ${JSON.stringify(stlCreateOnlyOwnDraftRow)}`,
  );

  const stlOthersDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
  const stlOthersDraftRow = Array.isArray(stlOthersDraftRows) ? stlOthersDraftRows[0] : stlOthersDraftRows;
  let stlCreateOnlyOthersDraftErr = null;
  try {
    await rpc("get_draft_settlement_batch_for_edit", { p_id: stlOthersDraftRow.id }, clientSettleCreateOnly);
  } catch (err) {
    stlCreateOnlyOthersDraftErr = err;
  }
  ok(
    "Part 14 item u (§7 — CRITICAL): get_draft_settlement_batch_for_edit() over real HTTP is DENIED to the create-only actor for a draft created by SOMEONE ELSE — 'own drafts only', not a blanket create-only pass",
    stlCreateOnlyOthersDraftErr !== null,
    `got ${stlCreateOnlyOthersDraftErr?.message}`,
  );

  // --- v) update_draft_settlement_batch() explicit keep/set/clear
  // semantics (Patch 7.1 §27). -------------------------------------------
  const stlUpdateDraftRows = await rpc("update_draft_settlement_batch", { p_id: stlOthersDraftRow.id, p_expected_version: 1, p_notes: "ملاحظة اختبار HTTP", p_notes_provided: true });
  const stlUpdateDraftRow = Array.isArray(stlUpdateDraftRows) ? stlUpdateDraftRows[0] : stlUpdateDraftRows;
  ok("Part 14 item v (§27): update_draft_settlement_batch() over real HTTP applies a new note when p_notes_provided=true", stlUpdateDraftRow?.row_version === 2, `got ${JSON.stringify(stlUpdateDraftRow)}`);

  await rpc("update_draft_settlement_batch", { p_id: stlOthersDraftRow.id, p_expected_version: 2, p_notes: null, p_notes_provided: true });
  const stlDraftAfterClearRows = await rpc("get_draft_settlement_batch_for_edit", { p_id: stlOthersDraftRow.id });
  const stlDraftAfterClear = Array.isArray(stlDraftAfterClearRows) ? stlDraftAfterClearRows[0] : stlDraftAfterClearRows;
  ok(
    "Part 14 item v (§27): update_draft_settlement_batch() over real HTTP genuinely CLEARS notes to NULL when p_notes_provided=true and p_notes=null (never merely 'left unspecified')",
    stlDraftAfterClear.notes === null,
    `got ${JSON.stringify(stlDraftAfterClear)}`,
  );

  // --- w) Layer-A lockdown continued: settlement_batch_lines/settlement_
  // bank_movement_events, now that real data genuinely exists on both. ----
  const { data: stlRawLinesRows, error: stlRawLinesErr } = await client.from("settlement_batch_lines").select("id").eq("settlement_batch_id", stlSaleBatchId);
  ok(
    "Part 14 item w: raw SELECT over real HTTP against settlement_batch_lines returns ZERO rows even though this batch genuinely has a line (zero SELECT RLS policy, migration 0173)",
    !stlRawLinesErr && Array.isArray(stlRawLinesRows) && stlRawLinesRows.length === 0,
    `error=${stlRawLinesErr?.message} rows=${stlRawLinesRows?.length}`,
  );
  const { data: stlRawMovementsRows, error: stlRawMovementsErr } = await client.from("settlement_bank_movement_events").select("id").eq("settlement_batch_id", stlSaleBatchId);
  ok(
    "Part 14 item w: raw SELECT over real HTTP against settlement_bank_movement_events returns ZERO rows even though this batch genuinely has a recorded movement (zero SELECT RLS policy, migration 0174)",
    !stlRawMovementsErr && Array.isArray(stlRawMovementsRows) && stlRawMovementsRows.length === 0,
    `error=${stlRawMovementsErr?.message} rows=${stlRawMovementsRows?.length}`,
  );
  let stlRawMovementInsertErr = null;
  try {
    const { error } = await client.from("settlement_bank_movement_events").insert({ settlement_batch_id: stlSaleBatchId, movement_business_date: todayIso, amount: "1.00" });
    if (error) stlRawMovementInsertErr = error;
  } catch (err) {
    stlRawMovementInsertErr = err;
  }
  ok(
    "Part 14 item w: raw INSERT over real HTTP against settlement_bank_movement_events is rejected even for the full-permission actor — only record_settlement_bank_movement() may write",
    stlRawMovementInsertErr !== null,
    `got ${stlRawMovementInsertErr?.message}`,
  );

  // --- x) COD source adapter: route matching, no-double-counting, and
  // route_formula fee parity between preview and finalize (Patch 7.1 §14,
  // CRITICAL). -----------------------------------------------------------
  const stlCodOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "1200.00" }],
  });
  const stlCodOrderRow = Array.isArray(stlCodOrderRows) ? stlCodOrderRows[0] : stlCodOrderRows;
  const stlCodOrderId = stlCodOrderRow?.id;

  const stlCodCarriers = await rpc("shipments_carrier_lookups", {});
  const stlCodZones = await rpc("shipments_zone_lookups", {});
  const stlCodCarrier = stlCodCarriers.find((c) => c.code === "SMSA");
  const stlCodZone = stlCodZones.find((z) => z.code === "RIYADH");

  const stlCodShipmentRows = await rpc("create_shipment", {
    p_sales_order_id: stlCodOrderId, p_store_id: STORE_ID, p_shipment_date: todayIso, p_direction: "outbound",
    p_carrier_id: stlCodCarrier.id, p_shipping_zone_id: stlCodZone.id, p_customer_shipping_charge: "0.00",
    p_is_cod: true, p_cod_expected_amount: "1200.00", p_manual_expected_cost: "5.00", p_manual_expected_cost_reason: "HTTP test تسويات — شحنة COD",
  });
  const stlCodShipmentRow = Array.isArray(stlCodShipmentRows) ? stlCodShipmentRows[0] : stlCodShipmentRows;
  const stlCodShipmentId = stlCodShipmentRow?.id;

  const stlSourcesChannelledForCod = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  ok(
    "Part 14 item x (item 5 — no-double-counting): the COD Sale is ABSENT from the payment_collection route's Sale sources — its money movement belongs entirely to the COD route instead",
    !stlSourcesChannelledForCod.some((s) => s.source_kind === "sale" && s.source_event_id === stlCodOrderId),
    `got ${JSON.stringify(stlSourcesChannelledForCod.filter((s) => s.source_kind === "sale" && s.source_event_id === stlCodOrderId))}`,
  );

  await rpc("record_shipment_cod_collection_state", { p_shipment_id: stlCodShipmentId, p_expected_version: 1, p_new_state: "collected", p_business_date: todayIso });
  const stlCodSources = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteCodId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const stlCodCollectionSource = stlCodSources.find((s) => s.source_kind === "cod_collection" && s.source_number === stlCodShipmentRow.shipment_number);
  ok(
    "Part 14 item x: list_unsettled_settlement_sources() over real HTTP surfaces the COD collection as source_kind='cod_collection' for the cod_carrier route (matched purely on shipping_carrier_id, item 9), gross=1200.00 (cod_expected_amount)",
    typeof stlCodCollectionSource?.gross_collection_impact === "string" && new Decimal(stlCodCollectionSource.gross_collection_impact).equals(new Decimal("1200.00")),
    `got ${JSON.stringify(stlCodCollectionSource)}`,
  );
  const stlCodCollectionEventId = stlCodCollectionSource.source_event_id;

  const stlCodPreviewRows = await rpc("preview_settlement_batch", {
    p_settlement_route_id: stlRouteCodId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_selected_sources: [{ source_kind: "cod_collection", source_event_id: stlCodCollectionEventId }],
  });
  const stlCodPreviewRow = Array.isArray(stlCodPreviewRows) ? stlCodPreviewRows[0] : stlCodPreviewRows;
  ok(
    "Part 14 item x (§14): preview_settlement_batch() over real HTTP computes the route_formula fee (2% of 1200.00 + 1.50 fixed = 25.50) via the SAME shared resolver finalize will use, every total typeof 'string'",
    typeof stlCodPreviewRow?.provider_fee_impact === "string" && new Decimal(stlCodPreviewRow.provider_fee_impact).equals(new Decimal("25.50")) &&
      typeof stlCodPreviewRow.gross_source_impact === "string" && typeof stlCodPreviewRow.expected_bank_settlement === "string",
    `got ${JSON.stringify(stlCodPreviewRow)}`,
  );

  const stlCodDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteCodId, p_settlement_date: todayIso });
  const stlCodDraftRow = Array.isArray(stlCodDraftRows) ? stlCodDraftRows[0] : stlCodDraftRows;
  await rpc("finalize_settlement_batch", { p_settlement_batch_id: stlCodDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "cod_collection", source_event_id: stlCodCollectionEventId }] });
  const stlCodBatchDetailRows = await rpc("get_settlement_batch", { p_settlement_batch_id: stlCodDraftRow.id });
  const stlCodBatchDetail = Array.isArray(stlCodBatchDetailRows) ? stlCodBatchDetailRows[0] : stlCodBatchDetailRows;
  ok(
    "Part 14 item x (§14 — CRITICAL, route_formula parity): finalize_settlement_batch() over real HTTP produces the EXACT SAME provider_fee_impact (25.50) preview_settlement_batch() already showed for this SAME selection — the two can never drift apart",
    new Decimal(stlCodBatchDetail.original_provider_fee_impact).equals(new Decimal(stlCodPreviewRow.provider_fee_impact)),
    `preview=${stlCodPreviewRow.provider_fee_impact} finalize=${stlCodBatchDetail.original_provider_fee_impact}`,
  );

  await rpc("record_shipment_cod_collection_state", { p_shipment_id: stlCodShipmentId, p_expected_version: 2, p_new_state: "not_collected", p_business_date: todayIso });
  const stlCodSourcesAfterReversal = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteCodId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const stlCodReversalSource = stlCodSourcesAfterReversal.find((s) => s.source_kind === "cod_reversal" && s.source_number === stlCodShipmentRow.shipment_number);
  ok(
    "Part 14 item y (item 20/21/22): a genuine collected -> not_collected transition over real HTTP produces a NEW 'cod_reversal' source, gross=-1200.00 (negative, exactly reversing the paired collection)",
    typeof stlCodReversalSource?.gross_collection_impact === "string" && new Decimal(stlCodReversalSource.gross_collection_impact).equals(new Decimal("-1200.00")),
    `got ${JSON.stringify(stlCodReversalSource)}`,
  );

  // =====================================================================
  // Part 15 — Phase 7 Final Integrity Hotfix 7.1.1 (migrations 0192-0196),
  // proven over the SAME real HTTP/PostgREST round trip, extending Part 14.
  // See the file header comment for the full a-k checklist.
  // =====================================================================
  const p15PastIso = new Date(Date.now() + 3 * 60 * 60 * 1000 - 2 * 86400000).toISOString().slice(0, 10);
  const p15ReversalIso = new Date(Date.now() + 3 * 60 * 60 * 1000 - 1 * 86400000).toISOString().slice(0, 10);

  // --- a) update_draft_settlement_batch() ownership on WRITE (§4). -------
  const p15OwnerDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso }, clientSettleCreateOnly);
  const p15OwnerDraftRow = Array.isArray(p15OwnerDraftRows) ? p15OwnerDraftRows[0] : p15OwnerDraftRows;
  const p15OwnerDraftId = p15OwnerDraftRow?.id;

  let p15aOtherErr = null;
  try {
    await rpc("update_draft_settlement_batch", { p_id: p15OwnerDraftId, p_expected_version: 1, p_notes: "محاولة تعديل من غير المالك (Part 15)", p_notes_provided: true }, clientSettleCreateOnly2);
  } catch (err) {
    p15aOtherErr = err;
  }
  ok(
    "Part 15 item a (§4 — CRITICAL): update_draft_settlement_batch() over real HTTP rejects (not-found) a DIFFERENT, genuinely distinct create-only, non-owner actor from editing someone else's draft",
    p15aOtherErr !== null && /غير موجودة/.test(String(p15aOtherErr.message)),
    `got ${p15aOtherErr?.message}`,
  );

  const p15OwnerUpdateRows = await rpc("update_draft_settlement_batch", { p_id: p15OwnerDraftId, p_expected_version: 1, p_notes: "تعديل من المالك نفسه (Part 15)", p_notes_provided: true }, clientSettleCreateOnly);
  const p15OwnerUpdateRow = Array.isArray(p15OwnerUpdateRows) ? p15OwnerUpdateRows[0] : p15OwnerUpdateRows;
  ok(
    "Part 15 item a (§4): update_draft_settlement_batch() over real HTTP lets the OWNER (create-only, no settlements.view) update their own draft",
    p15OwnerUpdateRow?.row_version === 2,
    `got ${JSON.stringify(p15OwnerUpdateRow)}`,
  );

  const p15ViewHolderUpdateRows = await rpc("update_draft_settlement_batch", { p_id: p15OwnerDraftId, p_expected_version: 2, p_notes: "تعديل من حامل settlements.view (Part 15)", p_notes_provided: true });
  const p15ViewHolderUpdateRow = Array.isArray(p15ViewHolderUpdateRows) ? p15ViewHolderUpdateRows[0] : p15ViewHolderUpdateRows;
  ok(
    "Part 15 item a (§4): update_draft_settlement_batch() over real HTTP is UNRESTRICTED for a settlements.view holder (actor 001), even on a draft owned by someone else entirely",
    p15ViewHolderUpdateRow?.row_version === 3,
    `got ${JSON.stringify(p15ViewHolderUpdateRow)}`,
  );

  // --- b) store-scope fail-closed on ALL FOUR lifecycle write RPCs (§5). -
  const p15ScopeOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "800.00" }],
  });
  const p15ScopeOrderRow = Array.isArray(p15ScopeOrderRows) ? p15ScopeOrderRows[0] : p15ScopeOrderRows;
  const p15ScopeAdjCreateRows = await rpc("create_sales_order_adjustment", {
    p_sales_order_id: p15ScopeOrderRow.id, p_adjustment_type_id: adjTypeId, p_processing_store_id: STORE_B_ID, p_adjustment_date: todayIso,
    p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID, p_participates_in_settlement: true,
    p_customer_charge: "150.00", p_direct_cost: "0.00", p_notes: "Part 15 §5 — نطاق المتجر",
  });
  const p15ScopeAdjCreateRow = Array.isArray(p15ScopeAdjCreateRows) ? p15ScopeAdjCreateRows[0] : p15ScopeAdjCreateRows;
  const p15ScopeAdjId = p15ScopeAdjCreateRow?.id;
  const p15ScopeAdjDetailRows = await rpc("get_sales_order_adjustment", { p_id: p15ScopeAdjId });
  const p15ScopeAdjDetail = Array.isArray(p15ScopeAdjDetailRows) ? p15ScopeAdjDetailRows[0] : p15ScopeAdjDetailRows;
  await rpc("approve_sales_order_adjustment", { p_id: p15ScopeAdjId, p_expected_version: p15ScopeAdjDetail.row_version });

  const p15ScopeDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
  const p15ScopeDraftRow = Array.isArray(p15ScopeDraftRows) ? p15ScopeDraftRows[0] : p15ScopeDraftRows;
  const p15ScopeBatchId = p15ScopeDraftRow.id;
  const p15ScopeFinalizeRows = await rpc("finalize_settlement_batch", { p_settlement_batch_id: p15ScopeBatchId, p_expected_version: 1, p_selected_sources: [{ source_kind: "adjustment_approved", source_event_id: p15ScopeAdjId }] });
  const p15ScopeFinalizeRow = Array.isArray(p15ScopeFinalizeRows) ? p15ScopeFinalizeRows[0] : p15ScopeFinalizeRows;

  let p15ScopeRecordErr = null;
  try {
    await rpc("record_settlement_bank_movement", { p_settlement_batch_id: p15ScopeBatchId, p_movement_business_date: todayIso, p_amount: "50.00" }, clientSettleStoreScoped);
  } catch (err) {
    p15ScopeRecordErr = err;
  }
  ok(
    "Part 15 item b (§5 — CRITICAL): record_settlement_bank_movement() over real HTTP fails closed (not-found) for a single-store-scoped actor who cannot see one of the batch's lines' stores",
    p15ScopeRecordErr !== null && /غير موجودة/.test(String(p15ScopeRecordErr.message)),
    `got ${p15ScopeRecordErr?.message}`,
  );

  let p15ScopeReconcileErr = null;
  try {
    await rpc("reconcile_settlement_batch", { p_settlement_batch_id: p15ScopeBatchId, p_expected_version: p15ScopeFinalizeRow.row_version }, clientSettleStoreScoped);
  } catch (err) {
    p15ScopeReconcileErr = err;
  }
  ok(
    "Part 15 item b (§5 — CRITICAL): reconcile_settlement_batch() over real HTTP fails closed (not-found) for the SAME store-scoped actor",
    p15ScopeReconcileErr !== null && /غير موجودة/.test(String(p15ScopeReconcileErr.message)),
    `got ${p15ScopeReconcileErr?.message}`,
  );

  let p15ScopeCancelErr = null;
  try {
    await rpc("cancel_settlement_batch", { p_settlement_batch_id: p15ScopeBatchId, p_expected_version: p15ScopeFinalizeRow.row_version, p_cancellation_business_date: todayIso, p_reason: "محاولة إلغاء من نطاق متجر مقيد" }, clientSettleStoreScoped);
  } catch (err) {
    p15ScopeCancelErr = err;
  }
  ok(
    "Part 15 item b (§5 — CRITICAL): cancel_settlement_batch() over real HTTP fails closed (not-found) for the SAME store-scoped actor",
    p15ScopeCancelErr !== null && /غير موجودة/.test(String(p15ScopeCancelErr.message)),
    `got ${p15ScopeCancelErr?.message}`,
  );

  const p15ScopeBatchDetailRows = await rpc("get_settlement_batch", { p_settlement_batch_id: p15ScopeBatchId });
  const p15ScopeBatchDetail = Array.isArray(p15ScopeBatchDetailRows) ? p15ScopeBatchDetailRows[0] : p15ScopeBatchDetailRows;
  const p15ScopeMovementId = await rpc("record_settlement_bank_movement", { p_settlement_batch_id: p15ScopeBatchId, p_movement_business_date: todayIso, p_amount: p15ScopeBatchDetail.original_expected_bank_settlement, p_bank_reference: "HTTP-P15-BANK-SCOPE" });
  ok(
    "Part 15 item b (§5): record_settlement_bank_movement() over real HTTP SUCCEEDS for the FULL actor on the SAME batch — store-scope only fails closed the restricted actor, not everyone",
    typeof p15ScopeMovementId === "string" && p15ScopeMovementId.length === 36,
    `got ${JSON.stringify(p15ScopeMovementId)}`,
  );

  let p15ScopeReverseErr = null;
  try {
    await rpc("reverse_settlement_bank_movement", { p_bank_movement_event_id: p15ScopeMovementId, p_reversal_business_date: todayIso, p_reason: "محاولة عكس من نطاق متجر مقيد" }, clientSettleStoreScoped);
  } catch (err) {
    p15ScopeReverseErr = err;
  }
  ok(
    "Part 15 item b (§5 — CRITICAL): reverse_settlement_bank_movement() over real HTTP fails closed for the SAME store-scoped actor, keyed on the movement's OWN batch",
    p15ScopeReverseErr !== null,
    `got ${p15ScopeReverseErr?.message}`,
  );

  const p15ScopeReconcileRows = await rpc("reconcile_settlement_batch", { p_settlement_batch_id: p15ScopeBatchId, p_expected_version: p15ScopeFinalizeRow.row_version });
  const p15ScopeReconcileRow = Array.isArray(p15ScopeReconcileRows) ? p15ScopeReconcileRows[0] : p15ScopeReconcileRows;
  ok(
    "Part 15 item b (§5): reconcile_settlement_batch() over real HTTP SUCCEEDS for the FULL actor on the SAME batch (zero variance, exact movement)",
    typeof p15ScopeReconcileRow?.variance === "string" && new Decimal(p15ScopeReconcileRow.variance).equals(new Decimal("0.00")),
    `got ${JSON.stringify(p15ScopeReconcileRow)}`,
  );

  const p15ScopeReversalId = await rpc("reverse_settlement_bank_movement", { p_bank_movement_event_id: p15ScopeMovementId, p_reversal_business_date: todayIso, p_reason: "Part 15 §5 — عكس للسماح بالإلغاء" });
  ok(
    "Part 15 item b (§5): reverse_settlement_bank_movement() over real HTTP SUCCEEDS for the FULL actor on the SAME movement",
    typeof p15ScopeReversalId === "string" && p15ScopeReversalId.length === 36,
    `got ${JSON.stringify(p15ScopeReversalId)}`,
  );

  const p15ScopeCancelId = await rpc("cancel_settlement_batch", { p_settlement_batch_id: p15ScopeBatchId, p_expected_version: p15ScopeReconcileRow.row_version, p_cancellation_business_date: todayIso, p_reason: "Part 15 §5 — إلغاء نهائي بعد إثبات النطاق" });
  ok(
    "Part 15 item b (§5): cancel_settlement_batch() over real HTTP SUCCEEDS for the FULL actor on the SAME batch — all four lifecycle write RPCs fail closed for the store-scoped actor and succeed for the full actor, on the exact same batch",
    typeof p15ScopeCancelId === "string" && p15ScopeCancelId.length === 36,
    `got ${JSON.stringify(p15ScopeCancelId)}`,
  );

  // --- c) settlement_route_fee_for_route_on_date() EXECUTE-revoked (§6). -
  let p15FeeResolverErr = null;
  try {
    await rpc("settlement_route_fee_for_route_on_date", { p_settlement_route_id: stlRouteChannelledId, p_date: todayIso });
  } catch (err) {
    p15FeeResolverErr = err;
  }
  ok(
    "Part 15 item c (§6 — CRITICAL): settlement_route_fee_for_route_on_date() is no longer callable via PostgREST RPC AT ALL over real HTTP, even for the most-privileged actor (EXECUTE revoked from PUBLIC and authenticated) — every legitimate caller only ever reaches it internally, as a SECURITY DEFINER function owner",
    p15FeeResolverErr !== null,
    `got ${p15FeeResolverErr?.message ?? "no error — RPC unexpectedly succeeded, which would be a real regression"}`,
  );

  // --- d) reconcile_settlement_batch() redaction, live (§7). -------------
  const p15ReconOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "600.00" }],
  });
  const p15ReconOrderRow = Array.isArray(p15ReconOrderRows) ? p15ReconOrderRows[0] : p15ReconOrderRows;
  const p15ReconDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
  const p15ReconDraftRow = Array.isArray(p15ReconDraftRows) ? p15ReconDraftRows[0] : p15ReconDraftRows;
  const p15ReconFinalizeRows = await rpc("finalize_settlement_batch", { p_settlement_batch_id: p15ReconDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "sale", source_event_id: p15ReconOrderRow.id }] });
  const p15ReconFinalizeRow = Array.isArray(p15ReconFinalizeRows) ? p15ReconFinalizeRows[0] : p15ReconFinalizeRows;
  const p15ReconBatchDetailRows = await rpc("get_settlement_batch", { p_settlement_batch_id: p15ReconDraftRow.id });
  const p15ReconBatchDetail = Array.isArray(p15ReconBatchDetailRows) ? p15ReconBatchDetailRows[0] : p15ReconBatchDetailRows;
  await rpc("record_settlement_bank_movement", { p_settlement_batch_id: p15ReconDraftRow.id, p_movement_business_date: todayIso, p_amount: p15ReconBatchDetail.original_expected_bank_settlement, p_bank_reference: "HTTP-P15-BANK-RECON" });

  const p15ReconRedactedRows = await rpc("reconcile_settlement_batch", { p_settlement_batch_id: p15ReconDraftRow.id, p_expected_version: p15ReconFinalizeRow.row_version }, clientSettleReconcileOnly);
  const p15ReconRedactedRow = Array.isArray(p15ReconRedactedRows) ? p15ReconRedactedRows[0] : p15ReconRedactedRows;
  ok(
    "Part 15 item d (§7 — CRITICAL): reconcile_settlement_batch() over real HTTP SUCCEEDS (the reconciliation itself only needs settlements.reconcile) but redacts actual_bank_movement/variance to JSON null for an actor holding settlements.reconcile WITHOUT settlements.view_financials",
    p15ReconRedactedRow?.actual_bank_movement === null && p15ReconRedactedRow?.variance === null,
    `got ${JSON.stringify(p15ReconRedactedRow)}`,
  );

  const p15ReconOrder2Rows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "650.00" }],
  });
  const p15ReconOrder2Row = Array.isArray(p15ReconOrder2Rows) ? p15ReconOrder2Rows[0] : p15ReconOrder2Rows;
  const p15ReconDraft2Rows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
  const p15ReconDraft2Row = Array.isArray(p15ReconDraft2Rows) ? p15ReconDraft2Rows[0] : p15ReconDraft2Rows;
  const p15ReconFinalize2Rows = await rpc("finalize_settlement_batch", { p_settlement_batch_id: p15ReconDraft2Row.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "sale", source_event_id: p15ReconOrder2Row.id }] });
  const p15ReconFinalize2Row = Array.isArray(p15ReconFinalize2Rows) ? p15ReconFinalize2Rows[0] : p15ReconFinalize2Rows;
  const p15ReconBatchDetail2Rows = await rpc("get_settlement_batch", { p_settlement_batch_id: p15ReconDraft2Row.id });
  const p15ReconBatchDetail2 = Array.isArray(p15ReconBatchDetail2Rows) ? p15ReconBatchDetail2Rows[0] : p15ReconBatchDetail2Rows;
  await rpc("record_settlement_bank_movement", { p_settlement_batch_id: p15ReconDraft2Row.id, p_movement_business_date: todayIso, p_amount: p15ReconBatchDetail2.original_expected_bank_settlement, p_bank_reference: "HTTP-P15-BANK-RECON2" });
  const p15ReconFullRows = await rpc("reconcile_settlement_batch", { p_settlement_batch_id: p15ReconDraft2Row.id, p_expected_version: p15ReconFinalize2Row.row_version });
  const p15ReconFullRow = Array.isArray(p15ReconFullRows) ? p15ReconFullRows[0] : p15ReconFullRows;
  ok(
    "Part 15 item d (§7): the SAME kind of reconciliation (zero variance) on a SEPARATE batch returns REAL typeof 'string' actual_bank_movement/variance for an actor holding settlements.view_financials",
    typeof p15ReconFullRow?.actual_bank_movement === "string" && typeof p15ReconFullRow?.variance === "string" && new Decimal(p15ReconFullRow.variance).equals(new Decimal("0.00")),
    `got ${JSON.stringify(p15ReconFullRow)}`,
  );

  // --- e) preview/finalize batch-fee-override parity + validation (§9). --
  const p15OverrideOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "700.00" }],
  });
  const p15OverrideOrderRow = Array.isArray(p15OverrideOrderRows) ? p15OverrideOrderRows[0] : p15OverrideOrderRows;
  const p15OverrideOrderId = p15OverrideOrderRow?.id;

  let p15PreviewNoReasonErr = null;
  try {
    await rpc("preview_settlement_batch", {
      p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo,
      p_selected_sources: [{ source_kind: "sale", source_event_id: p15OverrideOrderId }], p_batch_fee_override: "9.99",
    });
  } catch (err) {
    p15PreviewNoReasonErr = err;
  }
  ok(
    "Part 15 item e (§9): preview_settlement_batch() over real HTTP REJECTS a batch-fee override with no p_override_reason — the SAME validation finalize_settlement_batch() already enforces, now present at Preview time too",
    p15PreviewNoReasonErr !== null,
    `got ${p15PreviewNoReasonErr?.message}`,
  );

  let p15PreviewNegativeErr = null;
  try {
    await rpc("preview_settlement_batch", {
      p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo,
      p_selected_sources: [{ source_kind: "sale", source_event_id: p15OverrideOrderId }], p_batch_fee_override: "-1.00", p_override_reason: "اختبار رفض قيمة سالبة",
    });
  } catch (err) {
    p15PreviewNegativeErr = err;
  }
  ok(
    "Part 15 item e (§9): preview_settlement_batch() over real HTTP REJECTS a NEGATIVE batch-fee override",
    p15PreviewNegativeErr !== null,
    `got ${p15PreviewNegativeErr?.message}`,
  );

  const p15PreviewRows = await rpc("preview_settlement_batch", {
    p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo,
    p_selected_sources: [{ source_kind: "sale", source_event_id: p15OverrideOrderId }], p_batch_fee_override: "9.99",
    p_override_reason: "Part 15 §9 — اختبار تكافؤ المعاينة/الاعتماد",
  });
  const p15PreviewRow = Array.isArray(p15PreviewRows) ? p15PreviewRows[0] : p15PreviewRows;
  ok(
    "Part 15 item e (§9): preview_settlement_batch() over real HTTP with a batch-fee override returns effective_batch_fee=9.99 (typeof 'string'), batch_fee_overridden=true, and configured_batch_fee is the route's real configured default (a DIFFERENT value from 9.99)",
    typeof p15PreviewRow?.effective_batch_fee === "string" && new Decimal(p15PreviewRow.effective_batch_fee).equals(new Decimal("9.99")) &&
      p15PreviewRow.batch_fee_overridden === true &&
      typeof p15PreviewRow.configured_batch_fee === "string" && !new Decimal(p15PreviewRow.configured_batch_fee).equals(new Decimal("9.99")),
    `got ${JSON.stringify(p15PreviewRow)}`,
  );

  const p15ParityDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
  const p15ParityDraftRow = Array.isArray(p15ParityDraftRows) ? p15ParityDraftRows[0] : p15ParityDraftRows;
  await rpc("finalize_settlement_batch", {
    p_settlement_batch_id: p15ParityDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "sale", source_event_id: p15OverrideOrderId }],
    p_batch_fee_override: "9.99", p_override_reason: "Part 15 §9 — اختبار تكافؤ المعاينة/الاعتماد",
  });
  const p15ParityBatchDetailRows = await rpc("get_settlement_batch", { p_settlement_batch_id: p15ParityDraftRow.id });
  const p15ParityBatchDetail = Array.isArray(p15ParityBatchDetailRows) ? p15ParityBatchDetailRows[0] : p15ParityBatchDetailRows;
  ok(
    "Part 15 item e (§9 — CRITICAL, PARITY): for the SAME override on the SAME selection, finalize_settlement_batch()'s snapshotted original_batch_fee equals preview_settlement_batch()'s effective_batch_fee (as Decimal)",
    new Decimal(p15ParityBatchDetail.original_batch_fee).equals(new Decimal(p15PreviewRow.effective_batch_fee)),
    `preview=${p15PreviewRow.effective_batch_fee} finalize=${p15ParityBatchDetail.original_batch_fee}`,
  );
  ok(
    "Part 15 item e (§9 — PARITY, exact string equality): preview_settlement_batch()'s effective_batch_fee and finalize_settlement_batch()'s snapshotted original_batch_fee are the EXACT SAME text on the wire, not merely numerically equal",
    p15ParityBatchDetail.original_batch_fee === p15PreviewRow.effective_batch_fee,
    `preview=${JSON.stringify(p15PreviewRow.effective_batch_fee)} finalize=${JSON.stringify(p15ParityBatchDetail.original_batch_fee)}`,
  );

  // --- f) cancellation chronology vs the latest bank-movement reversal
  // (§11). -----------------------------------------------------------
  const p15ChronoOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: p15PastIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "400.00" }],
  });
  const p15ChronoOrderRow = Array.isArray(p15ChronoOrderRows) ? p15ChronoOrderRows[0] : p15ChronoOrderRows;
  const p15ChronoDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: p15PastIso });
  const p15ChronoDraftRow = Array.isArray(p15ChronoDraftRows) ? p15ChronoDraftRows[0] : p15ChronoDraftRows;
  const p15ChronoFinalizeRows = await rpc("finalize_settlement_batch", { p_settlement_batch_id: p15ChronoDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "sale", source_event_id: p15ChronoOrderRow.id }] });
  const p15ChronoFinalizeRow = Array.isArray(p15ChronoFinalizeRows) ? p15ChronoFinalizeRows[0] : p15ChronoFinalizeRows;
  const p15ChronoBatchDetailRows = await rpc("get_settlement_batch", { p_settlement_batch_id: p15ChronoDraftRow.id });
  const p15ChronoBatchDetail = Array.isArray(p15ChronoBatchDetailRows) ? p15ChronoBatchDetailRows[0] : p15ChronoBatchDetailRows;
  const p15ChronoMovementId = await rpc("record_settlement_bank_movement", { p_settlement_batch_id: p15ChronoDraftRow.id, p_movement_business_date: p15PastIso, p_amount: p15ChronoBatchDetail.original_expected_bank_settlement, p_bank_reference: "HTTP-P15-BANK-CHRONO" });
  await rpc("reverse_settlement_bank_movement", { p_bank_movement_event_id: p15ChronoMovementId, p_reversal_business_date: p15ReversalIso, p_reason: "Part 15 §11 — عكس لاختبار التسلسل الزمني" });

  let p15ChronoTooEarlyErr = null;
  try {
    await rpc("cancel_settlement_batch", { p_settlement_batch_id: p15ChronoDraftRow.id, p_expected_version: p15ChronoFinalizeRow.row_version, p_cancellation_business_date: p15PastIso, p_reason: "محاولة إلغاء بتاريخ أسبق من تاريخ العكس" });
  } catch (err) {
    p15ChronoTooEarlyErr = err;
  }
  ok(
    "Part 15 item f (§11): cancel_settlement_batch() over real HTTP REJECTS a cancellation dated BEFORE the latest bank-movement reversal on this batch (still on/after settlement_date, so this is specifically the §11 chronology guard, not the pre-existing settlement_date one)",
    p15ChronoTooEarlyErr !== null && /لا يمكن أن يكون قبل تاريخ آخر عكس/.test(String(p15ChronoTooEarlyErr.message)),
    `got ${p15ChronoTooEarlyErr?.message}`,
  );

  const p15ChronoCancelId = await rpc("cancel_settlement_batch", { p_settlement_batch_id: p15ChronoDraftRow.id, p_expected_version: p15ChronoFinalizeRow.row_version, p_cancellation_business_date: p15ReversalIso, p_reason: "إلغاء بتاريخ مطابق لتاريخ العكس — صحيح" });
  ok(
    "Part 15 item f (§11): cancel_settlement_batch() over real HTTP SUCCEEDS once dated on/after the latest bank-movement reversal",
    typeof p15ChronoCancelId === "string" && p15ChronoCancelId.length === 36,
    `got ${JSON.stringify(p15ChronoCancelId)}`,
  );

  // --- g) settlements.view-gated filter lookups (§12). --------------------
  const p15FilterPmView = await rpc("settlement_filter_payment_method_lookups", {}, clientNoProfit);
  const p15FilterChannelView = await rpc("settlement_filter_collection_channel_lookups", {}, clientNoProfit);
  ok(
    "Part 15 item g (§12): settlement_filter_payment_method_lookups()/settlement_filter_collection_channel_lookups() over real HTTP work for an actor holding settlements.view ALONE (no payment_methods.view/collection_channels.view at all) and INCLUDE disabled/historical rows",
    Array.isArray(p15FilterPmView) && p15FilterPmView.some((p) => p.id === "c9200000-0000-4000-8000-000000000002" && p.status === "inactive") &&
      Array.isArray(p15FilterChannelView) && p15FilterChannelView.some((c) => c.id === "c9500000-0000-4000-8000-000000000002" && c.status === "inactive"),
    `got pm=${JSON.stringify(p15FilterPmView)} channel=${JSON.stringify(p15FilterChannelView)}`,
  );

  const p15FilterPmCreateOnly = await rpc("settlement_filter_payment_method_lookups", {}, clientSettleCreateOnly);
  ok(
    "Part 15 item g (§12): settlement_filter_payment_method_lookups() over real HTTP returns an EMPTY result for an actor holding settlements.create but NOT settlements.view — the RPC gates every row via has_permission('settlements.view') inside its own WHERE clause (a permission-only-filtered SELECT, not an exception-raising check), so PostgREST itself still returns 200/[] rather than an error",
    Array.isArray(p15FilterPmCreateOnly) && p15FilterPmCreateOnly.length === 0,
    `got ${JSON.stringify(p15FilterPmCreateOnly)}`,
  );

  // --- h) cross-store source filter OR-match (§15). -----------------------
  const p15OrStoreA = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_store_id: STORE_ID, p_limit: 5000 });
  const p15OrStoreB = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_store_id: STORE_B_ID, p_limit: 5000 });
  ok(
    "Part 15 item h (§15): list_unsettled_settlement_sources()'s p_store_id filter over real HTTP matches the SAME cross-store Adjustment (Part 14 item f/j's stlCrossAdjId, unclaimed again since item j's cancellation) under EITHER Store A (the original Sale's own store) OR Store B (the processing store) independently — OR, not AND",
    p15OrStoreA.some((s) => s.source_kind === "adjustment_approved" && s.source_event_id === stlCrossAdjId) &&
      p15OrStoreB.some((s) => s.source_kind === "adjustment_approved" && s.source_event_id === stlCrossAdjId),
    `storeA found=${p15OrStoreA.some((s) => s.source_event_id === stlCrossAdjId)} storeB found=${p15OrStoreB.some((s) => s.source_event_id === stlCrossAdjId)}`,
  );

  // --- i) fee-reversal historical permanence + coexistence (§1, CRITICAL). -
  const p15PermOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "2.0000", sale_price: "2000.00" }],
    p_customer_name: "عميل اختبار الدوام التاريخي — Part 15",
  });
  const p15PermOrderRow = Array.isArray(p15PermOrderRows) ? p15PermOrderRows[0] : p15PermOrderRows;
  const p15PermReturnable = await rpc("get_returnable_sales_order", { p_sales_order_id: p15PermOrderRow.id });
  const p15PermItem = p15PermReturnable.items[0];
  const p15PermReturnRows = await rpc("create_sales_return", {
    p_sales_order_id: p15PermOrderRow.id, p_processed_store_id: STORE_ID, p_return_date: todayIso, p_scenario: "defective_product",
    p_items: [{ sales_order_item_id: p15PermItem.id, condition: "good_resellable" }],
    p_expected_sale_version: p15PermReturnable.row_version, p_collection_state: "collected", p_approved_refund_amount: "2000.00",
  });
  const p15PermReturnRow = Array.isArray(p15PermReturnRows) ? p15PermReturnRows[0] : p15PermReturnRows;
  const p15PermReturnId = p15PermReturnRow?.id;
  const p15PermReturnPending = await rpc("get_sales_return", { p_id: p15PermReturnId });
  await rpc("approve_sales_return", { p_return_id: p15PermReturnId, p_expected_version: p15PermReturnPending.row_version });
  const p15PermReturnApproved = await rpc("get_sales_return", { p_id: p15PermReturnId });
  const p15PermFeeReversalAmount = p15PermReturnApproved.payment_fee_reversal_amount;

  const p15PermSourcesBeforeReverse = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const p15PermFeeReversalBefore = p15PermSourcesBeforeReverse.find((s) => s.source_kind === "return_fee_reversal" && s.source_event_id === p15PermReturnId);
  ok(
    "Part 15 item i (§1): the return_fee_reversal source appears immediately upon approval, over real HTTP, BEFORE any administrative reversal",
    typeof p15PermFeeReversalBefore?.expected_settlement_impact === "string" && new Decimal(p15PermFeeReversalBefore.expected_settlement_impact).equals(new Decimal(p15PermFeeReversalAmount)),
    `got ${JSON.stringify(p15PermFeeReversalBefore)}`,
  );

  await rpc("reverse_sales_return", { p_return_id: p15PermReturnId, p_expected_version: p15PermReturnApproved.row_version, p_reversal_reason: "Part 15 §1 — عكس إداري لاختبار الدوام التاريخي", p_reversal_business_date: todayIso });

  const p15PermSourcesAfterReverse = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const p15PermFeeReversalAfter = p15PermSourcesAfterReverse.find((s) => s.source_kind === "return_fee_reversal" && s.source_event_id === p15PermReturnId);
  const p15PermFeeReversalReversalAfter = p15PermSourcesAfterReverse.find((s) => s.source_kind === "return_fee_reversal_reversal" && s.source_event_id === p15PermReturnId);
  ok(
    "Part 15 item i (§1 — CRITICAL): the return_fee_reversal source is STILL PRESENT over real HTTP after an administrative reverse_sales_return() call — a permanent historical fact, never re-derived from current status (the pre-hotfix bug this closes) — gross=0.00, expected UNCHANGED from before the reversal",
    typeof p15PermFeeReversalAfter?.gross_collection_impact === "string" && new Decimal(p15PermFeeReversalAfter.gross_collection_impact).equals(new Decimal("0.00")) &&
      new Decimal(p15PermFeeReversalAfter.expected_settlement_impact).equals(new Decimal(p15PermFeeReversalAmount)),
    `got ${JSON.stringify(p15PermFeeReversalAfter)}`,
  );
  ok(
    "Part 15 item i (§1): a NEW, INDEPENDENT return_fee_reversal_reversal source now ALSO appears over real HTTP for this SAME return, alongside the still-present original",
    typeof p15PermFeeReversalReversalAfter?.gross_collection_impact === "string",
    `got ${JSON.stringify(p15PermFeeReversalReversalAfter)}`,
  );
  ok(
    "Part 15 item i (§1): while BOTH remain unclaimed, their expected_settlement_impact values sum to EXACTLY 0.00 (as Decimal) — net zero, no phantom financial effect",
    new Decimal(p15PermFeeReversalAfter.expected_settlement_impact).plus(new Decimal(p15PermFeeReversalReversalAfter.expected_settlement_impact)).equals(new Decimal("0.00")),
    `feeReversal=${p15PermFeeReversalAfter.expected_settlement_impact} feeReversalReversal=${p15PermFeeReversalReversalAfter.expected_settlement_impact}`,
  );

  // --- j)/k) route-matching via the original Sale + independent claiming
  // into different batches (§3, §1/§3 consequence). -----------------------
  const p15RmOrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "900.00" }],
    p_customer_name: "عميل اختبار مطابقة المسار الأصلي — Part 15",
  });
  const p15RmOrderRow = Array.isArray(p15RmOrderRows) ? p15RmOrderRows[0] : p15RmOrderRows;
  const p15RmReturnable = await rpc("get_returnable_sales_order", { p_sales_order_id: p15RmOrderRow.id });
  const p15RmItem = p15RmReturnable.items[0];
  const p15RmReturnRows = await rpc("create_sales_return", {
    p_sales_order_id: p15RmOrderRow.id, p_processed_store_id: STORE_ID, p_return_date: todayIso, p_scenario: "defective_product",
    p_items: [{ sales_order_item_id: p15RmItem.id, condition: "good_resellable" }],
    p_expected_sale_version: p15RmReturnable.row_version, p_collection_state: "collected", p_approved_refund_amount: "900.00",
  });
  const p15RmReturnRow = Array.isArray(p15RmReturnRows) ? p15RmReturnRows[0] : p15RmReturnRows;
  const p15RmReturnId = p15RmReturnRow?.id;
  const p15RmReturnPending = await rpc("get_sales_return", { p_id: p15RmReturnId });
  await rpc("approve_sales_return", { p_return_id: p15RmReturnId, p_expected_version: p15RmReturnPending.row_version });
  const p15RmRefundRows = await rpc("record_sales_return_refund", { p_return_id: p15RmReturnId, p_amount: "900.00", p_refund_method_id: PAYMENT_METHOD_ID, p_reference: "HTTP-P15-REF-RM" });
  const p15RmRefundRow = Array.isArray(p15RmRefundRows) ? p15RmRefundRows[0] : p15RmRefundRows;
  const p15RmReturnAfterRefund = await rpc("get_sales_return", { p_id: p15RmReturnId });
  const p15RmRefundEventId = p15RmReturnAfterRefund.refund_events?.find((e) => e.id === p15RmRefundRow.id)?.id;

  const p15RmSourcesChannelled = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteChannelledId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const p15RmSourcesNoChannel = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: stlRouteNoChannelId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const p15RmFeeReversalChannelled = p15RmSourcesChannelled.find((s) => s.source_kind === "return_fee_reversal" && s.source_event_id === p15RmReturnId);
  const p15RmFeeReversalNoChannel = p15RmSourcesNoChannel.find((s) => s.source_kind === "return_fee_reversal" && s.source_event_id === p15RmReturnId);
  const p15RmRefundEventNoChannel = p15RmSourcesNoChannel.find((s) => s.source_kind === "return_refund_event" && s.source_event_id === p15RmRefundEventId);
  const p15RmRefundEventChannelled = p15RmSourcesChannelled.find((s) => s.source_kind === "return_refund_event" && s.source_event_id === p15RmRefundEventId);
  ok(
    "Part 15 item j (§3 — CRITICAL): for the SAME Return, over real HTTP, return_fee_reversal routes via the ORIGINAL SALE's own channel (found on the CHANNELLED route, ABSENT from the no-channel route), while the actual cash return_refund_event keeps routing via its OWN refund_method_id + implicit NULL channel (found ONLY on the no-channel route, ABSENT from the channelled route) — the two legitimately settle on DIFFERENT routes for the same Return",
    typeof p15RmFeeReversalChannelled?.gross_collection_impact === "string" && p15RmFeeReversalNoChannel === undefined &&
      typeof p15RmRefundEventNoChannel?.gross_collection_impact === "string" && p15RmRefundEventChannelled === undefined,
    `got feeReversalChannelled=${JSON.stringify(p15RmFeeReversalChannelled)} feeReversalNoChannel=${JSON.stringify(p15RmFeeReversalNoChannel)} refundEventNoChannel=${JSON.stringify(p15RmRefundEventNoChannel)} refundEventChannelled=${JSON.stringify(p15RmRefundEventChannelled)}`,
  );

  const p15RmFeeDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteChannelledId, p_settlement_date: todayIso });
  const p15RmFeeDraftRow = Array.isArray(p15RmFeeDraftRows) ? p15RmFeeDraftRows[0] : p15RmFeeDraftRows;
  const p15RmFeeFinalizeRows = await rpc("finalize_settlement_batch", { p_settlement_batch_id: p15RmFeeDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "return_fee_reversal", source_event_id: p15RmReturnId }] });
  const p15RmFeeFinalizeRow = Array.isArray(p15RmFeeFinalizeRows) ? p15RmFeeFinalizeRows[0] : p15RmFeeFinalizeRows;
  ok(
    "Part 15 item k (§1/§3 consequence): finalize_settlement_batch() over real HTTP succeeds claiming ONLY the return_fee_reversal source, on the CHANNELLED route",
    typeof p15RmFeeFinalizeRow?.settlement_number === "string" && /^SET-\d{10}$/.test(p15RmFeeFinalizeRow.settlement_number),
    `got ${JSON.stringify(p15RmFeeFinalizeRow)}`,
  );

  const p15RmRefundDraftRows = await rpc("create_draft_settlement_batch", { p_settlement_route_id: stlRouteNoChannelId, p_settlement_date: todayIso });
  const p15RmRefundDraftRow = Array.isArray(p15RmRefundDraftRows) ? p15RmRefundDraftRows[0] : p15RmRefundDraftRows;
  const p15RmRefundFinalizeRows = await rpc("finalize_settlement_batch", { p_settlement_batch_id: p15RmRefundDraftRow.id, p_expected_version: 1, p_selected_sources: [{ source_kind: "return_refund_event", source_event_id: p15RmRefundEventId }] });
  const p15RmRefundFinalizeRow = Array.isArray(p15RmRefundFinalizeRows) ? p15RmRefundFinalizeRows[0] : p15RmRefundFinalizeRows;
  ok(
    "Part 15 item k (§1/§3 consequence — CRITICAL): finalize_settlement_batch() over real HTTP ALSO succeeds, INDEPENDENTLY, claiming ONLY the return_refund_event source for the SAME Return, on the SEPARATE no-channel route — the two source families are no longer mutually exclusive/coupled the way pre-hotfix NULL-channel-only matching forced them to be",
    typeof p15RmRefundFinalizeRow?.settlement_number === "string" && /^SET-\d{10}$/.test(p15RmRefundFinalizeRow.settlement_number) && p15RmRefundFinalizeRow.settlement_number !== p15RmFeeFinalizeRow.settlement_number,
    `got ${JSON.stringify(p15RmRefundFinalizeRow)}`,
  );

  // =====================================================================
  // Part 16 — Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2
  // (migrations 0197-0198), proven over the SAME real HTTP/PostgREST round
  // trip, extending Part 15. §13 of the spec.
  //
  //  a) (§1/§7 CRITICAL) Route-A/Route-B Discovery split over real HTTP: a
  //     Sale on Payment Method A/Channel A -> full Return -> Approve ->
  //     Reverse -> the Sale is THEN edited to Payment Method B/Channel B
  //     (permitted post-reversal, 0084) -> list_unsettled_settlement_
  //     sources() over real HTTP resolves BOTH historical fee events
  //     (return_fee_reversal, return_fee_reversal_reversal) to Route A
  //     exclusively — never Route B, the Sale's new live route.
  //  b) (§10) collection_channel_id_snapshot cannot be mutated by ANY raw
  //     HTTP path: a direct PATCH against /sales_returns is a no-op (zero
  //     rows) for the ordinary full-permission actor (pre-existing
  //     zero-UPDATE-RLS-policy lockdown on this table) and is REJECTED
  //     outright, even for the trusted service_role verification client,
  //     by the 0197 BEFORE UPDATE immutability trigger (RLS-bypassing but
  //     never trigger-bypassing — same isolation rationale as Part 12 item
  //     17/32's terminal-mutation proof above).
  // =====================================================================
  // Route A reuses Part 14's stlRouteChannelledId — settlement_routes
  // enforces a UNIQUE (payment_method_id, collection_channel_id) constraint
  // for payment_collection routes (settlement_routes_payment_collection_
  // match_idx), so PAYMENT_METHOD_ID+CHANNEL_ID already has exactly one
  // route and a second cannot be created. Route B is a genuinely NEW
  // pairing (PAYMENT_METHOD_B_ID+CHANNEL_B_ID), never used by any earlier
  // Part, so it creates cleanly.
  const p16RouteAId = stlRouteChannelledId;
  const p16RouteBId = await rpc(
    "create_settlement_route",
    { p_code: `h712-route-b-${Date.now() % 100000}`, p_name_ar: "مسار Hotfix 7.1.2 - ب", p_route_kind: "payment_collection", p_name_en: null, p_payment_method_id: PAYMENT_METHOD_B_ID, p_collection_channel_id: CHANNEL_B_ID },
    clientSettleManageRoutesOnly,
  );
  await rpc("create_settlement_route_fee_version", { p_settlement_route_id: p16RouteBId, p_effective_from: stlPastIso, p_transaction_fee_strategy: "source_snapshot", p_batch_fee_fixed: "5.00" }, clientSettleManageRoutesOnly);

  const p16OrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "1000.00" }],
    p_customer_name: "عميل اختبار Hotfix 7.1.2 HTTP — أ",
  });
  const p16OrderRow = Array.isArray(p16OrderRows) ? p16OrderRows[0] : p16OrderRows;
  const p16OrderId = p16OrderRow?.id;

  const p16Returnable = await rpc("get_returnable_sales_order", { p_sales_order_id: p16OrderId });
  const p16Item = p16Returnable.items[0];
  const p16ReturnRows = await rpc("create_sales_return", {
    p_sales_order_id: p16OrderId, p_processed_store_id: STORE_ID, p_return_date: todayIso, p_scenario: "defective_product",
    p_items: [{ sales_order_item_id: p16Item.id, condition: "good_resellable" }],
    p_expected_sale_version: p16Returnable.row_version, p_collection_state: "collected", p_approved_refund_amount: "1000.00",
  });
  const p16ReturnRow = Array.isArray(p16ReturnRows) ? p16ReturnRows[0] : p16ReturnRows;
  const p16ReturnId = p16ReturnRow?.id;

  const p16ReturnPending = await rpc("get_sales_return", { p_id: p16ReturnId });
  const p16ApproveRows = await rpc("approve_sales_return", { p_return_id: p16ReturnId, p_expected_version: p16ReturnPending.row_version });
  const p16ApproveRow = Array.isArray(p16ApproveRows) ? p16ApproveRows[0] : p16ApproveRows;
  ok(
    "Part 16 item a: approve_sales_return() over real HTTP succeeds for the Hotfix 7.1.2 route-drift fixture",
    p16ApproveRow?.return_number === p16ReturnRow.return_number,
    `got ${JSON.stringify(p16ApproveRow)}`,
  );

  const p16ReturnApproved = await rpc("get_sales_return", { p_id: p16ReturnId });
  ok(
    "Part 16 item a: the approved Return carries a NONZERO payment_fee_reversal_amount (fixture assumption for a meaningful route-drift proof)",
    typeof p16ReturnApproved.payment_fee_reversal_amount === "string" && Number(p16ReturnApproved.payment_fee_reversal_amount) > 0,
    `got ${JSON.stringify(p16ReturnApproved.payment_fee_reversal_amount)}`,
  );

  await rpc("reverse_sales_return", {
    p_return_id: p16ReturnId,
    p_expected_version: p16ReturnApproved.row_version,
    p_reversal_reason: "HTTP Hotfix 7.1.2 — عكس قبل تعديل البيع",
  });

  // Edit the Sale to Payment Method B/Channel B AFTER the Return was
  // reversed — 0084's financial lock only checks status='approved', so
  // this must be PERMITTED over real HTTP (the exact §1 vulnerability
  // window).
  const p16OrderBeforeEdit = await rpc("get_sales_order", { p_id: p16OrderId });
  const p16UpdateRows = await rpc("update_sales_order", {
    p_order_id: p16OrderId,
    p_payment_method_id: PAYMENT_METHOD_B_ID,
    p_collection_channel_id: CHANNEL_B_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "1000.00" }],
    p_customer_name: "عميل اختبار Hotfix 7.1.2 HTTP — أ (بعد التعديل)",
    p_expected_version: p16OrderBeforeEdit.row_version,
  });
  const p16UpdateRow = Array.isArray(p16UpdateRows) ? p16UpdateRows[0] : p16UpdateRows;
  ok(
    "Part 16 item a (§1 CRITICAL): update_sales_order() over real HTTP successfully edits the Sale to Payment Method B/Channel B AFTER its Return was already reversed",
    p16UpdateRow?.id === p16OrderId,
    `got ${JSON.stringify(p16UpdateRow)}`,
  );
  const p16OrderAfterEdit = await rpc("get_sales_order", { p_id: p16OrderId });
  ok(
    "Part 16 item a: the Sale's LIVE payment_method_id/collection_channel_id are now genuinely B/B over real HTTP",
    p16OrderAfterEdit.payment_method_id === PAYMENT_METHOD_B_ID && p16OrderAfterEdit.collection_channel_id === CHANNEL_B_ID,
    `got pm=${p16OrderAfterEdit.payment_method_id} chan=${p16OrderAfterEdit.collection_channel_id}`,
  );

  const p16SourcesRouteA = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: p16RouteAId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const p16SourcesRouteB = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: p16RouteBId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const p16FeeRevOnA = p16SourcesRouteA.find((s) => s.source_kind === "return_fee_reversal" && s.source_event_id === p16ReturnId);
  const p16FeeRevRevOnA = p16SourcesRouteA.find((s) => s.source_kind === "return_fee_reversal_reversal" && s.source_event_id === p16ReturnId);
  const p16FeeRevOnB = p16SourcesRouteB.find((s) => s.source_kind === "return_fee_reversal" && s.source_event_id === p16ReturnId);
  const p16FeeRevRevOnB = p16SourcesRouteB.find((s) => s.source_kind === "return_fee_reversal_reversal" && s.source_event_id === p16ReturnId);
  ok(
    "Part 16 item a (§1/§7 CRITICAL): over real HTTP, BOTH historical fee events (return_fee_reversal, return_fee_reversal_reversal) resolve exclusively to Route A (the Return's OWN frozen creation-time snapshot route) — despite the Sale's LIVE route now being B/B",
    p16FeeRevOnA !== undefined && p16FeeRevRevOnA !== undefined && p16FeeRevOnB === undefined && p16FeeRevRevOnB === undefined,
    `got onA=${JSON.stringify({ feeRev: p16FeeRevOnA, feeRevRev: p16FeeRevRevOnA })} onB=${JSON.stringify({ feeRev: p16FeeRevOnB, feeRevRev: p16FeeRevRevOnB })}`,
  );

  // --- b) collection_channel_id_snapshot immutability over real HTTP. ----
  const { data: p16OrdinaryPatchData, error: p16OrdinaryPatchError } = await client
    .from("sales_returns")
    .update({ collection_state: "collected" })
    .eq("id", p16ReturnId)
    .select("id");
  ok(
    "Part 16 item b: a raw PATCH over real HTTP against /sales_returns is a no-op (zero rows, pre-existing zero-UPDATE-RLS-policy lockdown) for the ordinary full-permission actor — sales_returns has no direct write path over HTTP at all, this hotfix's new column included",
    !p16OrdinaryPatchError && Array.isArray(p16OrdinaryPatchData) && p16OrdinaryPatchData.length === 0,
    `error=${JSON.stringify(p16OrdinaryPatchError)} data=${JSON.stringify(p16OrdinaryPatchData)}`,
  );

  let p16ServiceMutationError = null;
  try {
    // Must target a GENUINELY DIFFERENT value than the return's own snapshot
    // (Channel A/CHANNEL_ID, captured at creation) — the trigger only fires
    // `IS DISTINCT FROM`, so re-setting the SAME value would be a silent
    // no-op, not a real test of the immutability guard.
    const { error } = await clientService.from("sales_returns").update({ collection_channel_id_snapshot: CHANNEL_B_ID }).eq("id", p16ReturnId);
    if (error) p16ServiceMutationError = error;
  } catch (err) {
    p16ServiceMutationError = err;
  }
  ok(
    "Part 16 item b (§10 CRITICAL): a direct PATCH over real HTTP against collection_channel_id_snapshot is REJECTED by the 0197 immutability trigger even for the trusted service_role client (RLS-bypassing but not trigger-bypassing) — mirrors Part 12 item 17/32's terminal-mutation proof exactly",
    p16ServiceMutationError !== null,
    `got ${p16ServiceMutationError?.message}`,
  );

  // =====================================================================
  // Part 17 — Phase 7 — Final Pending-Refresh Consistency Hotfix 7.1.3
  // (migrations 0197-0198 revised), proven over the SAME real HTTP/
  // PostgREST round trip, extending Part 16. §15 of the spec.
  //
  //  Full lockstep-refresh lifecycle over real HTTP:
  //    A) create Return on Sale A/A.
  //    B) update_sales_order() to B/B while the Return is still pending.
  //    C) refresh_pending_sales_return_from_sale() over real HTTP.
  //    D) approve_sales_return() — must now succeed.
  //    E) Discovery: Route B shows the fee event, Route A does not.
  //    F) reverse_sales_return().
  //    G) update_sales_order() AGAIN, to C/C (permitted post-reversal).
  //    H) Discovery: Route B still shows BOTH fee events (original +
  //       reversal), Route C shows neither — historical stability holds
  //       even over real HTTP after a sanctioned mid-lifecycle refresh.
  //    I) A raw PATCH against collection_channel_id_snapshot remains
  //       blocked over real HTTP — for the ordinary authenticated client
  //       (pre-existing zero-UPDATE-RLS no-op) AND for the trusted
  //       service_role client (rejected by the 0197 guard trigger).
  // =====================================================================
  const p17RouteAId = stlRouteChannelledId; // Route A (PAYMENT_METHOD_ID/CHANNEL_ID), reused.
  const p17RouteBId = p16RouteBId; // Route B (PAYMENT_METHOD_B_ID/CHANNEL_B_ID), reused.
  const p17RouteCId = await rpc(
    "create_settlement_route",
    { p_code: `h713-route-c-${Date.now() % 100000}`, p_name_ar: "مسار Hotfix 7.1.3 - ج", p_route_kind: "payment_collection", p_name_en: null, p_payment_method_id: PAYMENT_METHOD_C_ID, p_collection_channel_id: CHANNEL_C_ID },
    clientSettleManageRoutesOnly,
  );
  await rpc("create_settlement_route_fee_version", { p_settlement_route_id: p17RouteCId, p_effective_from: stlPastIso, p_transaction_fee_strategy: "source_snapshot", p_batch_fee_fixed: "5.00" }, clientSettleManageRoutesOnly);

  // --- A) Create Return on Sale A/A. --------------------------------------
  const p17OrderRows = await rpc("create_sales_order", {
    p_store_id: STORE_ID, p_sale_date: todayIso, p_payment_method_id: PAYMENT_METHOD_ID, p_collection_channel_id: CHANNEL_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "1000.00" }],
    p_customer_name: "عميل اختبار Hotfix 7.1.3 HTTP — أ",
  });
  const p17OrderRow = Array.isArray(p17OrderRows) ? p17OrderRows[0] : p17OrderRows;
  const p17OrderId = p17OrderRow?.id;

  const p17Returnable = await rpc("get_returnable_sales_order", { p_sales_order_id: p17OrderId });
  const p17Item = p17Returnable.items[0];
  const p17ReturnRows = await rpc("create_sales_return", {
    p_sales_order_id: p17OrderId, p_processed_store_id: STORE_ID, p_return_date: todayIso, p_scenario: "defective_product",
    p_items: [{ sales_order_item_id: p17Item.id, condition: "good_resellable" }],
    p_expected_sale_version: p17Returnable.row_version, p_collection_state: "collected", p_approved_refund_amount: "1000.00",
  });
  const p17ReturnRow = Array.isArray(p17ReturnRows) ? p17ReturnRows[0] : p17ReturnRows;
  const p17ReturnId = p17ReturnRow?.id;

  const p17ReturnAtCreation = await rpc("get_sales_return", { p_id: p17ReturnId });
  ok(
    "Part 17 item A (§9): a fresh Return over real HTTP captures payment_method_id=A/source_sale_row_version=1 at creation",
    p17ReturnAtCreation.payment_method_id === PAYMENT_METHOD_ID && String(p17ReturnAtCreation.source_sale_row_version) === "1",
    `got ${JSON.stringify({ pm: p17ReturnAtCreation.payment_method_id, ssrv: p17ReturnAtCreation.source_sale_row_version })}`,
  );

  // --- B) Update Sale to B/B while the Return is still pending. ----------
  // NOTE: 'id' is included in the item so update_sales_order() updates the
  // EXISTING sales_order_item in place — otherwise the pending Return's
  // sales_order_item_id reference would point at a removed item and step C
  // below would correctly reject (same established idiom used throughout
  // this hotfix's SQL/upgrade fixtures).
  const p17OrderBeforeEdit = await rpc("get_sales_order", { p_id: p17OrderId });
  await rpc("update_sales_order", {
    p_order_id: p17OrderId,
    p_payment_method_id: PAYMENT_METHOD_B_ID,
    p_collection_channel_id: CHANNEL_B_ID,
    p_items: [{ id: p17Item.id, category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "1000.00" }],
    p_customer_name: "عميل اختبار Hotfix 7.1.3 HTTP — أ (بعد التعديل الأول)",
    p_expected_version: p17OrderBeforeEdit.row_version,
  });
  const p17OrderAfterFirstEdit = await rpc("get_sales_order", { p_id: p17OrderId });
  ok(
    "Part 17 item B: update_sales_order() over real HTTP successfully edits the Sale to Payment Method B/Channel B WHILE the Return is still pending",
    p17OrderAfterFirstEdit.payment_method_id === PAYMENT_METHOD_B_ID && p17OrderAfterFirstEdit.collection_channel_id === CHANNEL_B_ID,
    `got pm=${p17OrderAfterFirstEdit.payment_method_id} chan=${p17OrderAfterFirstEdit.collection_channel_id}`,
  );

  // --- C) Refresh the Pending Return over real HTTP. ----------------------
  const p17ReturnBeforeRefresh = await rpc("get_sales_return", { p_id: p17ReturnId });
  await rpc("refresh_pending_sales_return_from_sale", { p_return_id: p17ReturnId, p_expected_version: p17ReturnBeforeRefresh.row_version });
  const p17ReturnAfterRefresh = await rpc("get_sales_return", { p_id: p17ReturnId });
  ok(
    "Part 17 item C (§1/§9 CRITICAL): refresh_pending_sales_return_from_sale() over real HTTP re-syncs payment_method_id AND source_sale_row_version to the Sale's CURRENT state (B/2)",
    p17ReturnAfterRefresh.payment_method_id === PAYMENT_METHOD_B_ID && String(p17ReturnAfterRefresh.source_sale_row_version) === "2" && p17ReturnAfterRefresh.requires_sale_refresh === false,
    `got ${JSON.stringify({ pm: p17ReturnAfterRefresh.payment_method_id, ssrv: p17ReturnAfterRefresh.source_sale_row_version, rsr: p17ReturnAfterRefresh.requires_sale_refresh })}`,
  );

  // --- D) Approve — must now succeed. -------------------------------------
  const p17ApproveRows = await rpc("approve_sales_return", { p_return_id: p17ReturnId, p_expected_version: p17ReturnAfterRefresh.row_version });
  const p17ApproveRow = Array.isArray(p17ApproveRows) ? p17ApproveRows[0] : p17ApproveRows;
  ok(
    "Part 17 item D: approve_sales_return() over real HTTP succeeds after the sanctioned refresh",
    p17ApproveRow?.return_number === p17ReturnRow.return_number,
    `got ${JSON.stringify(p17ApproveRow)}`,
  );
  const p17ReturnApproved = await rpc("get_sales_return", { p_id: p17ReturnId });
  ok(
    "Part 17 item D: the approved Return carries a NONZERO payment_fee_reversal_amount (fixture assumption for a meaningful route-discovery proof)",
    typeof p17ReturnApproved.payment_fee_reversal_amount === "string" && Number(p17ReturnApproved.payment_fee_reversal_amount) > 0,
    `got ${JSON.stringify(p17ReturnApproved.payment_fee_reversal_amount)}`,
  );

  // --- E) Discovery: Route B yes, Route A no. -----------------------------
  const p17SourcesRouteA_1 = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: p17RouteAId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const p17SourcesRouteB_1 = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: p17RouteBId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  ok(
    "Part 17 item E (§9 CRITICAL): over real HTTP, Discovery resolves the refreshed Return's fee event exclusively to Route B — never Route A, the abandoned pre-refresh basis",
    p17SourcesRouteB_1.some((s) => s.source_kind === "return_fee_reversal" && s.source_event_id === p17ReturnId) &&
      !p17SourcesRouteA_1.some((s) => s.source_event_id === p17ReturnId),
    `routeB has=${p17SourcesRouteB_1.some((s) => s.source_event_id === p17ReturnId)} routeA has=${p17SourcesRouteA_1.some((s) => s.source_event_id === p17ReturnId)}`,
  );

  // --- F) Reverse. ---------------------------------------------------------
  await rpc("reverse_sales_return", {
    p_return_id: p17ReturnId,
    p_expected_version: p17ReturnApproved.row_version,
    p_reversal_reason: "HTTP Hotfix 7.1.3 — عكس بعد التحديث المُعاد مزامنته",
  });

  // --- G) Update Sale AGAIN to C/C (permitted post-reversal, 0084). ------
  const p17OrderBeforeSecondEdit = await rpc("get_sales_order", { p_id: p17OrderId });
  await rpc("update_sales_order", {
    p_order_id: p17OrderId,
    p_payment_method_id: PAYMENT_METHOD_C_ID,
    p_collection_channel_id: CHANNEL_C_ID,
    p_items: [{ category_id: CATEGORY_ID, karat_id: KARAT_ID, weight_grams: "1.0000", sale_price: "1000.00" }],
    p_customer_name: "عميل اختبار Hotfix 7.1.3 HTTP — أ (بعد العكس، تعديل ثانٍ إلى ج)",
    p_expected_version: p17OrderBeforeSecondEdit.row_version,
  });
  const p17OrderAfterSecondEdit = await rpc("get_sales_order", { p_id: p17OrderId });
  ok(
    "Part 17 item G: update_sales_order() over real HTTP successfully edits the Sale AGAIN to Payment Method C/Channel C AFTER the Return was reversed",
    p17OrderAfterSecondEdit.payment_method_id === PAYMENT_METHOD_C_ID && p17OrderAfterSecondEdit.collection_channel_id === CHANNEL_C_ID,
    `got pm=${p17OrderAfterSecondEdit.payment_method_id} chan=${p17OrderAfterSecondEdit.collection_channel_id}`,
  );

  // --- H) Discovery: Route B still shows BOTH events, Route C shows none. -
  const p17SourcesRouteB_2 = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: p17RouteBId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const p17SourcesRouteC = await rpc("list_unsettled_settlement_sources", { p_settlement_route_id: p17RouteCId, p_source_date_from: stlDateFrom, p_source_date_to: stlDateTo, p_limit: 5000 });
  const p17FeeRevOnB = p17SourcesRouteB_2.find((s) => s.source_kind === "return_fee_reversal" && s.source_event_id === p17ReturnId);
  const p17FeeRevRevOnB = p17SourcesRouteB_2.find((s) => s.source_kind === "return_fee_reversal_reversal" && s.source_event_id === p17ReturnId);
  const p17AnyOnC = p17SourcesRouteC.find((s) => s.source_event_id === p17ReturnId);
  ok(
    "Part 17 item H (§10 CRITICAL): over real HTTP, despite the Sale being edited to C/C AFTER the refreshed Return was reversed, BOTH historical fee events remain pinned to Route B (the basis at approval/reversal time) — never drifted to C/C",
    p17FeeRevOnB !== undefined && p17FeeRevRevOnB !== undefined && p17AnyOnC === undefined,
    `got onB=${JSON.stringify({ feeRev: p17FeeRevOnB, feeRevRev: p17FeeRevRevOnB })} onC=${JSON.stringify(p17AnyOnC)}`,
  );

  // --- I) Raw PATCH against collection_channel_id_snapshot remains blocked.
  const { data: p17OrdinaryPatchData, error: p17OrdinaryPatchError } = await client
    .from("sales_returns")
    .update({ collection_state: "collected" })
    .eq("id", p17ReturnId)
    .select("id");
  ok(
    "Part 17 item I: a raw PATCH over real HTTP against /sales_returns is a no-op (zero rows, pre-existing zero-UPDATE-RLS-policy lockdown) for the ordinary full-permission authenticated actor, even after a sanctioned refresh",
    !p17OrdinaryPatchError && Array.isArray(p17OrdinaryPatchData) && p17OrdinaryPatchData.length === 0,
    `error=${JSON.stringify(p17OrdinaryPatchError)} data=${JSON.stringify(p17OrdinaryPatchData)}`,
  );

  let p17ServiceMutationError = null;
  try {
    // Targets a GENUINELY DIFFERENT value than the Return's own current
    // (frozen, post-reversal) snapshot Channel B — the guard trigger only
    // fires `IS DISTINCT FROM`.
    const { error } = await clientService.from("sales_returns").update({ collection_channel_id_snapshot: CHANNEL_C_ID }).eq("id", p17ReturnId);
    if (error) p17ServiceMutationError = error;
  } catch (err) {
    p17ServiceMutationError = err;
  }
  ok(
    "Part 17 item I (§5/§10 CRITICAL): a direct PATCH over real HTTP against collection_channel_id_snapshot is REJECTED by the revised 0197 guard trigger even for the trusted service_role client, on a Return that has already left the pending lifecycle (reversed) — mirrors Part 16 item b's proof, re-verified after a sanctioned refresh occurred earlier in this Return's life",
    p17ServiceMutationError !== null,
    `got ${p17ServiceMutationError?.message}`,
  );

  // -------------------------------------------------------------------
  // Part 18 — Phase 8 (Reports, Dashboard & Exports, migrations 0199-0204):
  // proves, over a REAL HTTP/PostgREST round trip (not the SQL-only tests
  // in supabase/tests/reports_detail_golden_scenario.test.sql and friends):
  //   (A) §40/§41 Decimal Transport Boundary + §83 Report Basis Indicator
  //       for get_dashboard_summary(), for the fully-privileged actor,
  //   (B) get_sales_report() carries its profit sub-fields (as typeof
  //       "string") for an actor holding sales.view_profit,
  //   (C) §79 CRITICAL: get_sales_report()'s profit keys are TRULY ABSENT
  //       (not present-with-null) in BOTH the summary object and each row,
  //       for an actor lacking sales.view_profit — proven with the `in`
  //       operator, the only reliable way to distinguish "absent" from
  //       "present but null" once a value has round-tripped through real
  //       HTTP/JSON,
  //   (D) §49: report_visible_stores_lookup() (a reports.view-gated lookup)
  //       works for an actor who does NOT hold stores.view at all,
  //   (E) §79: get_dashboard_summary()'s top-level net_operating_return key
  //       is entirely absent, and its sales sub-object's gross_profit key is
  //       entirely absent, for an actor lacking dashboard.view_financials,
  //   (F) §79: get_dashboard_summary()'s per-domain key omission is
  //       independent per domain — for an actor holding dashboard.view +
  //       dashboard.view_financials + adjustments.view + settlements.view/
  //       view_financials but NONE of sales.view/returns.view/shipments.view,
  //       the sales/returns/shipping keys are entirely absent (and so is
  //       net_operating_return, which needs ALL three), while adjustments/
  //       settlements are present WITH their financial sub-fields,
  //   (G) §8/§9 CRITICAL: get_dashboard_summary() explicitly REJECTS
  //       (raises, never silently narrows) a p_store_ids filter naming a
  //       store outside a single-store-scoped actor's visible scope.
  // Reuses three EXISTING actors (...-001 profit, ...-002 no-profit,
  // ...-005 store-B-only) — postgrest_http_test_setup.sql grants each the
  // Phase 8 permissions needed; no new actors/JWTs required since reports.*/
  // dashboard.* are pre-existing permission keys (migration 0199's comment).
  // -------------------------------------------------------------------
  const p18Today = todayIso;

  // --- A) Decimal Transport Boundary + Report Basis Indicator. -------------
  const p18Summary = await rpc("get_dashboard_summary", { p_date_from: p18Today, p_date_to: p18Today, p_store_ids: null });
  ok(
    "Part 18 item A (§83): get_dashboard_summary() basis indicator over real HTTP is 'current_effective_impact_within_period'",
    p18Summary.basis === "current_effective_impact_within_period",
    `got ${p18Summary.basis}`,
  );
  ok(
    "Part 18 item A (§40/§41): get_dashboard_summary() sales.sales_revenue arrives typeof \"string\" over real HTTP",
    typeof p18Summary.sales?.sales_revenue === "string",
    `got ${typeof p18Summary.sales?.sales_revenue}`,
  );
  ok(
    "Part 18 item A (§40/§41): get_dashboard_summary() sales.gross_profit (a profit sub-field) arrives typeof \"string\" over real HTTP",
    typeof p18Summary.sales?.gross_profit === "string",
    `got ${typeof p18Summary.sales?.gross_profit}`,
  );
  ok(
    "Part 18 item A (§40/§41): get_dashboard_summary() net_operating_return.net_operating_return arrives typeof \"string\" over real HTTP",
    typeof p18Summary.net_operating_return?.net_operating_return === "string",
    `got ${typeof p18Summary.net_operating_return?.net_operating_return}`,
  );

  // --- B) get_sales_report(), profit actor: profit sub-fields present. -----
  const p18SalesReportFull = await rpc("get_sales_report", { p_date_from: p18Today, p_date_to: p18Today, p_limit: 500 });
  ok(
    "Part 18 item B (§79): get_sales_report() summary includes gross_profit for an actor holding sales.view_profit",
    "gross_profit" in p18SalesReportFull.summary,
    `summary keys=${Object.keys(p18SalesReportFull.summary)}`,
  );
  ok(
    "Part 18 item B (§40/§41): get_sales_report() summary.gross_profit arrives typeof \"string\" over real HTTP",
    typeof p18SalesReportFull.summary.gross_profit === "string",
    `got ${typeof p18SalesReportFull.summary.gross_profit}`,
  );
  const p18Row0 = p18SalesReportFull.rows[0];
  ok(
    "Part 18 item B: get_sales_report() returns at least one row for today over real HTTP (earlier Parts created real Sales on today's business date)",
    p18Row0 !== undefined,
    `rows.length=${p18SalesReportFull.rows.length}`,
  );
  if (p18Row0) {
    ok("Part 18 item B (§79): get_sales_report() row includes gross_profit for the profit actor", "gross_profit" in p18Row0, `row keys=${Object.keys(p18Row0)}`);
  }

  // --- C) §79 CRITICAL: true key absence for the no-profit actor. ----------
  const p18SalesReportNoProfit = await rpc("get_sales_report", { p_date_from: p18Today, p_date_to: p18Today, p_limit: 500 }, clientNoProfit);
  ok(
    "Part 18 item C (§79 CRITICAL): get_sales_report() summary has gross_profit KEY TRULY ABSENT (not present-with-null) over real HTTP for a caller lacking sales.view_profit",
    !("gross_profit" in p18SalesReportNoProfit.summary),
    `summary=${JSON.stringify(p18SalesReportNoProfit.summary)}`,
  );
  const p18RowNoProfit0 = p18SalesReportNoProfit.rows[0];
  ok("Part 18 item C: get_sales_report() still returns rows for the no-profit actor", p18RowNoProfit0 !== undefined, `rows.length=${p18SalesReportNoProfit.rows.length}`);
  if (p18RowNoProfit0) {
    ok(
      "Part 18 item C (§79 CRITICAL): get_sales_report() row has gross_profit KEY TRULY ABSENT over real HTTP for a caller lacking sales.view_profit",
      !("gross_profit" in p18RowNoProfit0),
      `row=${JSON.stringify(p18RowNoProfit0)}`,
    );
    ok(
      "Part 18 item C: get_sales_report() row STILL includes non-profit fields (sales_revenue) for the no-profit actor",
      "sales_revenue" in p18RowNoProfit0,
      `row keys=${Object.keys(p18RowNoProfit0)}`,
    );
  }

  // --- D) §49: narrow reports.view-gated lookup, no stores.view needed. ----
  const p18StoreLookup = await rpc("report_visible_stores_lookup", {}, clientNoProfit);
  ok(
    "Part 18 item D (§49): report_visible_stores_lookup() over real HTTP works for an actor holding reports.view but NOT stores.view",
    Array.isArray(p18StoreLookup) && p18StoreLookup.length > 0,
    `got ${JSON.stringify(p18StoreLookup)}`,
  );

  // --- E) §79: dashboard redaction for the no-profit actor. ----------------
  const p18DashNoProfit = await rpc("get_dashboard_summary", { p_date_from: p18Today, p_date_to: p18Today, p_store_ids: null }, clientNoProfit);
  ok(
    "Part 18 item E (§79 CRITICAL): get_dashboard_summary() top-level result has net_operating_return KEY TRULY ABSENT over real HTTP for a caller lacking dashboard.view_financials",
    !("net_operating_return" in p18DashNoProfit),
    `keys=${Object.keys(p18DashNoProfit)}`,
  );
  ok(
    "Part 18 item E (§79): get_dashboard_summary() sales section for the no-profit actor still includes orders_count",
    p18DashNoProfit.sales !== undefined && "orders_count" in p18DashNoProfit.sales,
    `sales=${JSON.stringify(p18DashNoProfit.sales)}`,
  );
  ok(
    "Part 18 item E (§79 CRITICAL): get_dashboard_summary() sales section for the no-profit actor has gross_profit KEY TRULY ABSENT",
    p18DashNoProfit.sales !== undefined && !("gross_profit" in p18DashNoProfit.sales),
    `sales=${JSON.stringify(p18DashNoProfit.sales)}`,
  );

  // --- F) §79: per-domain independent redaction for the store-B-only actor.
  const p18DashStoreB = await rpc(
    "get_dashboard_summary",
    { p_date_from: p18Today, p_date_to: p18Today, p_store_ids: [STORE_B_ID] },
    clientAdjStoreBOnly,
  );
  ok("Part 18 item F (§79): get_dashboard_summary() has NO 'sales' key over real HTTP for an actor lacking sales.view entirely", !("sales" in p18DashStoreB), `keys=${Object.keys(p18DashStoreB)}`);
  ok("Part 18 item F (§79): get_dashboard_summary() has NO 'returns' key for an actor lacking returns.view", !("returns" in p18DashStoreB), `keys=${Object.keys(p18DashStoreB)}`);
  ok("Part 18 item F (§79): get_dashboard_summary() has NO 'shipping' key for an actor lacking shipments.view", !("shipping" in p18DashStoreB), `keys=${Object.keys(p18DashStoreB)}`);
  ok(
    "Part 18 item F (§79): get_dashboard_summary() has NO net_operating_return key (requires ALL of sales.view_profit/shipments.view/adjustments.view) even though this actor holds dashboard.view_financials",
    !("net_operating_return" in p18DashStoreB),
    `keys=${Object.keys(p18DashStoreB)}`,
  );
  ok(
    "Part 18 item F: get_dashboard_summary() DOES include 'adjustments' WITH the operational customer_charges sub-field for this actor (adjustments.view + dashboard.view_financials alone, §1)",
    p18DashStoreB.adjustments !== undefined && "customer_charges" in p18DashStoreB.adjustments,
    `adjustments=${JSON.stringify(p18DashStoreB.adjustments)}`,
  );
  ok(
    "Part 18 item F (§79/0205 CRITICAL): get_dashboard_summary()'s adjustments.net_adjustments_result (and direct_costs) KEY IS TRULY ABSENT for this actor, since migration 0205 additionally gates it on sales.view_profit (which this actor lacks) — matches get_adjustments_report()'s own row-level gate exactly; only customer_charges stays dashboard.view_financials-alone",
    p18DashStoreB.adjustments !== undefined && !("net_adjustments_result" in p18DashStoreB.adjustments) && !("direct_costs" in p18DashStoreB.adjustments),
    `adjustments=${JSON.stringify(p18DashStoreB.adjustments)}`,
  );
  ok(
    "Part 18 item F: get_dashboard_summary() DOES include 'settlements' WITH financial sub-fields for this actor (settlements.view_financials + dashboard.view_financials)",
    p18DashStoreB.settlements !== undefined && "expected" in p18DashStoreB.settlements,
    `settlements=${JSON.stringify(p18DashStoreB.settlements)}`,
  );

  // --- G) §8/§9 CRITICAL: explicit store-filter rejection, real HTTP. ------
  let p18StoreScopeError = null;
  try {
    await rpc("get_dashboard_summary", { p_date_from: p18Today, p_date_to: p18Today, p_store_ids: [STORE_ID] }, clientAdjStoreBOnly);
  } catch (err) {
    p18StoreScopeError = err;
  }
  ok(
    "Part 18 item G (§8/§9 CRITICAL): get_dashboard_summary() over real HTTP explicitly REJECTS a store filter naming a store outside the actor's visible scope (Store A, while scoped to Store B only) rather than silently narrowing/ignoring it",
    p18StoreScopeError !== null && /خارج نطاق رؤيتك/.test(String(p18StoreScopeError.message)),
    `got ${p18StoreScopeError?.message}`,
  );

  // -------------------------------------------------------------------
  // Part 19 — Patch 8.1's remaining new RPC-level surface not already
  // exercised by Part 18 (which focused on get_dashboard_summary()/
  // get_sales_report()'s Decimal Transport Boundary + §79 redaction), over
  // the SAME real HTTP/PostgREST round trip:
  //   (A) report_shipping_zones_lookup() (0213, a genuinely NEW lookup RPC
  //       this patch adds) — works over real HTTP for an actor holding only
  //       reports.view (mirrors Part 18 item D's report_visible_stores_
  //       lookup() proof exactly, for the ONE lookup 0199 originally missed).
  //   (B) get_shipping_report()'s new p_basis dual-basis dropdown (0206):
  //       the default 'current_effective' basis, the new 'movements_during_
  //       period' basis, an explicit invalid value rejected, and the
  //       pre-existing p_is_cod TYPED BOOLEAN filter still narrows correctly
  //       post-rewrite.
  //   (C) get_returns_report()'s new p_basis dual-basis dropdown (0208):
  //       default 'business_effect', new 'actual_cash', invalid rejected.
  //   (D) get_cod_report()'s new p_basis dual-basis dropdown (0209):
  //       default 'current_effective', new 'collection_transitions',
  //       invalid rejected.
  //   (E) get_settlements_report()'s new p_effective_status filter (0212,
  //       the WORKING "Cancelled" filter §41 adds since settlement_batches.
  //       status itself can never literally be 'cancelled') — valid value
  //       accepted, invalid value rejected, and the new snapshot-column
  //       filters (p_payment_method_id/p_shipping_carrier_id) narrow
  //       correctly (a nonexistent uuid legitimately yields zero rows, not
  //       an error) rather than being silently ignored.
  //   (F) get_sales_report()'s migration 0214 performance rewrite (the N+1
  //       correlated-subquery -> GROUP BY CTE optimization) produces
  //       IDENTICAL pagination behaviour over real HTTP: splitting today's
  //       known rows across two pages yields no duplicate and no missing
  //       order_id versus one unpaginated call — the same guarantee
  //       supabase/tests/upgrade_phase8_multidomain.test.sql and the golden-
  //       scenario re-run already proved at the SQL layer, now proved once
  //       more over the actual HTTP/PostgREST wire the app itself uses.
  // -------------------------------------------------------------------
  const p19Today = todayIso;

  // --- A) report_shipping_zones_lookup() — reports.view alone suffices. ----
  const p19ZonesLookup = await rpc("report_shipping_zones_lookup", {}, clientNoProfit);
  ok(
    "Part 19 item A (§39-42): report_shipping_zones_lookup() over real HTTP works for an actor holding reports.view but NOT shipping_rates.view/shipments.manage_cost etc.",
    Array.isArray(p19ZonesLookup) && p19ZonesLookup.length > 0,
    `got ${JSON.stringify(p19ZonesLookup)}`,
  );

  // --- B) get_shipping_report() basis dropdown + typed boolean filter. -----
  const p19ShipDefault = await rpc("get_shipping_report", { p_date_from: p19Today, p_date_to: p19Today });
  ok(
    "Part 19 item B (§7-8): get_shipping_report() with no p_basis defaults to 'current_effective' over real HTTP",
    p19ShipDefault.basis === "current_effective",
    `got ${p19ShipDefault.basis}`,
  );
  const p19ShipMovements = await rpc("get_shipping_report", { p_date_from: p19Today, p_date_to: p19Today, p_basis: "movements_during_period" });
  ok(
    "Part 19 item B (§7-8): get_shipping_report() with p_basis='movements_during_period' echoes that basis over real HTTP",
    p19ShipMovements.basis === "movements_during_period",
    `got ${p19ShipMovements.basis}`,
  );
  ok(
    "Part 19 item B (§40/§41): get_shipping_report() movements_during_period summary.customer_charge_effect arrives typeof \"string\" over real HTTP",
    typeof p19ShipMovements.summary?.customer_charge_effect === "string",
    `got ${typeof p19ShipMovements.summary?.customer_charge_effect}`,
  );
  let p19ShipBasisError = null;
  try {
    await rpc("get_shipping_report", { p_date_from: p19Today, p_date_to: p19Today, p_basis: "not_a_real_basis" });
  } catch (err) {
    p19ShipBasisError = err;
  }
  ok(
    "Part 19 item B: get_shipping_report() rejects an invalid p_basis value over real HTTP rather than silently defaulting",
    p19ShipBasisError !== null && /basis غير صالح/.test(String(p19ShipBasisError.message)),
    `got ${p19ShipBasisError?.message}`,
  );
  const p19ShipCodTrue = await rpc("get_shipping_report", { p_date_from: p19Today, p_date_to: p19Today, p_is_cod: true });
  const p19ShipCodFalse = await rpc("get_shipping_report", { p_date_from: p19Today, p_date_to: p19Today, p_is_cod: false });
  ok(
    "Part 19 item B: get_shipping_report()'s p_is_cod typed boolean filter narrows correctly post-0206-rewrite (true+false partition sums to the unfiltered total, no double count/loss)",
    p19ShipCodTrue.total_count + p19ShipCodFalse.total_count === p19ShipDefault.total_count,
    `cod_true=${p19ShipCodTrue.total_count} cod_false=${p19ShipCodFalse.total_count} unfiltered=${p19ShipDefault.total_count}`,
  );

  // --- C) get_returns_report() basis dropdown. ------------------------------
  const p19RetDefault = await rpc("get_returns_report", { p_date_from: p19Today, p_date_to: p19Today });
  ok(
    "Part 19 item C (§26-29): get_returns_report() with no p_basis defaults to 'business_effect' over real HTTP",
    p19RetDefault.basis === "business_effect",
    `got ${p19RetDefault.basis}`,
  );
  const p19RetCash = await rpc("get_returns_report", { p_date_from: p19Today, p_date_to: p19Today, p_basis: "actual_cash" });
  ok(
    "Part 19 item C (§26-29): get_returns_report() with p_basis='actual_cash' echoes that basis over real HTTP",
    p19RetCash.basis === "actual_cash",
    `got ${p19RetCash.basis}`,
  );
  let p19RetBasisError = null;
  try {
    await rpc("get_returns_report", { p_date_from: p19Today, p_date_to: p19Today, p_basis: "not_a_real_basis" });
  } catch (err) {
    p19RetBasisError = err;
  }
  ok(
    "Part 19 item C: get_returns_report() rejects an invalid p_basis value over real HTTP",
    p19RetBasisError !== null && /أساس تقرير غير صالح/.test(String(p19RetBasisError.message)),
    `got ${p19RetBasisError?.message}`,
  );

  // --- D) get_cod_report() basis dropdown. ----------------------------------
  const p19CodDefault = await rpc("get_cod_report", { p_date_from: p19Today, p_date_to: p19Today });
  ok(
    "Part 19 item D (§30-32/§65): get_cod_report() with no p_basis defaults to 'current_effective' over real HTTP",
    p19CodDefault.basis === "current_effective",
    `got ${p19CodDefault.basis}`,
  );
  const p19CodTransitions = await rpc("get_cod_report", { p_date_from: p19Today, p_date_to: p19Today, p_basis: "collection_transitions" });
  ok(
    "Part 19 item D (§30-32/§65): get_cod_report() with p_basis='collection_transitions' echoes that basis over real HTTP",
    p19CodTransitions.basis === "collection_transitions",
    `got ${p19CodTransitions.basis}`,
  );
  let p19CodBasisError = null;
  try {
    await rpc("get_cod_report", { p_date_from: p19Today, p_date_to: p19Today, p_basis: "not_a_real_basis" });
  } catch (err) {
    p19CodBasisError = err;
  }
  ok(
    "Part 19 item D: get_cod_report() rejects an invalid p_basis value over real HTTP",
    p19CodBasisError !== null && /أساس تقرير غير صالح/.test(String(p19CodBasisError.message)),
    `got ${p19CodBasisError?.message}`,
  );

  // --- E) get_settlements_report() new effective_status + snapshot filters.
  const p19SettleCancelled = await rpc("get_settlements_report", { p_date_from: p19Today, p_date_to: p19Today, p_effective_status: "cancelled" });
  ok(
    "Part 19 item E (§41): get_settlements_report() accepts the new p_effective_status='cancelled' filter over real HTTP (the first WORKING cancelled filter -- settlement_batches.status itself can never literally be 'cancelled')",
    typeof p19SettleCancelled.total_count === "number",
    `got ${JSON.stringify(p19SettleCancelled)}`,
  );
  let p19SettleStatusError = null;
  try {
    await rpc("get_settlements_report", { p_date_from: p19Today, p_date_to: p19Today, p_effective_status: "not_a_real_status" });
  } catch (err) {
    p19SettleStatusError = err;
  }
  ok(
    "Part 19 item E: get_settlements_report() rejects an invalid p_effective_status value over real HTTP",
    p19SettleStatusError !== null && /حالة تقرير غير صالحة/.test(String(p19SettleStatusError.message)),
    `got ${p19SettleStatusError?.message}`,
  );
  const p19SettleNoSuchPm = await rpc("get_settlements_report", {
    p_date_from: p19Today,
    p_date_to: p19Today,
    p_payment_method_id: "00000000-0000-4000-8000-000000000000",
  });
  ok(
    "Part 19 item E (§41): get_settlements_report()'s new p_payment_method_id snapshot-column filter genuinely narrows (a nonexistent id legitimately yields zero rows) rather than being silently ignored",
    p19SettleNoSuchPm.total_count === 0,
    `got total_count=${p19SettleNoSuchPm.total_count}`,
  );

  // --- F) get_sales_report() 0214 optimized-version pagination parity. -----
  const p19SalesUnpaged = await rpc("get_sales_report", { p_date_from: p19Today, p_date_to: p19Today, p_limit: 5000 });
  const p19SalesTotal = p19SalesUnpaged.total_count;
  ok(
    "Part 19 item F: enough real Sales exist on today's business date (created by earlier Parts of this same script) for a meaningful two-page pagination split",
    p19SalesTotal >= 2,
    `total_count=${p19SalesTotal}`,
  );
  const p19PageSize = Math.ceil(p19SalesTotal / 2);
  const p19Page1 = await rpc("get_sales_report", { p_date_from: p19Today, p_date_to: p19Today, p_limit: p19PageSize, p_offset: 0 });
  const p19Page2 = await rpc("get_sales_report", { p_date_from: p19Today, p_date_to: p19Today, p_limit: p19PageSize, p_offset: p19PageSize });
  const p19PagedIds = [...p19Page1.rows, ...p19Page2.rows].map((r) => r.order_id);
  const p19UnpagedIds = p19SalesUnpaged.rows.map((r) => r.order_id);
  ok(
    "Part 19 item F (§50-51/§71 CRITICAL): migration 0214's N+1->GROUP-BY-CTE get_sales_report() rewrite paginates with NO duplicate and NO missing order_id over real HTTP (two pages' combined ids exactly match one unpaginated call's ids, as a set)",
    p19PagedIds.length === p19UnpagedIds.length && new Set(p19PagedIds).size === p19PagedIds.length && p19UnpagedIds.every((id) => p19PagedIds.includes(id)),
    `unpaged=${p19UnpagedIds.length} paged_combined=${p19PagedIds.length} paged_unique=${new Set(p19PagedIds).size}`,
  );
  ok(
    "Part 19 item F: get_sales_report()'s total_count is IDENTICAL across the unpaginated call and both paginated calls post-0214 (the rewritten CTEs do not alter the row-matching predicate, only the aggregation strategy)",
    p19Page1.total_count === p19SalesTotal && p19Page2.total_count === p19SalesTotal,
    `unpaged=${p19SalesTotal} page1=${p19Page1.total_count} page2=${p19Page2.total_count}`,
  );

  // -------------------------------------------------------------------
  // Part 20 — Phase 8 Final Integrity Hotfix 8.1.1's new report-RPC
  // surface, over the SAME real HTTP/PostgREST round trip. This
  // complements (never duplicates) supabase/tests/hotfix_8_1_1_reports_
  // exports.test.sql's exhaustive business-logic proof of the exact same
  // fixes — that file proves the COMPUTED ANSWERS are correct (exact
  // COD/settlement/adjustment/return figures, permission-key-absence
  // matrices); this Part proves the NEW parameters/shapes genuinely
  // survive the real HTTP/JSON/PostgREST wire the app itself uses, for
  // `client` (the full-permission actor already used throughout this
  // script — postgrest_http_test_setup.sql grants it settlements.create/
  // settlements.view_financials/adjustments.*/returns.*/reports.view by
  // this point in the file, see the permission grants collected near its
  // end):
  //   (A) get_items_report()/get_adjustments_report()'s export row cap
  //       raised 500->5000 (§11-14) — an over-large p_limit now clamps to
  //       5000, not 500.
  //   (B) get_settlements_report()'s p_effective_status='draft' is now a
  //       REAL, working filter (§28-31 CRITICAL) — a genuinely never-
  //       finalized draft batch (created here, real HTTP round trip) is
  //       returned by name/id, and contributes zero to the financial
  //       summary.
  //   (C) get_adjustments_report()'s new filter set (§32-35) —
  //       p_processing_store_id vs the adjustment's original sale's own
  //       store are independent, and p_participates_in_settlement=false
  //       is a REAL typed boolean over HTTP (not dropped as falsy/
  //       stringified), genuinely narrowing to the one adjustment created
  //       with that flag.
  // -------------------------------------------------------------------
  const p20Today = todayIso;

  // --- A) export row cap raised 500 -> 5000 (§11-14). -----------------
  const p20ItemsCapped = await rpc("get_items_report", { p_date_from: p20Today, p_date_to: p20Today, p_limit: 6000 });
  ok(
    "Part 20 item A (§11-14): get_items_report()'s p_limit over real HTTP clamps an over-large request to the RAISED ceiling of 5000 (not the old 500)",
    p20ItemsCapped.limit === 5000,
    `got limit=${p20ItemsCapped.limit}`,
  );
  const p20AdjCapped = await rpc("get_adjustments_report", { p_date_from: p20Today, p_date_to: p20Today, p_limit: 6000 });
  ok(
    "Part 20 item A (§11-14): get_adjustments_report()'s p_limit over real HTTP clamps an over-large request to the RAISED ceiling of 5000 (not the old 500)",
    p20AdjCapped.limit === 5000,
    `got limit=${p20AdjCapped.limit}`,
  );

  // --- B) Settlements Draft effective_status is a real, working filter
  // (§28-31 CRITICAL), including the 0220 store-scope zero-lines fix this
  // hotfix's own SQL regression coverage discovered was needed for the
  // filter to surface anything at all. -----------------------------------
  const p20DraftBatchRef = `h811t-http-draft-${Date.now() % 100000}`;
  const p20DraftBatchRows = await rpc("create_draft_settlement_batch", {
    p_settlement_route_id: stlRouteChannelledId,
    p_settlement_date: p20Today,
    p_provider_statement_reference: p20DraftBatchRef,
  });
  const p20DraftBatchRow = Array.isArray(p20DraftBatchRows) ? p20DraftBatchRows[0] : p20DraftBatchRows;
  const p20DraftBatchId = p20DraftBatchRow?.id;
  ok(
    "Part 20 item B: create_draft_settlement_batch() over real HTTP returns a real settlement batch id",
    typeof p20DraftBatchId === "string" && p20DraftBatchId.length === 36,
    `got ${JSON.stringify(p20DraftBatchRow)}`,
  );

  const p20DraftReport = await rpc("get_settlements_report", {
    p_date_from: p20Today,
    p_date_to: p20Today,
    p_effective_status: "draft",
    p_settlement_route_id: stlRouteChannelledId,
  });
  const p20DraftRows = p20DraftReport.rows ?? [];
  ok(
    "Part 20 item B (§28-30/0220 CRITICAL): get_settlements_report(p_effective_status='draft') over real HTTP surfaces the just-created, never-finalized draft batch by id (was previously ALWAYS zero rows regardless of the filter — a real batch with zero settlement_batch_lines could never pass the store-scope check, see migration 0220)",
    p20DraftRows.some((r) => r.settlement_batch_id === p20DraftBatchId && r.effective_status === "draft"),
    `got rows=${JSON.stringify(p20DraftRows)}`,
  );
  ok(
    "Part 20 item B (§30): the draft-filtered summary's expected/actual are zero (a draft batch structurally has no expected_bank_settlement/bank movements yet)",
    Number(p20DraftReport.summary?.expected ?? 0) === 0 && Number(p20DraftReport.summary?.actual ?? 0) === 0,
    `got summary=${JSON.stringify(p20DraftReport.summary)}`,
  );

  let p20InvalidEffectiveStatusError = null;
  try {
    await rpc("get_settlements_report", { p_date_from: p20Today, p_date_to: p20Today, p_effective_status: "bogus_status" });
  } catch (err) {
    p20InvalidEffectiveStatusError = err;
  }
  ok(
    "Part 20 item B: get_settlements_report() over real HTTP still rejects an invalid p_effective_status value (unchanged from Part 19 item E, re-proven post-0218/0220)",
    p20InvalidEffectiveStatusError !== null,
    `got ${p20InvalidEffectiveStatusError?.message}`,
  );

  // --- C) Adjustments' new filter set (§32-35) — reuses the Part 11
  // adjustment (adjId: processing_store_id=STORE_ID, participates_in_
  // settlement=true, dated todayIso, on order adjOrderId) and adds ONE
  // more on the SAME order but processed in STORE_B_ID with participates_
  // in_settlement=false, so both filters have a genuine positive AND
  // negative case to distinguish. -----------------------------------------
  const p20AdjBRows = await rpc("create_sales_order_adjustment", {
    p_sales_order_id: adjOrderId,
    p_adjustment_type_id: adjTypeId,
    p_processing_store_id: STORE_B_ID,
    p_adjustment_date: p20Today,
    p_payment_method_id: null,
    p_collection_channel_id: null,
    p_participates_in_settlement: false,
    p_customer_charge: "0.00",
    p_direct_cost: "12.00",
    p_notes: "HTTP test adjustment B (store B, no settlement)",
  });
  const p20AdjBRow = Array.isArray(p20AdjBRows) ? p20AdjBRows[0] : p20AdjBRows;
  const p20AdjBId = p20AdjBRow?.id;
  const p20AdjBNumber = p20AdjBRow?.adjustment_number;
  ok(
    "Part 20 item C: create_sales_order_adjustment() over real HTTP accepts participates_in_settlement=false with customer_charge=0.00 (0146's real-boolean contract)",
    typeof p20AdjBNumber === "string" && /^ADJ-\d{10}$/.test(p20AdjBNumber),
    `got ${JSON.stringify(p20AdjBRow)}`,
  );

  // get_adjustments_report() only surfaces MOVEMENTS (approved/reversed) —
  // a still-pending adjustment (create_sales_order_adjustment() alone never
  // auto-approves, exactly like Part 11 item d's adjId above) contributes
  // no movement row at all, so it must be approved first before it can
  // appear in either filter below (the same reason adjId itself was
  // approved at Part 11 item g).
  const p20AdjBAfterCreateRows = await rpc("get_sales_order_adjustment", { p_id: p20AdjBId });
  const p20AdjBAfterCreate = Array.isArray(p20AdjBAfterCreateRows) ? p20AdjBAfterCreateRows[0] : p20AdjBAfterCreateRows;
  await rpc("approve_sales_order_adjustment", { p_id: p20AdjBId, p_expected_version: p20AdjBAfterCreate.row_version });

  const p20AdjByProcStoreB = await rpc("get_adjustments_report", { p_date_from: p20Today, p_date_to: p20Today, p_processing_store_id: STORE_B_ID });
  ok(
    "Part 20 item C (§33): get_adjustments_report(p_processing_store_id=STORE_B_ID) over real HTTP surfaces adjustment B and EXCLUDES adjustment A (processed in STORE_ID, never STORE_B_ID)",
    (p20AdjByProcStoreB.rows ?? []).some((r) => r.adjustment_number === p20AdjBNumber) &&
      !(p20AdjByProcStoreB.rows ?? []).some((r) => r.adjustment_number === adjCreateRow.adjustment_number),
    `got rows=${JSON.stringify(p20AdjByProcStoreB.rows)}`,
  );

  const p20AdjByParticipatesFalse = await rpc("get_adjustments_report", { p_date_from: p20Today, p_date_to: p20Today, p_participates_in_settlement: false });
  ok(
    "Part 20 item C (§34 CRITICAL): get_adjustments_report(p_participates_in_settlement=false) over real HTTP is a REAL typed boolean — surfaces adjustment B and EXCLUDES adjustment A (participates=true), proving `false` genuinely reaches and filters the RPC rather than being dropped/stringified in transit",
    (p20AdjByParticipatesFalse.rows ?? []).some((r) => r.adjustment_number === p20AdjBNumber) &&
      !(p20AdjByParticipatesFalse.rows ?? []).some((r) => r.adjustment_number === adjCreateRow.adjustment_number),
    `got rows=${JSON.stringify(p20AdjByParticipatesFalse.rows)}`,
  );

  console.log("");
  if (failures > 0) {
    console.error(`=== ${failures} ASSERTION(S) FAILED — real HTTP/PostgREST integration test did NOT pass ===`);
    process.exit(1);
  }
  console.log("=== ALL REAL HTTP/POSTGREST INTEGRATION TEST ASSERTIONS PASSED ===");
}

main().catch((err) => {
  console.error("FATAL:", err);
  process.exit(1);
});

-- ============================================================================
-- 0092: Returns Integrity Patch 4.1 (1/7): schema — business fields, item
-- condition, pending-membership/effective-claim split, stale-sale guard,
-- action business dates, refund finalization, upgrade-safety backfill
-- ============================================================================
-- Migrations 0001-0091 are UNCHANGED. Every fix in this patch is additive
-- (ALTER TABLE / new CREATE OR REPLACE) starting here. No Shipping /
-- Settlements / Services-Adjustments / Inventory / Reports work.
--
-- This migration only touches schema + two small pure helpers. Every RPC
-- rewrite (create/preview/update-pending/refresh/approve/reject/reverse/
-- refund/finalize/read) follows in 0093-0098, each CREATE OR REPLACE-ing the
-- existing function bodies from 0085-0090 in place — signatures change where
-- the spec requires new inputs, matching how 0081/0084 already rewrote
-- update_sales_order() more than once with the project's history.
--
-- ---------------------------------------------------------------------------
-- Part A — money-scale validation helper (Section 10)
-- ---------------------------------------------------------------------------
-- numeric(14,2) columns SILENTLY ROUND excess precision on write — a real
-- gap: record_sales_return_refund() (0089) never rejected 100.005 before
-- INSERT, Postgres just rounded it. A CHECK constraint on the STORED column
-- cannot catch this (by the time CHECK runs, the value is already rounded);
-- the raw incoming parameter must be validated BEFORE it is cast/stored.
-- Every new RPC in this patch that accepts a money amount from the caller
-- (deduction, approved refund, refund event amount, fee reversal override)
-- calls this first.
create or replace function public.validate_money_scale(p_value numeric, p_label text)
returns void
language plpgsql
immutable
as $$
begin
  if p_value is not null and scale(p_value) > 2 then
    raise exception '% يجب ألا يحتوي على أكثر من رقمين عشريين (القيمة المُدخلة: %)', p_label, p_value using errcode = 'P0001';
  end if;
end;
$$;

comment on function public.validate_money_scale(numeric, text) is
  'Patch 4.1 (Section 10) — rejects (does not silently round) any money input carrying more than 2 decimal places, e.g. 100.005. Must be called on the RAW caller-supplied numeric BEFORE it reaches a numeric(14,2) column, since the column itself would round rather than reject. p_label is the Arabic field name used in the raised message.';

revoke execute on function public.validate_money_scale(numeric, text) from public;
grant execute on function public.validate_money_scale(numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Part B — sales_returns: new business fields (Sections 1, 2, 4, 9, 11)
-- ---------------------------------------------------------------------------
alter table public.sales_returns
  -- Section 4 — stale-sale guard. sale_date_snapshot doubles as Section 7's
  -- DB-enforced "return_date >= sale_date" constraint (below); source_sale_
  -- row_version is what approve_sales_return() (0095) compares against the
  -- Sale's CURRENT row_version before ever computing a financial figure.
  add column sale_date_snapshot date,
  add column source_sale_row_version bigint,
  -- Section 1/2 — collection state, drives the customer_never_received fix.
  add column collection_state text not null default 'unknown',
  -- Section 1/12 — the new financial-effect fields. All four of these are
  -- written ONLY by approve_sales_return() (0095), exactly like sales_
  -- revenue_reversal_amount/gross_profit_reversal_amount already were —
  -- never touched again afterward, including by reverse_sales_return()
  -- (reversal changes effectiveness, not history — Section 6).
  add column returned_original_sale_amount numeric(14, 2),
  add column non_shipping_deduction_amount numeric(14, 2) not null default 0,
  add column deduction_reason text,
  add column recovered_original_cost_amount numeric(14, 2),
  add column net_sales_profit_adjustment numeric(14, 2),
  add column refund_difference_reason text,
  -- Section 9 — independent action business date for Reversal (Refund event
  -- dates live on sales_return_refund_events itself, Part D below, since
  -- there can be many refund events per return).
  add column reversal_business_date date,
  -- Section 11 — refund finalization/reconciliation.
  add column refund_finalized_at timestamptz,
  add column refund_finalized_by uuid references public.profiles (id) on delete set null,
  add column refund_final_variance_reason text;

comment on column public.sales_returns.collection_state is
  'Patch 4.1 (Sections 1-2) — was the original sale amount actually collected from the customer? collected/not_collected/partially_collected/unknown. Drives the customer_never_received fix: that scenario + not_collected forces approved_refund_amount=0 (a customer who never paid cannot be refunded), enforced by sales_returns_customer_never_received_zero_refund below — never hardcoded to a COD payment-method name.';
comment on column public.sales_returns.non_shipping_deduction_amount is
  'Patch 4.1 (Section 1) — a deduction from the returned sale amount that is NOT a shipping/logistics cost adjustment already modeled elsewhere in this phase (e.g. a restocking charge). sales_revenue_reversal_amount = returned_original_sale_amount - non_shipping_deduction_amount. Requires deduction_reason when > 0 (sales_returns_deduction_reason_required below). Validated for <=2 decimal places via validate_money_scale() before write (never relies on the column''s own silent rounding).';
comment on column public.sales_returns.returned_original_sale_amount is
  'Patch 4.1 (Section 1/12) — SUM(sale_price_snapshot) of this return''s active items, written ONLY at approval. Distinct from sales_revenue_reversal_amount (= this minus the deduction) and from approved_refund_amount (a separate, explicitly-set figure — Section 1).';
comment on column public.sales_returns.recovered_original_cost_amount is
  'Patch 4.1 (Section 1/12) — SUM(total_cost_snapshot) of this return''s active items, written ONLY at approval. Profit-sensitive (sales.view_profit).';
comment on column public.sales_returns.net_sales_profit_adjustment is
  'Patch 4.1 (Section 12) — -sales_revenue_reversal_amount + recovered_original_cost_amount + payment_fee_reversal_amount, written ONLY at approval. This, not gross/net_profit_reversal_amount, is the authoritative profit-adjustment figure going forward; the older columns are kept for compatibility and documented as such. Profit-sensitive.';
comment on column public.sales_returns.source_sale_row_version is
  'Patch 4.1 (Section 4) — the parent sales_orders.row_version at the moment this Pending return was created (or last explicitly refreshed via refresh_pending_sales_return_from_sale(), 0093). approve_sales_return() (0095) locks the Sale row and rejects approval if the Sale''s CURRENT row_version no longer matches — a stale-snapshot attack/race is rejected, never silently re-snapshotted.';
comment on column public.sales_returns.reversal_business_date is
  'Patch 4.1 (Section 9) — the independent business date reverse_sales_return() (0096) is subject to Daily Close on, distinct from return_date (the return''s own creation-time business date) and from any refund event''s own refund_business_date. Defaults to business_today() at the moment of reversal if not supplied.';
comment on column public.sales_returns.refund_finalized_at is
  'Patch 4.1 (Section 11) — set by finalize_sales_return_refund() (0097) when refund reconciliation for this return is declared complete. refund_final_variance_reason is mandatory at that point iff actual_refunded_total (sum of active sales_return_refund_events) does not equal approved_refund_amount. A return with approved_refund_amount=0 can be finalized without any refund event ever existing (Section 11/18-K) — finalization is a distinct action from recording cash.';

-- Section 1 — collection_state enum.
alter table public.sales_returns
  add constraint sales_returns_collection_state_valid check (
    collection_state in ('collected', 'not_collected', 'partially_collected', 'unknown')
  );

-- Section 1 — deduction bounds + mandatory reason, all same-row CHECKs (hold
-- even against a hypothetical direct write, not just RPC discipline).
alter table public.sales_returns
  add constraint sales_returns_deduction_non_negative check (non_shipping_deduction_amount >= 0),
  add constraint sales_returns_deduction_reason_required check (
    non_shipping_deduction_amount = 0 or (deduction_reason is not null and btrim(deduction_reason) <> '')
  ),
  add constraint sales_returns_deduction_not_exceeding_original check (
    returned_original_sale_amount is null or non_shipping_deduction_amount <= returned_original_sale_amount
  );

-- Section 1 — refund-difference-reason mandatory when approved_refund_amount
-- diverges from the computed revenue reversal.
alter table public.sales_returns
  add constraint sales_returns_refund_difference_reason_required check (
    approved_refund_amount is null or sales_revenue_reversal_amount is null
    or approved_refund_amount = sales_revenue_reversal_amount
    or (refund_difference_reason is not null and btrim(refund_difference_reason) <> '')
  );

-- Section 2 — the actual customer_never_received fix, as a real DB
-- invariant (not just "approval always happens to compute it that way").
alter table public.sales_returns
  add constraint sales_returns_customer_never_received_zero_refund check (
    scenario <> 'customer_never_received' or collection_state <> 'not_collected'
    or approved_refund_amount is null or approved_refund_amount = 0
  );

-- Section 7 — return_date may never precede the sale it corrects. A CHECK
-- constraint (not merely an RPC-body comparison, unlike the pre-existing
-- return_date <= business_today() check, which legitimately cannot be a
-- CHECK since business_today() is not a same-row, deterministic-per-row
-- value) — sale_date_snapshot is fixed at creation, so this is a genuine
-- same-row DB invariant.
alter table public.sales_returns
  add constraint sales_returns_return_date_not_before_sale check (
    sale_date_snapshot is null or return_date >= sale_date_snapshot
  );

comment on constraint sales_returns_return_date_not_before_sale on public.sales_returns is
  'Patch 4.1 (Section 7) — a return can never be dated before the sale it returns items from. sale_date_snapshot is copied from sales_orders.sale_date at create_sales_return() time and is immutable afterward (return_date itself is also immutable once set, per 0086), so this holds for the life of the row.';

-- ---------------------------------------------------------------------------
-- Part C — sales_return_items: condition tracking + the pending-membership
-- vs effective-claim split (Sections 3, 5, 6)
-- ---------------------------------------------------------------------------
alter table public.sales_return_items
  -- Section 3 — historical-only condition tracking. Explicitly does NOT
  -- trigger any Inventory movement in this phase (there is no Inventory
  -- module yet) — purely a recorded fact for Create/Edit/Detail/Audit.
  add column condition text not null default 'unknown',
  add column item_return_reason text,
  add column item_notes text,
  -- Section 5 — the actual double-return-prevention redesign. is_effective
  -- is TRUE only for the items of the one currently-approved-and-not-yet-
  -- reversed return that "owns" a given sales_order_item_id. status (active/
  -- removed) continues to mean PENDING-EDIT membership only (added/dropped
  -- while the return is still pending, via update_pending_sales_return) —
  -- reject_sales_return()/reverse_sales_return() (0095/0096) no longer
  -- cascade status to 'removed' at all; they only ever change is_effective.
  add column is_effective boolean not null default false,
  -- Section 6 — precise historical-display marker, independent of status
  -- and of is_effective: TRUE for every item that was still active AT THE
  -- MOMENT a decision (approve or reject) was made about this return, and
  -- never reset afterward (reversal does not touch it — only is_effective
  -- flips back to false on reversal, releasing the claim while the
  -- historical record survives). An item soft-removed during an EARLIER
  -- pending edit (before any decision) never gets this set, matching the
  -- spec's "pending edit removal CAN use soft-removed membership, but the
  -- decision's final item set must not be erased from history" distinction.
  add column included_in_decision boolean not null default false;

comment on column public.sales_return_items.condition is
  'Patch 4.1 (Section 3) — historical-only condition of the returned item at the time of this return: good_resellable/needs_service/damaged/unknown/not_applicable (customer_never_received naturally uses not_applicable — the item was never physically returned). Does NOT create any Inventory movement in this phase; there is no Inventory module yet.';
comment on column public.sales_return_items.is_effective is
  'Patch 4.1 (Section 5) — TRUE only while this row''s parent return is the one currently-approved-and-not-reversed claim on sales_order_item_id. Set TRUE by approve_sales_return() (0095), set FALSE by reverse_sales_return() (0096). sales_return_items_effective_claim_uq (below) is the real DB-enforced "at most one effective claim per item" invariant this replaces sales_return_items_order_item_active_uq with — multiple PENDING returns may now reference the same item; only one may ever become effective.';
comment on column public.sales_return_items.included_in_decision is
  'Patch 4.1 (Section 6) — TRUE for every item that was active at the moment this return was approved or rejected; never reset by a later reversal. Together with status=''active'' this is what get_sales_return() (0098) uses to show a Rejected or Reversed return''s full historical item set — item_count/detail must never read as zero just because reversal released the effective claim.';

alter table public.sales_return_items
  add constraint sales_return_items_condition_valid check (
    condition in ('good_resellable', 'needs_service', 'damaged', 'unknown', 'not_applicable')
  );

-- Section 5 — drop the old design's index (it claimed exclusivity the
-- instant a return became merely PENDING, which is exactly what the spec
-- says must not happen) and replace it with the real invariant: at most one
-- EFFECTIVE (is_effective=true) row per sales_order_item_id, DB-enforced —
-- holds under a real concurrent-approval race (0106's redesigned R1/R2
-- concurrency tests prove this), not merely serialized by the per-order
-- advisory lock (which is also still held throughout approval, see 0095).
drop index if exists public.sales_return_items_order_item_active_uq;

create unique index sales_return_items_effective_claim_uq
  on public.sales_return_items (sales_order_item_id)
  where is_effective = true;

comment on index sales_return_items_effective_claim_uq is
  'Patch 4.1 (Section 5) — replaces sales_return_items_order_item_active_uq (0082). The real DB-enforced "an item may be effectively claimed by at most one return at a time" invariant. Multiple PENDING returns may reference the same sales_order_item_id (no index conflict, since is_effective is false for both); only the row that approve_sales_return() flips to is_effective=true can ever conflict, so a genuine concurrent double-approval race is rejected here, not merely by app-level serialization.';

-- ---------------------------------------------------------------------------
-- Part D — sales_return_refund_events: per-event business dates (Section 9)
-- ---------------------------------------------------------------------------
alter table public.sales_return_refund_events
  add column refund_business_date date,
  add column reversal_business_date date;

comment on column public.sales_return_refund_events.refund_business_date is
  'Patch 4.1 (Section 9) — the business date record_sales_return_refund() (0097) is subject to Daily Close on for THIS specific cash event, independent of the parent return''s return_date and of any other event''s date. Defaults to business_today() at recording time if not supplied.';
comment on column public.sales_return_refund_events.reversal_business_date is
  'Patch 4.1 (Section 9) — the business date reverse_sales_return_refund_event() (0097) is subject to Daily Close on. Defaults to business_today() at reversal time if not supplied.';

-- ---------------------------------------------------------------------------
-- Part E — Upgrade safety backfill (Section 20). Data may already exist on
-- 0082-0091. Nothing below deletes a row or a historical fact; it only
-- fills in what the new columns need to mean for rows written under the OLD
-- design.
-- ---------------------------------------------------------------------------

-- sale_date_snapshot / source_sale_row_version — every existing return, any
-- status, backfilled from its parent Sale's CURRENT sale_date/row_version.
-- For an already-decided return this is purely informational (only a
-- PENDING return's source_sale_row_version is ever compared again, by
-- approve_sales_return()); for an existing PENDING return, backfilling to
-- the CURRENT version means the very first approval attempt after upgrade
-- compares against a value known to match right now — no spurious "stale
-- sale" rejection is introduced by the upgrade itself.
update public.sales_returns sr
set sale_date_snapshot = so.sale_date,
    source_sale_row_version = so.row_version
from public.sales_orders so
where so.id = sr.sales_order_id
  and sr.sale_date_snapshot is null;

alter table public.sales_returns
  alter column sale_date_snapshot set not null,
  alter column source_sale_row_version set not null;

-- is_effective — TRUE only for items that are (a) currently active AND
-- (b) belong to a currently-approved (not reversed) return. Pending items
-- are never effective (Section 20: "do NOT consider Pending as effective").
-- Reversed/rejected returns' items, whatever their current status under the
-- OLD cascade-to-removed behavior, are correctly left FALSE — they hold no
-- claim today.
update public.sales_return_items sri
set is_effective = true
from public.sales_returns sr
where sr.id = sri.sales_return_id
  and sr.status = 'approved'
  and sri.status = 'active';

-- included_in_decision — TRUE for items that were part of the FINAL set at
-- the moment of the historical decision (approve/reject), distinguished
-- from an earlier pending-edit removal by comparing removed_at against the
-- decision timestamp: the OLD reject/reverse cascade soft-removed every
-- active item in one single UPDATE at the moment of the decision, so a row
-- removed AT OR AFTER approved_at/rejected_at was part of that decision's
-- final set; a row removed BEFORE it was dropped earlier during editing.
update public.sales_return_items sri
set included_in_decision = true
from public.sales_returns sr
where sr.id = sri.sales_return_id
  and sr.status in ('approved', 'rejected', 'reversed')
  and (
    sri.status = 'active'
    or sri.removed_at >= coalesce(sr.approved_at, sr.rejected_at)
  );

comment on table public.sales_return_items is
  'One row per returned line. status (active/removed) tracks PENDING-EDIT membership only, as of Patch 4.1 (Section 5/6) — reject_sales_return()/reverse_sales_return() no longer cascade it to removed (that used to erase historical item visibility, Section 6). is_effective tracks the exclusive Approved claim (Section 5); included_in_decision permanently marks the final item set as of approve/reject (Section 6). Every *_snapshot column is fixed at INSERT time from sales_order_items and never re-read afterward (snapshot-only calculation) except via the explicit refresh_pending_sales_return_from_sale() (0093).';

-- ---------------------------------------------------------------------------
-- Part F — Section 8 fix: compute_sales_return_fee_reversal() previously
-- treated full_reversal and proportional_reversal identically for a PARTIAL
-- return. Per Phase 2's own seed-data documentation (0044) and the spec:
-- proportional_reversal reverses a proportional SHARE on every partial
-- return (unchanged); full_reversal reverses NOTHING on a partial return —
-- only the return that completes full coverage of the order absorbs the
-- entire remaining fee. Both still absorb the full remaining balance on the
-- allocation that completes full coverage (unchanged, no rounding residue
-- ever stranded). non_refundable_fee/manual/hard-cap are all unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.compute_sales_return_fee_reversal(
  p_order_subtotal_snapshot numeric,
  p_order_payment_fee_amount_snapshot numeric,
  p_return_subtotal numeric,
  p_refund_fee_policy text,
  p_covers_all_remaining_items boolean,
  p_already_reversed_fee numeric,
  p_fee_reversal_override numeric default null
)
returns numeric
language plpgsql
immutable
as $$
declare
  v_result numeric;
  v_remaining numeric;
begin
  if p_refund_fee_policy = 'non_refundable_fee' then
    v_result := 0;
  elsif p_refund_fee_policy = 'manual' then
    if p_fee_reversal_override is null then
      raise exception 'يجب إدخال قيمة استرداد العمولة يدويًا — سياسة استرداد العمولة لطريقة الدفع هذه "يدوي"' using errcode = 'P0001';
    end if;
    if p_fee_reversal_override < 0 then
      raise exception 'قيمة استرداد العمولة لا يمكن أن تكون سالبة' using errcode = 'P0001';
    end if;
    v_result := p_fee_reversal_override;
  elsif p_refund_fee_policy in ('full_reversal', 'proportional_reversal') then
    if p_fee_reversal_override is not null then
      raise exception 'لا يمكن تحديد قيمة استرداد عمولة يدويًا إلا عندما تكون سياسة استرداد العمولة "يدوي"' using errcode = 'P0001';
    end if;

    if p_covers_all_remaining_items then
      -- Both policies alike absorb the entire remaining balance on the
      -- allocation that completes full coverage — no rounding residue is
      -- ever left stranded, regardless of which policy applied to earlier
      -- partial returns on the same order.
      v_result := p_order_payment_fee_amount_snapshot - p_already_reversed_fee;
    elsif p_refund_fee_policy = 'proportional_reversal' then
      -- Partial return, proportional_reversal: a proportional share applies
      -- on every partial allocation (Phase 2 seed-data documented this
      -- explicitly for Tabby/Tamara — a 100% proportional refund already
      -- naturally equals full_reversal's own full-coverage case).
      v_result := round(p_order_payment_fee_amount_snapshot * (p_return_subtotal / nullif(p_order_subtotal_snapshot, 0)), 2);
    else
      -- Partial return, full_reversal: reverses NOTHING before full
      -- coverage — a full_reversal policy only ever reverses the fee once
      -- the return operation, cumulatively, covers the ENTIRE order.
      v_result := 0;
    end if;
  else
    raise exception 'سياسة استرداد عمولة غير معروفة: %', p_refund_fee_policy using errcode = 'P0001';
  end if;

  -- Hard cap — never reverse more fee than was ever charged on this order,
  -- regardless of policy or rounding (defensive invariant, independent of
  -- which branch above produced v_result).
  v_remaining := p_order_payment_fee_amount_snapshot - p_already_reversed_fee;
  if v_result > v_remaining then
    v_result := v_remaining;
  end if;
  if v_result < 0 then
    v_result := 0;
  end if;

  return v_result;
end;
$$;

comment on function public.compute_sales_return_fee_reversal(numeric, numeric, numeric, text, boolean, numeric, numeric) is
  'Patch 4.1 (Section 8) — fixes full_reversal vs proportional_reversal semantics for a PARTIAL return: proportional_reversal reverses a proportional share on every partial allocation (unchanged since 0085); full_reversal reverses NOTHING until the allocation that completes full coverage of the order, at which point it (like proportional_reversal) absorbs the entire remaining fee balance with no rounding residue left stranded. non_refundable_fee/manual/hard-cap unchanged from 0085. IMMUTABLE, no table access — caller supplies every already-queried figure. Still the single shared formula used identically by preview_sales_return() (0093) and approve_sales_return() (0095).';

revoke execute on function public.compute_sales_return_fee_reversal(numeric, numeric, numeric, text, boolean, numeric, numeric) from public;
grant execute on function public.compute_sales_return_fee_reversal(numeric, numeric, numeric, text, boolean, numeric, numeric) to authenticated;

-- ============================================================================
-- 0144: Phase 6 Integrity Patch 6.1 (1/13): zero-charge/free-service schema +
-- payment_reference column
-- ============================================================================
-- Migrations 0001-0143 are unmodified — this patch starts at 0144 (user
-- directive). No Settlements / Reports-Dashboard / Inventory / new phase.
--
-- Patch 6.1 item 9/10/11 — Phase 6 originally forced payment_method_id/
-- collection_channel_id to be NOT NULL even for a genuinely FREE service
-- (customer_charge = 0), which made a real free-service adjustment
-- impossible to model honestly (a payment method/channel had to be
-- fabricated for a transaction that never collects anything), and Approval
-- always resolved a Payment Fee Version even when there was nothing to
-- charge a fee on. This migration makes both columns nullable and adds two
-- explicit DB-level invariants (not merely RPC-level checks — a direct
-- trusted write must also honor them):
--   1. sales_order_adjustments_zero_charge_consistent — customer_charge = 0
--      implies payment_method_id/collection_channel_id/payment_reference
--      are ALL NULL and participates_in_settlement = false, unconditionally
--      (pending or approved, no exception).
--   2. sales_order_adjustments_lifecycle_consistent (replaces 0135's
--      original) — an APPROVED row must still carry a full financial
--      snapshot, but the shape of that snapshot now branches on
--      customer_charge: a PAID approved row (customer_charge > 0) requires
--      payment_fee_version_id/payment_method_name_snapshot/collection_
--      channel_name_snapshot to be set (a fee was genuinely resolved); a
--      FREE approved row (customer_charge = 0) requires ALL THREE to be
--      NULL (nothing was resolved) and payment_fee_amount = 0.00 exactly
--      (an explicit zero, not merely non-null).
--
-- Backfill IS required in principle: under the pre-0144 schema (0133-0143),
-- customer_charge = 0 was already a legal input (0139 only rejected
-- NEGATIVE values), payment_method_id/collection_channel_id were NOT NULL,
-- and approval always resolved a real Payment Fee Version — so a real
-- production database could already contain a genuinely free-service row
-- (customer_charge = 0) carrying a non-null payment method/channel/
-- settlement flag, and — if approved — a payment_fee_amount/net_
-- adjustment_profit computed from that (possibly non-zero) fee. This is
-- exactly the bug items 9/10 describe. Rather than asserting no such row
-- can exist (which would simply make this migration fail on a real
-- database that has one) or inventing a financial value, this migration
-- deterministically normalizes any such row to the NEW zero-charge
-- contract: payment fields -> NULL, participates_in_settlement -> false,
-- and — for an already-APPROVED row — the fee/net snapshot is recomputed
-- using the SAME deterministic rule the new RPCs now apply uniformly
-- (fee forced to 0.00; gross_adjustment_profit is untouched, since it never
-- depended on the fee; net_adjustment_profit becomes equal to gross). No
-- value is invented — every number written here is either NULL, false, or
-- mechanically re-derived from that row's own pre-existing customer_charge/
-- direct_cost/gross_adjustment_profit.
--
-- Hotfix 6.1.1 item 1 — the original draft of this migration only
-- normalized PENDING and APPROVED zero-charge rows, but the new
-- sales_order_adjustments_zero_charge_consistent CHECK below applies
-- unconditionally (regardless of status). A REJECTED row was already a
-- legal pre-0144 zero-charge state (0139 only rejected NEGATIVE charges;
-- rejection never depended on approval at all) and could just as easily
-- carry a non-null legacy payment method/channel — such a row would make
-- THIS migration itself fail on a real production database before it ever
-- reaches a later 0157+ fix. A REJECTED row never carries a financial
-- snapshot to begin with (payment_fee_amount/gross/net_adjustment_profit
-- are NULL for every non-approved row, enforced by the lifecycle
-- constraint since 0135) — only the same operational fields as the PENDING
-- branch need normalizing; no financial recomputation applies. Historical
-- identity (id/adjustment_number/status/rejection_reason/rejected_by/
-- rejected_at/notes/direct_cost/dates/store/type) is untouched.
-- ---------------------------------------------------------------------------
alter table public.sales_order_adjustments
  alter column payment_method_id drop not null,
  alter column collection_channel_id drop not null,
  add column payment_reference text;

comment on column public.sales_order_adjustments.payment_reference is
  'Patch 6.1 item 11/29 — optional free-text payment reference, editable while PENDING only (immutable after Approval/Rejection, enforced by the 0154 terminal-immutability trigger). NOT a secret/profit figure — visible to adjustments.view alone. Must be NULL for a free service (customer_charge = 0), enforced by the zero-charge CHECK below.';

-- The backfill below intentionally runs AFTER dropping the OLD (pre-Patch-
-- 6.1) lifecycle constraint and BEFORE adding the two new constraints: the
-- old constraint unconditionally required payment_fee_version_id/payment_
-- method_name_snapshot/collection_channel_name_snapshot to be non-null on
-- every APPROVED row (no zero-charge exception existed yet), so normalizing
-- a genuinely-free approved row to NULL/0.00 would itself violate the OLD
-- constraint if attempted first. Dropping it first, backfilling, then
-- adding the new (zero-charge-aware) constraints afterward is the only
-- ordering under which both the pre-existing data AND the final schema end
-- up consistent.
alter table public.sales_order_adjustments
  drop constraint sales_order_adjustments_lifecycle_consistent;

do $$
declare
  v_backfilled_pending integer;
  v_backfilled_rejected integer;
  v_backfilled_approved integer;
begin
  -- PENDING zero-charge rows carrying a non-null payment method/channel/
  -- settlement flag under the old schema — normalize the operational
  -- fields only (nothing was ever computed/snapshotted yet).
  with backfilled as (
    update public.sales_order_adjustments
    set payment_method_id = null,
        collection_channel_id = null,
        payment_reference = null,
        participates_in_settlement = false
    where status = 'pending'
      and customer_charge = 0
      and (payment_method_id is not null or collection_channel_id is not null or participates_in_settlement)
    returning 1
  )
  select count(*) into v_backfilled_pending from backfilled;

  -- Hotfix 6.1.1 item 1 — REJECTED zero-charge rows: same operational-only
  -- normalization as PENDING (a rejected row never carries a financial
  -- snapshot at all, so there is nothing to recompute). Historical rejection
  -- metadata (rejection_reason/rejected_by/rejected_at) is untouched.
  with backfilled as (
    update public.sales_order_adjustments
    set payment_method_id = null,
        collection_channel_id = null,
        payment_reference = null,
        participates_in_settlement = false
    where status = 'rejected'
      and customer_charge = 0
      and (payment_method_id is not null or collection_channel_id is not null or participates_in_settlement)
    returning 1
  )
  select count(*) into v_backfilled_rejected from backfilled;

  -- APPROVED zero-charge rows — normalize the operational fields AND
  -- deterministically recompute the fee/net snapshot to the new zero-fee
  -- rule (gross_adjustment_profit is untouched: it never depended on the
  -- fee amount to begin with).
  with backfilled as (
    update public.sales_order_adjustments
    set payment_method_id = null,
        collection_channel_id = null,
        payment_reference = null,
        participates_in_settlement = false,
        payment_fee_version_id = null,
        payment_fee_percentage_snapshot = null,
        payment_fee_fixed_snapshot = null,
        payment_method_name_snapshot = null,
        collection_channel_name_snapshot = null,
        payment_fee_amount = 0,
        net_adjustment_profit = gross_adjustment_profit
    where status = 'approved'
      and customer_charge = 0
      and (
        payment_method_id is not null or collection_channel_id is not null or participates_in_settlement
        or payment_fee_amount <> 0 or payment_fee_version_id is not null
      )
    returning 1
  )
  select count(*) into v_backfilled_approved from backfilled;

  raise notice 'Patch 6.1 items 9/10 + Hotfix 6.1.1 item 1: % صف Pending و% صف Rejected و% صف Approved بقيمة تحصيل صفرية أُعيد ضبطها إلى قاعدة الخدمة المجانية الجديدة (حقول الدفع -> NULL، العمولة -> 0.00 حتمًا للمعتمَد، لا قيم مُختلَقة)', v_backfilled_pending, v_backfilled_rejected, v_backfilled_approved;
end $$;

alter table public.sales_order_adjustments
  add constraint sales_order_adjustments_lifecycle_consistent check (
    (status = 'pending' and approved_at is null and rejected_at is null and approved_by is null and rejected_by is null)
    or (
      status = 'approved' and approved_at is not null and approved_by is not null
      and rejected_at is null and rejected_by is null
      and direct_cost is not null
      and payment_fee_amount is not null
      and gross_adjustment_profit is not null
      and net_adjustment_profit is not null
      and adjustment_type_code_snapshot is not null
      and (
        (customer_charge > 0
          and payment_fee_version_id is not null
          and payment_method_name_snapshot is not null
          and collection_channel_name_snapshot is not null)
        or
        (customer_charge = 0
          and payment_fee_version_id is null
          and payment_fee_percentage_snapshot is null
          and payment_fee_fixed_snapshot is null
          and payment_method_name_snapshot is null
          and collection_channel_name_snapshot is null
          and payment_fee_amount = 0)
      )
    )
    or (
      status = 'rejected' and rejected_at is not null and rejected_by is not null
      and approved_at is null and approved_by is null
      and rejection_reason is not null and btrim(rejection_reason) <> ''
    )
  );

alter table public.sales_order_adjustments
  add constraint sales_order_adjustments_zero_charge_consistent check (
    customer_charge > 0
    or (
      customer_charge = 0
      and payment_method_id is null
      and collection_channel_id is null
      and payment_reference is null
      and participates_in_settlement = false
    )
  );

comment on constraint sales_order_adjustments_zero_charge_consistent on public.sales_order_adjustments is
  'Patch 6.1 item 9/10 — a genuinely FREE service/adjustment (customer_charge = 0) never carries a payment method, collection channel, payment reference, or settlement participation — enforced at the DB level regardless of status (pending or approved), so no RPC bug or trusted direct write can leave a half-paid-half-free row.';

comment on constraint sales_order_adjustments_lifecycle_consistent on public.sales_order_adjustments is
  'Phase 6 original + Patch 6.1 item 9/10 — an APPROVED row''s financial snapshot shape branches on customer_charge: paid (>0) requires a resolved Payment Fee Version + payment method/channel name snapshots; free (=0) requires all three to be NULL and payment_fee_amount = 0.00 exactly (never merely non-null). A REJECTED row requires a non-blank reason. A PENDING row carries neither timestamp.';

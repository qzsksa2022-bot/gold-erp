# Phase 4 — Returns Core: Design Decisions (working notes)

Internal reference used while building migrations 0082+. Folded into
DELIVERY_REPORT.md's Phase 4 appendix at delivery time — not itself a
deliverable.

## Tables

- `sales_returns` — one row per return transaction (header). No hard delete.
- `sales_return_items` — one row per returned line, FK'd to
  `sales_order_items.id` (stable identity, never line_no/category+weight).
  Soft-remove only (`status active/removed`), mirrors `sales_order_items`
  (0067).
- `sales_return_refund_events` — append-only actual-cash-refund ledger.
  Rows are never edited after insert except a `status active→reversed`
  soft-void transition (amount/method/notes stay permanent).

No separate `sales_return_reversals` table — reversal is a single terminal
transition per return (no un-reverse), so `reversed_at/reversed_by/
reversal_reason` live directly on `sales_returns`, exactly like
`sales_order_items.removed_at/removed_by`. Same reasoning for
approve/reject: `approved_at/approved_by`, `rejected_at/rejected_by/
rejection_reason` inline columns, not separate tables.

## Double-return prevention — real DB constraint, not just app logic

`sales_return_items` gets a **partial unique index**:
`unique (sales_order_item_id) where status = 'active'`.

An item's `sales_return_items` row stays `status='active'` for as long as
its parent return is `pending` or `approved`. `reject_sales_return()` and
`reverse_sales_return()` both cascade-soft-remove every active item row of
that return in the same statement. Net effect: at any instant, at most one
`active` `sales_return_items` row can reference a given
`sales_order_item_id`, DB-enforced (survives a raw service_role write, not
just RPC discipline) — exactly the pattern this project already prefers
over app-only checks (GIST exclusion on fee versions, etc.). A concurrent
double-claim raises a real `unique_violation`, caught and translated to a
clear Arabic P0001 message.

## Per-order advisory lock (new namespace, key1 = 1004)

`acquire_returns_order_lock_exclusive(p_sales_order_id uuid)` — serializes
every return-lifecycle mutation (create/update-pending/approve/reject/
reverse) for one order, AND is acquired by `update_sales_order()`'s new
"does an effective return exist" check (migration 0084) — closes the race
between a concurrent Sales financial edit and a concurrent Return approval
on the same order. Mirrors `acquire_financial_master_lock_*`/
`acquire_daily_close_lock_*` (0065) exactly: two-int32 advisory lock,
transaction-scoped, `authenticated`-granted.

Daily-close integration reuses the *existing* Sales lock helpers verbatim
(`acquire_daily_close_lock_shared/exclusive`), keyed on
`(processed_store_id, return_date)` — a Return does NOT get its own closing
table; it respects the same `daily_closings` rows Sales' `close_sales_day()`
already writes. `returns.process_closed_day` is the override permission
(mirrors `sales.edit_closed_day`), with a mandatory reason.

## `sales_returns` can be processed at a different store than the sale

`processed_store_id` (not `sales_orders.store_id`) drives store-scope
checks and daily-close locking for a return — a customer may return an item
at a different branch than where they bought it. Create/approve/reject/
reverse/record-refund all require `processed_store_id` in the actor's
OPERABLE scope (mirrors `create_sales_order`); read (list/get) requires
VISIBLE scope on `processed_store_id`.

## Snapshot-only calculation

Every cost/price figure on `sales_return_items` is copied from
`sales_order_items` at return-creation (or pending-edit) time — Returns
NEVER calls `gold_price_for_karat_on_date()`/manufacturing/VAT resolvers.
`sales_returns.order_subtotal_snapshot`/`order_payment_fee_amount_snapshot`
are copied from `sales_orders` at return-creation time for the same reason.
`refund_fee_policy_snapshot` is the one deliberate exception: it is read
live from `payment_methods.refund_fee_policy` **at approval time only**,
because it is current business configuration ("which rule applies now"),
not a historical financial value being resolved for a past date — same
category as reading current dropdown options, not `gold_price_for_karat_
on_date()`. Once read, it is stored and never re-read.

## Two independent tracked values (never conflated)

- **Sales Revenue Reversal** (`sales_revenue_reversal_amount`) — a single
  deterministic number, `sum(sales_return_items.sale_price_snapshot)`,
  fixed at approval. Pure accounting concept: how much revenue is removed
  from the books.
- **Actual Cash Refund** — NOT a single column. It is
  `sum(sales_return_refund_events.amount where status='active')`, an
  append-only ledger the accountant/cashier populates over time via
  `record_sales_return_refund()` (could be partial, staged, via a
  different payment method than the original sale). `approved_refund_amount`
  (= `sales_revenue_reversal_amount` at approval) is the *target*; the
  ledger sum is what actually happened. Variance between the two is
  surfaced by the read RPCs for reconciliation, never auto-enforced to
  match.

## Payment fee reversal — cumulative capping + final-allocation rounding absorption

Computed once, at approval, consuming `payment_methods.refund_fee_policy`
(never hardcoding a provider name):

- `non_refundable_fee` → `payment_fee_reversal_amount = 0`, always.
- `manual` → caller must supply `p_fee_reversal_override` (required
  non-null, rejected if supplied for any other policy); still hard-capped
  below.
- `full_reversal` / `proportional_reversal` → both use the identical
  proportional formula (seed data's own comment: proportional_reversal at
  a 100% refund fraction already covers the full_reversal case):
  `fraction = this_return's sale_price sum / order_subtotal_snapshot`,
  `proportional_fee = round(order_payment_fee_amount_snapshot * fraction, 2)`.
  - If, after this approval, **every** active item of the order is now
    covered by an effective (approved, non-reversed) return — i.e. this is
    the allocation that completes full coverage — the remaining
    unreversed fee balance (`order_payment_fee_amount_snapshot -
    sum(fee_reversal_amount of other effective returns on this order)`)
    is absorbed *entirely* into this return instead of the proportional
    figure, so cumulative reversed fee always lands exactly on the
    original total fee with no rounding residue left stranded.
  - Otherwise, the proportional figure is used, hard-capped so cumulative
    reversed fee across all effective returns on the order never exceeds
    `order_payment_fee_amount_snapshot` (defensive, should not trigger
    under normal math).

`gross_profit_reversal_amount` / `net_profit_reversal_amount` (=
`gross_profit_reversal_amount - payment_fee_reversal_amount`) mirror
`sales_orders.gross_profit`/`net_sales_profit` symmetrically — profit-
sensitive, hidden without `sales.view_profit`, same as Sales.

## Order state (full / partial / not_returned) — derived, never stored

Computed live in the read RPCs from item coverage: for every *active*
`sales_order_items` row of the order, is it covered by an effective
(`status='approved'`) return? none → `not_returned`; all → `full`;
some → `partial`. Never a stored/cached column a client could send back
stale or forged.

## Financial lock after approved return (migration 0084)

`update_sales_order()` gets a new guard, inserted immediately after the
existing row_version conflict check: if any effective return exists for
this order, the call is restricted to metadata-only (customer_name/phone/
notes, and per-item item_name/description/sku) — any attempted payment
method/collection channel change, any item financial change (category/
karat/weight/sale_price), or any item add/remove is rejected with a clear
Arabic error before any write happens. Signature is unchanged from 0075/
0081 (same 9 params) — this is a pure `CREATE OR REPLACE` body change.

## Scenario enum

`defective_product`, `customer_changed_mind`, `wrong_item_delivered`,
`customer_never_received` (first-class, not a notes field, per spec),
`other` (requires non-empty `scenario_notes`, enforced in the RPC body,
mirroring the closed-day-reason conditional-requirement pattern — not a
blind CHECK constraint since the requirement is conditional).

## Permissions

New: `returns.reverse`, `returns.record_refund`, `returns.process_closed_day`.
`returns.view`/`create`/`approve` already exist (seeded pre-Phase-4).
Default grants mirror the existing `returns.approve` grant exactly (same
roles that can approve can also reverse/record-refund/override-closed-day):
Admin + Supervisor + Super Admin. `sales_employee`/`accountant` keep their
existing `returns.view`(+`create` for sales_employee) baseline, unchanged.

## Audit

New action taxonomy: `return.create`, `return.update`, `return.approve`,
`return.reject`, `return.reverse`, `return.refund_recorded`,
`return.refund_reversed`, `return.closed_day_override`. Migration 0091
extends the 0072 RLS policy: `action LIKE 'return.%'` requires
`audit_logs.view AND sales.view_profit` (reuses the existing permission,
no new `returns.view_profit`), identical mechanism to the `sale.%` rule.

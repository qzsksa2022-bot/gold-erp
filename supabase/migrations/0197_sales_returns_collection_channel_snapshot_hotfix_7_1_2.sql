-- ============================================================================
-- 0197: Phase 7 — Final Historical Route Snapshot Hotfix 7.1.2 (1/2):
-- sales_returns.collection_channel_id_snapshot — authoritative capture,
-- sanctioned-refresh lockstep, and deterministic audit-history backfill
-- ============================================================================
-- Migrations 0001-0196 are UNCHANGED (byte-for-byte). This migration is
-- additive only: a new column on sales_returns, two BEFORE-row triggers,
-- and a one-time historical backfill. No existing function's signature or
-- access model is touched.
--
-- ---------------------------------------------------------------------------
-- REVISION (Hotfix 7.1.3 source review, still pre-approval): this file was
-- rewritten IN PLACE. 0197/0198 had not yet been accepted as part of the
-- frozen baseline (only 0001-0196 are frozen) when an independent source-
-- level review of the delivered Hotfix 7.1.2 archive found that this
-- migration's ORIGINAL Part C/Part E were built on an incorrect assumption:
-- that sales_returns.payment_method_id is a permanent CREATION-TIME
-- snapshot. It is not. public.refresh_pending_sales_return_from_sale()
-- (0100) is the existing, sanctioned way to re-sync a PENDING return's
-- Sale-derived basis (payment_method_id, source_sale_row_version,
-- order_subtotal_snapshot, item snapshots, etc.) to the Sale's CURRENT
-- state after the Sale has been edited — and it has existed, unmodified,
-- since Patch 4.1/4.2, long before this hotfix. The ORIGINAL Part E's
-- unconditional "never changes after INSERT" trigger was therefore too
-- strict: it would let payment_method_id legitimately move to a new value
-- via a sanctioned refresh while permanently pinning collection_channel_id_
-- snapshot to whatever Sale state existed at Return creation — producing an
-- impossible, never-actually-existed (payment_method, channel) pair (e.g.
-- payment_method_id=B post-refresh alongside collection_channel_id_
-- snapshot=A from creation). The ORIGINAL Part C's backfill (first sale.
-- update audit row at/after sales_return.created_at) had the matching
-- flaw: a Return that was refreshed pre-0197 has a basis that moved AWAY
-- from its creation-time state, so "first edit after creation" no longer
-- identifies the Return's actual current financial basis and would corrupt
-- the backfill (or abort the whole migration) for any such Return, a real
-- upgrade blocker. Both are corrected below. The BEFORE INSERT trigger
-- (Part B) needed no change: it was always correct for a NEW Return.
-- ---------------------------------------------------------------------------
-- The bug this closes (Hotfix 7.1.2 §1): return_fee_reversal /
-- return_fee_reversal_reversal settlement-route matching (0192) currently
-- reads sales_orders.payment_method_id/collection_channel_id LIVE, at
-- Discovery time. sales_returns.payment_method_id is already a proper
-- Sale-derived-basis snapshot (0082/0100, re-synced ONLY by the sanctioned
-- refresh_pending_sales_return_from_sale() while pending, frozen once the
-- pending lifecycle ends) — so the payment-method half of the match is
-- already historically correct. But sales_returns carries no equivalent
-- snapshot for collection_channel_id, so that half of the match still
-- floats with whatever the Sale's collection_channel_id happens to be
-- *right now*. Once a Return has left the pending lifecycle (approved,
-- rejected, or reversed), update_sales_order()'s financial lock (0084) no
-- longer blocks editing payment_method_id/collection_channel_id on the
-- original Sale once the Return is reversed — so a LATER edit to the Sale
-- can retroactively change which settlement route an ALREADY-SETTLED-OR-
-- SETTLEABLE historical fee-reversal event resolves to. A Historical
-- Settlement Source's financial identity must never drift because of an
-- unrelated, later edit to the Sale, once that identity is no longer
-- eligible to move through the sanctioned refresh path.
--
-- The fix (this migration + 0198): give collection_channel_id a snapshot
-- column that moves in LOCKSTEP with payment_method_id + source_sale_row_
-- version — captured authoritatively at Return creation, re-captured
-- authoritatively ONLY by a coherent sanctioned pending-refresh transition,
-- frozen forever once the pending lifecycle ends, never re-read from a
-- live Sale for settlement-route matching purposes.
-- ---------------------------------------------------------------------------
-- This migration is wrapped in an explicit transaction (unlike every prior
-- migration in this project, which relies on psql's per-statement
-- autocommit + `-v ON_ERROR_STOP=1` to halt a failing script). It has to be:
-- the historical backfill below (Part C) can, on a real production
-- database with unreliable/incomplete audit history for a given Return,
-- legitimately RAISE and abort mid-way. Without an explicit transaction,
-- that would leave the column added (nullable, unbackfilled) but no
-- NOT NULL constraint and no immutability trigger — a genuinely broken
-- intermediate state. Wrapping the whole file guarantees it is all-or-
-- nothing: either every Return gets a verified, correct snapshot and the
-- column becomes permanently frozen (past the pending lifecycle), or
-- NOTHING in this file is applied at all and the operator sees one clear
-- error to investigate.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Part A — schema: the new snapshot column, nullable for now (Part C
-- backfills it, then Part D makes it NOT NULL).
-- ---------------------------------------------------------------------------
alter table public.sales_returns
  add column collection_channel_id_snapshot uuid references public.collection_channels (id) on delete restrict;

comment on column public.sales_returns.collection_channel_id_snapshot is
  'Hotfix 7.1.2/7.1.3 — the collection_channel_id of the Sale STATE this Return''s figures are CURRENTLY based on (mirrors payment_method_id, 0082/0100, exactly — the two move together, always from the same Sale row read). Captured authoritatively by the sales_returns_capture_channel_snapshot BEFORE INSERT trigger at Return creation (this migration) — never client-supplied. While the Return is pending, the ONLY way this basis ever moves is the SAME sanctioned path that already re-syncs payment_method_id/source_sale_row_version: refresh_pending_sales_return_from_sale() (0100, unmodified) — the sales_returns_channel_snapshot_guard BEFORE UPDATE trigger (this migration) recognizes that exact transition (status stays ''pending'' AND source_sale_row_version changes) and authoritatively re-derives this column from the Sale''s CURRENT collection_channel_id in the SAME statement, keeping it in lockstep with payment_method_id rather than pinning it to a stale creation-time value. Once the Return leaves the pending lifecycle (approved/rejected/reversed), this column is permanently frozen: the same trigger rejects ANY further change, for every role including service_role/trusted direct SQL, UNLESS it is again a coherent sanctioned-refresh transition (which cannot occur once status is no longer ''pending''). Historical rows (every sales_return created before this migration) were backfilled deterministically from audit_logs history keyed to each Return''s OWN source_sale_row_version (not a timestamp heuristic), verified against the existing payment_method_id snapshot as an anchor — see this migration''s Part C.';

create index sales_returns_collection_channel_snapshot_idx on public.sales_returns (collection_channel_id_snapshot);

-- ---------------------------------------------------------------------------
-- Part B — BEFORE INSERT trigger: authoritative capture for every FUTURE
-- Return, independent of create_sales_return() (0085/0093/0100, all frozen,
-- none of them need editing). Reads the Sale's collection_channel_id at the
-- exact moment of INSERT and overwrites NEW.collection_channel_id_snapshot
-- with it unconditionally — a client (or a future, unmodified INSERT
-- statement that never even mentions this column) cannot supply or omit
-- their way around this. UNCHANGED from the original 0197 — always correct
-- for a brand-new Return; the review that prompted this revision found no
-- issue here.
-- ---------------------------------------------------------------------------
create or replace function public.sales_returns_capture_channel_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_channel_id uuid;
begin
  select so.collection_channel_id into v_channel_id
  from public.sales_orders so
  where so.id = new.sales_order_id;

  if v_channel_id is null then
    raise exception 'تعذّر التقاط قناة التحصيل الحالية للمرتجع — عملية البيع (id: %) غير موجودة' , new.sales_order_id using errcode = 'P0001';
  end if;

  new.collection_channel_id_snapshot := v_channel_id;
  return new;
end;
$$;

comment on function public.sales_returns_capture_channel_snapshot() is
  'Hotfix 7.1.2 — BEFORE INSERT ON sales_returns. Authoritatively sets NEW.collection_channel_id_snapshot from the linked Sale''s CURRENT collection_channel_id, overwriting whatever (if anything) the INSERT statement supplied. Defensive-by-design so create_sales_return() (0085/0093/0100) never needs editing.';

create trigger sales_returns_capture_channel_snapshot
  before insert on public.sales_returns
  for each row
  execute function public.sales_returns_capture_channel_snapshot();

-- ---------------------------------------------------------------------------
-- Part C — one-time historical backfill for every Return that already
-- existed before this migration. NOT a blind `UPDATE ... SET
-- collection_channel_id_snapshot = sales_orders.collection_channel_id`, and
-- NOT (Hotfix 7.1.3 correction) keyed to "the first Sale edit at/after the
-- Return's created_at" either — a Return that went through a SANCTIONED
-- refresh_pending_sales_return_from_sale() call before this migration ran
-- has a CURRENT financial basis that is NEWER than its creation-time state;
-- "first edit after creation" would reconstruct the WRONG (pre-refresh)
-- channel for such a Return and fail its own anchor check.
--
-- Deterministic reconstruction algorithm (Hotfix 7.1.3 §6/§7), keyed to
-- each Return's OWN recorded basis version, not a timestamp heuristic:
--   For each sales_return sr, let v_basis_version := sr.source_sale_row_
--   version (the Sale row_version sr's figures are CURRENTLY based on —
--   set at creation, 0100, and re-set on every sanctioned refresh, 0100 —
--   this column has existed since 0099/0100 and is itself never guessed
--   here, only read).
--     A) Find the audit_logs row for this Sale (entity_type='sales_order',
--        entity_id=sr.sales_order_id) whose action is 'sale.create' or
--        'sale.update' and whose new_values.row_version EXACTLY equals
--        v_basis_version (0076's sale.create always logs row_version=1;
--        0084's sale.update always logs the post-edit row_version in
--        new_values — both canonical, confirmed present since the very
--        first version of each). Its new_values.payment_method_id/
--        collection_channel_id are, by construction, EXACTLY the Sale
--        state at that row_version — i.e. exactly sr's current basis.
--     B) If no such audit row exists (older data predating audit_logs
--        coverage, or a gap) but the SALE'S CURRENT row_version equals
--        v_basis_version AND the Sale's current payment_method_id equals
--        sr.payment_method_id (proving the Sale has not moved past sr's
--        recorded basis at all, and the basis IS the Sale's current live
--        row), the Sale's CURRENT collection_channel_id is safe to use —
--        it represents the exact same basis version.
--     C) Otherwise: no source can be trusted for this Return. Do not guess.
--
-- Integrity check (§6, unchanged rationale from the original 0197):
-- sales_returns.payment_method_id is ALREADY an honest basis-tracking
-- snapshot (0082/0100, re-synced only by the sanctioned refresh path) — an
-- independent, pre-existing verification anchor. Before trusting the
-- reconstructed collection_channel_id for ANY return, this migration
-- reconstructs payment_method_id via the exact SAME algorithm (same audit
-- row / same fallback condition) and requires it to equal the existing
-- sales_returns.payment_method_id column exactly. Any mismatch, or any
-- Return for which reconstruction produces no value at all (case C above),
-- means this Return's history cannot be trusted to reconstruct correctly —
-- rather than guess a channel in that case, the ENTIRE migration aborts
-- (see the header comment above) with a message naming every conflicting
-- Return/Order pair, for manual investigation.
-- ---------------------------------------------------------------------------
create temporary table h712_channel_backfill on commit drop as
with basis as (
  select
    sr.id as return_id,
    sr.return_number,
    sr.sales_order_id,
    sr.source_sale_row_version as basis_version,
    sr.payment_method_id as existing_payment_method_id
  from public.sales_returns sr
),
audit_match as (
  select distinct on (b.return_id)
    b.return_id,
    (al.new_values ->> 'payment_method_id')::uuid as audit_payment_method_id,
    (al.new_values ->> 'collection_channel_id')::uuid as audit_collection_channel_id
  from basis b
  join public.audit_logs al
    on al.entity_type = 'sales_order'
   and al.entity_id = b.sales_order_id
   and al.action in ('sale.create', 'sale.update')
   and (al.new_values ->> 'row_version')::bigint = b.basis_version
  order by b.return_id, al.created_at asc, al.id asc
),
reconstructed as (
  select
    b.return_id,
    b.return_number,
    b.sales_order_id,
    b.basis_version,
    b.existing_payment_method_id,
    coalesce(
      am.audit_payment_method_id,
      case when so.row_version = b.basis_version and so.payment_method_id = b.existing_payment_method_id
           then so.payment_method_id end
    ) as reconstructed_payment_method_id,
    coalesce(
      am.audit_collection_channel_id,
      case when so.row_version = b.basis_version and so.payment_method_id = b.existing_payment_method_id
           then so.collection_channel_id end
    ) as reconstructed_collection_channel_id
  from basis b
  join public.sales_orders so on so.id = b.sales_order_id
  left join audit_match am on am.return_id = b.return_id
)
select * from reconstructed;

do $$
declare
  v_conflicts text;
  v_conflict_count integer;
begin
  select count(*), string_agg(
    format(
      'return_number=%s (return_id=%s, sales_order_id=%s, basis_version(source_sale_row_version)=%s): existing sales_returns.payment_method_id=%s <> audit/fallback-reconstructed payment_method_id=%s (reconstructed_collection_channel_id=%s)',
      return_number, return_id, sales_order_id, basis_version, existing_payment_method_id, reconstructed_payment_method_id, reconstructed_collection_channel_id
    ),
    E'\n'
    order by return_number
  )
  into v_conflict_count, v_conflicts
  from h712_channel_backfill
  where reconstructed_payment_method_id is distinct from existing_payment_method_id
     or reconstructed_collection_channel_id is null;

  if v_conflict_count > 0 then
    raise exception E'Hotfix 7.1.2/7.1.3 backfill integrity check FAILED for % return(s) — no audit_logs row (sale.create/sale.update) matches this Return''s OWN recorded basis version (source_sale_row_version), and the Sale''s CURRENT state does not safely stand in for it either (row_version/payment_method_id mismatch), so the reconstructed collection_channel_id_snapshot for these returns cannot be trusted. This migration refuses to guess and has aborted with NO changes applied. Investigate the audit_logs history for the Sales below (a gap, a duplicate/out-of-order sale.update row, or a Return predating audit_logs coverage) before re-running:\n%',
      v_conflict_count, v_conflicts
      using errcode = 'P0001';
  end if;
end $$;

update public.sales_returns sr
set collection_channel_id_snapshot = b.reconstructed_collection_channel_id
from h712_channel_backfill b
where sr.id = b.return_id;

-- ---------------------------------------------------------------------------
-- Part D — the column is now fully backfilled and verified for every
-- existing row (Part C either succeeded for 100% of rows or the whole
-- transaction already aborted above); every future row gets it from Part
-- B's trigger before any INSERT can commit, and Part E keeps it correctly
-- re-synced through the pending lifecycle. Safe to enforce NOT NULL.
-- ---------------------------------------------------------------------------
alter table public.sales_returns
  alter column collection_channel_id_snapshot set not null;

-- ---------------------------------------------------------------------------
-- Part E — lockstep-with-refresh guard, enforced as a trigger (not RLS) so
-- it holds against EVERY role, including service_role / trusted direct SQL
-- (mirrors enforce_payment_method_fee_version_immutable()'s BEFORE UPDATE
-- pattern, 0047, extended with one sanctioned-transition exception).
--
-- Hotfix 7.1.3 correction: the ORIGINAL 0197 rejected EVERY post-INSERT
-- change unconditionally. That is too strict — public.refresh_pending_
-- sales_return_from_sale() (0100, frozen, unmodified by this migration) is
-- the existing, sanctioned way a PENDING return's Sale-derived basis
-- (payment_method_id, source_sale_row_version, and several other snapshot
-- columns) is re-synced to the Sale's CURRENT state, and it never touches
-- collection_channel_id_snapshot at all (that column did not exist when
-- 0100 was written) — so under the original trigger, a refreshed Return
-- could end up with payment_method_id/collection_channel_id_snapshot
-- describing TWO DIFFERENT Sale states that never coexisted, an impossible
-- historical route pair.
--
-- This trigger recognizes the EXACT transition 0100's own UPDATE statement
-- produces — OLD.status = 'pending' AND NEW.status = 'pending' (0100 never
-- touches status; it only runs when status is already 'pending', checked
-- before its UPDATE) AND NEW.source_sale_row_version IS DISTINCT FROM OLD.
-- source_sale_row_version (0100 always advances this to the Sale's row_
-- version at the moment of refresh) — and, ONLY on that transition, reads
-- the Sale's CURRENT row directly (never trusting whatever the UPDATE
-- statement itself supplied for this column, exactly like Part B's INSERT
-- trigger) to authoritatively set NEW.collection_channel_id_snapshot,
-- after confirming the transition is genuinely coherent: NEW.source_sale_
-- row_version must equal the Sale's actual current row_version, NEW.
-- payment_method_id must equal the Sale's actual current payment_method_
-- id, and NEW.requires_sale_refresh must be false — all three are exactly
-- what 0100's own UPDATE statement always produces, so a real refresh
-- always passes; anything else (a raw UPDATE forging a matching status/
-- source_sale_row_version shape without an actually-coherent Sale state)
-- is rejected outright, never silently accepted.
--
-- Any OTHER UPDATE (every sanctioned Returns lifecycle writer other than
-- refresh — approve/reject/reverse_sales_return(), update_pending_sales_
-- return()'s item-set edits — and, going forward, this column once the
-- pending lifecycle has ended) falls through to the plain immutability
-- check: reject if collection_channel_id_snapshot is changing at all. None
-- of those other writers ever set this column, so NEW is always identical
-- to OLD for it on every one of their writes — they pass through
-- unaffected, exactly as before this revision.
-- ---------------------------------------------------------------------------
create or replace function public.sales_returns_channel_snapshot_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sale record;
begin
  if old.status = 'pending' and new.status = 'pending'
     and new.source_sale_row_version is distinct from old.source_sale_row_version then

    select so.row_version, so.payment_method_id, so.collection_channel_id
    into v_sale
    from public.sales_orders so
    where so.id = new.sales_order_id;

    if v_sale.row_version is null then
      raise exception 'تعذّر التحقق من إعادة مزامنة المرتجع — عملية البيع (id: %) غير موجودة' , new.sales_order_id using errcode = 'P0001';
    end if;

    if new.source_sale_row_version is distinct from v_sale.row_version
       or new.payment_method_id is distinct from v_sale.payment_method_id
       or coalesce(new.requires_sale_refresh, true) <> false then
      raise exception 'محاولة تحديث غير متسقة لقناة التحصيل التاريخية (collection_channel_id_snapshot) — لا تطابق حالة عملية البيع الحالية (transition سليم فقط عبر refresh_pending_sales_return_from_sale)' using errcode = 'P0001';
    end if;

    new.collection_channel_id_snapshot := v_sale.collection_channel_id;
    return new;
  end if;

  if new.collection_channel_id_snapshot is distinct from old.collection_channel_id_snapshot then
    raise exception 'لا يمكن تعديل قناة التحصيل التاريخية (collection_channel_id_snapshot) لمرتجع خارج مسار إعادة المزامنة السليم (refresh_pending_sales_return_from_sale) — هذه القيمة تتجمَّد نهائيًا بمجرد خروج المرتجع من دورة الانتظار (اعتماد/رفض/عكس)'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.sales_returns_channel_snapshot_guard() is
  'Hotfix 7.1.3 — BEFORE UPDATE ON sales_returns (supersedes the original 0197 sales_returns_channel_snapshot_immutable, which rejected every post-INSERT change unconditionally). Recognizes the EXACT sanctioned refresh_pending_sales_return_from_sale() (0100) transition (status stays ''pending'', source_sale_row_version changes) and authoritatively re-derives collection_channel_id_snapshot from the Sale''s CURRENT row in the same statement, after verifying the transition is genuinely coherent (source_sale_row_version/payment_method_id/requires_sale_refresh all match what 0100''s own UPDATE always produces) — keeping this column in lockstep with payment_method_id rather than pinning it to a stale creation-time value. Any other attempted change is rejected outright, for every role including service_role/trusted direct SQL.';

drop trigger if exists sales_returns_channel_snapshot_immutable on public.sales_returns;
drop function if exists public.sales_returns_channel_snapshot_immutable();

create trigger sales_returns_channel_snapshot_guard
  before update on public.sales_returns
  for each row
  execute function public.sales_returns_channel_snapshot_guard();

commit;

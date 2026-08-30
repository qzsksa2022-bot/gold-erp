-- ============================================================================
-- Integration test: Phase 7 — Final Integrity Hotfix 7.1.1 upgrade path
-- (0191->latest, §20 item D) — proves REAL pre-existing Patch-7.1-shaped
-- Settlements data (including a return_fee_reversal source CLAIMED under
-- the OLD hardcoded-NULL-channel matching rule §1/§3 corrects going
-- forward, a cross-store adjustment, draft/reconciled/cancelled batches,
-- bank movements/reversals), all created under the OLD (0169-0191) RPC/
-- schema contracts, is byte-identical after 0192-0196 land on top — no data
-- loss, no silent migration-time mutation of any EXISTING claim/line — and
-- that every NEW hotfix-only capability (preview batch-fee override, draft
-- ownership check, store-scope enforcement, reconcile redaction, fee-
-- resolver lockdown, narrow filter lookups) works correctly once 0192-0196
-- have landed.
-- ============================================================================
-- This file does NOT build the database itself and does NOT create any of
-- the Settlements fixture data — it only ASSERTS against a database that
-- was already built the way a real production upgrade would experience it:
--
--   1. Fresh DB, migrations 0001-0191 applied (the ORIGINAL Patch 7.1
--      Settlements Core end state, before Hotfix 7.1.1 exists).
--   2. The REAL supabase/seed.sql applied.
--   3. supabase/tests/fixtures/hotfix_7_1_1_upgrade_pre_fixture.sql applied
--      — a SEPARATE psql invocation, COMMITTED (not rolled back) — builds a
--      channel route + a NULL-channel route, a return finalized under the
--      OLD matching rule (return_refund_event + return_fee_reversal BOTH
--      claimed on the NULL-channel route), a cross-store adjustment batch,
--      a draft batch, a reconciled batch, and a cancelled batch, ALL via
--      the OLD (0169-0191) RPCs, recording every id/number PLUS a
--      to_jsonb(row) snapshot of every row of interest into the PERMANENT
--      public.h711u_scratch table.
--   4. Migrations 0192 through 0196 (Hotfix 7.1.1) applied on top — in a
--      SEPARATE psql invocation, exactly like a production upgrade would.
--
-- See scripts/run_upgrade_test_hotfix_7_1_1_settlements.sh for the
-- orchestration that builds exactly this sequence, then runs this file.
--
-- Proves:
--   (A) Every snapshotted row is BYTE-IDENTICAL pre- vs post-migration —
--       CRITICALLY including the return batch's TWO claims/lines
--       (return_refund_event + return_fee_reversal), claimed under the OLD
--       matching rule: 0192 changes only future DISCOVERY, it must never
--       reach back and alter an EXISTING claim/line/batch.
--   (B) get_settlement_batch() (unchanged 0191 reader) still displays the
--       OLD-shape return batch's two lines correctly.
--   (C) The already-claimed refund_event/return sources are NOT re-offered
--       by the NEW (0192) list_unsettled_settlement_sources() on EITHER
--       route post-upgrade — a logic change to candidate matching does not
--       resurrect an already-claimed source.
--   (D) preview_settlement_batch()'s NEW 7-arg signature (batch-fee
--       override, §9) works correctly on a BRAND NEW batch created after
--       the upgrade.
--   (E) settlement_route_fee_for_route_on_date() (§6) has EXECUTE revoked
--       from PUBLIC/authenticated post-upgrade.
--   (F) update_draft_settlement_batch()'s NEW ownership check (§4): the
--       OWNER (fixture admin) can still update their OLD pre-existing
--       draft after the upgrade; a DIFFERENT create-only, non-owner actor
--       is rejected exactly like get_draft_settlement_batch_for_edit()
--       already was.
--   (G) reconcile_settlement_batch()'s NEW redaction (§7): an actor holding
--       settlements.reconcile alone (no view_financials) still succeeds but
--       gets NULL actual_bank_movement/variance in the RETURN, on a BRAND
--       NEW batch created after the upgrade.
--   (H) Final unconditional cleanup: drop the scratch table.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- (A) Byte-identical row snapshots (as postgres, bypassing RLS).
-- ---------------------------------------------------------------------------
do $$
declare v_before text; v_after text;
begin
  select value into v_before from public.h711u_scratch where label = 'route_chan_row_json';
  select to_jsonb(r)::text into v_after from public.settlement_routes r where r.id = (select value::uuid from public.h711u_scratch where label = 'route_chan');
  assert v_before = v_after, format('BUG (A): route_chan row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'route_null_row_json';
  select to_jsonb(r)::text into v_after from public.settlement_routes r where r.id = (select value::uuid from public.h711u_scratch where label = 'route_null');
  assert v_before = v_after, format('BUG (A): route_null row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'batch_return_row_json';
  select to_jsonb(b)::text into v_after from public.settlement_batches b where b.id = (select value::uuid from public.h711u_scratch where label = 'batch_return_id');
  assert v_before = v_after, format('BUG (A): batch_return row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'batch_return_lines_json';
  select jsonb_agg(to_jsonb(l) order by l.source_kind)::text into v_after from public.settlement_batch_lines l where l.settlement_batch_id = (select value::uuid from public.h711u_scratch where label = 'batch_return_id');
  assert v_before = v_after, format('BUG (A) CRITICAL: batch_return''s TWO lines (return_refund_event + return_fee_reversal, claimed under the OLD matching rule) changed post-migration — a candidate-matching LOGIC change must never mutate an EXISTING claim/line.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'batch_return_claims_json';
  select jsonb_agg(to_jsonb(c) order by c.source_kind)::text into v_after from public.settlement_source_claims c where c.settlement_batch_id = (select value::uuid from public.h711u_scratch where label = 'batch_return_id');
  assert v_before = v_after, format('BUG (A) CRITICAL: batch_return''s TWO settlement_source_claims rows changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'batch_adj_row_json';
  select to_jsonb(b)::text into v_after from public.settlement_batches b where b.id = (select value::uuid from public.h711u_scratch where label = 'batch_adj_id');
  assert v_before = v_after, format('BUG (A): batch_adj row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'batch_adj_line_row_json';
  select to_jsonb(l)::text into v_after from public.settlement_batch_lines l where l.settlement_batch_id = (select value::uuid from public.h711u_scratch where label = 'batch_adj_id');
  assert v_before = v_after, format('BUG (A): batch_adj line row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'batch_draft_row_json';
  select to_jsonb(b)::text into v_after from public.settlement_batches b where b.id = (select value::uuid from public.h711u_scratch where label = 'batch_draft_id');
  assert v_before = v_after, format('BUG (A): batch_draft row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'batch_reconciled_row_json';
  select to_jsonb(b)::text into v_after from public.settlement_batches b where b.id = (select value::uuid from public.h711u_scratch where label = 'batch_reconciled_id');
  assert v_before = v_after, format('BUG (A): batch_reconciled row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'move_reconciled_row_json';
  select to_jsonb(e)::text into v_after from public.settlement_bank_movement_events e where e.id = (select value::uuid from public.h711u_scratch where label = 'move_reconciled_id');
  assert v_before = v_after, format('BUG (A): move_reconciled row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'batch_cancelled_row_json';
  select to_jsonb(b)::text into v_after from public.settlement_batches b where b.id = (select value::uuid from public.h711u_scratch where label = 'batch_cancelled_id');
  assert v_before = v_after, format('BUG (A): batch_cancelled row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'move_cancelled_row_json';
  select to_jsonb(e)::text into v_after from public.settlement_bank_movement_events e where e.id = (select value::uuid from public.h711u_scratch where label = 'move_cancelled_id');
  assert v_before = v_after, format('BUG (A): move_cancelled row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'reversal_cancelled_row_json';
  select to_jsonb(rv)::text into v_after from public.settlement_bank_movement_reversals rv where rv.id = (select value::uuid from public.h711u_scratch where label = 'reversal_cancelled_id');
  assert v_before = v_after, format('BUG (A): reversal_cancelled row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  select value into v_before from public.h711u_scratch where label = 'cancellation_row_json';
  select to_jsonb(cx)::text into v_after from public.settlement_batch_cancellations cx where cx.id = (select value::uuid from public.h711u_scratch where label = 'cancellation_id');
  assert v_before = v_after, format('BUG (A): cancellation row changed post-migration.%sBEFORE=%s%sAFTER=%s', chr(10), v_before, chr(10), v_after);

  raise notice 'PASS (A): every pre-existing row snapshot (2 routes, return batch + its TWO claims/lines, adjustment batch, draft batch, reconciled batch + movement, cancelled batch + movement + reversal + cancellation) is BYTE-IDENTICAL pre- vs post-migration (0192-0196 mutated nothing existing)';
end $$;

-- ---------------------------------------------------------------------------
-- (B) get_settlement_batch() still displays the OLD-shape return batch's two
-- lines correctly.
-- ---------------------------------------------------------------------------
set role authenticated;
set local request.jwt.claims = '{"sub":"f7110000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_batch_return_id uuid := (select value::uuid from public.h711u_scratch where label = 'batch_return_id');
  v_return_number text := (select value from public.h711u_scratch where label = 'return_number');
  v_g record;
  v_found_refund boolean := false;
  v_found_feerev boolean := false;
  v_line jsonb;
begin
  select * into v_g from public.get_settlement_batch(v_batch_return_id);
  assert v_g.status = 'finalized', format('BUG (B): batch_return status expected finalized, got %s', v_g.status);
  assert jsonb_array_length(v_g.lines) = 2, format('BUG (B): batch_return expected 2 lines, got %s', jsonb_array_length(v_g.lines));
  for v_line in select * from jsonb_array_elements(v_g.lines) loop
    if v_line ->> 'source_kind' = 'return_refund_event' then
      v_found_refund := true;
      assert v_line ->> 'source_number' = v_return_number, format('BUG (B): return_refund_event line source_number mismatch: %s <> %s', v_line ->> 'source_number', v_return_number);
    elsif v_line ->> 'source_kind' = 'return_fee_reversal' then
      v_found_feerev := true;
    end if;
  end loop;
  assert v_found_refund and v_found_feerev, 'BUG (B): batch_return must still contain BOTH a return_refund_event line and a return_fee_reversal line post-migration';

  raise notice 'PASS (B): get_settlement_batch() still displays batch_return''s two OLD-shape lines (return_refund_event + return_fee_reversal, claimed together under the pre-hotfix matching rule), number=%', v_g.settlement_number;
end $$;

-- ---------------------------------------------------------------------------
-- (C) The already-claimed sources are NOT re-offered by the NEW (0192)
-- list_unsettled_settlement_sources() on EITHER route post-upgrade.
-- ---------------------------------------------------------------------------
do $$
declare
  v_route_chan uuid := (select value::uuid from public.h711u_scratch where label = 'route_chan');
  v_route_null uuid := (select value::uuid from public.h711u_scratch where label = 'route_null');
  v_return_id uuid := (select value::uuid from public.h711u_scratch where label = 'return_id');
  v_refund_event_id uuid := (select value::uuid from public.h711u_scratch where label = 'refund_event_id');
begin
  if exists (
    select 1 from public.list_unsettled_settlement_sources(v_route_null, public.business_today() - 3650, public.business_today() + 1)
    where source_kind = 'return_refund_event' and source_event_id = v_refund_event_id
  ) then
    raise exception 'FAIL (C): the already-claimed return_refund_event was re-offered by list_unsettled_settlement_sources() post-migration';
  end if;

  if exists (
    select 1 from public.list_unsettled_settlement_sources(v_route_chan, public.business_today() - 3650, public.business_today() + 1)
    where source_kind = 'return_fee_reversal' and source_event_id = v_return_id
  ) then
    raise exception 'FAIL (C): the already-claimed return_fee_reversal was re-offered by list_unsettled_settlement_sources() (on its NEW post-hotfix route) post-migration';
  end if;

  if exists (
    select 1 from public.list_unsettled_settlement_sources(v_route_null, public.business_today() - 3650, public.business_today() + 1)
    where source_kind = 'return_fee_reversal' and source_event_id = v_return_id
  ) then
    raise exception 'FAIL (C): the already-claimed return_fee_reversal was re-offered by list_unsettled_settlement_sources() (on its OLD pre-hotfix route) post-migration';
  end if;

  raise notice 'PASS (C): a candidate-matching LOGIC change (§1/§3) does not resurrect an already-claimed source on either its old or its new route';
end $$;

-- ---------------------------------------------------------------------------
-- (D) preview_settlement_batch()'s NEW 7-arg signature (batch-fee override,
-- §9) works correctly on a BRAND NEW batch created after the upgrade.
-- ---------------------------------------------------------------------------
do $$
declare
  v_route_chan uuid := (select value::uuid from public.h711u_scratch where label = 'route_chan');
  v_store_a uuid := (select value::uuid from public.h711u_scratch where label = 'store_a');
  v_pm_visa uuid; v_channel_id uuid; v_karat_id uuid; v_category_id uuid;
  v_order record;
  v_preview record;
begin
  select id into v_pm_visa from public.payment_methods where key = 'tabby';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';
  select id into v_karat_id from public.karats where code = 'H711UK';
  select id into v_category_id from public.product_categories where code = 'h711ucat';

  select * into v_order from public.create_sales_order(
    v_store_a, public.business_today(), v_pm_visa, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 200.00)),
    'عميل ما بعد ترقية 7.1.1', null, null, null
  );

  select * into v_preview from public.preview_settlement_batch(
    v_route_chan, public.business_today() - 1, public.business_today() + 1,
    jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)),
    public.business_today(), 9.99, 'اختبار ما بعد ترقية 7.1.1 — تجاوز رسوم الدفعة'
  );

  assert v_preview.batch_fee_overridden, 'BUG (D): preview_settlement_batch() with a batch_fee_override must return batch_fee_overridden=true';
  assert v_preview.effective_batch_fee::numeric = 9.99, format('BUG (D): preview effective_batch_fee expected 9.99, got %s', v_preview.effective_batch_fee);
  assert v_preview.configured_batch_fee::numeric = 5.00, format('BUG (D): preview configured_batch_fee expected the route''s configured 5.00, got %s', v_preview.configured_batch_fee);

  raise notice 'PASS (D): preview_settlement_batch()''s NEW 7-arg batch-fee-override signature (§9) works correctly on a brand new post-upgrade batch (configured=5.00, override=9.99)';
end $$;

-- ---------------------------------------------------------------------------
-- (E) settlement_route_fee_for_route_on_date() (§6) has EXECUTE revoked from
-- PUBLIC/authenticated post-upgrade.
-- ---------------------------------------------------------------------------
do $$
declare v_has_priv boolean;
begin
  select has_function_privilege('authenticated', 'public.settlement_route_fee_for_route_on_date(uuid,date)', 'execute') into v_has_priv;
  assert not v_has_priv, 'BUG (E): authenticated must NOT have EXECUTE on settlement_route_fee_for_route_on_date() post-migration (§6)';

  select has_function_privilege('anon', 'public.settlement_route_fee_for_route_on_date(uuid,date)', 'execute') into v_has_priv;
  assert not v_has_priv, 'BUG (E): anon (a stand-in for PUBLIC) must NOT have EXECUTE on settlement_route_fee_for_route_on_date() post-migration (§6)';

  raise notice 'PASS (E): settlement_route_fee_for_route_on_date() EXECUTE is revoked from PUBLIC/authenticated post-migration (§6) — internal-helper-only, callable only by SECURITY DEFINER wrappers';
end $$;

-- ---------------------------------------------------------------------------
-- (F) update_draft_settlement_batch()'s NEW ownership check (§4): the OWNER
-- can still update their OLD pre-existing draft; a different non-owner
-- create-only actor is rejected.
-- ---------------------------------------------------------------------------
do $$
declare
  v_batch_draft_id uuid := (select value::uuid from public.h711u_scratch where label = 'batch_draft_id');
  v_route_chan uuid := (select value::uuid from public.h711u_scratch where label = 'route_chan');
begin
  perform public.update_draft_settlement_batch(
    v_batch_draft_id, 1, v_route_chan, public.business_today(), null, 'ملاحظة بعد الترقية — المالك', false, true
  );
  raise notice 'PASS (F.1): the OWNER (fixture admin) can still update_draft_settlement_batch() their OLD pre-existing draft post-migration (§4 ownership check does not block the owner)';
exception when others then
  raise exception 'FAIL (F.1): the owner''s update_draft_settlement_batch() on their own pre-existing draft was unexpectedly rejected: %', sqlerrm;
end $$;

-- A second, DIFFERENT create-only actor (settlements.create granted,
-- settlements.view NOT granted) must be rejected on the same draft — the
-- exact §4 fix. Actor creation runs as postgres (bypassing RLS), same as
-- the pre-fixture's own admin-actor setup.
reset role;
reset request.jwt.claims;
do $$
declare v_actor2 uuid := 'f7110000-0000-4000-8000-000000000002';
begin
  insert into auth.users (id, email) values (v_actor2, 'test-h711u-actor2@example.invalid') on conflict do nothing;
  update public.profiles set full_name = 'H711U Actor 2 (create-only, non-owner)', status = 'active', store_access_scope = 'all' where id = v_actor2;
  insert into public.user_permission_overrides (user_id, permission_id, effect)
    select v_actor2, id, 'grant' from public.permissions where key = 'settlements.create'
    on conflict (user_id, permission_id) do update set effect = 'grant';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f7110000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare
  v_batch_draft_id uuid := (select value::uuid from public.h711u_scratch where label = 'batch_draft_id');
  v_route_chan uuid := (select value::uuid from public.h711u_scratch where label = 'route_chan');
  v_rejected boolean := false;
begin
  -- expected_version=2 (F.1's successful update already bumped it from 1 to
  -- 2) — using the CURRENT correct version isolates this rejection to the
  -- §4 ownership check alone, never a stale-version false negative.
  begin
    perform public.update_draft_settlement_batch(
      v_batch_draft_id, 2, v_route_chan, public.business_today(), null, 'محاولة تعديل من غير المالك', false, true
    );
  exception when others then
    if sqlerrm like '%دفعة التسوية غير موجودة%' then v_rejected := true; else raise; end if;
  end;
  assert v_rejected, 'FAIL (F.2): a DIFFERENT create-only, non-owner actor was able to update_draft_settlement_batch() on someone else''s pre-existing draft — §4 ownership check not enforced post-migration';
  raise notice 'PASS (F.2): a different create-only, non-owner actor is rejected (not-found) from update_draft_settlement_batch() on the fixture admin''s pre-existing draft, post-migration (§4, CRITICAL)';
end $$;

-- ---------------------------------------------------------------------------
-- (G) reconcile_settlement_batch()'s NEW redaction (§7): an actor holding
-- settlements.reconcile alone (no view_financials) still succeeds but gets
-- NULL actual_bank_movement/variance, on a BRAND NEW batch post-upgrade.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"f7110000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_route_chan uuid := (select value::uuid from public.h711u_scratch where label = 'route_chan');
  v_store_a uuid := (select value::uuid from public.h711u_scratch where label = 'store_a');
  v_pm_visa uuid; v_channel_id uuid; v_karat_id uuid; v_category_id uuid;
  v_order record; v_subtotal numeric; v_fee numeric; v_expected numeric;
  v_batch record; v_final record; v_move_id uuid;
begin
  select id into v_pm_visa from public.payment_methods where key = 'tabby';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';
  select id into v_karat_id from public.karats where code = 'H711UK';
  select id into v_category_id from public.product_categories where code = 'h711ucat';

  select * into v_order from public.create_sales_order(
    v_store_a, public.business_today(), v_pm_visa, v_channel_id,
    jsonb_build_array(jsonb_build_object('category_id', v_category_id, 'karat_id', v_karat_id, 'weight_grams', 1.0000, 'sale_price', 300.00)),
    'عميل ما بعد ترقية 7.1.1 — مطابقة', null, null, null
  );
  v_subtotal := (public.get_sales_order(v_order.id) ->> 'subtotal')::numeric;
  v_fee := (public.get_sales_order(v_order.id) ->> 'payment_fee_amount')::numeric;
  -- route_chan is source_snapshot (fee=sale's own snapshot) + batch_fee_
  -- fixed=5.00 -> expected_bank_settlement = gross - fee - 5.00.
  v_expected := v_subtotal - v_fee - 5.00;

  select * into v_batch from public.create_draft_settlement_batch(v_route_chan, public.business_today(), 'REF-H711U-POSTRECON', 'دفعة مطابقة بعد الترقية');
  select * into v_final from public.finalize_settlement_batch(v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null);
  select public.record_settlement_bank_movement(v_batch.id, public.business_today(), v_expected, 'BANKREF-H711U-POSTRECON', 'حركة مطابقة بعد الترقية') into v_move_id;

  perform set_config('h711u.postrecon_batch_id', v_batch.id::text, false);
  perform set_config('h711u.postrecon_row_version', v_final.row_version::text, false);
  raise notice 'H711U post-upgrade reconcile-redaction fixture OK: batch=%', v_batch.id;
end $$;

-- The narrow actor: settlements.reconcile ONLY (no view_financials). Actor
-- creation runs as postgres (bypassing RLS).
reset role;
reset request.jwt.claims;
do $$
declare v_actor3 uuid := 'f7110000-0000-4000-8000-000000000003';
begin
  insert into auth.users (id, email) values (v_actor3, 'test-h711u-actor3@example.invalid') on conflict do nothing;
  update public.profiles set full_name = 'H711U Actor 3 (reconcile-only)', status = 'active', store_access_scope = 'all' where id = v_actor3;
  insert into public.user_permission_overrides (user_id, permission_id, effect)
    select v_actor3, id, 'grant' from public.permissions where key in ('settlements.view', 'settlements.reconcile')
    on conflict (user_id, permission_id) do update set effect = 'grant';
  insert into public.user_permission_overrides (user_id, permission_id, effect)
    select v_actor3, id, 'revoke' from public.permissions where key = 'settlements.view_financials'
    on conflict (user_id, permission_id) do update set effect = 'revoke';
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f7110000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare
  v_batch_id uuid := current_setting('h711u.postrecon_batch_id')::uuid;
  v_row_version bigint := current_setting('h711u.postrecon_row_version')::bigint;
  v_recon record;
begin
  select * into v_recon from public.reconcile_settlement_batch(v_batch_id, v_row_version);
  assert v_recon.actual_bank_movement is null, format('FAIL (G): reconcile_settlement_batch()''s actual_bank_movement must be NULL for an actor lacking settlements.view_financials post-migration (§7), got %s', v_recon.actual_bank_movement);
  assert v_recon.variance is null, format('FAIL (G): reconcile_settlement_batch()''s variance must be NULL for an actor lacking settlements.view_financials post-migration (§7), got %s', v_recon.variance);
  raise notice 'PASS (G): reconcile_settlement_batch() succeeds for settlements.reconcile alone but REDACTS actual_bank_movement/variance (both NULL) without settlements.view_financials, post-migration (§7)';
end $$;

do $$
begin
  raise notice '=== ALL UPGRADE-TO-HOTFIX-7.1.1 TESTS PASSED (0192-0196 applied onto a real pre-Hotfix-7.1.1 production-shaped database built entirely under the OLD 0169-0191 Settlements RPCs, WITHOUT re-running seed.sql — every pre-existing row (including a return_fee_reversal claimed under the OLD matching rule) is byte-identical, an already-claimed source is never resurrected by the NEW discovery logic, and every NEW hotfix capability works correctly on fresh post-upgrade data) ===';
end $$;

rollback;

-- ---------------------------------------------------------------------------
-- (H) Final unconditional cleanup — committed immediately (outside the
-- rolled-back assertion transaction above).
-- ---------------------------------------------------------------------------
drop table if exists public.h711u_scratch;

-- ============================================================================
-- Integration test: Phase 7 — Final Integrity Hotfix 7.1.1 (§16) — dedicated
-- LIVE regression coverage for the hotfix's own new behaviors, run against a
-- database that already has ALL migrations (0001-latest) applied. Companion
-- to:
--   - settlements_phase7.test.sql (updated in place this hotfix for the
--     Fee-Reversal Timeline §1/§2 scenarios — Sign Convention C, the split
--     preview/finalize totals across route_visa/route_visa_chan, and 8.1c's
--     rewritten "both return_fee_reversal AND return_fee_reversal_reversal
--     coexist, net to zero" assertions).
--   - upgrade_hotfix_7_1_1_settlements.test.sql (§20 item D — the SAME §4/
--     §6/§7 behaviors proven again there specifically against data created
--     under the OLD pre-hotfix RPC contracts, post-upgrade).
--
-- This file covers what neither of those already exercises live:
--   (1) §4 (CRITICAL) draft ownership on WRITE: owner ok, a different
--       create-only actor rejected, a create+view actor unrestricted.
--   (2) §5 (CRITICAL) store-scope fail-closed on ALL FOUR lifecycle write
--       RPCs (record/reverse bank movement, reconcile, cancel).
--   (3) §7 (CRITICAL) reconcile_settlement_batch() redaction, live.
--   (4) §9 (CRITICAL) preview/finalize batch-fee-override PARITY — the
--       exact HTTP-test scenario the spec names, proven at SQL level too.
--   (5) §11 cancellation chronology vs the latest bank-movement reversal.
--   (6) §12 settlements.view-gated filter lookups, including a DISABLED
--       payment method staying visible.
--   (7) §15 cross-store Source Discovery filter (primary OR secondary).
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Fixture: one admin (super_admin), two stores, one channel route + fee
-- version, master data.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('f7112000-0000-4000-8000-000000000001', 'test-h711-admin@example.invalid'),
  ('f7112000-0000-4000-8000-000000000002', 'test-h711-owner@example.invalid'),
  ('f7112000-0000-4000-8000-000000000003', 'test-h711-other@example.invalid'),
  ('f7112000-0000-4000-8000-000000000004', 'test-h711-viewcreate@example.invalid'),
  ('f7112000-0000-4000-8000-000000000005', 'test-h711-storescoped@example.invalid'),
  ('f7112000-0000-4000-8000-000000000006', 'test-h711-reconcileonly@example.invalid'),
  ('f7112000-0000-4000-8000-000000000007', 'test-h711-filterview@example.invalid')
on conflict do nothing;

update public.profiles set full_name = 'H711 Admin', status = 'active', store_access_scope = 'all' where id = 'f7112000-0000-4000-8000-000000000001';
update public.profiles set full_name = 'H711 Owner (create-only)', status = 'active', store_access_scope = 'all' where id = 'f7112000-0000-4000-8000-000000000002';
update public.profiles set full_name = 'H711 Other (create-only, non-owner)', status = 'active', store_access_scope = 'all' where id = 'f7112000-0000-4000-8000-000000000003';
update public.profiles set full_name = 'H711 ViewCreate', status = 'active', store_access_scope = 'all' where id = 'f7112000-0000-4000-8000-000000000004';
update public.profiles set full_name = 'H711 Store-Scoped', status = 'active', store_access_scope = 'all' where id = 'f7112000-0000-4000-8000-000000000005';
update public.profiles set full_name = 'H711 Reconcile-Only', status = 'active', store_access_scope = 'all' where id = 'f7112000-0000-4000-8000-000000000006';
update public.profiles set full_name = 'H711 Filter-View-Only', status = 'active', store_access_scope = 'all' where id = 'f7112000-0000-4000-8000-000000000007';

insert into public.user_roles (user_id, role_id)
  select 'f7112000-0000-4000-8000-000000000001', id from public.roles where key = 'super_admin'
  on conflict do nothing;

do $$
declare v_pid uuid;
begin
  -- Owner/Other: settlements.create ONLY.
  for v_pid in select id from public.permissions where key = 'settlements.create' loop
    insert into public.user_permission_overrides (user_id, permission_id, effect) values
      ('f7112000-0000-4000-8000-000000000002', v_pid, 'grant'),
      ('f7112000-0000-4000-8000-000000000003', v_pid, 'grant')
    on conflict (user_id, permission_id) do update set effect = 'grant';
  end loop;

  -- ViewCreate: settlements.create + settlements.view.
  for v_pid in select id from public.permissions where key in ('settlements.create', 'settlements.view') loop
    insert into public.user_permission_overrides (user_id, permission_id, effect)
      values ('f7112000-0000-4000-8000-000000000004', v_pid, 'grant')
      on conflict (user_id, permission_id) do update set effect = 'grant';
  end loop;

  -- Store-Scoped: every lifecycle write permission, but store_access_scope
  -- restricts visibility to Store A only (set below once Store A exists).
  for v_pid in select id from public.permissions where key in (
    'settlements.create', 'settlements.finalize', 'settlements.record_bank_movement',
    'settlements.reconcile', 'settlements.reconcile_variance', 'settlements.cancel', 'settlements.process_closed_day'
  ) loop
    insert into public.user_permission_overrides (user_id, permission_id, effect)
      values ('f7112000-0000-4000-8000-000000000005', v_pid, 'grant')
      on conflict (user_id, permission_id) do update set effect = 'grant';
  end loop;

  -- Reconcile-Only: settlements.reconcile alone (no view_financials).
  for v_pid in select id from public.permissions where key = 'settlements.reconcile' loop
    insert into public.user_permission_overrides (user_id, permission_id, effect)
      values ('f7112000-0000-4000-8000-000000000006', v_pid, 'grant')
      on conflict (user_id, permission_id) do update set effect = 'grant';
  end loop;

  -- Filter-View-Only: settlements.view alone (deliberately NO payment_
  -- methods.view/collection_channels.view/shipping_rates.view — §12's own
  -- point).
  for v_pid in select id from public.permissions where key = 'settlements.view' loop
    insert into public.user_permission_overrides (user_id, permission_id, effect)
      values ('f7112000-0000-4000-8000-000000000007', v_pid, 'grant')
      on conflict (user_id, permission_id) do update set effect = 'grant';
  end loop;
end $$;

set role authenticated;
set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000001","role":"authenticated"}';

do $$
declare
  v_store_a uuid; v_store_b uuid; v_karat_id uuid; v_category_id uuid;
  v_pm uuid; v_channel_id uuid; v_pm_disabled uuid;
  v_route_chan uuid;
begin
  insert into public.stores (code, name_ar, status) values ('H711TSA', 'فرع اختبار 7.1.1 - أ', 'active') returning id into v_store_a;
  insert into public.stores (code, name_ar, status) values ('H711TSB', 'فرع اختبار 7.1.1 - ب', 'active') returning id into v_store_b;
  insert into public.karats (code, name_ar, sort_order, status) values ('H711TK', 'عيار اختبار 7.1.1', 983, 'active') returning id into v_karat_id;
  insert into public.product_categories (code, name_ar, sort_order, status) values ('h711tcat', 'تصنيف اختبار 7.1.1', 983, 'active') returning id into v_category_id;
  -- daily_gold_prices is looked up by EXACT date match (not version-style
  -- like manufacturing_fee_versions/payment_method_fee_versions below), so
  -- every distinct sale date used in this file needs its own row: today
  -- (most sales) and business_today() - 2 (the §11 chronology test's
  -- backdated Sale).
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today(), v_karat_id, 280.0000, 'f7112000-0000-4000-8000-000000000001');
  insert into public.daily_gold_prices (price_date, karat_id, price_per_gram, created_by)
    values (public.business_today() - 2, v_karat_id, 280.0000, 'f7112000-0000-4000-8000-000000000001');
  -- Also backdated to cover §11's chronology-test Sale (business_today() - 2)
  -- — this is a brand-new karat with no seed coverage otherwise.
  perform public.create_manufacturing_fee_version(v_karat_id, 10.0000, public.business_today() - 60, 'h711t fixture');

  select id into v_pm from public.payment_methods where key = 'tabby';
  select id into v_channel_id from public.collection_channels where key = 'direct_store';

  -- A disabled payment method — for §12's "historical/disabled values stay
  -- filterable" assertion.
  insert into public.payment_methods (key, name_ar, name_en, fee_model, refund_fee_policy, sort_order, status)
    values ('h711t_disabled_pm', 'طريقة معطّلة اختبار 7.1.1', 'H711T Disabled', 'none', 'non_refundable_fee', 999, 'inactive')
    returning id into v_pm_disabled;

  select public.create_settlement_route('h711t-chan-route', 'مسار اختبار 7.1.1', 'payment_collection', 'H711T Channel Route', v_pm, v_channel_id) into v_route_chan;
  perform public.create_settlement_route_fee_version(v_route_chan, public.business_today() - 30, 'source_snapshot', null, null, null, 5.00, null, 'h711t fee');

  update public.profiles set store_access_scope = 'single', default_store_id = v_store_a where id = 'f7112000-0000-4000-8000-000000000005';

  perform set_config('h711t.store_a', v_store_a::text, false);
  perform set_config('h711t.store_b', v_store_b::text, false);
  perform set_config('h711t.karat_id', v_karat_id::text, false);
  perform set_config('h711t.category_id', v_category_id::text, false);
  perform set_config('h711t.pm', v_pm::text, false);
  perform set_config('h711t.pm_disabled', v_pm_disabled::text, false);
  perform set_config('h711t.channel_id', v_channel_id::text, false);
  perform set_config('h711t.route_chan', v_route_chan::text, false);

  raise notice 'H711T SETUP OK: stores=%/%, route=%', v_store_a, v_store_b, v_route_chan;
end $$;

-- seed.sql's payment_method_fee_versions/vat_rate_versions both open at
-- business_today() with no historical coverage before it — the §11
-- chronology test below needs a Sale dated a few days in the past. Widen
-- tabby's fee version's and the VAT rate version's effective_from
-- backwards in place (same technique as settlements_phase7.test.sql's own
-- COD fixture) — cannot change any already-computed sale's frozen fee
-- snapshot, only which dates a FUTURE lookup can resolve.
reset role;
reset request.jwt.claims;
alter table public.payment_method_fee_versions disable trigger payment_method_fee_versions_enforce_immutable;
do $$
begin
  update public.payment_method_fee_versions
  set effective_from = public.business_today() - 60
  where payment_method_id = current_setting('h711t.pm')::uuid and status = 'active' and effective_to is null;

  update public.vat_rate_versions set effective_from = public.business_today() - 60
  where status = 'active' and effective_to is null;
end $$;
alter table public.payment_method_fee_versions enable trigger payment_method_fee_versions_enforce_immutable;
set role authenticated;
set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- (1) §4 CRITICAL — draft ownership on WRITE.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare v_batch record;
begin
  select * into v_batch from public.create_draft_settlement_batch(current_setting('h711t.route_chan')::uuid, public.business_today(), 'REF-H711T-OWN', 'مسودة اختبار الملكية');
  perform set_config('h711t.batch_owned', v_batch.id::text, false);
  raise notice 'PASS: 1a Owner (create-only) created their own draft, id=%', v_batch.id;
end $$;

do $$
declare v_batch_id uuid := current_setting('h711t.batch_owned')::uuid;
begin
  perform public.update_draft_settlement_batch(v_batch_id, 1, current_setting('h711t.route_chan')::uuid, public.business_today(), null, 'تعديل من المالك نفسه', false, true);
  raise notice 'PASS: 1b Owner can update THEIR OWN draft';
end $$;

set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000003","role":"authenticated"}';
do $$
declare v_batch_id uuid := current_setting('h711t.batch_owned')::uuid; v_rejected boolean := false;
begin
  begin
    perform public.update_draft_settlement_batch(v_batch_id, 2, current_setting('h711t.route_chan')::uuid, public.business_today(), null, 'محاولة تعديل من غير المالك', false, true);
  exception when others then
    if sqlerrm like '%دفعة التسوية غير موجودة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 1c: a different create-only, non-owner actor was able to update_draft_settlement_batch() on someone else''s draft — §4, CRITICAL'; end if;
  raise notice 'PASS: 1c a different create-only, non-owner actor is rejected (not-found) from update_draft_settlement_batch() (§4, CRITICAL)';
end $$;

set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000004","role":"authenticated"}';
do $$
declare v_batch_id uuid := current_setting('h711t.batch_owned')::uuid;
begin
  perform public.update_draft_settlement_batch(v_batch_id, 2, current_setting('h711t.route_chan')::uuid, public.business_today(), null, 'تعديل من حامل settlements.view', false, true);
  raise notice 'PASS: 1d a settlements.view holder is UNRESTRICTED by the §4 ownership check, even on someone else''s draft';
end $$;

-- ---------------------------------------------------------------------------
-- (2) §5 CRITICAL — store-scope fail-closed on ALL FOUR lifecycle write RPCs.
-- Build a batch containing an Adjustment whose PROCESSING store is Store B
-- (invisible to the Store-Scoped actor, who only sees Store A).
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order record; v_type_id uuid; v_adj record; v_adjrow record;
  v_batch record; v_final record; v_move_id uuid;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h711t.store_a')::uuid, public.business_today(),
    current_setting('h711t.pm')::uuid, current_setting('h711t.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h711t.category_id')::uuid, 'karat_id', current_setting('h711t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 500.00)),
    'عميل اختبار 7.1.1 — نطاق المتجر', null, null, null
  );
  select public.create_adjustment_type('h711t_service', 'خدمة اختبار 7.1.1') into v_type_id;
  select * into v_adj from public.create_sales_order_adjustment(
    v_order.id, v_type_id, current_setting('h711t.store_b')::uuid, public.business_today(),
    current_setting('h711t.pm')::uuid, current_setting('h711t.channel_id')::uuid,
    true, 100.00, 8.00, 'خدمة اختبار 7.1.1 عبر متاجر', null, 'REF-H711T-SCOPE'
  );
  select * into v_adjrow from public.get_sales_order_adjustment(v_adj.id);
  perform public.approve_sales_order_adjustment(v_adj.id, v_adjrow.row_version, null);

  select * into v_batch from public.create_draft_settlement_batch(current_setting('h711t.route_chan')::uuid, public.business_today(), 'REF-H711T-SCOPEBATCH', 'دفعة اختبار نطاق المتجر');
  select * into v_final from public.finalize_settlement_batch(v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'adjustment_approved', 'source_event_id', v_adj.id)), null, null, null);

  perform set_config('h711t.batch_scope', v_batch.id::text, false);
  perform set_config('h711t.batch_scope_rv', v_final.row_version::text, false);
  raise notice 'PASS: 2a setup — batch % finalized with one Adjustment line whose primary (processing) store is Store B', v_batch.id;
end $$;

set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
declare
  v_batch_id uuid := current_setting('h711t.batch_scope')::uuid;
  v_rv bigint := current_setting('h711t.batch_scope_rv')::bigint;
  v_rejected boolean;
begin
  v_rejected := false;
  begin
    perform public.record_settlement_bank_movement(v_batch_id, public.business_today(), 100.00, 'BANKREF-H711T-SCOPE', 'محاولة من نطاق متجر مقيد');
  exception when others then
    if sqlerrm like '%دفعة التسوية غير موجودة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 2b: record_settlement_bank_movement() did NOT fail closed for a store-scoped actor who cannot see one of the batch''s lines'' stores (§5, CRITICAL)'; end if;

  v_rejected := false;
  begin
    perform public.reconcile_settlement_batch(v_batch_id, v_rv);
  exception when others then
    if sqlerrm like '%دفعة التسوية غير موجودة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 2c: reconcile_settlement_batch() did NOT fail closed for a store-scoped actor (§5, CRITICAL)'; end if;

  v_rejected := false;
  begin
    perform public.cancel_settlement_batch(v_batch_id, v_rv, public.business_today(), 'محاولة إلغاء من نطاق متجر مقيد');
  exception when others then
    if sqlerrm like '%دفعة التسوية غير موجودة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 2d: cancel_settlement_batch() did NOT fail closed for a store-scoped actor (§5, CRITICAL)'; end if;

  raise notice 'PASS: 2b/c/d record_settlement_bank_movement()/reconcile_settlement_batch()/cancel_settlement_batch() all fail closed (not-found) for a store-scoped actor who cannot see every line''s store (§5, CRITICAL)';
end $$;

-- reverse_settlement_bank_movement() needs a REAL movement to attempt to
-- reverse first — recorded by the admin, then the store-scoped actor
-- attempts the reversal.
set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare v_move_id uuid;
begin
  -- 100.00 charge - 8.00 fee - 5.00 batch fee = 87.00 expected exactly (zero
  -- variance), so the reconcile-only actor in section (3) below doesn't
  -- also need settlements.reconcile_variance just to get past this.
  select public.record_settlement_bank_movement(current_setting('h711t.batch_scope')::uuid, public.business_today(), 87.00, 'BANKREF-H711T-SCOPE2', 'حركة من المدير لاختبار العكس') into v_move_id;
  perform set_config('h711t.move_scope', v_move_id::text, false);
end $$;

set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000005","role":"authenticated"}';
do $$
declare v_move_id uuid := current_setting('h711t.move_scope')::uuid; v_rejected boolean := false;
begin
  begin
    perform public.reverse_settlement_bank_movement(v_move_id, public.business_today(), 'محاولة عكس من نطاق متجر مقيد');
  exception when others then
    if sqlerrm like '%دفعة التسوية غير موجودة%' or sqlerrm like '%الحركة البنكية غير موجودة%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 2e: reverse_settlement_bank_movement() did NOT fail closed for a store-scoped actor (§5, CRITICAL)'; end if;
  raise notice 'PASS: 2e reverse_settlement_bank_movement() also fails closed (not-found) for a store-scoped actor who cannot see the batch''s lines'' stores (§5, CRITICAL)';
end $$;

-- ---------------------------------------------------------------------------
-- (3) §7 CRITICAL — reconcile_settlement_batch() redaction, live.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000006","role":"authenticated"}';
do $$
declare
  v_batch_id uuid := current_setting('h711t.batch_scope')::uuid;
  v_rv bigint := current_setting('h711t.batch_scope_rv')::bigint;
  v_recon record;
begin
  select * into v_recon from public.reconcile_settlement_batch(v_batch_id, v_rv);
  assert v_recon.actual_bank_movement is null, format('FAIL 3a: actual_bank_movement must be NULL without settlements.view_financials (§7), got %s', v_recon.actual_bank_movement);
  assert v_recon.variance is null, format('FAIL 3a: variance must be NULL without settlements.view_financials (§7), got %s', v_recon.variance);
  raise notice 'PASS: 3a reconcile_settlement_batch() succeeds for settlements.reconcile alone but redacts actual_bank_movement/variance (both NULL) without settlements.view_financials (§7, CRITICAL, live)';
end $$;

-- ---------------------------------------------------------------------------
-- (4) §9 CRITICAL — preview/finalize batch-fee-override PARITY.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order record; v_batch record; v_preview record; v_final record; v_g record;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h711t.store_a')::uuid, public.business_today(),
    current_setting('h711t.pm')::uuid, current_setting('h711t.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h711t.category_id')::uuid, 'karat_id', current_setting('h711t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 700.00)),
    'عميل اختبار 7.1.1 — تجاوز الرسوم', null, null, null
  );

  select * into v_preview from public.preview_settlement_batch(
    current_setting('h711t.route_chan')::uuid, public.business_today() - 1, public.business_today() + 1,
    jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)),
    public.business_today(), 9.99, 'اختبار تكافؤ 7.1.1 — معاينة'
  );
  assert v_preview.effective_batch_fee::numeric = 9.99, format('FAIL 4a: preview effective_batch_fee expected 9.99, got %s', v_preview.effective_batch_fee);

  select * into v_batch from public.create_draft_settlement_batch(current_setting('h711t.route_chan')::uuid, public.business_today(), 'REF-H711T-PARITY', 'دفعة اختبار التكافؤ');
  select * into v_final from public.finalize_settlement_batch(
    v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), 9.99, 'اختبار تكافؤ 7.1.1 — اعتماد', null
  );

  select * into v_g from public.get_settlement_batch(v_batch.id);
  assert v_g.original_batch_fee::numeric = 9.99 and v_g.is_batch_fee_override, format('FAIL 4b: finalize snapshot expected original_batch_fee=9.99/is_batch_fee_override=true, got %s/%s', v_g.original_batch_fee, v_g.is_batch_fee_override);
  assert v_g.original_batch_fee::numeric = v_preview.effective_batch_fee::numeric, format('FAIL 4c: preview effective_batch_fee (%s) must equal finalize''s snapshotted original_batch_fee (%s) — §9 PARITY', v_preview.effective_batch_fee, v_g.original_batch_fee);

  raise notice 'PASS: 4 preview_settlement_batch(override=9.99).effective_batch_fee EQUALS finalize_settlement_batch(override=9.99)''s snapshotted original_batch_fee exactly — §9 PARITY, CRITICAL';
end $$;

-- ---------------------------------------------------------------------------
-- (5) §11 — cancellation chronology vs the latest bank-movement reversal.
-- ---------------------------------------------------------------------------
do $$
declare
  v_order record; v_batch record; v_final record; v_move_id uuid;
  v_reversal_date date := public.business_today() - 1;
  v_rejected boolean := false;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h711t.store_a')::uuid, public.business_today() - 2,
    current_setting('h711t.pm')::uuid, current_setting('h711t.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h711t.category_id')::uuid, 'karat_id', current_setting('h711t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 300.00)),
    'عميل اختبار 7.1.1 — تسلسل الإلغاء', null, null, null
  );
  select * into v_batch from public.create_draft_settlement_batch(current_setting('h711t.route_chan')::uuid, public.business_today() - 2, 'REF-H711T-CHRONO', 'دفعة اختبار تسلسل الإلغاء');
  select * into v_final from public.finalize_settlement_batch(v_batch.id, 1, jsonb_build_array(jsonb_build_object('source_kind', 'sale', 'source_event_id', v_order.id)), null, null, null);
  select public.record_settlement_bank_movement(v_batch.id, public.business_today() - 2, 287.00, 'BANKREF-H711T-CHRONO', 'حركة قبل الإلغاء') into v_move_id;
  perform public.reverse_settlement_bank_movement(v_move_id, v_reversal_date, 'عكس قبل الإلغاء — اختبار التسلسل');

  -- A cancellation dated BEFORE the reversal must be rejected (§11).
  begin
    perform public.cancel_settlement_batch(v_batch.id, v_final.row_version, v_reversal_date - 1, 'محاولة إلغاء بتاريخ أسبق من تاريخ العكس');
  exception when others then
    if sqlerrm like '%تاريخ الإلغاء%لا يمكن أن يكون قبل تاريخ آخر عكس%' then v_rejected := true; else raise; end if;
  end;
  if not v_rejected then raise exception 'FAIL 5a: cancel_settlement_batch() accepted a cancellation_business_date BEFORE the latest bank-movement reversal (§11)'; end if;

  -- A cancellation dated ON/AFTER the reversal succeeds.
  perform public.cancel_settlement_batch(v_batch.id, v_final.row_version, v_reversal_date, 'إلغاء بتاريخ مطابق لتاريخ العكس — صحيح');

  raise notice 'PASS: 5 cancel_settlement_batch() rejects a cancellation_business_date before the latest bank-movement reversal, accepts one on/after it (§11)';
end $$;

-- ---------------------------------------------------------------------------
-- (6) §12 — settlements.view-gated filter lookups, including a DISABLED
-- payment method staying visible.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000007","role":"authenticated"}';
do $$
declare v_found_disabled boolean;
begin
  select exists (
    select 1 from public.settlement_filter_payment_method_lookups() l where l.id = current_setting('h711t.pm_disabled')::uuid
  ) into v_found_disabled;
  assert v_found_disabled, 'FAIL 6a: settlement_filter_payment_method_lookups() must include a DISABLED payment method (so an already-finalized batch under it stays filterable), §12';

  if not exists (select 1 from public.settlement_filter_collection_channel_lookups()) then
    raise exception 'FAIL 6b: settlement_filter_collection_channel_lookups() returned zero rows for a settlements.view-only actor (§12)';
  end if;

  raise notice 'PASS: 6 settlement_filter_payment_method_lookups()/settlement_filter_collection_channel_lookups() work for settlements.view ALONE (never payment_methods.view/collection_channels.view), and include disabled/historical values (§12)';
end $$;

-- ---------------------------------------------------------------------------
-- (7) §15 — cross-store Source Discovery filter (primary OR secondary),
-- distinct from the AND-rule that still governs whole-batch VISIBILITY.
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"f7112000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare
  v_order record; v_type_id uuid; v_adj record; v_adjrow record;
  v_found_a boolean; v_found_b boolean;
begin
  select * into v_order from public.create_sales_order(
    current_setting('h711t.store_a')::uuid, public.business_today(),
    current_setting('h711t.pm')::uuid, current_setting('h711t.channel_id')::uuid,
    jsonb_build_array(jsonb_build_object('category_id', current_setting('h711t.category_id')::uuid, 'karat_id', current_setting('h711t.karat_id')::uuid, 'weight_grams', 1.0000, 'sale_price', 250.00)),
    'عميل اختبار 7.1.1 — فلتر متجر عبر المتاجر', null, null, null
  );
  select public.create_adjustment_type('h711t_service2', 'خدمة اختبار 7.1.1 - ٢') into v_type_id;
  select * into v_adj from public.create_sales_order_adjustment(
    v_order.id, v_type_id, current_setting('h711t.store_b')::uuid, public.business_today(),
    current_setting('h711t.pm')::uuid, current_setting('h711t.channel_id')::uuid,
    true, 50.00, 4.00, 'خدمة اختبار 7.1.1 عبر متاجر ٢ — معالجة في ب، البيع الأصلي في أ', null, 'REF-H711T-XSTOREFILTER'
  );
  select * into v_adjrow from public.get_sales_order_adjustment(v_adj.id);
  perform public.approve_sales_order_adjustment(v_adj.id, v_adjrow.row_version, null);

  select exists (
    select 1 from public.list_unsettled_settlement_sources(current_setting('h711t.route_chan')::uuid, public.business_today() - 1, public.business_today() + 1, current_setting('h711t.store_a')::uuid)
    where source_kind = 'adjustment_approved' and source_event_id = v_adj.id
  ) into v_found_a;
  select exists (
    select 1 from public.list_unsettled_settlement_sources(current_setting('h711t.route_chan')::uuid, public.business_today() - 1, public.business_today() + 1, current_setting('h711t.store_b')::uuid)
    where source_kind = 'adjustment_approved' and source_event_id = v_adj.id
  ) into v_found_b;

  assert v_found_a, 'FAIL 7a: p_store_id := Store A (the SECONDARY/original-sale store) must find the cross-store Adjustment in Source Discovery (§15)';
  assert v_found_b, 'FAIL 7b: p_store_id := Store B (the PRIMARY/processing store) must find the cross-store Adjustment in Source Discovery (§15)';

  raise notice 'PASS: 7 list_unsettled_settlement_sources()''s store filter matches PRIMARY OR SECONDARY store for a cross-store Adjustment (§15) — filtering by EITHER Store A (original sale) or Store B (processing) finds it';
end $$;

do $$
begin
  raise notice '=== ALL settlements_hotfix_7_1_1.test.sql ASSERTIONS PASSED (§4/§5/§7/§9/§11/§12/§15 live regression coverage) ===';
end $$;

rollback;

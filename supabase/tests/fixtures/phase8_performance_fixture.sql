-- ============================================================================
-- Phase 8 Patch 8.1 §50-51/§71 — Performance fixture.
-- ============================================================================
-- Generates a realistically-shaped, LARGE dataset (10,000+ sales orders,
-- plus proportionally smaller returns/shipments/adjustments/settlements —
-- a real store's transaction mix is dominated by plain sales, not every
-- domain event type at equal volume) via the SAME production RPCs the
-- golden scenario fixture uses (create_sales_order/create_sales_return/
-- create_shipment/create_sales_order_adjustment/settlement batch RPCs) —
-- never raw INSERTs — so every snapshot column, trigger-computed field
-- (net_sales_profit, weighted costs, etc.) and audit trail is exactly as
-- real as a genuine year of store activity, and the report RPCs under test
-- see the same row shapes they see in production.
--
-- Test-only: this fixture is meant to be \i-included inside a transaction
-- the CALLING script rolls back (see performance_reports_dashboard.test.sql)
-- — exactly the convention phase8_golden_scenario_fixture.sql already
-- follows — so it never permanently bloats a shared scratch database.
--
-- Distinct '80300000-...' id prefix keeps every master-data row here
-- completely separate from the golden scenario fixture's '80100000-...'
-- rows, so the two fixtures can be \i-included in the same transaction
-- without colliding (useful for a combined correctness+performance run).
--
-- Business dates span the 365 days up to and including business_today(),
-- computed dynamically (never hardcoded) so this fixture keeps working
-- whenever it's re-run, in any environment/date.
-- ============================================================================

do $$
declare
  v_actor uuid := '80300000-0000-4000-8000-000000000001';
  v_today date := public.business_today();
  v_window_start date := public.business_today() - 364;

  v_store uuid[] := array[
    '80300000-0000-4000-8000-000000000011',
    '80300000-0000-4000-8000-000000000012',
    '80300000-0000-4000-8000-000000000013'
  ];
  v_karat uuid[] := array[
    '80300000-0000-4000-8000-000000000021',
    '80300000-0000-4000-8000-000000000022',
    '80300000-0000-4000-8000-000000000023'
  ];
  v_cat uuid[] := array[
    '80300000-0000-4000-8000-000000000031',
    '80300000-0000-4000-8000-000000000032',
    '80300000-0000-4000-8000-000000000033'
  ];
  v_pm uuid[] := array[
    '80300000-0000-4000-8000-000000000041',
    '80300000-0000-4000-8000-000000000042'
  ];
  v_ch uuid[] := array[
    '80300000-0000-4000-8000-000000000051',
    '80300000-0000-4000-8000-000000000052'
  ];
  v_carrier uuid := '80300000-0000-4000-8000-000000000061';
  v_zone uuid := '80300000-0000-4000-8000-000000000062';
  v_adjtype uuid[] := array[
    '80300000-0000-4000-8000-000000000071',
    '80300000-0000-4000-8000-000000000072'
  ];
  v_route_pay uuid := '80300000-0000-4000-8000-000000000081';
  v_route_cod uuid := '80300000-0000-4000-8000-000000000082';

  v_order_count integer := 10500;
  i integer;
  v_date date;
  v_weight numeric(10,3);
  v_price numeric(10,2);
  v_order_id uuid;
  v_order_number text;
  v_order_version bigint;
  v_order_item_id uuid;
  v_return_id uuid;
  v_return_version bigint;
  v_refund_event_id uuid;
  v_ship_id uuid;
  v_is_cod boolean;
  v_month_start date;
  v_month_end date;
  v_batch_id uuid;
  v_batch_ver bigint;
  v_sources jsonb;
  v_expected numeric;
  v_adj_id uuid;
  v_adj_version bigint;
begin
  -- request.jwt.claims is deliberately left UNSET through this whole setup
  -- block (auth.uid() = null) — matching phase8_golden_scenario_fixture.sql's
  -- own convention exactly. The raw profile-activation UPDATE below only
  -- counts as a trusted bootstrap context (public.is_trusted_bootstrap_context(),
  -- 0013) and satisfies 0029's provisioning invariant when NOBODY is logged
  -- in yet; calling set_config with the actor's own identity before this
  -- point would make auth.uid() non-null and this UPDATE would be rejected
  -- ("لم يكتمل تزويده عبر إنشاء المستخدم"). set_config is called ONLY once
  -- this actor genuinely exists and is active, right before it starts
  -- acting (creating sales/returns/shipments/etc. below).
  insert into auth.users (id, email) values (v_actor, 'p8-perf-actor@example.invalid') on conflict (id) do nothing;
  update public.profiles set full_name = 'Phase8 Performance Fixture Actor', status = 'active', store_access_scope = 'all' where id = v_actor;
  insert into public.user_roles (user_id, role_id)
    select v_actor, r.id from public.roles r where r.key = 'super_admin'
  on conflict do nothing;

  insert into public.stores (id, code, name_ar, status)
  select v_store[k], 'P8-PERF-STORE-' || k, 'متجر أداء ' || k, 'active'
  from generate_series(1, 3) k
  on conflict (id) do nothing;

  insert into public.karats (id, code, purity_per_mille, name_ar, name_en, sort_order, status)
  select v_karat[k], 'P8-PERF-K' || k, 750.000 + k * 20, 'عيار أداء ' || k, 'Perf Karat ' || k, 900 + k, 'active'
  from generate_series(1, 3) k
  on conflict (id) do nothing;

  insert into public.product_categories (id, code, name_ar, sort_order, status)
  select v_cat[k], 'P8-PERF-CAT-' || k, 'تصنيف أداء ' || k, 900 + k, 'active'
  from generate_series(1, 3) k
  on conflict (id) do nothing;

  insert into public.payment_methods (id, key, name_ar, fee_model, status, supports_refunds, refund_fee_policy) values
    (v_pm[1], 'p8-perf-cash', 'نقدًا - أداء', 'percentage', 'active', true, 'full_reversal'),
    (v_pm[2], 'p8-perf-card', 'بطاقة - أداء', 'percentage', 'active', true, 'full_reversal')
  on conflict (id) do nothing;

  insert into public.collection_channels (id, key, name_ar, status) values
    (v_ch[1], 'p8-perf-direct', 'مباشر - أداء', 'active'),
    (v_ch[2], 'p8-perf-online', 'إلكتروني - أداء', 'active')
  on conflict (id) do nothing;

  insert into public.shipping_carriers (id, code, name_ar, carrier_type, status) values
    (v_carrier, 'P8-PERF-CARRIER', 'ناقل أداء', 'external', 'active')
  on conflict (id) do nothing;

  insert into public.shipping_zones (id, code, name_ar, status) values
    (v_zone, 'P8-PERF-ZONE', 'منطقة أداء', 'active')
  on conflict (id) do nothing;

  insert into public.adjustment_types (id, code, name_ar, status) values
    (v_adjtype[1], 'P8-PERF-ADJ-1', 'خدمة أداء 1', 'active'),
    (v_adjtype[2], 'P8-PERF-ADJ-2', 'خدمة أداء 2', 'active')
  on conflict (id) do nothing;

  insert into public.settlement_routes (id, code, name_ar, route_kind, payment_method_id, collection_channel_id, status) values
    (v_route_pay, 'P8-PERF-ROUTE-PAY', 'مسار تحصيل أداء', 'payment_collection', v_pm[1], v_ch[1], 'active')
  on conflict (id) do nothing;
  insert into public.settlement_routes (id, code, name_ar, route_kind, shipping_carrier_id, status) values
    (v_route_cod, 'P8-PERF-ROUTE-COD', 'مسار ناقل أداء', 'cod_carrier', v_carrier, 'active')
  on conflict (id) do nothing;

  -- daily_gold_prices needs an EXACT price_date match per karat
  -- (gold_price_version_for_karat_on_date) — seed every day in the window
  -- for every karat used.
  insert into public.daily_gold_prices (id, price_date, karat_id, price_per_gram, source_type, is_manual_override, created_by, updated_by)
  select gen_random_uuid(), d::date, k, 200.00 + (extract(doy from d)::numeric % 30), 'manual', true, v_actor, v_actor
  from generate_series(v_window_start, v_today, interval '1 day') d
  cross join unnest(v_karat) k
  on conflict do nothing;

  insert into public.manufacturing_fee_versions (id, karat_id, fee_per_gram, effective_from, status, created_by)
  select gen_random_uuid(), k, 45.00, v_window_start, 'active', v_actor
  from unnest(v_karat) k
  on conflict do nothing;

  -- Global VAT rate row: closed range ending the day BEFORE "today" so it
  -- never overlaps seed.sql's own open-ended (today, infinity) active row
  -- (vat_rate_versions_no_overlap) — same technique as the golden fixture.
  insert into public.vat_rate_versions (id, rate_percent, effective_from, effective_to, status, created_by)
  values (gen_random_uuid(), 15.00, v_window_start, v_today - 1, 'active', v_actor)
  on conflict do nothing;

  insert into public.payment_method_fee_versions (id, payment_method_id, percentage_fee, fixed_fee, effective_from, status, created_by)
  select gen_random_uuid(), p, 2.00, 0.00, v_window_start, 'active', v_actor
  from unnest(v_pm) p
  on conflict do nothing;

  insert into public.settlement_route_fee_versions (id, settlement_route_id, effective_from, transaction_fee_strategy, transaction_fee_model, percentage_fee, fixed_fee, batch_fee_fixed, cod_fee_reversal_policy, status, created_by)
  values
    (gen_random_uuid(), v_route_pay, v_window_start, 'route_formula', 'percentage', 2.00, 0.00, 5.00, null, 'active', v_actor),
    (gen_random_uuid(), v_route_cod, v_window_start, 'route_formula', 'percentage', 1.50, 0.00, 5.00, 'full', 'active', v_actor)
  on conflict do nothing;

  -- Actor now genuinely exists and is active — safe to act as it from here on.
  perform set_config('request.jwt.claims', json_build_object('sub', v_actor::text, 'role', 'authenticated')::text, true);

  -- -------------------------------------------------------------------------
  -- Bulk sales orders (§50-51's headline "10,000+ synthetic sales orders"),
  -- each with a proportionally smaller chance of also spawning a return,
  -- shipment (some COD), or adjustment against it — mirroring a real
  -- store's mix (most sales are plain; only a minority return/ship/adjust).
  -- -------------------------------------------------------------------------
  for i in 1..v_order_count loop
    v_date := v_today - (i % 365);
    v_weight := (3 + (i % 25))::numeric(10,3);
    v_price := (v_weight * (300 + (i % 60)))::numeric(10,2);

    select t.id, t.order_number into v_order_id, v_order_number from public.create_sales_order(
      v_store[1 + (i % 3)], v_date, v_pm[1 + (i % 2)], v_ch[1 + (i % 2)],
      jsonb_build_array(jsonb_build_object(
        'category_id', v_cat[1 + (i % 3)], 'karat_id', v_karat[1 + (i % 3)],
        'weight_grams', v_weight, 'sale_price', v_price, 'item_name', 'Perf Item ' || i
      )),
      'Perf Customer ' || i, null, null
    ) as t;

    -- Return: ~1 in 9 orders (≈1,166 returns), a quarter of THOSE later reversed.
    if i % 9 = 0 then
      select so.row_version, soi.id into v_order_version, v_order_item_id
      from public.sales_orders so join public.sales_order_items soi on soi.sales_order_id = so.id
      where so.id = v_order_id and soi.status = 'active';

      select t.id into v_return_id from public.create_sales_return(
        v_order_id, v_store[1 + (i % 3)], least(v_date + 3, v_today), 'defective_product',
        jsonb_build_array(jsonb_build_object('sales_order_item_id', v_order_item_id)),
        v_order_version, 'collected', v_price
      ) as t;
      select row_version into v_return_version from public.sales_returns where id = v_return_id;
      perform public.approve_sales_return(v_return_id, v_return_version);

      -- Actual cash refund event (§26-29's 'actual_cash' basis ledger) —
      -- issued "now" (real wall-clock date), same convention as every
      -- other post-approval event in this fixture.
      select t.id into v_refund_event_id from public.record_sales_return_refund(
        v_return_id, v_price, v_pm[1 + (i % 2)], v_today, 'Perf fixture refund'
      ) as t;

      if i % 36 = 0 then
        select row_version into v_return_version from public.sales_returns where id = v_return_id;
        -- A reversal's business date must be >= approve_sales_return()'s own
        -- real approved_at (stamped "now" during this fixture run) — never
        -- the order's own historical v_date. Always v_today, mirroring the
        -- golden scenario fixture's identical convention.
        perform public.reverse_sales_return(v_return_id, v_return_version, 'Perf fixture reversal', v_today);
        perform public.reverse_sales_return_refund_event(v_refund_event_id, 'Perf fixture refund reversal', v_today);
      end if;
    end if;

    -- Shipment: ~1 in 10 orders (≈1,050 shipments), roughly a third COD.
    if i % 10 = 0 then
      v_is_cod := (i % 30) = 0;
      select t.id into v_ship_id from public.create_shipment(
        p_sales_order_id => v_order_id, p_store_id => v_store[1 + (i % 3)], p_shipment_date => v_date,
        p_direction => 'outbound', p_carrier_id => v_carrier, p_shipping_zone_id => v_zone,
        p_customer_shipping_charge => 30.00,
        p_is_cod => v_is_cod, p_cod_expected_amount => (case when v_is_cod then v_price else null end),
        p_manual_expected_cost => 22.00, p_manual_expected_cost_reason => 'Perf fixture -- no rate card configured'
      ) as t;

      if v_is_cod then
        -- ~60% of COD shipments get collected shortly after; the rest stay 'expected'.
        if i % 50 <> 0 then
          perform public.record_shipment_cod_collection_state(v_ship_id, 1, 'collected', least(v_date + 2, v_today));
        end if;
      else
        perform public.record_shipment_actual_cost(v_ship_id, 1, 18.00, v_date, 'Perf fixture carrier cost');
      end if;
    end if;

    -- Adjustment: ~1 in 25 orders (≈420 adjustments), a small fraction reversed.
    if i % 25 = 0 then
      select t.id into v_adj_id from public.create_sales_order_adjustment(
        v_order_id, v_adjtype[1 + (i % 2)], v_store[1 + (i % 3)], v_date, v_pm[1 + (i % 2)], v_ch[1 + (i % 2)],
        true, 80.00, 30.00, 'Perf fixture adjustment'
      ) as t;
      select row_version into v_adj_version from public.sales_order_adjustments where id = v_adj_id;
      perform public.approve_sales_order_adjustment(v_adj_id, v_adj_version);

      if i % 100 = 0 then
        select row_version into v_adj_version from public.sales_order_adjustments where id = v_adj_id;
        perform public.reverse_sales_order_adjustment(v_adj_id, v_adj_version, v_today, 'Perf fixture adjustment reversal');
      end if;
    end if;
  end loop;

  -- -------------------------------------------------------------------------
  -- Settlement batches: one per (route, month) across the whole window,
  -- sourced from whatever real unsettled events exist for that route/month
  -- (exactly list_unsettled_settlement_sources — never fabricated), giving
  -- get_settlements_report() a realistic multi-month batch population.
  -- Every 4th batch's bank movement deliberately does NOT match expected
  -- (a real variance); every 7th batch is cancelled afterward, so
  -- effective_status has genuine draft/finalized/reconciled/cancelled mix.
  -- -------------------------------------------------------------------------
  v_month_start := date_trunc('month', v_window_start)::date;
  i := 0;
  while v_month_start <= v_today loop
    i := i + 1;
    -- Batch settlement_date must be >= every one of its own selected
    -- sources' dates (finalize_settlement_batch's own check) — the month's
    -- LAST possible source date (its calendar end, clamped to "today") is
    -- the only value guaranteed safe, never an earlier mid-month guess.
    v_month_end := least((v_month_start + interval '1 month - 1 day')::date, v_today);

    select coalesce(jsonb_agg(jsonb_build_object('source_kind', src.source_kind, 'source_event_id', src.source_event_id)), '[]'::jsonb)
    into v_sources
    from public.list_unsettled_settlement_sources(v_route_pay, v_month_start, v_month_end, null, null, 2000, 0) src;

    if jsonb_array_length(v_sources) > 0 then
      select t.id into v_batch_id from public.create_draft_settlement_batch(v_route_pay, v_month_end, 'PERF-PAY-' || i) as t;
      select row_version into v_batch_ver from public.settlement_batches where id = v_batch_id;
      perform public.finalize_settlement_batch(v_batch_id, v_batch_ver, v_sources);

      select expected_bank_settlement into v_expected from public.settlement_batches where id = v_batch_id;
      -- Every 7th batch is cancelled instead of settled (see below) —
      -- cancel_settlement_batch() refuses a batch that carries any
      -- unreversed bank movement, so a batch destined for cancellation must
      -- never get a movement recorded on it in the first place (a real
      -- cancellation happens BEFORE the bank side is reconciled, not after).
      if v_expected is not null and i % 7 <> 0 then
        -- Bank movement recorded "now" (real wall-clock date) — same rule
        -- as every other post-finalize event in this fixture (finalized_at
        -- is stamped now(), so a movement dated any earlier historical day
        -- would violate the movement-must-not-precede-finalization check).
        perform public.record_settlement_bank_movement(
          v_batch_id, v_today,
          case when i % 4 = 0 then v_expected + 37.50 else v_expected end,
          'PERF-PAY-MOVEMENT-' || i
        );
      end if;

      if i % 7 = 0 then
        select row_version into v_batch_ver from public.settlement_batches where id = v_batch_id;
        perform public.cancel_settlement_batch(v_batch_id, v_batch_ver, v_today, 'Perf fixture batch cancellation');
      end if;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object('source_kind', src.source_kind, 'source_event_id', src.source_event_id)), '[]'::jsonb)
    into v_sources
    from public.list_unsettled_settlement_sources(v_route_cod, v_month_start, v_month_end, null, null, 2000, 0) src;

    if jsonb_array_length(v_sources) > 0 then
      select t.id into v_batch_id from public.create_draft_settlement_batch(v_route_cod, v_month_end, 'PERF-COD-' || i) as t;
      select row_version into v_batch_ver from public.settlement_batches where id = v_batch_id;
      perform public.finalize_settlement_batch(v_batch_id, v_batch_ver, v_sources);

      select expected_bank_settlement into v_expected from public.settlement_batches where id = v_batch_id;
      if v_expected is not null then
        perform public.record_settlement_bank_movement(v_batch_id, v_today, v_expected, 'PERF-COD-MOVEMENT-' || i);
      end if;
    end if;

    v_month_start := (v_month_start + interval '1 month')::date;
  end loop;
end $$;

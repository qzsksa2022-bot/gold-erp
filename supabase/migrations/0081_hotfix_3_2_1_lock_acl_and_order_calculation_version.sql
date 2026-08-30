-- ============================================================================
-- 0081: Phase 3 — Final Hotfix 3.2.1 (1/2): service_role EXECUTE grant on
-- the financial-master exclusive lock helper, and order-level
-- calculation_version semantics fixed for update_sales_order()
-- ============================================================================
-- Migrations 0001-0080 are unmodified (per spec: "لا تعدل migrations من
-- 0001 إلى 0080" / "كل الإصلاحات الجديدة تبدأ من 0081 وما بعده"). This
-- migration closes items 2 and 3 of Hotfix 3.2.1 (item 1, the Edit UI
-- stale-state-after-Conflict bug, is a TypeScript/React-only fix — see
-- src/app/(app)/sales/[id]/edit/page.tsx and
-- src/features/sales/components/sales-entry-form.tsx — and needs no new
-- migration).
--
-- ============================================================================
-- Part A (Hotfix 3.2.1 item 2) — service_role could not actually write
-- daily_gold_prices under the 0073 lock: permission denied, not "waits then
-- succeeds"
-- ============================================================================
--
-- Problem: 0073 added a table-level BEFORE STATEMENT trigger on
-- daily_gold_prices (enforce_daily_gold_prices_financial_lock(), plain
-- `language plpgsql`, i.e. SECURITY INVOKER — no `security definer` was
-- ever added) that calls public.acquire_financial_master_lock_exclusive().
-- A SECURITY INVOKER trigger function runs with the privileges of whichever
-- role actually performed the INSERT/UPDATE that fired it. 0065 granted
-- EXECUTE on acquire_financial_master_lock_exclusive() to `authenticated`
-- only:
--   revoke execute on function public.acquire_financial_master_lock_exclusive() from public;
--   grant execute on function public.acquire_financial_master_lock_exclusive() to authenticated;
-- `service_role` was never granted EXECUTE on it. `service_role` is a
-- BYPASSRLS role with full table-level grants (local_harness_setup.sql /
-- a real Supabase project's own role setup) — BYPASSRLS and table GRANTs
-- bypass/satisfy RLS policies and table privileges respectively, but
-- neither one satisfies a separate function-level EXECUTE grant. The
-- result, verified directly against a real database before this fix:
--
--   begin; set local role service_role;
--   update public.daily_gold_prices set price_per_gram = 999 where ...;
--   -- ERROR:  permission denied for function acquire_financial_master_lock_exclusive
--   -- CONTEXT: PL/pgSQL function enforce_daily_gold_prices_financial_lock() line 11 at PERFORM
--
-- This directly contradicts 0073's own stated intent ("closing the
-- bypass for every present and future writer, including service_role") —
-- service_role wasn't bypassing the lock, it was being hard-blocked from
-- writing at all, which is a correctness regression for any trusted
-- server-side integration (a future price-feed importer, an admin script,
-- etc.) that legitimately writes this table as service_role, and is a
-- BLOCKING error, not a wait-then-succeed lock acquisition.
--
-- save_daily_gold_price()/save_daily_gold_prices_bulk() (0066) are also
-- SECURITY INVOKER (deliberately, per 0066's own header comment) and call
-- the SAME helper directly — so a service_role caller of those two RPCs
-- hits the identical "permission denied for function" error, not just the
-- direct-table-write path. Both call sites are fixed by the single GRANT
-- below (no other code changes needed for either).
--
-- Fix: grant EXECUTE on the helper to service_role too. `anon` is
-- deliberately NOT touched (still has zero access, exactly as before) —
-- this is a minimal, additive grant to the one role that legitimately
-- needs it and did not have it.
-- ----------------------------------------------------------------------------
grant execute on function public.acquire_financial_master_lock_exclusive() to service_role;

comment on function public.acquire_financial_master_lock_exclusive() is
  'Patch 3.1 item 7 — EXCLUSIVE transaction-scoped advisory lock over the single global "financial master data" key (1001, 0). Acquired by every financial-master WRITER (save_daily_gold_price, save_daily_gold_prices_bulk, create_manufacturing_fee_version, create_payment_method_fee_version, create_vat_rate_version — 0066) immediately after their has_permission() check, so a price/fee/VAT write can never commit in the middle of a concurrent Sale''s multi-step snapshot resolution (which holds the SHARED counterpart for its whole resolution window) — the whole Order will always see either fully-old or fully-new financial master data, never a mix. Also acquired by the daily_gold_prices_financial_lock_trigger (0073) on EVERY insert/update statement against that table, regardless of write path. Released automatically at transaction end. Hotfix 3.2.1 item 2: EXECUTE is granted to `authenticated` (0065) AND `service_role` (0081, this migration) — the SECURITY INVOKER trigger (0073) and the SECURITY INVOKER save_daily_gold_price()/save_daily_gold_prices_bulk() (0066) all run this call under the CALLING role''s own privileges, so BOTH roles that can legitimately write daily_gold_prices (a real client via `authenticated`, a trusted server-side integration via `service_role`) must independently hold EXECUTE here, or that role''s writes are blocked outright with "permission denied" instead of correctly waiting on/holding the lock. `anon` remains ungranted.';

-- ============================================================================
-- Part B (Hotfix 3.2.1 item 3) — unify sales_orders.calculation_version
-- semantics: it must reflect the ORDER-AGGREGATE engine version that
-- actually produced the header's current totals, not freeze at whatever
-- value existed before the most recent edit
-- ============================================================================
--
-- Problem: create_sales_order() (0076) correctly stamps a brand-new order's
-- header calculation_version = 2 (entirely the Patch 3.2 engine). But
-- update_sales_order() (0075) never included calculation_version in its
-- `update public.sales_orders set ...` statement at all — so ANY successful
-- edit leaves the header's calculation_version at whatever it already was,
-- even though that SAME update_sales_order() call just recomputed
-- subtotal/gross_profit/payment_fee_amount/net_sales_profit from scratch
-- using the current (Patch 3.2) aggregate engine. Concretely: a Patch-3.1-
-- era order created with calculation_version = 1, then given a Patch-3.2
-- metadata-only or financial edit via update_sales_order(), ends up with
-- header totals produced by the CURRENT engine but a header
-- calculation_version that still reads 1 — indistinguishable, by that
-- column alone, from a header whose totals were never touched by the
-- Patch 3.2 engine at all. The 0075 sale.update audit entry compounded
-- this: new_values.calculation_version was written as
-- v_old_order.calculation_version (the OLD value, unchanged), so even the
-- audit trail could not tell the two cases apart after the fact.
--
-- This is entirely independent of sales_order_items.calculation_version
-- (0074/0075, unchanged by this migration) — that column's semantics were
-- already correct and stay exactly as they are: legacy-untouched item stays
-- v1, new/financially-recalculated item becomes v2, no forced upgrade, one
-- order may legitimately mix both. This migration only fixes the
-- ORDER-HEADER column's meaning, and gives the two columns clearly distinct,
-- independently-correct semantics:
--   - sales_order_items.calculation_version = which cost-engine computed
--     THIS item's own gold/manufacturing/VAT component costs.
--   - sales_orders.calculation_version = which aggregate engine produced
--     the CURRENTLY-STORED header totals (subtotal/gross_profit/
--     payment_fee_amount/net_sales_profit) -- i.e. is up to date with the
--     current engine or not.
--
-- Fix: since every successful update_sales_order() call (this function,
-- unconditionally) already recomputes all four header totals using the
-- current (Patch 3.2) engine regardless of whether any ITEM's financial
-- inputs changed, every successful update_sales_order() call now also
-- stamps the header calculation_version = 2 — never a partial/conditional
-- bump, and never a bare migration-time backfill with no accompanying
-- recalculation (a legacy order that is simply never edited again keeps
-- its original header calculation_version = 1 forever, correctly, because
-- its stored totals genuinely were never touched by the new engine).
-- Deliberately: Order header = v2, Item A (untouched) = v1, Item B
-- (recalculated) = v2 within the SAME order is the correct, intended
-- outcome — the two columns answer two different questions. The
-- sale.update audit entry is corrected to match: old_values.
-- calculation_version keeps reporting the row's actual PRE-edit value
-- (v_old_order.calculation_version, unchanged), new_values.
-- calculation_version now reports the actual POST-edit value (2), instead
-- of repeating the old value on both sides.
--
-- Function body below is 0075's update_sales_order() reproduced byte-for-
-- byte except for these two changes (search "Hotfix 3.2.1" for both). Same
-- exact signature (uuid,uuid,uuid,jsonb,text,text,text,text,bigint) as
-- 0075 — no DROP needed, CREATE OR REPLACE alone is sufficient here.
-- ----------------------------------------------------------------------------
create or replace function public.update_sales_order(
  p_order_id uuid,
  p_payment_method_id uuid,
  p_collection_channel_id uuid,
  p_items jsonb,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_notes text default null,
  p_closed_day_reason text default null,
  p_expected_version bigint default null
)
returns table (id uuid, order_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old_order record;
  v_old_items_for_audit jsonb;
  v_new_items_for_audit jsonb;
  v_payment_method record;
  v_collection_channel record;
  v_payment_method_changed boolean;
  v_collection_channel_changed boolean;
  v_payment_fee record;
  v_payment_fee_version_id uuid;
  v_payment_fee_percentage numeric;
  v_payment_fee_fixed numeric;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_item jsonb;
  v_item_id uuid;
  v_seen_ids uuid[] := '{}'::uuid[];
  v_max_line_no integer;
  v_new_active_ids uuid[] := '{}'::uuid[];
  v_line_no integer;
  v_category_id uuid;
  v_karat_id uuid;
  v_weight numeric;
  v_sale_price numeric;
  v_item_name text;
  v_description text;
  v_sku text;
  v_existing record;
  v_category record;
  v_karat record;
  v_category_changed boolean;
  v_karat_changed boolean;
  v_financial_changed boolean;
  v_metadata_changed boolean;
  v_gold record;
  v_mfg record;
  v_vat record;
  v_costs record;
  v_subtotal numeric;
  v_order_gross_profit numeric;
  v_payment_fee_amount numeric;
  v_net_sales_profit numeric;
  v_new_row_version bigint;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتعديل عملية بيع' using errcode = 'P0001';
  end if;

  if not public.has_permission('sales.edit') then
    raise exception 'ليست لديك صلاحية تعديل عمليات البيع' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لحفظ التعديل' using errcode = 'P0001';
  end if;

  -- Row lock (unchanged from 0069/0075) — a concurrent update_sales_order()
  -- on the same order blocks here until this transaction commits/rolls back.
  select * into v_old_order from public.sales_orders so where so.id = p_order_id for update;

  -- Item 9 — VISIBLE scope (not operable) for editing an EXISTING Sale:
  -- store_id is immutable here, so a store disabled after the Sale was
  -- created must not by itself block correcting the record, as long as the
  -- actor can still see it and holds sales.edit.
  if v_old_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_old_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  -- Item 2 — optimistic concurrency check, immediately after the row lock
  -- guarantees v_old_order.row_version is the latest committed value, and
  -- BEFORE any other validation or write proceeds. A stale caller is turned
  -- away here, never allowed to silently overwrite a newer committed edit.
  if v_old_order.row_version <> p_expected_version then
    raise exception 'تم تعديل عملية البيع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الحفظ.' using errcode = 'P0001';
  end if;

  if p_payment_method_id is null or p_collection_channel_id is null then
    raise exception 'طريقة الدفع وقناة التحصيل كلاهما مطلوبان' using errcode = 'P0001';
  end if;

  perform public.acquire_daily_close_lock_shared(v_old_order.store_id, v_old_order.sale_date);

  select exists(
    select 1 from public.daily_closings
    where store_id = v_old_order.store_id and business_date = v_old_order.sale_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('sales.edit_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن تعديل عملية البيع إلا بصلاحية خاصة (sales.edit_closed_day)', v_old_order.sale_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتعديل عملية بيع في يوم مقفل (%)', v_old_order.sale_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  v_payment_method_changed := (p_payment_method_id is distinct from v_old_order.payment_method_id);
  if v_payment_method_changed then
    select * into v_payment_method from public.payment_methods pm where pm.id = p_payment_method_id;
    if v_payment_method.id is null then
      raise exception 'طريقة الدفع غير موجودة' using errcode = 'P0001';
    end if;
    if v_payment_method.status <> 'active' then
      raise exception 'طريقة الدفع "%" غير نشطة', v_payment_method.name_ar using errcode = 'P0001';
    end if;
  end if;

  v_collection_channel_changed := (p_collection_channel_id is distinct from v_old_order.collection_channel_id);
  if v_collection_channel_changed then
    select * into v_collection_channel from public.collection_channels cc where cc.id = p_collection_channel_id;
    if v_collection_channel.id is null then
      raise exception 'قناة التحصيل غير موجودة' using errcode = 'P0001';
    end if;
    if v_collection_channel.status <> 'active' then
      raise exception 'قناة التحصيل "%" غير نشطة', v_collection_channel.name_ar using errcode = 'P0001';
    end if;
  end if;

  perform public.acquire_financial_master_lock_shared();

  if v_payment_method_changed then
    select * into v_payment_fee from public.payment_fee_for_method_on_date(p_payment_method_id, v_old_order.sale_date);
    v_payment_fee_version_id := v_payment_fee.fee_version_id;
    v_payment_fee_percentage := v_payment_fee.percentage_fee;
    v_payment_fee_fixed := v_payment_fee.fixed_fee;
  else
    v_payment_fee_version_id := v_old_order.payment_fee_version_id;
    v_payment_fee_percentage := v_old_order.payment_fee_percentage_snapshot;
    v_payment_fee_fixed := v_old_order.payment_fee_fixed_snapshot;
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'يجب أن تحتوي عملية البيع على بند واحد على الأقل' using errcode = 'P0001';
  end if;

  select coalesce(jsonb_agg(to_jsonb(it.*) order by it.line_no), '[]'::jsonb) into v_old_items_for_audit
  from public.sales_order_items it
  where it.sales_order_id = p_order_id and it.status = 'active';

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if (v_item ->> 'id') is not null then
      v_item_id := (v_item ->> 'id')::uuid;

      if v_item_id = any(v_seen_ids) then
        raise exception 'يوجد معرف بند مكرر في نفس الطلب (id: %)', v_item_id using errcode = 'P0001';
      end if;
      v_seen_ids := array_append(v_seen_ids, v_item_id);

      if not exists (
        select 1 from public.sales_order_items it
        where it.id = v_item_id and it.sales_order_id = p_order_id and it.status = 'active'
      ) then
        raise exception 'بند غير موجود ضمن عملية البيع هذه أو تمت إزالته مسبقًا (id: %)', v_item_id using errcode = 'P0001';
      end if;
    end if;
  end loop;

  select coalesce(max(line_no), 0) into v_max_line_no from public.sales_order_items where sales_order_id = p_order_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    if v_item ->> 'category_id' is null or v_item ->> 'karat_id' is null
       or v_item ->> 'weight_grams' is null or v_item ->> 'sale_price' is null then
      raise exception 'كل بند يجب أن يحدد التصنيف والعيار والوزن وسعر البيع' using errcode = 'P0001';
    end if;

    v_item_id := case when (v_item ->> 'id') is null then null else (v_item ->> 'id')::uuid end;
    v_category_id := (v_item ->> 'category_id')::uuid;
    v_karat_id := (v_item ->> 'karat_id')::uuid;
    v_weight := (v_item ->> 'weight_grams')::numeric;
    v_sale_price := (v_item ->> 'sale_price')::numeric;
    v_item_name := nullif(btrim(coalesce(v_item ->> 'item_name', '')), '');
    v_description := nullif(btrim(coalesce(v_item ->> 'description', '')), '');
    v_sku := nullif(btrim(coalesce(v_item ->> 'sku', '')), '');

    if v_weight <= 0 then
      raise exception 'الوزن يجب أن يكون أكبر من صفر' using errcode = 'P0001';
    end if;

    if v_sale_price < 0 then
      raise exception 'سعر البيع لا يمكن أن يكون سالبًا' using errcode = 'P0001';
    end if;

    -- Item 4 — DB-level precision/scale/bounds validation, BEFORE any
    -- calculation, for every item that will actually be calculated (new,
    -- or an existing item whose financial inputs changed — checked again
    -- below just before compute_sales_item_costs() is called, since an
    -- unchanged-financials item never recalculates at all and therefore
    -- never needs this check re-run against inputs it isn't using).
    if v_item_id is null then
      -- ------------------------------------------------------------------
      -- New item — always fresh, always Patch 3.2 engine (calculation_version = 2).
      -- ------------------------------------------------------------------
      perform public.validate_sales_item_precision(v_weight, v_sale_price);

      v_max_line_no := v_max_line_no + 1;
      v_line_no := v_max_line_no;

      select * into v_category from public.product_categories pc where pc.id = v_category_id;
      if v_category.id is null then
        raise exception 'التصنيف غير موجود' using errcode = 'P0001';
      end if;
      if v_category.status <> 'active' then
        raise exception 'التصنيف "%" غير نشط — لا يمكن استخدامه في بند جديد', v_category.name_ar using errcode = 'P0001';
      end if;

      select * into v_karat from public.karats k where k.id = v_karat_id;
      if v_karat.id is null then
        raise exception 'العيار غير موجود' using errcode = 'P0001';
      end if;
      if v_karat.status <> 'active' then
        raise exception 'عيار "%" غير نشط — لا يمكن استخدامه في بند جديد', v_karat.name_ar using errcode = 'P0001';
      end if;

      select * into v_gold from public.gold_price_version_for_karat_on_date(v_karat_id, v_old_order.sale_date);
      select * into v_mfg from public.manufacturing_fee_version_for_karat_on_date(v_karat_id, v_old_order.sale_date);
      select * into v_vat from public.vat_rate_version_for_date(v_old_order.sale_date);

      select * into v_costs from public.compute_sales_item_costs(
        v_gold.price_per_gram, v_mfg.fee_per_gram, v_vat.rate_percent, v_weight, v_sale_price
      );

      insert into public.sales_order_items (
        sales_order_id, line_no, category_id, karat_id, item_name, description, sku,
        weight_grams, sale_price,
        category_name_ar_snapshot, karat_code_snapshot, karat_name_ar_snapshot,
        daily_gold_price_id, gold_price_per_gram_snapshot,
        manufacturing_fee_version_id, manufacturing_fee_per_gram_snapshot,
        vat_rate_version_id, vat_rate_percent_snapshot,
        gold_component_cost, manufacturing_component_cost, base_cost, vat_cost, total_cost, gross_profit,
        calculation_version,
        status,
        created_by, updated_by
      ) values (
        p_order_id, v_line_no, v_category_id, v_karat_id, v_item_name, v_description, v_sku,
        v_weight, v_sale_price,
        v_category.name_ar, v_karat.code, v_karat.name_ar,
        v_gold.daily_gold_price_id, v_gold.price_per_gram,
        v_mfg.manufacturing_fee_version_id, v_mfg.fee_per_gram,
        v_vat.vat_rate_version_id, v_vat.rate_percent,
        v_costs.gold_component_cost, v_costs.manufacturing_component_cost, v_costs.base_cost, v_costs.vat_cost, v_costs.total_cost, v_costs.gross_profit,
        2,
        'active',
        v_actor, v_actor
      )
      returning sales_order_items.id into v_item_id;

      v_new_active_ids := array_append(v_new_active_ids, v_item_id);
    else
      select * into v_existing from public.sales_order_items soi where soi.id = v_item_id;

      v_category_changed := (v_category_id is distinct from v_existing.category_id);
      v_karat_changed := (v_karat_id is distinct from v_existing.karat_id);
      v_financial_changed := v_category_changed or v_karat_changed
        or (v_weight is distinct from v_existing.weight_grams)
        or (v_sale_price is distinct from v_existing.sale_price);
      v_metadata_changed := (v_item_name is distinct from v_existing.item_name)
        or (v_description is distinct from v_existing.description)
        or (v_sku is distinct from v_existing.sku);

      if v_financial_changed then
        -- Item 4 — validate the new financial inputs before recalculating.
        perform public.validate_sales_item_precision(v_weight, v_sale_price);

        if v_category_changed then
          select * into v_category from public.product_categories pc where pc.id = v_category_id;
          if v_category.id is null then
            raise exception 'التصنيف غير موجود' using errcode = 'P0001';
          end if;
          if v_category.status <> 'active' then
            raise exception 'التصنيف "%" غير نشط — لا يمكن التحويل إليه', v_category.name_ar using errcode = 'P0001';
          end if;
        else
          select * into v_category from public.product_categories pc where pc.id = v_category_id;
          if v_category.id is null then
            raise exception 'التصنيف غير موجود' using errcode = 'P0001';
          end if;
        end if;

        if v_karat_changed then
          select * into v_karat from public.karats k where k.id = v_karat_id;
          if v_karat.id is null then
            raise exception 'العيار غير موجود' using errcode = 'P0001';
          end if;
          if v_karat.status <> 'active' then
            raise exception 'عيار "%" غير نشط — لا يمكن التحويل إليه', v_karat.name_ar using errcode = 'P0001';
          end if;
        else
          select * into v_karat from public.karats k where k.id = v_karat_id;
          if v_karat.id is null then
            raise exception 'العيار غير موجود' using errcode = 'P0001';
          end if;
        end if;

        select * into v_gold from public.gold_price_version_for_karat_on_date(v_karat_id, v_old_order.sale_date);
        select * into v_mfg from public.manufacturing_fee_version_for_karat_on_date(v_karat_id, v_old_order.sale_date);
        select * into v_vat from public.vat_rate_version_for_date(v_old_order.sale_date);

        select * into v_costs from public.compute_sales_item_costs(
          v_gold.price_per_gram, v_mfg.fee_per_gram, v_vat.rate_percent, v_weight, v_sale_price
        );

        -- Item 7 — this item's financials were actually recalculated under
        -- the Patch 3.2 engine, so it is stamped v2 regardless of whatever
        -- version it carried before (legacy v1 or already v2).
        update public.sales_order_items soi
        set category_id = v_category_id,
            karat_id = v_karat_id,
            item_name = v_item_name,
            description = v_description,
            sku = v_sku,
            weight_grams = v_weight,
            sale_price = v_sale_price,
            category_name_ar_snapshot = v_category.name_ar,
            karat_code_snapshot = v_karat.code,
            karat_name_ar_snapshot = v_karat.name_ar,
            daily_gold_price_id = v_gold.daily_gold_price_id,
            gold_price_per_gram_snapshot = v_gold.price_per_gram,
            manufacturing_fee_version_id = v_mfg.manufacturing_fee_version_id,
            manufacturing_fee_per_gram_snapshot = v_mfg.fee_per_gram,
            vat_rate_version_id = v_vat.vat_rate_version_id,
            vat_rate_percent_snapshot = v_vat.rate_percent,
            gold_component_cost = v_costs.gold_component_cost,
            manufacturing_component_cost = v_costs.manufacturing_component_cost,
            base_cost = v_costs.base_cost,
            vat_cost = v_costs.vat_cost,
            total_cost = v_costs.total_cost,
            gross_profit = v_costs.gross_profit,
            calculation_version = 2,
            updated_by = v_actor
        where soi.id = v_item_id;
      elsif v_metadata_changed then
        -- No financial input changed — calculation_version stays exactly
        -- as stored (legacy items are NEVER upgraded just for a metadata
        -- edit, per spec item 7).
        update public.sales_order_items soi
        set item_name = v_item_name,
            description = v_description,
            sku = v_sku,
            updated_by = v_actor
        where soi.id = v_item_id;
      end if;

      v_new_active_ids := array_append(v_new_active_ids, v_item_id);
    end if;
  end loop;

  update public.sales_order_items soi
  set status = 'removed', removed_at = now(), removed_by = v_actor
  where soi.sales_order_id = p_order_id
    and soi.status = 'active'
    and soi.id <> all(v_new_active_ids);

  select coalesce(sum(sale_price), 0), coalesce(sum(gross_profit), 0)
  into v_subtotal, v_order_gross_profit
  from public.sales_order_items
  where sales_order_id = p_order_id and status = 'active';

  v_payment_fee_amount := round((v_subtotal * v_payment_fee_percentage / 100) + v_payment_fee_fixed, 2);
  v_net_sales_profit := round(v_order_gross_profit, 2) - v_payment_fee_amount;
  v_new_row_version := v_old_order.row_version + 1;

  -- Hotfix 3.2.1 item 3 — calculation_version = 2 added: every successful
  -- update_sales_order() call unconditionally recomputes subtotal/
  -- gross_profit/payment_fee_amount/net_sales_profit above using the
  -- current (Patch 3.2) aggregate engine, so the header's
  -- calculation_version must reflect that unconditionally too — not stay
  -- frozen at whatever it was before this edit. This is a real
  -- recalculation on every successful call (never a bare backfill): the
  -- four totals just above are genuinely being written fresh in this same
  -- statement.
  update public.sales_orders
  set payment_method_id = p_payment_method_id,
      collection_channel_id = p_collection_channel_id,
      customer_name = nullif(btrim(coalesce(p_customer_name, '')), ''),
      customer_phone = nullif(btrim(coalesce(p_customer_phone, '')), ''),
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      payment_fee_version_id = v_payment_fee_version_id,
      payment_fee_percentage_snapshot = v_payment_fee_percentage,
      payment_fee_fixed_snapshot = v_payment_fee_fixed,
      payment_fee_amount = v_payment_fee_amount,
      subtotal = round(v_subtotal, 2),
      gross_profit = round(v_order_gross_profit, 2),
      net_sales_profit = v_net_sales_profit,
      calculation_version = 2,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_orders.id = p_order_id;

  -- Item 10 — complete audit: new_values now carries the FINAL active items
  -- array (previously missing entirely), plus calculation_version/
  -- row_version/snapshots/totals on BOTH sides, so old vs new together
  -- fully explains what changed, not just the header. Hotfix 3.2.1 item 3:
  -- new_values.calculation_version now reports the actual POST-edit value
  -- (2, matching the UPDATE above) instead of repeating
  -- v_old_order.calculation_version on both sides — old_values keeps
  -- reporting the row's real pre-edit value, unchanged.
  select coalesce(jsonb_agg(to_jsonb(it.*) order by it.line_no), '[]'::jsonb) into v_new_items_for_audit
  from public.sales_order_items it
  where it.sales_order_id = p_order_id and it.status = 'active';

  perform public.log_audit_event(
    'sale.update', 'sales_order', p_order_id,
    jsonb_build_object('order_number', v_old_order.order_number, 'items', v_old_items_for_audit,
      'payment_method_id', v_old_order.payment_method_id, 'collection_channel_id', v_old_order.collection_channel_id,
      'customer_name', v_old_order.customer_name, 'customer_phone', v_old_order.customer_phone, 'notes', v_old_order.notes,
      'subtotal', v_old_order.subtotal, 'gross_profit', v_old_order.gross_profit,
      'payment_fee_amount', v_old_order.payment_fee_amount, 'net_sales_profit', v_old_order.net_sales_profit,
      'calculation_version', v_old_order.calculation_version, 'row_version', v_old_order.row_version),
    jsonb_build_object('order_number', v_old_order.order_number, 'items', v_new_items_for_audit,
      'payment_method_id', p_payment_method_id, 'collection_channel_id', p_collection_channel_id,
      'customer_name', p_customer_name, 'customer_phone', p_customer_phone, 'notes', p_notes,
      'subtotal', round(v_subtotal, 2), 'gross_profit', round(v_order_gross_profit, 2),
      'payment_fee_amount', v_payment_fee_amount, 'net_sales_profit', v_net_sales_profit,
      'calculation_version', 2, 'row_version', v_new_row_version)
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'sale.closed_day_update', 'sales_order', p_order_id, null,
      jsonb_build_object('order_number', v_old_order.order_number, 'sale_date', v_old_order.sale_date, 'edited_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := p_order_id;
  order_number := v_old_order.order_number;
  return next;
end;
$$;

comment on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text, bigint) is
  'Hotfix 3.2.1 (item 3, supersedes 0075''s body, same signature) — every successful call now also stamps the ORDER-HEADER sales_orders.calculation_version = 2 (previously left untouched at whatever value the row already had), because this function unconditionally recomputes subtotal/gross_profit/payment_fee_amount/net_sales_profit using the current aggregate engine on every successful call; the sale.update audit new_values.calculation_version now reports this real post-edit value (2) instead of repeating the old value on both sides. This is independent of sales_order_items.calculation_version (0074/0075, unchanged): item-level = which cost engine computed that item''s own component costs (legacy-untouched item may stay v1 even after this edit); header-level = which aggregate engine produced the header''s current totals (always v2 after any successful edit). Everything else is byte-for-byte identical to 0075: real optimistic concurrency control via row_version/p_expected_version (item 2), user_visible_store_ids() store scope for edits (item 9), the Patch 3.2 full-precision compute_sales_item_costs()/validate_sales_item_precision() engine (items 3/4), item-level calculation_version stamping rules (item 7), and the complete sale.update audit item arrays (item 10). Every Patch 3.1 structural fix (stable item ids, soft-remove not delete, selective snapshot recalculation, historical inactive-reference tolerance for unchanged references, daily-close/financial-master shared locks) remains preserved unchanged. SECURITY DEFINER.';

revoke execute on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text, bigint) from public;
grant execute on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text, bigint) to authenticated;

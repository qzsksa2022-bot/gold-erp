-- ============================================================================
-- 0078: Phase 3 — Final Sales Integrity Patch 3.2 (6/8): preview_update_sales_order()
-- — an Edit-mode preview that mirrors update_sales_order()'s decision tree
-- exactly, not Create's
-- ============================================================================
-- Migrations 0001-0072 are unmodified. Brand-new function — nothing to
-- DROP, no existing overload to collide with.
--
-- Problem (spec item 5): Patch 3.1 improved preview_sales_order() to match
-- create_sales_order() — correct for a NEW sale, but the Edit UI reused
-- that SAME preview even though update_sales_order()'s actual behavior is
-- structurally different: it preserves snapshots for financially-unchanged
-- items, tolerates an unchanged historical reference even if now inactive,
-- re-resolves snapshots only for the item that actually changed, and
-- preserves the payment-fee version snapshot when the payment method is
-- unchanged — whereas preview_sales_order() treats every item as brand new,
-- re-resolves everything, and requires every reference to be currently
-- active. Concrete break case the spec gives: a historical Sale has a Gold
-- Snapshot of 300; the Gold Master is later corrected to 310 for that same
-- date; the user opens Edit and changes only `notes`; the OLD preview would
-- show profit computed against 310, while a correct Save preserves the
-- original Snapshot of 300 — an unacceptable divergence between what Edit
-- previews and what Edit actually saves.
--
-- Fix: a SEPARATE, mode-aware preview that applies the EXACT SAME decision
-- tree as update_sales_order() (0075) — unchanged financial item -> preserve
-- its stored snapshot/cost columns verbatim, never recalculated; descriptive-
-- only change (item_name/description/sku) -> financials still preserved;
-- any actually-changed financial input (category_id/karat_id/weight_grams/
-- sale_price) -> recalculate ONLY that item, exactly like Save; brand-new
-- item (no id) -> fresh resolution, exactly like Save; an existing active
-- item omitted from the payload -> excluded from the preview output,
-- exactly as Save would soft-remove it; an unchanged reference that has
-- since become inactive is left as-is (never rejected); a NEWLY-selected
-- inactive reference is rejected, exactly like Save; payment method
-- unchanged -> the stored fee version/percentage/fixed snapshot is reused
-- verbatim, never re-resolved; payment method changed -> the fee version is
-- re-resolved, exactly like Save.
--
-- Writes NOTHING — no INSERT/UPDATE, no audit row, no advisory lock (same
-- reasoning 0070 gives for preview_sales_order(): a read-only preview has
-- nothing to protect by holding a lock only to release it at the end of its
-- own transaction; update_sales_order() itself remains the sole source of
-- truth and independently re-resolves everything under its own locks and
-- its own row_version check at actual Save time).
--
-- p_expected_version IS validated here (unlike the rest of the preview,
-- which is otherwise side-effect-free) so a client gets the SAME Conflict
-- feedback at Preview time that a stale Save would produce — early,
-- actionable UX, still fully compatible with "writes nothing to the DB"
-- since raising an exception performs no write.
-- ---------------------------------------------------------------------------
create or replace function public.preview_update_sales_order(
  p_order_id uuid,
  p_expected_version bigint,
  p_payment_method_id uuid,
  p_collection_channel_id uuid,
  p_items jsonb,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_can_view_profit boolean;
  v_old_order record;
  v_payment_method record;
  v_collection_channel record;
  v_payment_method_changed boolean;
  v_collection_channel_changed boolean;
  v_payment_fee record;
  v_payment_fee_version_id uuid;
  v_payment_fee_percentage numeric;
  v_payment_fee_fixed numeric;
  v_is_closed boolean;
  v_item jsonb;
  v_item_id uuid;
  v_seen_ids uuid[] := '{}'::uuid[];
  v_category_id uuid;
  v_karat_id uuid;
  v_weight numeric;
  v_sale_price numeric;
  v_existing record;
  v_category record;
  v_karat record;
  v_category_changed boolean;
  v_karat_changed boolean;
  v_financial_changed boolean;
  v_gold record;
  v_mfg record;
  v_vat record;
  v_costs record;
  v_subtotal numeric := 0;
  v_order_gross_profit numeric := 0;
  v_payment_fee_amount numeric;
  v_net_sales_profit numeric;
  v_items_json jsonb := '[]'::jsonb;
  v_item_json jsonb;
  v_calc_version integer;
begin
  if v_actor is null or not public.has_permission('sales.edit') then
    raise exception 'ليست لديك صلاحية معاينة تعديل عملية بيع' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  select * into v_old_order from public.sales_orders so where so.id = p_order_id;

  -- Item 9 — same VISIBLE-scope policy as the real update_sales_order()
  -- (0075): store_id is immutable, so a disabled store never blocks
  -- previewing/saving a correction to an existing historical Sale.
  if v_old_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_old_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  -- Early Conflict feedback — identical message/condition to the real
  -- update_sales_order() row_version check (0075), so a stale Edit session
  -- is told to reload before the user even attempts to Save.
  if p_expected_version is null or v_old_order.row_version <> p_expected_version then
    raise exception 'تم تعديل عملية البيع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الحفظ.' using errcode = 'P0001';
  end if;

  if p_payment_method_id is null or p_collection_channel_id is null then
    raise exception 'طريقة الدفع وقناة التحصيل كلاهما مطلوبان' using errcode = 'P0001';
  end if;

  select exists(
    select 1 from public.daily_closings
    where store_id = v_old_order.store_id and business_date = v_old_order.sale_date
  ) into v_is_closed;

  if v_is_closed and not public.has_permission('sales.edit_closed_day') then
    raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن تعديل عملية البيع إلا بصلاحية خاصة (sales.edit_closed_day)', v_old_order.sale_date using errcode = 'P0001';
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

  -- Item 2(B) parity — reuse the stored fee snapshot verbatim when the
  -- payment method is unchanged, exactly like the real update.
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

  -- Item 1 parity — validation-first pass, identical rules to the real update.
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

    if v_weight <= 0 then
      raise exception 'الوزن يجب أن يكون أكبر من صفر' using errcode = 'P0001';
    end if;

    if v_sale_price < 0 then
      raise exception 'سعر البيع لا يمكن أن يكون سالبًا' using errcode = 'P0001';
    end if;

    if v_item_id is null then
      -- New item — always fresh, exactly like the real update.
      perform public.validate_sales_item_precision(v_weight, v_sale_price);

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

      v_calc_version := 2;

      v_item_json := jsonb_build_object(
        'id', null, 'category_id', v_category_id, 'karat_id', v_karat_id,
        'weight_grams', v_weight::text, 'sale_price', v_sale_price::text,
        'category_name_ar', v_category.name_ar, 'karat_name_ar', v_karat.name_ar,
        'calculation_version', v_calc_version
      )
      || case when v_can_view_profit then jsonb_build_object(
        'gold_price_per_gram', v_gold.price_per_gram::text,
        'manufacturing_fee_per_gram', v_mfg.fee_per_gram::text,
        'vat_rate_percent', v_vat.rate_percent::text,
        'gold_component_cost', v_costs.gold_component_cost::text,
        'manufacturing_component_cost', v_costs.manufacturing_component_cost::text,
        'base_cost', v_costs.base_cost::text,
        'vat_cost', v_costs.vat_cost::text,
        'total_cost', v_costs.total_cost::text,
        'gross_profit', v_costs.gross_profit::text
      ) else '{}'::jsonb end;

      v_items_json := v_items_json || jsonb_build_array(v_item_json);
      v_subtotal := v_subtotal + v_sale_price;
      v_order_gross_profit := v_order_gross_profit + v_costs.gross_profit;
    else
      select * into v_existing from public.sales_order_items soi where soi.id = v_item_id;

      v_category_changed := (v_category_id is distinct from v_existing.category_id);
      v_karat_changed := (v_karat_id is distinct from v_existing.karat_id);
      v_financial_changed := v_category_changed or v_karat_changed
        or (v_weight is distinct from v_existing.weight_grams)
        or (v_sale_price is distinct from v_existing.sale_price);

      if v_financial_changed then
        -- Item 2(D)/4 parity — recalculate ONLY this item, validated first.
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
        end if;

        select * into v_gold from public.gold_price_version_for_karat_on_date(v_karat_id, v_old_order.sale_date);
        select * into v_mfg from public.manufacturing_fee_version_for_karat_on_date(v_karat_id, v_old_order.sale_date);
        select * into v_vat from public.vat_rate_version_for_date(v_old_order.sale_date);

        select * into v_costs from public.compute_sales_item_costs(
          v_gold.price_per_gram, v_mfg.fee_per_gram, v_vat.rate_percent, v_weight, v_sale_price
        );

        v_calc_version := 2;

        v_item_json := jsonb_build_object(
          'id', v_item_id, 'category_id', v_category_id, 'karat_id', v_karat_id,
          'weight_grams', v_weight::text, 'sale_price', v_sale_price::text,
          'category_name_ar', v_category.name_ar, 'karat_name_ar', v_karat.name_ar,
          'calculation_version', v_calc_version
        )
        || case when v_can_view_profit then jsonb_build_object(
          'gold_price_per_gram', v_gold.price_per_gram::text,
          'manufacturing_fee_per_gram', v_mfg.fee_per_gram::text,
          'vat_rate_percent', v_vat.rate_percent::text,
          'gold_component_cost', v_costs.gold_component_cost::text,
          'manufacturing_component_cost', v_costs.manufacturing_component_cost::text,
          'base_cost', v_costs.base_cost::text,
          'vat_cost', v_costs.vat_cost::text,
          'total_cost', v_costs.total_cost::text,
          'gross_profit', v_costs.gross_profit::text
        ) else '{}'::jsonb end;

        v_items_json := v_items_json || jsonb_build_array(v_item_json);
        v_subtotal := v_subtotal + v_sale_price;
        v_order_gross_profit := v_order_gross_profit + v_costs.gross_profit;
      else
        -- Item 2(A)/(C) parity — no financial input changed: the stored
        -- snapshot/cost/profit columns are echoed back VERBATIM, never
        -- recalculated, even if the applicable master data has since
        -- changed for this sale_date (the exact regression case the spec
        -- describes — a corrected Gold Master must NOT leak into an
        -- unrelated notes-only edit's preview).
        v_item_json := jsonb_build_object(
          'id', v_item_id, 'category_id', v_existing.category_id, 'karat_id', v_existing.karat_id,
          'weight_grams', v_existing.weight_grams::text, 'sale_price', v_existing.sale_price::text,
          'category_name_ar', v_existing.category_name_ar_snapshot, 'karat_name_ar', v_existing.karat_name_ar_snapshot,
          'calculation_version', v_existing.calculation_version
        )
        || case when v_can_view_profit then jsonb_build_object(
          'gold_price_per_gram', v_existing.gold_price_per_gram_snapshot::text,
          'manufacturing_fee_per_gram', v_existing.manufacturing_fee_per_gram_snapshot::text,
          'vat_rate_percent', v_existing.vat_rate_percent_snapshot::text,
          'gold_component_cost', v_existing.gold_component_cost::text,
          'manufacturing_component_cost', v_existing.manufacturing_component_cost::text,
          'base_cost', v_existing.base_cost::text,
          'vat_cost', v_existing.vat_cost::text,
          'total_cost', v_existing.total_cost::text,
          'gross_profit', v_existing.gross_profit::text
        ) else '{}'::jsonb end;

        v_items_json := v_items_json || jsonb_build_array(v_item_json);
        v_subtotal := v_subtotal + v_existing.sale_price;
        v_order_gross_profit := v_order_gross_profit + v_existing.gross_profit;
      end if;
    end if;
    -- An existing active item simply omitted from p_items is, exactly like
    -- the real update, never included here — mirroring the soft-remove
    -- Save would perform.
  end loop;

  v_payment_fee_amount := round((v_subtotal * v_payment_fee_percentage / 100) + v_payment_fee_fixed, 2);
  v_net_sales_profit := round(v_order_gross_profit, 2) - v_payment_fee_amount;

  return jsonb_build_object('subtotal', round(v_subtotal, 2)::text, 'items', v_items_json, 'is_day_closed', v_is_closed)
  || case when v_can_view_profit then jsonb_build_object(
    'gross_profit', round(v_order_gross_profit, 2)::text,
    'payment_fee_amount', v_payment_fee_amount::text,
    'net_sales_profit', v_net_sales_profit::text
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.preview_update_sales_order(uuid, bigint, uuid, uuid, jsonb, text, text, text) is
  'Patch 3.2 item 5 — Edit-mode preview, applying the EXACT SAME decision tree as update_sales_order() (0075): unchanged financial item -> stored snapshot echoed verbatim (never recalculated); changed financial item -> recalculated alone via the full-precision engine (0074), validated via validate_sales_item_precision() first; new item -> fresh resolution; item omitted from payload -> excluded, mirroring a soft-remove; unchanged inactive historical reference allowed, a newly-selected inactive reference rejected; payment method unchanged -> fee snapshot reused verbatim. Validates p_expected_version against the live row for early Conflict feedback but writes NOTHING (no INSERT/UPDATE/audit/lock) — update_sales_order() remains the sole source of truth. Used ONLY by the Edit form; the New Sale form continues to use preview_sales_order() (0077).';

revoke execute on function public.preview_update_sales_order(uuid, bigint, uuid, uuid, jsonb, text, text, text) from public;
grant execute on function public.preview_update_sales_order(uuid, bigint, uuid, uuid, jsonb, text, text, text) to authenticated;

-- ============================================================================
-- 0069: Phase 3 — Sales Integrity Patch 3.1 (5/7): update_sales_order()
-- rewritten — stable item identity, selective snapshot recalculation,
-- historical inactive-reference tolerance, row-lock against lost updates,
-- daily-close/financial-master concurrency locks
-- ============================================================================
-- Migrations 0001-0068 are unmodified. CREATE OR REPLACE of update_sales_
-- order() (0063) — same signature. This is the core of Patch 3.1 (items 1,
-- 2, 3, 5, 6, 7 all meet here). Summary of what changed vs 0063:
--
-- Item 1 (stable identity): NO MORE `delete from sales_order_items` +
-- full re-insert. Each element of p_items may now carry a nullable "id":
-- null = new item (fresh row, fresh id); an existing id = edit-in-place of
-- that EXACT row (never re-inserted — its id, created_at, created_by never
-- change). An existing active item whose id is absent from the new payload
-- is soft-removed (status='removed', removed_at=now(), removed_by=actor) —
-- never DELETEd, never re-usable. A submitted id must belong to this exact
-- order and currently be 'active', and duplicate ids within one payload are
-- rejected — both checked in a validation-first pass before any write.
--
-- Item 2 (selective snapshot recalculation): financial inputs are exactly
-- category_id/karat_id/weight_grams/sale_price (per item) and payment
-- method (order-level).
--   - An existing item whose financial inputs are byte-for-byte unchanged
--     is NEVER re-resolved — not touched at all if its metadata (item_name/
--     description/sku) is also unchanged; touched only for those metadata
--     columns otherwise. Its snapshot/cost/profit columns are never
--     rewritten.
--   - An existing item with ANY financial input changed gets a FULL
--     re-resolution of ITS OWN snapshots (based on the order's unchanged
--     sale_date) — no other item is touched.
--   - A brand-new item always gets a fresh resolution.
--   - Payment method unchanged -> the payment fee VERSION/percentage/fixed
--     snapshot are reused exactly as stored, never re-resolved (0-lookup) —
--     but payment_fee_amount/net_sales_profit are still recomputed via the
--     stored percentage/fixed against the (possibly item-edit-changed)
--     subtotal, since payment_fee_amount = f(subtotal, pct, fixed) is a
--     real accounting formula, not itself a snapshot (see the header
--     comment on the totals section below for the full reasoning — this is
--     a deliberate, documented interpretation of spec item 2(B)'s "لا تُعِد
--     حساب Payment Fee Version" as "don't re-RESOLVE the version," not
--     "freeze the derived amount even when its own subtotal input moves").
--   - Payment method CHANGED -> the fee VERSION is re-resolved (payment_
--     fee_for_method_on_date) and payment_fee_amount/net_sales_profit
--     recomputed — Gold/Manufacturing/VAT/item costs are never touched by
--     this alone.
--
-- Item 3 (historical inactive-reference tolerance): the "must be active"
-- check on category_id/karat_id (per item)/payment_method_id/
-- collection_channel_id (order-level) is enforced ONLY when that exact
-- reference is being introduced fresh (a new item) or CHANGED to a
-- different id than it already had. If the id is unchanged from what was
-- already stored, it is left exactly as-is — including its resolution
-- against sale_date if a recompute is independently triggered by another
-- financial input on the same item — even if the referenced master-data row
-- has since become inactive.
--
-- Item 5 (daily-close race): acquire_daily_close_lock_shared() (0065)
-- acquired right after the order row is located, before the daily_closings
-- check — same shared/exclusive pairing as create_sales_order() (0068)
-- against close_sales_day() (0071).
--
-- Item 6 (lost update): the order row is now located via
-- `... for update`, so a second concurrent update_sales_order() call on the
-- SAME order blocks until the first commits, then reads the LATEST
-- committed row as its own v_old_order (both for its own edit logic and for
-- the audit old_values) — never overwrites based on stale pre-lock data.
--
-- Item 7 (torn financial snapshot): acquire_financial_master_lock_shared()
-- (0065) acquired before the first financial-master read (payment fee
-- resolution, or the per-item gold/manufacturing/VAT resolution below),
-- held for the rest of the transaction.
-- ---------------------------------------------------------------------------
create or replace function public.update_sales_order(
  p_order_id uuid,
  p_payment_method_id uuid,
  p_collection_channel_id uuid,
  p_items jsonb,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_notes text default null,
  p_closed_day_reason text default null
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

  -- Item 6 — lock the target row NOW, before reading anything else about
  -- it. A concurrent update_sales_order() on the same order blocks here
  -- until this transaction commits/rolls back, then reads the state THIS
  -- transaction actually left behind — never a stale pre-lock snapshot.
  select * into v_old_order from public.sales_orders so where so.id = p_order_id for update;

  if v_old_order.id is null or not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_old_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if p_payment_method_id is null or p_collection_channel_id is null then
    raise exception 'طريقة الدفع وقناة التحصيل كلاهما مطلوبان' using errcode = 'P0001';
  end if;

  -- Item 5 — SHARED daily-close lock for the order's own (unchangeable)
  -- store/date, before consulting daily_closings.
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

  -- Item 3 — payment method: active check ONLY if it is actually changing.
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

  -- Item 3 — collection channel: same rule.
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

  -- Item 7 — SHARED financial-master lock before the first financial-master
  -- read below (payment fee resolution, if the method changed; otherwise
  -- the first per-item gold/manufacturing/VAT resolution).
  perform public.acquire_financial_master_lock_shared();

  -- Item 2(B) — payment fee: re-resolve the VERSION only if the method
  -- itself changed; otherwise reuse the stored snapshot exactly, no lookup.
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

  -- Full pre-edit ACTIVE item set, for the audit trail (§21) — captured
  -- under the row lock above, so this is the true "before" state.
  select coalesce(jsonb_agg(to_jsonb(it.*) order by it.line_no), '[]'::jsonb) into v_old_items_for_audit
  from public.sales_order_items it
  where it.sales_order_id = p_order_id and it.status = 'active';

  -- Item 1 — validation-first pass over every submitted id: no duplicates,
  -- every non-null id must belong to THIS order and currently be active.
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

  -- Next line_no considers EVERY row this order has ever had (active or
  -- removed) — line_no is never reused, even for a removed item's old slot.
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

    if v_item_id is null then
      -- ------------------------------------------------------------------
      -- New item (Item 2(E)) — always a fresh reference: category/karat
      -- must be active exactly like create_sales_order(), always a full
      -- resolution, always a new id and a new line_no.
      -- ------------------------------------------------------------------
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
        'active',
        v_actor, v_actor
      )
      returning sales_order_items.id into v_item_id;

      v_new_active_ids := array_append(v_new_active_ids, v_item_id);
    else
      -- ------------------------------------------------------------------
      -- Existing item, edit-in-place — id, created_by, created_at NEVER
      -- change. Ownership/duplicate/active-status already verified in the
      -- validation pass above.
      -- ------------------------------------------------------------------
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
        -- Item 3 — category/karat active check ONLY for a field that is
        -- actually changing to a different value; an unchanged reference is
        -- resolved as-is even if it has since become inactive.
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

        -- Item 2(D) — full re-resolution of THIS item's snapshots, based on
        -- the order's unchanged sale_date. May legitimately differ from the
        -- item's original snapshot if the applicable master data for that
        -- date was corrected since (e.g. a gold-price correction) — that is
        -- the intended behavior of a deliberate financial correction, not a
        -- bug (spec item 2 worked example).
        select * into v_gold from public.gold_price_version_for_karat_on_date(v_karat_id, v_old_order.sale_date);
        select * into v_mfg from public.manufacturing_fee_version_for_karat_on_date(v_karat_id, v_old_order.sale_date);
        select * into v_vat from public.vat_rate_version_for_date(v_old_order.sale_date);

        select * into v_costs from public.compute_sales_item_costs(
          v_gold.price_per_gram, v_mfg.fee_per_gram, v_vat.rate_percent, v_weight, v_sale_price
        );

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
            updated_by = v_actor
        where soi.id = v_item_id;
      elsif v_metadata_changed then
        -- Item 2(A)/(C) — no financial input changed: every snapshot/cost/
        -- profit column stays byte-for-byte as stored. Only touch the
        -- non-financial metadata columns that actually differ.
        update public.sales_order_items soi
        set item_name = v_item_name,
            description = v_description,
            sku = v_sku,
            updated_by = v_actor
        where soi.id = v_item_id;
      end if;
      -- else: absolutely nothing changed for this item (not even metadata)
      -- — no UPDATE at all, row is left byte-for-byte untouched.

      v_new_active_ids := array_append(v_new_active_ids, v_item_id);
    end if;
  end loop;

  -- Item 1(E) — an existing active item whose id was not resubmitted is
  -- soft-removed, never deleted, id never reused.
  update public.sales_order_items soi
  set status = 'removed', removed_at = now(), removed_by = v_actor
  where soi.sales_order_id = p_order_id
    and soi.status = 'active'
    and soi.id <> all(v_new_active_ids);

  -- Totals are always recomputed from the FINAL active-item set — this is
  -- the one place spec item 2's "don't touch unrelated data" and spec item
  -- 8's "sale_price = total_cost + gross_profit" / "order totals = SUM
  -- (active items)" reconciliation invariants meet: subtotal/gross_profit
  -- are aggregates, not themselves snapshots, so they are legitimately
  -- re-derived every time regardless of which specific edit type occurred
  -- (a pure metadata edit still re-derives the SAME numbers from the SAME
  -- unchanged active items — mathematically a no-op, never a drift).
  select coalesce(sum(sale_price), 0), coalesce(sum(gross_profit), 0)
  into v_subtotal, v_order_gross_profit
  from public.sales_order_items
  where sales_order_id = p_order_id and status = 'active';

  v_payment_fee_amount := round((v_subtotal * v_payment_fee_percentage / 100) + v_payment_fee_fixed, 2);
  v_net_sales_profit := round(v_order_gross_profit, 2) - v_payment_fee_amount;

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
      updated_by = v_actor
  where sales_orders.id = p_order_id;

  perform public.log_audit_event(
    'sale.update', 'sales_order', p_order_id,
    jsonb_build_object('order_number', v_old_order.order_number, 'items', v_old_items_for_audit,
      'payment_method_id', v_old_order.payment_method_id, 'collection_channel_id', v_old_order.collection_channel_id,
      'customer_name', v_old_order.customer_name, 'customer_phone', v_old_order.customer_phone, 'notes', v_old_order.notes,
      'subtotal', v_old_order.subtotal, 'net_sales_profit', v_old_order.net_sales_profit),
    jsonb_build_object('order_number', v_old_order.order_number, 'payment_method_id', p_payment_method_id, 'collection_channel_id', p_collection_channel_id,
      'customer_name', p_customer_name, 'customer_phone', p_customer_phone, 'notes', p_notes,
      'subtotal', round(v_subtotal, 2), 'net_sales_profit', v_net_sales_profit)
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

comment on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text) is
  'Patch 3.1 rewrite (items 1/2/3/5/6/7) — the single transactional entry point for editing a Sale. order_number/created_by/created_at/calculation_version/store_id/sale_date remain never-editable. Items carry a nullable id: null=new, existing id=edit-in-place (never re-inserted, id/created_at/created_by permanent); an item omitted from the payload is soft-removed (status=''removed'') not deleted. Snapshot/cost columns for an existing item are recomputed ONLY if one of its financial inputs (category_id/karat_id/weight_grams/sale_price) actually changed; otherwise left byte-for-byte untouched. category_id/karat_id/payment_method_id/collection_channel_id active-status is enforced only when that exact reference is new or changing, never for an unchanged historical reference. Locks the target row (`for update`) against lost updates, and acquires acquire_daily_close_lock_shared()/acquire_financial_master_lock_shared() (0065) exactly like create_sales_order() (0068). SECURITY DEFINER.';

revoke execute on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text) from public;
grant execute on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text) to authenticated;

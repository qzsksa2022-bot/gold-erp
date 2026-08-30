-- ============================================================================
-- 0084: Phase 4 — Returns Core (3/10): update_sales_order() financial lock
-- after an approved return exists
-- ============================================================================
-- Migrations 0001-0083 are unmodified, including 0075/0081 themselves — this
-- is a fresh CREATE OR REPLACE of update_sales_order() with the EXACT SAME
-- signature as 0081 (9 params, ending p_expected_version bigint) — Postgres
-- allows CREATE OR REPLACE to keep the same overload when the argument TYPE
-- list is unchanged, no DROP FUNCTION needed here (unlike 0075, which added
-- a new trailing parameter). Every fix from Patch 3.1/3.2/Hotfix 3.2.1 —
-- stable item ids, soft-remove not delete, selective snapshot
-- recalculation, historical inactive-reference tolerance, daily-close/
-- financial-master shared locks, optimistic concurrency, disabled-store
-- historical-edit policy, full-precision engine, calculation_version
-- stamping (now =2 on the header, per 0081) — is preserved byte-for-byte
-- below; the ONLY change is one new guard block, inserted immediately after
-- the existing row_version conflict check and before anything else is
-- validated or written.
--
-- ---------------------------------------------------------------------------
-- The rule (Phase 4 spec): once ANY effective return exists for an order
-- (sales_returns.status = 'approved' — approved and not yet reversed), the
-- Sale becomes financially locked. Only metadata may still be edited:
-- customer_name/customer_phone/notes at the header, item_name/description/
-- sku per item. Any attempted payment_method_id/collection_channel_id
-- change, any item category/karat/weight/sale_price change, or any item
-- add/remove is rejected outright, before any write happens. This protects
-- the snapshot integrity a Return already captured at its own creation time
-- (sales_return_items.*_snapshot, 0082) from ever being invalidated by a
-- retroactive edit to the very Sale it was computed against.
--
-- acquire_returns_order_lock_exclusive() (0082) is taken before the check
-- below runs, so this guard can never race a concurrent approve_sales_
-- return() call on the same order — either this transaction's check sees
-- the return as already-approved (and correctly locks), or it blocks until
-- the concurrent approval commits/rolls back first.
-- ---------------------------------------------------------------------------
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
  -- Phase 4 additions:
  v_has_effective_return boolean;
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

  if v_old_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_old_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if v_old_order.row_version <> p_expected_version then
    raise exception 'تم تعديل عملية البيع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الحفظ.' using errcode = 'P0001';
  end if;

  -- ---------------------------------------------------------------------
  -- Phase 4 — financial lock after an approved return. Acquired BEFORE the
  -- check itself so this cannot race a concurrent approve_sales_return()
  -- on the same order (0082/0087).
  -- ---------------------------------------------------------------------
  perform public.acquire_returns_order_lock_exclusive(p_order_id);

  select exists(
    select 1 from public.sales_returns sr
    where sr.sales_order_id = p_order_id and sr.status = 'approved'
  ) into v_has_effective_return;

  if v_has_effective_return then
    if p_payment_method_id is distinct from v_old_order.payment_method_id
       or p_collection_channel_id is distinct from v_old_order.collection_channel_id then
      raise exception 'لا يمكن تعديل طريقة الدفع أو قناة التحصيل — يوجد مرتجع معتمد على هذه العملية. التعديلات المسموحة بعد اعتماد مرتجع هي بيانات وصفية فقط (اسم/هاتف العميل، الملاحظات، واسم/وصف/رمز البند)' using errcode = 'P0001';
    end if;

    if exists (
      select 1 from public.sales_order_items soi
      where soi.sales_order_id = p_order_id and soi.status = 'active'
        and not exists (
          select 1 from jsonb_array_elements(p_items) it
          where (it ->> 'id') is not null and (it ->> 'id')::uuid = soi.id
        )
    ) then
      raise exception 'لا يمكن حذف بنود من عملية البيع — يوجد مرتجع معتمد على هذه العملية' using errcode = 'P0001';
    end if;

    for v_item in select * from jsonb_array_elements(p_items)
    loop
      if (v_item ->> 'id') is null then
        raise exception 'لا يمكن إضافة بنود جديدة — يوجد مرتجع معتمد على هذه العملية' using errcode = 'P0001';
      end if;

      select * into v_existing from public.sales_order_items soi where soi.id = (v_item ->> 'id')::uuid;

      if v_existing.id is null then
        raise exception 'بند غير موجود ضمن عملية البيع هذه (id: %)', (v_item ->> 'id') using errcode = 'P0001';
      end if;

      if (v_item ->> 'category_id')::uuid is distinct from v_existing.category_id
         or (v_item ->> 'karat_id')::uuid is distinct from v_existing.karat_id
         or (v_item ->> 'weight_grams')::numeric is distinct from v_existing.weight_grams
         or (v_item ->> 'sale_price')::numeric is distinct from v_existing.sale_price then
        raise exception 'لا يمكن تعديل الفئة أو العيار أو الوزن أو سعر البيع لأي بند — يوجد مرتجع معتمد على هذه العملية (id: %)', (v_item ->> 'id') using errcode = 'P0001';
      end if;
    end loop;
  end if;
  -- ---------------------------------------------------------------------

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

    if v_item_id is null then
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
      row_version = v_new_row_version,
      calculation_version = 2,
      updated_by = v_actor
  where sales_orders.id = p_order_id;

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
  'Phase 4 rewrite (supersedes 0075/0081''s body, IDENTICAL signature) — adds exactly one new guard: once an effective return exists for this order (sales_returns.status=''approved'', checked under acquire_returns_order_lock_exclusive(), 0082), only metadata fields (customer_name/phone/notes, item_name/description/sku) may still be edited — any payment method/collection channel change, any item financial change, or any item add/remove is rejected before any write happens. Every Patch 3.1/3.2/Hotfix 3.2.1 fix (optimistic concurrency, disabled-store historical-edit policy, full-precision engine, calculation_version=2 stamping on both header and recalculated items, complete audit old/new) is preserved unchanged. SECURITY DEFINER.';

-- No REVOKE/GRANT change — same signature as 0075, already
-- authenticated-only (0075's own REVOKE/GRANT already covers this exact
-- overload; CREATE OR REPLACE does not reset existing grants).

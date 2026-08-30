-- ============================================================================
-- 0075: Phase 3 — Final Sales Integrity Patch 3.2 (3/8): real optimistic
-- concurrency control (row_version), disabled-store historical-edit policy,
-- full-precision engine + input validation wiring, calculation_version
-- stamping, and complete update audit old/new — update_sales_order()
-- ============================================================================
-- Migrations 0001-0072 are unmodified, including 0069 itself — this is a
-- fresh CREATE OR REPLACE of update_sales_order() with the SAME parameter
-- list as 0069 PLUS exactly one new trailing parameter (Postgres only
-- allows CREATE OR REPLACE to ADD parameters at the very end, and only with
-- a DEFAULT — so p_expected_version is appended last, `default null`, with
-- an internal null-check that makes it effectively required despite the
-- SQL-level default). Every structural fix from Patch 3.1 that 0069 built —
-- stable item ids, soft-remove instead of delete, selective snapshot
-- recalculation, historical inactive-reference tolerance for an UNCHANGED
-- reference, the daily-close/financial-master shared locks — is preserved
-- byte-for-byte below; only the four things Patch 3.2 requires changed are
-- new/updated: optimistic concurrency (item 2), the store-scope policy for
-- editing a Sale whose store has since been disabled (item 9), full-
-- precision cost engine + DB-level precision validation (items 3/4, via
-- 0074), and calculation_version stamping (item 7) + complete audit
-- old/new (item 10).
--
-- ---------------------------------------------------------------------------
-- Part A — row_version column (item 2).
-- ---------------------------------------------------------------------------
alter table public.sales_orders
  add column if not exists row_version bigint not null default 1;

comment on column public.sales_orders.row_version is
  'Patch 3.2 item 2 — optimistic-concurrency token. Incremented by exactly 1 on every successful update_sales_order() call. get_sales_order() (0079) returns the current value; a client MUST send it back as p_expected_version on update_sales_order(); a mismatch is rejected with a Conflict error rather than silently overwritten (see update_sales_order() below). This REPLACES relying on `select ... for update` alone as the concurrency guard: the row lock alone only serializes concurrent writers, it does not stop a serialized-but-stale payload from silently winning (classic last-write-wins) — row_version closes that gap.';

-- ---------------------------------------------------------------------------
-- Part B — why `for update` alone (0069) is not enough, and what changes
-- (item 2).
--
-- 0069 locks the target row with `for update` before reading it, which
-- correctly serializes two concurrent update_sales_order() calls on the
-- SAME order so they can never interleave their writes — but it does NOT
-- stop the SECOND caller, once it acquires the lock and proceeds, from
-- blindly applying ITS OWN payload (which was built from data the user
-- loaded before the FIRST caller's edit committed) on top of the first
-- caller's already-committed changes. The second caller's edit silently
-- wins and the first caller's committed changes are lost with no error to
-- anyone — textbook Lost Update, `for update` only fixed the interleaving,
-- not the staleness.
--
-- Fix: real Optimistic Concurrency Control via row_version. Order of
-- operations, exactly per spec: (1) lock the row `for update` (kept,
-- unchanged — still needed so two concurrent writers can''t even READ each
-- other''s in-flight uncommitted state); (2) read the row''s CURRENT
-- row_version, now guaranteed to be the latest committed value because of
-- the lock; (3) compare it against the caller-supplied p_expected_version —
-- on mismatch, reject with a clear, greppable-by-message Conflict error
-- BEFORE touching anything else, so a stale caller''s payload is never
-- applied at all; (4) if it matches, proceed exactly as before; (5) on
-- success, row_version = row_version + 1, so the very next reader/editor
-- must present THIS transaction''s new version to succeed.
--
-- Mandatory scenario this closes: A and B both load version=5. A saves
-- first -> version becomes 6. B (which was blocked on the `for update` lock
-- while A''s transaction was open) now acquires the lock, but B''s
-- p_expected_version is still 5 while the row''s actual row_version is now
-- 6 -> B''s call FAILS with a Conflict, A''s committed edit is never
-- silently overwritten. B must reload (observing version=6), re-apply its
-- edit on top of A''s change, and resubmit with p_expected_version=6 to
-- succeed -> version becomes 7. The UI layer (src/features/sales) must
-- never auto-resubmit the same stale payload on a Conflict — it must show
-- the Arabic message below and require the user to reload and reconcile.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Part C — disabled-store historical-edit policy (item 9).
--
-- Problem: Sales READ (0070) already resolves store scope via
-- user_visible_store_ids() (broader — includes disabled stores the actor
-- can still see historically), but 0069's update_sales_order() resolves
-- scope via user_operable_store_ids() (narrower — excludes disabled
-- stores). Result: a historical Sale in a store that is later disabled
-- remains visible and its Edit page opens, but Save always fails, with no
-- warning at the point the user opens Edit at all.
--
-- Chosen, explicit policy (the user''s stated preference, since store_id
-- itself is immutable on edit — spec item 9): Create Sale and Close Day
-- both continue to require the OPERABLE scope (unchanged, matches
-- create_sales_order()/close_sales_day(), 0068/0071/0076 — a NEW Sale or a
-- day close should never target a disabled store). Editing an EXISTING
-- Sale, by contrast, is allowed as long as the store is within the actor''s
-- VISIBLE scope AND the actor holds sales.edit — because store_id cannot be
-- changed via update_sales_order() at all (it is not even a parameter),
-- disabling a store must not, by itself, block correcting a historical
-- record that already belongs to it. The daily-close rule is unaffected and
-- still applies exactly as before (a closed day still needs
-- sales.edit_closed_day + a reason, regardless of the store''s
-- enabled/disabled state).
-- ---------------------------------------------------------------------------
-- IMPORTANT: adding a trailing parameter changes this function's argument
-- signature (uuid,uuid,uuid,jsonb,text,text,text,text) ->
-- (uuid,uuid,uuid,jsonb,text,text,text,text,bigint). CREATE OR REPLACE only
-- replaces a function whose argument-type list matches EXACTLY — a changed
-- signature creates a NEW, separate overload instead, leaving the OLD
-- 8-argument version reachable and callable with no p_expected_version at
-- all, completely bypassing the optimistic-concurrency check this migration
-- exists to add. The old overload is therefore explicitly dropped first so
-- exactly one update_sales_order() exists afterward.
drop function if exists public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text);

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

  -- Row lock (unchanged from 0069) — a concurrent update_sales_order() on
  -- the same order blocks here until this transaction commits/rolls back.
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
      updated_by = v_actor
  where sales_orders.id = p_order_id;

  -- Item 10 — complete audit: new_values now carries the FINAL active items
  -- array (previously missing entirely), plus calculation_version/
  -- row_version/snapshots/totals on BOTH sides, so old vs new together
  -- fully explains what changed, not just the header.
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
      'calculation_version', v_old_order.calculation_version, 'row_version', v_new_row_version)
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
  'Patch 3.2 rewrite (items 2/3/4/7/9/10, supersedes 0069''s body, same signature plus trailing p_expected_version) — adds real optimistic concurrency control (row lock still taken first, but the caller''s p_expected_version is compared against the just-locked row''s row_version and a stale caller is rejected with a clear Arabic Conflict message BEFORE any edit is applied; row_version increments by 1 on success); changes the store-scope check from user_operable_store_ids() to user_visible_store_ids() so a store disabled after a Sale was created no longer blocks correcting that historical Sale (store_id itself remains immutable here); uses the Patch 3.2 full-precision compute_sales_item_costs() (0074) and validate_sales_item_precision() (0074, called before any recalculation) instead of the 0065 engine; stamps calculation_version=2 on every new or financially-recalculated item while leaving an untouched item''s version exactly as stored (no forced upgrade); and writes a complete sale.update audit row whose new_values now includes the final active items array (previously header-only) alongside old_values, plus calculation_version/row_version/payment_fee_amount/gross_profit on both sides. Every Patch 3.1 structural fix (stable item ids, soft-remove not delete, selective snapshot recalculation, historical inactive-reference tolerance for unchanged references, daily-close/financial-master shared locks) is preserved unchanged. SECURITY DEFINER.';

revoke execute on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text, bigint) from public;
grant execute on function public.update_sales_order(uuid, uuid, uuid, jsonb, text, text, text, text, bigint) to authenticated;

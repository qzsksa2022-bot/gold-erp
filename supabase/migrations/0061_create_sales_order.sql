-- ============================================================================
-- 0061: Phase 3 — Sales Core (4/8): create_sales_order()
-- ============================================================================
-- Migrations 0001-0060 are unmodified.
--
-- ---------------------------------------------------------------------------
-- Part A — three new financial-version resolvers.
--
-- gold_price_for_karat_on_date() (0041/0057), manufacturing_fee_for_karat_
-- on_date() (0042/0056), and vat_rate_for_date() (0058) all deliberately
-- return only the resolved NUMERIC value, matching their established public
-- API contract used throughout Phase 2 — this migration does not touch or
-- replace any of them. A sales_order_items row, however, must snapshot BOTH
-- the resolved value AND the exact source row's id (daily_gold_price_id /
-- manufacturing_fee_version_id / vat_rate_version_id — spec §8), so Sales
-- needs a sibling for each that returns (id, value) together — exactly the
-- shape payment_fee_for_method_on_date() (0045/0056) already returns for
-- payment fees (fee_version_id, percentage_fee, fixed_fee). These three new
-- functions are purely additive resolvers with byte-for-byte the same
-- resolution predicate as their value-only counterparts (STABLE, SECURITY
-- INVOKER, PUBLIC EXECUTE, same P0001 "not found" behavior) — nothing about
-- the existing functions changes.
-- ---------------------------------------------------------------------------
create or replace function public.gold_price_version_for_karat_on_date(p_karat_id uuid, p_date date default public.business_today())
returns table (daily_gold_price_id uuid, price_per_gram numeric)
language plpgsql
stable
as $$
declare
  v_row record;
begin
  select daily_gold_prices.id, daily_gold_prices.price_per_gram into v_row
  from public.daily_gold_prices
  where karat_id = p_karat_id and price_date = p_date;

  if v_row.id is null then
    raise exception 'لا يوجد سعر ذهب مسجَّل لهذا العيار بتاريخ %', p_date using errcode = 'P0001';
  end if;

  daily_gold_price_id := v_row.id;
  price_per_gram := v_row.price_per_gram;
  return next;
end;
$$;

comment on function public.gold_price_version_for_karat_on_date(uuid, date) is
  'Additive sibling of gold_price_for_karat_on_date() (0041/0057) that also returns the source daily_gold_prices row''s id, for Sales snapshot columns (sales_order_items.daily_gold_price_id, spec §8). Identical resolution/error behavior otherwise.';

create or replace function public.manufacturing_fee_version_for_karat_on_date(p_karat_id uuid, p_date date default public.business_today())
returns table (manufacturing_fee_version_id uuid, fee_per_gram numeric)
language plpgsql
stable
as $$
declare
  v_row record;
begin
  select manufacturing_fee_versions.id, manufacturing_fee_versions.fee_per_gram into v_row
  from public.manufacturing_fee_versions
  where karat_id = p_karat_id
    and status <> 'cancelled'
    and effective_from <= p_date
    and (effective_to is null or effective_to >= p_date)
  order by effective_from desc
  limit 1;

  if v_row.id is null then
    raise exception 'لا توجد مصنعية معتمدة لهذا العيار بتاريخ %', p_date using errcode = 'P0001';
  end if;

  manufacturing_fee_version_id := v_row.id;
  fee_per_gram := v_row.fee_per_gram;
  return next;
end;
$$;

comment on function public.manufacturing_fee_version_for_karat_on_date(uuid, date) is
  'Additive sibling of manufacturing_fee_for_karat_on_date() (0042/0056) that also returns the source manufacturing_fee_versions row''s id, for Sales snapshot columns. Identical resolution/error behavior otherwise.';

create or replace function public.vat_rate_version_for_date(p_date date default public.business_today())
returns table (vat_rate_version_id uuid, rate_percent numeric)
language plpgsql
stable
as $$
declare
  v_row record;
begin
  select vat_rate_versions.id, vat_rate_versions.rate_percent into v_row
  from public.vat_rate_versions
  where status <> 'cancelled'
    and effective_from <= p_date
    and (effective_to is null or effective_to >= p_date)
  order by effective_from desc
  limit 1;

  if v_row.id is null then
    raise exception 'لا يوجد إصدار ضريبة قيمة مضافة معتمد بتاريخ %', p_date using errcode = 'P0001';
  end if;

  vat_rate_version_id := v_row.id;
  rate_percent := v_row.rate_percent;
  return next;
end;
$$;

comment on function public.vat_rate_version_for_date(date) is
  'Additive sibling of vat_rate_for_date() (0058) that also returns the source vat_rate_versions row''s id, for Sales snapshot columns. Identical resolution/error behavior otherwise.';

-- ---------------------------------------------------------------------------
-- Part B — create_sales_order(): the single transactional entry point for
-- creating a Sale (spec §11). No client-side "insert order then loop insert
-- items" — the app calls this ONE RPC with only business inputs; every
-- financial value is resolved and computed inside this function from
-- official sources, never accepted from the caller (spec §6/§24 — the JSON
-- payload below is read for exactly: store_id, sale_date, payment_method_id,
-- collection_channel_id, customer_name/phone, notes, and per-item
-- category_id/karat_id/weight_grams/sale_price/item_name/description/sku —
-- nothing else is ever read from p_items even if a caller includes extra
-- keys like a fabricated cost/profit/snapshot field).
--
-- Concurrency/isolation (spec §25): runs under the database's default READ
-- COMMITTED isolation. Every financial resolution here (gold price,
-- manufacturing fee, VAT rate, payment fee) is a single point-in-time SELECT
-- against a specific (karat/method, date) — not a multi-step check-then-act
-- window against the SAME row a concurrent writer could also be modifying
-- (that concern already has its own dedicated locking — the `for update`
-- guard inside create_manufacturing_fee_version() et al., 0042/0047 — which
-- governs concurrent *version creation*, not concurrent *reads* of already-
-- committed versions). A concurrent gold-price change during this
-- transaction therefore cannot produce a torn/mixed snapshot: this
-- transaction either sees the price as it was before that change committed,
-- or (if the other transaction committed first) the new price — always one
-- consistent, real value, never a hybrid. order_number generation is safe
-- under true concurrency because it comes from a SEQUENCE (nextval() is
-- atomic and never blocks on or conflicts with another concurrent call,
-- spec §5/§25).
create or replace function public.create_sales_order(
  p_store_id uuid,
  p_sale_date date,
  p_payment_method_id uuid,
  p_collection_channel_id uuid,
  p_items jsonb,
  p_customer_name text default null,
  p_customer_phone text default null,
  p_notes text default null,
  -- Mandatory, non-empty reason — ONLY required (and only checked) when
  -- p_sale_date's business day is already closed for p_store_id AND the
  -- actor holds sales.edit_closed_day (spec §20). Ignored/unused otherwise.
  p_closed_day_reason text default null
)
returns table (id uuid, order_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_today date := public.business_today();
  v_order_id uuid;
  v_order_number text;
  v_payment_method record;
  v_collection_channel record;
  v_payment_fee record; -- fee_version_id, percentage_fee, fixed_fee
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_item jsonb;
  v_line_no integer := 0;
  v_category_id uuid;
  v_karat_id uuid;
  v_weight numeric;
  v_sale_price numeric;
  v_item_name text;
  v_description text;
  v_sku text;
  v_category record;
  v_karat record;
  v_gold record; -- daily_gold_price_id, price_per_gram
  v_mfg record;  -- manufacturing_fee_version_id, fee_per_gram
  v_vat record;  -- vat_rate_version_id, rate_percent
  v_gold_component numeric;
  v_mfg_component numeric;
  v_base_cost numeric;
  v_vat_cost numeric;
  v_total_cost numeric;
  v_item_gross_profit numeric;
  v_subtotal numeric := 0;
  v_order_gross_profit numeric := 0;
  v_payment_fee_amount numeric;
  v_net_sales_profit numeric;
  v_item_id uuid;
begin
  -- 1-2) Authenticate actor + sales.create permission. has_permission()
  -- already fails closed for auth.uid() is null (is_active_user() finds no
  -- matching active profile) and for a non-active profile (0008) — the
  -- explicit v_actor is null check below exists only to give a distinct,
  -- unambiguous message rather than folding into the generic permission
  -- error text.
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لإنشاء عملية بيع' using errcode = 'P0001';
  end if;

  if not public.has_permission('sales.create') then
    raise exception 'ليست لديك صلاحية إنشاء عمليات بيع' using errcode = 'P0001';
  end if;

  -- 3) Actor active — redundant with has_permission()'s own is_active_user()
  -- check above, kept explicit for defense-in-depth per spec §11 step 3.
  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_store_id is null or p_sale_date is null or p_payment_method_id is null or p_collection_channel_id is null then
    raise exception 'المتجر وتاريخ البيع وطريقة الدفع وقناة التحصيل كلها مطلوبة' using errcode = 'P0001';
  end if;

  -- 4-5) Store must be within the actor's OPERABLE scope (spec §14) —
  -- user_operable_store_ids() (0031) already filters to active stores only
  -- and fails closed for an inactive actor, so this one check covers scope,
  -- existence, and active status together.
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'هذا المتجر غير متاح لك لإنشاء عمليات بيع فيه، أو أنه غير نشط' using errcode = 'P0001';
  end if;

  -- 6) sale_date allowed. Never in the future (a Sale cannot be recorded
  -- for a business day that has not happened yet — the same principle
  -- close_sales_day() (0064) enforces for closing a day, applied here to
  -- creating one; not a literal spec §11 bullet, but a direct, undisputed
  -- consequence of "sale_date is a business date" that this project's
  -- convention already applies everywhere else "today" is business-
  -- meaningful). Back-dating to a PAST open day is allowed (e.g. entering
  -- yesterday's sale the next morning) — only a genuinely future date is
  -- rejected.
  if p_sale_date > v_today then
    raise exception 'لا يمكن تسجيل عملية بيع بتاريخ مستقبلي (%)', p_sale_date using errcode = 'P0001';
  end if;

  select exists(
    select 1 from public.daily_closings
    where store_id = p_store_id and business_date = p_sale_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('sales.edit_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن إنشاء عملية بيع جديدة فيه إلا بصلاحية خاصة (sales.edit_closed_day)', p_sale_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لإنشاء عملية بيع في يوم مقفل (%)', p_sale_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  -- 7) Master references — payment method / collection channel must exist
  -- and be active for a NEW sale (spec §12).
  select * into v_payment_method from public.payment_methods where payment_methods.id = p_payment_method_id;
  if v_payment_method.id is null then
    raise exception 'طريقة الدفع غير موجودة' using errcode = 'P0001';
  end if;
  if v_payment_method.status <> 'active' then
    raise exception 'طريقة الدفع "%" غير نشطة — لا يمكن استخدامها في عملية بيع جديدة', v_payment_method.name_ar using errcode = 'P0001';
  end if;

  select * into v_collection_channel from public.collection_channels where collection_channels.id = p_collection_channel_id;
  if v_collection_channel.id is null then
    raise exception 'قناة التحصيل غير موجودة' using errcode = 'P0001';
  end if;
  if v_collection_channel.status <> 'active' then
    raise exception 'قناة التحصيل "%" غير نشطة — لا يمكن استخدامها في عملية بيع جديدة', v_collection_channel.name_ar using errcode = 'P0001';
  end if;

  -- 8 (order-level) Resolve the payment fee version for this method/date —
  -- raises a clear message (spec §9's exact COD example) if unconfigured,
  -- never assumes 0%.
  select * into v_payment_fee from public.payment_fee_for_method_on_date(p_payment_method_id, p_sale_date);

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'يجب أن تحتوي عملية البيع على بند واحد على الأقل' using errcode = 'P0001';
  end if;

  -- 11 (partial) Order number + header row FIRST (with placeholder totals
  -- that are corrected below once every item is resolved and computed) —
  -- sales_order_items.sales_order_id is NOT NULL, so the header must exist
  -- before any item row can be inserted.
  v_order_number := public.generate_sales_order_number();

  insert into public.sales_orders (
    order_number, store_id, sale_date, salesperson_id, payment_method_id, collection_channel_id,
    customer_name, customer_phone, notes,
    payment_fee_version_id, payment_fee_percentage_snapshot, payment_fee_fixed_snapshot,
    payment_fee_amount, subtotal, gross_profit, net_sales_profit, calculation_version,
    created_by, updated_by
  ) values (
    v_order_number, p_store_id, p_sale_date, v_actor, p_payment_method_id, p_collection_channel_id,
    nullif(btrim(coalesce(p_customer_name, '')), ''), nullif(btrim(coalesce(p_customer_phone, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''),
    v_payment_fee.fee_version_id, v_payment_fee.percentage_fee, v_payment_fee.fixed_fee,
    0, 0, 0, 0, 1,
    v_actor, v_actor
  )
  returning sales_orders.id into v_order_id;

  -- 8-10 (per item) Resolve every item's financial snapshots and compute
  -- its cost breakdown per spec §2, using full NUMERIC precision throughout
  -- this loop — every column below is only ever rounded to 2dp at the
  -- moment it is written to a numeric(14,2) column (spec §7: round only at
  -- the final output boundary, and each of these breakdown columns is
  -- itself a real accounting output, not merely an internal step, so each
  -- is rounded independently from the same shared full-precision chain
  -- rather than derived by summing already-rounded siblings — see this
  -- migration's DELIVERY_REPORT appendix for the full rationale).
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_line_no := v_line_no + 1;

    if v_item ->> 'category_id' is null or v_item ->> 'karat_id' is null
       or v_item ->> 'weight_grams' is null or v_item ->> 'sale_price' is null then
      raise exception 'كل بند يجب أن يحدد التصنيف والعيار والوزن وسعر البيع (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;

    v_category_id := (v_item ->> 'category_id')::uuid;
    v_karat_id := (v_item ->> 'karat_id')::uuid;
    v_weight := (v_item ->> 'weight_grams')::numeric;
    v_sale_price := (v_item ->> 'sale_price')::numeric;
    v_item_name := nullif(btrim(coalesce(v_item ->> 'item_name', '')), '');
    v_description := nullif(btrim(coalesce(v_item ->> 'description', '')), '');
    v_sku := nullif(btrim(coalesce(v_item ->> 'sku', '')), '');

    if v_weight <= 0 then
      raise exception 'الوزن يجب أن يكون أكبر من صفر (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;

    if v_sale_price < 0 then
      raise exception 'سعر البيع لا يمكن أن يكون سالبًا (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;

    -- 12) Active master data rules (spec §12) — category and karat must be
    -- active for a NEW sale.
    select * into v_category from public.product_categories where product_categories.id = v_category_id;
    if v_category.id is null then
      raise exception 'التصنيف غير موجود (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;
    if v_category.status <> 'active' then
      raise exception 'التصنيف "%" غير نشط — لا يمكن استخدامه في عملية بيع جديدة (بند رقم %)', v_category.name_ar, v_line_no using errcode = 'P0001';
    end if;

    select * into v_karat from public.karats where karats.id = v_karat_id;
    if v_karat.id is null then
      raise exception 'العيار غير موجود (بند رقم %)', v_line_no using errcode = 'P0001';
    end if;
    if v_karat.status <> 'active' then
      raise exception 'عيار "%" غير نشط — لا يمكن استخدامه في عملية بيع جديدة (بند رقم %)', v_karat.name_ar, v_line_no using errcode = 'P0001';
    end if;

    -- Fail-loud financial resolution (spec §9) — each raises its own clear
    -- Arabic P0001 message (e.g. "لا يوجد سعر ذهب لعيار % بتاريخ %") if
    -- unconfigured for this exact (karat, sale_date); never a fabricated
    -- zero/default.
    select * into v_gold from public.gold_price_version_for_karat_on_date(v_karat_id, p_sale_date);
    select * into v_mfg from public.manufacturing_fee_version_for_karat_on_date(v_karat_id, p_sale_date);
    select * into v_vat from public.vat_rate_version_for_date(p_sale_date);

    v_gold_component := v_gold.price_per_gram * v_weight;
    v_mfg_component := v_mfg.fee_per_gram * v_weight;
    v_base_cost := v_gold_component + v_mfg_component;
    v_vat_cost := v_base_cost * v_vat.rate_percent / 100;
    v_total_cost := v_base_cost + v_vat_cost;
    v_item_gross_profit := v_sale_price - v_total_cost;

    insert into public.sales_order_items (
      sales_order_id, line_no, category_id, karat_id, item_name, description, sku,
      weight_grams, sale_price,
      category_name_ar_snapshot, karat_code_snapshot, karat_name_ar_snapshot,
      daily_gold_price_id, gold_price_per_gram_snapshot,
      manufacturing_fee_version_id, manufacturing_fee_per_gram_snapshot,
      vat_rate_version_id, vat_rate_percent_snapshot,
      gold_component_cost, manufacturing_component_cost, base_cost, vat_cost, total_cost, gross_profit,
      created_by, updated_by
    ) values (
      v_order_id, v_line_no, v_category_id, v_karat_id, v_item_name, v_description, v_sku,
      v_weight, v_sale_price,
      v_category.name_ar, v_karat.code, v_karat.name_ar,
      v_gold.daily_gold_price_id, v_gold.price_per_gram,
      v_mfg.manufacturing_fee_version_id, v_mfg.fee_per_gram,
      v_vat.vat_rate_version_id, v_vat.rate_percent,
      round(v_gold_component, 2), round(v_mfg_component, 2), round(v_base_cost, 2), round(v_vat_cost, 2), round(v_total_cost, 2), round(v_item_gross_profit, 2),
      v_actor, v_actor
    )
    returning sales_order_items.id into v_item_id;

    v_subtotal := v_subtotal + v_sale_price;
    -- Order Gross Profit = SUM(Item Gross Profit) using the same rounded
    -- value just stored on the item row (spec §2) — not the pre-rounding
    -- raw value, so the order total reconciles exactly against what each
    -- item row displays.
    v_order_gross_profit := v_order_gross_profit + round(v_item_gross_profit, 2);
  end loop;

  -- 10) Order totals. Payment Fee = (Subtotal × Percentage / 100) + Fixed
  -- (spec §2) — percentage_fee/fixed_fee snapshots already resolved above;
  -- subtotal is an exact sum of already-2dp sale_price inputs, so this is
  -- the one remaining full-precision computation, rounded once here at
  -- final storage.
  v_payment_fee_amount := round((v_subtotal * v_payment_fee.percentage_fee / 100) + v_payment_fee.fixed_fee, 2);
  v_net_sales_profit := round(v_order_gross_profit, 2) - v_payment_fee_amount;

  update public.sales_orders
  set subtotal = round(v_subtotal, 2),
      gross_profit = round(v_order_gross_profit, 2),
      payment_fee_amount = v_payment_fee_amount,
      net_sales_profit = v_net_sales_profit
  where sales_orders.id = v_order_id;

  -- 14) Audit (spec §21). This table has no direct-write RLS policy at all
  -- (see 0059's access-model note) so this explicit call is the only audit
  -- trail this write will ever produce — exactly as tamper-proof as a
  -- trigger would be here. log_audit_event() (0008, locked to service_role-
  -- only for `authenticated`/`anon` by 0016) is still callable from THIS
  -- SECURITY DEFINER function: privilege checks for a nested call run as
  -- the function's OWNER (not the invoking client role), while auth.uid()
  -- itself is unaffected by SECURITY DEFINER and still correctly resolves
  -- to the real acting user (same reasoning already documented for
  -- finalize_new_user_profile, 0016 §4) — so the actor attribution here is
  -- exactly as trustworthy as everywhere else in this project.
  perform public.log_audit_event(
    'sale.create', 'sales_order', v_order_id, null,
    jsonb_build_object('order_number', v_order_number, 'store_id', p_store_id, 'sale_date', p_sale_date, 'subtotal', round(v_subtotal, 2), 'net_sales_profit', v_net_sales_profit)
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'sale.closed_day_update', 'sales_order', v_order_id, null,
      jsonb_build_object('order_number', v_order_number, 'sale_date', p_sale_date, 'created_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := v_order_id;
  order_number := v_order_number;
  return next;
end;
$$;

comment on function public.create_sales_order(uuid, date, uuid, uuid, jsonb, text, text, text, text) is
  'The single transactional entry point for creating a Sale (spec §11) — authenticates the actor, checks sales.create + store scope (user_operable_store_ids) + active store/master-data + closed-day gating, resolves every financial version for sale_date (gold price, manufacturing fee, VAT rate, payment fee) and computes every cost/profit figure inside Postgres using full NUMERIC precision, then writes the order header and every item atomically — any failure (a missing item field, an inactive karat, an unconfigured VAT/fee version for that date, ...) rolls back the entire call: no order, no items, no partially-used order number reuse concern (gaps from a rolled-back nextval() are expected and harmless, spec §28). SECURITY DEFINER — sales_orders/sales_order_items have zero direct-write RLS policies (0059), so this function, has_permission(''sales.create''), and the explicit checks in its body are the complete authorization surface.';

revoke execute on function public.create_sales_order(uuid, date, uuid, uuid, jsonb, text, text, text, text) from public;
grant execute on function public.create_sales_order(uuid, date, uuid, uuid, jsonb, text, text, text, text) to authenticated;

-- log_audit_event() (0008, locked to service_role since 0016) now also has
-- trusted SECURITY DEFINER callers from the Sales RPCs (this migration
-- onward: create_sales_order here; update_sales_order 0063; close_sales_day
-- 0064) — each an intentional, narrow, documented extension exactly as
-- 0016's own comment anticipated ("the only remaining legitimate caller..."
-- was accurate as of 0016-0057; Sales adds new legitimate SECURITY DEFINER
-- callers without changing 0016's actual mechanism or its `authenticated`/
-- `anon` lockout in any way). Comment updated here to keep the function's
-- documentation accurate; no grant/behavior change.
comment on function public.log_audit_event is
  'General-purpose audit writer, service_role/SECURITY DEFINER-internal ONLY — never directly callable by `authenticated`/`anon` (0016). Legitimate callers: the server-only failed-login path in src/features/auth/actions.ts (via the admin/service-role client), and, as of Phase 3 (0061/0063/0064), the Sales RPCs (create_sales_order/update_sales_order/close_sales_day), all SECURITY DEFINER and all resolving auth.uid() to the real acting user regardless of the definer/owner context. Every other sensitive-table mutation is logged automatically by audit_table_changes() instead (0016) — this function is never the right choice for a table that still has a direct-write RLS policy.';

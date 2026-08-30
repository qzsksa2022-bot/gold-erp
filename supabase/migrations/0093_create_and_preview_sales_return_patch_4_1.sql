-- ============================================================================
-- 0093: Returns Integrity Patch 4.1 (2/7): create_sales_return(),
-- preview_sales_return(), refresh_pending_sales_return_from_sale()
-- ============================================================================
-- Migrations 0001-0092 are unmodified.
--
-- p_items changes shape from uuid[] (0085) to jsonb — every element now
-- carries {sales_order_item_id, condition, item_return_reason, item_notes}
-- (Section 3), mirroring how create_sales_order() (0061) already takes
-- p_items jsonb for the same reason: per-line business data beyond a bare id.
--
-- create_sales_return() gains: p_expected_sale_version (Section 4 stale-sale
-- guard — validated here at CREATION; the authoritative re-check happens
-- again at approve_sales_return(), 0095, since a pending return can sit for
-- a while before approval), p_collection_state, p_approved_refund_amount
-- (now an explicit business input, not an approval-time derivation),
-- p_non_shipping_deduction_amount, p_deduction_reason, p_refund_difference_
-- reason (Section 1). The double-return pre-check changes from "is this
-- item claimed by ANY active return" to "is this item EFFECTIVELY claimed by
-- an approved return" — multiple PENDING returns may now coexist on the
-- same item (Section 5); only an effective (approved) claim blocks a new one.
create or replace function public.create_sales_return(
  p_sales_order_id uuid,
  p_processed_store_id uuid,
  p_return_date date,
  p_scenario text,
  p_items jsonb,
  p_expected_sale_version bigint,
  p_collection_state text,
  p_approved_refund_amount numeric,
  p_non_shipping_deduction_amount numeric default 0,
  p_deduction_reason text default null,
  p_refund_difference_reason text default null,
  p_scenario_notes text default null,
  p_closed_day_reason text default null
)
returns table (id uuid, return_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_today date := public.business_today();
  v_order record;
  v_return_id uuid;
  v_return_number text;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_item jsonb;
  v_item_id uuid;
  v_condition text;
  v_soi record;
  v_line_no integer := 0;
  v_speculative_original numeric := 0;
  v_speculative_revenue_reversal numeric;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لإنشاء مرتجع' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.create') then
    raise exception 'ليست لديك صلاحية إنشاء مرتجعات' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_sales_order_id is null or p_processed_store_id is null or p_return_date is null or p_scenario is null then
    raise exception 'عملية البيع والمتجر وتاريخ المرتجع والسيناريو كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_expected_sale_version is null then
    raise exception 'إصدار عملية البيع (row_version) مطلوب لإنشاء مرتجع — أعد تحميل بيانات عملية البيع قبل المتابعة' using errcode = 'P0001';
  end if;

  if p_collection_state is null then
    raise exception 'حالة تحصيل المبلغ الأصلي مطلوبة' using errcode = 'P0001';
  end if;

  if p_approved_refund_amount is null or p_approved_refund_amount < 0 then
    raise exception 'قيمة الاسترداد المعتمد مطلوبة ويجب ألا تكون سالبة' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_approved_refund_amount, 'قيمة الاسترداد المعتمد');
  perform public.validate_money_scale(p_non_shipping_deduction_amount, 'قيمة الاستقطاع');

  if p_non_shipping_deduction_amount is null or p_non_shipping_deduction_amount < 0 then
    raise exception 'قيمة الاستقطاع يجب ألا تكون سالبة' using errcode = 'P0001';
  end if;

  if p_non_shipping_deduction_amount > 0 and (p_deduction_reason is null or btrim(p_deduction_reason) = '') then
    raise exception 'يجب إدخال سبب الاستقطاع عندما تكون قيمته أكبر من صفر' using errcode = 'P0001';
  end if;

  if p_scenario = 'other' and (p_scenario_notes is null or btrim(p_scenario_notes) = '') then
    raise exception 'يجب إدخال ملاحظات عند اختيار سيناريو "أخرى"' using errcode = 'P0001';
  end if;

  -- Section 2 — the real customer_never_received fix, validated here too
  -- (not just left to the CHECK constraint) for a friendly message at the
  -- point of entry.
  if p_scenario = 'customer_never_received' and p_collection_state = 'not_collected' and p_approved_refund_amount <> 0 then
    raise exception 'عندما لم يستلم العميل البضاعة ولم يتم تحصيل المبلغ الأصلي، يجب أن تكون قيمة الاسترداد المعتمد صفرًا' using errcode = 'P0001';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'يجب اختيار بند واحد على الأقل للإرجاع' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_items) e
    group by (e->>'sales_order_item_id') having count(*) > 1
  ) then
    raise exception 'يوجد بند مكرر في قائمة البنود المراد إرجاعها' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_processed_store_id) then
    raise exception 'هذا المتجر غير متاح لك لمعالجة مرتجعات فيه، أو أنه غير نشط' using errcode = 'P0001';
  end if;

  if p_return_date > v_today then
    raise exception 'لا يمكن تسجيل مرتجع بتاريخ مستقبلي (%)', p_return_date using errcode = 'P0001';
  end if;

  select * into v_order from public.sales_orders so where so.id = p_sales_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  -- Section 4 — stale-sale guard at creation: the UI must be looking at the
  -- CURRENT Sale before it can even open a return against it.
  if v_order.row_version <> p_expected_sale_version then
    raise exception 'تم تعديل عملية البيع منذ آخر مرة تم تحميل بياناتها. أعد تحميل الصفحة قبل إنشاء مرتجع.' using errcode = 'P0001';
  end if;

  -- Section 7 — return_date must not precede the sale being returned from.
  if p_return_date < v_order.sale_date then
    raise exception 'لا يمكن أن يكون تاريخ المرتجع (%) قبل تاريخ عملية البيع (%)', p_return_date, v_order.sale_date using errcode = 'P0001';
  end if;

  perform public.acquire_returns_order_lock_exclusive(p_sales_order_id);

  perform public.acquire_daily_close_lock_shared(p_processed_store_id, p_return_date);

  select exists(
    select 1 from public.daily_closings
    where store_id = p_processed_store_id and business_date = p_return_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('returns.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن معالجة مرتجع فيه إلا بصلاحية خاصة (returns.process_closed_day)', p_return_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لمعالجة مرتجع في يوم مقفل (%)', p_return_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  -- First pass over the items: validate existence/effective-claim, and
  -- accumulate a SPECULATIVE original-sale total purely to validate the
  -- deduction bound and the refund-difference-reason rule up front (the
  -- authoritative figures are only ever computed at approval, Section 16).
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_item_id := (v_item->>'sales_order_item_id')::uuid;

    select * into v_soi from public.sales_order_items soi
    where soi.id = v_item_id and soi.sales_order_id = p_sales_order_id and soi.status = 'active';

    if v_soi.id is null then
      raise exception 'البند غير موجود ضمن عملية البيع هذه، أو تمت إزالته (id: %)', v_item_id using errcode = 'P0001';
    end if;

    -- Section 5 — an item already EFFECTIVELY (approved) claimed by another
    -- return can never be the target of a new one; being merely referenced
    -- by another still-pending return is explicitly allowed.
    if exists (select 1 from public.sales_return_items sri where sri.sales_order_item_id = v_item_id and sri.is_effective = true) then
      raise exception 'تم إرجاع هذا البند بالفعل ضمن مرتجع معتمد آخر (id: %)', v_item_id using errcode = 'P0001';
    end if;

    v_speculative_original := v_speculative_original + v_soi.sale_price;
  end loop;

  v_speculative_revenue_reversal := round(v_speculative_original, 2) - p_non_shipping_deduction_amount;

  if p_non_shipping_deduction_amount > round(v_speculative_original, 2) then
    raise exception 'قيمة الاستقطاع (%) لا يمكن أن تتجاوز إجمالي مبلغ البيع الأصلي للبنود المرتجعة (%)', p_non_shipping_deduction_amount, round(v_speculative_original, 2) using errcode = 'P0001';
  end if;

  if p_approved_refund_amount <> v_speculative_revenue_reversal and (p_refund_difference_reason is null or btrim(p_refund_difference_reason) = '') then
    raise exception 'قيمة الاسترداد المعتمد (%) تختلف عن صافي عكس الإيراد المتوقع (%) — يجب إدخال سبب الفرق', p_approved_refund_amount, v_speculative_revenue_reversal using errcode = 'P0001';
  end if;

  v_return_number := public.generate_sales_return_number();

  insert into public.sales_returns (
    return_number, sales_order_id, processed_store_id, return_date,
    customer_name_snapshot, customer_phone_snapshot,
    scenario, scenario_notes, status,
    order_subtotal_snapshot, order_payment_fee_amount_snapshot, payment_method_id,
    sale_date_snapshot, source_sale_row_version,
    collection_state, approved_refund_amount, non_shipping_deduction_amount,
    deduction_reason, refund_difference_reason,
    created_by, updated_by
  ) values (
    v_return_number, p_sales_order_id, p_processed_store_id, p_return_date,
    v_order.customer_name, v_order.customer_phone,
    p_scenario, nullif(btrim(coalesce(p_scenario_notes, '')), ''), 'pending',
    v_order.subtotal, v_order.payment_fee_amount, v_order.payment_method_id,
    v_order.sale_date, v_order.row_version,
    p_collection_state, p_approved_refund_amount, p_non_shipping_deduction_amount,
    nullif(btrim(coalesce(p_deduction_reason, '')), ''), nullif(btrim(coalesce(p_refund_difference_reason, '')), ''),
    v_actor, v_actor
  )
  returning sales_returns.id into v_return_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_line_no := v_line_no + 1;
    v_item_id := (v_item->>'sales_order_item_id')::uuid;
    v_condition := coalesce(nullif(btrim(v_item->>'condition'), ''), 'unknown');

    select * into v_soi from public.sales_order_items soi where soi.id = v_item_id;

    begin
      insert into public.sales_return_items (
        sales_return_id, sales_order_item_id, line_no,
        category_name_ar_snapshot, karat_code_snapshot, karat_name_ar_snapshot,
        weight_grams_snapshot, sale_price_snapshot,
        gold_component_cost_snapshot, manufacturing_component_cost_snapshot,
        base_cost_snapshot, vat_cost_snapshot, total_cost_snapshot, gross_profit_snapshot,
        item_calculation_version_snapshot,
        condition, item_return_reason, item_notes,
        created_by
      ) values (
        v_return_id, v_item_id, v_line_no,
        v_soi.category_name_ar_snapshot, v_soi.karat_code_snapshot, v_soi.karat_name_ar_snapshot,
        v_soi.weight_grams, v_soi.sale_price,
        v_soi.gold_component_cost, v_soi.manufacturing_component_cost,
        v_soi.base_cost, v_soi.vat_cost, v_soi.total_cost, v_soi.gross_profit,
        v_soi.calculation_version,
        v_condition, nullif(btrim(coalesce(v_item->>'item_return_reason', '')), ''), nullif(btrim(coalesce(v_item->>'item_notes', '')), ''),
        v_actor
      );
    exception when unique_violation then
      raise exception 'تم إرجاع هذا البند بالفعل ضمن مرتجع معتمد آخر (id: %)', v_item_id using errcode = 'P0001';
    end;
  end loop;

  perform public.log_audit_event(
    'return.create', 'sales_return', v_return_id, null,
    jsonb_build_object(
      'return_number', v_return_number, 'sales_order_id', p_sales_order_id,
      'order_number', v_order.order_number, 'processed_store_id', p_processed_store_id,
      'return_date', p_return_date, 'scenario', p_scenario, 'collection_state', p_collection_state,
      'item_count', jsonb_array_length(p_items), 'source_sale_row_version', v_order.row_version
    )
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'return.closed_day_override', 'sales_return', v_return_id, null,
      jsonb_build_object('return_number', v_return_number, 'return_date', p_return_date, 'created_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := v_return_id;
  return_number := v_return_number;
  return next;
end;
$$;

comment on function public.create_sales_return(uuid, uuid, date, text, jsonb, bigint, text, numeric, numeric, text, text, text, text) is
  'Patch 4.1 — p_items is now jsonb (per-item condition/reason/notes, Section 3) instead of uuid[]. New required inputs: p_expected_sale_version (Section 4 stale-sale guard, re-checked authoritatively at approval), p_collection_state, p_approved_refund_amount, plus optional p_non_shipping_deduction_amount/p_deduction_reason/p_refund_difference_reason (Section 1). return_date must be >= the Sale''s sale_date (Section 7). Double-return pre-check now blocks only on an EFFECTIVE (approved) claim — multiple pending returns may reference the same item (Section 5). SECURITY DEFINER.';

drop function if exists public.create_sales_return(uuid, uuid, date, text, uuid[], text, text);

revoke execute on function public.create_sales_return(uuid, uuid, date, text, jsonb, bigint, text, numeric, numeric, text, text, text, text) from public;
grant execute on function public.create_sales_return(uuid, uuid, date, text, jsonb, bigint, text, numeric, numeric, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- preview_sales_return() — extended to accept the same Business Inputs
-- create_sales_return() does (Section 16), computed via the exact same
-- speculative-total logic and the SAME compute_sales_return_fee_reversal()
-- approve_sales_return() uses. Still read-only, still not Source of Truth —
-- approval recomputes and re-validates fully from whatever is actually
-- stored on the return at that time.
-- ---------------------------------------------------------------------------
create or replace function public.preview_sales_return(
  p_sales_order_id uuid,
  p_items jsonb,
  p_collection_state text default null,
  p_non_shipping_deduction_amount numeric default 0,
  p_deduction_reason text default null,
  p_approved_refund_amount numeric default null,
  p_refund_difference_reason text default null,
  p_fee_reversal_override numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_order record;
  v_can_view_profit boolean;
  v_item jsonb;
  v_item_id uuid;
  v_condition text;
  v_soi record;
  v_items jsonb := '[]'::jsonb;
  v_return_original numeric := 0;
  v_return_cost numeric := 0;
  v_payment_method record;
  v_already_reversed_fee numeric;
  v_covers_all_remaining boolean;
  v_fee_reversal numeric;
  v_revenue_reversal numeric;
  v_profit_adjustment numeric;
begin
  if v_actor is null or not public.has_permission('returns.create') then
    raise exception 'ليست لديك صلاحية إنشاء مرتجعات' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

  if p_sales_order_id is null then
    raise exception 'عملية البيع مطلوبة' using errcode = 'P0001';
  end if;

  select * into v_order from public.sales_orders so where so.id = p_sales_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'يجب اختيار بند واحد على الأقل للإرجاع' using errcode = 'P0001';
  end if;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_item_id := (v_item->>'sales_order_item_id')::uuid;
    v_condition := coalesce(nullif(btrim(v_item->>'condition'), ''), 'unknown');

    select * into v_soi from public.sales_order_items soi
    where soi.id = v_item_id and soi.sales_order_id = p_sales_order_id and soi.status = 'active';

    if v_soi.id is null then
      raise exception 'البند غير موجود ضمن عملية البيع هذه، أو تمت إزالته (id: %)', v_item_id using errcode = 'P0001';
    end if;

    if exists (select 1 from public.sales_return_items sri where sri.sales_order_item_id = v_item_id and sri.is_effective = true) then
      raise exception 'تم إرجاع هذا البند بالفعل ضمن مرتجع معتمد آخر (id: %)', v_item_id using errcode = 'P0001';
    end if;

    v_return_original := v_return_original + v_soi.sale_price;
    v_return_cost := v_return_cost + v_soi.total_cost;

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'sales_order_item_id', v_soi.id,
      'category_name_ar_snapshot', v_soi.category_name_ar_snapshot,
      'karat_name_ar_snapshot', v_soi.karat_name_ar_snapshot,
      'weight_grams', v_soi.weight_grams::text,
      'sale_price', v_soi.sale_price::text,
      'condition', v_condition
    ) || case when v_can_view_profit then jsonb_build_object('total_cost', v_soi.total_cost::text, 'gross_profit', v_soi.gross_profit::text) else '{}'::jsonb end);
  end loop;

  v_return_original := round(v_return_original, 2);
  v_return_cost := round(v_return_cost, 2);
  v_revenue_reversal := v_return_original - coalesce(p_non_shipping_deduction_amount, 0);

  select * into v_payment_method from public.payment_methods pm where pm.id = v_order.payment_method_id;

  select coalesce(sum(sr.payment_fee_reversal_amount), 0) into v_already_reversed_fee
  from public.sales_returns sr
  where sr.sales_order_id = p_sales_order_id and sr.status = 'approved';

  select not exists (
    select 1 from public.sales_order_items soi
    where soi.sales_order_id = p_sales_order_id and soi.status = 'active'
      and not (soi.id in (select (e->>'sales_order_item_id')::uuid from jsonb_array_elements(p_items) e))
      and not exists (
        select 1 from public.sales_return_items sri
        where sri.sales_order_item_id = soi.id and sri.is_effective = true
      )
  ) into v_covers_all_remaining;

  v_fee_reversal := public.compute_sales_return_fee_reversal(
    v_order.subtotal, v_order.payment_fee_amount, v_return_original,
    v_payment_method.refund_fee_policy, v_covers_all_remaining, v_already_reversed_fee, p_fee_reversal_override
  );

  v_profit_adjustment := -v_revenue_reversal + v_return_cost + v_fee_reversal;

  return jsonb_build_object(
    'items', v_items,
    'returned_original_sale_amount', v_return_original::text,
    'non_shipping_deduction_amount', coalesce(p_non_shipping_deduction_amount, 0)::text,
    'sales_revenue_reversal_amount', v_revenue_reversal::text,
    'suggested_approved_refund_amount', v_revenue_reversal::text,
    'is_fee_reversal_estimate', true,
    'estimated_payment_fee_reversal_amount', v_fee_reversal::text
  )
  || case when v_can_view_profit then jsonb_build_object(
    'recovered_original_cost_amount', v_return_cost::text,
    'estimated_net_sales_profit_adjustment', v_profit_adjustment::text
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.preview_sales_return(uuid, jsonb, text, numeric, text, numeric, text, numeric) is
  'Patch 4.1 (Section 16) — extended to accept the same Business Inputs create_sales_return() does, and uses the exact same compute_sales_return_fee_reversal() formula and returned_original_sale/revenue_reversal/recovered_cost/profit_adjustment shape approve_sales_return() (0095) will compute. Still an ESTIMATE — approval recomputes and re-validates fully from what is actually stored at that time, never trusts this preview as Source of Truth. Decimal-safe transport. Profit-sensitive keys absent without sales.view_profit.';

drop function if exists public.preview_sales_return(uuid, uuid[]);

revoke execute on function public.preview_sales_return(uuid, jsonb, text, numeric, text, numeric, text, numeric) from public;
grant execute on function public.preview_sales_return(uuid, jsonb, text, numeric, text, numeric, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- refresh_pending_sales_return_from_sale() — Section 4's explicit refresh
-- path. Re-snapshots the header (sale_date_snapshot, order_subtotal_
-- snapshot, order_payment_fee_amount_snapshot, payment_method_id, customer
-- snapshots, source_sale_row_version) AND every currently-active item from
-- the CURRENT sales_orders/sales_order_items rows. NEVER called implicitly
-- by approve_sales_return() — a stale return is rejected there, never
-- silently repaired; the user must explicitly choose to discard the old
-- basis via this RPC (and review the new figures before re-attempting
-- approval). Follows the same safe lock order as approve_sales_return()
-- (0095) — sales_returns row, THEN sales_orders row, THEN the advisory
-- lock — see Section 19 / 0095's comment for why that order is mandatory.
-- ---------------------------------------------------------------------------
create or replace function public.refresh_pending_sales_return_from_sale(
  p_return_id uuid,
  p_expected_version bigint
)
returns table (id uuid, return_number text, row_version bigint, source_sale_row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old_return record;
  v_order record;
  v_item record;
  v_new_row_version bigint;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتحديث بيانات المرتجع' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.create') then
    raise exception 'ليست لديك صلاحية تعديل مرتجعات' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لتحديث المرتجع' using errcode = 'P0001';
  end if;

  select * into v_old_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_old_return.id is null or not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_old_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_old_return.status <> 'pending' then
    raise exception 'لا يمكن تحديث بيانات مرتجع تمت معالجته بالفعل (الحالة الحالية: %)', v_old_return.status using errcode = 'P0001';
  end if;

  if v_old_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل التحديث.' using errcode = 'P0001';
  end if;

  -- Safe global lock order (Section 19): sales_returns row (above) ->
  -- sales_orders row -> returns advisory lock -> sales_order_items rows.
  select * into v_order from public.sales_orders so where so.id = v_old_return.sales_order_id for update;

  perform public.acquire_returns_order_lock_exclusive(v_old_return.sales_order_id);

  if p_expected_version is null then
    -- unreachable, defensive
    raise exception 'إصدار السجل مطلوب' using errcode = 'P0001';
  end if;

  -- Every item currently active in this return must still be an active item
  -- of the Sale — refresh does not change the item SET, only the figures.
  -- If the Sale itself removed an item this return references, the user
  -- must first edit the item set via update_pending_sales_return().
  if exists (
    select 1 from public.sales_return_items sri
    where sri.sales_return_id = p_return_id and sri.status = 'active'
      and not exists (
        select 1 from public.sales_order_items soi
        where soi.id = sri.sales_order_item_id and soi.sales_order_id = v_old_return.sales_order_id and soi.status = 'active'
      )
  ) then
    raise exception 'تمت إزالة بند (أو أكثر) من عملية البيع الأصلية — عدّل بنود المرتجع أولًا قبل تحديث بياناته من عملية البيع' using errcode = 'P0001';
  end if;

  for v_item in
    select sri.id as sri_id, soi.*
    from public.sales_return_items sri
    join public.sales_order_items soi on soi.id = sri.sales_order_item_id
    where sri.sales_return_id = p_return_id and sri.status = 'active'
    order by soi.id
  loop
    update public.sales_return_items
    set category_name_ar_snapshot = v_item.category_name_ar_snapshot,
        karat_code_snapshot = v_item.karat_code_snapshot,
        karat_name_ar_snapshot = v_item.karat_name_ar_snapshot,
        weight_grams_snapshot = v_item.weight_grams,
        sale_price_snapshot = v_item.sale_price,
        gold_component_cost_snapshot = v_item.gold_component_cost,
        manufacturing_component_cost_snapshot = v_item.manufacturing_component_cost,
        base_cost_snapshot = v_item.base_cost,
        vat_cost_snapshot = v_item.vat_cost,
        total_cost_snapshot = v_item.total_cost,
        gross_profit_snapshot = v_item.gross_profit,
        item_calculation_version_snapshot = v_item.calculation_version
    where sales_return_items.id = v_item.sri_id;
  end loop;

  v_new_row_version := v_old_return.row_version + 1;

  update public.sales_returns
  set order_subtotal_snapshot = v_order.subtotal,
      order_payment_fee_amount_snapshot = v_order.payment_fee_amount,
      payment_method_id = v_order.payment_method_id,
      sale_date_snapshot = v_order.sale_date,
      source_sale_row_version = v_order.row_version,
      customer_name_snapshot = v_order.customer_name,
      customer_phone_snapshot = v_order.customer_phone,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  perform public.log_audit_event(
    'return.update', 'sales_return', p_return_id,
    jsonb_build_object('source_sale_row_version', v_old_return.source_sale_row_version, 'row_version', v_old_return.row_version),
    jsonb_build_object('source_sale_row_version', v_order.row_version, 'row_version', v_new_row_version, 'refreshed_from_sale', true)
  );

  id := p_return_id;
  return_number := v_old_return.return_number;
  row_version := v_new_row_version;
  source_sale_row_version := v_order.row_version;
  return next;
end;
$$;

comment on function public.refresh_pending_sales_return_from_sale(uuid, bigint) is
  'Patch 4.1 (Section 4) — the ONLY way a Pending return''s Sale-derived snapshots (header + every active item) are ever re-taken after creation. approve_sales_return() (0095) NEVER does this implicitly — a stale basis is rejected outright, requiring the user to explicitly call this RPC (and review the refreshed figures) before re-attempting approval. Does not change the item SET; if the Sale itself dropped an item this return references, update_pending_sales_return() must be used first. SECURITY DEFINER.';

revoke execute on function public.refresh_pending_sales_return_from_sale(uuid, bigint) from public;
grant execute on function public.refresh_pending_sales_return_from_sale(uuid, bigint) to authenticated;

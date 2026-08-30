-- ============================================================================
-- 0110: Phase 4 — Final Hotfix 4.2.1 (5/7): preview_sales_return() — Fee
-- Engine v2 parity (Section 20).
-- ============================================================================
-- Migrations 0001-0109 are unmodified.
--
-- Section 20 — preview_sales_return() (0100) had the SAME v1 bug as
-- approve_sales_return() had before 0109: it computed the estimated payment
-- fee reversal from v_return_original (the returned item value), via the
-- old compute_sales_return_fee_reversal(). This migration switches Preview
-- to the same compute_sales_return_fee_reversal_v2() engine, on the same
-- cumulative approved-refund-amount basis, so the Estimate the user sees
-- BEFORE approval always matches what approve_sales_return() will actually
-- compute at approval time — Approval remains the Source of Truth and always
-- recomputes independently (0109), but Preview no longer shows a number
-- calculated from a different, wrong basis.
--
-- Basis rule (Section 20, verbatim):
--   - If the caller has already entered p_approved_refund_amount, THAT is
--     the actual basis contributed by this (not-yet-created) return.
--   - If not (still drafting), v_suggested_refund is used as an ESTIMATE-
--     ONLY basis for this return's own contribution — never
--     v_return_original (returned_original_sale_amount), which is the item
--     value, not any refund/cash basis.
-- Same signature as 0100 — no new parameter needed, so no DROP/overload
-- change; CREATE OR REPLACE only.
-- ---------------------------------------------------------------------------
create or replace function public.preview_sales_return(
  p_sales_order_id uuid,
  p_items jsonb,
  p_scenario text default null,
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
  v_previous_approved_refund_basis numeric;
  v_previous_effective_fee_reversals numeric;
  v_fee_reversal_basis numeric;
  v_cumulative_approved_refund_basis numeric;
  v_fee_reversal numeric;
  v_revenue_reversal numeric;
  v_profit_adjustment numeric;
  v_deduction numeric := coalesce(p_non_shipping_deduction_amount, 0);
  v_suggested_refund numeric;
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

  -- Section 5/10 — same validation tree create_sales_return() applies,
  -- WHENEVER the corresponding input was actually supplied. Preview never
  -- invents a scenario/collection_state the caller has not chosen yet (both
  -- remain optional, unlike create's hard requirement), but the moment
  -- enough is present to judge a rule, Preview raises the EXACT SAME error
  -- create_sales_return() would — it never silently accepts an input that
  -- create would reject. UNCHANGED from 0100.
  perform public.validate_money_scale(p_approved_refund_amount, 'قيمة الاسترداد المعتمد');
  perform public.validate_money_scale(v_deduction, 'قيمة الاستقطاع');

  if v_deduction < 0 then
    raise exception 'قيمة الاستقطاع يجب ألا تكون سالبة' using errcode = 'P0001';
  end if;

  if v_deduction > 0 and (p_deduction_reason is null or btrim(p_deduction_reason) = '') then
    raise exception 'يجب إدخال سبب الاستقطاع عندما تكون قيمته أكبر من صفر' using errcode = 'P0001';
  end if;

  if p_scenario = 'customer_never_received' and p_collection_state = 'not_collected'
     and p_approved_refund_amount is not null and p_approved_refund_amount <> 0 then
    raise exception 'عندما لم يستلم العميل البضاعة ولم يتم تحصيل المبلغ الأصلي، يجب أن تكون قيمة الاسترداد المعتمد صفرًا' using errcode = 'P0001';
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

  if v_deduction > v_return_original then
    raise exception 'قيمة الاستقطاع (%) لا يمكن أن تتجاوز إجمالي مبلغ البيع الأصلي للبنود المرتجعة (%)', v_deduction, v_return_original using errcode = 'P0001';
  end if;

  v_revenue_reversal := v_return_original - v_deduction;

  -- Section 2 suggestion rule (unchanged) — customer_never_received +
  -- not_collected always suggests 0; every other combination suggests the
  -- full revenue reversal.
  v_suggested_refund := case
    when p_scenario = 'customer_never_received' and p_collection_state = 'not_collected' then 0
    else v_revenue_reversal
  end;

  if p_approved_refund_amount is not null and p_approved_refund_amount <> v_revenue_reversal
     and (p_refund_difference_reason is null or btrim(p_refund_difference_reason) = '') then
    raise exception 'قيمة الاسترداد المعتمد (%) تختلف عن صافي عكس الإيراد المتوقع (%) — يجب إدخال سبب الفرق', p_approved_refund_amount, v_revenue_reversal using errcode = 'P0001';
  end if;

  select * into v_payment_method from public.payment_methods pm where pm.id = v_order.payment_method_id;

  -- Hotfix 4.2.1 (Section 20) — the fix: the fee-reversal ESTIMATE is now
  -- computed by the same cumulative approved-refund-basis engine
  -- (compute_sales_return_fee_reversal_v2(), 0109) approve_sales_return()
  -- itself uses, never by the old item-value basis
  -- (compute_sales_return_fee_reversal(), v1, v_return_original). This
  -- return's own contribution to the basis is p_approved_refund_amount when
  -- the caller has already entered it, otherwise v_suggested_refund as an
  -- ESTIMATE-ONLY stand-in (never v_return_original).
  select coalesce(sum(sr.approved_refund_amount), 0), coalesce(sum(sr.payment_fee_reversal_amount), 0)
  into v_previous_approved_refund_basis, v_previous_effective_fee_reversals
  from public.sales_returns sr
  where sr.sales_order_id = p_sales_order_id and sr.status = 'approved';

  v_fee_reversal_basis := coalesce(p_approved_refund_amount, v_suggested_refund);
  v_cumulative_approved_refund_basis := v_previous_approved_refund_basis + v_fee_reversal_basis;

  v_fee_reversal := public.compute_sales_return_fee_reversal_v2(
    v_order.subtotal, v_order.payment_fee_amount,
    v_cumulative_approved_refund_basis, v_previous_effective_fee_reversals,
    v_payment_method.refund_fee_policy, p_fee_reversal_override
  );

  v_profit_adjustment := -v_revenue_reversal + v_return_cost + v_fee_reversal;

  return jsonb_build_object(
    'items', v_items,
    'returned_original_sale_amount', v_return_original::text,
    'non_shipping_deduction_amount', v_deduction::text,
    'sales_revenue_reversal_amount', v_revenue_reversal::text,
    'suggested_approved_refund_amount', v_suggested_refund::text,
    'approved_refund_amount', case when p_approved_refund_amount is not null then p_approved_refund_amount::text else null end,
    'refund_variance', case when p_approved_refund_amount is not null then (p_approved_refund_amount - v_revenue_reversal)::text else null end,
    'is_fee_reversal_estimate', true,
    'estimated_payment_fee_reversal_amount', v_fee_reversal::text,
    'payment_fee_reversal_calculation_version', 2
  )
  || case when v_can_view_profit then jsonb_build_object(
    'recovered_original_cost_amount', v_return_cost::text,
    'estimated_net_sales_profit_adjustment', v_profit_adjustment::text
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.preview_sales_return(uuid, jsonb, text, text, numeric, text, numeric, text, numeric) is
  'Patch 4.2/Hotfix 4.2.1 (Section 5/20) — same signature as 0100. Hotfix 4.2.1: estimated_payment_fee_reversal_amount now computed by compute_sales_return_fee_reversal_v2() (0109) on a cumulative approved-refund-amount basis (every OTHER approved return on the order''s approved_refund_amount, PLUS this not-yet-created return''s own contribution — p_approved_refund_amount if already entered, else suggested_approved_refund_amount as an ESTIMATE-ONLY stand-in), never on returned_original_sale_amount (the returned item value). Approval (approve_sales_return(), 0109) always recomputes independently and remains the Source of Truth — this is still only an estimate. Decimal-safe transport. Profit-sensitive keys absent without sales.view_profit.';

revoke execute on function public.preview_sales_return(uuid, jsonb, text, text, numeric, text, numeric, text, numeric) from public;
grant execute on function public.preview_sales_return(uuid, jsonb, text, text, numeric, text, numeric, text, numeric) to authenticated;

-- ============================================================================
-- 0085: Phase 4 — Returns Core (4/10): compute_sales_return_fee_reversal()
-- helper, create_sales_return(), preview_sales_return()
-- ============================================================================
-- Migrations 0001-0084 are unmodified.
--
-- ---------------------------------------------------------------------------
-- Part A — compute_sales_return_fee_reversal(): the shared reconciling
-- payment-fee-reversal formula, used identically by create_sales_return()
-- (via preview_sales_return(), for the UI's estimate) and approve_sales_
-- return() (0087, for the real committed figure) — same "one shared
-- function, called by every site that needs this number" pattern as
-- compute_sales_item_costs() (0065/0074). Pure function of its scalar
-- inputs (the caller does all the table querying beforehand and passes in
-- already_reversed_fee / covers_all_remaining_items) — IMMUTABLE, no table
-- access, matching that same established convention.
--
-- Consumes payment_methods.refund_fee_policy (0044) — never hardcodes a
-- provider name. full_reversal and proportional_reversal use the IDENTICAL
-- formula (seed data's own comment on 0044: proportional_reversal at a
-- 100% refund fraction already covers the full_reversal case) — return-
-- subtotal-proportional share of the order's original payment_fee_amount,
-- EXCEPT when this allocation is the one that completes full coverage of
-- the order (every active item now covered by an effective return), in
-- which case the entire remaining un-reversed balance is absorbed here
-- instead of the proportional figure — cumulative reversed fee across every
-- effective return on one order always lands exactly on the order's
-- original total fee, no rounding residue ever left stranded. Hard-capped
-- so cumulative reversed fee can never exceed the original total fee
-- regardless of policy/rounding — see PHASE_4_DESIGN_NOTES.md.
-- ---------------------------------------------------------------------------
create or replace function public.compute_sales_return_fee_reversal(
  p_order_subtotal_snapshot numeric,
  p_order_payment_fee_amount_snapshot numeric,
  p_return_subtotal numeric,
  p_refund_fee_policy text,
  p_covers_all_remaining_items boolean,
  p_already_reversed_fee numeric,
  p_fee_reversal_override numeric default null
)
returns numeric
language plpgsql
immutable
as $$
declare
  v_result numeric;
  v_remaining numeric;
begin
  if p_refund_fee_policy = 'non_refundable_fee' then
    v_result := 0;
  elsif p_refund_fee_policy = 'manual' then
    if p_fee_reversal_override is null then
      raise exception 'يجب إدخال قيمة استرداد العمولة يدويًا — سياسة استرداد العمولة لطريقة الدفع هذه "يدوي"' using errcode = 'P0001';
    end if;
    if p_fee_reversal_override < 0 then
      raise exception 'قيمة استرداد العمولة لا يمكن أن تكون سالبة' using errcode = 'P0001';
    end if;
    v_result := p_fee_reversal_override;
  elsif p_refund_fee_policy in ('full_reversal', 'proportional_reversal') then
    if p_fee_reversal_override is not null then
      raise exception 'لا يمكن تحديد قيمة استرداد عمولة يدويًا إلا عندما تكون سياسة استرداد العمولة "يدوي"' using errcode = 'P0001';
    end if;

    if p_covers_all_remaining_items then
      v_result := p_order_payment_fee_amount_snapshot - p_already_reversed_fee;
    else
      v_result := round(p_order_payment_fee_amount_snapshot * (p_return_subtotal / nullif(p_order_subtotal_snapshot, 0)), 2);
    end if;
  else
    raise exception 'سياسة استرداد عمولة غير معروفة: %', p_refund_fee_policy using errcode = 'P0001';
  end if;

  -- Hard cap — never reverse more fee than was ever charged on this order,
  -- regardless of policy or rounding (defensive invariant, independent of
  -- which branch above produced v_result).
  v_remaining := p_order_payment_fee_amount_snapshot - p_already_reversed_fee;
  if v_result > v_remaining then
    v_result := v_remaining;
  end if;
  if v_result < 0 then
    v_result := 0;
  end if;

  return v_result;
end;
$$;

comment on function public.compute_sales_return_fee_reversal(numeric, numeric, numeric, text, boolean, numeric, numeric) is
  'Phase 4 — the single shared reconciling payment-fee-reversal formula used identically by preview_sales_return() (estimate) and approve_sales_return() (0087, committed). Consumes payment_methods.refund_fee_policy (0044) verbatim — never hardcodes Tabby/Tamara/Visa/Mada/Cash/COD. Absorbs the full remaining fee balance (no proportional rounding) when p_covers_all_remaining_items=true, so cumulative reversed fee across every effective return on one order exactly equals the order''s original total fee. Hard-capped so it can never exceed (original total fee - already reversed). IMMUTABLE, no table access — caller supplies every already-queried figure.';

revoke execute on function public.compute_sales_return_fee_reversal(numeric, numeric, numeric, text, boolean, numeric, numeric) from public;
grant execute on function public.compute_sales_return_fee_reversal(numeric, numeric, numeric, text, boolean, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Part B — create_sales_return(): the single transactional entry point for
-- opening a return (mirrors create_sales_order()'s role, 0061). Only
-- business inputs are accepted; every snapshot is copied from already-
-- stored Sale/Item data, never resolved live (snapshot-only calculation —
-- this function never calls gold_price_for_karat_on_date()/manufacturing/
-- VAT resolvers). Leaves every financial reversal column NULL — those are
-- computed only at approval (0087). status starts 'pending'.
-- ---------------------------------------------------------------------------
create or replace function public.create_sales_return(
  p_sales_order_id uuid,
  p_processed_store_id uuid,
  p_return_date date,
  p_scenario text,
  p_item_ids uuid[],
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
  v_item_id uuid;
  v_soi record;
  v_line_no integer := 0;
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

  if p_scenario = 'other' and (p_scenario_notes is null or btrim(p_scenario_notes) = '') then
    raise exception 'يجب إدخال ملاحظات عند اختيار سيناريو "أخرى"' using errcode = 'P0001';
  end if;

  if p_item_ids is null or array_length(p_item_ids, 1) is null or array_length(p_item_ids, 1) = 0 then
    raise exception 'يجب اختيار بند واحد على الأقل للإرجاع' using errcode = 'P0001';
  end if;

  if exists (select 1 from unnest(p_item_ids) x group by x having count(*) > 1) then
    raise exception 'يوجد بند مكرر في قائمة البنود المراد إرجاعها' using errcode = 'P0001';
  end if;

  -- processed_store_id must be OPERABLE (mirrors create_sales_order's
  -- new-transaction operable-scope check, 0061) — a return being newly
  -- processed here is a forward-looking financial event, not a historical
  -- correction, so the narrower (active-only) scope applies, same as a
  -- brand-new Sale.
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_processed_store_id) then
    raise exception 'هذا المتجر غير متاح لك لمعالجة مرتجعات فيه، أو أنه غير نشط' using errcode = 'P0001';
  end if;

  if p_return_date > v_today then
    raise exception 'لا يمكن تسجيل مرتجع بتاريخ مستقبلي (%)', p_return_date using errcode = 'P0001';
  end if;

  -- The order itself must be VISIBLE to the actor (they need to be able to
  -- see the Sale to return from it — regardless of the processing store).
  select * into v_order from public.sales_orders so where so.id = p_sales_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  -- Serializes every return-lifecycle mutation for this exact order (0082) —
  -- closes the race between two concurrent create_sales_return() calls (or
  -- a concurrent approve/reverse) both targeting an overlapping item set.
  perform public.acquire_returns_order_lock_exclusive(p_sales_order_id);

  -- Daily-close integration — reuses the EXACT SAME lock helpers Sales uses
  -- (0065), scoped to (processed_store_id, return_date), NOT the original
  -- Sale's store/day.
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

  v_return_number := public.generate_sales_return_number();

  insert into public.sales_returns (
    return_number, sales_order_id, processed_store_id, return_date,
    customer_name_snapshot, customer_phone_snapshot,
    scenario, scenario_notes, status,
    order_subtotal_snapshot, order_payment_fee_amount_snapshot, payment_method_id,
    created_by, updated_by
  ) values (
    v_return_number, p_sales_order_id, p_processed_store_id, p_return_date,
    v_order.customer_name, v_order.customer_phone,
    p_scenario, nullif(btrim(coalesce(p_scenario_notes, '')), ''), 'pending',
    v_order.subtotal, v_order.payment_fee_amount, v_order.payment_method_id,
    v_actor, v_actor
  )
  returning sales_returns.id into v_return_id;

  foreach v_item_id in array p_item_ids
  loop
    v_line_no := v_line_no + 1;

    select * into v_soi from public.sales_order_items soi
    where soi.id = v_item_id and soi.sales_order_id = p_sales_order_id and soi.status = 'active';

    if v_soi.id is null then
      raise exception 'البند غير موجود ضمن عملية البيع هذه، أو تمت إزالته (id: %)', v_item_id using errcode = 'P0001';
    end if;

    -- Clear, common-case message ahead of the unique-index backstop below
    -- (the per-order advisory lock above already makes this the ONLY path
    -- that can reach here for this order, so this check and the unique
    -- index should never actually disagree — see PHASE_4_DESIGN_NOTES.md).
    if exists (select 1 from public.sales_return_items sri where sri.sales_order_item_id = v_item_id and sri.status = 'active') then
      raise exception 'هذا البند مرتبط بالفعل بمرتجع آخر نشط (قيد المراجعة أو معتمد) (id: %)', v_item_id using errcode = 'P0001';
    end if;

    begin
      insert into public.sales_return_items (
        sales_return_id, sales_order_item_id, line_no,
        category_name_ar_snapshot, karat_code_snapshot, karat_name_ar_snapshot,
        weight_grams_snapshot, sale_price_snapshot,
        gold_component_cost_snapshot, manufacturing_component_cost_snapshot,
        base_cost_snapshot, vat_cost_snapshot, total_cost_snapshot, gross_profit_snapshot,
        item_calculation_version_snapshot,
        created_by
      ) values (
        v_return_id, v_item_id, v_line_no,
        v_soi.category_name_ar_snapshot, v_soi.karat_code_snapshot, v_soi.karat_name_ar_snapshot,
        v_soi.weight_grams, v_soi.sale_price,
        v_soi.gold_component_cost, v_soi.manufacturing_component_cost,
        v_soi.base_cost, v_soi.vat_cost, v_soi.total_cost, v_soi.gross_profit,
        v_soi.calculation_version,
        v_actor
      );
    exception when unique_violation then
      raise exception 'هذا البند مرتبط بالفعل بمرتجع آخر نشط (قيد المراجعة أو معتمد) (id: %)', v_item_id using errcode = 'P0001';
    end;
  end loop;

  perform public.log_audit_event(
    'return.create', 'sales_return', v_return_id, null,
    jsonb_build_object(
      'return_number', v_return_number, 'sales_order_id', p_sales_order_id,
      'order_number', v_order.order_number, 'processed_store_id', p_processed_store_id,
      'return_date', p_return_date, 'scenario', p_scenario, 'item_count', array_length(p_item_ids, 1)
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

comment on function public.create_sales_return(uuid, uuid, date, text, uuid[], text, text) is
  'The single transactional entry point for opening a Return (mirrors create_sales_order(), 0061) — authenticates, checks returns.create + processed_store_id OPERABLE scope + non-future return_date + closed-day gating (reusing Sales'' own daily_closings/lock helpers, scoped to processed_store_id+return_date), verifies the target order is VISIBLE, then snapshots every financial figure from the CURRENT sales_order_items/sales_orders rows (never re-resolved from a price/fee/VAT resolver) into sales_return_items/sales_returns. status starts ''pending'' — every reversal/refund column stays NULL until approve_sales_return() (0087). Double-return prevention: an explicit pre-check plus the sales_return_items_order_item_active_uq partial unique index (0082) as a real DB-enforced backstop, both serialized per-order via acquire_returns_order_lock_exclusive() (0082). SECURITY DEFINER.';

revoke execute on function public.create_sales_return(uuid, uuid, date, text, uuid[], text, text) from public;
grant execute on function public.create_sales_return(uuid, uuid, date, text, uuid[], text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Part C — preview_sales_return(): read-only, no write, no permission gate
-- beyond returns.create (mirrors preview_sales_order()'s role) — lets the
-- UI show the customer/staff an estimate of the reversal figures BEFORE
-- committing to create_sales_return(). Uses the exact same snapshot values
-- and the exact same compute_sales_return_fee_reversal() formula
-- approve_sales_return() will eventually use — but the fee-reversal figure
-- here is explicitly labelled an ESTIMATE (is_fee_reversal_estimate: true
-- in the result), because it reflects OTHER effective returns'' state as of
-- THIS moment; if another return on the same order is approved between
-- preview and this return''s own eventual approval, the real committed
-- figure computed inside approve_sales_return() can differ (cumulative-
-- capping/final-allocation logic is inherently a function of approval
-- ORDER, not creation order). Decimal-safe transport — every numeric
-- returned as ::text (finance-safe boundary, matching every other RPC in
-- this project that returns a value destined for a financial calculation).
-- ---------------------------------------------------------------------------
create or replace function public.preview_sales_return(
  p_sales_order_id uuid,
  p_item_ids uuid[]
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
  v_item_id uuid;
  v_soi record;
  v_items jsonb := '[]'::jsonb;
  v_return_subtotal numeric := 0;
  v_return_gross_profit numeric := 0;
  v_payment_method record;
  v_already_reversed_fee numeric;
  v_covers_all_remaining boolean;
  v_fee_reversal numeric;
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

  if p_item_ids is null or array_length(p_item_ids, 1) is null or array_length(p_item_ids, 1) = 0 then
    raise exception 'يجب اختيار بند واحد على الأقل للإرجاع' using errcode = 'P0001';
  end if;

  foreach v_item_id in array p_item_ids
  loop
    select * into v_soi from public.sales_order_items soi
    where soi.id = v_item_id and soi.sales_order_id = p_sales_order_id and soi.status = 'active';

    if v_soi.id is null then
      raise exception 'البند غير موجود ضمن عملية البيع هذه، أو تمت إزالته (id: %)', v_item_id using errcode = 'P0001';
    end if;

    if exists (select 1 from public.sales_return_items sri where sri.sales_order_item_id = v_item_id and sri.status = 'active') then
      raise exception 'هذا البند مرتبط بالفعل بمرتجع آخر نشط (قيد المراجعة أو معتمد) (id: %)', v_item_id using errcode = 'P0001';
    end if;

    v_return_subtotal := v_return_subtotal + v_soi.sale_price;
    v_return_gross_profit := v_return_gross_profit + v_soi.gross_profit;

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'sales_order_item_id', v_soi.id,
      'category_name_ar_snapshot', v_soi.category_name_ar_snapshot,
      'karat_name_ar_snapshot', v_soi.karat_name_ar_snapshot,
      'weight_grams', v_soi.weight_grams::text,
      'sale_price', v_soi.sale_price::text
    ) || case when v_can_view_profit then jsonb_build_object('gross_profit', v_soi.gross_profit::text) else '{}'::jsonb end);
  end loop;

  select * into v_payment_method from public.payment_methods pm where pm.id = v_order.payment_method_id;

  select coalesce(sum(sr.payment_fee_reversal_amount), 0) into v_already_reversed_fee
  from public.sales_returns sr
  where sr.sales_order_id = p_sales_order_id and sr.status = 'approved';

  select not exists (
    select 1 from public.sales_order_items soi
    where soi.sales_order_id = p_sales_order_id and soi.status = 'active'
      and soi.id <> all(p_item_ids)
      and not exists (
        select 1 from public.sales_return_items sri
        join public.sales_returns sr on sr.id = sri.sales_return_id
        where sri.sales_order_item_id = soi.id and sri.status = 'active' and sr.status = 'approved'
      )
  ) into v_covers_all_remaining;

  v_fee_reversal := public.compute_sales_return_fee_reversal(
    v_order.subtotal, v_order.payment_fee_amount, round(v_return_subtotal, 2),
    v_payment_method.refund_fee_policy, v_covers_all_remaining, v_already_reversed_fee, null
  );

  return jsonb_build_object(
    'items', v_items,
    'sales_revenue_reversal_amount', round(v_return_subtotal, 2)::text,
    'is_fee_reversal_estimate', true,
    'estimated_payment_fee_reversal_amount', v_fee_reversal::text,
    'estimated_approved_refund_amount', round(v_return_subtotal, 2)::text
  )
  || case when v_can_view_profit then jsonb_build_object(
    'gross_profit_reversal_amount', round(v_return_gross_profit, 2)::text,
    'estimated_net_profit_reversal_amount', (round(v_return_gross_profit, 2) - v_fee_reversal)::text
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.preview_sales_return(uuid, uuid[]) is
  'Read-only preview of create_sales_return()''s eventual reversal figures — no write, no return_number burned (mirrors preview_sales_order(), 0062). The fee-reversal figure is an ESTIMATE (is_fee_reversal_estimate: true) computed via the exact same compute_sales_return_fee_reversal() formula approve_sales_return() (0087) will use, but reflecting OTHER effective returns'' state as of THIS call — the real committed figure is only fixed at that return''s own approval. Decimal-safe transport (every numeric ::text). Profit-sensitive keys absent without sales.view_profit.';

revoke execute on function public.preview_sales_return(uuid, uuid[]) from public;
grant execute on function public.preview_sales_return(uuid, uuid[]) to authenticated;

-- ============================================================================
-- 0109: Phase 4 — Final Hotfix 4.2.1 (4/7): compute_sales_return_fee_
-- reversal_v2(), approve_sales_return()
-- ============================================================================
-- Migrations 0001-0108 are unmodified.
--
-- Sections 7-13 — the financial correctness fix. compute_sales_return_fee_
-- reversal() (0085) computes each return's proportional share of the
-- order's payment fee from p_return_subtotal — the VALUE OF THE ITEMS
-- BEING RETURNED (returned_original_sale_amount) — not from the cash basis
-- that was ever actually approved for refund (approved_refund_amount).
-- Those two numbers are equal only when there is no deduction, no
-- refund-difference, and no customer_never_received/not_collected
-- zero-refund case — Phase 4's original spec was explicit that the fee
-- reversal basis must be the approved cash-refund basis, not the returned
-- item value. Example from the spec: subtotal=1000, fee=100, policy=
-- proportional_reversal, returned item value=500, deduction=100,
-- approved_refund_amount=400 -> correct fee reversal = 100*400/1000 = 40,
-- but the old function (given p_return_subtotal=500) computes 50.
--
-- Fix: a NEW function, not a silent behavior change to the old one (Section
-- 8 — an existing approved return's historical payment_fee_reversal_amount
-- must never be reinterpreted retroactively; see payment_fee_reversal_
-- calculation_version, 0106). compute_sales_return_fee_reversal_v2() takes
-- the CUMULATIVE approved-refund-amount basis (every other approved return
-- on this order's approved_refund_amount, PLUS this return's own) instead
-- of a single return's item value, and derives the target CUMULATIVE fee
-- reversal from it directly — this return's own share is the delta between
-- that target and what was already reversed by other approved returns.
-- This single formula change also correctly resolves Section 12
-- (customer_never_received + not_collected -> approved_refund_amount=0 ->
-- contributes nothing to the cumulative basis -> fee reversal=0, for both
-- proportional_reversal and full_reversal, with NO special-case branch
-- needed — it falls out of the formula on its own).
create or replace function public.compute_sales_return_fee_reversal_v2(
  p_original_order_subtotal numeric,
  p_original_payment_fee numeric,
  p_cumulative_approved_refund_basis numeric,
  p_previous_effective_fee_reversals numeric,
  p_refund_fee_policy text,
  p_manual_override numeric default null
)
returns numeric
language plpgsql
immutable
as $$
declare
  v_result numeric;
  v_remaining numeric;
  v_target_cumulative_fee numeric;
begin
  if p_refund_fee_policy = 'non_refundable_fee' then
    -- Section 11 — always 0, regardless of basis.
    v_result := 0;
  elsif p_refund_fee_policy = 'manual' then
    -- Section 11 — a manual override is an absolute value for THIS return
    -- only, never derived from any cumulative basis; still capped below.
    if p_manual_override is null then
      raise exception 'يجب إدخال قيمة استرداد العمولة يدويًا — سياسة استرداد العمولة لطريقة الدفع هذه "يدوي"' using errcode = 'P0001';
    end if;
    if p_manual_override < 0 then
      raise exception 'قيمة استرداد العمولة لا يمكن أن تكون سالبة' using errcode = 'P0001';
    end if;
    v_result := p_manual_override;
  elsif p_refund_fee_policy = 'proportional_reversal' then
    if p_manual_override is not null then
      raise exception 'لا يمكن تحديد قيمة استرداد عمولة يدويًا إلا عندما تكون سياسة استرداد العمولة "يدوي"' using errcode = 'P0001';
    end if;

    -- Section 9 — the cumulative TARGET is a proportional share of the
    -- cumulative approved-refund basis, rounded once; when that basis has
    -- reached (or somehow exceeds) the full order subtotal, the target
    -- becomes the ENTIRE original fee exactly (no proportional rounding
    -- residue possible) rather than trusting the division to land there —
    -- this is what absorbs cumulative rounding drift across many partial
    -- returns onto one order (see the 333.33/333.33/333.34 test case).
    if p_cumulative_approved_refund_basis >= p_original_order_subtotal then
      v_target_cumulative_fee := p_original_payment_fee;
    else
      v_target_cumulative_fee := round(p_original_payment_fee * (p_cumulative_approved_refund_basis / nullif(p_original_order_subtotal, 0)), 2);
    end if;

    v_result := v_target_cumulative_fee - p_previous_effective_fee_reversals;
  elsif p_refund_fee_policy = 'full_reversal' then
    if p_manual_override is not null then
      raise exception 'لا يمكن تحديد قيمة استرداد عمولة يدويًا إلا عندما تكون سياسة استرداد العمولة "يدوي"' using errcode = 'P0001';
    end if;

    -- Section 10 — zero on the cumulative approved-refund basis, the FULL
    -- remaining fee only once that basis reaches the entire order subtotal
    -- (i.e. this return, together with every other approved return on the
    -- order, has been approved for the FULL cash value of the order) —
    -- never merely because every item was returned; a partially-refunded-
    -- in-cash order (deductions, refund differences) does not qualify.
    if p_cumulative_approved_refund_basis >= p_original_order_subtotal then
      v_result := p_original_payment_fee - p_previous_effective_fee_reversals;
    else
      v_result := 0;
    end if;
  else
    raise exception 'سياسة استرداد عمولة غير معروفة: %', p_refund_fee_policy using errcode = 'P0001';
  end if;

  -- Same hard cap as v1 — never reverse more fee than was ever charged on
  -- this order, regardless of policy or rounding.
  v_remaining := p_original_payment_fee - p_previous_effective_fee_reversals;
  if v_result > v_remaining then
    v_result := v_remaining;
  end if;
  if v_result < 0 then
    v_result := 0;
  end if;

  return v_result;
end;
$$;

comment on function public.compute_sales_return_fee_reversal_v2(numeric, numeric, numeric, numeric, text, numeric) is
  'Hotfix 4.2.1 (Sections 7-13) — the approved-refund-basis payment-fee-reversal formula, replacing compute_sales_return_fee_reversal() (0085, v1, item-value basis — kept UNCHANGED and still used to interpret every pre-existing approved/reversed return''s historical payment_fee_reversal_amount, never recomputed). Basis is the CUMULATIVE approved_refund_amount across every approved return on the order (this return''s own + every other), not any single return''s item value — this return''s own fee reversal is the delta between the cumulative target and what other approved returns already reversed. customer_never_received + not_collected (approved_refund_amount=0) naturally yields a zero delta, no special case needed. IMMUTABLE, no table access — caller supplies every already-queried figure, exactly like v1.';

revoke execute on function public.compute_sales_return_fee_reversal_v2(numeric, numeric, numeric, numeric, text, numeric) from public;
grant execute on function public.compute_sales_return_fee_reversal_v2(numeric, numeric, numeric, numeric, text, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- approve_sales_return() — same signature as 0101, body rewritten to use
-- the v2 engine above and to stamp payment_fee_reversal_calculation_version
-- = 2 on every return approved from this migration forward (0106 already
-- backfilled every PRE-EXISTING approved/reversed row to version 1 — this
-- never touches them). A legacy Pending return approved for the first time
-- after this hotfix gets version 2, per spec Section 13 — it was never
-- "financially effective" under v1, so there is no historical figure to
-- preserve for it.
-- ---------------------------------------------------------------------------
create or replace function public.approve_sales_return(
  p_return_id uuid,
  p_expected_version bigint,
  p_fee_reversal_override numeric default null,
  p_closed_day_reason text default null
)
returns table (id uuid, return_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old_return record;
  v_order record;
  v_payment_method record;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_returned_original numeric;
  v_recovered_cost numeric;
  v_gross_profit numeric;
  v_revenue_reversal numeric;
  v_previous_approved_refund_basis numeric;
  v_previous_effective_fee_reversals numeric;
  v_cumulative_approved_refund_basis numeric;
  v_fee_reversal numeric;
  v_net_profit_reversal_legacy numeric;
  v_net_profit_adjustment numeric;
  v_new_row_version bigint;
  v_items_audit jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لاعتماد مرتجع' using errcode = 'P0001';
  end if;

  if not public.has_permission('returns.approve') then
    raise exception 'ليست لديك صلاحية اعتماد مرتجعات' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_expected_version is null then
    raise exception 'إصدار السجل (row_version) مطلوب لاعتماد المرتجع' using errcode = 'P0001';
  end if;

  perform public.validate_money_scale(p_fee_reversal_override, 'قيمة استرداد العمولة اليدوية');

  select * into v_old_return from public.sales_returns sr where sr.id = p_return_id for update;

  if v_old_return.id is null or not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_old_return.processed_store_id) then
    raise exception 'المرتجع غير موجود أو غير متاح لك' using errcode = 'P0001';
  end if;

  if v_old_return.status <> 'pending' then
    raise exception 'لا يمكن اعتماد مرتجع ليس قيد المراجعة (الحالة الحالية: %)', v_old_return.status using errcode = 'P0001';
  end if;

  if v_old_return.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا المرتجع بواسطة مستخدم آخر. حدّث الصفحة وراجع التغييرات قبل الاعتماد.' using errcode = 'P0001';
  end if;

  if v_old_return.requires_sale_refresh then
    raise exception 'يجب تحديث بيانات المرتجع من عملية البيع قبل اعتماده.' using errcode = 'P0001';
  end if;

  select * into v_order from public.sales_orders so where so.id = v_old_return.sales_order_id for update;

  perform public.acquire_returns_order_lock_exclusive(v_old_return.sales_order_id);

  perform public.acquire_daily_close_lock_shared(v_old_return.processed_store_id, v_old_return.return_date);

  select exists(
    select 1 from public.daily_closings
    where store_id = v_old_return.processed_store_id and business_date = v_old_return.return_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('returns.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن اعتماد مرتجع فيه إلا بصلاحية خاصة (returns.process_closed_day)', v_old_return.return_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لاعتماد مرتجع في يوم مقفل (%)', v_old_return.return_date using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  if not exists (select 1 from public.sales_return_items sri where sri.sales_return_id = p_return_id and sri.status = 'active') then
    raise exception 'لا يحتوي هذا المرتجع على أي بند نشط — لا يمكن اعتماده' using errcode = 'P0001';
  end if;

  perform 1 from public.sales_order_items soi
  where soi.id in (select sri.sales_order_item_id from public.sales_return_items sri where sri.sales_return_id = p_return_id and sri.status = 'active')
  order by soi.id
  for update;

  if v_order.row_version <> v_old_return.source_sale_row_version then
    raise exception 'تم تعديل عملية البيع بعد إنشاء طلب المرتجع. حدّث بيانات المرتجع قبل اعتماده.' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.sales_return_items sri
    where sri.sales_return_id = p_return_id and sri.status = 'active'
      and not exists (
        select 1 from public.sales_order_items soi
        where soi.id = sri.sales_order_item_id and soi.sales_order_id = v_old_return.sales_order_id and soi.status = 'active'
      )
  ) then
    raise exception 'تم تعديل عملية البيع بعد إنشاء طلب المرتجع. حدّث بيانات المرتجع قبل اعتماده.' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.sales_return_items sri
    where sri.sales_return_id = p_return_id and sri.status = 'active'
      and exists (
        select 1 from public.sales_return_items other
        where other.sales_order_item_id = sri.sales_order_item_id
          and other.is_effective = true
          and other.sales_return_id <> p_return_id
      )
  ) then
    raise exception 'هذه القطعة مرتجعة بالفعل.' using errcode = 'P0001';
  end if;

  select coalesce(sum(sale_price_snapshot), 0), coalesce(sum(total_cost_snapshot), 0), coalesce(sum(gross_profit_snapshot), 0)
  into v_returned_original, v_recovered_cost, v_gross_profit
  from public.sales_return_items
  where sales_return_id = p_return_id and status = 'active';

  v_returned_original := round(v_returned_original, 2);
  v_recovered_cost := round(v_recovered_cost, 2);
  v_gross_profit := round(v_gross_profit, 2);

  if v_old_return.non_shipping_deduction_amount > v_returned_original then
    raise exception 'قيمة الاستقطاع (%) تتجاوز إجمالي مبلغ البيع الأصلي المحتسب حاليًا (%) — عدّل المرتجع قبل اعتماده', v_old_return.non_shipping_deduction_amount, v_returned_original using errcode = 'P0001';
  end if;

  v_revenue_reversal := v_returned_original - v_old_return.non_shipping_deduction_amount;

  if v_old_return.scenario = 'customer_never_received' and v_old_return.collection_state = 'not_collected' and v_old_return.approved_refund_amount <> 0 then
    raise exception 'عندما لم يستلم العميل البضاعة ولم يتم تحصيل المبلغ الأصلي، يجب أن تكون قيمة الاسترداد المعتمد صفرًا' using errcode = 'P0001';
  end if;

  if v_old_return.approved_refund_amount <> v_revenue_reversal and (v_old_return.refund_difference_reason is null or btrim(v_old_return.refund_difference_reason) = '') then
    raise exception 'قيمة الاسترداد المعتمد (%) تختلف عن صافي عكس الإيراد المحتسب حاليًا (%) — عدّل المرتجع لإضافة سبب الفرق قبل اعتماده', v_old_return.approved_refund_amount, v_revenue_reversal using errcode = 'P0001';
  end if;

  select * into v_payment_method from public.payment_methods pm where pm.id = v_old_return.payment_method_id;

  -- Hotfix 4.2.1 (Sections 7-9) — the fix: cumulative basis is every OTHER
  -- approved return's own approved_refund_amount (the cash basis actually
  -- authorized), PLUS this return's own approved_refund_amount — never any
  -- return's returned-item value. previous_effective_fee_reversals stays
  -- the same query shape as v1 (sum of payment_fee_reversal_amount over
  -- other approved returns) — the delta computation in v2 needs it exactly
  -- as before, regardless of whether those prior figures were computed by
  -- v1 or v2 (a v1 figure is just as real a "cumulative reversed so far"
  -- fact as a v2 one; only the FORMULA that produced it differs, not its
  -- validity as an already-reversed amount going forward).
  select coalesce(sum(sr.approved_refund_amount), 0), coalesce(sum(sr.payment_fee_reversal_amount), 0)
  into v_previous_approved_refund_basis, v_previous_effective_fee_reversals
  from public.sales_returns sr
  where sr.sales_order_id = v_old_return.sales_order_id and sr.status = 'approved' and sr.id <> p_return_id;

  v_cumulative_approved_refund_basis := v_previous_approved_refund_basis + v_old_return.approved_refund_amount;

  v_fee_reversal := public.compute_sales_return_fee_reversal_v2(
    v_old_return.order_subtotal_snapshot, v_old_return.order_payment_fee_amount_snapshot,
    v_cumulative_approved_refund_basis, v_previous_effective_fee_reversals,
    v_payment_method.refund_fee_policy, p_fee_reversal_override
  );

  v_net_profit_reversal_legacy := v_gross_profit - v_fee_reversal;
  v_net_profit_adjustment := -v_revenue_reversal + v_recovered_cost + v_fee_reversal;
  v_new_row_version := v_old_return.row_version + 1;

  update public.sales_returns
  set status = 'approved',
      approved_at = now(),
      approved_by = v_actor,
      returned_original_sale_amount = v_returned_original,
      sales_revenue_reversal_amount = v_revenue_reversal,
      recovered_original_cost_amount = v_recovered_cost,
      net_sales_profit_adjustment = v_net_profit_adjustment,
      gross_profit_reversal_amount = v_gross_profit,
      payment_fee_reversal_amount = v_fee_reversal,
      net_profit_reversal_amount = v_net_profit_reversal_legacy,
      refund_fee_policy_snapshot = v_payment_method.refund_fee_policy,
      payment_fee_reversal_calculation_version = 2,
      row_version = v_new_row_version,
      updated_by = v_actor
  where sales_returns.id = p_return_id;

  begin
    update public.sales_return_items
    set is_effective = true, included_in_decision = true
    where sales_return_id = p_return_id and status = 'active';
  exception when unique_violation then
    raise exception 'هذه القطعة مرتجعة بالفعل.' using errcode = 'P0001';
  end;

  select coalesce(jsonb_agg(jsonb_build_object('sales_order_item_id', sales_order_item_id, 'condition', condition)), '[]'::jsonb)
  into v_items_audit
  from public.sales_return_items where sales_return_id = p_return_id and status = 'active';

  perform public.log_audit_event(
    'return.approve', 'sales_return', p_return_id,
    jsonb_build_object('status', v_old_return.status, 'row_version', v_old_return.row_version),
    jsonb_build_object(
      'status', 'approved', 'row_version', v_new_row_version,
      'sales_order_id', v_old_return.sales_order_id, 'items', v_items_audit,
      'collection_state', v_old_return.collection_state,
      'returned_original_sale_amount', v_returned_original,
      'non_shipping_deduction_amount', v_old_return.non_shipping_deduction_amount,
      'deduction_reason', v_old_return.deduction_reason,
      'sales_revenue_reversal_amount', v_revenue_reversal,
      'approved_refund_amount', v_old_return.approved_refund_amount,
      'refund_difference_reason', v_old_return.refund_difference_reason,
      'recovered_original_cost_amount', v_recovered_cost,
      'payment_fee_reversal_amount', v_fee_reversal,
      'payment_fee_reversal_calculation_version', 2,
      'cumulative_approved_refund_basis', v_cumulative_approved_refund_basis,
      'net_sales_profit_adjustment', v_net_profit_adjustment,
      'gross_profit_reversal_amount', v_gross_profit,
      'net_profit_reversal_amount', v_net_profit_reversal_legacy,
      'refund_fee_policy_snapshot', v_payment_method.refund_fee_policy,
      'source_sale_row_version', v_old_return.source_sale_row_version,
      'actor', v_actor, 'approved_at', now()
    )
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'return.closed_day_override', 'sales_return', p_return_id, null,
      jsonb_build_object('return_number', v_old_return.return_number, 'return_date', v_old_return.return_date, 'approved_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := p_return_id;
  return_number := v_old_return.return_number;
  return next;
end;
$$;

comment on function public.approve_sales_return(uuid, bigint, numeric, text) is
  'Patch 4.1/4.2/Hotfix 4.2.1 (Sections 1/2/4/5/6/7-13/17/19) — same signature as 0087/0095/0101, body rewritten. Hotfix 4.2.1 (Sections 7-13): payment_fee_reversal_amount now computed by compute_sales_return_fee_reversal_v2() (0109) on the CUMULATIVE approved_refund_amount basis (this return''s own + every other approved return on the order), never on any single return''s returned-item value — stamps payment_fee_reversal_calculation_version=2 (0106 backfilled every PRE-EXISTING approved/reversed row to version 1; never recomputed). Global safe lock order unchanged. SECURITY DEFINER.';

revoke execute on function public.approve_sales_return(uuid, bigint, numeric, text) from public;
grant execute on function public.approve_sales_return(uuid, bigint, numeric, text) to authenticated;

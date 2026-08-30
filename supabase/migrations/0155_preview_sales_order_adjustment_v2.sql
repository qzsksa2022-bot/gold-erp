-- ============================================================================
-- 0155: Phase 6 Integrity Patch 6.1 (12/13): preview_sales_order_adjustment()
-- v2 — money-scale rejection, zero-charge support (nullable payment method)
-- ============================================================================
-- Migrations 0001-0154 are unmodified. p_payment_method_id gains a DEFAULT
-- (previously required) — argument TYPES/order/count are unchanged, so this
-- remains a true CREATE OR REPLACE of the same function identity.
--
-- Patch 6.1 item 7 — customer_charge/direct_cost now reject overprecision
-- (validate_money_scale) instead of silently rounding.
-- Patch 6.1 item 9 — a FREE preview (customer_charge = 0) never needs a
-- payment method at all: fee_found=true, payment_fee_amount=0.00
-- unconditionally, matching approve_sales_order_adjustment()'s (0148) own
-- zero-charge branch exactly, so the preview panel and the authoritative
-- approval never disagree about what "free" computes to.
-- ---------------------------------------------------------------------------
create or replace function public.preview_sales_order_adjustment(
  p_payment_method_id uuid default null,
  p_customer_charge numeric default null,
  p_direct_cost numeric default null,
  p_adjustment_date date default public.business_today()
)
returns table (
  fee_found boolean,
  customer_charge text,
  payment_fee_percentage text,
  payment_fee_fixed text,
  payment_fee_amount text,
  direct_cost text,
  gross_adjustment_profit text,
  net_adjustment_profit text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_can_view_profit boolean;
  v_fee record;
  v_fee_found boolean := false;
  v_fee_amount numeric;
  v_gross numeric;
  v_net numeric;
  v_is_free boolean;
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء تعديل/خدمة' using errcode = 'P0001';
  end if;

  if p_customer_charge is null or p_customer_charge < 0 then
    raise exception 'قيمة تحصيل العميل يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
  end if;
  perform public.validate_money_scale(p_customer_charge, 'قيمة تحصيل العميل');
  if p_direct_cost is not null then
    if p_direct_cost < 0 then
      raise exception 'التكلفة المباشرة يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
    end if;
    perform public.validate_money_scale(p_direct_cost, 'التكلفة المباشرة');
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');
  v_is_free := round(p_customer_charge, 2) = 0;

  if v_is_free then
    v_fee_found := true;
    v_fee_amount := 0;
  elsif p_payment_method_id is not null then
    perform public.acquire_financial_master_lock_shared();
    begin
      select * into v_fee from public.payment_fee_for_method_on_date(p_payment_method_id, p_adjustment_date);
      v_fee_found := true;
    exception
      when sqlstate 'P0001' then
        v_fee_found := false;
    end;
    if v_fee_found then
      v_fee_amount := round(p_customer_charge * v_fee.percentage_fee / 100 + v_fee.fixed_fee, 2);
    end if;
  else
    v_fee_found := false;
  end if;

  if p_direct_cost is not null then
    v_gross := round(p_customer_charge, 2) - round(p_direct_cost, 2);
    if v_fee_found then
      v_net := v_gross - v_fee_amount;
    end if;
  end if;

  fee_found := v_fee_found;
  customer_charge := round(p_customer_charge, 2)::text;

  if v_can_view_profit then
    payment_fee_percentage := case when v_is_free then null when v_fee_found then v_fee.percentage_fee::text else null end;
    payment_fee_fixed := case when v_is_free then null when v_fee_found then v_fee.fixed_fee::text else null end;
    payment_fee_amount := case when v_fee_found then v_fee_amount::text else null end;
    direct_cost := case when p_direct_cost is not null then round(p_direct_cost, 2)::text else null end;
    gross_adjustment_profit := case when p_direct_cost is not null then v_gross::text else null end;
    net_adjustment_profit := case when (p_direct_cost is not null and v_fee_found) then v_net::text else null end;
  else
    payment_fee_percentage := null;
    payment_fee_fixed := null;
    payment_fee_amount := null;
    direct_cost := null;
    gross_adjustment_profit := null;
    net_adjustment_profit := null;
  end if;

  return next;
end;
$$;

comment on function public.preview_sales_order_adjustment(uuid, numeric, numeric, date) is
  'Phase 6 (§11/§35) + Patch 6.1 items 7/9 — non-authoritative preview. customer_charge/direct_cost reject overprecision (validate_money_scale). customer_charge=0 always resolves fee_found=true/payment_fee_amount=0.00 without needing a payment method at all — matches approve_sales_order_adjustment()''s (0148) own zero-charge branch. Approval always recomputes from scratch and ignores this output entirely. SECURITY DEFINER.';

revoke execute on function public.preview_sales_order_adjustment(uuid, numeric, numeric, date) from public;
grant execute on function public.preview_sales_order_adjustment(uuid, numeric, numeric, date) to authenticated;

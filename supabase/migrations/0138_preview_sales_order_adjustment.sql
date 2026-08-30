-- ============================================================================
-- 0138: Phase 6 — Services / Adjustments Core (6/11): preview_sales_order_
-- adjustment()
-- ============================================================================
-- Migrations 0001-0137 are unmodified.
--
-- §35 — operational vs profit-gated fields, explicitly NOT a trusted
-- financial source: Approval (0140) recomputes fee/gross/net authoritatively
-- from scratch and never reads this preview's output. Reuses the SAME
-- canonical payment_fee_for_method_on_date() engine Sales/Returns/Shipping
-- already use (0056) — the P0001 it raises when no configuration covers the
-- date is caught locally and surfaced as fee_found=false, never reimplemented
-- as a separate formula/lookup.
-- ---------------------------------------------------------------------------
create or replace function public.preview_sales_order_adjustment(
  p_payment_method_id uuid,
  p_customer_charge numeric,
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
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء تعديل/خدمة' using errcode = 'P0001';
  end if;

  if p_customer_charge is null or p_customer_charge < 0 then
    raise exception 'قيمة تحصيل العميل يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
  end if;
  if p_direct_cost is not null and p_direct_cost < 0 then
    raise exception 'التكلفة المباشرة يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');

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

  if p_direct_cost is not null then
    v_gross := round(p_customer_charge, 2) - round(p_direct_cost, 2);
    if v_fee_found then
      v_net := v_gross - v_fee_amount;
    end if;
  end if;

  fee_found := v_fee_found;
  customer_charge := round(p_customer_charge, 2)::text;

  if v_can_view_profit then
    payment_fee_percentage := case when v_fee_found then v_fee.percentage_fee::text else null end;
    payment_fee_fixed := case when v_fee_found then v_fee.fixed_fee::text else null end;
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
  'Phase 6 (§11/§35) — non-authoritative preview: customer_charge/fee_found always visible to any adjustments.create holder; payment_fee_*/direct_cost/gross/net are additionally gated on sales.view_profit. Reuses payment_fee_for_method_on_date() (0056) verbatim — no separate fee formula. Approval (0140) recomputes everything from scratch and ignores this output entirely. SECURITY DEFINER.';

revoke execute on function public.preview_sales_order_adjustment(uuid, numeric, numeric, date) from public;
grant execute on function public.preview_sales_order_adjustment(uuid, numeric, numeric, date) to authenticated;

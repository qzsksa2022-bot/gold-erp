-- ============================================================================
-- 0146: Phase 6 Integrity Patch 6.1 (3/13): create_sales_order_adjustment()
-- v2 — manage_cost gate, money-scale rejection, sale-date floor, zero-charge
-- normalization, payment_reference, adjustments type lock
-- ============================================================================
-- Migrations 0001-0145 are unmodified. Same signature as 0139's original —
-- CREATE OR REPLACE in place (no caller-visible parameter change).
--
-- Patch 6.1 fixes bundled here (all touch this single function):
--   item 1A — adjustments.create ALONE can no longer supply an initial
--     direct_cost; p_direct_cost is not null now REQUIRES adjustments.
--     manage_cost too, or the call is rejected outright (fail-safe reject,
--     not silent drop).
--   item 7 — customer_charge/direct_cost are validated via validate_money_
--     scale() (0092) BEFORE rounding — 100.999 is now REJECTED, never
--     silently coerced to 101.00.
--   item 8 — adjustment_date must be >= the linked Sales Order's sale_date
--     (in addition to the existing "not in the future" check).
--   item 9/10 — a genuinely FREE service (customer_charge = 0) FORCES
--     payment_method_id/collection_channel_id/payment_reference to NULL and
--     participates_in_settlement to false regardless of what was supplied —
--     matches the 0144 DB-level invariant exactly, so the UI's zero-charge
--     mode (item 28) never fights the RPC over what "free" means.
--   item 11 — payment_reference is now an accepted, optional, PENDING-only
--     input.
--   item 14 — acquire_adjustments_lock_shared() (0133) is now taken before
--     resolving/validating the Adjustment Type, so a concurrent type
--     rename/disable (0136's writers hold the EXCLUSIVE counterpart) can
--     never race a torn read.
-- ---------------------------------------------------------------------------
-- p_payment_reference is a NEW trailing parameter (item 11) — Postgres only
-- treats CREATE OR REPLACE as replacing the SAME function when the argument
-- list is identical, so the original 0139 11-argument signature is dropped
-- explicitly first; otherwise it would keep existing as a separate, un-
-- patched overload reachable by any caller that omits the new argument.
drop function if exists public.create_sales_order_adjustment(uuid, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text);

create or replace function public.create_sales_order_adjustment(
  p_sales_order_id uuid,
  p_adjustment_type_id uuid,
  p_processing_store_id uuid,
  p_adjustment_date date,
  p_payment_method_id uuid,
  p_collection_channel_id uuid,
  p_participates_in_settlement boolean,
  p_customer_charge numeric,
  p_direct_cost numeric default null,
  p_notes text default null,
  p_closed_day_reason text default null,
  p_payment_reference text default null
)
returns table (id uuid, adjustment_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_order record;
  v_type record;
  v_payment_method record;
  v_collection_channel record;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
  v_number text;
  v_id uuid;
  v_today date := public.business_today();
  v_is_free boolean;
  v_payment_method_id uuid;
  v_collection_channel_id uuid;
  v_payment_reference text;
  v_participates boolean;
  v_direct_cost numeric;
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء تعديل/خدمة' using errcode = 'P0001';
  end if;

  if p_customer_charge is null or p_customer_charge < 0 then
    raise exception 'قيمة تحصيل العميل يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
  end if;
  perform public.validate_money_scale(p_customer_charge, 'قيمة تحصيل العميل');
  v_is_free := round(p_customer_charge, 2) = 0;

  -- item 1A — direct_cost cannot be supplied at all without adjustments.
  -- manage_cost; the create-only actor must create with a NULL cost and let
  -- a manage_cost holder use set_pending_sales_order_adjustment_direct_cost
  -- (0145) afterward.
  if p_direct_cost is not null then
    if not public.has_permission('adjustments.manage_cost') then
      raise exception 'ليست لديك صلاحية إدخال التكلفة المباشرة — يمكن إنشاء التعديل/الخدمة بلا تكلفة ثم إدخالها لاحقًا عبر من يملك صلاحية adjustments.manage_cost' using errcode = 'P0001';
    end if;
    if p_direct_cost < 0 then
      raise exception 'التكلفة المباشرة يجب أن تكون رقمًا غير سالب' using errcode = 'P0001';
    end if;
    perform public.validate_money_scale(p_direct_cost, 'التكلفة المباشرة');
    v_direct_cost := round(p_direct_cost, 2);
  else
    v_direct_cost := null;
  end if;

  if p_adjustment_date is null then
    raise exception 'تاريخ التعديل/الخدمة مطلوب' using errcode = 'P0001';
  end if;
  if p_adjustment_date > v_today then
    raise exception 'تاريخ التعديل/الخدمة لا يمكن أن يكون في المستقبل' using errcode = 'P0001';
  end if;

  -- §23 — Original Sales Order only needs to be VISIBLE (not operable).
  select * into v_order from public.sales_orders where sales_orders.id = p_sales_order_id;
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير مرئية لك' using errcode = 'P0001';
  end if;

  -- item 8 — adjustment_date can never precede the Sale it corrects/services.
  if p_adjustment_date < v_order.sale_date then
    raise exception 'تاريخ التعديل/الخدمة لا يمكن أن يسبق تاريخ عملية البيع الأصلية (%)', v_order.sale_date using errcode = 'P0001';
  end if;

  -- §23 — Processing Store needs to be OPERABLE for a NEW record.
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_processing_store_id) then
    raise exception 'المتجر المُعالِج غير متاح لك للعمل عليه' using errcode = 'P0001';
  end if;

  -- item 14 — SHARED adjustments lock before resolving the Adjustment Type,
  -- held for the remainder of this transaction (released at commit).
  perform public.acquire_adjustments_lock_shared();

  select * into v_type from public.adjustment_types where adjustment_types.id = p_adjustment_type_id;
  if v_type.id is null then
    raise exception 'نوع التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if v_type.status <> 'active' then
    raise exception 'نوع التعديل/الخدمة "%" غير نشط — لا يمكن استخدامه في تعديل/خدمة جديد', v_type.name_ar using errcode = 'P0001';
  end if;

  -- item 9/10 — zero-charge normalization: a FREE service NEVER carries a
  -- payment method/channel/reference/settlement flag, regardless of what
  -- the caller supplied (the UI hides these fields entirely for a free
  -- service, item 28 — this is the server-side backstop for any caller,
  -- including a raw RPC call from the HTTP test suite).
  if v_is_free then
    v_payment_method_id := null;
    v_collection_channel_id := null;
    v_payment_reference := null;
    v_participates := false;
  else
    if p_participates_in_settlement is null then
      raise exception 'يجب تحديد ما إذا كان هذا التعديل/الخدمة ضمن التسوية بشكل صريح' using errcode = 'P0001';
    end if;
    if p_payment_method_id is null then
      raise exception 'طريقة الدفع مطلوبة لتعديل/خدمة بقيمة تحصيل أكبر من صفر' using errcode = 'P0001';
    end if;
    if p_collection_channel_id is null then
      raise exception 'قناة التحصيل مطلوبة لتعديل/خدمة بقيمة تحصيل أكبر من صفر' using errcode = 'P0001';
    end if;

    select * into v_payment_method from public.payment_methods where payment_methods.id = p_payment_method_id;
    if v_payment_method.id is null then
      raise exception 'طريقة الدفع غير موجودة' using errcode = 'P0001';
    end if;
    if v_payment_method.status <> 'active' then
      raise exception 'طريقة الدفع "%" غير نشطة — لا يمكن استخدامها في تعديل/خدمة جديد', v_payment_method.name_ar using errcode = 'P0001';
    end if;

    select * into v_collection_channel from public.collection_channels where collection_channels.id = p_collection_channel_id;
    if v_collection_channel.id is null then
      raise exception 'قناة التحصيل غير موجودة' using errcode = 'P0001';
    end if;
    if v_collection_channel.status <> 'active' then
      raise exception 'قناة التحصيل "%" غير نشطة — لا يمكن استخدامها في تعديل/خدمة جديد', v_collection_channel.name_ar using errcode = 'P0001';
    end if;

    v_payment_method_id := p_payment_method_id;
    v_collection_channel_id := p_collection_channel_id;
    v_payment_reference := nullif(btrim(coalesce(p_payment_reference, '')), '');
    v_participates := p_participates_in_settlement;
  end if;

  -- Daily Close (§22) — shared lock on (processing store, adjustment_date).
  perform public.acquire_daily_close_lock_shared(p_processing_store_id, p_adjustment_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = p_processing_store_id and dc.business_date = p_adjustment_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('adjustments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن إنشاء تعديل/خدمة فيه إلا بصلاحية خاصة (adjustments.process_closed_day)', p_adjustment_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لإنشاء تعديل/خدمة في يوم مقفل' using errcode = 'P0001';
    end if;
    v_used_closed_day_override := true;
  end if;

  v_number := public.generate_adjustment_number();

  insert into public.sales_order_adjustments (
    adjustment_number, sales_order_id, adjustment_type_id, processing_store_id, adjustment_date,
    payment_method_id, collection_channel_id, payment_reference, participates_in_settlement,
    customer_charge, direct_cost, notes, status,
    created_by, updated_by
  ) values (
    v_number, p_sales_order_id, p_adjustment_type_id, p_processing_store_id, p_adjustment_date,
    v_payment_method_id, v_collection_channel_id, v_payment_reference, v_participates,
    round(p_customer_charge, 2), v_direct_cost,
    nullif(btrim(coalesce(p_notes, '')), ''), 'pending',
    v_actor, v_actor
  )
  returning sales_order_adjustments.id into v_id;

  perform public.log_audit_event(
    'adjustment.create', 'sales_order_adjustment', v_id, null,
    jsonb_build_object(
      'adjustment_number', v_number, 'sales_order_id', p_sales_order_id, 'adjustment_type_id', p_adjustment_type_id,
      'processing_store_id', p_processing_store_id, 'adjustment_date', p_adjustment_date,
      'customer_charge', round(p_customer_charge, 2), 'direct_cost', v_direct_cost,
      'participates_in_settlement', v_participates, 'is_free_service', v_is_free
    )
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'adjustment.closed_day_override', 'sales_order_adjustment', v_id, null,
      jsonb_build_object('adjustment_number', v_number, 'adjustment_date', p_adjustment_date, 'created_on_closed_day', true),
      p_closed_day_reason
    );
  end if;

  id := v_id;
  adjustment_number := v_number;
  return next;
end;
$$;

comment on function public.create_sales_order_adjustment(uuid, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text, text) is
  'Phase 6 (§36) + Patch 6.1 items 1A/7/8/9/10/11/14 — creates a PENDING Service/Adjustment. p_direct_cost requires adjustments.manage_cost (create-only actors must create with cost=NULL, then a manage_cost holder calls set_pending_sales_order_adjustment_direct_cost, 0145). customer_charge/direct_cost reject overprecision (validate_money_scale). adjustment_date must be within [sale_date, business_today()]. customer_charge=0 forces payment_method_id/collection_channel_id/payment_reference to NULL and participates_in_settlement to false. Requires adjustments.create. SECURITY DEFINER.';

revoke execute on function public.create_sales_order_adjustment(uuid, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text, text) from public;
grant execute on function public.create_sales_order_adjustment(uuid, uuid, uuid, date, uuid, uuid, boolean, numeric, numeric, text, text, text) to authenticated;

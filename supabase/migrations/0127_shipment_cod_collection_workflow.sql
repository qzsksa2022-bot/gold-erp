-- ============================================================================
-- 0127: Shipping Integrity Patch 5.1 (6/10): COD Collection State workflow
-- ============================================================================
-- Migrations 0001-0126 are unmodified.
--
-- Item 13/14 — shipments.cod_collection_state (0116) had NO write path at
-- all after creation (it defaults to ''unknown'' or is set once at create_
-- shipment() time) — there was never an RPC to record it as collected/
-- not_collected, so it stayed stale forever. Fixed with the SAME append-
-- only-ledger + transactionally-maintained-cache pattern already used for
-- status (shipment_status_events -> current_status) and actual cost
-- (shipment_financial_events -> actual_carrier_cost): a new append-only
-- shipment_cod_events table + record_shipment_cod_collection_state() RPC.
-- Treated as a Financial/Settlement-adjacent operation per item 13's own
-- instruction — gated on shipments.manage_cost (no new permission key
-- introduced), Daily Close-checked against its own business_date exactly
-- like record_shipment_actual_cost() (0118), optimistic concurrency via
-- row_version, user_visible_store_ids() scope (mutates an EXISTING
-- shipment). Explicitly NOT a Settlement — no batch, no bank
-- reconciliation, no commission; this phase''s COD remains purely
-- operational (Section 21/22, unchanged).
--
-- Item 14 — customer_never_received/returned_to_store on a COD shipment
-- never silently flips cod_collection_state — the UI may SUGGEST
-- not_collected (src/features/shipping, see this delivery''s UI changes),
-- but only an explicit call to record_shipment_cod_collection_state()
-- (a real, audited Business Action) ever changes it.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- PART A — shipment_cod_events, append-only (same unconditional, no-
-- escape-hatch trigger philosophy as shipment_status_events/shipment_
-- financial_events, 0116 — "Phase 5 has no legacy pre-existing data to
-- backfill").
-- ---------------------------------------------------------------------------
create table public.shipment_cod_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.shipments (id) on delete restrict,
  state text not null check (state in ('expected', 'collected', 'not_collected', 'unknown')),
  business_date date not null,
  reference text,
  reason text,
  actor uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

comment on table public.shipment_cod_events is
  'Patch 5.1 (item 13) — append-only COD collection-state timeline. shipments.cod_collection_state (0116) is a transactionally-maintained cache of the latest event here, updated only by record_shipment_cod_collection_state() (this migration) — never written directly after creation. NO UPDATE/DELETE, ever (trigger-enforced below) — a wrong entry is corrected by appending a NEW event, never by editing/removing history. Purely operational — no settlement/reconciliation semantics.';

create index shipment_cod_events_shipment_idx on public.shipment_cod_events (shipment_id, created_at);

alter table public.shipment_cod_events enable row level security;
-- Deliberately zero RLS policies for `authenticated` — same access model as
-- shipment_status_events/shipment_financial_events (0116): every read goes
-- through get_shipment() (extended below), every write through record_
-- shipment_cod_collection_state().

create or replace function public.reject_shipment_cod_event_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception 'shipment_cod_events سجل ثابت لا يقبل التعديل أو الحذف بعد إنشائه' using errcode = 'P0001';
end;
$$;

create trigger shipment_cod_events_no_update
  before update on public.shipment_cod_events
  for each row execute function public.reject_shipment_cod_event_mutation();

create trigger shipment_cod_events_no_delete
  before delete on public.shipment_cod_events
  for each row execute function public.reject_shipment_cod_event_mutation();

-- ---------------------------------------------------------------------------
-- PART B — record_shipment_cod_collection_state().
-- ---------------------------------------------------------------------------
create or replace function public.record_shipment_cod_collection_state(
  p_shipment_id uuid,
  p_expected_version bigint,
  p_new_state text,
  p_business_date date,
  p_reference text default null,
  p_notes text default null,
  p_closed_day_reason text default null
)
returns table (row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_shipment record;
  v_new_row_version bigint;
  v_is_closed boolean;
  v_used_closed_day_override boolean := false;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول لتحديث حالة تحصيل الدفع عند الاستلام' using errcode = 'P0001';
  end if;

  if not public.has_permission('shipments.manage_cost') then
    raise exception 'ليست لديك صلاحية إدارة تكلفة/تحصيل الشحن' using errcode = 'P0001';
  end if;

  if not public.is_active_user(v_actor) then
    raise exception 'حساب المستخدم غير نشط' using errcode = 'P0001';
  end if;

  if p_shipment_id is null or p_expected_version is null or p_new_state is null or p_business_date is null then
    raise exception 'الشحنة وإصدار السجل وحالة التحصيل الجديدة وتاريخ العملية كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_new_state not in ('expected', 'collected', 'not_collected', 'unknown') then
    raise exception 'حالة تحصيل الدفع عند الاستلام غير صالحة' using errcode = 'P0001';
  end if;

  if p_business_date > public.business_today() then
    raise exception 'لا يمكن تسجيل حالة تحصيل بتاريخ مستقبلي (%)', p_business_date using errcode = 'P0001';
  end if;

  -- Lock FIRST, then compare row_version (same lost-update fix as every
  -- other Shipping write RPC, 0075's original pattern).
  select s.* into v_shipment from public.shipments s where s.id = p_shipment_id for update;

  if v_shipment.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_shipment.store_id) then
    raise exception 'الشحنة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  if v_shipment.row_version <> p_expected_version then
    raise exception 'تم تعديل هذه الشحنة من قِبل مستخدم آخر — يرجى إعادة تحميل البيانات والمحاولة مجددًا (الإصدار المتوقع %، الإصدار الحالي %)', p_expected_version, v_shipment.row_version
      using errcode = 'P0001';
  end if;

  if not v_shipment.is_cod then
    raise exception 'هذه الشحنة ليست دفعًا عند الاستلام (COD) — لا يمكن تسجيل حالة تحصيل لها' using errcode = 'P0001';
  end if;

  -- Item 18 (business-date chronology, applied here directly): a COD
  -- collection event can never be dated before the shipment itself.
  if p_business_date < v_shipment.shipment_date then
    raise exception 'لا يمكن أن يكون تاريخ حالة التحصيل (%) قبل تاريخ الشحنة نفسها (%)', p_business_date, v_shipment.shipment_date using errcode = 'P0001';
  end if;

  -- Daily Close — shared lock + gating on the COD EVENT's own business_date
  -- (Section 28-style, same as record_shipment_actual_cost(), 0118).
  perform public.acquire_daily_close_lock_shared(v_shipment.store_id, p_business_date);

  select exists (
    select 1 from public.daily_closings dc where dc.store_id = v_shipment.store_id and dc.business_date = p_business_date
  ) into v_is_closed;

  if v_is_closed then
    if not public.has_permission('shipments.process_closed_day') then
      raise exception 'اليوم % مقفل لهذا المتجر — لا يمكن تسجيل حالة تحصيل فيه إلا بصلاحية خاصة (shipments.process_closed_day)', p_business_date using errcode = 'P0001';
    end if;

    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتسجيل حالة تحصيل في يوم مقفل' using errcode = 'P0001';
    end if;

    v_used_closed_day_override := true;
  end if;

  insert into public.shipment_cod_events (shipment_id, state, business_date, reference, reason, actor)
  values (p_shipment_id, p_new_state, p_business_date, p_reference, p_notes, v_actor);

  v_new_row_version := v_shipment.row_version + 1;

  update public.shipments
  set cod_collection_state = p_new_state, updated_by = v_actor, row_version = v_new_row_version
  where id = p_shipment_id;

  -- 'shipment.cod_state_record' — deliberately UNGATED in audit_logs RLS
  -- (0121/0124's gated list is unchanged by this migration): this event
  -- never carries a money figure — cod_expected_amount was already fixed
  -- at creation (and stays profit-gated there) — only a state string/date/
  -- reference, exactly like shipment.status_add.
  perform public.log_audit_event(
    'shipment.cod_state_record', 'shipment', p_shipment_id, jsonb_build_object('cod_collection_state', v_shipment.cod_collection_state),
    jsonb_build_object(
      'cod_collection_state', p_new_state, 'business_date', p_business_date, 'reference', p_reference,
      'recorded_on_closed_day', v_used_closed_day_override
    ),
    p_notes
  );

  if v_used_closed_day_override then
    perform public.log_audit_event(
      'shipment.closed_day_override', 'shipment', p_shipment_id, null,
      jsonb_build_object('business_date', p_business_date, 'action', 'cod_state_record'),
      p_closed_day_reason
    );
  end if;

  return query select v_new_row_version;
end;
$$;

comment on function public.record_shipment_cod_collection_state(uuid, bigint, text, date, text, text, text) is
  'Patch 5.1 (item 13/14) — appends a shipment_cod_events row and transactionally advances shipments.cod_collection_state (the cache). Rejects if the shipment is not COD. Gated on shipments.manage_cost (Financial/Settlement-adjacent per item 13, no new permission key), Daily Close checked against p_business_date, user_visible_store_ids() scope, optimistic concurrency via row_version. Never creates a Settlement, never touches Sales/Returns P/L. SECURITY DEFINER.';

revoke execute on function public.record_shipment_cod_collection_state(uuid, bigint, text, date, text, text, text) from public;
grant execute on function public.record_shipment_cod_collection_state(uuid, bigint, text, date, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- PART C — surface the COD event timeline in get_shipment() (operational,
-- never profit-sensitive — same reasoning as status_timeline).
-- ---------------------------------------------------------------------------
create or replace function public.get_shipment(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_shipment record;
  v_can_view_profit boolean;
  v_order_number text;
  v_return_number text;
  v_store_name text;
  v_original_sale_store_id uuid;
  v_original_sale_store_name text;
  v_carrier_code text;
  v_carrier_name text;
  v_zone_code text;
  v_zone_name text;
  v_status_timeline jsonb;
  v_cod_timeline jsonb;
  v_financial_events jsonb;
  v_effective_charge numeric;
  v_has_actual_cost boolean;
begin
  if v_actor is null or not public.has_permission('shipments.view') then
    raise exception 'ليست لديك صلاحية عرض الشحنات' using errcode = 'P0001';
  end if;

  select s.* into v_shipment from public.shipments s where s.id = p_id;

  if v_shipment.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_shipment.store_id) then
    raise exception 'الشحنة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  v_can_view_profit := public.has_permission('sales.view_profit');
  v_has_actual_cost := v_shipment.actual_carrier_cost is not null;

  select so.order_number, so.store_id into v_order_number, v_original_sale_store_id from public.sales_orders so where so.id = v_shipment.sales_order_id;
  select sr.return_number into v_return_number from public.sales_returns sr where sr.id = v_shipment.sales_return_id;
  select st.name_ar into v_store_name from public.stores st where st.id = v_shipment.store_id;
  select st.name_ar into v_original_sale_store_name from public.stores st where st.id = v_original_sale_store_id;
  select c.code, c.name_ar into v_carrier_code, v_carrier_name from public.shipping_carriers c where c.id = v_shipment.carrier_id;
  select z.code, z.name_ar into v_zone_code, v_zone_name from public.shipping_zones z where z.id = v_shipment.shipping_zone_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', e.id, 'status', e.status, 'event_business_date', e.event_business_date, 'event_at', e.event_at,
      'notes', e.notes, 'is_correction', e.is_correction, 'external_reference', e.external_reference,
      'actor', e.actor, 'created_at', e.created_at
    )
    order by e.created_at
  ), '[]'::jsonb) into v_status_timeline
  from public.shipment_status_events e
  where e.shipment_id = v_shipment.id;

  -- Item 13/27 — COD collection-state timeline, operational only, never
  -- profit-gated (mirrors status_timeline exactly).
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', ce.id, 'state', ce.state, 'business_date', ce.business_date,
      'reference', ce.reference, 'reason', ce.reason, 'actor', ce.actor, 'created_at', ce.created_at
    )
    order by ce.created_at
  ), '[]'::jsonb) into v_cod_timeline
  from public.shipment_cod_events ce
  where ce.shipment_id = v_shipment.id;

  select fe.amount into v_effective_charge
  from public.shipment_financial_events fe
  where fe.shipment_id = v_shipment.id and fe.event_type = 'customer_charge_correction'
  order by fe.created_at desc limit 1;

  v_effective_charge := coalesce(v_effective_charge, v_shipment.customer_shipping_charge);

  if v_can_view_profit then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id', fe.id, 'event_type', fe.event_type, 'amount', fe.amount::text, 'business_date', fe.business_date,
        'reference', fe.reference, 'reason', fe.reason, 'actor', fe.actor, 'created_at', fe.created_at
      )
      order by fe.created_at
    ), '[]'::jsonb) into v_financial_events
    from public.shipment_financial_events fe
    where fe.shipment_id = v_shipment.id;
  end if;

  return jsonb_build_object(
    'id', v_shipment.id, 'shipment_number', v_shipment.shipment_number,
    'sales_order_id', v_shipment.sales_order_id, 'order_number', v_order_number,
    'sales_return_id', v_shipment.sales_return_id, 'return_number', v_return_number,
    'store_id', v_shipment.store_id, 'store_name', v_store_name,
    'original_sale_store_id', v_original_sale_store_id, 'original_sale_store_name', v_original_sale_store_name,
    'carrier_id', v_shipment.carrier_id, 'carrier_code', v_carrier_code, 'carrier_name', v_carrier_name,
    'shipping_zone_id', v_shipment.shipping_zone_id, 'zone_code', v_zone_code, 'zone_name', v_zone_name,
    'direction', v_shipment.direction, 'fulfillment_type', v_shipment.fulfillment_type,
    'tracking_number', v_shipment.tracking_number, 'external_reference', v_shipment.external_reference,
    'customer_name', v_shipment.customer_name_snapshot, 'customer_phone', v_shipment.customer_phone_snapshot,
    'recipient_address', v_shipment.recipient_address_snapshot, 'shipment_date', v_shipment.shipment_date,
    'is_cod', v_shipment.is_cod, 'cod_collection_state', v_shipment.cod_collection_state,
    'cod_timeline', v_cod_timeline,
    'current_status', v_shipment.current_status, 'notes', v_shipment.notes,
    'row_version', v_shipment.row_version,
    'created_by', v_shipment.created_by, 'updated_by', v_shipment.updated_by,
    'created_at', v_shipment.created_at, 'updated_at', v_shipment.updated_at,
    'status_timeline', v_status_timeline,
    'customer_shipping_charge', v_shipment.customer_shipping_charge::text,
    'effective_customer_shipping_charge', v_effective_charge::text,
    'customer_return_shipping_fee_version_id', v_shipment.customer_return_shipping_fee_version_id,
    'customer_return_shipping_fee_standard_amount', v_shipment.customer_return_shipping_fee_standard_amount::text,
    'customer_return_shipping_charge_is_override', v_shipment.customer_return_shipping_charge_is_override,
    'customer_return_shipping_charge_override_reason', v_shipment.customer_return_shipping_charge_override_reason,
    'has_actual_carrier_cost', v_has_actual_cost
  )
  || case when v_can_view_profit then jsonb_build_object(
    'carrier_rate_version_id', v_shipment.carrier_rate_version_id,
    'expected_carrier_cost', v_shipment.expected_carrier_cost::text,
    'expected_carrier_cost_is_manual', v_shipment.expected_carrier_cost_is_manual,
    'expected_carrier_cost_manual_reason', v_shipment.expected_carrier_cost_manual_reason,
    'actual_carrier_cost', v_shipment.actual_carrier_cost::text,
    'net_shipping_expected', v_shipment.net_shipping_expected::text,
    'net_shipping_actual', v_shipment.net_shipping_actual::text,
    'cod_expected_amount', v_shipment.cod_expected_amount::text,
    'financial_events', v_financial_events
  ) else '{}'::jsonb end;
end;
$$;

comment on function public.get_shipment(uuid) is
  'Phase 5 (Section 37), corrected by Patch 5.1 (0126/0127): customer_shipping_charge/effective_customer_shipping_charge, the Customer Return Shipping Fee snapshot (0125), has_actual_carrier_cost (item 23), and cod_timeline (item 13/27, operational) are ALWAYS present. Still gated behind sales.view_profit: carrier_rate_version_id, expected/actual_carrier_cost, net_shipping_expected/actual, cod_expected_amount, financial_events. Scoped via user_visible_store_ids(). SECURITY DEFINER.';

revoke execute on function public.get_shipment(uuid) from public;
grant execute on function public.get_shipment(uuid) to authenticated;

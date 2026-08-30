-- ============================================================================
-- 0152: Phase 6 Integrity Patch 6.1 (9/13): narrow Pending-edit getter
-- (closes the Hidden adjustments.view dependency, item 23) + view-only
-- historical filter lookups (item 22)
-- ============================================================================
-- Migrations 0001-0151 are unmodified.
--
-- item 23 — /adjustments/[id]/edit (and the post-create redirect target)
-- previously called getAdjustmentDetail() -> get_sales_order_adjustment(),
-- which requires adjustments.view. A create-only actor (adjustments.create,
-- no adjustments.view) could successfully CREATE a Pending record and then
-- land on a page that immediately denied them — a hidden permission
-- dependency the spec explicitly calls out. get_pending_sales_order_
-- adjustment_for_edit() is the narrow fix: gated on adjustments.create
-- ALONE, returns only the fields the edit form actually needs, no profit
-- history (there is none while pending anyway), no approved/rejected
-- record ever (explicitly pending-only).
--
-- item 22 — /adjustments' type/payment-method/collection-channel filters
-- were wired to the CREATE-flow lookups (adjustments_active_type_lookups()
-- et al., 0136/0137), which are active-only and gated on adjustments.create
-- — so a adjustments.view-only actor (no create) landed on a list page
-- whose filters silently used a permission they don't hold, and any
-- adjustment referencing an already-disabled/inactive type or a since-
-- disabled payment method/channel had NO filter option to select it by.
-- These three new lookups are gated on adjustments.view alone and return
-- the FULL catalog (including disabled/inactive) for exactly this reason.
-- ---------------------------------------------------------------------------
create or replace function public.get_pending_sales_order_adjustment_for_edit(p_id uuid)
returns table (
  id uuid,
  row_version bigint,
  sales_order_id uuid,
  order_number text,
  adjustment_type_id uuid,
  processing_store_id uuid,
  adjustment_date date,
  payment_method_id uuid,
  collection_channel_id uuid,
  payment_reference text,
  participates_in_settlement boolean,
  customer_charge text,
  has_direct_cost boolean,
  direct_cost text,
  notes text,
  status text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_row record;
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء/تعديل تعديل/خدمة' using errcode = 'P0001';
  end if;

  select a.*, so.order_number, so.store_id as sale_store_id
  into v_row
  from public.sales_order_adjustments a
  join public.sales_orders so on so.id = a.sales_order_id
  where a.id = p_id;

  if v_row.id is null then
    raise exception 'التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_row.sale_store_id)
     or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_row.processing_store_id) then
    raise exception 'التعديل/الخدمة غير مرئي لك' using errcode = 'P0001';
  end if;

  if v_row.status <> 'pending' then
    raise exception 'لم يعد هذا التعديل/الخدمة قيد الانتظار — لا يمكن تحريره' using errcode = 'P0001';
  end if;

  id := v_row.id;
  row_version := v_row.row_version;
  sales_order_id := v_row.sales_order_id;
  order_number := v_row.order_number;
  adjustment_type_id := v_row.adjustment_type_id;
  processing_store_id := v_row.processing_store_id;
  adjustment_date := v_row.adjustment_date;
  payment_method_id := v_row.payment_method_id;
  collection_channel_id := v_row.collection_channel_id;
  payment_reference := v_row.payment_reference;
  participates_in_settlement := v_row.participates_in_settlement;
  customer_charge := v_row.customer_charge::text;
  has_direct_cost := v_row.direct_cost is not null;
  notes := v_row.notes;
  status := v_row.status;

  if public.has_permission('sales.view_profit') or public.has_permission('adjustments.manage_cost') then
    direct_cost := v_row.direct_cost::text;
  else
    direct_cost := null;
  end if;

  return next;
end;
$$;

comment on function public.get_pending_sales_order_adjustment_for_edit(uuid) is
  'Patch 6.1 item 23 — narrow read for /adjustments/[id]/edit, gated on adjustments.create ALONE (never adjustments.view). PENDING only — raises a clear, catchable error otherwise so the page can redirect to the (permission-gated) detail page instead. No profit history (gross/net/fee) exposed at all — direct_cost visible to sales.view_profit OR adjustments.manage_cost, same pending exception as get_sales_order_adjustment() (0151). SECURITY DEFINER.';

revoke execute on function public.get_pending_sales_order_adjustment_for_edit(uuid) from public;
grant execute on function public.get_pending_sales_order_adjustment_for_edit(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- View-only historical filter lookups (item 22) — full catalog including
-- disabled/inactive, gated on adjustments.view alone.
-- ---------------------------------------------------------------------------
create or replace function public.adjustments_filter_type_lookups()
returns table (id uuid, code text, name_ar text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('adjustments.view') then
    raise exception 'ليست لديك صلاحية عرض التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  return query
  select t.id, t.code, t.name_ar, t.status
  from public.adjustment_types t
  order by t.sort_order, t.name_ar;
end;
$$;

comment on function public.adjustments_filter_type_lookups() is
  'Patch 6.1 item 22 — FULL type catalog (including disabled) for the /adjustments list filter, gated on adjustments.view alone (NOT adjustments.create/adjustments.manage_types) — a view-only actor must be able to filter by a type that is now disabled but still referenced by a visible historical record.';

revoke execute on function public.adjustments_filter_type_lookups() from public;
grant execute on function public.adjustments_filter_type_lookups() to authenticated;

create or replace function public.adjustments_filter_payment_method_lookups()
returns table (id uuid, key text, name_ar text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('adjustments.view') then
    raise exception 'ليست لديك صلاحية عرض التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  return query
  select pm.id, pm.key, pm.name_ar, pm.status
  from public.payment_methods pm
  order by pm.name_ar;
end;
$$;

comment on function public.adjustments_filter_payment_method_lookups() is
  'Patch 6.1 item 22 — FULL payment method catalog (including inactive) for the /adjustments list filter, gated on adjustments.view alone.';

revoke execute on function public.adjustments_filter_payment_method_lookups() from public;
grant execute on function public.adjustments_filter_payment_method_lookups() to authenticated;

create or replace function public.adjustments_filter_collection_channel_lookups()
returns table (id uuid, key text, name_ar text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('adjustments.view') then
    raise exception 'ليست لديك صلاحية عرض التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  return query
  select cc.id, cc.key, cc.name_ar, cc.status
  from public.collection_channels cc
  order by cc.name_ar;
end;
$$;

comment on function public.adjustments_filter_collection_channel_lookups() is
  'Patch 6.1 item 22 — FULL collection channel catalog (including inactive) for the /adjustments list filter, gated on adjustments.view alone.';

revoke execute on function public.adjustments_filter_collection_channel_lookups() from public;
grant execute on function public.adjustments_filter_collection_channel_lookups() to authenticated;

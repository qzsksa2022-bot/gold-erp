-- ============================================================================
-- 0080: Phase 3 — Final Sales Integrity Patch 3.2 (8/8): sales_order_edit_lookups()
-- — historical-inclusive lookups for the Edit form, without broadening
-- Master Data permissions
-- ============================================================================
-- Migrations 0001-0072 are unmodified. Brand-new function.
--
-- Problem (spec item 6): update_sales_order() (0075, and 0069 before it)
-- correctly ALLOWS an unchanged reference to remain even if it has since
-- become inactive — but the Edit UI's Select inputs are populated from
-- active-only lookups (getSalesFormLookups(), shared with the New Sale
-- form), so a historical Sale that references a now-inactive Karat/
-- Category/Payment Method/Collection Channel doesn't render correctly in
-- its own Edit form (the current value is either missing from the list or
-- shows blank).
--
-- Fix: a Sales-specific RPC, scoped to ONE order the caller can already
-- edit, that returns every ACTIVE option (for making a genuine change) PLUS
-- the order's own CURRENTLY-USED value for each of the four reference kinds
-- even if that value is now inactive — flagged is_historical so the UI can
-- label it (e.g. "عيار 21 — غير نشط (تاريخي)") and allow it to remain
-- selected, while the client-side Select must still prevent choosing any
-- OTHER inactive option (server-side, update_sales_order() independently
-- re-enforces this: a NEWLY-selected inactive reference is always
-- rejected, regardless of what the UI allows).
--
-- Deliberately NOT a general Master Data browsing grant: this function
-- requires sales.edit AND that the caller can see this exact order (same
-- user_visible_store_ids() scope as update_sales_order()/
-- preview_update_sales_order(), item 9) — it returns only the active
-- catalogue (which every Sales editor already effectively needs to create/
-- edit a Sale, and getSalesFormLookups() already exposes today) plus the
-- handful of specific historical rows actually referenced by THIS order,
-- never a general active-or-inactive Master Data listing independent of a
-- Sale the caller is permitted to touch.
-- ---------------------------------------------------------------------------
create or replace function public.sales_order_edit_lookups(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_order record;
  v_categories jsonb;
  v_karats jsonb;
  v_payment_methods jsonb;
  v_collection_channels jsonb;
  v_historical_category_ids uuid[];
  v_historical_karat_ids uuid[];
begin
  if v_actor is null or not public.has_permission('sales.edit') then
    raise exception 'ليست لديك صلاحية تعديل عمليات البيع' using errcode = 'P0001';
  end if;

  select * into v_order from public.sales_orders so where so.id = p_order_id;

  -- Item 9 — same VISIBLE-scope policy as update_sales_order()/
  -- preview_update_sales_order() (0075/0078): store_id is immutable on
  -- edit, so a disabled store must not block loading the Edit form either.
  if v_order.id is null or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_order.store_id) then
    raise exception 'عملية البيع غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  -- Every category/karat actually referenced by one of this order's
  -- (active) items — used below to include the historical row even if it
  -- is currently inactive, and to avoid listing it twice if it is active.
  select coalesce(array_agg(distinct it.category_id), '{}'::uuid[]) into v_historical_category_ids
  from public.sales_order_items it where it.sales_order_id = p_order_id and it.status = 'active';

  select coalesce(array_agg(distinct it.karat_id), '{}'::uuid[]) into v_historical_karat_ids
  from public.sales_order_items it where it.sales_order_id = p_order_id and it.status = 'active';

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pc.id, 'name_ar', pc.name_ar, 'is_historical', (pc.status <> 'active')
  ) order by pc.name_ar), '[]'::jsonb) into v_categories
  from public.product_categories pc
  where pc.status = 'active' or pc.id = any(v_historical_category_ids);

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', k.id, 'name_ar', k.name_ar, 'code', k.code, 'is_historical', (k.status <> 'active')
  ) order by k.name_ar), '[]'::jsonb) into v_karats
  from public.karats k
  where k.status = 'active' or k.id = any(v_historical_karat_ids);

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pm.id, 'name_ar', pm.name_ar, 'is_historical', (pm.status <> 'active')
  ) order by pm.name_ar), '[]'::jsonb) into v_payment_methods
  from public.payment_methods pm
  where pm.status = 'active' or pm.id = v_order.payment_method_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cc.id, 'name_ar', cc.name_ar, 'is_historical', (cc.status <> 'active')
  ) order by cc.name_ar), '[]'::jsonb) into v_collection_channels
  from public.collection_channels cc
  where cc.status = 'active' or cc.id = v_order.collection_channel_id;

  return jsonb_build_object(
    'categories', v_categories,
    'karats', v_karats,
    'payment_methods', v_payment_methods,
    'collection_channels', v_collection_channels
  );
end;
$$;

comment on function public.sales_order_edit_lookups(uuid) is
  'Patch 3.2 item 6 — Edit-mode lookup source for ONE Sale the caller already holds sales.edit + visible-store access to: every ACTIVE category/karat/payment method/collection channel, PLUS the order''s own currently-used values even if now inactive (flagged is_historical). NOT a general Master Data grant — scoped to exactly the reference rows this specific order uses. update_sales_order()/preview_update_sales_order() independently re-enforce that only an UNCHANGED inactive reference is ever accepted; this RPC only controls what the Edit form can display/offer, not what the server will accept.';

revoke execute on function public.sales_order_edit_lookups(uuid) from public;
grant execute on function public.sales_order_edit_lookups(uuid) to authenticated;

-- ============================================================================
-- 0229: Phase 9 — Inventory Core (3/3): SECURITY DEFINER RPCs
-- ============================================================================
-- Migrations 0001-0228 are unmodified.
--
-- Every mutation/read below is a SECURITY DEFINER RPC (search_path pinned to
-- public, pg_temp) — the base tables carry zero direct-write RLS policy
-- (0228), so this is not merely a convention, it is the only path that
-- works at all, mirroring every prior phase exactly. Money/weight/quantity
-- values are always returned ::text (never a raw numeric column), matching
-- this codebase's "safe" RPC convention (see src/lib/decimal.ts's toDecimal
-- doc comment) — PostgREST serializes numeric as an unquoted JSON number by
-- default, which is exactly where precision can silently be lost.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- create_inventory_item() — a new SKU. Gated on inventory.receive (a new
-- catalog entry is typically introduced at the moment stock is first
-- received for it — mirrors how a new adjustment_type is a Master-Data
-- action, just gated on the operational permission that actually needs it
-- here, since Phase 9's approved scope defines only 3 permission keys, none
-- of which is a dedicated "manage catalog" key).
-- ---------------------------------------------------------------------------
create or replace function public.create_inventory_item(
  p_sku text,
  p_name_ar text,
  p_category_id uuid,
  p_karat_id uuid default null,
  p_unit text default 'gram',
  p_notes text default null
)
returns table (id uuid, sku text, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
begin
  if v_actor is null or not public.has_permission('inventory.receive') then
    raise exception 'ليست لديك صلاحية إضافة صنف مخزون' using errcode = 'P0001';
  end if;

  if p_sku is null or btrim(p_sku) = '' then
    raise exception 'رمز الصنف (SKU) مطلوب' using errcode = 'P0001';
  end if;

  if p_name_ar is null or btrim(p_name_ar) = '' then
    raise exception 'اسم الصنف مطلوب' using errcode = 'P0001';
  end if;

  if p_unit is null or p_unit not in ('gram', 'piece') then
    raise exception 'وحدة القياس غير صالحة' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.product_categories c where c.id = p_category_id and c.status = 'active') then
    raise exception 'التصنيف غير موجود أو غير نشط' using errcode = 'P0001';
  end if;

  if p_karat_id is not null and not exists (select 1 from public.karats k where k.id = p_karat_id and k.status = 'active') then
    raise exception 'العيار غير موجود أو غير نشط' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.inventory_items i where lower(i.sku) = lower(btrim(p_sku))) then
    raise exception 'رمز الصنف (SKU) مستخدم بالفعل' using errcode = 'P0001';
  end if;

  insert into public.inventory_items (sku, name_ar, category_id, karat_id, unit, notes, created_by, updated_by)
  values (btrim(p_sku), btrim(p_name_ar), p_category_id, p_karat_id, p_unit, nullif(btrim(coalesce(p_notes, '')), ''), v_actor, v_actor)
  returning inventory_items.id into v_id;

  perform public.log_audit_event('inventory.create_item', 'inventory_item', v_id, null, jsonb_build_object('sku', p_sku, 'name_ar', p_name_ar, 'category_id', p_category_id, 'karat_id', p_karat_id, 'unit', p_unit));

  return query select v_id, i.sku, i.row_version from public.inventory_items i where i.id = v_id;
end;
$$;

revoke execute on function public.create_inventory_item(text, text, uuid, uuid, text, text) from public;
grant execute on function public.create_inventory_item(text, text, uuid, uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- update_inventory_item() — edit catalog fields (never sku, permanent once
-- created, mirrors adjustment_types.code). Gated on inventory.adjust
-- (correcting an existing item's master data is a correction action).
-- row_version-checked optimistic concurrency, mirrors update_sales_order_
-- adjustment() (0146) exactly.
-- ---------------------------------------------------------------------------
create or replace function public.update_inventory_item(
  p_id uuid,
  p_expected_version bigint,
  p_name_ar text,
  p_category_id uuid,
  p_karat_id uuid default null,
  p_unit text default 'gram',
  p_active boolean default true,
  p_notes text default null
)
returns table (id uuid, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old public.inventory_items%rowtype;
begin
  if v_actor is null or not public.has_permission('inventory.adjust') then
    raise exception 'ليست لديك صلاحية تعديل بيانات صنف مخزون' using errcode = 'P0001';
  end if;

  if p_name_ar is null or btrim(p_name_ar) = '' then
    raise exception 'اسم الصنف مطلوب' using errcode = 'P0001';
  end if;

  if p_unit is null or p_unit not in ('gram', 'piece') then
    raise exception 'وحدة القياس غير صالحة' using errcode = 'P0001';
  end if;

  select * into v_old from public.inventory_items where id = p_id for update;

  if not found then
    raise exception 'الصنف غير موجود' using errcode = 'P0001';
  end if;

  if v_old.row_version <> p_expected_version then
    raise exception 'تم تعديل هذا الصنف من قِبل مستخدم آخر، الرجاء إعادة التحميل والمحاولة مرة أخرى' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.product_categories c where c.id = p_category_id and c.status = 'active') then
    raise exception 'التصنيف غير موجود أو غير نشط' using errcode = 'P0001';
  end if;

  if p_karat_id is not null and not exists (select 1 from public.karats k where k.id = p_karat_id and k.status = 'active') then
    raise exception 'العيار غير موجود أو غير نشط' using errcode = 'P0001';
  end if;

  update public.inventory_items
  set name_ar = btrim(p_name_ar),
      category_id = p_category_id,
      karat_id = p_karat_id,
      unit = p_unit,
      active = coalesce(p_active, true),
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      row_version = row_version + 1,
      updated_by = v_actor,
      updated_at = now()
  where inventory_items.id = p_id;

  perform public.log_audit_event(
    'inventory.update_item', 'inventory_item', p_id,
    jsonb_build_object('name_ar', v_old.name_ar, 'category_id', v_old.category_id, 'karat_id', v_old.karat_id, 'unit', v_old.unit, 'active', v_old.active),
    jsonb_build_object('name_ar', p_name_ar, 'category_id', p_category_id, 'karat_id', p_karat_id, 'unit', p_unit, 'active', p_active)
  );

  return query select p_id, i.row_version from public.inventory_items i where i.id = p_id;
end;
$$;

revoke execute on function public.update_inventory_item(uuid, bigint, text, uuid, uuid, text, boolean, text) from public;
grant execute on function public.update_inventory_item(uuid, bigint, text, uuid, uuid, text, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
-- record_inventory_stock_movement() — shared internal engine for both
-- receive_inventory_stock()/adjust_inventory_stock() below. Takes the
-- advisory lock from 0227 BEFORE summing the ledger, so a concurrent call
-- for the SAME (item_id, store_id) pair can never both observe a
-- pre-decrement balance and both push it negative — this is the real race
-- guard, mirroring reconcile_settlement_batch()'s row-lock-then-compute
-- shape (0180) with an advisory lock standing in for a row lock (there is
-- no balance row to lock).
-- ---------------------------------------------------------------------------
create or replace function public.record_inventory_stock_movement(
  p_permission text,
  p_item_id uuid,
  p_store_id uuid,
  p_movement_kind text,
  p_quantity_delta numeric,
  p_business_date date,
  p_reason text,
  p_reference text
)
returns table (id uuid, resulting_balance text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_current_balance numeric(14, 3);
  v_new_balance numeric(14, 3);
  v_id uuid;
begin
  if v_actor is null or not public.has_permission(p_permission) then
    raise exception 'ليست لديك صلاحية تنفيذ هذا الإجراء' using errcode = 'P0001';
  end if;

  if p_quantity_delta is null or p_quantity_delta = 0 then
    raise exception 'الكمية يجب ألا تساوي صفرًا' using errcode = 'P0001';
  end if;

  if p_movement_kind = 'receive' and p_quantity_delta < 0 then
    raise exception 'كمية الاستلام يجب أن تكون رقمًا موجبًا' using errcode = 'P0001';
  end if;

  if p_movement_kind = 'adjust' and (p_reason is null or btrim(p_reason) = '') then
    raise exception 'سبب التصحيح مطلوب' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.inventory_items i where i.id = p_item_id and i.active) then
    raise exception 'الصنف غير موجود أو غير نشط' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'ليس لديك صلاحية الوصول لهذا الفرع' using errcode = 'P0001';
  end if;

  -- Real race guard (Pre-check below is only a friendly error message
  -- ahead of it, mirrors the 0179 "the REAL race guard is the UNIQUE index"
  -- comment) — everything from here to the INSERT runs serialized per
  -- (item_id, store_id) pair.
  perform public.acquire_inventory_item_store_lock(p_item_id, p_store_id);

  select coalesce(sum(quantity_delta), 0) into v_current_balance
  from public.inventory_stock_movements
  where item_id = p_item_id and store_id = p_store_id;

  v_new_balance := v_current_balance + p_quantity_delta;

  if v_new_balance < 0 then
    raise exception 'الكمية الناتجة ستكون سالبة (الرصيد الحالي %، والحركة المطلوبة %) — العملية مرفوضة', v_current_balance, p_quantity_delta using errcode = 'P0001';
  end if;

  insert into public.inventory_stock_movements (item_id, store_id, movement_kind, quantity_delta, business_date, reason, reference, created_by)
  values (p_item_id, p_store_id, p_movement_kind, p_quantity_delta, coalesce(p_business_date, current_date), nullif(btrim(coalesce(p_reason, '')), ''), nullif(btrim(coalesce(p_reference, '')), ''), v_actor)
  returning inventory_stock_movements.id into v_id;

  perform public.log_audit_event(
    'inventory.' || p_movement_kind, 'inventory_stock_movement', v_id, null,
    jsonb_build_object('item_id', p_item_id, 'store_id', p_store_id, 'quantity_delta', p_quantity_delta, 'resulting_balance', v_new_balance)
  );

  return query select v_id, v_new_balance::text;
end;
$$;

revoke execute on function public.record_inventory_stock_movement(text, uuid, uuid, text, numeric, date, text, text) from public;
-- Intentionally NOT granted to authenticated directly — always called
-- through receive_inventory_stock()/adjust_inventory_stock() below, which
-- hardcode the movement_kind/permission pair so a client can never pass a
-- mismatched combination (e.g. 'receive' gated on inventory.adjust).

create or replace function public.receive_inventory_stock(
  p_item_id uuid,
  p_store_id uuid,
  p_quantity numeric,
  p_business_date date default current_date,
  p_reference text default null,
  p_notes text default null
)
returns table (id uuid, resulting_balance text)
language sql
security definer
set search_path = public, pg_temp
as $$
  select * from public.record_inventory_stock_movement('inventory.receive', p_item_id, p_store_id, 'receive', p_quantity, p_business_date, p_notes, p_reference);
$$;

revoke execute on function public.receive_inventory_stock(uuid, uuid, numeric, date, text, text) from public;
grant execute on function public.receive_inventory_stock(uuid, uuid, numeric, date, text, text) to authenticated;

create or replace function public.adjust_inventory_stock(
  p_item_id uuid,
  p_store_id uuid,
  p_quantity_delta numeric,
  p_reason text,
  p_business_date date default current_date,
  p_reference text default null
)
returns table (id uuid, resulting_balance text)
language sql
security definer
set search_path = public, pg_temp
as $$
  select * from public.record_inventory_stock_movement('inventory.adjust', p_item_id, p_store_id, 'adjust', p_quantity_delta, p_business_date, p_reason, p_reference);
$$;

revoke execute on function public.adjust_inventory_stock(uuid, uuid, numeric, text, date, text) from public;
grant execute on function public.adjust_inventory_stock(uuid, uuid, numeric, text, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- list_inventory_items() — paginated catalog, gated on inventory.view.
-- ---------------------------------------------------------------------------
create or replace function public.list_inventory_items(
  p_search text default null,
  p_category_id uuid default null,
  p_karat_id uuid default null,
  p_active boolean default null,
  p_limit int default 20,
  p_offset int default 0
)
returns table (
  id uuid, sku text, name_ar text, category_id uuid, category_name_ar text,
  karat_id uuid, karat_name_ar text, unit text, active boolean, notes text,
  row_version bigint, created_at timestamptz, total_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('inventory.view') then
    raise exception 'ليست لديك صلاحية عرض المخزون' using errcode = 'P0001';
  end if;

  return query
  with filtered as (
    select i.*
    from public.inventory_items i
    where (p_category_id is null or i.category_id = p_category_id)
      and (p_karat_id is null or i.karat_id = p_karat_id)
      and (p_active is null or i.active = p_active)
      and (p_search is null or btrim(p_search) = '' or i.sku ilike '%' || btrim(p_search) || '%' or i.name_ar ilike '%' || btrim(p_search) || '%')
  ),
  counted as (select count(*) as c from filtered)
  select
    f.id, f.sku, f.name_ar, f.category_id, c.name_ar, f.karat_id, k.name_ar, f.unit, f.active, f.notes,
    f.row_version, f.created_at, counted.c
  from filtered f
  left join public.product_categories c on c.id = f.category_id
  left join public.karats k on k.id = f.karat_id
  cross join counted
  order by f.name_ar
  limit p_limit offset p_offset;
end;
$$;

revoke execute on function public.list_inventory_items(text, uuid, uuid, boolean, int, int) from public;
grant execute on function public.list_inventory_items(text, uuid, uuid, boolean, int, int) to authenticated;

-- ---------------------------------------------------------------------------
-- list_inventory_stock_balances() — one row per (item, store) that has ANY
-- movement, balance derived live from the ledger. Gated on inventory.view;
-- always scoped to the actor's user_visible_store_ids() regardless of what
-- p_store_id is passed, so a caller can never enumerate a store's balances
-- they cannot see.
-- ---------------------------------------------------------------------------
create or replace function public.list_inventory_stock_balances(
  p_store_id uuid default null,
  p_item_id uuid default null,
  p_search text default null,
  p_limit int default 20,
  p_offset int default 0
)
returns table (
  item_id uuid, sku text, name_ar text, unit text,
  store_id uuid, store_name_ar text, balance text, total_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('inventory.view') then
    raise exception 'ليست لديك صلاحية عرض المخزون' using errcode = 'P0001';
  end if;

  if p_store_id is not null and not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'ليس لديك صلاحية الوصول لهذا الفرع' using errcode = 'P0001';
  end if;

  return query
  with balances as (
    select m.item_id, m.store_id, sum(m.quantity_delta) as balance
    from public.inventory_stock_movements m
    where m.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
      and (p_store_id is null or m.store_id = p_store_id)
      and (p_item_id is null or m.item_id = p_item_id)
    group by m.item_id, m.store_id
  ),
  filtered as (
    select b.item_id, b.store_id, b.balance, i.sku, i.name_ar, i.unit, s.name_ar as store_name_ar
    from balances b
    join public.inventory_items i on i.id = b.item_id
    join public.stores s on s.id = b.store_id
    where p_search is null or btrim(p_search) = '' or i.sku ilike '%' || btrim(p_search) || '%' or i.name_ar ilike '%' || btrim(p_search) || '%'
  ),
  counted as (select count(*) as c from filtered)
  select f.item_id, f.sku, f.name_ar, f.unit, f.store_id, f.store_name_ar, f.balance::text, counted.c
  from filtered f
  cross join counted
  order by f.name_ar, f.store_name_ar
  limit p_limit offset p_offset;
end;
$$;

revoke execute on function public.list_inventory_stock_balances(uuid, uuid, text, int, int) from public;
grant execute on function public.list_inventory_stock_balances(uuid, uuid, text, int, int) to authenticated;

-- ---------------------------------------------------------------------------
-- list_inventory_stock_movements() — history, gated on inventory.view,
-- always scoped to user_visible_store_ids() (mirrors the RLS SELECT policy
-- on inventory_stock_movements, 0228, but applied inside the RPC too so the
-- p_store_id validation error message is friendly rather than a silent
-- empty result).
-- ---------------------------------------------------------------------------
create or replace function public.list_inventory_stock_movements(
  p_item_id uuid default null,
  p_store_id uuid default null,
  p_date_from date default null,
  p_date_to date default null,
  p_limit int default 20,
  p_offset int default 0
)
returns table (
  id uuid, item_id uuid, sku text, item_name_ar text, store_id uuid, store_name_ar text,
  movement_kind text, quantity_delta text, business_date date, reason text, reference text,
  created_at timestamptz, created_by_name text, total_count bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('inventory.view') then
    raise exception 'ليست لديك صلاحية عرض المخزون' using errcode = 'P0001';
  end if;

  if p_store_id is not null and not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'ليس لديك صلاحية الوصول لهذا الفرع' using errcode = 'P0001';
  end if;

  return query
  with filtered as (
    select m.*
    from public.inventory_stock_movements m
    where m.store_id in (select sid from public.user_visible_store_ids(v_actor) sid)
      and (p_store_id is null or m.store_id = p_store_id)
      and (p_item_id is null or m.item_id = p_item_id)
      and (p_date_from is null or m.business_date >= p_date_from)
      and (p_date_to is null or m.business_date <= p_date_to)
  ),
  counted as (select count(*) as c from filtered)
  select
    f.id, f.item_id, i.sku, i.name_ar, f.store_id, s.name_ar, f.movement_kind, f.quantity_delta::text,
    f.business_date, f.reason, f.reference, f.created_at, p.full_name, counted.c
  from filtered f
  join public.inventory_items i on i.id = f.item_id
  join public.stores s on s.id = f.store_id
  left join public.profiles p on p.id = f.created_by
  cross join counted
  order by f.created_at desc
  limit p_limit offset p_offset;
end;
$$;

revoke execute on function public.list_inventory_stock_movements(uuid, uuid, date, date, int, int) from public;
grant execute on function public.list_inventory_stock_movements(uuid, uuid, date, date, int, int) to authenticated;

-- ---------------------------------------------------------------------------
-- Narrow lookups for the UI (mirror adjustments_operable_store_lookups()/
-- adjustments_visible_store_lookups(), 0137) — never depend on stores.view/
-- categories.view/karats.view, only the specific Inventory permission that
-- legitimately needs the picker.
-- ---------------------------------------------------------------------------
create or replace function public.inventory_operable_store_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not (public.has_permission('inventory.receive') or public.has_permission('inventory.adjust')) then
    raise exception 'ليست لديك صلاحية تسجيل حركة مخزون' using errcode = 'P0001';
  end if;

  return query
  select st.id, st.name_ar
  from public.stores st
  where st.id in (select sid from public.user_operable_store_ids(v_actor) sid)
  order by st.name_ar;
end;
$$;

revoke execute on function public.inventory_operable_store_lookups() from public;
grant execute on function public.inventory_operable_store_lookups() to authenticated;

create or replace function public.inventory_visible_store_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('inventory.view') then
    raise exception 'ليست لديك صلاحية عرض المخزون' using errcode = 'P0001';
  end if;

  return query
  select st.id, st.name_ar
  from public.stores st
  where st.id in (select sid from public.user_visible_store_ids(v_actor) sid)
  order by st.name_ar;
end;
$$;

revoke execute on function public.inventory_visible_store_lookups() from public;
grant execute on function public.inventory_visible_store_lookups() to authenticated;

-- Active item picker for the Receive/Adjust dialogs — deliberately gated on
-- inventory.receive OR inventory.adjust ALONE, never inventory.view, so an
-- actor with only the operational permission (no inventory.view) is never
-- silently blocked from populating the item dropdown — mirrors the fix
-- documented on adjustments_active_type_lookups() (0136) vs the later
-- VIEW-only adjustments_filter_type_lookups() (0152): the CREATE-flow
-- picker and the VIEW-flow filter picker are always two distinct RPCs.
create or replace function public.inventory_active_item_lookups()
returns table (id uuid, sku text, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not (public.has_permission('inventory.receive') or public.has_permission('inventory.adjust')) then
    raise exception 'ليست لديك صلاحية تسجيل حركة مخزون' using errcode = 'P0001';
  end if;

  return query select i.id, i.sku, i.name_ar from public.inventory_items i where i.active order by i.name_ar;
end;
$$;

revoke execute on function public.inventory_active_item_lookups() from public;
grant execute on function public.inventory_active_item_lookups() to authenticated;

create or replace function public.inventory_category_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not (public.has_permission('inventory.receive') or public.has_permission('inventory.adjust')) then
    raise exception 'ليست لديك صلاحية إدارة أصناف المخزون' using errcode = 'P0001';
  end if;

  return query select c.id, c.name_ar from public.product_categories c where c.status = 'active' order by c.sort_order, c.name_ar;
end;
$$;

revoke execute on function public.inventory_category_lookups() from public;
grant execute on function public.inventory_category_lookups() to authenticated;

create or replace function public.inventory_karat_lookups()
returns table (id uuid, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not (public.has_permission('inventory.receive') or public.has_permission('inventory.adjust')) then
    raise exception 'ليست لديك صلاحية إدارة أصناف المخزون' using errcode = 'P0001';
  end if;

  return query select k.id, k.name_ar from public.karats k where k.status = 'active' order by k.name_ar;
end;
$$;

revoke execute on function public.inventory_karat_lookups() from public;
grant execute on function public.inventory_karat_lookups() to authenticated;

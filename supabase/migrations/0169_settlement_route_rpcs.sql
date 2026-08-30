-- ============================================================================
-- 0169: Phase 7 — Settlements Core (3/N): settlement_routes CRUD RPCs +
-- narrow lookups
-- ============================================================================
-- Migrations 0001-0168 are unmodified.
--
-- code/route_kind/payment_method_id/collection_channel_id/shipping_
-- carrier_id are set ONCE at creation and never editable afterward (mirrors
-- adjustment_types' `code` immutability, extended here to every matching
-- field — item 36's deterministic route matching would be undermined if a
-- route's matching key could silently change under an already-finalized
-- batch's feet). To correct a mis-configured route, disable it and create a
-- replacement — historical batches keep their own frozen snapshot
-- regardless (item 38).
-- ---------------------------------------------------------------------------
create or replace function public.create_settlement_route(
  p_code text,
  p_name_ar text,
  p_route_kind text,
  p_name_en text default null,
  p_payment_method_id uuid default null,
  p_collection_channel_id uuid default null,
  p_shipping_carrier_id uuid default null,
  p_description text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
  v_code text := btrim(coalesce(p_code, ''));
  v_name_ar text := btrim(coalesce(p_name_ar, ''));
  v_route_kind text := btrim(coalesce(p_route_kind, ''));
begin
  if v_actor is null or not public.has_permission('settlements.manage_routes') then
    raise exception 'ليست لديك صلاحية إدارة مسارات التسوية' using errcode = 'P0001';
  end if;

  if v_code = '' then
    raise exception 'رمز مسار التسوية مطلوب' using errcode = 'P0001';
  end if;
  if v_name_ar = '' then
    raise exception 'الاسم العربي لمسار التسوية مطلوب' using errcode = 'P0001';
  end if;
  if v_route_kind not in ('payment_collection', 'cod_carrier') then
    raise exception 'نوع مسار التسوية غير صالح' using errcode = 'P0001';
  end if;

  if v_route_kind = 'payment_collection' then
    if p_payment_method_id is null then
      raise exception 'طريقة الدفع مطلوبة لمسار تحصيل دفع' using errcode = 'P0001';
    end if;
    if p_shipping_carrier_id is not null then
      raise exception 'مسار تحصيل الدفع لا يجوز أن يحدد شركة شحن' using errcode = 'P0001';
    end if;
  else
    if p_shipping_carrier_id is null then
      raise exception 'شركة الشحن مطلوبة لمسار COD الناقل' using errcode = 'P0001';
    end if;
    if p_payment_method_id is not null or p_collection_channel_id is not null then
      raise exception 'مسار COD الناقل لا يجوز أن يحدد طريقة دفع أو قناة تحصيل' using errcode = 'P0001';
    end if;
  end if;

  perform public.acquire_settlement_master_lock_exclusive();

  if exists (select 1 from public.settlement_routes where lower(code) = lower(v_code)) then
    raise exception 'رمز "%" مستخدم مسبقًا لمسار تسوية آخر', v_code using errcode = 'P0001';
  end if;

  insert into public.settlement_routes (
    code, name_ar, name_en, route_kind, payment_method_id, collection_channel_id, shipping_carrier_id,
    description, created_by, updated_by
  )
  values (
    v_code, v_name_ar, nullif(btrim(coalesce(p_name_en, '')), ''), v_route_kind,
    p_payment_method_id, p_collection_channel_id, p_shipping_carrier_id,
    nullif(btrim(coalesce(p_description, '')), ''), v_actor, v_actor
  )
  returning id into v_id;

  perform public.log_audit_event(
    'settlement_route.create', 'settlement_route', v_id, null,
    jsonb_build_object(
      'code', v_code, 'name_ar', v_name_ar, 'name_en', p_name_en, 'route_kind', v_route_kind,
      'payment_method_id', p_payment_method_id, 'collection_channel_id', p_collection_channel_id,
      'shipping_carrier_id', p_shipping_carrier_id, 'description', p_description
    )
  );

  return v_id;
end;
$$;

comment on function public.create_settlement_route(text, text, text, text, uuid, uuid, uuid, text) is
  'Phase 7 (item 10) — creates a new active Settlement Route. code/route_kind/payment_method_id/collection_channel_id/shipping_carrier_id are permanent from this point on. Requires settlements.manage_routes. SECURITY DEFINER.';

revoke execute on function public.create_settlement_route(text, text, text, text, uuid, uuid, uuid, text) from public;
grant execute on function public.create_settlement_route(text, text, text, text, uuid, uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.update_settlement_route(
  p_id uuid,
  p_name_ar text,
  p_name_en text default null,
  p_description text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old record;
  v_name_ar text := btrim(coalesce(p_name_ar, ''));
  v_description text := nullif(btrim(coalesce(p_description, '')), '');
begin
  if v_actor is null or not public.has_permission('settlements.manage_routes') then
    raise exception 'ليست لديك صلاحية إدارة مسارات التسوية' using errcode = 'P0001';
  end if;

  if v_name_ar = '' then
    raise exception 'الاسم العربي لمسار التسوية مطلوب' using errcode = 'P0001';
  end if;

  perform public.acquire_settlement_master_lock_exclusive();

  select * into v_old from public.settlement_routes where id = p_id for update;
  if v_old.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;

  update public.settlement_routes
  set name_ar = v_name_ar,
      name_en = nullif(btrim(coalesce(p_name_en, '')), ''),
      description = v_description
  where id = p_id;

  perform public.log_audit_event(
    'settlement_route.update', 'settlement_route', p_id,
    jsonb_build_object('name_ar', v_old.name_ar, 'name_en', v_old.name_en, 'description', v_old.description),
    jsonb_build_object('name_ar', v_name_ar, 'name_en', p_name_en, 'description', v_description)
  );
end;
$$;

comment on function public.update_settlement_route(uuid, text, text, text) is
  'Phase 7 — edits name_ar/name_en/description of an existing route only. code/route_kind/matching FKs are never editable here. Requires settlements.manage_routes. SECURITY DEFINER.';

revoke execute on function public.update_settlement_route(uuid, text, text, text) from public;
grant execute on function public.update_settlement_route(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.disable_settlement_route(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old record;
begin
  if v_actor is null or not public.has_permission('settlements.manage_routes') then
    raise exception 'ليست لديك صلاحية إدارة مسارات التسوية' using errcode = 'P0001';
  end if;

  perform public.acquire_settlement_master_lock_exclusive();

  select * into v_old from public.settlement_routes where id = p_id for update;
  if v_old.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;
  if v_old.status = 'disabled' then
    raise exception 'مسار التسوية معطَّل بالفعل' using errcode = 'P0001';
  end if;

  update public.settlement_routes set status = 'disabled' where id = p_id;

  perform public.log_audit_event(
    'settlement_route.disable', 'settlement_route', p_id,
    jsonb_build_object('status', 'active'), jsonb_build_object('status', 'disabled')
  );
end;
$$;

comment on function public.disable_settlement_route(uuid) is
  'Phase 7 — disables an active route (no hard delete, ever). A disabled route may never match a NEW settlement source (item 37) but stays historically visible/readable on every batch that already snapshotted it. Requires settlements.manage_routes. SECURITY DEFINER.';

revoke execute on function public.disable_settlement_route(uuid) from public;
grant execute on function public.disable_settlement_route(uuid) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.enable_settlement_route(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old record;
begin
  if v_actor is null or not public.has_permission('settlements.manage_routes') then
    raise exception 'ليست لديك صلاحية إدارة مسارات التسوية' using errcode = 'P0001';
  end if;

  perform public.acquire_settlement_master_lock_exclusive();

  select * into v_old from public.settlement_routes where id = p_id for update;
  if v_old.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;
  if v_old.status = 'active' then
    raise exception 'مسار التسوية نشط بالفعل' using errcode = 'P0001';
  end if;

  -- Re-activating must not silently create an ambiguous match against
  -- another route already actively claiming the same matching key (item
  -- 36) — the partial unique indexes (0168) enforce this at the DB level;
  -- surface a clear Arabic error instead of a raw constraint-violation
  -- message.
  if exists (
    select 1 from public.settlement_routes r
    where r.id <> p_id and r.status = 'active' and r.route_kind = v_old.route_kind
      and (
        (v_old.route_kind = 'payment_collection'
          and r.payment_method_id = v_old.payment_method_id
          and coalesce(r.collection_channel_id, '00000000-0000-0000-0000-000000000000'::uuid)
            = coalesce(v_old.collection_channel_id, '00000000-0000-0000-0000-000000000000'::uuid))
        or
        (v_old.route_kind = 'cod_carrier' and r.shipping_carrier_id = v_old.shipping_carrier_id)
      )
  ) then
    raise exception 'يوجد مسار نشط آخر بنفس معايير المطابقة بالفعل — لا يمكن تفعيل هذا المسار قبل تعطيل الآخر' using errcode = 'P0001';
  end if;

  update public.settlement_routes set status = 'active' where id = p_id;

  perform public.log_audit_event(
    'settlement_route.enable', 'settlement_route', p_id,
    jsonb_build_object('status', 'disabled'), jsonb_build_object('status', 'active')
  );
end;
$$;

comment on function public.enable_settlement_route(uuid) is
  'Phase 7 — reactivates a disabled route, guarded against recreating an ambiguous active-matching-key collision (item 36) with a clear error instead of a raw constraint violation. Requires settlements.manage_routes. SECURITY DEFINER.';

revoke execute on function public.enable_settlement_route(uuid) from public;
grant execute on function public.enable_settlement_route(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Narrow lookups.
-- ---------------------------------------------------------------------------
create or replace function public.settlement_route_lookups()
returns table (id uuid, code text, name_ar text, route_kind text, payment_method_id uuid, collection_channel_id uuid, shipping_carrier_id uuid)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select r.id, r.code, r.name_ar, r.route_kind, r.payment_method_id, r.collection_channel_id, r.shipping_carrier_id
  from public.settlement_routes r
  where r.status = 'active' and public.has_permission('settlements.create')
  order by r.name_ar;
$$;

comment on function public.settlement_route_lookups() is
  'Phase 7 — narrow ACTIVE-only route picker for /settlements/new (item 50 step 1), gated on settlements.create alone (never settlements.manage_routes).';

revoke execute on function public.settlement_route_lookups() from public;
grant execute on function public.settlement_route_lookups() to authenticated;

create or replace function public.settlement_route_filter_lookups()
returns table (id uuid, code text, name_ar text, route_kind text, status text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select r.id, r.code, r.name_ar, r.route_kind, r.status
  from public.settlement_routes r
  where public.has_permission('settlements.view')
  order by r.name_ar;
$$;

comment on function public.settlement_route_filter_lookups() is
  'Phase 7 — full (active + disabled) route list for the /settlements list-page filter dropdown (item 46), gated on settlements.view alone.';

revoke execute on function public.settlement_route_filter_lookups() from public;
grant execute on function public.settlement_route_filter_lookups() to authenticated;

create or replace function public.settlement_routes_admin_list()
returns table (
  id uuid, code text, name_ar text, name_en text, route_kind text,
  payment_method_id uuid, payment_method_name text,
  collection_channel_id uuid, collection_channel_name text,
  shipping_carrier_id uuid, shipping_carrier_name text,
  status text, description text, created_at timestamptz, updated_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select
    r.id, r.code, r.name_ar, r.name_en, r.route_kind,
    r.payment_method_id, pm.name_ar,
    r.collection_channel_id, cc.name_ar,
    r.shipping_carrier_id, sc.name_ar,
    r.status, r.description, r.created_at, r.updated_at
  from public.settlement_routes r
  left join public.payment_methods pm on pm.id = r.payment_method_id
  left join public.collection_channels cc on cc.id = r.collection_channel_id
  left join public.shipping_carriers sc on sc.id = r.shipping_carrier_id
  where public.has_permission('settlements.manage_routes')
  order by r.status, r.name_ar;
$$;

comment on function public.settlement_routes_admin_list() is
  'Phase 7 — full admin listing (active + disabled, historically visible per item 37) for /master-data/settlement-routes. Requires settlements.manage_routes.';

revoke execute on function public.settlement_routes_admin_list() from public;
grant execute on function public.settlement_routes_admin_list() to authenticated;

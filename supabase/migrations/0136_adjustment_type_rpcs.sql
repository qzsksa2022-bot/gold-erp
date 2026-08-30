-- ============================================================================
-- 0136: Phase 6 — Services / Adjustments Core (4/11): adjustment_types CRUD
-- RPCs + narrow lookups
-- ============================================================================
-- Migrations 0001-0135 are unmodified.

-- ---------------------------------------------------------------------------
-- create_adjustment_type() — §5/§6. code is set once, immutable forever.
-- ---------------------------------------------------------------------------
create or replace function public.create_adjustment_type(
  p_code text,
  p_name_ar text,
  p_name_en text default null,
  p_description text default null,
  p_sort_order integer default 0
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
begin
  if v_actor is null or not public.has_permission('adjustments.manage_types') then
    raise exception 'ليست لديك صلاحية إدارة أنواع التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  if v_code = '' then
    raise exception 'رمز نوع التعديل/الخدمة مطلوب' using errcode = 'P0001';
  end if;
  if v_name_ar = '' then
    raise exception 'الاسم العربي لنوع التعديل/الخدمة مطلوب' using errcode = 'P0001';
  end if;

  perform public.acquire_adjustments_lock_exclusive();

  if exists (select 1 from public.adjustment_types where code = v_code) then
    raise exception 'رمز "%" مستخدم مسبقًا لنوع تعديل/خدمة آخر', v_code using errcode = 'P0001';
  end if;

  insert into public.adjustment_types (code, name_ar, name_en, description, sort_order, created_by, updated_by)
  values (v_code, v_name_ar, nullif(btrim(coalesce(p_name_en, '')), ''), nullif(btrim(coalesce(p_description, '')), ''), coalesce(p_sort_order, 0), v_actor, v_actor)
  returning id into v_id;

  perform public.log_audit_event(
    'adjustment_type.create', 'adjustment_type', v_id, null,
    jsonb_build_object('code', v_code, 'name_ar', v_name_ar, 'name_en', p_name_en, 'sort_order', coalesce(p_sort_order, 0))
  );

  return v_id;
end;
$$;

comment on function public.create_adjustment_type(text, text, text, text, integer) is
  'Phase 6 (§5/§6) — creates a new active Service/Adjustment type. `code` is permanent from this point on (no RPC ever changes it). Requires adjustments.manage_types. SECURITY DEFINER.';

revoke execute on function public.create_adjustment_type(text, text, text, text, integer) from public;
grant execute on function public.create_adjustment_type(text, text, text, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- update_adjustment_type() — name/description/sort_order only. `code` and
-- `status` are never accepted here (status changes go through the
-- dedicated disable/enable RPCs below so each is its own distinct audit
-- action, per the governing spec's §34 action list).
-- ---------------------------------------------------------------------------
create or replace function public.update_adjustment_type(
  p_id uuid,
  p_name_ar text,
  p_name_en text default null,
  p_description text default null,
  p_sort_order integer default 0
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
begin
  if v_actor is null or not public.has_permission('adjustments.manage_types') then
    raise exception 'ليست لديك صلاحية إدارة أنواع التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  if v_name_ar = '' then
    raise exception 'الاسم العربي لنوع التعديل/الخدمة مطلوب' using errcode = 'P0001';
  end if;

  perform public.acquire_adjustments_lock_exclusive();

  select * into v_old from public.adjustment_types where id = p_id for update;
  if v_old.id is null then
    raise exception 'نوع التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;

  update public.adjustment_types
  set name_ar = v_name_ar,
      name_en = nullif(btrim(coalesce(p_name_en, '')), ''),
      description = nullif(btrim(coalesce(p_description, '')), ''),
      sort_order = coalesce(p_sort_order, 0),
      updated_by = v_actor
  where id = p_id;

  perform public.log_audit_event(
    'adjustment_type.update', 'adjustment_type', p_id,
    jsonb_build_object('name_ar', v_old.name_ar, 'name_en', v_old.name_en, 'sort_order', v_old.sort_order),
    jsonb_build_object('name_ar', v_name_ar, 'name_en', p_name_en, 'sort_order', coalesce(p_sort_order, 0))
  );
end;
$$;

comment on function public.update_adjustment_type(uuid, text, text, text, integer) is
  'Phase 6 — edits name_ar/name_en/description/sort_order of an existing type. `code` and `status` are never editable here. Requires adjustments.manage_types. SECURITY DEFINER.';

revoke execute on function public.update_adjustment_type(uuid, text, text, text, integer) from public;
grant execute on function public.update_adjustment_type(uuid, text, text, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- disable_adjustment_type() / enable_adjustment_type() — distinct audit
-- actions, no hard delete ever.
-- ---------------------------------------------------------------------------
create or replace function public.disable_adjustment_type(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old record;
begin
  if v_actor is null or not public.has_permission('adjustments.manage_types') then
    raise exception 'ليست لديك صلاحية إدارة أنواع التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  perform public.acquire_adjustments_lock_exclusive();

  select * into v_old from public.adjustment_types where id = p_id for update;
  if v_old.id is null then
    raise exception 'نوع التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if v_old.status = 'disabled' then
    raise exception 'نوع التعديل/الخدمة معطّل بالفعل' using errcode = 'P0001';
  end if;

  update public.adjustment_types set status = 'disabled', updated_by = v_actor where id = p_id;

  perform public.log_audit_event('adjustment_type.disable', 'adjustment_type', p_id, jsonb_build_object('status', 'active'), jsonb_build_object('status', 'disabled'));
end;
$$;

comment on function public.disable_adjustment_type(uuid) is
  'Phase 6 — disables a type: blocks it from NEW selection (0136''s active lookup, 0140''s approval validation) while every historical reference/snapshot stays fully visible. Requires adjustments.manage_types. SECURITY DEFINER.';

revoke execute on function public.disable_adjustment_type(uuid) from public;
grant execute on function public.disable_adjustment_type(uuid) to authenticated;

create or replace function public.enable_adjustment_type(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old record;
begin
  if v_actor is null or not public.has_permission('adjustments.manage_types') then
    raise exception 'ليست لديك صلاحية إدارة أنواع التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  perform public.acquire_adjustments_lock_exclusive();

  select * into v_old from public.adjustment_types where id = p_id for update;
  if v_old.id is null then
    raise exception 'نوع التعديل/الخدمة غير موجود' using errcode = 'P0001';
  end if;
  if v_old.status = 'active' then
    raise exception 'نوع التعديل/الخدمة نشط بالفعل' using errcode = 'P0001';
  end if;

  update public.adjustment_types set status = 'active', updated_by = v_actor where id = p_id;

  perform public.log_audit_event('adjustment_type.enable', 'adjustment_type', p_id, jsonb_build_object('status', 'disabled'), jsonb_build_object('status', 'active'));
end;
$$;

comment on function public.enable_adjustment_type(uuid) is
  'Phase 6 — re-enables a previously disabled type. Requires adjustments.manage_types. SECURITY DEFINER.';

revoke execute on function public.enable_adjustment_type(uuid) from public;
grant execute on function public.enable_adjustment_type(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Narrow lookups — each gated on the SPECIFIC permission that legitimately
-- needs it, never a broader Master-Data browse permission (mirrors 0120's
-- shipments_carrier_lookups()/shipments_operable_store_lookups() exactly).
-- ---------------------------------------------------------------------------
create or replace function public.adjustments_active_type_lookups()
returns table (id uuid, code text, name_ar text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('adjustments.create') then
    raise exception 'ليست لديك صلاحية إنشاء تعديل/خدمة' using errcode = 'P0001';
  end if;

  return query
  select t.id, t.code, t.name_ar
  from public.adjustment_types t
  where t.status = 'active'
  order by t.sort_order, t.name_ar;
end;
$$;

comment on function public.adjustments_active_type_lookups() is
  'Phase 6 — active types only, for the /adjustments/new type picker. Gated on adjustments.create alone (NOT adjustments.manage_types/adjustments.view) so a create-only actor can complete the flow.';

revoke execute on function public.adjustments_active_type_lookups() from public;
grant execute on function public.adjustments_active_type_lookups() to authenticated;

create or replace function public.adjustment_types_admin_list()
returns table (id uuid, code text, name_ar text, name_en text, description text, status text, sort_order integer, created_at timestamptz, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null or not public.has_permission('adjustments.manage_types') then
    raise exception 'ليست لديك صلاحية إدارة أنواع التعديلات/الخدمات' using errcode = 'P0001';
  end if;

  return query
  select t.id, t.code, t.name_ar, t.name_en, t.description, t.status, t.sort_order, t.created_at, t.updated_at
  from public.adjustment_types t
  order by t.sort_order, t.name_ar;
end;
$$;

comment on function public.adjustment_types_admin_list() is
  'Phase 6 — full catalog including disabled types, for the /master-data/adjustment-types admin screen. Requires adjustments.manage_types.';

revoke execute on function public.adjustment_types_admin_list() from public;
grant execute on function public.adjustment_types_admin_list() to authenticated;

-- ============================================================================
-- 0232: Phase 9 review fix — update_inventory_item(): ambiguous column
-- references against its own OUT parameters
-- ============================================================================
-- Migrations 0001-0231 are unmodified; additive fix on top of the committed
-- Phase 9 migrations, matching 0230/0231's approach.
--
-- Review finding: update_inventory_item() is declared
-- `returns table (id uuid, row_version bigint)`, which puts TWO implicit OUT
-- parameters named `id` and `row_version` in the function's own namespace.
-- Two statements in its body then referenced those same names UNQUALIFIED
-- against public.inventory_items:
--
--   1. select * into v_old from public.inventory_items where id = p_id
--      for update;
--          -> ERROR: column reference "id" is ambiguous
--
--   2. update public.inventory_items set ... row_version = row_version + 1
--          -> the right-hand `row_version` is ambiguous the same way (it is
--             only reached once (1) is fixed, so the first error masked it).
--
-- plpgsql resolves such a collision at RUN time, not at CREATE time, so
-- 0229 applied perfectly cleanly and the function only fails when actually
-- CALLED — every single invocation, unconditionally. `update_inventory_item`
-- was therefore 100% non-functional as shipped in 0229. The rest of 0229 is
-- unaffected: create_inventory_item()/record_inventory_stock_movement() and
-- the read RPCs already alias or table-qualify every column reference (e.g.
-- `from public.inventory_items i where i.id = ...`), which is exactly the
-- convention this fix restores here.
--
-- Fixed by table-aliasing both statements (`i` / `ii`) so each name resolves
-- unambiguously to the COLUMN.
--
-- SECOND finding, in the same function (hence the same CREATE OR REPLACE):
-- the optimistic-concurrency check was `v_old.row_version <>
-- p_expected_version`. Against a NULL p_expected_version that expression is
-- NULL, never TRUE — so a caller who simply omitted the version skipped the
-- check entirely and overwrote whatever another session had already
-- committed. A NULL version is now rejected outright, and the comparison
-- itself uses `is distinct from` so it is NULL-safe regardless. (The same
-- `<>` shape exists in older update RPCs — 0075/0086/... — but those
-- migrations are frozen and out of Phase 9's scope; only this new Phase 9
-- function is corrected here.)
--
-- No other behavioral change: the permission gate, validation order, audit
-- payload and return shape are byte-for-byte the same as 0229's.
-- ---------------------------------------------------------------------------
begin;

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

  -- 0232: aliased (`i`) — bare `id` here collided with this function's own
  -- `id` OUT parameter.
  select * into v_old from public.inventory_items i where i.id = p_id for update;

  if not found then
    raise exception 'الصنف غير موجود' using errcode = 'P0001';
  end if;

  -- 0232: a NULL expected version is rejected explicitly. `v_old.row_version
  -- <> NULL` evaluates to NULL, never TRUE, so a caller that simply omitted
  -- the version silently bypassed optimistic concurrency entirely and
  -- overwrote whatever was committed. `is distinct from` below then makes
  -- the real comparison NULL-safe regardless.
  if p_expected_version is null then
    raise exception 'رقم إصدار الصنف (row_version) مطلوب للتعديل' using errcode = 'P0001';
  end if;

  if v_old.row_version is distinct from p_expected_version then
    raise exception 'تم تعديل هذا الصنف من قِبل مستخدم آخر، الرجاء إعادة التحميل والمحاولة مرة أخرى' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.product_categories c where c.id = p_category_id and c.status = 'active') then
    raise exception 'التصنيف غير موجود أو غير نشط' using errcode = 'P0001';
  end if;

  if p_karat_id is not null and not exists (select 1 from public.karats k where k.id = p_karat_id and k.status = 'active') then
    raise exception 'العيار غير موجود أو غير نشط' using errcode = 'P0001';
  end if;

  -- 0232: aliased (`ii`) — the right-hand `row_version` in the increment
  -- collided with this function's own `row_version` OUT parameter.
  update public.inventory_items ii
  set name_ar = btrim(p_name_ar),
      category_id = p_category_id,
      karat_id = p_karat_id,
      unit = p_unit,
      active = coalesce(p_active, true),
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      row_version = ii.row_version + 1,
      updated_by = v_actor,
      updated_at = now()
  where ii.id = p_id;

  perform public.log_audit_event(
    'inventory.update_item', 'inventory_item', p_id,
    jsonb_build_object('name_ar', v_old.name_ar, 'category_id', v_old.category_id, 'karat_id', v_old.karat_id, 'unit', v_old.unit, 'active', v_old.active),
    jsonb_build_object('name_ar', p_name_ar, 'category_id', p_category_id, 'karat_id', p_karat_id, 'unit', p_unit, 'active', p_active)
  );

  return query select p_id, i.row_version from public.inventory_items i where i.id = p_id;
end;
$$;

comment on function public.update_inventory_item(uuid, bigint, text, uuid, uuid, text, boolean, text) is
  'Phase 9 (fixed 0232) -- edit an inventory item''s catalog fields (never sku). Gated on inventory.adjust, row_version-checked optimistic concurrency. 0232 table-aliases the lookup/update so `id`/`row_version` resolve to the COLUMNS rather than colliding with this function''s own RETURNS TABLE OUT parameters, which made every call fail at run time under 0229.';

commit;

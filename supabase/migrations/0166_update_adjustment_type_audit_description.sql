-- ============================================================================
-- 0166: Phase 6 Final Audit & Invariant Hotfix 6.1.2 (4/4): update_adjustment_
-- type() audit completeness — description
-- ============================================================================
-- Migrations 0001-0165 are unmodified (Hotfix 6.1.2 freeze rule). Same
-- 5-argument signature and return shape as 0136 — CREATE OR REPLACE in
-- place, no drop needed. IDENTICAL runtime behavior to 0136: same
-- validation, same lock, same UPDATE. The ONLY change is the payload of the
-- single log_audit_event('adjustment_type.update', ...) call.
--
-- Hotfix 6.1.2 item 5 — update_adjustment_type() (0136) already changes
-- description (it is part of the UPDATE ... set list) but its audit entry
-- only ever captured name_ar/name_en/sort_order old/new, silently omitting
-- description from the historical record. This migration completes the
-- audit payload so adjustment_type.update documents name_ar, name_en,
-- description, sort_order — old AND new — for all four. No new audit action
-- is introduced; this is still a single adjustment_type.update entry.
--
-- The normalized description value written to the row (nullif(btrim(
-- coalesce(p_description, '')), '')) is captured once into v_description and
-- reused identically in both the UPDATE and the audit new_values, avoiding
-- any risk of the two drifting apart.
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
  v_description text := nullif(btrim(coalesce(p_description, '')), '');
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
      description = v_description,
      sort_order = coalesce(p_sort_order, 0),
      updated_by = v_actor
  where id = p_id;

  perform public.log_audit_event(
    'adjustment_type.update', 'adjustment_type', p_id,
    jsonb_build_object('name_ar', v_old.name_ar, 'name_en', v_old.name_en, 'description', v_old.description, 'sort_order', v_old.sort_order),
    jsonb_build_object('name_ar', v_name_ar, 'name_en', p_name_en, 'description', v_description, 'sort_order', coalesce(p_sort_order, 0))
  );
end;
$$;

comment on function public.update_adjustment_type(uuid, text, text, text, integer) is
  'Phase 6 + Hotfix 6.1.2 item 5 — edits name_ar/name_en/description/sort_order of an existing type. `code` and `status` are never editable here. Requires adjustments.manage_types. adjustment_type.update audit entry now documents name_ar/name_en/description/sort_order old and new (description was previously omitted despite being editable). SECURITY DEFINER.';

revoke execute on function public.update_adjustment_type(uuid, text, text, text, integer) from public;
grant execute on function public.update_adjustment_type(uuid, text, text, text, integer) to authenticated;

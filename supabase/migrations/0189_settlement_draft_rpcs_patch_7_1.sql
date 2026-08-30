-- ============================================================================
-- 0189: Phase 7 — Integrity Patch 7.1 (6/N): create/update draft settlement
-- batch — business-date validation (§10), explicit keep/set/clear
-- semantics + full audit payload (§27).
-- ============================================================================
-- Migrations 0001-0188 are FROZEN.
--
-- §10 — 0177 never validated settlement_date at all; a draft (and, until
-- 0185, Finalize) could carry a future settlement_date. Both RPCs below now
-- reject settlement_date > business_today() (never current_date — always
-- the canonical Riyadh business_today()).
--
-- §27 — 0177's update_draft_settlement_batch() used
-- `case when p_X is null then keep else nullif(btrim(p_X), '') end` for
-- provider_statement_reference/notes — which DOES support clearing (an
-- explicit '' argument produces NULL) at the RPC layer, but the Server
-- Action (src/features/settlements/actions.ts, fixed alongside this
-- migration) converted a blank form field to NULL before calling the RPC,
-- meaning "leave untouched" and "clear" were indistinguishable from the
-- UI's perspective — a user could never actually clear a filled-in field.
-- Fix: two new trailing boolean "provided" flags make the three states
-- explicit at the RPC boundary itself (keep / set-to-value / clear-to-null)
-- so no caller, present or future, can accidentally conflate them again.
-- Also expands the settlement.update audit payload to include provider_
-- statement_reference/notes/row_version old->new (previously only route_id
-- and settlement_date were recorded).
-- ============================================================================
create or replace function public.create_draft_settlement_batch(
  p_settlement_route_id uuid,
  p_settlement_date date,
  p_provider_statement_reference text default null,
  p_notes text default null
)
returns table (id uuid, settlement_number text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_route record;
  v_id uuid;
  v_number text;
begin
  if v_actor is null or not public.has_permission('settlements.create') then
    raise exception 'ليست لديك صلاحية إنشاء تسوية' using errcode = 'P0001';
  end if;

  if p_settlement_route_id is null then
    raise exception 'مسار التسوية مطلوب' using errcode = 'P0001';
  end if;
  if p_settlement_date is null then
    raise exception 'تاريخ التسوية مطلوب' using errcode = 'P0001';
  end if;

  -- §10 — settlement_date can never be in the future.
  if p_settlement_date > public.business_today() then
    raise exception 'تاريخ التسوية (%) لا يمكن أن يكون في المستقبل', p_settlement_date using errcode = 'P0001';
  end if;

  select * into v_route from public.settlement_routes r where r.id = p_settlement_route_id;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;
  if v_route.status <> 'active' then
    raise exception 'لا يمكن استخدام مسار معطَّل لدفعة تسوية' using errcode = 'P0001';
  end if;

  v_number := public.generate_settlement_number();

  insert into public.settlement_batches (
    settlement_number, settlement_route_id, settlement_date,
    provider_statement_reference, notes, created_by
  )
  values (
    v_number, p_settlement_route_id, p_settlement_date,
    nullif(btrim(coalesce(p_provider_statement_reference, '')), ''),
    nullif(btrim(coalesce(p_notes, '')), ''),
    v_actor
  )
  returning settlement_batches.id into v_id;

  perform public.log_audit_event(
    'settlement.create', 'settlement_batch', v_id, null,
    jsonb_build_object(
      'settlement_number', v_number, 'settlement_route_id', p_settlement_route_id,
      'settlement_date', p_settlement_date
    )
  );

  id := v_id;
  settlement_number := v_number;
  return next;
end;
$$;

comment on function public.create_draft_settlement_batch(uuid, date, text, text) is
  'Phase 7.1 patch (§10) — same signature as 0177. settlement_date now rejected if > business_today(). Requires settlements.create. SECURITY DEFINER.';

revoke execute on function public.create_draft_settlement_batch(uuid, date, text, text) from public;
grant execute on function public.create_draft_settlement_batch(uuid, date, text, text) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.update_draft_settlement_batch(
  p_id uuid,
  p_expected_version bigint,
  p_settlement_route_id uuid default null,
  p_settlement_date date default null,
  p_provider_statement_reference text default null,
  p_notes text default null,
  p_provider_statement_reference_provided boolean default false,
  p_notes_provided boolean default false
)
returns table (id uuid, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_route record;
  v_new_route uuid;
  v_new_date date;
  v_new_reference text;
  v_new_notes text;
begin
  if not public.has_permission('settlements.create') then
    raise exception 'ليست لديك صلاحية إنشاء/تعديل تسوية' using errcode = 'P0001';
  end if;

  select * into v_row from public.settlement_batches b where b.id = p_id for update;
  if v_row.id is null then
    raise exception 'دفعة التسوية غير موجودة' using errcode = 'P0001';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'لا يمكن تعديل دفعة تسوية بعد اعتمادها (finalize) — هي مقفلة الآن' using errcode = 'P0001';
  end if;
  if p_expected_version is null or v_row.row_version <> p_expected_version then
    raise exception 'تم تعديل دفعة التسوية هذه من قِبل مستخدم آخر — يرجى إعادة التحميل والمحاولة مجددًا' using errcode = 'P0001';
  end if;

  v_new_route := coalesce(p_settlement_route_id, v_row.settlement_route_id);
  v_new_date := coalesce(p_settlement_date, v_row.settlement_date);

  -- §10 — settlement_date can never be in the future.
  if v_new_date > public.business_today() then
    raise exception 'تاريخ التسوية (%) لا يمكن أن يكون في المستقبل', v_new_date using errcode = 'P0001';
  end if;

  select * into v_route from public.settlement_routes r where r.id = v_new_route;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;
  if v_route.status <> 'active' then
    raise exception 'لا يمكن استخدام مسار معطَّل لدفعة تسوية' using errcode = 'P0001';
  end if;

  -- §27 — explicit keep/set/clear: the "_provided" flag is the ONLY signal
  -- that this field is being touched at all; an unset flag ALWAYS keeps
  -- the existing value verbatim, regardless of what p_X itself contains.
  v_new_reference := case
    when p_provider_statement_reference_provided then nullif(btrim(coalesce(p_provider_statement_reference, '')), '')
    else v_row.provider_statement_reference
  end;
  v_new_notes := case
    when p_notes_provided then nullif(btrim(coalesce(p_notes, '')), '')
    else v_row.notes
  end;

  update public.settlement_batches b
  set
    settlement_route_id = v_new_route,
    settlement_date = v_new_date,
    provider_statement_reference = v_new_reference,
    notes = v_new_notes,
    row_version = b.row_version + 1
  where b.id = p_id;

  perform public.log_audit_event(
    'settlement.update', 'settlement_batch', p_id,
    jsonb_build_object(
      'settlement_route_id', v_row.settlement_route_id, 'settlement_date', v_row.settlement_date,
      'provider_statement_reference', v_row.provider_statement_reference, 'notes', v_row.notes,
      'row_version', v_row.row_version
    ),
    jsonb_build_object(
      'settlement_route_id', v_new_route, 'settlement_date', v_new_date,
      'provider_statement_reference', v_new_reference, 'notes', v_new_notes,
      'row_version', v_row.row_version + 1
    )
  );

  return query select p_id, v_row.row_version + 1;
end;
$$;

comment on function public.update_draft_settlement_batch(uuid, bigint, uuid, date, text, text, boolean, boolean) is
  'Phase 7.1 patch (§10/§27) — settlement_date rejected if > business_today(). provider_statement_reference/notes now use explicit keep/set/clear semantics via p_provider_statement_reference_provided/p_notes_provided (an unset flag ALWAYS keeps the existing value; a set flag applies p_X verbatim, including clearing to NULL when p_X is null/blank) — replaces 0177''s ambiguous NULL-means-keep contract. settlement.update audit payload now includes provider_statement_reference/notes/row_version old->new (0177 only recorded route/date). Requires settlements.create. SECURITY DEFINER.';

revoke execute on function public.update_draft_settlement_batch(uuid, bigint, uuid, date, text, text, boolean, boolean) from public;
grant execute on function public.update_draft_settlement_batch(uuid, bigint, uuid, date, text, text, boolean, boolean) to authenticated;

-- 0177's old 6-argument overload is no longer callable from application
-- code once actions.ts is updated (this migration), but CREATE OR REPLACE
-- above only replaces the exact-matching signature — since 0177 declared
-- update_draft_settlement_batch with exactly 6 parameters and this
-- migration declares 8 (2 new trailing), Postgres treats this as a NEW
-- overload alongside the old one rather than replacing it (differing
-- parameter counts). Drop the old 6-arg overload explicitly so exactly one
-- signature exists — an accidental call against the old contract (NULL
-- silently meaning "keep", forever unable to clear) must not remain
-- reachable.
drop function if exists public.update_draft_settlement_batch(uuid, bigint, uuid, date, text, text);

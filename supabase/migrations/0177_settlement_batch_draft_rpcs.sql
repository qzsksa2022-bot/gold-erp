-- ============================================================================
-- 0177: Phase 7 — Settlements Core (11/N): settlement_batches draft
-- lifecycle RPCs (create_draft_settlement_batch / update_draft_settlement_
-- batch)
-- ============================================================================
-- Migrations 0001-0176 are unmodified.
--
-- item 18 — a draft settlement batch reserves NOTHING financially: no
-- settlement_source_claims row is created, no settlement_batch_lines row is
-- created, none of the snapshot/figure columns on settlement_batches are
-- populated (they stay NULL, enforced by settlement_batches_calc_version_
-- consistent and the snapshot columns simply never being written here).
-- Those all happen exclusively inside finalize_settlement_batch() (0178).
--
-- Both RPCs require settlements.create (item 41's role matrix — creating OR
-- editing a still-draft batch is the same authority level; only Finalization
-- itself later requires nothing extra beyond settlements.create either,
-- since Finalization is not a separate elevated action per the spec).
--
-- A route must be 'active' (item 37) to be selected for a NEW/updated draft
-- — a disabled route stays visible on already-finalized batches (its
-- snapshot is frozen forever) but can never be chosen for a batch that has
-- not yet reserved anything.
-- ---------------------------------------------------------------------------
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
  v_route record;
  v_id uuid;
  v_number text;
begin
  if not public.has_permission('settlements.create') then
    raise exception 'ليست لديك صلاحية إنشاء تسوية' using errcode = 'P0001';
  end if;

  if p_settlement_route_id is null or p_settlement_date is null then
    raise exception 'مسار التسوية وتاريخ التسوية مطلوبان' using errcode = 'P0001';
  end if;

  select * into v_route from public.settlement_routes r where r.id = p_settlement_route_id;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;
  if v_route.status <> 'active' then
    raise exception 'لا يمكن إنشاء تسوية جديدة على مسار معطَّل' using errcode = 'P0001';
  end if;

  v_number := public.generate_settlement_number();

  insert into public.settlement_batches (
    settlement_number, settlement_route_id, settlement_date, status,
    provider_statement_reference, notes, created_by, updated_by
  )
  values (
    v_number, p_settlement_route_id, p_settlement_date, 'draft',
    nullif(btrim(p_provider_statement_reference), ''), nullif(btrim(p_notes), ''), auth.uid(), auth.uid()
  )
  returning settlement_batches.id into v_id;

  perform public.log_audit_event(
    'settlement.create', 'settlement_batch', v_id, null,
    jsonb_build_object(
      'settlement_number', v_number, 'settlement_route_id', p_settlement_route_id,
      'settlement_date', p_settlement_date
    )
  );

  return query select v_id, v_number;
end;
$$;

comment on function public.create_draft_settlement_batch(uuid, date, text, text) is
  'Phase 7 (item 15/18) — creates a draft settlement batch header. Reserves NOTHING financially (no claims, no lines, no snapshot columns populated) — those happen only at finalize_settlement_batch() (0178). Requires settlements.create. SECURITY DEFINER.';

revoke execute on function public.create_draft_settlement_batch(uuid, date, text, text) from public;
grant execute on function public.create_draft_settlement_batch(uuid, date, text, text) to authenticated;

-- ---------------------------------------------------------------------------
create or replace function public.update_draft_settlement_batch(
  p_id uuid,
  p_expected_version bigint,
  p_settlement_route_id uuid default null,
  p_settlement_date date default null,
  p_provider_statement_reference text default null,
  p_notes text default null
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

  select * into v_route from public.settlement_routes r where r.id = v_new_route;
  if v_route.id is null then
    raise exception 'مسار التسوية غير موجود' using errcode = 'P0001';
  end if;
  if v_route.status <> 'active' then
    raise exception 'لا يمكن استخدام مسار معطَّل لدفعة تسوية' using errcode = 'P0001';
  end if;

  update public.settlement_batches b
  set
    settlement_route_id = v_new_route,
    settlement_date = v_new_date,
    provider_statement_reference = case
      when p_provider_statement_reference is null then b.provider_statement_reference
      else nullif(btrim(p_provider_statement_reference), '')
    end,
    notes = case
      when p_notes is null then b.notes
      else nullif(btrim(p_notes), '')
    end,
    row_version = b.row_version + 1
  where b.id = p_id;

  perform public.log_audit_event(
    'settlement.update', 'settlement_batch', p_id,
    jsonb_build_object('settlement_route_id', v_row.settlement_route_id, 'settlement_date', v_row.settlement_date),
    jsonb_build_object('settlement_route_id', v_new_route, 'settlement_date', v_new_date)
  );

  return query select p_id, v_row.row_version + 1;
end;
$$;

comment on function public.update_draft_settlement_batch(uuid, bigint, uuid, date, text, text) is
  'Phase 7 (item 18) — edits a still-draft settlement batch header only (route/date/reference/notes). Rejected once the batch has left draft (frozen by settlement_batches_reject_financial_mutation, 0172, at the DB level regardless). Optimistic concurrency via row_version/p_expected_version. Requires settlements.create. SECURITY DEFINER.';

revoke execute on function public.update_draft_settlement_batch(uuid, bigint, uuid, date, text, text) from public;
grant execute on function public.update_draft_settlement_batch(uuid, bigint, uuid, date, text, text) to authenticated;

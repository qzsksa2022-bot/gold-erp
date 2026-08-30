-- ============================================================================
-- 0042: manufacturing_fee_versions — Phase 2, module 3/6
-- ============================================================================
-- Manufacturing fee is versioned by karat, never overwritten in place (spec
-- §4: "لا نكتب فوق القيمة القديمة عند تغيير المصنعية"). Changing a rate
-- always means: end the currently-open version, insert a new one — the old
-- row's fee_per_gram is permanent history. Non-overlap for the SAME karat
-- is enforced at the database level via a GIST exclusion constraint, not
-- just application discipline, so even a direct SQL/PostgREST write cannot
-- create two simultaneously-effective rates for one karat.
--
-- btree_gist is required for the exclusion constraint below to support an
-- equality comparison (karat_id =) alongside the range overlap (&&) in the
-- same EXCLUDE clause.
create extension if not exists btree_gist;

create table public.manufacturing_fee_versions (
  id uuid primary key default gen_random_uuid(),
  karat_id uuid not null references public.karats (id) on delete restrict,
  fee_per_gram numeric(12, 4) not null check (fee_per_gram >= 0),
  effective_from date not null,
  -- NULL = open-ended (this is the currently active/scheduled version for
  -- its karat). Set only by create_manufacturing_fee_version() below when a
  -- newer version supersedes it — never edited directly by the client.
  effective_to date,
  -- 'active'   = the current open-ended version (effective_to IS NULL) —
  --              at most one per karat (see the partial unique index
  --              below). This is what "the currently configured rate" means.
  -- 'ended'    = superseded by a later version (effective_to was stamped
  --              when the newer version was created). STILL real, permanent
  --              history — date-range resolution and the overlap guard
  --              both treat 'active' and 'ended' identically (both filter
  --              on `status <> 'cancelled'`), because an 'ended' row is
  --              exactly as valid for a date inside its own range as an
  --              'active' one is for a date inside its.
  -- 'cancelled'= a FUTURE-dated version withdrawn before it ever took
  --              effect (see cancel_manufacturing_fee_version() below) —
  --              the only form of "undo" allowed, and only pre-effective.
  --              The ONLY status excluded from date-range resolution and
  --              the overlap guard — it never represents real history.
  status text not null default 'active' check (status in ('active', 'ended', 'cancelled')),
  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);

comment on table public.manufacturing_fee_versions is
  'Versioned manufacturing fee per gram, by karat. Append-only in spirit: rows are never edited after creation except to stamp effective_to/status=ended (superseded) or status=cancelled (a future, not-yet-effective row withdrawn). No updated_at/updated_by — an "edit" is always a new row, never a mutation of an already-effective rate.';

-- At most one OPEN (effective_to IS NULL, status=active) version per karat
-- at any time — this is "the current/next scheduled rate" for that karat.
create unique index manufacturing_fee_versions_open_idx
  on public.manufacturing_fee_versions (karat_id)
  where effective_to is null and status = 'active';

comment on index public.manufacturing_fee_versions_open_idx is
  'At most one open-ended active version per karat — the row create_manufacturing_fee_version() ends before inserting a new one.';

-- No two non-cancelled periods for the same karat may overlap in time,
-- enforced at the database level (not just by the app''s "end-then-insert"
-- flow). daterange(..., '[]') is inclusive on both ends, matching how the
-- business describes periods ("من 1 يناير إلى 30 يونيو"); Postgres
-- canonicalizes a discrete daterange internally, so this behaves correctly
-- even with a NULL (unbounded) upper bound. The predicate is `status <>
-- 'cancelled'` (NOT `status = 'active'`) — a superseded ('ended') row is
-- still real, permanent history occupying its own date range forever; only
-- a 'cancelled' (withdrawn-before-effective) row must be excluded from the
-- overlap check, otherwise it would permanently block reusing that date
-- range even though it never actually took effect.
alter table public.manufacturing_fee_versions
  add constraint manufacturing_fee_versions_no_overlap
  exclude using gist (
    karat_id with =,
    daterange(effective_from, effective_to, '[]') with &&
  )
  where (status <> 'cancelled');

create index manufacturing_fee_versions_karat_idx on public.manufacturing_fee_versions (karat_id);
create index manufacturing_fee_versions_effective_from_idx on public.manufacturing_fee_versions (effective_from);

alter table public.manufacturing_fee_versions enable row level security;

create policy manufacturing_fee_versions_select on public.manufacturing_fee_versions
  for select to authenticated
  using (public.has_permission('manufacturing_fees.view'));

-- INSERT/UPDATE are exposed to `authenticated` only through the two
-- SECURITY INVOKER functions below (they still resolve permission via
-- has_permission() internally, exactly like a raw INSERT/UPDATE under RLS
-- would) — a direct INSERT/UPDATE from a client is ALSO allowed under the
-- same permission for defense in depth (matches every other master-data
-- table in this phase), but the app never uses that path because it cannot
-- express "atomically end the old version and insert the new one" as two
-- separate client-side calls without a race window.
create policy manufacturing_fee_versions_insert on public.manufacturing_fee_versions
  for insert to authenticated
  with check (public.has_permission('manufacturing_fees.manage'));

create policy manufacturing_fee_versions_update on public.manufacturing_fee_versions
  for update to authenticated
  using (public.has_permission('manufacturing_fees.manage'))
  with check (public.has_permission('manufacturing_fees.manage'));

-- No DELETE policy: a version, once created, is permanent history (or
-- 'cancelled' in place if it never took effect) — never removed.

create trigger manufacturing_fee_versions_audit_trigger
  after insert or update or delete on public.manufacturing_fee_versions
  for each row execute function public.audit_table_changes('manufacturing_fee_version', 'id');

-- ---------------------------------------------------------------------------
-- Atomic "create a new version" — ends the currently open version (if the
-- new effective_from is after it) and inserts the new one in the SAME
-- statement/transaction, so no concurrent request can observe (or create)
-- an overlapping pair. SECURITY INVOKER: permission is re-checked here via
-- has_permission() AND independently enforced by the RLS policies above —
-- two layers, same as everywhere else in this project.
-- ---------------------------------------------------------------------------
create or replace function public.create_manufacturing_fee_version(
  p_karat_id uuid,
  p_fee_per_gram numeric,
  p_effective_from date,
  p_notes text default null
)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
  v_open record;
begin
  if not public.has_permission('manufacturing_fees.manage') then
    raise exception 'ليست لديك صلاحية إدارة المصنعية' using errcode = 'P0001';
  end if;

  if p_karat_id is null or p_fee_per_gram is null or p_effective_from is null then
    raise exception 'العيار، قيمة المصنعية، وتاريخ السريان كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_fee_per_gram < 0 then
    raise exception 'قيمة المصنعية لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  select * into v_open
  from public.manufacturing_fee_versions
  where karat_id = p_karat_id and effective_to is null and status = 'active'
  for update;

  if found then
    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار مصنعية سارٍ/مجدوَل لهذا العيار بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق. لإلغاء إصدار مستقبلي لم يسرِ بعد، استخدم cancel_manufacturing_fee_version أولًا.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.manufacturing_fee_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.manufacturing_fee_versions (karat_id, fee_per_gram, effective_from, effective_to, status, notes, created_by)
  values (p_karat_id, p_fee_per_gram, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_manufacturing_fee_version(uuid, numeric, date, text) is
  'Atomically ends the karat''s currently open manufacturing fee version (if the new effective_from is after it) and inserts the new one — the only sanctioned way to change a manufacturing fee. Never mutates a rate that already took effect; rejects a new effective_from at or before the currently open version''s own effective_from (use cancel_manufacturing_fee_version() first for a future, not-yet-effective correction).';

-- ---------------------------------------------------------------------------
-- Withdraw a FUTURE version that has not taken effect yet — the only
-- allowed "undo". Never permitted once effective_from <= current_date,
-- i.e. once a rate could already have been used ("لا تعديل رجعي صامت على
-- Rate سبق استخدامه").
-- ---------------------------------------------------------------------------
create or replace function public.cancel_manufacturing_fee_version(p_version_id uuid)
returns void
language plpgsql
as $$
declare
  v_row record;
begin
  if not public.has_permission('manufacturing_fees.manage') then
    raise exception 'ليست لديك صلاحية إدارة المصنعية' using errcode = 'P0001';
  end if;

  select * into v_row from public.manufacturing_fee_versions where id = p_version_id for update;

  if not found then
    raise exception 'إصدار المصنعية غير موجود' using errcode = 'P0001';
  end if;

  if v_row.status <> 'active' then
    raise exception 'هذا الإصدار ليس نشِطًا أصلًا (تم إلغاؤه أو استبداله سابقًا)' using errcode = 'P0001';
  end if;

  if v_row.effective_from <= current_date then
    raise exception 'لا يمكن إلغاء إصدار مصنعية سارٍ بالفعل أو مضى تاريخ سريانه — يُسمح فقط بإلغاء إصدار مستقبلي لم يسرِ بعد' using errcode = 'P0001';
  end if;

  update public.manufacturing_fee_versions set status = 'cancelled' where id = p_version_id;
end;
$$;

comment on function public.cancel_manufacturing_fee_version(uuid) is
  'Withdraws a manufacturing fee version that has not taken effect yet (effective_from is strictly in the future). Rejects any version whose effective_from has already arrived — a rate that could already have been used is permanent history, never silently undone.';

-- ---------------------------------------------------------------------------
-- Query surface for later phases (spec §16): "manufacturing fee for
-- (karat, date)". Raises instead of returning NULL/0, matching
-- gold_price_for_karat_on_date.
-- ---------------------------------------------------------------------------
create or replace function public.manufacturing_fee_for_karat_on_date(p_karat_id uuid, p_date date default current_date)
returns numeric
language plpgsql
stable
as $$
declare
  v_fee numeric;
begin
  -- status <> 'cancelled' (not `= 'active'`): a superseded ('ended') row is
  -- still valid history for whatever date range it covered — only a
  -- cancelled (never-took-effect) row must never be resolved to.
  select fee_per_gram into v_fee
  from public.manufacturing_fee_versions
  where karat_id = p_karat_id
    and status <> 'cancelled'
    and effective_from <= p_date
    and (effective_to is null or effective_to >= p_date)
  order by effective_from desc
  limit 1;

  if v_fee is null then
    raise exception 'لا توجد مصنعية معتمدة لهذا العيار بتاريخ %', p_date using errcode = 'P0001';
  end if;

  return v_fee;
end;
$$;

comment on function public.manufacturing_fee_for_karat_on_date(uuid, date) is
  'Manufacturing fee per gram applicable to a karat on a date, resolved from manufacturing_fee_versions. Raises P0001 (not NULL/0) if no active version covers that date.';

-- ============================================================================
-- 0045: payment_method_fee_versions — Phase 2, module 5/6 (part 2: fees)
-- ============================================================================
-- Same versioning pattern as manufacturing_fee_versions (0042): a fee
-- change never overwrites history, it ends the currently open version and
-- inserts a new one, enforced atomically by a DB function plus a GIST
-- exclusion constraint so no two ACTIVE periods for the same payment method
-- can overlap even via a direct write.
--
-- percentage_fee AND fixed_fee are both present on every row (not a
-- polymorphic "type + single value" design) so a single version can express
-- all four shapes the spec requires without a schema change:
--   percentage only          -> fixed_fee = 0
--   fixed only                -> percentage_fee = 0
--   percentage + fixed         -> both > 0 (e.g. a future COD: % + flat
--                                 transfer fee, spec §7)
--   no fee                    -> both = 0 (Cash, Bank Transfer today)
-- COD intentionally gets NO seeded version at all (see supabase/seed.sql) —
-- payment_fee_for_method_on_date() below then raises a clear error instead
-- of a fabricated rate, exactly matching spec §7: "لا تخترع نسبة؛ اتركها
-- قابلة للإعداد بدون قيمة وهمية".
create table public.payment_method_fee_versions (
  id uuid primary key default gen_random_uuid(),
  payment_method_id uuid not null references public.payment_methods (id) on delete restrict,
  percentage_fee numeric(6, 3) not null default 0 check (percentage_fee >= 0),
  fixed_fee numeric(12, 4) not null default 0 check (fixed_fee >= 0),
  effective_from date not null,
  effective_to date,
  status text not null default 'active' check (status in ('active', 'ended', 'cancelled')),
  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);

comment on table public.payment_method_fee_versions is
  'Versioned percentage/fixed fee per payment method, mirroring manufacturing_fee_versions (0042) exactly. Both fee columns are always present (not a polymorphic type column) so percentage-only, fixed-only, percentage+fixed, and zero-fee are all just different combinations of two NUMERIC columns — no schema change needed for a future shape like COD''s eventual %+flat structure.';

create unique index payment_method_fee_versions_open_idx
  on public.payment_method_fee_versions (payment_method_id)
  where effective_to is null and status = 'active';

-- status <> 'cancelled' (not `= 'active'`) — see the identical comment in
-- 0042's manufacturing_fee_versions_no_overlap: a superseded ('ended') row
-- is still real, permanent history and must keep blocking its own date
-- range from being reused by mistake; only a cancelled (never-effective)
-- row is excluded.
alter table public.payment_method_fee_versions
  add constraint payment_method_fee_versions_no_overlap
  exclude using gist (
    payment_method_id with =,
    daterange(effective_from, effective_to, '[]') with &&
  )
  where (status <> 'cancelled');

create index payment_method_fee_versions_method_idx on public.payment_method_fee_versions (payment_method_id);
create index payment_method_fee_versions_effective_from_idx on public.payment_method_fee_versions (effective_from);

alter table public.payment_method_fee_versions enable row level security;

create policy payment_method_fee_versions_select on public.payment_method_fee_versions
  for select to authenticated
  using (public.has_permission('payment_methods.view'));

create policy payment_method_fee_versions_insert on public.payment_method_fee_versions
  for insert to authenticated
  with check (public.has_permission('payment_methods.manage'));

create policy payment_method_fee_versions_update on public.payment_method_fee_versions
  for update to authenticated
  using (public.has_permission('payment_methods.manage'))
  with check (public.has_permission('payment_methods.manage'));

-- No DELETE policy — a version is permanent history once created.

create trigger payment_method_fee_versions_audit_trigger
  after insert or update or delete on public.payment_method_fee_versions
  for each row execute function public.audit_table_changes('payment_method_fee_version', 'id');

-- ---------------------------------------------------------------------------
-- Atomic "create a new fee version" — identical shape to
-- create_manufacturing_fee_version() (0042), see that migration's comments
-- for the full rationale.
-- ---------------------------------------------------------------------------
create or replace function public.create_payment_method_fee_version(
  p_payment_method_id uuid,
  p_percentage_fee numeric,
  p_fixed_fee numeric,
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
  if not public.has_permission('payment_methods.manage') then
    raise exception 'ليست لديك صلاحية إدارة طرق الدفع' using errcode = 'P0001';
  end if;

  if p_payment_method_id is null or p_effective_from is null then
    raise exception 'طريقة الدفع وتاريخ السريان مطلوبان' using errcode = 'P0001';
  end if;

  p_percentage_fee := coalesce(p_percentage_fee, 0);
  p_fixed_fee := coalesce(p_fixed_fee, 0);

  if p_percentage_fee < 0 or p_fixed_fee < 0 then
    raise exception 'قيم العمولة لا يمكن أن تكون سالبة' using errcode = 'P0001';
  end if;

  select * into v_open
  from public.payment_method_fee_versions
  where payment_method_id = p_payment_method_id and effective_to is null and status = 'active'
  for update;

  if found then
    if p_effective_from <= v_open.effective_from then
      raise exception 'يوجد بالفعل إصدار عمولة سارٍ/مجدوَل لهذه الطريقة بتاريخ سريان % — لا يمكن إضافة إصدار بتاريخ سابق له أو مطابق. لإلغاء إصدار مستقبلي لم يسرِ بعد، استخدم cancel_payment_method_fee_version أولًا.', v_open.effective_from
        using errcode = 'P0001';
    end if;

    update public.payment_method_fee_versions
    set effective_to = p_effective_from - 1, status = 'ended'
    where id = v_open.id;
  end if;

  insert into public.payment_method_fee_versions
    (payment_method_id, percentage_fee, fixed_fee, effective_from, effective_to, status, notes, created_by)
  values
    (p_payment_method_id, p_percentage_fee, p_fixed_fee, p_effective_from, null, 'active', p_notes, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.create_payment_method_fee_version(uuid, numeric, numeric, date, text) is
  'Atomically ends the payment method''s currently open fee version (if the new effective_from is after it) and inserts the new one. Mirrors create_manufacturing_fee_version() (0042) exactly.';

create or replace function public.cancel_payment_method_fee_version(p_version_id uuid)
returns void
language plpgsql
as $$
declare
  v_row record;
begin
  if not public.has_permission('payment_methods.manage') then
    raise exception 'ليست لديك صلاحية إدارة طرق الدفع' using errcode = 'P0001';
  end if;

  select * into v_row from public.payment_method_fee_versions where id = p_version_id for update;

  if not found then
    raise exception 'إصدار العمولة غير موجود' using errcode = 'P0001';
  end if;

  if v_row.status <> 'active' then
    raise exception 'هذا الإصدار ليس نشِطًا أصلًا (تم إلغاؤه أو استبداله سابقًا)' using errcode = 'P0001';
  end if;

  if v_row.effective_from <= current_date then
    raise exception 'لا يمكن إلغاء إصدار عمولة سارٍ بالفعل أو مضى تاريخ سريانه — يُسمح فقط بإلغاء إصدار مستقبلي لم يسرِ بعد' using errcode = 'P0001';
  end if;

  update public.payment_method_fee_versions set status = 'cancelled' where id = p_version_id;
end;
$$;

comment on function public.cancel_payment_method_fee_version(uuid) is
  'Withdraws a payment fee version that has not taken effect yet. Mirrors cancel_manufacturing_fee_version() (0042) exactly.';

-- ---------------------------------------------------------------------------
-- Query surface for later phases (spec §16): "payment fee configuration for
-- (payment_method, date)". Raises instead of returning NULL/0 — this is
-- what makes an unconfigured COD fee (deliberately unseeded) a loud error
-- rather than a silent free transaction once Sales starts consuming it.
-- ---------------------------------------------------------------------------
create or replace function public.payment_fee_for_method_on_date(p_payment_method_id uuid, p_date date default current_date)
returns table (fee_version_id uuid, percentage_fee numeric, fixed_fee numeric)
language plpgsql
stable
as $$
declare
  v_row record;
begin
  -- status <> 'cancelled': a superseded ('ended') row is still valid
  -- history for the date range it covered — see manufacturing_fee_for_karat_on_date (0042) for the identical reasoning.
  select v.id, v.percentage_fee, v.fixed_fee
  into v_row
  from public.payment_method_fee_versions v
  where v.payment_method_id = p_payment_method_id
    and v.status <> 'cancelled'
    and v.effective_from <= p_date
    and (v.effective_to is null or v.effective_to >= p_date)
  order by v.effective_from desc
  limit 1;

  if v_row.id is null then
    raise exception 'لا توجد نسبة/رسوم معتمدة لطريقة الدفع هذه بتاريخ %', p_date using errcode = 'P0001';
  end if;

  fee_version_id := v_row.id;
  percentage_fee := v_row.percentage_fee;
  fixed_fee := v_row.fixed_fee;
  return next;
end;
$$;

comment on function public.payment_fee_for_method_on_date(uuid, date) is
  'Fee configuration (percentage_fee, fixed_fee) applicable to a payment method on a date. Raises P0001 if no active version covers that date — deliberately what happens for COD until an Admin configures a real rate (no fabricated default).';

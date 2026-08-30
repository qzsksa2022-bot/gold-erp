-- ============================================================================
-- 0041: daily_gold_prices — Phase 2, module 2/6
-- ============================================================================
-- A historical, append-and-update-today log — NOT a single setting
-- overwritten daily (spec §3: "نبني سجل أسعار تاريخي، وليس Setting واحدة").
-- Each (price_date, karat_id) pair is exactly one row; "saving today's
-- prices" upserts that day's rows only and never touches any earlier date,
-- so history is preserved automatically by construction.
--
-- Design is already shaped for a future external price feed without a
-- schema change: source_type distinguishes manual entry from an
-- external_api pull, source_name/source_reference record where an
-- automated price came from, and is_manual_override stays available even
-- after that integration exists (a human can always override a fetched
-- price — spec §3: "حتى بعد إضافة التكامل مستقبلًا، يجب أن يستطيع المستخدم
-- المصرح له عمل Manual Override"). No external API is called from this
-- migration or any app code in this phase.
create table public.daily_gold_prices (
  id uuid primary key default gen_random_uuid(),
  -- The trading date this price applies to (not the row's insert time).
  price_date date not null,
  karat_id uuid not null references public.karats (id) on delete restrict,
  price_per_gram numeric(12, 4) not null check (price_per_gram > 0),
  source_type text not null default 'manual' check (source_type in ('manual', 'external_api')),
  source_name text,
  source_reference text,
  is_manual_override boolean not null default true,
  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (price_date, karat_id)
);

comment on table public.daily_gold_prices is
  'Historical daily gold price log, one row per (price_date, karat_id). Never delete past days — "saving today''s prices" only inserts/updates today''s rows. price_per_gram is always > 0 (checked); there is no such thing as a valid free/zero gold price, unlike a payment fee.';

create index daily_gold_prices_date_idx on public.daily_gold_prices (price_date desc);
create index daily_gold_prices_karat_idx on public.daily_gold_prices (karat_id);

create trigger daily_gold_prices_set_updated_at
  before update on public.daily_gold_prices
  for each row
  execute function public.set_updated_at();

alter table public.daily_gold_prices enable row level security;

create policy daily_gold_prices_select on public.daily_gold_prices
  for select to authenticated
  using (public.has_permission('gold_prices.view'));

create policy daily_gold_prices_insert on public.daily_gold_prices
  for insert to authenticated
  with check (public.has_permission('gold_prices.edit'));

create policy daily_gold_prices_update on public.daily_gold_prices
  for update to authenticated
  using (public.has_permission('gold_prices.edit'))
  with check (public.has_permission('gold_prices.edit'));

-- No DELETE policy: "لا تمسح أسعار الأيام السابقة" — enforced at the
-- database layer, not just by the UI never offering a delete button.

create trigger daily_gold_prices_audit_trigger
  after insert or update or delete on public.daily_gold_prices
  for each row execute function public.audit_table_changes('gold_price', 'id');

-- ---------------------------------------------------------------------------
-- Fast "save today's prices" entry point (spec §3 UX requirement). A plain
-- supabase-js .upsert() would overwrite EVERY column it is given on
-- conflict, including created_by/created_at, silently erasing who first
-- recorded a given day's price every time it is later corrected. This
-- SECURITY INVOKER function instead does INSERT ... ON CONFLICT DO UPDATE
-- with an explicit column list: price_per_gram/source fields/updated_by/
-- updated_at change, created_by/created_at never do once a row exists.
-- ---------------------------------------------------------------------------
create or replace function public.save_daily_gold_price(
  p_price_date date,
  p_karat_id uuid,
  p_price_per_gram numeric,
  p_notes text default null
)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  if not public.has_permission('gold_prices.edit') then
    raise exception 'ليست لديك صلاحية تعديل أسعار الذهب' using errcode = 'P0001';
  end if;

  if p_price_date is null or p_karat_id is null or p_price_per_gram is null then
    raise exception 'التاريخ والعيار والسعر كلها مطلوبة' using errcode = 'P0001';
  end if;

  if p_price_per_gram <= 0 then
    raise exception 'السعر يجب أن يكون رقمًا موجبًا' using errcode = 'P0001';
  end if;

  insert into public.daily_gold_prices
    (price_date, karat_id, price_per_gram, source_type, is_manual_override, notes, created_by, updated_by)
  values
    (p_price_date, p_karat_id, p_price_per_gram, 'manual', true, p_notes, auth.uid(), auth.uid())
  on conflict (price_date, karat_id) do update
    set price_per_gram = excluded.price_per_gram,
        source_type = 'manual',
        is_manual_override = true,
        notes = excluded.notes,
        updated_by = auth.uid(),
        updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.save_daily_gold_price(date, uuid, numeric, text) is
  'Upserts one (price_date, karat_id) price row via an explicit column list — unlike a raw upsert, created_by/created_at are set on first insert only and never touched again on a later same-day correction, so "who first recorded this" stays intact while updated_by/updated_at always reflect the latest edit. Always stamps source_type=manual/is_manual_override=true (this phase has no external feed to mark it otherwise).';

-- ---------------------------------------------------------------------------
-- Query surface for later phases (spec §16): "gold price for (karat, date)".
-- Deliberately RAISES on a missing price instead of returning NULL/0 — spec
-- §3/§16: "لا يقوم النظام بافتراض 0 بصمت في الحالات المالية".
-- ---------------------------------------------------------------------------
create or replace function public.gold_price_for_karat_on_date(p_karat_id uuid, p_date date default current_date)
returns numeric
language plpgsql
stable
as $$
declare
  v_price numeric;
begin
  select price_per_gram into v_price
  from public.daily_gold_prices
  where karat_id = p_karat_id and price_date = p_date;

  if v_price is null then
    raise exception 'لا يوجد سعر ذهب مسجَّل لهذا العيار بتاريخ %', p_date using errcode = 'P0001';
  end if;

  return v_price;
end;
$$;

comment on function public.gold_price_for_karat_on_date(uuid, date) is
  'Gold price per gram for a karat on an exact date. Raises P0001 (not NULL/0) if no price was recorded for that exact date — callers must not silently treat a missing price as free/zero. SECURITY INVOKER; RLS (gold_prices.view) governs access as usual.';

-- ---------------------------------------------------------------------------
-- Discoverability hook for a future "missing today's price" notification
-- (spec §3: "لا تبنِ Notification Engine جديدًا الآن... فقط اجعل البيانات
-- قابلة لاكتشاف هذه الحالة"). Returns every ACTIVE karat that has no price
-- row for the given date (defaults to today) — a future scheduled job or
-- dashboard widget can poll this without any schema change.
-- ---------------------------------------------------------------------------
create or replace function public.gold_prices_missing_for_date(p_date date default current_date)
returns setof public.karats
language sql
stable
as $$
  select k.* from public.karats k
  where k.status = 'active'
    and not exists (
      select 1 from public.daily_gold_prices p
      where p.karat_id = k.id and p.price_date = p_date
    )
  order by k.sort_order, k.code;
$$;

comment on function public.gold_prices_missing_for_date(date) is
  'Active karats with no daily_gold_prices row for the given date (defaults to today). Discoverability hook only — no notification is sent by this function; a future scheduler/dashboard widget consumes it.';

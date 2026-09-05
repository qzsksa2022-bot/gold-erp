-- ============================================================================
-- 0235: Phase 10 — Store Expenses Core (3/4): SECURITY DEFINER RPCs
-- ============================================================================
-- Migrations 0001-0234 are unmodified.
--
-- Every mutation/read below is a SECURITY DEFINER RPC with search_path pinned
-- to public, pg_temp — the base tables carry zero direct-write RLS policy
-- (0234), so this is not merely a convention, it is the only path that works
-- at all, mirroring every prior phase exactly. Money values are always
-- returned ::text (never a raw numeric column), matching this codebase's
-- "safe" RPC convention (see src/lib/decimal.ts's toDecimal doc comment) —
-- PostgREST serializes numeric as an unquoted JSON number by default, which
-- is exactly where precision can silently be lost.
-- ---------------------------------------------------------------------------
begin;

-- ---------------------------------------------------------------------------
-- create_expense_category() — gated on expenses.manage_categories.
-- ---------------------------------------------------------------------------
create or replace function public.create_expense_category(
  p_code text,
  p_name_ar text,
  p_name_en text default null,
  p_notes text default null
)
returns table (id uuid, code text, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
begin
  if v_actor is null or not public.has_permission('expenses.manage_categories') then
    raise exception 'ليست لديك صلاحية إدارة تصنيفات المصروفات' using errcode = 'P0001';
  end if;

  if p_code is null or btrim(p_code) = '' then
    raise exception 'رمز التصنيف مطلوب' using errcode = 'P0001';
  end if;

  if p_name_ar is null or btrim(p_name_ar) = '' then
    raise exception 'اسم التصنيف مطلوب' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.expense_categories c where lower(c.code) = lower(btrim(p_code))) then
    raise exception 'رمز التصنيف مستخدم بالفعل' using errcode = 'P0001';
  end if;

  insert into public.expense_categories (code, name_ar, name_en, notes, created_by, updated_by)
  values (btrim(p_code), btrim(p_name_ar), nullif(btrim(coalesce(p_name_en, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''), v_actor, v_actor)
  returning expense_categories.id into v_id;

  perform public.log_audit_event(
    'expense_category.create', 'expense_category', v_id, null,
    jsonb_build_object('code', btrim(p_code), 'name_ar', btrim(p_name_ar), 'name_en', p_name_en, 'notes', p_notes)
  );

  return query select c.id, c.code, c.row_version from public.expense_categories c where c.id = v_id;
end;
$$;

revoke execute on function public.create_expense_category(text, text, text, text) from public;
grant execute on function public.create_expense_category(text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- update_expense_category() — row_version optimistic concurrency.
-- `code` is permanent once created (mirrors adjustment_types.code and
-- inventory_items.sku).
-- ---------------------------------------------------------------------------
create or replace function public.update_expense_category(
  p_id uuid,
  p_expected_version bigint,
  p_name_ar text,
  p_name_en text default null,
  p_notes text default null
)
returns table (id uuid, row_version bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old public.expense_categories%rowtype;
begin
  if v_actor is null or not public.has_permission('expenses.manage_categories') then
    raise exception 'ليست لديك صلاحية إدارة تصنيفات المصروفات' using errcode = 'P0001';
  end if;

  if p_name_ar is null or btrim(p_name_ar) = '' then
    raise exception 'اسم التصنيف مطلوب' using errcode = 'P0001';
  end if;

  -- Table-aliased so `id`/`row_version` resolve to the COLUMNS rather than
  -- colliding with this function's own RETURNS TABLE out-parameters (the
  -- run-time-only failure 0232 had to fix in update_inventory_item()).
  select * into v_old from public.expense_categories c where c.id = p_id for update;

  if not found then
    raise exception 'التصنيف غير موجود' using errcode = 'P0001';
  end if;

  -- A NULL expected version is rejected explicitly: `row_version <> NULL` is
  -- NULL, never TRUE, so a caller that simply omitted the version would
  -- silently bypass optimistic concurrency entirely (0232 lineage).
  if p_expected_version is null then
    raise exception 'رقم إصدار التصنيف (row_version) مطلوب للتعديل' using errcode = 'P0001';
  end if;

  if v_old.row_version is distinct from p_expected_version then
    raise exception 'تم تعديل هذا التصنيف من قِبل مستخدم آخر، الرجاء إعادة التحميل والمحاولة مرة أخرى' using errcode = 'P0001';
  end if;

  update public.expense_categories ec
  set name_ar = btrim(p_name_ar),
      name_en = nullif(btrim(coalesce(p_name_en, '')), ''),
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      row_version = ec.row_version + 1,
      updated_by = v_actor,
      updated_at = now()
  where ec.id = p_id;

  perform public.log_audit_event(
    'expense_category.update', 'expense_category', p_id,
    jsonb_build_object('name_ar', v_old.name_ar, 'name_en', v_old.name_en, 'notes', v_old.notes),
    jsonb_build_object('name_ar', btrim(p_name_ar), 'name_en', p_name_en, 'notes', p_notes)
  );

  return query select p_id, c.row_version from public.expense_categories c where c.id = p_id;
end;
$$;

revoke execute on function public.update_expense_category(uuid, bigint, text, text, text) from public;
grant execute on function public.update_expense_category(uuid, bigint, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- enable/disable_expense_category() — lifecycle, mirrors 0136's
-- enable_adjustment_type()/disable_adjustment_type() exactly. A category is
-- NEVER deleted, so historical store_expenses rows keep resolving.
-- ---------------------------------------------------------------------------
create or replace function public.disable_expense_category(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old text;
begin
  if v_actor is null or not public.has_permission('expenses.manage_categories') then
    raise exception 'ليست لديك صلاحية إدارة تصنيفات المصروفات' using errcode = 'P0001';
  end if;

  select c.status into v_old from public.expense_categories c where c.id = p_id for update;
  if v_old is null then
    raise exception 'التصنيف غير موجود' using errcode = 'P0001';
  end if;

  update public.expense_categories ec
  set status = 'disabled', row_version = ec.row_version + 1, updated_by = v_actor, updated_at = now()
  where ec.id = p_id;

  perform public.log_audit_event('expense_category.disable', 'expense_category', p_id,
    jsonb_build_object('status', v_old), jsonb_build_object('status', 'disabled'));
end;
$$;

create or replace function public.enable_expense_category(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_old text;
begin
  if v_actor is null or not public.has_permission('expenses.manage_categories') then
    raise exception 'ليست لديك صلاحية إدارة تصنيفات المصروفات' using errcode = 'P0001';
  end if;

  select c.status into v_old from public.expense_categories c where c.id = p_id for update;
  if v_old is null then
    raise exception 'التصنيف غير موجود' using errcode = 'P0001';
  end if;

  update public.expense_categories ec
  set status = 'active', row_version = ec.row_version + 1, updated_by = v_actor, updated_at = now()
  where ec.id = p_id;

  perform public.log_audit_event('expense_category.enable', 'expense_category', p_id,
    jsonb_build_object('status', v_old), jsonb_build_object('status', 'active'));
end;
$$;

revoke execute on function public.disable_expense_category(uuid) from public;
grant execute on function public.disable_expense_category(uuid) to authenticated;
revoke execute on function public.enable_expense_category(uuid) from public;
grant execute on function public.enable_expense_category(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- _store_expense_daily_close_guard() — internal. The §12 Daily Close contract,
-- identical in shape to record_settlement_bank_movement()'s (0188): take the
-- SHARED lock on (store, business_date) so this entry can never slip in while
-- close_sales_day() is closing that exact day, then require BOTH the
-- process_closed_day permission AND an explicit reason if the day is already
-- closed.
-- ---------------------------------------------------------------------------
create or replace function public._store_expense_daily_close_guard(
  p_store_id uuid,
  p_business_date date,
  p_closed_day_reason text,
  p_what text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.acquire_daily_close_lock_shared(p_store_id, p_business_date);

  if exists (select 1 from public.daily_closings dc where dc.store_id = p_store_id and dc.business_date = p_business_date) then
    if not public.has_permission('expenses.process_closed_day') then
      raise exception 'تاريخ % (%) يقع في يوم مقفل لهذا الفرع — يتطلب صلاحية خاصة (expenses.process_closed_day)', p_what, p_business_date using errcode = 'P0001';
    end if;
    if p_closed_day_reason is null or btrim(p_closed_day_reason) = '' then
      raise exception 'يجب إدخال سبب لتسجيل % في يوم مقفل', p_what using errcode = 'P0001';
    end if;
  end if;
end;
$$;

comment on function public._store_expense_daily_close_guard(uuid, date, text, text) is
  'Phase 10 (internal) — §12 Daily Close guard for the expense ledger: acquires the SHARED (1002) daily-close lock for (store, business_date), then demands expenses.process_closed_day plus an explicit reason if that day is already closed. Not granted to authenticated; reachable only through record_store_expense()/reverse_store_expense().';

revoke execute on function public._store_expense_daily_close_guard(uuid, date, text, text) from public;

-- ---------------------------------------------------------------------------
-- record_store_expense() — post an expense (gross paid amount only).
-- ---------------------------------------------------------------------------
create or replace function public.record_store_expense(
  p_store_id uuid,
  p_expense_category_id uuid,
  p_amount numeric,
  p_business_date date default public.business_today(),
  p_description text default null,
  p_closed_day_reason text default null
)
returns table (id uuid, expense_number text, amount text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
  v_number text;
  -- Typed to the COLUMN's own numeric(14, 2), and read back from the inserted
  -- row below, so the ::text this RPC returns is exactly what was stored
  -- ("1500.00"), never the caller's unscaled input literal ("1500").
  v_stored_amount numeric(14, 2);
  v_category public.expense_categories%rowtype;
begin
  if v_actor is null or not public.has_permission('expenses.create') then
    raise exception 'ليست لديك صلاحية تسجيل مصروف' using errcode = 'P0001';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'مبلغ المصروف يجب أن يكون رقمًا موجبًا' using errcode = 'P0001';
  end if;
  perform public.validate_money_scale(p_amount, 'مبلغ المصروف');

  if p_business_date is null then
    raise exception 'تاريخ المصروف مطلوب' using errcode = 'P0001';
  end if;
  if p_business_date > public.business_today() then
    raise exception 'لا يمكن تسجيل مصروف بتاريخ مستقبلي' using errcode = 'P0001';
  end if;

  -- Write scope is OPERABLE (can act on), not merely visible — matching
  -- record_inventory_stock_movement() (0229) and every other write path.
  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = p_store_id) then
    raise exception 'ليس لديك صلاحية الوصول لهذا الفرع' using errcode = 'P0001';
  end if;

  select * into v_category from public.expense_categories c where c.id = p_expense_category_id;
  if v_category.id is null then
    raise exception 'تصنيف المصروف غير موجود' using errcode = 'P0001';
  end if;
  if v_category.status <> 'active' then
    raise exception 'تصنيف المصروف غير نشط' using errcode = 'P0001';
  end if;

  perform public._store_expense_daily_close_guard(p_store_id, p_business_date, p_closed_day_reason, 'المصروف');

  v_number := public.generate_expense_number();

  insert into public.store_expenses (
    expense_number, store_id, expense_category_id, business_date, entry_kind, amount,
    description, closed_day_reason, category_code_snapshot, category_name_ar_snapshot, created_by
  )
  values (
    v_number, p_store_id, p_expense_category_id, p_business_date, 'expense', p_amount,
    nullif(btrim(coalesce(p_description, '')), ''), nullif(btrim(coalesce(p_closed_day_reason, '')), ''),
    v_category.code, v_category.name_ar, v_actor
  )
  returning store_expenses.id, store_expenses.amount into v_id, v_stored_amount;

  perform public.log_audit_event(
    'expense.record', 'store_expense', v_id, null,
    jsonb_build_object(
      'expense_number', v_number, 'store_id', p_store_id, 'expense_category_id', p_expense_category_id,
      'business_date', p_business_date, 'amount', v_stored_amount::text, 'description', p_description
    )
  );

  return query select v_id, v_number, v_stored_amount::text;
end;
$$;

revoke execute on function public.record_store_expense(uuid, uuid, numeric, date, text, text) from public;
grant execute on function public.record_store_expense(uuid, uuid, numeric, date, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- reverse_store_expense() — the ONLY correction path.
-- ---------------------------------------------------------------------------
create or replace function public.reverse_store_expense(
  p_expense_id uuid,
  p_reason text,
  p_reversal_business_date date default public.business_today(),
  p_closed_day_reason text default null
)
returns table (id uuid, expense_number text, amount text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_original public.store_expenses%rowtype;
  v_id uuid;
  v_number text;
  -- Read back from the inserted row for the same reason as
  -- record_store_expense(): the returned ::text must be the STORED value.
  v_stored_amount numeric(14, 2);
begin
  if v_actor is null or not public.has_permission('expenses.reverse') then
    raise exception 'ليست لديك صلاحية عكس مصروف' using errcode = 'P0001';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'سبب العكس مطلوب' using errcode = 'P0001';
  end if;

  if p_reversal_business_date is null then
    raise exception 'تاريخ العكس مطلوب' using errcode = 'P0001';
  end if;
  if p_reversal_business_date > public.business_today() then
    raise exception 'لا يمكن عكس مصروف بتاريخ مستقبلي' using errcode = 'P0001';
  end if;

  -- Row-locks the original for the rest of this transaction, so two
  -- concurrent reversals of the SAME expense are serialized here; the loser
  -- then re-reads the already-reversed state below. The partial unique index
  -- (0234) is the authoritative backstop either way.
  select * into v_original from public.store_expenses se where se.id = p_expense_id for update;

  if v_original.id is null then
    raise exception 'المصروف غير موجود' using errcode = 'P0001';
  end if;

  if v_original.entry_kind <> 'expense' then
    raise exception 'لا يمكن عكس حركة عكس — اعكس المصروف الأصلي بدلًا من ذلك' using errcode = 'P0001';
  end if;

  if not exists (select 1 from public.user_operable_store_ids(v_actor) sid where sid = v_original.store_id) then
    raise exception 'ليس لديك صلاحية الوصول لهذا الفرع' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from public.store_expenses se
    where se.reverses_expense_id = p_expense_id and se.entry_kind = 'reversal'
  ) then
    raise exception 'تم عكس هذا المصروف مسبقًا' using errcode = 'P0001';
  end if;

  if p_reversal_business_date < v_original.business_date then
    raise exception 'تاريخ العكس لا يمكن أن يسبق تاريخ المصروف الأصلي (%)', v_original.business_date using errcode = 'P0001';
  end if;

  -- §85 Event Date: the reversal is guarded against ITS OWN business date,
  -- not the original's.
  perform public._store_expense_daily_close_guard(v_original.store_id, p_reversal_business_date, p_closed_day_reason, 'عكس المصروف');

  v_number := public.generate_expense_number();

  insert into public.store_expenses (
    expense_number, store_id, expense_category_id, business_date, entry_kind, amount,
    description, reverses_expense_id, reversal_reason, closed_day_reason,
    category_code_snapshot, category_name_ar_snapshot, created_by
  )
  values (
    v_number, v_original.store_id, v_original.expense_category_id, p_reversal_business_date, 'reversal', -v_original.amount,
    v_original.description, p_expense_id, btrim(p_reason), nullif(btrim(coalesce(p_closed_day_reason, '')), ''),
    v_original.category_code_snapshot, v_original.category_name_ar_snapshot, v_actor
  )
  returning store_expenses.id, store_expenses.amount into v_id, v_stored_amount;

  perform public.log_audit_event(
    'expense.reverse', 'store_expense', v_id,
    jsonb_build_object('reversed_expense_number', v_original.expense_number, 'original_amount', v_original.amount::text, 'original_business_date', v_original.business_date),
    jsonb_build_object('expense_number', v_number, 'amount', v_stored_amount::text, 'business_date', p_reversal_business_date, 'reason', btrim(p_reason))
  );

  return query select v_id, v_number, v_stored_amount::text;
end;
$$;

revoke execute on function public.reverse_store_expense(uuid, text, date, text) from public;
grant execute on function public.reverse_store_expense(uuid, text, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Reads — paginated, store-scoped, money as text.
-- ---------------------------------------------------------------------------
create or replace function public.list_expense_categories(
  p_search text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_rows jsonb;
  v_total int;
begin
  if v_actor is null or not public.has_permission('expenses.view') then
    raise exception 'ليست لديك صلاحية عرض تصنيفات المصروفات' using errcode = 'P0001';
  end if;

  select count(*) into v_total
  from public.expense_categories c
  where (p_status is null or c.status = p_status)
    and (p_search is null or btrim(p_search) = '' or c.name_ar ilike '%' || btrim(p_search) || '%' or c.code ilike '%' || btrim(p_search) || '%');

  select coalesce(jsonb_agg(r order by r ->> 'code'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', c.id, 'code', c.code, 'name_ar', c.name_ar, 'name_en', c.name_en,
      'status', c.status, 'notes', c.notes, 'row_version', c.row_version
    ) as r
    from public.expense_categories c
    where (p_status is null or c.status = p_status)
      and (p_search is null or btrim(p_search) = '' or c.name_ar ilike '%' || btrim(p_search) || '%' or c.code ilike '%' || btrim(p_search) || '%')
    order by c.code
    limit v_limit offset greatest(coalesce(p_offset, 0), 0)
  ) t;

  return jsonb_build_object('rows', v_rows, 'total_count', v_total, 'limit', v_limit, 'offset', greatest(coalesce(p_offset, 0), 0));
end;
$$;

revoke execute on function public.list_expense_categories(text, text, integer, integer) from public;
grant execute on function public.list_expense_categories(text, text, integer, integer) to authenticated;

create or replace function public.list_store_expenses(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_expense_category_id uuid default null,
  p_entry_kind text default null,
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 5000);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_scope uuid[];
  v_rows jsonb;
  v_total int;
  v_expense_total numeric(14, 2);
  v_reversal_total numeric(14, 2);
  v_net numeric(14, 2);
begin
  if v_actor is null or not public.has_permission('expenses.view') then
    raise exception 'ليست لديك صلاحية عرض مصروفات الفروع' using errcode = 'P0001';
  end if;

  if p_date_from is null or p_date_to is null then
    raise exception 'نطاق التاريخ مطلوب' using errcode = 'P0001';
  end if;
  if p_date_from > p_date_to then
    raise exception 'تاريخ البداية لا يمكن أن يكون بعد تاريخ النهاية' using errcode = 'P0001';
  end if;

  select array_agg(sid) into v_scope from public.user_visible_store_ids(v_actor) sid;
  v_scope := coalesce(v_scope, array[]::uuid[]);

  -- An explicit store filter naming a store outside the actor's scope is
  -- REJECTED, never silently narrowed (§8, same as every report RPC).
  if p_store_ids is not null then
    if exists (select 1 from unnest(p_store_ids) s where s <> all (v_scope)) then
      raise exception 'أحد الفروع المحددة خارج نطاق صلاحيتك' using errcode = 'P0001';
    end if;
    v_scope := p_store_ids;
  end if;

  select
    count(*),
    coalesce(sum(se.amount) filter (where se.entry_kind = 'expense'), 0),
    coalesce(sum(se.amount) filter (where se.entry_kind = 'reversal'), 0),
    coalesce(sum(se.amount), 0)
  into v_total, v_expense_total, v_reversal_total, v_net
  from public.store_expenses se
  where se.store_id = any (v_scope)
    and se.business_date between p_date_from and p_date_to
    and (p_expense_category_id is null or se.expense_category_id = p_expense_category_id)
    and (p_entry_kind is null or se.entry_kind = p_entry_kind)
    and (p_search is null or btrim(p_search) = '' or se.expense_number ilike '%' || btrim(p_search) || '%' or coalesce(se.description, '') ilike '%' || btrim(p_search) || '%');

  select coalesce(jsonb_agg(r order by (r ->> 'business_date') desc, r ->> 'expense_number' desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', se.id,
      'expense_number', se.expense_number,
      'store_id', se.store_id,
      'store_name', st.name_ar,
      'expense_category_id', se.expense_category_id,
      'category_code', se.category_code_snapshot,
      'category_name', se.category_name_ar_snapshot,
      'business_date', se.business_date,
      'entry_kind', se.entry_kind,
      'amount', se.amount::text,
      'description', se.description,
      'reverses_expense_id', se.reverses_expense_id,
      'reversal_reason', se.reversal_reason,
      'is_reversed', exists (select 1 from public.store_expenses r2 where r2.reverses_expense_id = se.id and r2.entry_kind = 'reversal')
    ) as r
    from public.store_expenses se
    join public.stores st on st.id = se.store_id
    where se.store_id = any (v_scope)
      and se.business_date between p_date_from and p_date_to
      and (p_expense_category_id is null or se.expense_category_id = p_expense_category_id)
      and (p_entry_kind is null or se.entry_kind = p_entry_kind)
      and (p_search is null or btrim(p_search) = '' or se.expense_number ilike '%' || btrim(p_search) || '%' or coalesce(se.description, '') ilike '%' || btrim(p_search) || '%')
    order by se.business_date desc, se.expense_number desc
    limit v_limit offset v_offset
  ) t;

  return jsonb_build_object(
    'rows', v_rows,
    'total_count', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'date_from', p_date_from,
    'date_to', p_date_to,
    'summary', jsonb_build_object(
      'entries_count', v_total,
      'gross_expenses_total', v_expense_total::text,
      'reversals_total', v_reversal_total::text,
      'operating_expenses_total', v_net::text
    )
  );
end;
$$;

revoke execute on function public.list_store_expenses(date, date, uuid[], uuid, text, text, integer, integer) from public;
grant execute on function public.list_store_expenses(date, date, uuid[], uuid, text, text, integer, integer) to authenticated;

commit;

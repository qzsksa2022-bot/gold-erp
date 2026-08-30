-- ============================================================================
-- 0043: product_categories — Phase 2, module 4/6
-- ============================================================================
-- Hierarchical (self-referencing parent_id), depth is NOT capped — the
-- table structure supports Main → Sub → Sub-sub... indefinitely even though
-- the current UI only exposes Main/Sub (spec §5: "لا نحدد عمق الشجرة بشكل
-- يمنع التوسع مستقبلًا"). external_id/external_source are included now
-- (nullable, unused) so a future qzs-ksa.com sync can be added without a
-- schema change — no sync runs in this phase.
create table public.product_categories (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.product_categories (id) on delete restrict,
  -- Plain UNIQUE (not just the case-insensitive index below): Postgres
  -- treats every NULL as distinct under a plain unique constraint, so this
  -- costs nothing for categories that never set a code, while giving seed
  -- data (and any future ON CONFLICT (code) upsert) a simple, non-partial
  -- target to reference.
  code text unique,
  name_ar text not null,
  name_en text,
  sort_order integer not null default 0,
  status text not null default 'active' check (status in ('active', 'inactive')),
  -- Reserved for a future external catalog sync (e.g. qzs-ksa.com) — not
  -- populated or read by any code in this phase.
  external_id text,
  external_source text,
  created_by uuid references public.profiles (id) on delete set null,
  updated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (parent_id is null or parent_id <> id)
);

comment on table public.product_categories is
  'Hierarchical product category tree (self-referencing parent_id, unbounded depth). Never hard-deleted once used historically — status=inactive instead. on delete restrict on parent_id: a category with children cannot be deleted at the DB level either (there is no DELETE policy for authenticated anyway, but this also protects service_role/admin tooling from accidentally orphaning a subtree).';

create unique index product_categories_code_lower_idx on public.product_categories (lower(code)) where code is not null;
create index product_categories_parent_idx on public.product_categories (parent_id);
create index product_categories_status_idx on public.product_categories (status);
create index product_categories_sort_order_idx on public.product_categories (sort_order);

create trigger product_categories_set_updated_at
  before update on public.product_categories
  for each row
  execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Cycle guard: a category can never become its own ancestor (directly via
-- the CHECK above, or indirectly through a longer chain via this trigger).
-- Without this, re-parenting two existing categories into each other would
-- silently create an infinite loop that any recursive tree query would
-- spin forever on.
-- ---------------------------------------------------------------------------
create or replace function public.prevent_category_cycle()
returns trigger
language plpgsql
as $$
declare
  v_current uuid;
  v_depth integer := 0;
begin
  if new.parent_id is null then
    return new;
  end if;

  v_current := new.parent_id;
  while v_current is not null loop
    if v_current = new.id then
      raise exception 'لا يمكن أن يكون التصنيف أبًا لنفسه عبر سلسلة تصنيفات أخرى — هذا سيُنشئ حلقة لا نهائية' using errcode = 'P0001';
    end if;

    v_depth := v_depth + 1;
    if v_depth > 100 then
      -- Defensive backstop only — a legitimate tree will never approach
      -- this depth; if it does, something is already wrong upstream.
      raise exception 'سلسلة تصنيفات أعمق من الحد المسموح — تحقق من بنية الشجرة' using errcode = 'P0001';
    end if;

    select parent_id into v_current from public.product_categories where id = v_current;
  end loop;

  return new;
end;
$$;

create trigger product_categories_prevent_cycle
  before insert or update of parent_id on public.product_categories
  for each row execute function public.prevent_category_cycle();

alter table public.product_categories enable row level security;

create policy product_categories_select on public.product_categories
  for select to authenticated
  using (public.has_permission('categories.view'));

create policy product_categories_insert on public.product_categories
  for insert to authenticated
  with check (public.has_permission('categories.manage'));

create policy product_categories_update on public.product_categories
  for update to authenticated
  using (public.has_permission('categories.manage'))
  with check (public.has_permission('categories.manage'));

-- No DELETE policy — disable instead (spec §5: "لا يوجد Hard Delete لتصنيف
-- مستخدم تاريخيًا"); on delete restrict on parent_id above additionally
-- protects service_role tooling from orphaning a subtree even if it tried.

create trigger product_categories_audit_trigger
  after insert or update or delete on public.product_categories
  for each row execute function public.audit_table_changes('product_category', 'id');

-- ---------------------------------------------------------------------------
-- Query surface for later phases (spec §16): "active product categories".
-- ---------------------------------------------------------------------------
create or replace function public.active_product_categories()
returns setof public.product_categories
language sql
stable
as $$
  select * from public.product_categories
  where status = 'active'
  order by sort_order, name_ar;
$$;

comment on function public.active_product_categories() is
  'Active product categories, unordered by hierarchy (flat) — callers needing the tree shape join on parent_id themselves. SECURITY INVOKER — relies on the caller holding categories.view via RLS.';

-- ============================================================================
-- 0240: Phase 11 — Purchases & Suppliers Core (4/4): reads and reports
-- ============================================================================
-- Migrations 0001-0239 are unmodified.
--
-- Purchases are a SEPARATE report layer, by design. Nothing here touches
-- get_dashboard_summary(), get_dashboard_summary_with_comparison() (0221),
-- get_dashboard_summary_with_expenses() (0236) or any Phase 10 expense
-- function: an acquisition of inventory is not an operating expense, and
-- Phase 11 introduces no GL and no COGS. net_operating_return and the
-- operating-expense formulas keep their exact meaning and their exact values.
--
-- Every monetary value is returned ::text. Invoice status and outstanding
-- amounts are DERIVED here from the immutable ledgers, never read from a
-- stored column (there is none).
-- ---------------------------------------------------------------------------
begin;

-- ---------------------------------------------------------------------------
-- list_suppliers()
-- ---------------------------------------------------------------------------
create or replace function public.list_suppliers(
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
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_rows jsonb;
  v_total int;
begin
  if v_actor is null or not public.has_permission('purchases.view') then
    raise exception 'ليست لديك صلاحية عرض الموردين' using errcode = 'P0001';
  end if;

  select count(*) into v_total
  from public.suppliers s
  where (p_status is null or s.status = p_status)
    and (p_search is null or btrim(p_search) = '' or s.name_ar ilike '%' || btrim(p_search) || '%' or s.code ilike '%' || btrim(p_search) || '%');

  select coalesce(jsonb_agg(r order by r ->> 'code'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', s.id, 'code', s.code, 'name_ar', s.name_ar, 'name_en', s.name_en,
      'vat_number', s.vat_number, 'contact_person', s.contact_person, 'phone', s.phone,
      'email', s.email, 'status', s.status, 'notes', s.notes, 'row_version', s.row_version
    ) as r
    from public.suppliers s
    where (p_status is null or s.status = p_status)
      and (p_search is null or btrim(p_search) = '' or s.name_ar ilike '%' || btrim(p_search) || '%' or s.code ilike '%' || btrim(p_search) || '%')
    order by s.code
    limit v_limit offset v_offset
  ) t;

  return jsonb_build_object('rows', v_rows, 'total_count', v_total, 'limit', v_limit, 'offset', v_offset);
end;
$$;

revoke execute on function public.list_suppliers(text, text, integer, integer) from public;
grant execute on function public.list_suppliers(text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- list_purchase_invoices() — the purchases report engine (screen AND export,
-- §39 one engine).
-- ---------------------------------------------------------------------------
-- `payment_status` is DERIVED per row:
--   reversed  the invoice carries a reversal document
--   paid      outstanding = 0
--   partial   0 < outstanding < gross
--   unpaid    outstanding = gross
-- computed from ledger facts only.
create or replace function public.list_purchase_invoices(
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null,
  p_supplier_id uuid default null,
  p_entry_kind text default null,
  p_payment_status text default null,
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
  v_net numeric(14, 2);
  v_vat numeric(14, 2);
  v_gross numeric(14, 2);
  v_paid numeric(14, 2);
begin
  if v_actor is null or not public.has_permission('purchases.view') then
    raise exception 'ليست لديك صلاحية عرض المشتريات' using errcode = 'P0001';
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
  -- REJECTED, never silently narrowed (§8).
  if p_store_ids is not null then
    if exists (select 1 from unnest(p_store_ids) s where s <> all (v_scope)) then
      raise exception 'أحد الفروع المحددة خارج نطاق صلاحيتك' using errcode = 'P0001';
    end if;
    v_scope := p_store_ids;
  end if;

  with base as (
    select pi.*,
      public.purchase_invoice_outstanding(pi.id) as outstanding,
      exists (select 1 from public.purchase_invoices r where r.reverses_invoice_id = pi.id and r.entry_kind = 'reversal') as is_reversed
    from public.purchase_invoices pi
    where pi.store_id = any (v_scope)
      and pi.business_date between p_date_from and p_date_to
      and (p_supplier_id is null or pi.supplier_id = p_supplier_id)
      and (p_entry_kind is null or pi.entry_kind = p_entry_kind)
      and (p_search is null or btrim(p_search) = ''
           or pi.purchase_number ilike '%' || btrim(p_search) || '%'
           or coalesce(pi.supplier_invoice_number, '') ilike '%' || btrim(p_search) || '%'
           or pi.supplier_name_snapshot ilike '%' || btrim(p_search) || '%')
  ),
  classified as (
    select b.*,
      case
        when b.entry_kind = 'reversal' then 'reversal'
        when b.is_reversed then 'reversed'
        when b.outstanding = 0 then 'paid'
        when b.outstanding < b.gross_total then 'partial'
        else 'unpaid'
      end as payment_status
    from base b
  ),
  filtered as (
    select * from classified c
    where p_payment_status is null or c.payment_status = p_payment_status
  )
  select
    count(*),
    coalesce(sum(f.net_total), 0),
    coalesce(sum(f.vat_total), 0),
    coalesce(sum(f.gross_total), 0),
    coalesce(sum(case when f.entry_kind = 'invoice' then f.gross_total - f.outstanding else 0 end), 0)
  into v_total, v_net, v_vat, v_gross, v_paid
  from filtered f;

  with base as (
    select pi.*,
      public.purchase_invoice_outstanding(pi.id) as outstanding,
      exists (select 1 from public.purchase_invoices r where r.reverses_invoice_id = pi.id and r.entry_kind = 'reversal') as is_reversed
    from public.purchase_invoices pi
    where pi.store_id = any (v_scope)
      and pi.business_date between p_date_from and p_date_to
      and (p_supplier_id is null or pi.supplier_id = p_supplier_id)
      and (p_entry_kind is null or pi.entry_kind = p_entry_kind)
      and (p_search is null or btrim(p_search) = ''
           or pi.purchase_number ilike '%' || btrim(p_search) || '%'
           or coalesce(pi.supplier_invoice_number, '') ilike '%' || btrim(p_search) || '%'
           or pi.supplier_name_snapshot ilike '%' || btrim(p_search) || '%')
  ),
  classified as (
    select b.*,
      case
        when b.entry_kind = 'reversal' then 'reversal'
        when b.is_reversed then 'reversed'
        when b.outstanding = 0 then 'paid'
        when b.outstanding < b.gross_total then 'partial'
        else 'unpaid'
      end as payment_status
    from base b
  )
  select coalesce(jsonb_agg(r order by (r ->> 'business_date') desc, r ->> 'purchase_number' desc), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', c.id,
      'purchase_number', c.purchase_number,
      'supplier_id', c.supplier_id,
      'supplier_name', c.supplier_name_snapshot,
      'supplier_vat_number', c.supplier_vat_number_snapshot,
      'supplier_invoice_number', c.supplier_invoice_number,
      'supplier_invoice_date', c.supplier_invoice_date,
      'store_id', c.store_id,
      'store_name', st.name_ar,
      'business_date', c.business_date,
      'entry_kind', c.entry_kind,
      'net_total', c.net_total::text,
      'vat_total', c.vat_total::text,
      'gross_total', c.gross_total::text,
      'outstanding', c.outstanding::text,
      'payment_status', c.payment_status,
      'is_reversed', c.is_reversed,
      'reverses_invoice_id', c.reverses_invoice_id,
      'notes', c.notes
    ) as r
    from classified c
    join public.stores st on st.id = c.store_id
    where p_payment_status is null or c.payment_status = p_payment_status
    order by c.business_date desc, c.purchase_number desc
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
      'documents_count', v_total,
      'net_total', v_net::text,
      'vat_total', v_vat::text,
      'gross_total', v_gross::text,
      'paid_total', v_paid::text,
      'outstanding_total', (v_gross - v_paid)::text
    )
  );
end;
$$;

revoke execute on function public.list_purchase_invoices(date, date, uuid[], uuid, text, text, text, integer, integer) from public;
grant execute on function public.list_purchase_invoices(date, date, uuid[], uuid, text, text, text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- get_purchase_invoice() — one document with its lines and payments.
-- ---------------------------------------------------------------------------
create or replace function public.get_purchase_invoice(p_invoice_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_inv public.purchase_invoices%rowtype;
  v_lines jsonb;
  v_payments jsonb;
  v_outstanding numeric(14, 2);
  v_is_reversed boolean;
begin
  if v_actor is null or not public.has_permission('purchases.view') then
    raise exception 'ليست لديك صلاحية عرض المشتريات' using errcode = 'P0001';
  end if;

  select * into v_inv from public.purchase_invoices pi where pi.id = p_invoice_id;
  if v_inv.id is null
     or not exists (select 1 from public.user_visible_store_ids(v_actor) sid where sid = v_inv.store_id) then
    raise exception 'الفاتورة غير موجودة أو غير متاحة لك' using errcode = 'P0001';
  end if;

  v_outstanding := public.purchase_invoice_outstanding(p_invoice_id);
  v_is_reversed := exists (select 1 from public.purchase_invoices r where r.reverses_invoice_id = p_invoice_id and r.entry_kind = 'reversal');

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', l.id,
    'inventory_item_id', l.inventory_item_id,
    'sku', l.item_sku_snapshot,
    'item_name', l.item_name_snapshot,
    'quantity', l.quantity::text,
    'unit_net_cost', l.unit_net_cost::text,
    'tax_treatment', l.tax_treatment,
    'tax_rate_percent', l.tax_rate_percent::text,
    'net_amount', l.net_amount::text,
    'vat_amount', l.vat_amount::text,
    'gross_amount', l.gross_amount::text,
    'inventory_movement_id', l.inventory_movement_id
  ) order by l.created_at), '[]'::jsonb) into v_lines
  from public.purchase_invoice_lines l where l.purchase_invoice_id = p_invoice_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', sp.id,
    'payment_number', sp.payment_number,
    'business_date', sp.business_date,
    'entry_kind', sp.entry_kind,
    'amount', sp.amount::text,
    'payment_mode', sp.payment_mode,
    'payment_reference', sp.payment_reference,
    'reverses_payment_id', sp.reverses_payment_id,
    'reversal_reason', sp.reversal_reason,
    'is_reversed', exists (select 1 from public.supplier_payments r where r.reverses_payment_id = sp.id and r.entry_kind = 'reversal')
  ) order by sp.business_date, sp.payment_number), '[]'::jsonb) into v_payments
  from public.supplier_payments sp where sp.purchase_invoice_id = p_invoice_id;

  return jsonb_build_object(
    'id', v_inv.id,
    'purchase_number', v_inv.purchase_number,
    'supplier_id', v_inv.supplier_id,
    'supplier_name', v_inv.supplier_name_snapshot,
    'supplier_vat_number', v_inv.supplier_vat_number_snapshot,
    'supplier_invoice_number', v_inv.supplier_invoice_number,
    'supplier_invoice_date', v_inv.supplier_invoice_date,
    'store_id', v_inv.store_id,
    'business_date', v_inv.business_date,
    'entry_kind', v_inv.entry_kind,
    'net_total', v_inv.net_total::text,
    'vat_total', v_inv.vat_total::text,
    'gross_total', v_inv.gross_total::text,
    'outstanding', v_outstanding::text,
    'is_reversed', v_is_reversed,
    'reverses_invoice_id', v_inv.reverses_invoice_id,
    'reversal_reason', v_inv.reversal_reason,
    'notes', v_inv.notes,
    'lines', v_lines,
    'payments', v_payments
  );
end;
$$;

revoke execute on function public.get_purchase_invoice(uuid) from public;
grant execute on function public.get_purchase_invoice(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- get_supplier_outstanding_summary() — the liabilities report.
-- ---------------------------------------------------------------------------
create or replace function public.get_supplier_outstanding_summary(
  p_store_ids uuid[] default null,
  p_supplier_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_scope uuid[];
  v_rows jsonb;
  v_total numeric(14, 2);
begin
  if v_actor is null or not public.has_permission('purchases.view') then
    raise exception 'ليست لديك صلاحية عرض المشتريات' using errcode = 'P0001';
  end if;

  select array_agg(sid) into v_scope from public.user_visible_store_ids(v_actor) sid;
  v_scope := coalesce(v_scope, array[]::uuid[]);
  if p_store_ids is not null then
    if exists (select 1 from unnest(p_store_ids) s where s <> all (v_scope)) then
      raise exception 'أحد الفروع المحددة خارج نطاق صلاحيتك' using errcode = 'P0001';
    end if;
    v_scope := p_store_ids;
  end if;

  with open_invoices as (
    select pi.supplier_id, pi.supplier_name_snapshot, public.purchase_invoice_outstanding(pi.id) as outstanding
    from public.purchase_invoices pi
    where pi.entry_kind = 'invoice'
      and pi.store_id = any (v_scope)
      and (p_supplier_id is null or pi.supplier_id = p_supplier_id)
      and not exists (select 1 from public.purchase_invoices r where r.reverses_invoice_id = pi.id and r.entry_kind = 'reversal')
  ),
  per_supplier as (
    select o.supplier_id, min(o.supplier_name_snapshot) as supplier_name,
           count(*) filter (where o.outstanding > 0) as open_invoices_count,
           coalesce(sum(o.outstanding), 0) as outstanding
    from open_invoices o
    group by o.supplier_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'supplier_id', p.supplier_id,
      'supplier_name', p.supplier_name,
      'open_invoices_count', p.open_invoices_count,
      'outstanding', p.outstanding::text
    ) order by p.outstanding desc), '[]'::jsonb),
    coalesce(sum(p.outstanding), 0)
  into v_rows, v_total
  from per_supplier p
  where p.outstanding <> 0;

  return jsonb_build_object('rows', v_rows, 'summary', jsonb_build_object('outstanding_total', v_total::text));
end;
$$;

revoke execute on function public.get_supplier_outstanding_summary(uuid[], uuid) from public;
grant execute on function public.get_supplier_outstanding_summary(uuid[], uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- get_supplier_statement() — one supplier's documents and payments over a
-- period, with the running liability it leaves behind.
-- ---------------------------------------------------------------------------
create or replace function public.get_supplier_statement(
  p_supplier_id uuid,
  p_date_from date,
  p_date_to date,
  p_store_ids uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
declare
  v_actor uuid := auth.uid();
  v_scope uuid[];
  v_supplier public.suppliers%rowtype;
  v_entries jsonb;
  v_invoiced numeric(14, 2);
  v_paid numeric(14, 2);
  v_opening numeric(14, 2);
  v_closing numeric(14, 2);
  v_current numeric(14, 2);
begin
  if v_actor is null or not public.has_permission('purchases.view') then
    raise exception 'ليست لديك صلاحية عرض المشتريات' using errcode = 'P0001';
  end if;
  if p_date_from is null or p_date_to is null or p_date_from > p_date_to then
    raise exception 'نطاق التاريخ غير صالح' using errcode = 'P0001';
  end if;

  select * into v_supplier from public.suppliers s where s.id = p_supplier_id;
  if v_supplier.id is null then
    raise exception 'المورّد غير موجود' using errcode = 'P0001';
  end if;

  select array_agg(sid) into v_scope from public.user_visible_store_ids(v_actor) sid;
  v_scope := coalesce(v_scope, array[]::uuid[]);
  if p_store_ids is not null then
    if exists (select 1 from unnest(p_store_ids) s where s <> all (v_scope)) then
      raise exception 'أحد الفروع المحددة خارج نطاق صلاحيتك' using errcode = 'P0001';
    end if;
    v_scope := p_store_ids;
  end if;

  -- -------------------------------------------------------------------------
  -- AS-OF-DATE BALANCES. A statement that reports only period movement cannot
  -- answer "what did we owe this supplier on the 30th?", so the opening and
  -- closing balances are computed here from business date alone.
  --
  -- Because every document and payment is an immutable, signed, business-dated
  -- row — and a correction is a NEW row carrying its OWN date (§85) rather
  -- than an edit — a reversal dated after p_date_to contributes to neither
  -- balance. A historical statement therefore cannot be altered by anything
  -- that happens afterwards.
  --
  -- `closing_balance` (as of p_date_to) is deliberately distinct from
  -- `current_balance` (as of today). They differ exactly when activity exists
  -- after p_date_to, and the two are reported side by side so the reader is
  -- never left guessing which one a single number meant.
  -- -------------------------------------------------------------------------
  select coalesce(sum(x.amount), 0) into v_opening
  from (
    select pi.gross_total as amount, pi.business_date
    from public.purchase_invoices pi
    where pi.supplier_id = p_supplier_id and pi.store_id = any (v_scope)
    union all
    select -sp.amount, sp.business_date
    from public.supplier_payments sp
    where sp.supplier_id = p_supplier_id and sp.store_id = any (v_scope)
  ) x
  where x.business_date < p_date_from;

  select coalesce(sum(x.amount), 0) into v_closing
  from (
    select pi.gross_total as amount, pi.business_date
    from public.purchase_invoices pi
    where pi.supplier_id = p_supplier_id and pi.store_id = any (v_scope)
    union all
    select -sp.amount, sp.business_date
    from public.supplier_payments sp
    where sp.supplier_id = p_supplier_id and sp.store_id = any (v_scope)
  ) x
  where x.business_date <= p_date_to;

  select coalesce(sum(x.amount), 0) into v_current
  from (
    select pi.gross_total as amount
    from public.purchase_invoices pi
    where pi.supplier_id = p_supplier_id and pi.store_id = any (v_scope)
    union all
    select -sp.amount
    from public.supplier_payments sp
    where sp.supplier_id = p_supplier_id and sp.store_id = any (v_scope)
  ) x;

  select coalesce(sum(pi.gross_total), 0) into v_invoiced
  from public.purchase_invoices pi
  where pi.supplier_id = p_supplier_id and pi.store_id = any (v_scope)
    and pi.business_date between p_date_from and p_date_to;

  select coalesce(sum(sp.amount), 0) into v_paid
  from public.supplier_payments sp
  where sp.supplier_id = p_supplier_id and sp.store_id = any (v_scope)
    and sp.business_date between p_date_from and p_date_to;

  select coalesce(jsonb_agg(e order by (e ->> 'business_date'), (e ->> 'reference')), '[]'::jsonb) into v_entries
  from (
    select jsonb_build_object(
      'kind', 'invoice', 'entry_kind', pi.entry_kind, 'reference', pi.purchase_number,
      'business_date', pi.business_date, 'amount', pi.gross_total::text,
      'supplier_invoice_number', pi.supplier_invoice_number, 'store_id', pi.store_id
    ) as e
    from public.purchase_invoices pi
    where pi.supplier_id = p_supplier_id and pi.store_id = any (v_scope)
      and pi.business_date between p_date_from and p_date_to
    union all
    select jsonb_build_object(
      'kind', 'payment', 'entry_kind', sp.entry_kind, 'reference', sp.payment_number,
      'business_date', sp.business_date, 'amount', sp.amount::text,
      'payment_mode', sp.payment_mode, 'store_id', sp.store_id
    )
    from public.supplier_payments sp
    where sp.supplier_id = p_supplier_id and sp.store_id = any (v_scope)
      and sp.business_date between p_date_from and p_date_to
  ) t;

  return jsonb_build_object(
    'supplier_id', v_supplier.id,
    'supplier_name', v_supplier.name_ar,
    'supplier_vat_number', v_supplier.vat_number,
    'date_from', p_date_from,
    'date_to', p_date_to,
    'entries', v_entries,
    'summary', jsonb_build_object(
      'opening_balance', v_opening::text,
      'invoiced_total', v_invoiced::text,
      'paid_total', v_paid::text,
      'net_movement', (v_invoiced - v_paid)::text,
      -- Balance owed AS OF p_date_to. opening + net movement, by construction.
      'closing_balance', v_closing::text,
      -- Balance owed AS OF TODAY. Equal to closing_balance only when nothing
      -- happened after p_date_to.
      'current_balance', v_current::text
    )
  );
end;
$$;

revoke execute on function public.get_supplier_statement(uuid, date, date, uuid[]) from public;
grant execute on function public.get_supplier_statement(uuid, date, date, uuid[]) to authenticated;

commit;

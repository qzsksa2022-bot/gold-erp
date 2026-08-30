-- ============================================================================
-- 0154: Phase 6 Integrity Patch 6.1 (11/13): sales_order_adjustments
-- terminal-state immutability + identity-column lock + no-delete DB
-- invariant (items 17/18)
-- ============================================================================
-- Migrations 0001-0153 are unmodified.
--
-- item 17 — an APPROVED or REJECTED record's financial/administrative
-- record should be protected even against a future buggy RPC or a trusted
-- direct write, not merely by every current RPC happening to check status
-- correctly. BEFORE UPDATE: once OLD.status is 'approved' or 'rejected',
-- ANY further UPDATE is rejected outright — reversal (0141/0150) never
-- issues an UPDATE against this table at all (append-only via a separate
-- table), so this never fires against it. BEFORE DELETE: always rejected.
--
-- item 18 — identity columns (id/adjustment_number/sales_order_id/
-- created_at/created_by) are locked at the DB level even for a still-
-- PENDING record — no sanctioned RPC (create/update/set-cost) ever touches
-- them after INSERT, so this is a pure defense-in-depth backstop.
-- ---------------------------------------------------------------------------
create or replace function public.sales_order_adjustments_reject_identity_mutation()
returns trigger
language plpgsql
as $$
begin
  if new.id is distinct from old.id then
    raise exception 'معرّف التعديل/الخدمة غير قابل للتغيير' using errcode = 'P0001';
  end if;
  if new.adjustment_number is distinct from old.adjustment_number then
    raise exception 'رقم التعديل/الخدمة غير قابل للتغيير' using errcode = 'P0001';
  end if;
  if new.sales_order_id is distinct from old.sales_order_id then
    raise exception 'ربط التعديل/الخدمة بعملية البيع غير قابل للتغيير' using errcode = 'P0001';
  end if;
  if new.created_at is distinct from old.created_at then
    raise exception 'تاريخ إنشاء التعديل/الخدمة غير قابل للتعديل' using errcode = 'P0001';
  end if;
  if new.created_by is distinct from old.created_by then
    raise exception 'مُنشئ التعديل/الخدمة غير قابل للتعديل' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.sales_order_adjustments_reject_identity_mutation() is
  'Patch 6.1 item 18 — id/adjustment_number/sales_order_id/created_at/created_by are immutable at the DB level for ANY row regardless of status. No sanctioned RPC ever touches them post-INSERT.';

create trigger sales_order_adjustments_reject_identity_mutation
  before update on public.sales_order_adjustments
  for each row
  execute function public.sales_order_adjustments_reject_identity_mutation();

create or replace function public.sales_order_adjustments_reject_terminal_mutation()
returns trigger
language plpgsql
as $$
begin
  if old.status in ('approved', 'rejected') then
    raise exception 'سجل تعديل/خدمة معتمد أو مرفوض غير قابل للتعديل — التصحيح بعد الاعتماد يتم فقط عبر العكس الإداري الإضافي (sales_order_adjustment_reversals)' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.sales_order_adjustments_reject_terminal_mutation() is
  'Patch 6.1 item 17 — once a record is approved or rejected, ANY further UPDATE is rejected at the DB level, protecting the terminal financial snapshot even against a future buggy RPC or a trusted direct write. reverse_sales_order_adjustment() (0141/0150) never UPDATEs this table — the append-only sales_order_adjustment_reversals row is the ONLY effect of a reversal.';

create trigger sales_order_adjustments_reject_terminal_mutation
  before update on public.sales_order_adjustments
  for each row
  execute function public.sales_order_adjustments_reject_terminal_mutation();

create or replace function public.sales_order_adjustments_reject_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception 'سجلات التعديلات/الخدمات لا تُحذف أبدًا' using errcode = 'P0001';
end;
$$;

comment on function public.sales_order_adjustments_reject_delete() is
  'Patch 6.1 item 17 — unconditional DELETE rejection at the DB level. No RPC in this project ever issues a DELETE against this table.';

create trigger sales_order_adjustments_reject_delete
  before delete on public.sales_order_adjustments
  for each row
  execute function public.sales_order_adjustments_reject_delete();

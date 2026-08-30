-- ============================================================================
-- 0083: Phase 4 — Returns Core (2/10): return_number sequence + generator
-- ============================================================================
-- Migrations 0001-0082 are unmodified. Mirrors generate_sales_order_number()
-- (0059) exactly — a Postgres SEQUENCE is the concurrency-safe primitive
-- (nextval() is atomic, no lock contention, no possibility of two callers
-- ever observing the same value). Global (not per-store), gaps on rollback
-- expected and harmless (same reasoning as 0059).
create sequence public.sales_return_number_seq as bigint start with 1 increment by 1 no cycle;

create or replace function public.generate_sales_return_number()
returns text
language sql
as $$
  select 'RET-' || lpad(nextval('public.sales_return_number_seq')::text, 10, '0');
$$;

comment on function public.generate_sales_return_number() is
  'Issues the next globally-unique, gap-tolerant, concurrency-safe return number (format RET-0000000001 — only global uniqueness/non-forgeability/monotonic-non-reuse are the real contract, mirrors generate_sales_order_number() 0059). VOLATILE (default). Deliberately NOT granted to `authenticated` — only create_sales_return() (0085), itself SECURITY DEFINER, calls this.';

revoke execute on function public.generate_sales_return_number() from public;
-- No GRANT to authenticated — SECURITY DEFINER callers execute as the
-- function owner, which retains EXECUTE implicitly (same pattern as 0059).

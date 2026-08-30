-- ============================================================================
-- 0048: Financial Integrity Patch 2.1 (2/4) — system-managed column lockdown
-- ============================================================================
-- Spec item 3. Foundation already solved exactly this problem for its own
-- tables in 0021 (enforce_system_managed_columns()/enforce_created_by_
-- immutable() — see that migration for the full rationale) but Phase 2's
-- seven new tables (0040-0046) never got the same triggers attached, so
-- `authenticated` could still forge created_by/created_at/updated_by/
-- updated_at on any of them via a direct INSERT/UPDATE carrying those
-- columns explicitly (wherever a direct write path exists at all — see
-- 0047 for the two versioning tables, which no longer have one).
--
-- Both trigger FUNCTIONS already exist (0021, untouched, not redefined
-- here) and are entirely table-agnostic — they only ever reference the
-- literal column names created_at/created_by/updated_at/updated_by (or,
-- for enforce_created_by_immutable(), just created_at/created_by), so
-- attaching them to a new table needs nothing but a `create trigger`.
--
-- Which function per table depends on which columns the table actually has:
--   enforce_system_managed_columns()  -> all four columns present
--   enforce_created_by_immutable()    -> created_at/created_by only (no
--                                        updated_at/updated_by column exists
--                                        on these two by design, see 0042/
--                                        0045 — an "edit" is always a new
--                                        version row, never a mutation)
-- ---------------------------------------------------------------------------
create trigger karats_enforce_system_columns
  before insert or update on public.karats
  for each row
  execute function public.enforce_system_managed_columns();

create trigger daily_gold_prices_enforce_system_columns
  before insert or update on public.daily_gold_prices
  for each row
  execute function public.enforce_system_managed_columns();

create trigger product_categories_enforce_system_columns
  before insert or update on public.product_categories
  for each row
  execute function public.enforce_system_managed_columns();

create trigger payment_methods_enforce_system_columns
  before insert or update on public.payment_methods
  for each row
  execute function public.enforce_system_managed_columns();

create trigger collection_channels_enforce_system_columns
  before insert or update on public.collection_channels
  for each row
  execute function public.enforce_system_managed_columns();

create trigger manufacturing_fee_versions_enforce_created_by
  before insert or update on public.manufacturing_fee_versions
  for each row
  execute function public.enforce_created_by_immutable();

create trigger payment_method_fee_versions_enforce_created_by
  before insert or update on public.payment_method_fee_versions
  for each row
  execute function public.enforce_created_by_immutable();

-- Note: daily_gold_prices already has its own defense-in-depth for
-- created_by specifically via save_daily_gold_price()'s explicit-column
-- upsert (0041) — this trigger is an ADDITIONAL, table-level guarantee that
-- holds even if a future code path ever writes to daily_gold_prices some
-- other way, exactly the same "layered additionally, not a replacement"
-- philosophy 0021 already established for Foundation's own tables.
--
-- manufacturing_fee_versions/payment_method_fee_versions also already gained
-- immutability triggers for their OWN specific value/identity columns in
-- 0047 (karat_id/fee_per_gram/effective_from and payment_method_id/
-- percentage_fee/fixed_fee/effective_from respectively) — this migration's
-- triggers on those same two tables cover the DISJOINT created_at/created_by
-- columns only, so both sets of triggers coexist without overlap.

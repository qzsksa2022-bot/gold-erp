-- ============================================================================
-- 0124: Shipping Integrity Patch 5.1 (3/10): carriers/zones hardening +
-- full audit trail for Shipping Master Data / Rates, with DB-level profit
-- protection on the rate/cost-bearing audit rows
-- ============================================================================
-- Migrations 0001-0123 are unmodified.
--
-- Item 6 — shipping_carriers.code/shipping_zones.code are documented
-- (0113) as "stable machine keys", but nothing stopped a direct UPDATE from
-- changing them (which would silently re-point every historical rate
-- version/shipment referencing that id at a DIFFERENT carrier/zone
-- identity). Locked immutable after creation, same trigger style as every
-- other identity-column lock in this project. created_at/created_by are
-- forced to server truth and pinned immutable via enforce_system_managed_
-- columns() (0021/0048) — the exact same reusable trigger already attached
-- to karats/categories/payment_methods/collection_channels — which also
-- makes updated_by correctly reflect the real actor (previously nullable
-- and settable to anything via a crafted PostgREST write). No DELETE
-- policy existed before and still does not (unchanged).
--
-- Item 7 — shipping_carriers/shipping_zones/shipping_carrier_rate_versions/
-- customer_return_shipping_fee_versions had zero audit trail. The two
-- versioning tables' create/cancel RPCs already gained log_audit_event()
-- calls in 0122 (shipping_rate.create/cancel, customer_return_shipping_fee.
-- create/cancel — genuinely carry base_cost/fee_amount, a sensitive Carrier
-- Cost figure). Carriers/zones are written directly under RLS (not via an
-- RPC — Section 4/5's own access model, unchanged: "direct RLS INSERT/
-- UPDATE ... exactly like karats/categories/payment_methods/collection_
-- channels already work"), so their audit trail is added here as an AFTER
-- INSERT/UPDATE trigger (the only way to guarantee it fires regardless of
-- write path, mirroring audit_table_changes()'s own philosophy, 0016/0024) —
-- a dedicated function rather than reusing audit_table_changes() directly,
-- so a status transition INTO 'disabled' is logged as its own distinct
-- shipping_carrier.disable/shipping_zone.disable action (spec item 7's
-- explicit list) instead of a generic ''.update'' row.
--
-- Profit protection (item 7, second half): shipping_rate.create/cancel and
-- customer_return_shipping_fee.create/cancel carry a real Carrier Cost/
-- Customer Fee figure — gated behind sales.view_profit in audit_logs RLS,
-- extending 0121's fine-grained action-list exactly the same way. shipping_
-- carrier.*/shipping_zone.* carry only name/code/type/status — never a
-- money figure — so they stay UNGATED (audit_logs.view alone is enough),
-- consistent with 0121's own reasoning for shipment.status_add.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- PART A — code immutability (item 6).
-- ---------------------------------------------------------------------------
create or replace function public.enforce_shipping_carrier_code_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.code is distinct from old.code then
    raise exception 'لا يمكن تغيير الرمز الثابت (code) لشركة الشحن بعد إنشائها — هذا الرمز يُستخدم كمرجع دائم في إصدارات التسعير والشحنات' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.enforce_shipping_carrier_code_immutable() is
  'Patch 5.1 item 6/21 — shipping_carriers.code is a permanent machine key once the row is created (referenced by shipping_carrier_rate_versions/shipments); no UPDATE, including a trusted bootstrap context, may change it.';

revoke execute on function public.enforce_shipping_carrier_code_immutable() from public;

create trigger shipping_carriers_enforce_code_immutable
  before update on public.shipping_carriers
  for each row
  execute function public.enforce_shipping_carrier_code_immutable();

create or replace function public.enforce_shipping_zone_code_immutable()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.code is distinct from old.code then
    raise exception 'لا يمكن تغيير الرمز الثابت (code) للمنطقة بعد إنشائها — هذا الرمز يُستخدم كمرجع دائم في إصدارات التسعير والشحنات' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

comment on function public.enforce_shipping_zone_code_immutable() is
  'Patch 5.1 item 6/21 — shipping_zones.code is a permanent machine key. Mirrors enforce_shipping_carrier_code_immutable() exactly.';

revoke execute on function public.enforce_shipping_zone_code_immutable() from public;

create trigger shipping_zones_enforce_code_immutable
  before update on public.shipping_zones
  for each row
  execute function public.enforce_shipping_zone_code_immutable();

-- ---------------------------------------------------------------------------
-- PART B — system-managed columns (item 6/21): created_at/created_by forced
-- to server truth + pinned immutable; updated_at/updated_by always reflect
-- now()/auth.uid() on every write. Table-agnostic function, already exists
-- (0021), untouched here — same trigger karats/categories/payment_methods/
-- collection_channels already carry (0048).
-- ---------------------------------------------------------------------------
create trigger shipping_carriers_enforce_system_columns
  before insert or update on public.shipping_carriers
  for each row
  execute function public.enforce_system_managed_columns();

create trigger shipping_zones_enforce_system_columns
  before insert or update on public.shipping_zones
  for each row
  execute function public.enforce_system_managed_columns();

-- ---------------------------------------------------------------------------
-- PART C — full audit trail for carriers/zones (item 7). Dedicated function
-- (not the generic audit_table_changes()) so a transition into 'disabled'
-- logs its own distinct action name.
-- ---------------------------------------------------------------------------
create or replace function public.audit_shipping_master_data_changes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_entity_type text := TG_ARGV[0];
  v_verb text;
  v_old jsonb;
  v_new jsonb;
begin
  if TG_OP = 'INSERT' then
    v_new := to_jsonb(new);
    v_verb := 'create';
  elsif TG_OP = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    if new.status = 'disabled' and old.status is distinct from 'disabled' then
      v_verb := 'disable';
    else
      v_verb := 'update';
    end if;
  end if;

  perform public.log_audit_event(v_entity_type || '.' || v_verb, v_entity_type, new.id, v_old, v_new, null);

  return new;
end;
$$;

comment on function public.audit_shipping_master_data_changes() is
  'Patch 5.1 item 7 — AFTER INSERT/UPDATE trigger writing shipping_carrier.create/update/disable or shipping_zone.create/update/disable, fired regardless of write path (same "trigger, not RPC-embedded logging" guarantee as audit_table_changes(), 0016/0024). A status transition INTO ''disabled'' is logged as its own distinct .disable action (spec item 7''s explicit action list); any other change (including a re-enable, disabled -> active) logs as .update. Args: (entity_type). Never carries a money figure — carrier/zone rows have none — so it is NOT added to audit_logs'' profit-gated action list.';

revoke execute on function public.audit_shipping_master_data_changes() from public;

create trigger shipping_carriers_audit_trigger
  after insert or update on public.shipping_carriers
  for each row
  execute function public.audit_shipping_master_data_changes('shipping_carrier');

create trigger shipping_zones_audit_trigger
  after insert or update on public.shipping_zones
  for each row
  execute function public.audit_shipping_master_data_changes('shipping_zone');

-- ---------------------------------------------------------------------------
-- PART D — extend audit_logs RLS (item 7, profit protection): add the two
-- Rate-Configuration action families 0122 introduced (each carries base_
-- cost/fee_amount) to 0121's gated action list. Same exact-action-name
-- fine-grained gating style 0121 established (not a blanket prefix) —
-- shipping_carrier.*/shipping_zone.* deliberately excluded (no money field).
-- ---------------------------------------------------------------------------
drop policy if exists audit_logs_select on public.audit_logs;

create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    public.has_permission('audit_logs.view')
    and (
      (
        action not like 'sale.%'
        and action not like 'return.%'
        and action not in (
          'shipment.create', 'shipment.cost_record', 'shipment.cost_correct', 'shipment.charge_correct',
          'shipping_rate.create', 'shipping_rate.cancel',
          'customer_return_shipping_fee.create', 'customer_return_shipping_fee.cancel'
        )
      )
      or public.has_permission('sales.view_profit')
    )
  );

comment on policy audit_logs_select on public.audit_logs is
  'audit_logs.view alone grants every action outside sale.%/return.% (0072/0091), outside the four financial shipment.* actions (0121), and outside the four Rate-Configuration actions added by Patch 5.1 (0124): shipping_rate.create/cancel (carries base_cost) and customer_return_shipping_fee.create/cancel (carries fee_amount) — both genuinely a Carrier Cost/Customer Fee figure. shipment.status_add/shipment.closed_day_override AND shipping_carrier.*/shipping_zone.* (Patch 5.1, 0124 — name/code/type/status only, never a money figure) remain UNGATED. A row matching any gated action additionally requires sales.view_profit — reused verbatim, no separate shipments.view_profit/shipping_rates.view_profit permission. Enforced in RLS, holds against every access path including a raw PostgREST request.';

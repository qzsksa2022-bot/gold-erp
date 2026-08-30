-- Phase 8 Patch 8.1 §39-42 -- Report Shipping Zones Lookup.
--
-- FREEZE: migrations 0001-0212 untouched (§0). This is a genuinely NEW
-- function (0199's "foundation lookups" migration built one for every
-- report-filterable master-data table EXCEPT shipping_zones, even though
-- get_shipping_report() has accepted p_shipping_zone_id since 0203) -- so
-- CREATE FUNCTION, not a replace of anything.
--
-- Gap: the Shipping report's own RPC (get_shipping_report, 0203/0206) has
-- always accepted p_shipping_zone_id, but the app layer had no lookup RPC
-- to populate a "zone" filter dropdown with -- so that filter was silently
-- unreachable from the UI. This migration closes that one missing lookup,
-- mirroring report_shipping_carriers_lookup()/report_adjustment_types_lookup()
-- (0199) byte-for-byte in shape and permission gate.
create function public.report_shipping_zones_lookup()
returns table (id uuid, code text, name_ar text, status text)
language plpgsql
security definer
set search_path = public, pg_temp
stable
as $$
begin
  if auth.uid() is null or not public.has_permission('reports.view') then
    raise exception 'ليست لديك صلاحية عرض التقارير' using errcode = 'P0001';
  end if;
  return query select z.id, z.code, z.name_ar, z.status from public.shipping_zones z order by z.sort_order, z.name_ar;
end;
$$;

comment on function public.report_shipping_zones_lookup() is 'Phase 8 Patch 8.1 §39-42 -- shipping zone filter options (including disabled/historical), closing the one lookup 0199 missed for get_shipping_report()''s existing p_shipping_zone_id filter. Gated on reports.view only.';
revoke execute on function public.report_shipping_zones_lookup() from public;
grant execute on function public.report_shipping_zones_lookup() to authenticated;

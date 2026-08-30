-- ============================================================================
-- 0194: Phase 7 — Final Integrity Hotfix 7.1.1 (3/N): settlement_route_fee_
-- for_route_on_date() must not stay a public authenticated RPC (§6).
-- ============================================================================
-- Migrations 0001-0193 are FROZEN.
--
-- §6 (CRITICAL) — settlement_route_fee_for_route_on_date(uuid, date) (0171)
-- is SECURITY DEFINER with `grant execute ... to authenticated` and NO
-- permission check inside its own body — any authenticated caller with the
-- route's UUID could call it directly over PostgREST and read raw
-- fee-strategy/percentage/fixed-fee/batch-fee/cod-reversal-policy
-- configuration, entirely bypassing settlement_route_fee_versions' own RLS
-- (gated on settlements.view_financials, migration 0170) and Financial
-- Privacy generally.
--
-- Fix: REVOKE EXECUTE from PUBLIC and authenticated. Every legitimate
-- caller — preview_settlement_batch() (0185/0195), finalize_settlement_
-- batch() (0185), create_settlement_route_fee_version()/create_settlement_
-- route_fee_version() (0171/0190) — is itself SECURITY DEFINER, so it calls
-- this helper as the function OWNER (a superuser role during migration
-- application), which bypasses EXECUTE privilege checks entirely; none of
-- those call sites need (or receive) any new grant to keep working. No test
-- or script in this project calls this function directly via service_role
-- either (confirmed by inspection — every reference goes through one of the
-- SECURITY DEFINER RPCs above), so no service_role grant is added; one can
-- be added later, narrowly, if a genuine operational need arises.
-- ============================================================================
revoke execute on function public.settlement_route_fee_for_route_on_date(uuid, date) from public;
revoke execute on function public.settlement_route_fee_for_route_on_date(uuid, date) from authenticated;

comment on function public.settlement_route_fee_for_route_on_date(uuid, date) is
  'Hotfix 7.1.1 (§6) — INTERNAL ONLY as of this migration (EXECUTE revoked from PUBLIC and authenticated; 0171''s original grant to authenticated was a real Financial Privacy bypass — raw fee-strategy/percentage/fixed-fee/batch-fee/cod-reversal-policy configuration readable by ANY authenticated actor holding a route UUID, entirely outside settlement_route_fee_versions'' own settlements.view_financials-gated RLS, 0170). Every legitimate caller (preview_settlement_batch()/finalize_settlement_batch()/create_settlement_route_fee_version(), all SECURITY DEFINER) keeps working unchanged — it calls this helper as the function owner, which bypasses EXECUTE checks. Resolves the historical fee-version configuration covering a route on a given date; empty result means no fee version covers that date.';

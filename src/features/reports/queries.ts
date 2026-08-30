import "server-only";

import { createClient } from "@/lib/supabase/server";

/**
 * Phase 8 — Reports, Dashboard & Exports (migrations 0199-0204).
 *
 * Every get_*_report()/get_*_management_report() RPC returns ONE atomic
 * jsonb payload shaped `{ total_count, limit, offset, summary, rows[] }`
 * (§92/§94 — summary and its paginated page always come from the SAME
 * MVCC snapshot). get_dashboard_summary()/get_dashboard_trends() return
 * their own differently-shaped jsonb objects (see features/dashboard).
 *
 * Every money/weight field in `summary`/`rows` is a TEXT string (§40/§41 —
 * never parse it with parseFloat/Number for anything that feeds another
 * calculation; format-only display via src/lib/money.ts is fine).
 *
 * A field simply being ABSENT from `summary`/a row (not `null`) means the
 * caller lacks the permission that would reveal it (§79) — component code
 * must check with `"field" in summary`, never `summary.field == null`,
 * to tell "redacted" apart from "genuinely zero".
 */
export interface ReportEnvelope {
  total_count: number;
  limit: number;
  offset: number;
  summary: Record<string, unknown>;
  rows: Record<string, unknown>[];
  /** Present on movements-ledger / dual-basis reports only — see §83. */
  basis?: string;
  row_basis?: string;
  summary_basis?: string;
}

/**
 * Hotfix 8.1.2 §24-25 — get_payment_methods_report()'s envelope is NOT a
 * single-schema ReportEnvelope: `total_count`/`limit`/`offset`/`summary`/
 * `rows` (the Sales section) are built ONLY inside `if v_can_sales then...`
 * (0207/0217) — an actor lacking sales.view gets an envelope where those
 * keys are entirely ABSENT (§79 true key-absence), not merely empty/zero.
 * `limit`/`offset` ARE always present (part of the unconditional base
 * envelope) — only `total_count`/`summary`/`rows` are conditional. The
 * Actual Refund Cash (refund_summary/refund_rows) and Settlements
 * (settlement_summary/settlement_rows) sections are each independently
 * gated the same way on returns.view/settlements.view respectively.
 * Component code (e.g. a `<Pagination>` footer) must therefore check
 * `typeof envelope.total_count === "number"` before reading it — treating
 * this shape as a plain ReportEnvelope silently produced `total={undefined}`
 * for any actor without sales.view (§24's own bug).
 */
export interface PaymentMethodsReportEnvelope {
  date_from: string;
  date_to: string;
  limit: number;
  offset: number;
  total_count?: number;
  summary?: Record<string, unknown>;
  rows?: Record<string, unknown>[];
  refund_summary?: Record<string, unknown>;
  refund_rows?: Record<string, unknown>[];
  settlement_summary?: Record<string, unknown>;
  settlement_rows?: Record<string, unknown>[];
}

export interface ReportBaseFilters {
  date_from: string;
  date_to: string;
  store_ids?: string[];
  search?: string;
  sort?: string;
  page: number;
  /**
   * Patch 8.1 §11-14/§60 — overrides the default screen page size. The
   * export route (`api/reports/export/route.ts`) sets this to
   * `EXPORT_MAX_ROWS` so the export dataset is fetched in ONE RPC call —
   * literally the same `fetch()` the screen uses, just with a larger
   * `p_limit` — never a second, divergently-computed export query. Every
   * `get_*_report()` RPC's own `total_count` is always the TRUE total
   * match count (computed before its own LIMIT/OFFSET), independent of
   * this value, so the caller can always tell whether everything came
   * back in this one call by comparing `envelope.total_count` to the
   * `limit` it requested.
   */
  limit?: number;
}

const PAGE_SIZE = 50;

/**
 * Patch 8.1 §11-14/§60 — the documented, tested safety maximum for a
 * single export. Matches the `v_limit` cap every touched report RPC now
 * enforces server-side (500 -> 5000 across 0206/0207/0208/0209/0210/0211/
 * 0212) — raising this constant without raising every RPC's own cap (or
 * vice versa) would silently reintroduce truncation, so the two are kept
 * in lockstep by convention (documented here and in each migration's own
 * header comment) rather than by a shared code constant (SQL and
 * TypeScript cannot share one literal across the RPC boundary).
 */
export const EXPORT_MAX_ROWS = 5000;

function offsetFor(page: number, limit: number = PAGE_SIZE): number {
  return (Math.max(1, page) - 1) * limit;
}

// ---------------------------------------------------------------------------
// Dashboard (§12-§20) — see src/features/dashboard/queries.ts for the two
// dedicated wrappers (get_dashboard_summary/get_dashboard_trends); kept
// there rather than here so the Dashboard feature stays self-contained.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Filter-dropdown lookups (§49) — every one gated on reports.view alone.
// ---------------------------------------------------------------------------
export async function getReportVisibleStores() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_visible_stores_lookup");
  if (error) throw error;
  return data ?? [];
}

export async function getReportCategories() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_categories_lookup");
  if (error) throw error;
  return data ?? [];
}

export async function getReportKarats() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_karats_lookup");
  if (error) throw error;
  return data ?? [];
}

export async function getReportPaymentMethods() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_payment_methods_lookup");
  if (error) throw error;
  return data ?? [];
}

export async function getReportCollectionChannels() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_collection_channels_lookup");
  if (error) throw error;
  return data ?? [];
}

export async function getReportShippingCarriers() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_shipping_carriers_lookup");
  if (error) throw error;
  return data ?? [];
}

// Patch 8.1 §39-42 — closes the one lookup 0199 missed for
// get_shipping_report()'s existing p_shipping_zone_id filter (0213).
export async function getReportShippingZones() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_shipping_zones_lookup");
  if (error) throw error;
  return data ?? [];
}

export async function getReportAdjustmentTypes() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_adjustment_types_lookup");
  if (error) throw error;
  return data ?? [];
}

export async function getReportSettlementRoutes() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_settlement_routes_lookup");
  if (error) throw error;
  return data ?? [];
}

export async function getReportEmployees() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("report_employees_lookup");
  if (error) throw error;
  return data ?? [];
}

// ---------------------------------------------------------------------------
// §21 Sales Report
// ---------------------------------------------------------------------------
export interface SalesReportFilters extends ReportBaseFilters {
  employee_id?: string;
  category_id?: string;
  karat_id?: string;
  payment_method_id?: string;
  collection_channel_id?: string;
}

export async function getSalesReport(f: SalesReportFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_sales_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_employee_id: f.employee_id ?? null,
    p_category_id: f.category_id ?? null,
    p_karat_id: f.karat_id ?? null,
    p_payment_method_id: f.payment_method_id ?? null,
    p_collection_channel_id: f.collection_channel_id ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §22 Items Report
// ---------------------------------------------------------------------------
export interface ItemsReportFilters extends ReportBaseFilters {
  category_id?: string;
  karat_id?: string;
  /** Hotfix 8.1.2 §34-36 — bound to sales_orders.salesperson_id. */
  salesperson_id?: string;
}

export async function getItemsReport(f: ItemsReportFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_items_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_category_id: f.category_id ?? null,
    p_karat_id: f.karat_id ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
    p_salesperson_id: f.salesperson_id ?? null,
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §23 Categories Report
// ---------------------------------------------------------------------------
export interface CategoriesReportFilters extends ReportBaseFilters {
  karat_id?: string;
  /** Hotfix 8.1.1 §41-42 — direct-children drill-down filter (0211's product_categories.parent_id chain). */
  parent_id?: string;
}

export async function getCategoriesReport(f: CategoriesReportFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_categories_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_karat_id: f.karat_id ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
    p_parent_id: f.parent_id ?? null,
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §24 Karats Report
// ---------------------------------------------------------------------------
export interface KaratsReportFilters extends ReportBaseFilters {
  category_id?: string;
}

export async function getKaratsReport(f: KaratsReportFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_karats_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_category_id: f.category_id ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §25 Employees Report
// ---------------------------------------------------------------------------
export async function getEmployeesReport(f: ReportBaseFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_employees_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §26 Payment Methods Report — Hotfix 8.1.1 §6-10: THREE independent
// sections (Sales/rows, Actual Refund Cash/refund_rows, Settlements/
// settlement_rows) — see @/features/reports/export/presentation.ts for how
// the raw envelope this returns is resolved into renderable sections.
// ---------------------------------------------------------------------------
export interface PaymentMethodsReportFilters extends ReportBaseFilters {
  /** Filters the Actual Refund Cash section by the refund EVENT's own refund_method_id (has no effect on the Sales/Settlements sections). */
  refund_method_id?: string;
  /** Hotfix 8.1.2 §31-33 — filters the Sales section by the sale's own payment_method_id, and the Settlements section by route payment_method_id. Distinct from refund_method_id (never the same column/section) — has no effect on Actual Refund Cash. */
  payment_method_id?: string;
  /** Filters the Sales section by (payment_method_id, collection_channel_id) pair's channel, and the Settlements section by route collection_channel_id. */
  collection_channel_id?: string;
}

export async function getPaymentMethodsReport(f: PaymentMethodsReportFilters): Promise<PaymentMethodsReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_payment_methods_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
    p_refund_method_id: f.refund_method_id ?? null,
    p_collection_channel_id: f.collection_channel_id ?? null,
    p_payment_method_id: f.payment_method_id ?? null,
  });
  if (error) throw error;
  return data as unknown as PaymentMethodsReportEnvelope;
}

// ---------------------------------------------------------------------------
// §27 Collection Channels Report
// ---------------------------------------------------------------------------
export async function getCollectionChannelsReport(f: ReportBaseFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_collection_channels_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §28 Returns Report — movements ledger (§84/§85/§83 basis="movements_during_period").
// ---------------------------------------------------------------------------
export interface ReturnsReportFilters extends ReportBaseFilters {
  scenario?: string;
  status?: string;
  payment_method_id?: string;
  collection_channel_id?: string;
  /** Patch 8.1 §26-29 — 'business_effect' (default) | 'actual_cash'; unrecognized/omitted falls back to the RPC's own default. */
  basis?: string;
  /** Patch 8.1 §39-42 — under `business_effect` matches the sale's own `payment_method_id`; under `actual_cash` matches the refund EVENT's own `refund_method_id` (never the same column, §26-29's core distinction). */
  refund_method_id?: string;
  salesperson_id?: string;
  original_sale_date_from?: string;
  original_sale_date_to?: string;
  /** 'not_applicable' | 'pending' | 'finalized_matched' | 'finalized_with_variance' — a CURRENT operational indicator, never a business date (§26-29). */
  refund_reconciliation_state?: string;
}

export async function getReturnsReport(f: ReturnsReportFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_returns_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_scenario: f.scenario ?? null,
    p_status: f.status ?? null,
    p_payment_method_id: f.payment_method_id ?? null,
    p_collection_channel_id: f.collection_channel_id ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
    p_basis: f.basis ?? null,
    p_refund_method_id: f.refund_method_id ?? null,
    p_salesperson_id: f.salesperson_id ?? null,
    p_original_sale_date_from: f.original_sale_date_from ?? null,
    p_original_sale_date_to: f.original_sale_date_to ?? null,
    p_refund_reconciliation_state: f.refund_reconciliation_state ?? null,
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §29 Shipping Report — Current Effective basis (§83).
// ---------------------------------------------------------------------------
export interface ShippingReportFilters extends ReportBaseFilters {
  carrier_id?: string;
  shipping_zone_id?: string;
  direction?: string;
  current_status?: string;
  is_cod?: boolean;
  /** Patch 8.1 §7-8 — 'current_effective' (default) | 'movements_during_period'; unrecognized/omitted falls back to the RPC's own default. */
  basis?: string;
}

export async function getShippingReport(f: ShippingReportFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_shipping_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_carrier_id: f.carrier_id ?? null,
    p_shipping_zone_id: f.shipping_zone_id ?? null,
    p_direction: f.direction ?? null,
    p_current_status: f.current_status ?? null,
    p_is_cod: f.is_cod ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
    p_basis: f.basis ?? null,
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §30 COD Report — Current Effective basis (§83).
// ---------------------------------------------------------------------------
export interface CodReportFilters extends ReportBaseFilters {
  cod_collection_state?: string;
  /** Patch 8.1 §30-32 — 'current_effective' (default) | 'collection_transitions'; unrecognized/omitted falls back to the RPC's own default. */
  basis?: string;
}

export async function getCodReport(f: CodReportFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_cod_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_cod_collection_state: f.cod_collection_state ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
    p_basis: f.basis ?? null,
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §32 Adjustments Report — movements ledger (§84/§85/§83 basis="movements_during_period").
// ---------------------------------------------------------------------------
export interface AdjustmentsReportFilters extends ReportBaseFilters {
  adjustment_type_id?: string;
  /** Hotfix 8.1.1 §32-35 — the ORIGINAL sale's own store (so.store_id) — independent of processing_store_id below, never OR-merged (§33). */
  original_sale_store_id?: string;
  /** The adjustment's own processing store (a.processing_store_id) — independent of original_sale_store_id above (§33). */
  processing_store_id?: string;
  /** The adjustment's OWN payment_method_id/collection_channel_id (a.*, not the original sale's). */
  payment_method_id?: string;
  collection_channel_id?: string;
  /** A real, end-to-end typed boolean — `false` must reach the RPC as `false`, never dropped as falsy (§34). */
  participates_in_settlement?: boolean;
  /** Which ledger movement kind this row represents: 'approved' | 'reversed' (the movement's own effective status, not a row-per-adjustment status). */
  movement_type?: string;
  created_by?: string;
  approved_by?: string;
}

export async function getAdjustmentsReport(f: AdjustmentsReportFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_adjustments_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_adjustment_type_id: f.adjustment_type_id ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
    p_original_sale_store_id: f.original_sale_store_id ?? null,
    p_processing_store_id: f.processing_store_id ?? null,
    p_payment_method_id: f.payment_method_id ?? null,
    p_collection_channel_id: f.collection_channel_id ?? null,
    p_participates_in_settlement: f.participates_in_settlement ?? null,
    p_movement_type: f.movement_type ?? null,
    p_created_by: f.created_by ?? null,
    p_approved_by: f.approved_by ?? null,
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §33 Settlements Report — dual basis (§83: rows=current_effective,
// summary=movements_during_period).
// ---------------------------------------------------------------------------
export interface SettlementsReportFilters extends ReportBaseFilters {
  settlement_route_id?: string;
  status?: string;
  /** Patch 8.1 §41 — 'payment_collection' | 'cod_carrier', read from the batch's own `route_kind_snapshot` (0172), never a join to `settlement_routes`. */
  route_kind?: string;
  payment_method_id?: string;
  collection_channel_id?: string;
  shipping_carrier_id?: string;
  /** Patch 8.1 §41 — the correct, WORKING "Cancelled" filter: `status` can structurally never be 'cancelled' (0172's CHECK constraint), so `effective_status` is computed server-side as `case when is_cancelled then 'cancelled' else status end`. Prefer this over `status` going forward. */
  effective_status?: string;
  /** Patch 8.1 §41 / Hotfix 8.1.1 §28-31 — financial; gated behind `settlements.view_financials`. An actor lacking that permission who still sends this filter is EXPLICITLY REJECTED by the RPC (a thrown exception), never silently ignored/dropped — a silently-ignored filter would misleadingly imply "no variance filter was requested" instead of "you are not allowed to use this filter". */
  has_variance?: boolean;
  provider_statement_reference?: string;
}

export async function getSettlementsReport(f: SettlementsReportFilters): Promise<ReportEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_settlements_report", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_settlement_route_id: f.settlement_route_id ?? null,
    p_status: f.status ?? null,
    p_search: f.search ?? null,
    p_sort: f.sort ?? null,
    p_limit: f.limit ?? PAGE_SIZE,
    p_offset: offsetFor(f.page, f.limit ?? PAGE_SIZE),
    p_route_kind: f.route_kind ?? null,
    p_payment_method_id: f.payment_method_id ?? null,
    p_collection_channel_id: f.collection_channel_id ?? null,
    p_shipping_carrier_id: f.shipping_carrier_id ?? null,
    p_effective_status: f.effective_status ?? null,
    p_has_variance: f.has_variance ?? null,
    p_provider_statement_reference: f.provider_statement_reference ?? null,
  });
  if (error) throw error;
  return data as unknown as ReportEnvelope;
}

// ---------------------------------------------------------------------------
// §34-§37 Daily/Weekly/Monthly/Yearly Management Reports — each delegates to
// get_dashboard_summary() server-side (see 0204's own comment) and returns
// that SAME jsonb shape plus a small period-identity envelope, so these
// wrappers reuse the Dashboard's own type on the call site.
// ---------------------------------------------------------------------------
export async function getDailyManagementReport(date?: string, storeIds?: string[]) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_daily_management_report", {
    p_date: date ?? null,
    p_store_ids: storeIds ?? null,
  });
  if (error) throw error;
  return data as unknown as Record<string, unknown>;
}

export async function getWeeklyManagementReport(referenceDate?: string, storeIds?: string[]) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_weekly_management_report", {
    p_reference_date: referenceDate ?? null,
    p_store_ids: storeIds ?? null,
  });
  if (error) throw error;
  return data as unknown as Record<string, unknown>;
}

export async function getMonthlyManagementReport(year?: number, month?: number, storeIds?: string[]) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_monthly_management_report", {
    p_year: year ?? null,
    p_month: month ?? null,
    p_store_ids: storeIds ?? null,
  });
  if (error) throw error;
  return data as unknown as Record<string, unknown>;
}

export async function getYearlyManagementReport(year?: number, storeIds?: string[]) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_yearly_management_report", {
    p_year: year ?? null,
    p_store_ids: storeIds ?? null,
  });
  if (error) throw error;
  return data as unknown as Record<string, unknown>;
}

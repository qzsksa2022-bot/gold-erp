import "server-only";

import { createClient } from "@/lib/supabase/server";

/**
 * Phase 11 — Purchases & Suppliers read layer. Every figure here is already
 * summed server-side from the append-only ledgers (migrations 0238-0240) and
 * arrives as TEXT — nothing in this file recomputes or re-parses a monetary
 * value.
 *
 * Note what is deliberately ABSENT: there is no recoverable-input-VAT figure
 * anywhere in this layer, because Phase 11 stores tax data without deciding
 * eligibility. `vat_total` is the VAT the supplier charged, nothing more.
 */

export const PURCHASES_PAGE_SIZE = 50;

export type PurchasePaymentStatus = "unpaid" | "partial" | "paid" | "reversed" | "reversal";

export interface SupplierRow {
  id: string;
  code: string;
  name_ar: string;
  name_en: string | null;
  vat_number: string | null;
  contact_person: string | null;
  phone: string | null;
  email: string | null;
  status: "active" | "disabled";
  notes: string | null;
  row_version: number;
}

export interface PurchaseInvoiceRow {
  id: string;
  purchase_number: string;
  supplier_id: string;
  supplier_name: string;
  supplier_vat_number: string | null;
  supplier_invoice_number: string | null;
  supplier_invoice_date: string | null;
  store_id: string;
  store_name: string;
  business_date: string;
  entry_kind: "invoice" | "reversal";
  net_total: string;
  vat_total: string;
  gross_total: string;
  outstanding: string;
  payment_status: PurchasePaymentStatus;
  is_reversed: boolean;
  reverses_invoice_id: string | null;
  notes: string | null;
}

export interface PurchaseInvoicesEnvelope {
  rows: PurchaseInvoiceRow[];
  total_count: number;
  limit: number;
  offset: number;
  date_from: string;
  date_to: string;
  summary: {
    documents_count: number;
    net_total: string;
    vat_total: string;
    gross_total: string;
    paid_total: string;
    outstanding_total: string;
  };
}

export interface PurchaseInvoiceLine {
  id: string;
  inventory_item_id: string;
  sku: string;
  item_name: string;
  quantity: string;
  unit_net_cost: string;
  tax_treatment: "standard" | "zero_rated" | "exempt" | "out_of_scope";
  tax_rate_percent: string;
  net_amount: string;
  vat_amount: string;
  gross_amount: string;
  /** The Phase 9 movement this line posted. Proof that stock and document moved together. */
  inventory_movement_id: string;
}

export interface SupplierPaymentEntry {
  id: string;
  payment_number: string;
  business_date: string;
  entry_kind: "payment" | "reversal";
  amount: string;
  payment_mode: string;
  payment_reference: string | null;
  reverses_payment_id: string | null;
  reversal_reason: string | null;
  is_reversed: boolean;
}

export interface PurchaseInvoiceDetail {
  id: string;
  purchase_number: string;
  supplier_id: string;
  supplier_name: string;
  supplier_vat_number: string | null;
  supplier_invoice_number: string | null;
  supplier_invoice_date: string | null;
  store_id: string;
  business_date: string;
  entry_kind: "invoice" | "reversal";
  net_total: string;
  vat_total: string;
  gross_total: string;
  outstanding: string;
  is_reversed: boolean;
  reverses_invoice_id: string | null;
  reversal_reason: string | null;
  notes: string | null;
  lines: PurchaseInvoiceLine[];
  payments: SupplierPaymentEntry[];
}

export interface SupplierOutstandingRow {
  supplier_id: string;
  supplier_name: string;
  open_invoices_count: number;
  outstanding: string;
}

export interface SupplierOutstandingEnvelope {
  rows: SupplierOutstandingRow[];
  summary: { outstanding_total: string };
}

export interface SupplierStatementEntry {
  kind: "invoice" | "payment";
  entry_kind: string;
  reference: string;
  business_date: string;
  amount: string;
  supplier_invoice_number?: string | null;
  payment_mode?: string | null;
  store_id: string;
}

export interface SupplierStatement {
  supplier_id: string;
  supplier_name: string;
  supplier_vat_number: string | null;
  date_from: string;
  date_to: string;
  entries: SupplierStatementEntry[];
  summary: {
    /** Owed before date_from. */
    opening_balance: string;
    invoiced_total: string;
    paid_total: string;
    net_movement: string;
    /**
     * Owed AS OF date_to. Because every entry is immutable and business-dated,
     * and a correction is a new row carrying its own date (§85), this figure
     * cannot be changed by anything that happens after date_to — a statement
     * reads the same tomorrow as it did the day it was issued.
     */
    closing_balance: string;
    /** Owed AS OF TODAY. Differs from closing_balance exactly when there has been activity since date_to. */
    current_balance: string;
  };
}

export interface PurchaseInvoicesFilters {
  date_from: string;
  date_to: string;
  store_ids?: string[];
  supplier_id?: string;
  entry_kind?: string;
  payment_status?: string;
  search?: string;
  page?: number;
  limit?: number;
}

function offsetFor(page: number | undefined, limit: number): number {
  return Math.max(0, ((page ?? 1) - 1) * limit);
}

export async function getPurchaseInvoices(f: PurchaseInvoicesFilters): Promise<PurchaseInvoicesEnvelope> {
  const supabase = await createClient();
  const limit = f.limit ?? PURCHASES_PAGE_SIZE;
  const { data, error } = await supabase.rpc("list_purchase_invoices", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_supplier_id: f.supplier_id ?? null,
    p_entry_kind: f.entry_kind ?? null,
    p_payment_status: f.payment_status ?? null,
    p_search: f.search ?? null,
    p_limit: limit,
    p_offset: offsetFor(f.page, limit),
  });
  if (error) throw error;
  return data as unknown as PurchaseInvoicesEnvelope;
}

export async function getPurchaseInvoice(invoiceId: string): Promise<PurchaseInvoiceDetail> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_purchase_invoice", { p_invoice_id: invoiceId });
  if (error) throw error;
  return data as unknown as PurchaseInvoiceDetail;
}

export async function getSuppliers(search?: string, status?: string): Promise<{ rows: SupplierRow[]; total_count: number }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("list_suppliers", {
    p_search: search ?? null,
    p_status: status ?? null,
    p_limit: 200,
    p_offset: 0,
  });
  if (error) throw error;
  return data as unknown as { rows: SupplierRow[]; total_count: number };
}

/** Active suppliers only — what the new-purchase form may offer. */
export async function getActiveSuppliers(): Promise<SupplierRow[]> {
  const { rows } = await getSuppliers(undefined, "active");
  return rows;
}

export async function getSupplierOutstanding(storeIds?: string[], supplierId?: string): Promise<SupplierOutstandingEnvelope> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_supplier_outstanding_summary", {
    p_store_ids: storeIds ?? null,
    p_supplier_id: supplierId ?? null,
  });
  if (error) throw error;
  return data as unknown as SupplierOutstandingEnvelope;
}

export async function getSupplierStatement(
  supplierId: string,
  dateFrom: string,
  dateTo: string,
  storeIds?: string[],
): Promise<SupplierStatement> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_supplier_statement", {
    p_supplier_id: supplierId,
    p_date_from: dateFrom,
    p_date_to: dateTo,
    p_store_ids: storeIds ?? null,
  });
  if (error) throw error;
  return data as unknown as SupplierStatement;
}

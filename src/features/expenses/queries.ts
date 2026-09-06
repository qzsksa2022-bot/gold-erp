import "server-only";

import { createClient } from "@/lib/supabase/server";

/**
 * Phase 10 — Store Expenses read layer. Every figure here is already summed
 * server-side from the append-only ledger (migration 0234/0235) and arrives
 * as TEXT — nothing in this file recomputes or re-parses a monetary value.
 */

export const EXPENSES_PAGE_SIZE = 50;

export interface StoreExpenseRow {
  id: string;
  expense_number: string;
  store_id: string;
  store_name: string;
  expense_category_id: string;
  category_code: string;
  category_name: string;
  business_date: string;
  entry_kind: "expense" | "reversal";
  amount: string;
  description: string | null;
  reverses_expense_id: string | null;
  reversal_reason: string | null;
  is_reversed: boolean;
}

export interface StoreExpensesEnvelope {
  rows: StoreExpenseRow[];
  total_count: number;
  limit: number;
  offset: number;
  date_from: string;
  date_to: string;
  summary: {
    entries_count: number;
    gross_expenses_total: string;
    reversals_total: string;
    operating_expenses_total: string;
  };
}

export interface ExpenseCategoryRow {
  id: string;
  code: string;
  name_ar: string;
  name_en: string | null;
  status: "active" | "disabled";
  notes: string | null;
  row_version: number;
}

export interface StoreExpensesFilters {
  date_from: string;
  date_to: string;
  store_ids?: string[];
  expense_category_id?: string;
  entry_kind?: string;
  search?: string;
  page?: number;
  limit?: number;
}

function offsetFor(page: number | undefined, limit: number): number {
  return Math.max(0, ((page ?? 1) - 1) * limit);
}

export async function getStoreExpenses(f: StoreExpensesFilters): Promise<StoreExpensesEnvelope> {
  const supabase = await createClient();
  const limit = f.limit ?? EXPENSES_PAGE_SIZE;
  const { data, error } = await supabase.rpc("list_store_expenses", {
    p_date_from: f.date_from,
    p_date_to: f.date_to,
    p_store_ids: f.store_ids ?? null,
    p_expense_category_id: f.expense_category_id ?? null,
    p_entry_kind: f.entry_kind ?? null,
    p_search: f.search ?? null,
    p_limit: limit,
    p_offset: offsetFor(f.page, limit),
  });
  if (error) throw error;
  return data as unknown as StoreExpensesEnvelope;
}

export async function getExpenseCategories(search?: string, status?: string): Promise<{ rows: ExpenseCategoryRow[]; total_count: number }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("list_expense_categories", {
    p_search: search ?? null,
    p_status: status ?? null,
    p_limit: 200,
    p_offset: 0,
  });
  if (error) throw error;
  return data as unknown as { rows: ExpenseCategoryRow[]; total_count: number };
}

/** Active categories only — what the record-expense form may offer. */
export async function getActiveExpenseCategories(): Promise<ExpenseCategoryRow[]> {
  const { rows } = await getExpenseCategories(undefined, "active");
  return rows;
}

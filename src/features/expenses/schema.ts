import { z } from "zod";
import { hasMaxDecimalPlaces, isPositiveDecimal } from "@/lib/decimal";

// Phase 10 (Store Expenses Core) — every monetary input here stays a STRING
// all the way to the RPC call, never parsed through Number()/parseFloat() at
// any point in this file or in actions.ts, exactly mirroring
// src/features/inventory/schema.ts and src/features/settlements/schema.ts.
// Totals are never computed client-side — they are always whatever
// list_store_expenses()/get_dashboard_summary_with_expenses() (migrations
// 0235/0236) return, already summed server-side from the append-only ledger.

const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined));

const rowVersionSchema = z.number({ required_error: "إصدار السجل مطلوب" }).int().nonnegative();

/** Strictly positive amount with at most 2 decimal places (mirrors store_expenses.amount numeric(14,2), migration 0234, and record_store_expense()'s own positive-amount guard). */
const positiveAmountSchema = z
  .string({ required_error: "المبلغ مطلوب" })
  .trim()
  .refine((v) => isPositiveDecimal(v), "المبلغ يجب أن يكون رقمًا أكبر من صفر")
  .refine((v) => hasMaxDecimalPlaces(v, 2), "المبلغ يجب ألا يتجاوز منزلتين عشريتين");

// ---------------------------------------------------------------------------
// create_expense_category() (migration 0235) — code is permanent once
// created, only accepted on create, never on update (mirrors
// adjustment_types.code and inventory_items.sku).
// ---------------------------------------------------------------------------
export const createExpenseCategorySchema = z.object({
  code: z
    .string({ required_error: "رمز التصنيف مطلوب" })
    .trim()
    .min(1, "رمز التصنيف مطلوب")
    .max(100, "رمز التصنيف طويل جدًا"),
  name_ar: z.string({ required_error: "اسم التصنيف مطلوب" }).trim().min(1, "اسم التصنيف مطلوب").max(200),
  name_en: optionalText(200),
  notes: optionalText(1000),
});

export type CreateExpenseCategoryInput = z.infer<typeof createExpenseCategorySchema>;

// ---------------------------------------------------------------------------
// update_expense_category() (migration 0235) — code intentionally NOT part of
// this schema. row_version is REQUIRED: the RPC rejects a NULL expected
// version outright, because `row_version <> NULL` would silently bypass the
// optimistic-concurrency check entirely.
// ---------------------------------------------------------------------------
export const updateExpenseCategorySchema = z.object({
  id: z.string().uuid(),
  row_version: rowVersionSchema,
  name_ar: z.string({ required_error: "اسم التصنيف مطلوب" }).trim().min(1, "اسم التصنيف مطلوب").max(200),
  name_en: optionalText(200),
  notes: optionalText(1000),
});

export type UpdateExpenseCategoryInput = z.infer<typeof updateExpenseCategorySchema>;

// ---------------------------------------------------------------------------
// record_store_expense() (migration 0235) — the GROSS paid amount only. No
// recoverable input-VAT handling exists in Phase 10 by design.
// ---------------------------------------------------------------------------
export const recordStoreExpenseSchema = z.object({
  store_id: z.string({ required_error: "الفرع مطلوب" }).uuid("فرع غير صالح"),
  expense_category_id: z.string({ required_error: "التصنيف مطلوب" }).uuid("تصنيف غير صالح"),
  amount: positiveAmountSchema,
  business_date: z.string({ required_error: "التاريخ مطلوب" }).trim().min(1, "التاريخ مطلوب"),
  description: optionalText(1000),
  closed_day_reason: optionalText(1000),
});

export type RecordStoreExpenseInput = z.infer<typeof recordStoreExpenseSchema>;

// ---------------------------------------------------------------------------
// reverse_store_expense() (migration 0235) — the ONLY correction path; a
// posted expense is never updated or deleted. The reversal carries its OWN
// business date (§85 Event Date).
// ---------------------------------------------------------------------------
export const reverseStoreExpenseSchema = z.object({
  expense_id: z.string({ required_error: "المصروف مطلوب" }).uuid("مصروف غير صالح"),
  reason: z.string({ required_error: "سبب العكس مطلوب" }).trim().min(1, "سبب العكس مطلوب").max(1000),
  business_date: z.string({ required_error: "تاريخ العكس مطلوب" }).trim().min(1, "تاريخ العكس مطلوب"),
  closed_day_reason: optionalText(1000),
});

export type ReverseStoreExpenseInput = z.infer<typeof reverseStoreExpenseSchema>;

// ---------------------------------------------------------------------------
// list_store_expenses() filters.
// ---------------------------------------------------------------------------
export const storeExpensesListFiltersSchema = z.object({
  date_from: z.string().optional(),
  date_to: z.string().optional(),
  store_id: z.string().uuid().optional(),
  expense_category_id: z.string().uuid().optional(),
  entry_kind: z.enum(["expense", "reversal"]).optional(),
  search: z.string().optional(),
  page: z.number().int().min(1).default(1),
});

export type StoreExpensesListFilters = z.infer<typeof storeExpensesListFiltersSchema>;

export const EXPENSE_ENTRY_KIND_LABELS_AR: Record<"expense" | "reversal", string> = {
  expense: "مصروف",
  reversal: "عكس",
};

/** True when a DB error message indicates the business date falls in a closed day — the UI must then ask for an explicit reason (and the actor needs expenses.process_closed_day). */
export function isClosedDayError(message: string): boolean {
  return message.includes("يوم مقفل");
}

/** True when a DB error message indicates the expense was already reversed — the client must reload rather than retry. */
export function isAlreadyReversedError(message: string): boolean {
  return message.includes("مسبقًا");
}

/** True when a DB error message indicates an optimistic-concurrency Conflict (row_version mismatch) — mirrors inventory/adjustments/settlements schema.ts. */
export function isVersionConflictError(message: string): boolean {
  return message.includes("مستخدم آخر");
}

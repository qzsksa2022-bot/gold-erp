import { z } from "zod";
import { hasMaxDecimalPlaces, isNonNegativeDecimal, isPositiveDecimal } from "@/lib/decimal";

// Phase 9 (Inventory Core) — every quantity input here stays a STRING all
// the way to the RPC call, never parsed through Number()/parseFloat() at
// any point in this file or in actions.ts, exactly mirroring
// src/features/adjustments/schema.ts and src/features/settlements/schema.ts.
// The stock balance is never computed client-side — it is always whatever
// list_inventory_stock_balances()/receive_inventory_stock()/adjust_
// inventory_stock() (migration 0229) returns, already summed server-side
// from the append-only ledger.

export const INVENTORY_UNITS = ["gram", "piece"] as const;

export const INVENTORY_UNIT_LABELS_AR: Record<(typeof INVENTORY_UNITS)[number], string> = {
  gram: "جرام",
  piece: "قطعة",
};

const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined));

const rowVersionSchema = z.number({ required_error: "إصدار السجل مطلوب" }).int().nonnegative();

/** Strictly positive quantity with at most 3 decimal places (mirrors inventory_stock_movements.quantity_delta numeric(12,3), migration 0228, and the RPC's own "receive must be positive" CHECK). */
const positiveQuantitySchema = z
  .string({ required_error: "الكمية مطلوبة" })
  .trim()
  .refine((v) => isPositiveDecimal(v), "الكمية يجب أن تكون رقمًا أكبر من صفر")
  .refine((v) => hasMaxDecimalPlaces(v, 3), "الكمية يجب ألا تتجاوز 3 منازل عشرية");

/** Signed, non-zero quantity delta for a manual correction — sign carries meaning (found extra vs. found missing). */
const signedNonZeroQuantitySchema = z
  .string({ required_error: "الكمية مطلوبة" })
  .trim()
  .refine((v) => /^-?\d+(\.\d+)?$/.test(v) && v !== "" && v !== "-", "الكمية يجب أن تكون رقمًا صالحًا")
  .refine((v) => {
    try {
      return !isNonNegativeDecimal(v) || isPositiveDecimal(v);
    } catch {
      return false;
    }
  }, "الكمية يجب ألا تساوي صفرًا")
  .refine((v) => hasMaxDecimalPlaces(v, 3), "الكمية يجب ألا تتجاوز 3 منازل عشرية");

// ---------------------------------------------------------------------------
// create_inventory_item() (migration 0229) — sku is permanent once created,
// only accepted on create, never on update (mirrors adjustment_types.code).
// ---------------------------------------------------------------------------
export const createInventoryItemSchema = z.object({
  sku: z
    .string({ required_error: "رمز الصنف (SKU) مطلوب" })
    .trim()
    .min(1, "رمز الصنف (SKU) مطلوب")
    .max(100, "رمز الصنف طويل جدًا"),
  name_ar: z.string({ required_error: "اسم الصنف مطلوب" }).trim().min(1, "اسم الصنف مطلوب").max(200),
  category_id: z.string({ required_error: "التصنيف مطلوب" }).uuid("تصنيف غير صالح"),
  karat_id: z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined))
    .refine((v) => v === undefined || z.string().uuid().safeParse(v).success, "عيار غير صالح"),
  unit: z.enum(INVENTORY_UNITS, { required_error: "وحدة القياس مطلوبة" }),
  notes: optionalText(1000),
});

export type CreateInventoryItemInput = z.infer<typeof createInventoryItemSchema>;

// ---------------------------------------------------------------------------
// update_inventory_item() (migration 0229) — sku intentionally NOT part of
// this schema.
// ---------------------------------------------------------------------------
export const updateInventoryItemSchema = z.object({
  id: z.string().uuid(),
  row_version: rowVersionSchema,
  name_ar: z.string({ required_error: "اسم الصنف مطلوب" }).trim().min(1, "اسم الصنف مطلوب").max(200),
  category_id: z.string({ required_error: "التصنيف مطلوب" }).uuid("تصنيف غير صالح"),
  karat_id: z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined))
    .refine((v) => v === undefined || z.string().uuid().safeParse(v).success, "عيار غير صالح"),
  unit: z.enum(INVENTORY_UNITS, { required_error: "وحدة القياس مطلوبة" }),
  active: z.boolean({ required_error: "يجب تحديد حالة التفعيل" }),
  notes: optionalText(1000),
});

export type UpdateInventoryItemInput = z.infer<typeof updateInventoryItemSchema>;

// ---------------------------------------------------------------------------
// receive_inventory_stock() (migration 0229) — quantity must be strictly
// positive.
// ---------------------------------------------------------------------------
export const receiveInventoryStockSchema = z.object({
  item_id: z.string({ required_error: "الصنف مطلوب" }).uuid("صنف غير صالح"),
  store_id: z.string({ required_error: "المتجر مطلوب" }).uuid("متجر غير صالح"),
  quantity: positiveQuantitySchema,
  business_date: z.string({ required_error: "التاريخ مطلوب" }).trim().min(1, "التاريخ مطلوب"),
  reference: optionalText(200),
  notes: optionalText(1000),
});

export type ReceiveInventoryStockInput = z.infer<typeof receiveInventoryStockSchema>;

// ---------------------------------------------------------------------------
// adjust_inventory_stock() (migration 0229) — quantity_delta is signed
// (positive = found extra, negative = found missing), reason mandatory.
// ---------------------------------------------------------------------------
export const adjustInventoryStockSchema = z.object({
  item_id: z.string({ required_error: "الصنف مطلوب" }).uuid("صنف غير صالح"),
  store_id: z.string({ required_error: "المتجر مطلوب" }).uuid("متجر غير صالح"),
  quantity_delta: signedNonZeroQuantitySchema,
  reason: z.string({ required_error: "سبب التصحيح مطلوب" }).trim().min(1, "سبب التصحيح مطلوب").max(1000),
  business_date: z.string({ required_error: "التاريخ مطلوب" }).trim().min(1, "التاريخ مطلوب"),
  reference: optionalText(200),
});

export type AdjustInventoryStockInput = z.infer<typeof adjustInventoryStockSchema>;

// ---------------------------------------------------------------------------
// list_inventory_items() filters.
// ---------------------------------------------------------------------------
export const inventoryItemsListFiltersSchema = z.object({
  search: z.string().optional(),
  category_id: z.string().uuid().optional(),
  karat_id: z.string().uuid().optional(),
  active: z.boolean().optional(),
  page: z.number().int().min(1).default(1),
});

export type InventoryItemsListFilters = z.infer<typeof inventoryItemsListFiltersSchema>;

// ---------------------------------------------------------------------------
// list_inventory_stock_movements() filters.
// ---------------------------------------------------------------------------
export const inventoryMovementsListFiltersSchema = z.object({
  item_id: z.string().uuid().optional(),
  store_id: z.string().uuid().optional(),
  date_from: z.string().optional(),
  date_to: z.string().optional(),
  page: z.number().int().min(1).default(1),
});

export type InventoryMovementsListFilters = z.infer<typeof inventoryMovementsListFiltersSchema>;

/** True when a DB error message indicates a would-go-negative stock rejection — mirrors isVersionConflictError()'s shape below. */
export function isNegativeStockError(message: string): boolean {
  return message.includes("سالبة");
}

/** True when a DB error message indicates an optimistic-concurrency Conflict (row_version mismatch) — the client must reload rather than auto-resubmit. Mirrors adjustments/settlements schema.ts's isVersionConflictError(). */
export function isVersionConflictError(message: string): boolean {
  return message.includes("جهة أخرى");
}

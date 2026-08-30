import { z } from "zod";
import { hasMaxDecimalPlaces, isNonNegativeDecimal, isPositiveDecimal } from "@/lib/decimal";

// Every financial input here stays a STRING all the way to the RPC call —
// never parsed through Number()/parseFloat() at any point in this file or
// in actions.ts. See src/lib/decimal.ts and migration 0061's header
// comment (spec §6): the app can only Preview: PostgreSQL is the sole
// source of truth for every computed value.

export const salesOrderItemSchema = z.object({
  // Patch 3.1 item 1/9 — stable identity: present (a real DB uuid) for an
  // existing item being kept/edited, absent for a brand-new item. Never
  // sent for create_sales_order() (every item there is new by definition).
  // See update_sales_order() (migration 0069): any existing active item NOT
  // referenced by id in the submitted array is soft-removed, never
  // hard-deleted.
  id: z.string().uuid().optional(),
  category_id: z.string({ required_error: "التصنيف مطلوب" }).uuid("تصنيف غير صالح"),
  karat_id: z.string({ required_error: "العيار مطلوب" }).uuid("عيار غير صالح"),
  weight_grams: z
    .string({ required_error: "الوزن مطلوب" })
    .trim()
    .refine((v) => isPositiveDecimal(v), "الوزن يجب أن يكون رقمًا أكبر من صفر")
    // Patch 3.2 item 4 — mirrors validate_sales_item_precision() (0074):
    // weight_grams is NUMERIC(10,4), so the DB rejects (never silently
    // rounds) more than 4 decimal places. Checked client-side too for
    // immediate feedback, but the DB call remains the actual authority.
    .refine((v) => hasMaxDecimalPlaces(v, 4), "الوزن يجب ألا يتجاوز 4 منازل عشرية"),
  sale_price: z
    .string({ required_error: "سعر البيع مطلوب" })
    .trim()
    .refine((v) => isNonNegativeDecimal(v), "سعر البيع يجب أن يكون رقمًا موجبًا أو صفرًا")
    // Patch 3.2 item 4 — mirrors validate_sales_item_precision() (0074):
    // sale_price is NUMERIC(14,2), so the DB rejects more than 2 decimal
    // places rather than silently rounding it.
    .refine((v) => hasMaxDecimalPlaces(v, 2), "سعر البيع يجب ألا يتجاوز منزلتين عشريتين"),
  item_name: z
    .string()
    .trim()
    .max(200)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  description: z
    .string()
    .trim()
    .max(1000)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  sku: z
    .string()
    .trim()
    .max(100)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
});

export type SalesOrderItemFormInput = z.infer<typeof salesOrderItemSchema>;

const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined));

export const createSalesOrderSchema = z.object({
  store_id: z.string({ required_error: "المتجر مطلوب" }).uuid("متجر غير صالح"),
  sale_date: z.string({ required_error: "تاريخ البيع مطلوب" }).trim().min(1, "تاريخ البيع مطلوب"),
  payment_method_id: z.string({ required_error: "طريقة الدفع مطلوبة" }).uuid("طريقة دفع غير صالحة"),
  collection_channel_id: z.string({ required_error: "قناة التحصيل مطلوبة" }).uuid("قناة تحصيل غير صالحة"),
  customer_name: optionalText(200),
  customer_phone: optionalText(30),
  notes: optionalText(1000),
  items: z.array(salesOrderItemSchema).min(1, "يجب إضافة بند واحد على الأقل"),
  closed_day_reason: optionalText(500),
});

export type CreateSalesOrderInput = z.infer<typeof createSalesOrderSchema>;

export const updateSalesOrderSchema = z.object({
  order_id: z.string().uuid(),
  // Patch 3.2 item 2 — optimistic concurrency: the row_version the Edit form
  // loaded (from get_sales_order(), migration 0079). update_sales_order()
  // (0075) now REQUIRES this and rejects a stale value with a Conflict — the
  // client must never fabricate/omit it, and must never silently resubmit
  // the same value again after a Conflict (see isVersionConflictError()
  // below and the Edit form's reload-on-conflict handling).
  row_version: z.number({ required_error: "إصدار السجل مطلوب" }).int().nonnegative(),
  payment_method_id: z.string({ required_error: "طريقة الدفع مطلوبة" }).uuid("طريقة دفع غير صالحة"),
  collection_channel_id: z.string({ required_error: "قناة التحصيل مطلوبة" }).uuid("قناة تحصيل غير صالحة"),
  customer_name: optionalText(200),
  customer_phone: optionalText(30),
  notes: optionalText(1000),
  items: z.array(salesOrderItemSchema).min(1, "يجب إضافة بند واحد على الأقل"),
  closed_day_reason: optionalText(500),
});

export type UpdateSalesOrderInput = z.infer<typeof updateSalesOrderSchema>;

export const previewSalesOrderSchema = z.object({
  store_id: z.string().uuid(),
  sale_date: z.string().trim().min(1),
  payment_method_id: z.string().uuid(),
  // Patch 3.1 item 10 — preview_sales_order() (migration 0070) requires
  // this now, matching create_sales_order()'s own required argument, so
  // Preview validates collection-channel-active exactly like Save does.
  collection_channel_id: z.string().uuid(),
  items: z.array(salesOrderItemSchema).min(1),
});

export type PreviewSalesOrderInput = z.infer<typeof previewSalesOrderSchema>;

// Patch 3.2 item 5 — Edit-mode preview, mirrors update_sales_order()'s own
// inputs (order_id + row_version + items-with-ids), NOT create's shape.
// Used ONLY by the Edit form; the New Sale form keeps using
// previewSalesOrderSchema/previewSalesOrderAction above.
export const previewUpdateSalesOrderSchema = z.object({
  order_id: z.string().uuid(),
  row_version: z.number({ required_error: "إصدار السجل مطلوب" }).int().nonnegative(),
  payment_method_id: z.string().uuid(),
  collection_channel_id: z.string().uuid(),
  customer_name: optionalText(200),
  customer_phone: optionalText(30),
  notes: optionalText(1000),
  items: z.array(salesOrderItemSchema).min(1),
});

export type PreviewUpdateSalesOrderInput = z.infer<typeof previewUpdateSalesOrderSchema>;

export const closeSalesDaySchema = z.object({
  store_id: z.string({ required_error: "المتجر مطلوب" }).uuid("متجر غير صالح"),
  business_date: z.string({ required_error: "التاريخ مطلوب" }).trim().min(1, "التاريخ مطلوب"),
  notes: optionalText(500),
});

export type CloseSalesDayInput = z.infer<typeof closeSalesDaySchema>;

export const salesListFiltersSchema = z.object({
  date_from: z.string().optional(),
  date_to: z.string().optional(),
  store_id: z.string().uuid().optional(),
  order_number: z.string().optional(),
  salesperson_id: z.string().uuid().optional(),
  payment_method_id: z.string().uuid().optional(),
  collection_channel_id: z.string().uuid().optional(),
  page: z.number().int().min(1).default(1),
});

export type SalesListFilters = z.infer<typeof salesListFiltersSchema>;

/** True when a DB error message indicates the target day is closed — used by the client to trigger the mandatory-reason dialog (spec §20) rather than just showing a dead-end error. */
export function isClosedDayError(message: string): boolean {
  return message.includes("مقفل");
}

/**
 * Patch 3.2 item 2 — true when a DB error message indicates an optimistic-
 * concurrency Conflict (update_sales_order()'s row_version mismatch,
 * migration 0075/0078). The client MUST NOT auto-resubmit the same stale
 * payload on this error — it must show the message and require the user to
 * reload the order (re-fetching the current row_version) before saving
 * again.
 */
export function isVersionConflictError(message: string): boolean {
  return message.includes("مستخدم آخر");
}

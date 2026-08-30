import { z } from "zod";
import { isNonNegativeDecimal } from "@/lib/decimal";

// Patch 5.1 items 19/20 — Shipping Rate/Carrier/Zone Admin UI. Carrier/zone
// CRUD writes go through direct Supabase table insert/update (RLS-gated on
// shipping_rates.manage, exactly like src/features/karats) — code is
// immutable after creation (enforced DB-side, migration 0124) so it is
// never accepted on update. Rate-version/return-fee-version writes go
// through the sanctioned create_*/cancel_* RPCs ONLY (migrations
// 0114/0115/0122) — never a raw insert/update on those two tables, which
// have zero direct-write RLS policies as of 0122 item 1.

const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined));

// ---------------------------------------------------------------------------
// shipping_carriers — direct table write (migration 0113, hardened 0124).
// ---------------------------------------------------------------------------
export const SHIPPING_CARRIER_TYPES = ["external", "store_courier", "other"] as const;

export const SHIPPING_CARRIER_TYPE_LABELS_AR: Record<(typeof SHIPPING_CARRIER_TYPES)[number], string> = {
  external: "شركة شحن خارجية",
  store_courier: "مندوب المتجر",
  other: "أخرى",
};

export const shippingCarrierFormSchema = z.object({
  code: z
    .string({ required_error: "كود شركة الشحن مطلوب" })
    .trim()
    .min(1, "كود شركة الشحن مطلوب")
    .max(30, "الكود طويل جدًا")
    .regex(/^[A-Za-z0-9_]+$/, "الكود يجب أن يتكون من أحرف/أرقام لاتينية و _ فقط"),
  name_ar: z.string({ required_error: "الاسم بالعربية مطلوب" }).trim().min(1, "الاسم مطلوب").max(100),
  name_en: optionalText(100),
  carrier_type: z.enum(SHIPPING_CARRIER_TYPES, { required_error: "نوع شركة الشحن مطلوب" }),
  notes: optionalText(500),
});

export type ShippingCarrierFormInput = z.infer<typeof shippingCarrierFormSchema>;

// ---------------------------------------------------------------------------
// shipping_zones — direct table write (migration 0113, hardened 0124).
// ---------------------------------------------------------------------------
export const shippingZoneFormSchema = z.object({
  code: z
    .string({ required_error: "كود المنطقة مطلوب" })
    .trim()
    .min(1, "كود المنطقة مطلوب")
    .max(30, "الكود طويل جدًا")
    .regex(/^[A-Za-z0-9_]+$/, "الكود يجب أن يتكون من أحرف/أرقام لاتينية و _ فقط"),
  name_ar: z.string({ required_error: "الاسم بالعربية مطلوب" }).trim().min(1, "الاسم مطلوب").max(100),
  name_en: optionalText(100),
  sort_order: z.coerce.number().int().min(0).max(10000).optional().default(0),
  notes: optionalText(500),
});

export type ShippingZoneFormInput = z.infer<typeof shippingZoneFormSchema>;

// ---------------------------------------------------------------------------
// create_shipping_carrier_rate_version() (migrations 0114/0122) — RPC only.
// ---------------------------------------------------------------------------
export const SHIPMENT_RATE_DIRECTIONS = ["outbound", "return"] as const;

export const SHIPMENT_RATE_DIRECTION_LABELS_AR: Record<(typeof SHIPMENT_RATE_DIRECTIONS)[number], string> = {
  outbound: "ذهاب (للعميل)",
  return: "إرجاع (من العميل)",
};

export const shippingCarrierRateVersionFormSchema = z.object({
  carrier_id: z.string({ required_error: "شركة الشحن مطلوبة" }).uuid("شركة شحن غير صالحة"),
  shipping_zone_id: z.string({ required_error: "المنطقة مطلوبة" }).uuid("منطقة غير صالحة"),
  direction: z.enum(SHIPMENT_RATE_DIRECTIONS, { required_error: "الاتجاه مطلوب" }),
  base_cost: z
    .string({ required_error: "التكلفة الأساسية مطلوبة" })
    .trim()
    .refine((v) => isNonNegativeDecimal(v), "التكلفة الأساسية يجب أن تكون رقمًا موجبًا أو صفرًا"),
  effective_from: z.string({ required_error: "تاريخ السريان مطلوب" }).trim().min(1, "تاريخ السريان مطلوب"),
  notes: optionalText(500),
});

export type ShippingCarrierRateVersionFormInput = z.infer<typeof shippingCarrierRateVersionFormSchema>;

// ---------------------------------------------------------------------------
// create_customer_return_shipping_fee_version() (migrations 0115/0122) —
// RPC only.
// ---------------------------------------------------------------------------
export const customerReturnShippingFeeVersionFormSchema = z.object({
  shipping_zone_id: z.string({ required_error: "المنطقة مطلوبة" }).uuid("منطقة غير صالحة"),
  fee_amount: z
    .string({ required_error: "قيمة رسوم الإرجاع مطلوبة" })
    .trim()
    .refine((v) => isNonNegativeDecimal(v), "قيمة رسوم الإرجاع يجب أن تكون رقمًا موجبًا أو صفرًا"),
  effective_from: z.string({ required_error: "تاريخ السريان مطلوب" }).trim().min(1, "تاريخ السريان مطلوب"),
  notes: optionalText(500),
});

export type CustomerReturnShippingFeeVersionFormInput = z.infer<typeof customerReturnShippingFeeVersionFormSchema>;

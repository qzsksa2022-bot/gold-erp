import { z } from "zod";
import { isNonNegativeDecimal, toDecimal } from "@/lib/decimal";

const FEE_MODELS = ["percentage", "fixed", "percentage_plus_fixed", "none"] as const;
const REFUND_POLICIES = ["full_reversal", "proportional_reversal", "non_refundable_fee", "manual"] as const;

export const paymentMethodFormSchema = z.object({
  key: z
    .string({ required_error: "المفتاح مطلوب" })
    .trim()
    .min(2, "المفتاح قصير جدًا")
    .max(40, "المفتاح طويل جدًا")
    .regex(/^[a-z0-9_]+$/, "المفتاح يجب أن يتكون من حروف إنجليزية صغيرة وأرقام و _ فقط")
    .optional(),
  name_ar: z.string({ required_error: "الاسم بالعربية مطلوب" }).trim().min(1, "الاسم مطلوب").max(80),
  name_en: z
    .string()
    .trim()
    .max(80)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  fee_model: z.enum(FEE_MODELS),
  supports_refunds: z.coerce.boolean(),
  refund_fee_policy: z.enum(REFUND_POLICIES),
  sort_order: z.coerce.number().int().min(0).max(10000).optional().default(0),
});

export type PaymentMethodFormInput = z.infer<typeof paymentMethodFormSchema>;

export const paymentMethodFeeVersionSchema = z.object({
  payment_method_id: z.string({ required_error: "طريقة الدفع مطلوبة" }).uuid(),
  percentage_fee: z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : "0"))
    // Decimal, never Number() — see src/lib/decimal.ts. <= 100 mirrors the
    // payment_method_fee_versions_percentage_max DB CHECK constraint
    // (0047) — validated here too so the form gives an immediate, specific
    // message instead of surfacing the DB error verbatim.
    .refine((v) => isNonNegativeDecimal(v) && toDecimal(v).lte(100), "النسبة يجب أن تكون رقمًا بين 0 و100"),
  fixed_fee: z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : "0"))
    .refine((v) => isNonNegativeDecimal(v), "المبلغ الثابت يجب أن يكون رقمًا موجبًا أو صفرًا"),
  effective_from: z.string({ required_error: "تاريخ السريان مطلوب" }).trim().min(1, "تاريخ السريان مطلوب"),
  notes: z
    .string()
    .trim()
    .max(500)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
});

export type PaymentMethodFeeVersionInput = z.infer<typeof paymentMethodFeeVersionSchema>;

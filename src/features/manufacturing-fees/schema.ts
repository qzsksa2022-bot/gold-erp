import { z } from "zod";
import { isNonNegativeDecimal } from "@/lib/decimal";

export const manufacturingFeeVersionSchema = z.object({
  karat_id: z.string({ required_error: "العيار مطلوب" }).uuid("عيار غير صالح"),
  fee_per_gram: z
    .string({ required_error: "قيمة المصنعية مطلوبة" })
    .trim()
    // Decimal, never Number() — see src/lib/decimal.ts.
    .refine((v) => isNonNegativeDecimal(v), "قيمة المصنعية يجب أن تكون رقمًا موجبًا أو صفرًا"),
  effective_from: z.string({ required_error: "تاريخ السريان مطلوب" }).trim().min(1, "تاريخ السريان مطلوب"),
  notes: z
    .string()
    .trim()
    .max(500)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
});

export type ManufacturingFeeVersionInput = z.infer<typeof manufacturingFeeVersionSchema>;

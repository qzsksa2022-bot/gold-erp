import { z } from "zod";
import { isNonNegativeDecimal, hasMaxDecimalPlaces } from "@/lib/decimal";

// Hotfix 10.1.0 — VAT rate versioning input contract.
//
// Mirrors src/features/manufacturing-fees/schema.ts exactly: the rate stays a
// STRING all the way to create_vat_rate_version() (migration 0058, hardened
// 0066), never parsed through Number()/parseFloat(). VAT is an input to every
// Sale's Total Product Cost (0074), so an imprecise round-trip here would
// silently move real money.
//
// vat_rate_versions.rate_percent is numeric(6, 3) (0058), hence the 3-decimal
// ceiling; the value is a PERCENT (15 means 15%), not a fraction.

export const vatRateVersionSchema = z.object({
  rate_percent: z
    .string({ required_error: "نسبة الضريبة مطلوبة" })
    .trim()
    .min(1, "نسبة الضريبة مطلوبة")
    // Decimal, never Number() — see src/lib/decimal.ts.
    .refine((v) => isNonNegativeDecimal(v), "نسبة الضريبة يجب أن تكون رقمًا موجبًا أو صفرًا")
    .refine((v) => hasMaxDecimalPlaces(v, 3), "نسبة الضريبة يجب ألا تتجاوز 3 منازل عشرية"),
  effective_from: z.string({ required_error: "تاريخ السريان مطلوب" }).trim().min(1, "تاريخ السريان مطلوب"),
  notes: z
    .string()
    .trim()
    .max(500)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
});

export type VatRateVersionInput = z.infer<typeof vatRateVersionSchema>;

import { z } from "zod";
import { toDecimal } from "@/lib/decimal";

export const karatFormSchema = z.object({
  code: z
    .string({ required_error: "كود العيار مطلوب" })
    .trim()
    .min(1, "كود العيار مطلوب")
    .max(20, "كود العيار طويل جدًا"),
  name_ar: z.string({ required_error: "اسم العيار بالعربية مطلوب" }).trim().min(1, "الاسم مطلوب").max(80),
  name_en: z
    .string()
    .trim()
    .max(80)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  purity_per_mille: z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined))
    .refine(
      (v) => {
        if (v === undefined) return true;
        // Decimal, never Number() — see src/lib/decimal.ts. A malformed
        // string throws inside toDecimal(), which the try/catch here
        // treats as invalid, exactly like the old Number.isNaN() check did.
        try {
          const d = toDecimal(v);
          return d.gt(0) && d.lte(1000);
        } catch {
          return false;
        }
      },
      { message: "قيمة العيار بالألف يجب أن تكون بين 0 و1000" },
    ),
  sort_order: z.coerce.number().int().min(0).max(10000).optional().default(0),
});

export type KaratFormInput = z.infer<typeof karatFormSchema>;

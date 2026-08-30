import { z } from "zod";

export const categoryFormSchema = z.object({
  parent_id: z
    .string()
    .trim()
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  code: z
    .string()
    .trim()
    .max(40)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  name_ar: z.string({ required_error: "اسم التصنيف بالعربية مطلوب" }).trim().min(1, "الاسم مطلوب").max(120),
  name_en: z
    .string()
    .trim()
    .max(120)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  sort_order: z.coerce.number().int().min(0).max(10000).optional().default(0),
});

export type CategoryFormInput = z.infer<typeof categoryFormSchema>;

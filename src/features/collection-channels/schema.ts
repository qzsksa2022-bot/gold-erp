import { z } from "zod";

export const collectionChannelFormSchema = z.object({
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
  sort_order: z.coerce.number().int().min(0).max(10000).optional().default(0),
});

export type CollectionChannelFormInput = z.infer<typeof collectionChannelFormSchema>;

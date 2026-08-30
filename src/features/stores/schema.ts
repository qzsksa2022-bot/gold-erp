import { z } from "zod";

export const storeFormSchema = z.object({
  code: z
    .string({ required_error: "كود المتجر مطلوب" })
    .trim()
    .min(2, "كود المتجر يجب أن يكون حرفين على الأقل")
    .max(20, "كود المتجر طويل جدًا")
    .regex(/^[A-Za-z0-9\-_]+$/, "الكود يجب أن يتكون من حروف/أرقام إنجليزية أو - أو _ فقط"),
  name_ar: z.string({ required_error: "اسم المتجر بالعربية مطلوب" }).trim().min(2, "الاسم قصير جدًا").max(120),
  name_en: z
    .string()
    .trim()
    .max(120)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  description: z
    .string()
    .trim()
    .max(500)
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
  logo_url: z
    .string()
    .trim()
    .url("رابط الشعار غير صحيح")
    .optional()
    .or(z.literal(""))
    .transform((v) => (v ? v : undefined)),
});

export type StoreFormInput = z.infer<typeof storeFormSchema>;

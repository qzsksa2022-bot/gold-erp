import { z } from "zod";

export const loginSchema = z.object({
  email: z
    .string({ required_error: "البريد الإلكتروني مطلوب" })
    .min(1, "البريد الإلكتروني مطلوب")
    .email("صيغة البريد الإلكتروني غير صحيحة"),
  password: z.string({ required_error: "كلمة المرور مطلوبة" }).min(1, "كلمة المرور مطلوبة"),
  rememberMe: z.coerce.boolean().optional().default(false),
});

export type LoginInput = z.infer<typeof loginSchema>;

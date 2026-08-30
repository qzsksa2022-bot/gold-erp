import { z } from "zod";

export const generalSettingsSchema = z.object({
  system_name_ar: z.string({ required_error: "اسم النظام بالعربية مطلوب" }).trim().min(2).max(100),
  system_name_en: z.string().trim().max(100).optional().or(z.literal("")).transform((v) => v || ""),
  currency: z.string().trim().min(3).max(3).default("SAR"),
  timezone: z.string().trim().min(1).default("Asia/Riyadh"),
});

export const appearanceSettingsSchema = z.object({
  logo_url: z.string().trim().url("رابط الشعار غير صحيح").optional().or(z.literal("")).transform((v) => (v ? v : null)),
  accent_color: z
    .string({ required_error: "لون العلامة مطلوب" })
    .trim()
    .regex(/^#[0-9a-fA-F]{6}$/, "استخدم صيغة لون سداسية مثل #A9812E"),
  font_family: z.string().trim().max(80).optional().or(z.literal("")).transform((v) => (v ? v : null)),
});

export const securitySettingsSchema = z.object({
  two_factor_enabled: z.coerce.boolean().default(false),
  session_timeout_minutes: z.coerce.number().int().min(15).max(1440).default(480),
});

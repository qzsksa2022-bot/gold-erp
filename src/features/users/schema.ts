import { z } from "zod";

const storeAccessScope = z.enum(["all", "multiple", "single"]);

export const createUserSchema = z.object({
  full_name: z.string({ required_error: "الاسم الكامل مطلوب" }).trim().min(2, "الاسم قصير جدًا").max(120),
  email: z.string({ required_error: "البريد الإلكتروني مطلوب" }).trim().email("صيغة البريد الإلكتروني غير صحيحة"),
  password: z
    .string({ required_error: "كلمة المرور مطلوبة" })
    .min(8, "يجب أن تكون كلمة المرور 8 أحرف على الأقل")
    .max(72, "كلمة المرور طويلة جدًا"),
  default_store_id: z.string().uuid().optional().or(z.literal("")).transform((v) => (v ? v : undefined)),
  store_access_scope: storeAccessScope.default("single"),
});
export type CreateUserInput = z.infer<typeof createUserSchema>;

// Foundation Hardening 1.3, item 2e / item 3: split what used to be one
// combined updateUserSchema into two independent schemas, one per DB-layer
// permission group (supabase/migrations/0030). full_name is authorized by
// users.edit; store_access_scope/default_store_id are authorized by
// users.manage_store_access ONLY -- an actor holding just one of the two
// permissions can now legitimately submit only the fields they are allowed
// to change, instead of every update needing both permissions at once just
// because the two field groups used to travel together in one form/action.

export const updateUserProfileSchema = z.object({
  full_name: z.string({ required_error: "الاسم الكامل مطلوب" }).trim().min(2, "الاسم قصير جدًا").max(120),
});
export type UpdateUserProfileInput = z.infer<typeof updateUserProfileSchema>;

export const updateUserStoreScopeSchema = z.object({
  default_store_id: z.string().uuid().optional().or(z.literal("")).transform((v) => (v ? v : undefined)),
  store_access_scope: storeAccessScope,
});
export type UpdateUserStoreScopeInput = z.infer<typeof updateUserStoreScopeSchema>;

export const roleFormSchema = z.object({
  name_ar: z.string({ required_error: "اسم الدور مطلوب" }).trim().min(2, "الاسم قصير جدًا").max(80),
  name_en: z.string().trim().max(80).optional().or(z.literal("")).transform((v) => (v ? v : undefined)),
  description_ar: z.string().trim().max(300).optional().or(z.literal("")).transform((v) => (v ? v : undefined)),
});
export type RoleFormInput = z.infer<typeof roleFormSchema>;

export const permissionOverrideSchema = z.object({
  permissionId: z.string().uuid(),
  effect: z.enum(["grant", "revoke", "clear"]),
  reason: z.string().trim().max(300).optional().or(z.literal("")).transform((v) => (v ? v : undefined)),
});

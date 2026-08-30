/**
 * One-time bootstrap script: creates the FIRST Super Admin account.
 *
 * Why a script and not a UI route: this is the only user-creation path that
 * runs before any admin exists to grant permissions, so it must run outside
 * the normal permission-gated app flow. It uses the Supabase Service Role
 * key directly (never exposed to a browser -- this script only runs on your
 * own machine / CI, reading the key from .env.local, which is git-ignored).
 *
 * Usage:
 *   npm run bootstrap:super-admin -- --email admin@yourstore.sa --name "اسم المدير"
 * (the password is always typed at an interactive prompt, never passed as a
 * CLI flag, so it never ends up in shell history)
 *
 * Safe to re-run: if the email already has an auth user, the script will
 * just ensure that user has the super_admin role instead of erroring.
 */
import { createClient } from "@supabase/supabase-js";
import { config } from "dotenv";
import { existsSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";

for (const file of [".env.local", ".env"]) {
  if (existsSync(file)) config({ path: file });
}

function parseArg(name: string): string | undefined {
  const idx = process.argv.indexOf(`--${name}`);
  return idx !== -1 ? process.argv[idx + 1] : undefined;
}

/**
 * Plain (visible) terminal prompt. NOTE: this does not mask password
 * characters on screen -- implementing true masked input portably across
 * Windows/macOS/Linux needs a small terminal library, which felt like
 * overkill for a one-time bootstrap script. What it does guarantee is that
 * the password never appears in shell history (unlike passing it as a CLI
 * flag) and is never written to disk or logged. Run this in a private
 * terminal.
 */
async function prompt(question: string): Promise<string> {
  const rl = createInterface({ input: stdin, output: stdout });
  const answer = await rl.question(question);
  rl.close();
  return answer;
}

async function main() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceRoleKey) {
    console.error(
      "خطأ: يجب تعريف NEXT_PUBLIC_SUPABASE_URL و SUPABASE_SERVICE_ROLE_KEY في .env.local قبل تشغيل هذا السكربت.",
    );
    process.exit(1);
  }

  const email = parseArg("email") ?? (await prompt("البريد الإلكتروني لأول Super Admin: "));
  const fullName = parseArg("name") ?? (await prompt("الاسم الكامل: "));
  const password = await prompt("كلمة المرور (8 أحرف على الأقل): ");

  if (!email || !fullName || password.length < 8) {
    console.error("خطأ: البريد الإلكتروني والاسم مطلوبان، وكلمة المرور يجب ألا تقل عن 8 أحرف.");
    process.exit(1);
  }

  const admin = createClient(url, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } });

  const { data: roleRow, error: roleError } = await admin.from("roles").select("id").eq("key", "super_admin").single();
  if (roleError || !roleRow) {
    console.error("خطأ: لم يتم العثور على دور super_admin. تأكد أن supabase/seed.sql تم تطبيقه على قاعدة البيانات.");
    process.exit(1);
  }

  // Look for an existing auth user with this email first (idempotent re-run).
  let userId: string | undefined;
  const { data: existingList } = await admin.auth.admin.listUsers({ page: 1, perPage: 200 });
  userId = existingList?.users.find((u) => u.email?.toLowerCase() === email.toLowerCase())?.id;

  if (!userId) {
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName },
    });
    if (createError || !created.user) {
      console.error("خطأ: فشل إنشاء المستخدم:", createError?.message);
      process.exit(1);
    }
    userId = created.user.id;
    console.log(`تم إنشاء حساب المصادقة (${email}).`);
  } else {
    console.log(`البريد الإلكتروني موجود مسبقًا (${email}) -- سيتم استخدام هذا الحساب.`);
  }

  const { error: profileError } = await admin
    .from("profiles")
    .update({ full_name: fullName, status: "active", store_access_scope: "all" })
    .eq("id", userId);
  if (profileError) {
    console.error("خطأ: فشل تحديث ملف المستخدم:", profileError.message);
    process.exit(1);
  }
  console.log("تم ضبط الملف الشخصي كـ Super Admin نشط بصلاحية وصول لكل المتاجر.");

  const { error: roleAssignError } = await admin
    .from("user_roles")
    .upsert({ user_id: userId, role_id: roleRow.id }, { onConflict: "user_id,role_id" });
  if (roleAssignError) {
    console.error("خطأ: فشل إسناد دور Super Admin:", roleAssignError.message);
    process.exit(1);
  }
  console.log("تم إسناد دور Super Admin.");

  console.log("\nيمكنك الآن تسجيل الدخول بهذا الحساب من صفحة /login.");
  process.exit(0);
}

main().catch((err) => {
  console.error("خطأ غير متوقع:", err);
  process.exit(1);
});

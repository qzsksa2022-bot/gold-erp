"use server";

import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";
import { redirect } from "next/navigation";
import { ROUTES } from "@/lib/constants";
import { loginSchema } from "./schema";
import { actionError, type ActionResult } from "@/lib/action-result";
import { createAdminClient } from "@/lib/supabase/admin";
import { logFailedLoginAttempt } from "@/lib/audit/log-failed-login";

/**
 * Maps Supabase Auth's (English, sometimes detail-leaking) error messages
 * to a small set of safe, generic Arabic messages. We deliberately do NOT
 * reveal whether the email exists, whether the account is suspended vs.
 * wrong-password, etc. — a single generic "بيانات الدخول غير صحيحة"
 * prevents user enumeration.
 */
function translateAuthError(message: string): string {
  if (/rate limit|too many/i.test(message)) {
    return "محاولات كثيرة جدًا. الرجاء الانتظار قليلًا ثم إعادة المحاولة.";
  }
  return "البريد الإلكتروني أو كلمة المرور غير صحيحة.";
}

export async function loginAction(_prevState: ActionResult<{ redirectTo: string }> | null, formData: FormData) {
  const parsed = loginSchema.safeParse({
    email: formData.get("email"),
    password: formData.get("password"),
    rememberMe: formData.get("rememberMe") === "on",
  });

  if (!parsed.success) {
    return actionError("تحقق من صحة البيانات المدخلة.", parsed.error.flatten().fieldErrors);
  }

  const { email, password, rememberMe } = parsed.data;
  const cookieStore = await cookies();

  // A dedicated client (rather than the shared lib/supabase/server.ts one)
  // so we can control the auth cookies' Max-Age based on "تذكرني": checked
  // -> persistent cookie (survives browser restarts, Supabase's normal
  // default); unchecked -> session cookie (options.maxAge stripped, so the
  // browser drops it on close). This is the "مناسب وآمن" reading of
  // "remember me" — actual token *validity* is still bounded by the
  // Supabase project's refresh-token expiry configured server-side.
  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, rememberMe ? options : { ...options, maxAge: undefined, expires: undefined });
          }
        },
      },
    },
  );

  const { data, error } = await supabase.auth.signInWithPassword({ email, password });

  if (error || !data.user) {
    // Best-effort audit trail for failed attempts, via the trusted
    // service-role client from this server-only action -- see
    // supabase/migrations/0016, which removed the `anon`-grantable
    // log_audit_event RPC this used to go through (an open RPC callable
    // pre-auth was exactly the kind of thing that migration closes). Rate
    // limited internally so a scripted brute-force attempt cannot flood the
    // audit log; the actual sign-in attempt is still rejected as usual by
    // Supabase Auth's own throttling regardless of whether this succeeds.
    await logFailedLoginAttempt(createAdminClient(), email);
    return actionError(translateAuthError(error?.message ?? ""));
  }

  const { data: profile } = await supabase.from("profiles").select("status").eq("id", data.user.id).single();

  if (!profile || profile.status !== "active") {
    await supabase.auth.signOut();
    return actionError("هذا الحساب معطل حاليًا. الرجاء التواصل مع الإدارة.");
  }

  // service_role-only RPC (0023) -- log_auth_event(text) (0016) was
  // revoked from `authenticated` because any signed-in client could call
  // it directly, at arbitrary times, to fabricate login/logout timeline
  // entries unrelated to a real sign-in. This call happens from
  // server-only code, AFTER the session/status checks above have
  // independently verified a real, successful sign-in just occurred, with
  // the user id supplied explicitly (the admin client has no JWT sub claim
  // of its own).
  await createAdminClient().rpc("log_auth_event_trusted", {
    p_user_id: data.user.id,
    p_action: "auth.login_success",
  });

  redirect(ROUTES.dashboard);
}

export async function logoutAction() {
  const cookieStore = await cookies();
  const supabase = createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        for (const { name, value, options } of cookiesToSet) {
          cookieStore.set(name, value, options);
        }
      },
    },
  });

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (user) {
    // Same trusted server-only path as loginAction above (0023) -- verified
    // via getUser() immediately before this call, then logged via the
    // admin/service-role client rather than a client-callable RPC.
    await createAdminClient().rpc("log_auth_event_trusted", {
      p_user_id: user.id,
      p_action: "auth.logout",
    });
  }

  await supabase.auth.signOut();
  redirect(ROUTES.login);
}

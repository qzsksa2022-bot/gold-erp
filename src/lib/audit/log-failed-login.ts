import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/types/database";

const RATE_LIMIT_WINDOW_MINUTES = 15;
const RATE_LIMIT_MAX_LOGGED_ATTEMPTS = 10;

/**
 * Logs a failed login attempt via the trusted service-role client. This is
 * now the ONLY sanctioned way pre-auth activity reaches audit_logs —
 * supabase/migrations/0016 revoked `log_audit_event` from `anon` entirely
 * (an open RPC any unauthenticated caller could invoke with arbitrary
 * action/entity_type values was exactly the fabrication risk that migration
 * closes). This function is called from the login Server Action, which is
 * server-only code — the service-role key it needs never reaches the
 * browser, satisfying "server-only endpoint/path" rather than an
 * anon-grantable RPC.
 *
 * Resolves the attempted email to an existing profile (if any) so the row
 * is attributable to a real account via entity_id/entity_type instead of
 * storing the raw email in the free-text `reason` column — the previous
 * design did that unnecessarily (a person's email address doesn't belong in
 * a "reason" field, and doing so surfaces it in the audit viewer's text
 * search for anyone who can view the log). An email with no matching
 * account is logged with no identifying data at all, rather than retaining
 * an address that doesn't correspond to a real account.
 *
 * Rate-limited per resolved account: once RATE_LIMIT_MAX_LOGGED_ATTEMPTS
 * failed-login audit rows exist for the same account within
 * RATE_LIMIT_WINDOW_MINUTES, further attempts stop writing new audit rows.
 * This only throttles the AUDIT WRITE — the sign-in attempt itself is still
 * rejected as usual by Supabase Auth's own rate limiting — so a scripted
 * brute-force attempt cannot flood the audit log with thousands of
 * near-identical rows even though it is (rightly) still blocked from
 * signing in by Auth itself.
 */
export async function logFailedLoginAttempt(admin: SupabaseClient<Database>, email: string): Promise<void> {
  const { data: profile } = await admin.from("profiles").select("id").ilike("email", email).maybeSingle();

  const entityId = profile?.id ?? null;
  const entityType = profile ? "user" : "auth";

  if (entityId) {
    const since = new Date(Date.now() - RATE_LIMIT_WINDOW_MINUTES * 60_000).toISOString();
    const { count } = await admin
      .from("audit_logs")
      .select("id", { count: "exact", head: true })
      .eq("action", "auth.login_failed")
      .eq("entity_id", entityId)
      .gte("created_at", since);

    if ((count ?? 0) >= RATE_LIMIT_MAX_LOGGED_ATTEMPTS) {
      return;
    }
  }

  const { error } = await admin.rpc("log_audit_event", {
    p_action: "auth.login_failed",
    p_entity_type: entityType,
    p_entity_id: entityId,
  });

  if (error) {
    console.error("[audit] فشل تسجيل محاولة دخول فاشلة:", error);
  }
}

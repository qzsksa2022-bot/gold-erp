import "server-only";

import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/types/database";

/**
 * Service-role Supabase client. This BYPASSES Row Level Security entirely
 * and can perform Admin API operations (create/delete auth users, etc).
 *
 * Hard rules:
 *  - The `import "server-only"` above makes any accidental import of this
 *    module from client code fail the build instead of leaking the key.
 *  - Only use this client for operations that genuinely require elevated
 *    privilege and cannot be expressed as "the signed-in user, via RLS":
 *    creating an auth user (Admin API), the Super Admin bootstrap script,
 *    and reading auth.users metadata (e.g. last_sign_in_at) for the users
 *    list. Every such call site must itself re-check the calling user's
 *    permission (via src/lib/permissions) before doing anything — this
 *    client does not do that for you.
 *  - Never pass this client, or anything derived from it, to a Client
 *    Component or a browser fetch response.
 */
export function createAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceRoleKey) {
    throw new Error(
      "SUPABASE_SERVICE_ROLE_KEY أو NEXT_PUBLIC_SUPABASE_URL غير مُعرّفين في متغيرات البيئة.",
    );
  }

  return createSupabaseClient<Database>(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

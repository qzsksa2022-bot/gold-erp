import type { PermissionKey } from "./constants";
import type { Database } from "@/types/database";

/**
 * Pure, server-agnostic permission resolution helpers — deliberately kept
 * free of the `server-only` import (unlike session.ts) so they can be unit
 * tested directly (see tests/permissions.test.ts) without any Next.js
 * request context or database connection.
 *
 * This mirrors (but does not replace) the authoritative logic in
 * `public.has_permission()` / `public.get_user_permissions()`
 * (supabase/migrations/0008_permission_functions.sql): the SQL functions
 * are what actually protects data via RLS; this is the same short-circuit
 * rule applied to a permission set already computed by that SQL and handed
 * to the app layer, used for UI-level decisions (page guards, showing/
 * hiding buttons).
 */
export type MinimalSession = {
  profile: Pick<Database["public"]["Tables"]["profiles"]["Row"], "status">;
  permissions: Set<PermissionKey>;
  isSuperAdmin: boolean;
};

export function sessionHasPermission(session: MinimalSession | null, key: PermissionKey): boolean {
  if (!session) return false;
  if (session.profile.status !== "active") return false;
  return session.isSuperAdmin || session.permissions.has(key);
}

export function sessionHasAnyPermission(session: MinimalSession | null, keys: PermissionKey[]): boolean {
  return keys.some((key) => sessionHasPermission(session, key));
}

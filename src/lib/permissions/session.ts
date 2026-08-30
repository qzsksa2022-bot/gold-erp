import "server-only";

import { cache } from "react";
import { createClient } from "@/lib/supabase/server";
import type { PermissionKey } from "./constants";
import type { Database } from "@/types/database";
import { sessionHasPermission, sessionHasAnyPermission } from "./resolve";

export { sessionHasPermission, sessionHasAnyPermission };

export type CurrentSession = {
  userId: string;
  email: string;
  profile: Database["public"]["Tables"]["profiles"]["Row"];
  permissions: Set<PermissionKey>;
  isSuperAdmin: boolean;
};

/**
 * Resolves the current request's authenticated user + effective
 * permissions, once per request (React `cache`). This is the single place
 * Server Components / Server Actions should call to know "who is this and
 * what can they do" — it delegates the actual permission computation to the
 * database function `get_user_permissions` (see supabase/migrations/0008),
 * so the app layer and RLS never disagree.
 *
 * Returns null when there is no signed-in user (middleware normally already
 * redirected these to /login before a page renders, but this stays
 * defensive for direct Server Action invocation).
 */
export const getCurrentSession = cache(async (): Promise<CurrentSession | null> => {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return null;

  // Self-scoped RPCs only (see supabase/migrations/0015): the uuid-taking
  // get_user_permissions/is_super_admin are service_role-only now, so the
  // app calls the wrappers that hardcode auth.uid() server-side instead of
  // ever passing a user id explicitly.
  const [{ data: profile }, { data: permissionRows }, { data: isSuperAdmin }] = await Promise.all([
    supabase.from("profiles").select("*").eq("id", user.id).single(),
    supabase.rpc("get_my_permissions"),
    supabase.rpc("am_i_super_admin"),
  ]);

  if (!profile) return null;

  return {
    userId: user.id,
    email: user.email ?? profile.email,
    profile,
    permissions: new Set((permissionRows ?? []).map((r) => r.permission_key as PermissionKey)),
    isSuperAdmin: Boolean(isSuperAdmin),
  };
});

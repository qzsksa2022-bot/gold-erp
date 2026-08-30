import "server-only";

import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import type { ProfileStatus } from "@/types/database";

export type UserListFilters = {
  q?: string;
  status?: ProfileStatus | "all";
  page: number;
  pageSize: number;
};

export async function listUsers({ q, status = "all", page, pageSize }: UserListFilters) {
  const supabase = await createClient();

  let query = supabase.from("profiles").select("*", { count: "exact" }).order("created_at", { ascending: false });

  if (q) query = query.or(`full_name.ilike.%${q}%,email.ilike.%${q}%`);
  if (status !== "all") query = query.eq("status", status);

  const from = (page - 1) * pageSize;
  const { data: profiles, error, count } = await query.range(from, from + pageSize - 1);
  if (error) throw error;

  const userIds = (profiles ?? []).map((p) => p.id);

  const [{ data: userRoles }, { data: stores }] = await Promise.all([
    userIds.length
      ? supabase.from("user_roles").select("user_id, role:roles(id, name_ar, key)").in("user_id", userIds)
      : Promise.resolve({ data: [] as { user_id: string; role: { id: string; name_ar: string; key: string } | null }[] }),
    supabase.from("stores").select("id, name_ar"),
  ]);

  const storeMap = new Map((stores ?? []).map((s) => [s.id, s.name_ar]));
  const rolesByUser = new Map<string, { id: string; name_ar: string; key: string }[]>();
  for (const row of userRoles ?? []) {
    if (!row.role) continue;
    const list = rolesByUser.get(row.user_id) ?? [];
    list.push(row.role);
    rolesByUser.set(row.user_id, list);
  }

  const users = (profiles ?? []).map((p) => ({
    ...p,
    roles: rolesByUser.get(p.id) ?? [],
    defaultStoreName: p.default_store_id ? (storeMap.get(p.default_store_id) ?? null) : null,
  }));

  return { users, total: count ?? 0 };
}

/** Best-effort last-sign-in lookup via the Admin API — bounded to a single page of results. */
export async function attachLastSignIn<T extends { id: string }>(users: T[]): Promise<(T & { lastSignInAt: string | null })[]> {
  if (users.length === 0) return [];
  try {
    const admin = createAdminClient();
    const results = await Promise.all(
      users.map(async (u) => {
        const { data } = await admin.auth.admin.getUserById(u.id);
        return { id: u.id, lastSignInAt: data.user?.last_sign_in_at ?? null };
      }),
    );
    const map = new Map(results.map((r) => [r.id, r.lastSignInAt]));
    return users.map((u) => ({ ...u, lastSignInAt: map.get(u.id) ?? null }));
  } catch (err) {
    console.error("[users] تعذر جلب آخر تسجيل دخول", err);
    return users.map((u) => ({ ...u, lastSignInAt: null }));
  }
}

export async function getUserDetail(userId: string) {
  const supabase = await createClient();

  const [{ data: profile }, { data: userRoles }, { data: overrides }, { data: storeAccess }] = await Promise.all([
    supabase.from("profiles").select("*").eq("id", userId).single(),
    supabase.from("user_roles").select("role_id, role:roles(*)").eq("user_id", userId),
    supabase
      .from("user_permission_overrides")
      .select("permission_id, effect, reason, permission:permissions(*)")
      .eq("user_id", userId),
    // Patch 1.4.1, item 2: raw `store_id` only -- deliberately NOT the
    // embedded `store:stores(...)` shape this used to select. PostgREST's
    // embedded-resource expansion is independently subject to RLS on the
    // JOINED table (`stores`) -- an actor with users.view + users.
    // manage_store_access but WITHOUT stores.view can already see this
    // row's raw `store_id` (users.view alone grants that via 0010's
    // user_store_access_select policy), but the embedded `stores` object
    // comes back null for every row (blocked by stores_select's stores.view
    // requirement), and the old code's `.filter(Boolean)` silently dropped
    // every one of them -- so the Store Access editor rendered NOTHING as
    // checked, even for stores the actor fully manages. See
    // src/features/users/store-access-helpers.ts and
    // src/app/(app)/users/[id]/page.tsx for how the raw ids below are
    // turned into checkbox state using manageable_stores_for_actor()
    // (0035) for names instead of this join.
    supabase.from("user_store_access").select("store_id").eq("user_id", userId),
  ]);

  if (!profile) return null;

  return {
    profile,
    roles: (userRoles ?? []).map((r) => r.role).filter(Boolean),
    overrides: overrides ?? [],
    storeAccessIds: (storeAccess ?? []).map((s) => s.store_id),
  };
}

// Foundation Hardening 1.4, item 4: dedicated source for "stores THIS actor
// may manage store-access for" (supabase/migrations/0035's
// manageable_stores_for_actor()) — deliberately NOT
// listActiveStoresForSelect() (src/features/stores/queries.ts), which is
// gated by stores.view and returns the FULL active store catalog. An actor
// holding only users.manage_store_access (not stores.view) would get an
// empty list from that query even though the database has fully supported
// their store-scope/store-access writes since 0018; and even a stores.view
// holder should only be offered stores within their own operable range here,
// not every store system-wide. Feeds both UserStoreScopeForm (default
// store) and UserStoreAccessEditor (the 'multiple'-scope checklist).
export async function listManageableStoresForActor() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("manageable_stores_for_actor");
  if (error) throw error;
  return (data ?? []) as { id: string; code: string; name_ar: string; name_en: string; status: string }[];
}

export async function listAllRoles() {
  const supabase = await createClient();
  const { data, error } = await supabase.from("roles").select("*").order("is_system", { ascending: false }).order("name_ar");
  if (error) throw error;
  return data ?? [];
}

export async function listAllPermissions() {
  const supabase = await createClient();
  const { data, error } = await supabase.from("permissions").select("*").order("category").order("key");
  if (error) throw error;
  return data ?? [];
}

export async function getRolePermissionIds(roleId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.from("role_permissions").select("permission_id").eq("role_id", roleId);
  if (error) throw error;
  return new Set((data ?? []).map((r) => r.permission_id));
}

export async function getPermissionIdsForRoles(roleIds: string[]) {
  if (roleIds.length === 0) return new Set<string>();
  const supabase = await createClient();
  const { data, error } = await supabase.from("role_permissions").select("permission_id").in("role_id", roleIds);
  if (error) throw error;
  return new Set((data ?? []).map((r) => r.permission_id));
}

export async function countUsersForRole(roleId: string) {
  const supabase = await createClient();
  const { count } = await supabase.from("user_roles").select("user_id", { count: "exact", head: true }).eq("role_id", roleId);
  return count ?? 0;
}

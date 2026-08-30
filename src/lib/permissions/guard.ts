import "server-only";

import { redirect } from "next/navigation";
import { ROUTES } from "@/lib/constants";
import { getCurrentSession, sessionHasAnyPermission, sessionHasPermission, type CurrentSession } from "./session";
import type { PermissionKey } from "./constants";

/**
 * Require a signed-in, active user. Use at the top of any authenticated
 * page/layout/server action. Redirects to /login (preserving the intended
 * destination) if there is no session — this mirrors what the middleware
 * already does, but Server Actions are invoked directly (not through the
 * page request the middleware saw), so they need their own check too.
 */
export async function requireSession(): Promise<CurrentSession> {
  const session = await getCurrentSession();
  if (!session) redirect(ROUTES.login);
  if (session.profile.status !== "active") redirect(`${ROUTES.login}?suspended=1`);
  return session;
}

/**
 * Require the current user to hold `key` (or be Super Admin). Redirects to
 * the 403 page otherwise. This is the server-side gate — it is what
 * actually protects a page; hiding a nav link or button is UX only.
 */
export async function requirePermission(key: PermissionKey): Promise<CurrentSession> {
  const session = await requireSession();
  if (!sessionHasPermission(session, key)) {
    redirect("/403");
  }
  return session;
}

export async function requireAnyPermission(keys: PermissionKey[]): Promise<CurrentSession> {
  const session = await requireSession();
  if (!sessionHasAnyPermission(session, keys)) {
    redirect("/403");
  }
  return session;
}

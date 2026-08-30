"use client";

import { createContext, useContext, useMemo } from "react";
import type { PermissionKey } from "./constants";

type PermissionsContextValue = {
  permissions: PermissionKey[];
  isSuperAdmin: boolean;
};

const PermissionsContext = createContext<PermissionsContextValue | null>(null);

/**
 * Provides the current user's effective permissions to the client
 * component tree. The list itself is computed server-side (see
 * src/lib/permissions/session.ts, backed by the get_user_permissions SQL
 * function) and passed down as plain props from the authenticated layout —
 * this provider never fetches or re-derives permissions on the client.
 *
 * This ONLY controls what UI is shown/hidden (buttons, nav items). It is
 * not a security boundary — RLS + server-side requirePermission() are.
 */
export function PermissionsProvider({
  permissions,
  isSuperAdmin,
  children,
}: PermissionsContextValue & { children: React.ReactNode }) {
  const value = useMemo(() => ({ permissions, isSuperAdmin }), [permissions, isSuperAdmin]);
  return <PermissionsContext.Provider value={value}>{children}</PermissionsContext.Provider>;
}

export function usePermissions() {
  const ctxOrNull = useContext(PermissionsContext);
  if (!ctxOrNull) {
    throw new Error("usePermissions must be used within a PermissionsProvider");
  }
  // Re-bind to a variable TypeScript knows is never reassigned so the
  // non-null narrowing above survives into the nested closures below
  // (control-flow narrowing of the original `useContext` result is not
  // retained inside nested function declarations).
  const ctx = ctxOrNull;
  const permissionSet = useMemo(() => new Set(ctx.permissions), [ctx.permissions]);

  function can(key: PermissionKey) {
    return ctx.isSuperAdmin || permissionSet.has(key);
  }

  function canAny(keys: PermissionKey[]) {
    return keys.some(can);
  }

  return { can, canAny, isSuperAdmin: ctx.isSuperAdmin };
}

/** Declarative conditional-render helper: <Can permission="stores.create">...</Can> */
export function Can({
  permission,
  anyOf,
  fallback = null,
  children,
}: {
  permission?: PermissionKey;
  anyOf?: PermissionKey[];
  fallback?: React.ReactNode;
  children: React.ReactNode;
}) {
  const { can, canAny } = usePermissions();
  const allowed = permission ? can(permission) : anyOf ? canAny(anyOf) : false;
  return <>{allowed ? children : fallback}</>;
}

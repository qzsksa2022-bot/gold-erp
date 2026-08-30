import { describe, expect, it } from "vitest";
import { sessionHasAnyPermission, sessionHasPermission, type MinimalSession } from "@/lib/permissions/resolve";

function makeSession(overrides: Partial<MinimalSession> = {}): MinimalSession {
  return {
    profile: { status: "active" },
    permissions: new Set(),
    isSuperAdmin: false,
    ...overrides,
  };
}

describe("sessionHasPermission", () => {
  it("returns false when there is no session", () => {
    expect(sessionHasPermission(null, "stores.view")).toBe(false);
  });

  it("returns false for a suspended user, even if they hold the permission", () => {
    const session = makeSession({
      profile: { status: "suspended" },
      permissions: new Set(["stores.view"]),
    });
    expect(sessionHasPermission(session, "stores.view")).toBe(false);
  });

  it("returns false for a suspended super admin (fail closed)", () => {
    const session = makeSession({ profile: { status: "suspended" }, isSuperAdmin: true });
    expect(sessionHasPermission(session, "settings.manage")).toBe(false);
  });

  it("returns false for a pending_setup user, even a super admin (Foundation Hardening 1.3 item 7: fail closed for any non-active status, not just suspended)", () => {
    const session = makeSession({ profile: { status: "pending_setup" }, isSuperAdmin: true, permissions: new Set(["stores.view"]) });
    expect(sessionHasPermission(session, "stores.view")).toBe(false);
  });

  it("returns true for an active super admin regardless of explicit permission set", () => {
    const session = makeSession({ isSuperAdmin: true, permissions: new Set() });
    expect(sessionHasPermission(session, "backups.manage")).toBe(true);
  });

  it("returns true only for permissions actually present in the set", () => {
    const session = makeSession({ permissions: new Set(["stores.view", "stores.create"]) });
    expect(sessionHasPermission(session, "stores.view")).toBe(true);
    expect(sessionHasPermission(session, "stores.disable")).toBe(false);
  });
});

describe("sessionHasAnyPermission", () => {
  it("returns true if at least one of the keys is present", () => {
    const session = makeSession({ permissions: new Set(["reports.view"]) });
    expect(sessionHasAnyPermission(session, ["reports.export_pdf", "reports.view"])).toBe(true);
  });

  it("returns false if none of the keys are present", () => {
    const session = makeSession({ permissions: new Set(["reports.view"]) });
    expect(sessionHasAnyPermission(session, ["reports.export_pdf", "reports.export_excel"])).toBe(false);
  });

  it("returns false for an empty key list", () => {
    const session = makeSession({ isSuperAdmin: true });
    expect(sessionHasAnyPermission(session, [])).toBe(false);
  });
});

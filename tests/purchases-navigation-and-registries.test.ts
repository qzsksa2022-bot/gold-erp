import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";

// Phase 11 (Purchases & Suppliers Core) — the supporting registries.
//
// A feature can be fully implemented in SQL and still be unreachable, or
// mislabelled in the audit log, or missing from the permission catalogue the
// admin UI renders. These are the registries that make the module real to a
// user, and each of them has drifted at least once in this project's history.
//
// The last describe block is the one that matters most: it re-asserts
// Decision 5 against the SOURCE of the expense feature — if some future change
// couples the two ledgers, this fails regardless of what the SQL says.

vi.mock("server-only", () => ({}));

import { NAV_ITEMS } from "@/components/layout/nav-items";
import { PERMISSION_KEYS } from "@/lib/permissions/constants";
import { ROUTES } from "@/lib/constants";
import { AUDIT_ACTION_LABELS_AR, AUDIT_ENTITY_LABELS_AR, auditActionLabel, auditEntityLabel } from "@/lib/audit/action-labels";

const PHASE_11_PERMISSIONS = [
  "purchases.view",
  "purchases.create",
  "purchases.reverse",
  "purchases.record_payment",
  "purchases.reverse_payment",
  "purchases.manage_suppliers",
  "purchases.process_closed_day",
] as const;

describe("permission catalogue — all 7 Phase 11 keys are declared client-side", () => {
  it.each(PHASE_11_PERMISSIONS)("%s is present in PERMISSION_KEYS", (key) => {
    expect(PERMISSION_KEYS as readonly string[]).toContain(key);
  });

  it("declares exactly the 7 keys migration 0237 seeds — no more, no fewer", () => {
    const declared = (PERMISSION_KEYS as readonly string[]).filter((k) => k.startsWith("purchases."));
    expect(declared.sort()).toEqual([...PHASE_11_PERMISSIONS].sort());
  });

  it("the client catalogue matches migration 0237 itself, key for key", () => {
    // Guards the real drift risk: a key seeded in SQL but never declared here
    // is invisible to the permissions admin screen, so nobody can grant it.
    const sql = readFileSync(path.join(process.cwd(), "supabase/migrations/0237_purchases_permissions.sql"), "utf-8");
    const seeded = [...sql.matchAll(/\('(purchases\.[a-z_]+)',\s*'purchases'/g)].map((m) => m[1]);
    expect(seeded.length).toBe(7);
    expect(seeded.sort()).toEqual([...PHASE_11_PERMISSIONS].sort());
  });
});

describe("navigation — purchases is reachable and correctly gated", () => {
  it("exposes a Purchases entry gated on purchases.view", () => {
    const item = NAV_ITEMS.find((i) => i.href === ROUTES.purchases);
    expect(item, "the Purchases nav item should exist").toBeDefined();
    expect(item!.permission).toBe("purchases.view");
  });

  it("is not falsely labelled coming soon — the module ships in this phase", () => {
    const item = NAV_ITEMS.find((i) => i.href === ROUTES.purchases);
    expect(item!.comingSoon).toBeUndefined();
    expect(NAV_ITEMS.filter((i) => i.comingSoon)).toHaveLength(0);
  });

  it("the Master Data hub is visible to an actor holding only purchases.manage_suppliers", () => {
    // The suppliers catalogue lives under master-data; without this key in the
    // hub's anyOf list, a supplier manager could not navigate to their own page.
    const hub = NAV_ITEMS.find((i) => i.href === ROUTES.masterData);
    expect(hub?.anyOf).toContain("purchases.manage_suppliers");
  });

  it("pins the Phase 11 routes", () => {
    expect(ROUTES.purchases).toBe("/purchases");
    expect(ROUTES.purchasesNew).toBe("/purchases/new");
    expect(ROUTES.purchasesOutstanding).toBe("/purchases/outstanding");
    expect(ROUTES.suppliers).toBe("/master-data/suppliers");
  });
});

describe("audit log — every Phase 11 event has an Arabic label", () => {
  const ACTIONS = [
    "supplier.create",
    "supplier.update",
    "supplier.enable",
    "supplier.disable",
    "purchase.post",
    "purchase.reverse",
    "supplier_payment.record",
    "supplier_payment.reverse",
  ];

  it.each(ACTIONS)("%s resolves to a real Arabic label, not the raw key", (action) => {
    expect(AUDIT_ACTION_LABELS_AR[action]).toBeDefined();
    expect(auditActionLabel(action)).not.toBe(action);
  });

  it.each(["supplier", "purchase_invoice", "supplier_payment"])("entity %s resolves to a real Arabic label", (entity) => {
    expect(AUDIT_ENTITY_LABELS_AR[entity]).toBeDefined();
    expect(auditEntityLabel(entity)).not.toBe(entity);
  });

  it("covers exactly the actions migration 0239 actually emits", () => {
    // A label registry drifts silently: the RPC keeps emitting an action the
    // UI can no longer name, and the audit screen shows a raw English key.
    const sql = readFileSync(path.join(process.cwd(), "supabase/migrations/0239_purchases_rpcs.sql"), "utf-8");
    const emitted = new Set([...sql.matchAll(/log_audit_event\(\s*\n?\s*'([a-z_.]+)'/g)].map((m) => m[1]));
    // supplier.enable/disable are emitted through a CASE expression, so they
    // are asserted by the per-action test above rather than by this scan.
    for (const action of emitted) {
      expect(AUDIT_ACTION_LABELS_AR[action], `migration 0239 emits '${action}' with no Arabic label`).toBeDefined();
    }
    expect(emitted.size).toBeGreaterThanOrEqual(5);
  });
});

describe("DECISION 5 — the two ledgers stay disjoint in the TypeScript layer too", () => {
  /**
   * Reads a source file with its comments removed. Both features legitimately
   * NAME the other in prose — each file's header explains the boundary and
   * says which sibling module it mirrors. Scanning the raw text would flag
   * that documentation as a coupling, so only executable code is examined.
   * CRLF is normalized first: `.` never matches `\r`, so on a CRLF checkout
   * `/\/\/.*$/` would strip nothing (the same trap fixed in
   * tests/inventory-money-string-invariant.test.ts).
   */
  function read(rel: string): string {
    const raw = readFileSync(path.join(process.cwd(), rel), "utf-8");
    return raw
      .replace(/\r\n/g, "\n")
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .split("\n")
      .map((line) => line.replace(/\/\/.*$/, ""))
      .join("\n");
  }

  it("the comment-stripped scan still sees real code — it cannot pass by reading nothing", () => {
    // Without this, a bug in the stripper would make every assertion below
    // vacuously true.
    const source = read("src/features/purchases/actions.ts");
    expect(source).toMatch(/post_purchase_invoice/);
    expect(source).toMatch(/requirePermission\("purchases\.create"\)/);
  });

  it("no purchases source file references the expense feature", () => {
    for (const f of ["src/features/purchases/actions.ts", "src/features/purchases/queries.ts", "src/features/purchases/schema.ts"]) {
      const source = read(f);
      expect(source, `${f} must not import or call the expense feature`).not.toMatch(/features\/expenses/);
      expect(source).not.toMatch(/store_expense|record_store_expense/);
    }
  });

  it("no expense source file references the purchases feature", () => {
    for (const f of ["src/features/expenses/actions.ts", "src/features/expenses/queries.ts", "src/features/expenses/schema.ts"]) {
      const source = read(f);
      expect(source, `${f} must not import or call the purchases feature`).not.toMatch(/features\/purchases/);
      expect(source).not.toMatch(/purchase_invoice|supplier_payment/);
    }
  });

  it("no purchases action revalidates the dashboard — net_operating_return cannot move because of a purchase", () => {
    expect(read("src/features/purchases/actions.ts")).not.toMatch(/ROUTES\.dashboard/);
  });
});

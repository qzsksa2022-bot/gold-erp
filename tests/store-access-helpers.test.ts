import { describe, expect, it } from "vitest";
import { selectableStoreAccessIds } from "@/features/users/store-access-helpers";

// Patch 1.4.1, item 2: an actor scoped to stores A+B (via
// manageable_stores_for_actor(), supabase/migrations/0035) editing a
// target who holds A+C (C outside the actor's own operable range) must
// see exactly A checked — never C (the actor cannot manage it and the UI
// must not even reveal its existence), and never anything the actor
// doesn't manage rendered as "selected" by mistake.
describe("selectableStoreAccessIds", () => {
  it("keeps only stores present in both the target's current grants and the actor's manageable stores", () => {
    const currentGrants = ["A", "C"];
    const manageable = ["A", "B"];
    expect(selectableStoreAccessIds(currentGrants, manageable)).toEqual(["A"]);
  });

  it("returns an empty list when the target has no grants at all", () => {
    expect(selectableStoreAccessIds([], ["A", "B"])).toEqual([]);
  });

  it("returns an empty list when the actor can manage nothing (no false positives)", () => {
    expect(selectableStoreAccessIds(["A", "C"], [])).toEqual([]);
  });

  it("never invents a selection the target does not actually hold", () => {
    // Actor manages A+B, but the target only holds C (outside range) —
    // nothing should render as checked, and B must NOT appear just
    // because the actor can manage it.
    expect(selectableStoreAccessIds(["C"], ["A", "B"])).toEqual([]);
  });

  it("accepts a Set for the manageable-stores argument", () => {
    expect(selectableStoreAccessIds(["A", "C"], new Set(["A", "B"]))).toEqual(["A"]);
  });

  it("preserves the target's own grant order among selectable stores", () => {
    expect(selectableStoreAccessIds(["C", "B", "A"], ["A", "B"])).toEqual(["B", "A"]);
  });
});

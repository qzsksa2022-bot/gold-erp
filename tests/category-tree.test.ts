import { describe, expect, it } from "vitest";
import { buildCategoryTree, descendantIds } from "@/features/categories/tree";
import type { Category } from "@/features/categories/tree";

function makeCategory(overrides: Partial<Category> & { id: string }): Category {
  return {
    parent_id: null,
    code: null,
    name_ar: overrides.id,
    name_en: null,
    sort_order: 0,
    status: "active",
    external_id: null,
    external_source: null,
    created_by: null,
    updated_by: null,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

describe("buildCategoryTree", () => {
  it("nests children under their parent, unlimited depth", () => {
    const flat: Category[] = [
      makeCategory({ id: "rings" }),
      makeCategory({ id: "gold-rings", parent_id: "rings" }),
      makeCategory({ id: "engagement-rings", parent_id: "gold-rings" }),
      makeCategory({ id: "chains" }),
    ];

    const tree = buildCategoryTree(flat);
    expect(tree.map((n) => n.id)).toEqual(["rings", "chains"]);
    expect(tree[0].children.map((n) => n.id)).toEqual(["gold-rings"]);
    expect(tree[0].children[0].children.map((n) => n.id)).toEqual(["engagement-rings"]);
    expect(tree[0].children[0].children[0].children).toEqual([]);
  });

  it("treats a category whose parent_id points to a missing row as a root (defensive, should never happen given the FK)", () => {
    const flat: Category[] = [makeCategory({ id: "orphan", parent_id: "does-not-exist" })];
    const tree = buildCategoryTree(flat);
    expect(tree.map((n) => n.id)).toEqual(["orphan"]);
  });
});

describe("descendantIds", () => {
  it("returns every descendant, not just direct children", () => {
    const flat: Category[] = [
      makeCategory({ id: "a" }),
      makeCategory({ id: "b", parent_id: "a" }),
      makeCategory({ id: "c", parent_id: "b" }),
      makeCategory({ id: "d" }), // unrelated sibling
    ];

    expect(descendantIds(flat, "a")).toEqual(new Set(["b", "c"]));
    expect(descendantIds(flat, "b")).toEqual(new Set(["c"]));
    expect(descendantIds(flat, "c")).toEqual(new Set());
    expect(descendantIds(flat, "d")).toEqual(new Set());
  });
});

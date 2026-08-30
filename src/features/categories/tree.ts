import type { Database } from "@/types/database";

export type Category = Database["public"]["Tables"]["product_categories"]["Row"];
export type CategoryNode = Category & { children: CategoryNode[] };

/** Builds a parent/children tree from a flat list — pure, no I/O, unit-testable. Depth is unbounded (spec §5). */
export function buildCategoryTree(flat: Category[]): CategoryNode[] {
  const nodesById = new Map<string, CategoryNode>(flat.map((c) => [c.id, { ...c, children: [] }]));
  const roots: CategoryNode[] = [];

  for (const node of nodesById.values()) {
    if (node.parent_id && nodesById.has(node.parent_id)) {
      nodesById.get(node.parent_id)!.children.push(node);
    } else {
      roots.push(node);
    }
  }

  return roots;
}

/** All descendant ids of `categoryId` (itself excluded) — used to keep the parent picker from offering a category's own subtree (which the DB would reject anyway, but this keeps the UI from ever suggesting an invalid choice). */
export function descendantIds(flat: Category[], categoryId: string): Set<string> {
  const childrenOf = new Map<string, string[]>();
  for (const c of flat) {
    if (!c.parent_id) continue;
    childrenOf.set(c.parent_id, [...(childrenOf.get(c.parent_id) ?? []), c.id]);
  }

  const result = new Set<string>();
  const stack = [...(childrenOf.get(categoryId) ?? [])];
  while (stack.length) {
    const id = stack.pop()!;
    if (result.has(id)) continue;
    result.add(id);
    stack.push(...(childrenOf.get(id) ?? []));
  }
  return result;
}

"use client";

import { ChevronLeft, ChevronDown, FolderTree } from "lucide-react";
import { useState } from "react";
import { Can } from "@/lib/permissions/context";
import { CategoryFormDialog } from "./category-form-dialog";
import { CategoryStatusBadge } from "./category-status-badge";
import { CategoryStatusToggle } from "./category-status-toggle";
import { buildCategoryTree, type Category, type CategoryNode } from "../tree";
import { cn } from "@/lib/utils";

function CategoryRow({ node, depth, allCategories }: { node: CategoryNode; depth: number; allCategories: Category[] }) {
  const [expanded, setExpanded] = useState(true);
  const hasChildren = node.children.length > 0;

  return (
    <div>
      <div
        className={cn("flex flex-wrap items-center justify-between gap-2 border-b border-border py-2.5", depth > 0 && "ps-6")}
        style={depth > 0 ? { paddingInlineStart: `${depth * 1.5 + 0.5}rem` } : undefined}
      >
        <div className="flex min-w-0 items-center gap-2">
          {hasChildren ? (
            <button
              type="button"
              onClick={() => setExpanded((v) => !v)}
              className="text-muted-foreground hover:text-foreground"
              aria-label={expanded ? "طي" : "توسيع"}
            >
              {expanded ? <ChevronDown className="size-4" /> : <ChevronLeft className="size-4" />}
            </button>
          ) : (
            <FolderTree className="size-4 text-muted-foreground" />
          )}
          <div className="flex min-w-0 flex-col">
            <span className="truncate font-medium">{node.name_ar}</span>
            {node.name_en && <span className="truncate text-xs text-muted-foreground">{node.name_en}</span>}
          </div>
          {node.code && (
            <span className="hidden rounded bg-muted px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground sm:inline">
              {node.code}
            </span>
          )}
          <CategoryStatusBadge status={node.status} />
        </div>

        <div className="flex shrink-0 items-center gap-1">
          <Can permission="categories.manage">
            <CategoryFormDialog allCategories={allCategories} defaultParentId={node.id} />
            <CategoryFormDialog category={node} allCategories={allCategories} />
            <CategoryStatusToggle categoryId={node.id} status={node.status} categoryName={node.name_ar} />
          </Can>
        </div>
      </div>

      {expanded && hasChildren && (
        <div>
          {node.children.map((child) => (
            <CategoryRow key={child.id} node={child} depth={depth + 1} allCategories={allCategories} />
          ))}
        </div>
      )}
    </div>
  );
}

export function CategoryTreeView({ categories }: { categories: Category[] }) {
  const tree = buildCategoryTree(categories);

  return (
    <div className="rounded-xl border border-border bg-card px-4">
      {tree.map((node) => (
        <CategoryRow key={node.id} node={node} depth={0} allCategories={categories} />
      ))}
    </div>
  );
}

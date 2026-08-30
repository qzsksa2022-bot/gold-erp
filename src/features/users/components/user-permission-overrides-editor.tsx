"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import { setPermissionOverrideAction } from "../actions";
import { PERMISSION_CATEGORY_LABELS_AR } from "@/lib/permissions/constants";
import type { Database } from "@/types/database";

type Permission = Database["public"]["Tables"]["permissions"]["Row"];
type Effect = "grant" | "revoke" | "clear";

export function UserPermissionOverridesEditor({
  userId,
  allPermissions,
  fromRolePermissionIds,
  initialOverrides,
  readOnly,
}: {
  userId: string;
  allPermissions: Permission[];
  fromRolePermissionIds: Set<string>;
  initialOverrides: Map<string, "grant" | "revoke">;
  readOnly: boolean;
}) {
  const [overrides, setOverrides] = useState(initialOverrides);
  const [, startTransition] = useTransition();

  const grouped = allPermissions.reduce<Record<string, Permission[]>>((acc, p) => {
    (acc[p.category] ??= []).push(p);
    return acc;
  }, {});

  function setEffect(permissionId: string, effect: Effect) {
    const prevMap = new Map(overrides);
    setOverrides((prev) => {
      const next = new Map(prev);
      if (effect === "clear") next.delete(permissionId);
      else next.set(permissionId, effect);
      return next;
    });
    startTransition(async () => {
      const result = await setPermissionOverrideAction(userId, permissionId, effect);
      if (!result.success) {
        toast.error(result.error);
        setOverrides(prevMap);
      }
    });
  }

  return (
    <ScrollArea className="max-h-[28rem] pe-3">
      <div className="flex flex-col gap-5">
        {Object.entries(grouped).map(([category, perms]) => (
          <div key={category}>
            <p className="mb-2 text-xs font-semibold text-muted-foreground">{PERMISSION_CATEGORY_LABELS_AR[category] ?? category}</p>
            <div className="flex flex-col divide-y divide-border rounded-lg border border-border">
              {perms.map((p) => {
                const fromRole = fromRolePermissionIds.has(p.id);
                const override = overrides.get(p.id);
                return (
                  <div key={p.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
                    <div className="flex items-center gap-2">
                      <span className="text-sm">{p.description_ar}</span>
                      {fromRole && !override && (
                        <Badge variant="outline" className="text-[10px]">
                          من الدور
                        </Badge>
                      )}
                    </div>
                    {!readOnly ? (
                      <div className="flex overflow-hidden rounded-md border border-border text-xs">
                        <OverrideButton active={override === "revoke"} tone="destructive" onClick={() => setEffect(p.id, "revoke")}>
                          سحب
                        </OverrideButton>
                        <OverrideButton active={!override} tone="neutral" onClick={() => setEffect(p.id, "clear")}>
                          تلقائي
                        </OverrideButton>
                        <OverrideButton active={override === "grant"} tone="success" onClick={() => setEffect(p.id, "grant")}>
                          منح
                        </OverrideButton>
                      </div>
                    ) : (
                      <Badge variant={override === "grant" ? "success" : override === "revoke" ? "destructive" : "outline"}>
                        {override === "grant" ? "ممنوحة" : override === "revoke" ? "مسحوبة" : fromRole ? "من الدور" : "لا يملكها"}
                      </Badge>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
        ))}
      </div>
    </ScrollArea>
  );
}

function OverrideButton({
  active,
  tone,
  onClick,
  children,
}: {
  active: boolean;
  tone: "destructive" | "neutral" | "success";
  onClick: () => void;
  children: React.ReactNode;
}) {
  const toneClasses = {
    destructive: "data-[active=true]:bg-destructive data-[active=true]:text-destructive-foreground",
    neutral: "data-[active=true]:bg-secondary-foreground data-[active=true]:text-secondary",
    success: "data-[active=true]:bg-success data-[active=true]:text-success-foreground",
  }[tone];

  return (
    <button
      type="button"
      data-active={active}
      onClick={onClick}
      className={cn("px-2.5 py-1.5 text-muted-foreground transition-colors hover:bg-secondary", toneClasses)}
    >
      {children}
    </button>
  );
}

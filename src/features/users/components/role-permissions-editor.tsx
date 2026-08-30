"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Settings2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { toggleRolePermissionAction } from "../roles-actions";
import { PERMISSION_CATEGORY_LABELS_AR } from "@/lib/permissions/constants";
import type { Database } from "@/types/database";

type Permission = Database["public"]["Tables"]["permissions"]["Row"];
type Role = Database["public"]["Tables"]["roles"]["Row"];

export function RolePermissionsEditor({
  role,
  allPermissions,
  assignedPermissionIds,
}: {
  role: Role;
  allPermissions: Permission[];
  assignedPermissionIds: Set<string>;
}) {
  const [open, setOpen] = useState(false);
  const [assigned, setAssigned] = useState(assignedPermissionIds);
  const [, startTransition] = useTransition();
  const isSuperAdminRole = role.key === "super_admin";

  const grouped = allPermissions.reduce<Record<string, Permission[]>>((acc, p) => {
    (acc[p.category] ??= []).push(p);
    return acc;
  }, {});

  function toggle(permissionId: string, enabled: boolean) {
    setAssigned((prev) => {
      const next = new Set(prev);
      if (enabled) next.add(permissionId);
      else next.delete(permissionId);
      return next;
    });
    startTransition(async () => {
      const result = await toggleRolePermissionAction(role.id, permissionId, enabled);
      if (!result.success) {
        toast.error(result.error);
        setAssigned((prev) => {
          const reverted = new Set(prev);
          if (enabled) reverted.delete(permissionId);
          else reverted.add(permissionId);
          return reverted;
        });
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="icon" aria-label="تعديل صلاحيات الدور">
          <Settings2 className="size-4" />
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-xl">
        <DialogHeader>
          <DialogTitle>صلاحيات دور: {role.name_ar}</DialogTitle>
          <DialogDescription>
            {isSuperAdminRole
              ? "مستخدم Super Admin يملك كل الصلاحيات دائمًا بغض النظر عن هذه القائمة."
              : "حدد الصلاحيات التي يمنحها هذا الدور. يتم الحفظ فور التبديل."}
          </DialogDescription>
        </DialogHeader>

        <ScrollArea className="max-h-[60vh] pe-3">
          <div className="flex flex-col gap-5">
            {Object.entries(grouped).map(([category, perms]) => (
              <div key={category}>
                <p className="mb-2 text-xs font-semibold text-muted-foreground">
                  {PERMISSION_CATEGORY_LABELS_AR[category] ?? category}
                </p>
                <div className="flex flex-col gap-2">
                  {perms.map((p) => (
                    <label key={p.id} className="flex cursor-pointer items-center gap-2.5 rounded-md px-1 py-1 text-sm hover:bg-secondary/60">
                      <Checkbox
                        checked={assigned.has(p.id)}
                        disabled={isSuperAdminRole}
                        onCheckedChange={(checked) => toggle(p.id, checked === true)}
                      />
                      <span>{p.description_ar}</span>
                      <span className="ms-auto font-mono text-[11px] text-muted-foreground">{p.key}</span>
                    </label>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </ScrollArea>
      </DialogContent>
    </Dialog>
  );
}

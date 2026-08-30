"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { X } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { assignRoleAction, removeRoleAction } from "../actions";
import type { Database } from "@/types/database";

type Role = Database["public"]["Tables"]["roles"]["Row"];

export function UserRolesEditor({
  userId,
  assignedRoles,
  allRoles,
  readOnly,
}: {
  userId: string;
  assignedRoles: Role[];
  allRoles: Role[];
  readOnly: boolean;
}) {
  const [selected, setSelected] = useState("");
  const [isPending, startTransition] = useTransition();
  const assignedIds = new Set(assignedRoles.map((r) => r.id));
  const available = allRoles.filter((r) => !assignedIds.has(r.id));

  function handleAdd() {
    if (!selected) return;
    startTransition(async () => {
      const result = await assignRoleAction(userId, selected);
      if (result.success) {
        toast.success(result.message);
        setSelected("");
      } else toast.error(result.error);
    });
  }

  function handleRemove(roleId: string) {
    startTransition(async () => {
      const result = await removeRoleAction(userId, roleId);
      if (result.success) toast.success(result.message);
      else toast.error(result.error);
    });
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap gap-2">
        {assignedRoles.length === 0 && <p className="text-sm text-muted-foreground">لا يوجد أي دور مُسند لهذا المستخدم.</p>}
        {assignedRoles.map((role) => (
          <Badge key={role.id} variant="outline" className="gap-1.5 py-1 ps-3 pe-1.5">
            {role.name_ar}
            {!readOnly && (
              <button
                type="button"
                onClick={() => handleRemove(role.id)}
                disabled={isPending}
                className="rounded-full p-0.5 hover:bg-destructive/10 hover:text-destructive"
                aria-label={`إزالة دور ${role.name_ar}`}
              >
                <X className="size-3" />
              </button>
            )}
          </Badge>
        ))}
      </div>

      {!readOnly && available.length > 0 && (
        <div className="flex items-center gap-2">
          <Select value={selected} onValueChange={setSelected}>
            <SelectTrigger className="w-56">
              <SelectValue placeholder="إضافة دور..." />
            </SelectTrigger>
            <SelectContent>
              {available.map((role) => (
                <SelectItem key={role.id} value={role.id}>
                  {role.name_ar}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Button type="button" size="sm" onClick={handleAdd} disabled={!selected || isPending}>
            إسناد
          </Button>
        </div>
      )}
    </div>
  );
}

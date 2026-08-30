"use client";

import { useState } from "react";
import { Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { deleteRoleAction } from "../roles-actions";

export function RoleDeleteButton({ roleId, roleName, userCount }: { roleId: string; roleName: string; userCount: number }) {
  const [open, setOpen] = useState(false);

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label="حذف الدور">
        <Trash2 className="size-4 text-destructive" />
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={`حذف دور "${roleName}"؟`}
        description={
          userCount > 0
            ? `لا يمكن حذف هذا الدور لأنه مُسند إلى ${userCount} مستخدم.`
            : "لا يمكن التراجع عن هذا الإجراء."
        }
        confirmLabel="حذف"
        destructive
        onConfirm={async () => {
          const result = await deleteRoleAction(roleId);
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}

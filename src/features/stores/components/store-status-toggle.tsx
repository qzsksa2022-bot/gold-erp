"use client";

import { useState } from "react";
import { Power, PowerOff } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { setStoreStatusAction } from "../actions";
import type { StoreStatus } from "@/types/database";

export function StoreStatusToggle({ storeId, status, storeName }: { storeId: string; status: StoreStatus; storeName: string }) {
  const [open, setOpen] = useState(false);
  const willDisable = status === "active";

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label={willDisable ? "تعطيل المتجر" : "إعادة تفعيل المتجر"}>
        {willDisable ? <PowerOff className="size-4 text-destructive" /> : <Power className="size-4 text-success" />}
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={willDisable ? `تعطيل متجر "${storeName}"؟` : `إعادة تفعيل متجر "${storeName}"؟`}
        description={
          willDisable
            ? "لن يتمكن الموظفون من العمل على هذا المتجر بعد تعطيله. يمكن إعادة تفعيله لاحقًا في أي وقت."
            : "سيصبح هذا المتجر متاحًا للعمل عليه مجددًا."
        }
        confirmLabel={willDisable ? "تعطيل" : "تفعيل"}
        destructive={willDisable}
        onConfirm={async () => {
          const result = await setStoreStatusAction(storeId, willDisable ? "disabled" : "active");
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}

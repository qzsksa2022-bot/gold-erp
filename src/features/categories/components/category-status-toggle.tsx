"use client";

import { useState } from "react";
import { Power, PowerOff } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { setCategoryStatusAction } from "../actions";
import type { MasterDataStatus } from "@/types/database";

export function CategoryStatusToggle({
  categoryId,
  status,
  categoryName,
}: {
  categoryId: string;
  status: MasterDataStatus;
  categoryName: string;
}) {
  const [open, setOpen] = useState(false);
  const willDisable = status === "active";

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label={willDisable ? "تعطيل التصنيف" : "إعادة تفعيل التصنيف"}>
        {willDisable ? <PowerOff className="size-4 text-destructive" /> : <Power className="size-4 text-success" />}
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={willDisable ? `تعطيل تصنيف "${categoryName}"؟` : `إعادة تفعيل تصنيف "${categoryName}"؟`}
        description={
          willDisable
            ? "لن يظهر هذا التصنيف كخيار جديد بعد تعطيله، وستبقى التصنيفات الفرعية وبياناته التاريخية كما هي."
            : "سيصبح هذا التصنيف متاحًا للاستخدام مجددًا."
        }
        confirmLabel={willDisable ? "تعطيل" : "تفعيل"}
        destructive={willDisable}
        onConfirm={async () => {
          const result = await setCategoryStatusAction(categoryId, willDisable ? "inactive" : "active");
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}

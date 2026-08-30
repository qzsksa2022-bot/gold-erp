"use client";

import { useState } from "react";
import { Power, PowerOff } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { setAdjustmentTypeStatusAction } from "../actions";

/** Enable/disable toggle for adjustment_types — goes through disable_adjustment_type()/enable_adjustment_type() (0136), never a raw table write. */
export function AdjustmentTypeStatusToggle({ typeId, status, typeName }: { typeId: string; status: "active" | "disabled"; typeName: string }) {
  const [open, setOpen] = useState(false);
  const willDisable = status === "active";

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label={willDisable ? "تعطيل النوع" : "إعادة تفعيل النوع"}>
        {willDisable ? <PowerOff className="size-4 text-destructive" /> : <Power className="size-4 text-success" />}
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={willDisable ? `تعطيل نوع "${typeName}"؟` : `إعادة تفعيل نوع "${typeName}"؟`}
        description={
          willDisable
            ? "لن يظهر هذا النوع كخيار عند إنشاء تعديل/خدمة جديد بعد تعطيله — كل السجلات التاريخية التي تستخدمه تبقى دون تأثير."
            : "سيصبح هذا النوع متاحًا للاستخدام في تعديلات/خدمات جديدة مجددًا."
        }
        confirmLabel={willDisable ? "تعطيل" : "تفعيل"}
        destructive={willDisable}
        onConfirm={async () => {
          const result = await setAdjustmentTypeStatusAction(typeId, willDisable ? "disabled" : "active");
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}

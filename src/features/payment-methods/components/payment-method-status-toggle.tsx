"use client";

import { useState } from "react";
import { Power, PowerOff } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/shared/confirm-dialog";
import { setPaymentMethodStatusAction } from "../actions";
import type { MasterDataStatus } from "@/types/database";

export function PaymentMethodStatusToggle({ methodId, status, methodName }: { methodId: string; status: MasterDataStatus; methodName: string }) {
  const [open, setOpen] = useState(false);
  const willDisable = status === "active";

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label={willDisable ? "تعطيل طريقة الدفع" : "إعادة تفعيل طريقة الدفع"}>
        {willDisable ? <PowerOff className="size-4 text-destructive" /> : <Power className="size-4 text-success" />}
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={willDisable ? `تعطيل طريقة دفع "${methodName}"؟` : `إعادة تفعيل طريقة دفع "${methodName}"؟`}
        description={
          willDisable
            ? "لن تظهر طريقة الدفع هذه كخيار في عمليات جديدة بعد تعطيلها، وستبقى بياناتها التاريخية كما هي."
            : "ستصبح طريقة الدفع هذه متاحة للاستخدام مجددًا."
        }
        confirmLabel={willDisable ? "تعطيل" : "تفعيل"}
        destructive={willDisable}
        onConfirm={async () => {
          const result = await setPaymentMethodStatusAction(methodId, willDisable ? "inactive" : "active");
          if (result.success) toast.success(result.message);
          else toast.error(result.error);
        }}
      />
    </>
  );
}
